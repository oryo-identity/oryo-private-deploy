#!/usr/bin/env bash
# Oryo-internal: provision the AWS prerequisites for a private deployment.
#
# This is the MUTATING counterpart to customer/scripts/setup.sh (which only
# verifies). Customers provision their own resources per customer/docs/prereqs.md;
# Oryo uses this to stand up the sandbox, or to provision on a customer's behalf
# when they delegate it.
#
# Every resource here corresponds 1:1 to a section of customer/docs/prereqs.md.
# Idempotent: each step is create-or-tolerate-exists.
#
# Usage:
#   cp ../../customer/.env.example .env  (or point ENV_FILE at one) and fill it
#   ./provision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${AWS_PROFILE:?}"; : "${AWS_REGION:?}"; : "${ACCOUNT_ID:?}"
: "${CLUSTER_NAME:?}"; : "${NAMESPACE:?}"; : "${BUCKET_NAME:?}"
export AWS_PROFILE AWS_REGION
POLICY_NAME="${POLICY_NAME:-OryoWorkloadPolicy}"
ROLE_NAME="${ROLE_NAME:-OryoWorkloadRole}"
SERVICE_ACCOUNT="oryo-platform"   # MUST match values.yaml serviceAccount.name + the IRSA trust policy

log() { printf "\033[1;34m[provision]\033[0m %s\n" "$*"; }

# --- guard: confirm we're in the intended account -------------------------
ACTUAL=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACTUAL" == "$ACCOUNT_ID" ]] || { echo "ERROR: profile is in $ACTUAL, expected $ACCOUNT_ID" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────
# prereqs.md §1 — S3 bucket
#   WHY: object storage for the workers/api (file uploads, sensor artifacts,
#   etc). The chart's global.env.DEFAULT_BUCKET points at it; the IAM policy
#   below scopes pod access to exactly this bucket.
# ──────────────────────────────────────────────────────────────────────────
log "S3 bucket $BUCKET_NAME"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  log "  exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region us-east-1
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  log "  created"
fi

# ──────────────────────────────────────────────────────────────────────────
# prereqs.md §2a — IAM permission policy
#   WHY: pods need S3 access (read/write/list) limited to the bucket above.
#   Least-privilege: only that bucket, only object + list actions.
# ──────────────────────────────────────────────────────────────────────────
log "IAM policy $POLICY_NAME"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "  exists"
else
  TMP=$(mktemp)
  cat > "$TMP" <<EOF
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
  "Resource": ["arn:aws:s3:::${BUCKET_NAME}","arn:aws:s3:::${BUCKET_NAME}/*"]
}]}
EOF
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://$TMP" >/dev/null
  rm "$TMP"; log "  created"
fi

# ──────────────────────────────────────────────────────────────────────────
# prereqs.md §2b — IAM role (IRSA), role-only
#   WHY: pods assume this role via IRSA to use the policy above. --role-only
#   because the HELM CHART creates the k8s ServiceAccount (named oryo-platform)
#   and annotates it with this role's ARN. eksctl wires the OIDC trust policy
#   binding system:serviceaccount:<ns>:oryo-platform → this role.
#   (The old setup.sh let eksctl create the SA too, with a different name than
#   the chart used — a latent IRSA mismatch. --role-only + the fixed name fix it.)
# ──────────────────────────────────────────────────────────────────────────
log "IAM role $ROLE_NAME (IRSA, role-only, SA=$NAMESPACE/$SERVICE_ACCOUNT)"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "  exists"
else
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace "$NAMESPACE" --name "$SERVICE_ACCOUNT" \
    --role-only --role-name "$ROLE_NAME" \
    --attach-policy-arn "$POLICY_ARN" --approve
  log "  created"
fi
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

# ──────────────────────────────────────────────────────────────────────────
# prereqs.md §3 — tag public subnets for ALB discovery
#   WHY: EKS Auto Mode's ALB controller finds where to place internet-facing
#   load balancers by scanning the cluster VPC for subnets tagged
#   kubernetes.io/role/elb=1. Without it, ingresses never get an address
#   ("couldn't auto-discover subnets").
# ──────────────────────────────────────────────────────────────────────────
log "Tag public subnets (kubernetes.io/role/elb=1)"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text)
if [[ -z "$PUBLIC_SUBNETS" ]]; then
  echo "  WARN: no public subnets in $VPC_ID" >&2
else
  # shellcheck disable=SC2086
  aws ec2 create-tags --region "$AWS_REGION" --resources $PUBLIC_SUBNETS --tags Key=kubernetes.io/role/elb,Value=1 >/dev/null
  log "  tagged: $(echo $PUBLIC_SUBNETS | tr ' ' ',')"
fi

# ──────────────────────────────────────────────────────────────────────────
# prereqs.md §4 — allow arm64 in the Auto Mode NodePool
#   WHY: Oryo images are arm64 (Graviton). Auto Mode's default general-purpose
#   NodePool only provisions amd64, so pods stay Pending with an arch
#   mismatch until arm64 is added to its allowed values.
# ──────────────────────────────────────────────────────────────────────────
if kubectl get nodepool general-purpose >/dev/null 2>&1; then
  log "Allow arm64 in general-purpose NodePool"
  CUR=$(kubectl get nodepool general-purpose -o json \
    | jq -r '.spec.template.spec.requirements[] | select(.key=="kubernetes.io/arch") | .values | join(",")')
  if echo "$CUR" | grep -q arm64; then
    log "  already allowed ($CUR)"
  else
    kubectl get nodepool general-purpose -o json \
      | jq '.spec.template.spec.requirements |= map(if .key=="kubernetes.io/arch" then .values=(.values+["arm64"]|unique) else . end)
            | {apiVersion,kind,metadata:{name:.metadata.name},spec:.spec}' \
      | kubectl apply -f - >/dev/null
    log "  patched (arm64 + amd64)"
  fi
else
  log "No Auto Mode NodePool — ensure an arm64 node group exists (classic)."
fi

# ──────────────────────────────────────────────────────────────────────────
# Done — hand off to the customer flow.
# ──────────────────────────────────────────────────────────────────────────
cat <<EOF

[provision] Done. For values.yaml:

  serviceAccount:
    name: $SERVICE_ACCOUNT
    annotations:
      eks.amazonaws.com/role-arn: $ROLE_ARN

  global.env.DEFAULT_BUCKET: $BUCKET_NAME

Next: bootstrap secrets + install via the customer flow:
  cd ../../customer
  ./scripts/setup.sh --bootstrap-secrets    # or create secrets yourself
  helm install oryo ./chart -n $NAMESPACE --create-namespace --values values.yaml --wait --timeout 15m
EOF
