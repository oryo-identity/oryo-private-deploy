#!/usr/bin/env bash
# Oryo private-deployment AWS + k8s prep.
# Idempotent: safe to re-run. Each step is `create-or-tolerate-exists`.
#
# Usage:
#   1. Copy .env.example → .env and fill in values
#   2. ./scripts/setup.sh
#
# After this completes, fill in values.yaml (use the ARNs printed at the end)
# and run `helm install`.

set -euo pipefail

# ----- Load config ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example → .env and fill in values." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${AWS_PROFILE:?AWS_PROFILE must be set in .env}"
: "${AWS_REGION:?AWS_REGION must be set in .env}"
: "${ACCOUNT_ID:?ACCOUNT_ID must be set in .env}"
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"
: "${NAMESPACE:?NAMESPACE must be set in .env}"
: "${BUCKET_NAME:?BUCKET_NAME must be set in .env}"
: "${DB_ADMIN_USER:?DB_ADMIN_USER must be set in .env (RDS superuser)}"
: "${DB_ADMIN_PASSWORD:?DB_ADMIN_PASSWORD must be set in .env}"
: "${DB_HOST:?DB_HOST must be set in .env (RDS endpoint)}"
: "${DB_NAME:?DB_NAME must be set in .env (target database to create if missing)}"

export AWS_PROFILE AWS_REGION

POLICY_NAME="${POLICY_NAME:-OryoWorkloadPolicy}"
ROLE_NAME="${ROLE_NAME:-OryoWorkloadRole}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-oryo-platform-workload}"

log() { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }

# ----- 0. Sanity ----------------------------------------------------------

log "Verifying AWS identity..."
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [[ "$ACTUAL_ACCOUNT" != "$ACCOUNT_ID" ]]; then
  echo "ERROR: AWS_PROFILE=$AWS_PROFILE is in account $ACTUAL_ACCOUNT, expected $ACCOUNT_ID" >&2
  exit 1
fi

log "Verifying kubectl context..."
kubectl config current-context >/dev/null || { echo "kubectl not configured" >&2; exit 1; }

# ----- 1. S3 object-storage bucket -----------------------------------------

log "Ensuring S3 bucket $BUCKET_NAME exists..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  log "  bucket exists"
else
  aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
  log "  bucket created"
fi

# ----- 2. IAM policy + IRSA role ------------------------------------------

log "Ensuring IAM policy $POLICY_NAME..."
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "  policy exists"
else
  TMP_POLICY=$(mktemp)
  cat > "$TMP_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${BUCKET_NAME}",
      "arn:aws:s3:::${BUCKET_NAME}/*"
    ]
  }]
}
EOF
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$TMP_POLICY" >/dev/null
  rm "$TMP_POLICY"
  log "  policy created"
fi

log "Ensuring IRSA role $ROLE_NAME bound to $NAMESPACE/$SERVICE_ACCOUNT..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "  role exists"
else
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace "$NAMESPACE" \
    --name "$SERVICE_ACCOUNT" \
    --role-name "$ROLE_NAME" \
    --attach-policy-arn "$POLICY_ARN" \
    --approve --region "$AWS_REGION"
  log "  role + service account created"
fi
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

# ----- 3. Namespace --------------------------------------------------------

log "Ensuring namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ----- 4. K8s secrets ------------------------------------------------------

create_secret() {
  local name="$1"; shift
  if kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    log "  secret $name exists"
  else
    kubectl -n "$NAMESPACE" create secret generic "$name" "$@" >/dev/null
    log "  secret $name created"
  fi
}

log "Ensuring k8s secrets..."
create_secret oryo-session-secret \
  --from-literal=value="$(openssl rand -hex 32)"
create_secret oryo-db-admin \
  --from-literal=username="$DB_ADMIN_USER" \
  --from-literal=password="$DB_ADMIN_PASSWORD"
for role in dashboard gateway worker; do
  create_secret "oryo-db-$role" \
    --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
done

# ----- 5. Ensure the target database exists --------------------------------
#
# Workaround for: dbInit currently assumes DB_NAME exists. See follow-up task
# "dbInit: create DB_DATABASE if missing". Remove this block once that ships.

log "Ensuring database '$DB_NAME' exists on $DB_HOST..."

# Use a one-shot in-cluster pod (laptops can't reach RDS in private subnets).
PSQL_POD="psql-bootstrap-$$"
trap 'kubectl -n "$NAMESPACE" delete pod "$PSQL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

