#!/usr/bin/env bash
# Oryo private-deployment preflight.
#
# This script CREATES NOTHING in your AWS account. It verifies that the
# prerequisites from docs/prereqs.md exist and are configured correctly, then
# prints the values you need for values.yaml. If anything is missing it tells
# you exactly what to create.
#
# The one optional exception is in-cluster k8s Secrets: pass --bootstrap-secrets
# to have this script generate + create them (convenience). Without the flag,
# it only verifies they exist — bring your own via ESO / Vault / SealedSecrets
# / manual kubectl if you prefer to manage secrets externally.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   ./scripts/setup.sh                      # verify only
#   ./scripts/setup.sh --bootstrap-secrets  # verify + create the k8s secrets

set -euo pipefail

BOOTSTRAP_SECRETS=false
[[ "${1:-}" == "--bootstrap-secrets" ]] && BOOTSTRAP_SECRETS=true

# ----- Load config ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Copy .env.example → .env." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${AWS_PROFILE:?set in .env}"
: "${AWS_REGION:?set in .env}"
: "${ACCOUNT_ID:?set in .env}"
: "${CLUSTER_NAME:?set in .env}"
: "${NAMESPACE:?set in .env}"
: "${BUCKET_NAME:?set in .env}"
export AWS_PROFILE AWS_REGION
ROLE_NAME="${ROLE_NAME:-OryoWorkloadRole}"
SENSOR_EXECUTABLES_BUCKET="${SENSOR_EXECUTABLES_BUCKET:-binaries-pub-prod-us-east-1-oryo}"

ok()   { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
bad()  { printf "\033[1;31m  ✗\033[0m %s\n" "$*"; FAILED=1; }
warn() { printf "\033[1;33m  !\033[0m %s\n" "$*"; }
log()  { printf "\033[1;34m[preflight]\033[0m %s\n" "$*"; }
FAILED=0

# ----- 0. Identity + cluster connection ------------------------------------

log "Account + cluster"
ACTUAL=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "?")
[[ "$ACTUAL" == "$ACCOUNT_ID" ]] && ok "AWS account $ACCOUNT_ID" \
  || bad "AWS_PROFILE=$AWS_PROFILE is in account $ACTUAL, expected $ACCOUNT_ID"
kubectl config current-context >/dev/null 2>&1 && ok "kubectl context: $(kubectl config current-context)" \
  || bad "kubectl not configured — run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"

# ----- 1. S3 bucket --------------------------------------------------------

log "S3 object-storage bucket"
if aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
  ok "bucket $BUCKET_NAME exists"
else
  bad "bucket $BUCKET_NAME not found — see docs/prereqs.md §1"
fi

# ----- 2. IAM role (IRSA) --------------------------------------------------

log "IAM workload role"
if ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null); then
  ok "role $ROLE_NAME exists ($ROLE_ARN)"
else
  ROLE_ARN=""
  bad "role $ROLE_NAME not found — see docs/prereqs.md §2"
fi

# ----- 3. Public subnets tagged for ALB discovery --------------------------

log "ALB subnet tags"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
if [[ -n "$VPC_ID" ]]; then
  TAGGED=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
  [[ -n "$TAGGED" ]] && ok "public subnets tagged kubernetes.io/role/elb=1" \
    || bad "no subnets tagged kubernetes.io/role/elb=1 in $VPC_ID — see docs/prereqs.md §3"
else
  bad "could not resolve cluster VPC"
fi

# ----- 4. NodePool arm64 (Auto Mode) ---------------------------------------

log "Node architecture (arm64)"
if kubectl get nodepool >/dev/null 2>&1; then
  # Need a NodePool that allows arm64 AND is schedulable by workloads (no
  # NoSchedule taint — the built-in `system` pool allows arm64 but is tainted
  # CriticalAddonsOnly, so it doesn't count). A dedicated arm64 NodePool is
  # durable; patching general-purpose isn't (Auto Mode reverts it).
  ARM_POOL=$(kubectl get nodepool -o json 2>/dev/null | jq -r '
    .items[]
    | select([.spec.template.spec.requirements[] | select(.key=="kubernetes.io/arch") | .values[]] | index("arm64"))
    | select(((.spec.template.spec.taints // []) | map(select(.effect=="NoSchedule")) | length) == 0)
    | .metadata.name' | head -1)
  [[ -n "$ARM_POOL" ]] && ok "schedulable arm64 NodePool: '$ARM_POOL'" \
    || bad "no schedulable arm64 NodePool — see docs/prereqs.md §4 (create a dedicated arm64 NodePool)"
else
  warn "no Auto Mode NodePools (classic node groups) — ensure an arm64 node group exists"
fi

# ----- 5. K8s secrets ------------------------------------------------------

REQUIRED_SECRETS=(oryo-session-secret oryo-db-admin oryo-db-dashboard oryo-db-gateway oryo-db-worker)

if [[ "$BOOTSTRAP_SECRETS" == true ]]; then
  log "Bootstrapping k8s secrets (--bootstrap-secrets)"
  : "${DB_ADMIN_USER:?set in .env (needed to create oryo-db-admin)}"
  : "${DB_ADMIN_PASSWORD:?set in .env (needed to create oryo-db-admin)}"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  mk() { local n="$1"; shift
    kubectl -n "$NAMESPACE" get secret "$n" >/dev/null 2>&1 && ok "$n exists" \
      || { kubectl -n "$NAMESPACE" create secret generic "$n" "$@" >/dev/null; ok "$n created"; }; }
  mk oryo-session-secret --from-literal=value="$(openssl rand -hex 32)"
  mk oryo-db-admin --from-literal=username="$DB_ADMIN_USER" --from-literal=password="$DB_ADMIN_PASSWORD"
  for r in dashboard gateway worker; do
    mk "oryo-db-$r" --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
  done
  [[ -n "${RESEND_API_KEY:-}" ]] && mk oryo-resend-api-key --from-literal=value="$RESEND_API_KEY"
else
  log "K8s secrets (verify; pass --bootstrap-secrets to generate)"
  for s in "${REQUIRED_SECRETS[@]}"; do
    kubectl -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1 && ok "$s exists" \
      || bad "secret $s missing in namespace $NAMESPACE — create it, or re-run with --bootstrap-secrets"
  done
fi

# ----- Summary -------------------------------------------------------------

echo
if [[ "$FAILED" -ne 0 ]]; then
  printf "\033[1;31m[preflight] Not ready.\033[0m Fix the ✗ items above (see docs/prereqs.md), then re-run.\n"
  exit 1
fi

printf "\033[1;32m[preflight] All checks passed.\033[0m\n\n"
cat <<EOF
Plug these into values.yaml:

  serviceAccount:
    name: oryo-platform
    annotations:
      eks.amazonaws.com/role-arn: $ROLE_ARN

  global.env.DEFAULT_BUCKET: $BUCKET_NAME
  api.env.SENSOR_EXECUTABLES_BUCKET: $SENSOR_EXECUTABLES_BUCKET

Then fill the rest (domain, RDS host, cert ARN, ingress hosts, default tenant)
and install:

  cp values.example.yaml values.yaml && \$EDITOR values.yaml
  helm install oryo ./chart --namespace $NAMESPACE --create-namespace --values values.yaml --wait --timeout 15m

EOF
