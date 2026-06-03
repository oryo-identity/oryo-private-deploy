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

# ----- 5. IngressClass for EKS Auto Mode -----------------------------------

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

# ----- 6. Summary ----------------------------------------------------------

cat <<EOF

\033[1;32m[setup] Done.\033[0m

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