kubectl -n "$NAMESPACE" run "$PSQL_POD" \
  --image=postgres:16-alpine --restart=Never --command -- \
  sh -c "PGPASSWORD='$DB_ADMIN_PASSWORD' psql 'host=$DB_HOST port=5432 dbname=postgres user=$DB_ADMIN_USER sslmode=require' -tAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\" | grep -q 1 || PGPASSWORD='$DB_ADMIN_PASSWORD' psql 'host=$DB_HOST port=5432 dbname=postgres user=$DB_ADMIN_USER sslmode=require' -c 'CREATE DATABASE \"$DB_NAME\";'" >/dev/null

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"$PSQL_POD" --timeout=60s >/dev/null
# Wait for the container to actually finish its command
sleep 5
LOG=$(kubectl -n "$NAMESPACE" logs "$PSQL_POD" 2>&1 || true)
kubectl -n "$NAMESPACE" delete pod "$PSQL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
trap - EXIT

if echo "$LOG" | grep -qi 'CREATE DATABASE'; then
  log "  database '$DB_NAME' created"
elif echo "$LOG" | grep -qiE 'error|fatal'; then
  echo "ERROR creating database '$DB_NAME':" >&2
  echo "$LOG" >&2
  exit 1
else
  log "  database '$DB_NAME' already exists"
fi

# ----- 6. IngressClass for EKS Auto Mode -----------------------------------

log "Ensuring IngressClass 'alb' (EKS Auto Mode)..."
kubectl apply -f - <<EOF >/dev/null
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: eks.amazonaws.com/alb
EOF
log "  applied"

# ----- 7. EKS Auto Mode: allow arm64 in default NodePool -------------------
#
# Auto Mode ships a `general-purpose` NodePool that ONLY provisions amd64
# instances by default. Oryo images are arm64 (matching prod's Graviton
# nodes), so without this patch every pod stays Pending with:
#   incompatible requirements, key kubernetes.io/arch, In [arm64] not in [amd64]
#
# Idempotent: re-applying with arm64 already present is a no-op.

if kubectl get nodepool general-purpose >/dev/null 2>&1; then
  log "Ensuring Auto Mode 'general-purpose' NodePool allows arm64..."
  CURRENT_ARCH=$(kubectl get nodepool general-purpose -o json \
    | jq -r '.spec.template.spec.requirements[] | select(.key=="kubernetes.io/arch") | .values | sort | join(",")')
  if echo "$CURRENT_ARCH" | grep -q arm64; then
    log "  arm64 already allowed ($CURRENT_ARCH)"
  else
    kubectl get nodepool general-purpose -o json \
      | jq '.spec.template.spec.requirements |= map(if .key == "kubernetes.io/arch" then .values = (.values + ["arm64"] | unique) else . end)
            | del(.status, .metadata.resourceVersion, .metadata.uid, .metadata.generation, .metadata.creationTimestamp, .metadata.managedFields)' \
      | kubectl apply -f - >/dev/null
    log "  patched (now allows arm64 + amd64)"
  fi
else
  log "No Auto Mode NodePool found — assuming classic node group (skip arch patch)."
fi

# ----- 8. Tag public subnets for ALB auto-discovery ------------------------
#
# The EKS Auto Mode ALB controller auto-discovers subnets to place ALBs in by
# scanning the cluster's VPC for subnets tagged `kubernetes.io/role/elb=1`
# (internet-facing). Without this, Ingresses sit forever with no ADDRESS and
# events show:
#   Failed build model due to couldn't auto-discover subnets
#
# We tag public subnets only (MapPublicIpOnLaunch=true). For internal ALBs
# you'd tag private subnets with kubernetes.io/role/internal-elb=1 — out of
# scope here.

log "Tagging public subnets for ALB auto-discovery..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text)
if [[ -z "$PUBLIC_SUBNETS" ]]; then
  echo "WARN: no public subnets found in VPC $VPC_ID — ALBs will fail to provision" >&2
else
  # shellcheck disable=SC2086
  aws ec2 create-tags --resources $PUBLIC_SUBNETS --tags Key=kubernetes.io/role/elb,Value=1 >/dev/null
  log "  tagged: $(echo $PUBLIC_SUBNETS | tr ' ' ',')"
fi

# ----- 9. Summary ----------------------------------------------------------

printf "\n\033[1;32m[setup] Done.\033[0m\n\n"
cat <<EOF
Plug these into values.yaml:

  serviceAccount.annotations:
    eks.amazonaws.com/role-arn: $ROLE_ARN

  global.env.DEFAULT_BUCKET: $BUCKET_NAME

Next:
  1. Copy values.example.yaml → values.yaml and fill in:
     - global.env.DOMAIN, APP_BASE_URL, ingress hosts
     - alb.ingress.kubernetes.io/certificate-arn (ACM cert ARN — request separately)
     - global.db.host, database (your RDS endpoint)
  2. helm install oryo ./chart --namespace $NAMESPACE --values values.yaml

EOF
