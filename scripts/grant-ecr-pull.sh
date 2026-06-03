#!/usr/bin/env bash
# Grant a consumer AWS account permission to pull Oryo container images from
# Oryo's distribution ECR (account 831622638566, region us-east-1).
#
# Run by Oryo (NOT by the customer) when onboarding a new private deployment.
# Idempotent: re-running with the same consumer ID is a no-op.
#
# Usage:
#   ./scripts/grant-ecr-pull.sh <consumer-account-id> [profile]
#
# Example:
#   ./scripts/grant-ecr-pull.sh 221759618824 oryo-prod

set -euo pipefail

CONSUMER_ACCOUNT_ID="${1:?usage: $0 <consumer-account-id> [profile]}"
PROFILE="${2:-oryo-prod}"
REGION="${REGION:-us-east-1}"

# Repos that make up an Oryo private deployment. Update if more services ship.
REPOS=(
  dashboard
  gateway
  api
  workers
  db-init
)

if ! [[ "$CONSUMER_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: consumer account ID must be 12 digits, got '$CONSUMER_ACCOUNT_ID'" >&2
  exit 1
fi

log() { printf "\033[1;34m[grant-ecr]\033[0m %s\n" "$*"; }

log "Verifying AWS identity (must be Oryo prod 831622638566)..."
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
if [[ "$ACTUAL_ACCOUNT" != "831622638566" ]]; then
  echo "ERROR: profile '$PROFILE' is in account $ACTUAL_ACCOUNT, expected 831622638566 (Oryo prod)" >&2
  exit 1
fi

# A policy statement granting one consumer account pull permission.
# When merging into an existing policy, we deduplicate by Sid.
STATEMENT_SID="AllowAccountPull-${CONSUMER_ACCOUNT_ID}"
STATEMENT_JSON=$(cat <<EOF
{
  "Sid": "$STATEMENT_SID",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::${CONSUMER_ACCOUNT_ID}:root" },
  "Action": [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:DescribeImages",
    "ecr:ListImages"
  ]
}
EOF
)

for repo in "${REPOS[@]}"; do
  log "Repo: $repo"

  if ! aws ecr describe-repositories \
      --profile "$PROFILE" --region "$REGION" \
      --repository-names "$repo" >/dev/null 2>&1; then
    echo "  WARN: repo '$repo' does not exist in $REGION — skipping" >&2
    continue
  fi

  # Fetch existing policy (if any). Empty string means no policy yet.
  EXISTING=$(aws ecr get-repository-policy \
    --profile "$PROFILE" --region "$REGION" \
    --repository-name "$repo" \
    --query 'policyText' --output text 2>/dev/null || true)

  if [[ -z "$EXISTING" || "$EXISTING" == "None" ]]; then
    NEW_POLICY=$(jq -n --argjson stmt "$STATEMENT_JSON" \
      '{Version:"2008-10-17", Statement:[$stmt]}')
  else
    # Merge: drop any existing statement with the same Sid, then append.
    NEW_POLICY=$(jq --argjson stmt "$STATEMENT_JSON" --arg sid "$STATEMENT_SID" '
      .Statement |= ((map(select(.Sid != $sid))) + [$stmt])
    ' <<<"$EXISTING")

    if [[ "$NEW_POLICY" == "$EXISTING" ]]; then
      log "  already granted to ${CONSUMER_ACCOUNT_ID} — no change"
      continue
    fi
  fi

  aws ecr set-repository-policy \
    --profile "$PROFILE" --region "$REGION" \
    --repository-name "$repo" \
    --policy-text "$NEW_POLICY" >/dev/null
  log "  granted pull access to ${CONSUMER_ACCOUNT_ID}"
done

log "Done. Consumer ${CONSUMER_ACCOUNT_ID} can now pull from ${REGION} ECR in 831622638566."
