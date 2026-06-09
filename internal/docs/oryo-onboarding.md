# Onboarding a New Private-Deploy Customer (Oryo Internal)

What Oryo does, once, when a new customer signs up. After this, the customer follows [customer/docs/runbook.md](../../customer/docs/runbook.md) themselves.

## 1. Authenticate to Oryo prod

```bash
aws sso login --profile oryo-prod
aws sts get-caller-identity --profile oryo-prod
# Account must be 831622638566
```

## 2. Grant the customer's AWS account pull access to Oryo image repos

```bash
cd ~/Work/oryo-private-deploy
./internal/scripts/grant-ecr-pull.sh <customer-account-id> oryo-prod
```

The script attaches a repository policy on each Oryo image repo in `us-east-1` (`dashboard`, `gateway`, `api`, `workers`, `db-init`) granting `BatchGetImage` / `GetDownloadUrlForLayer` etc. to the customer account. Idempotent — re-running with the same account ID is a no-op.

## 3. Hand the customer:

- This repo's `customer/` directory (clone link, tarball, OR once OCI publishing exists: the `oci://...` chart URL + a tarball with `setup.sh` + docs)
- The chart version / image tag they should install (e.g. `v1.2.3` matching the current `oryo-platform` release)
- [customer/docs/runbook.md](../../customer/docs/runbook.md)
- Their kickoff support channel / email

That's it for onboarding. The customer drives the rest in their own account.

## Offboarding a customer

If a customer cancels, their account is compromised, or they're no longer entitled to pulls, run the same script with `--revoke`:

```bash
cd ~/Work/oryo-private-deploy
./internal/scripts/grant-ecr-pull.sh --revoke <customer-account-id> oryo-prod
```

The script drops the per-account statement from each Oryo image repo's repository policy. If their grant was the last statement on a repo, the policy is removed entirely. Idempotent — re-running is a no-op.

---

## Reference: a complete worked deployment

A full deployment of `app.oryo-pd.click` in a dedicated AWS account, end to end. Use it as a concrete example of the customer flow with every value filled in.

```bash
# 0. Make sure your local sandbox-side SSO + kubectl are configured
aws sso login --profile sandbox
aws eks update-kubeconfig --profile sandbox --region us-east-2 --name cluster-pd-1

# 1. From the customer/ flow — sandbox uses customer/scripts/setup.sh
#    .env at customer/.env is already populated with sandbox values (gitignored).
cd customer
./scripts/setup.sh

# 2. Cross-account ECR pull — run from Oryo prod, one-time, idempotent
./../internal/scripts/grant-ecr-pull.sh 221759618824 oryo-prod

# 3. Install with the sandbox values file from internal/
helm install oryo ./chart \
  --namespace oryo-sandbox \
  --values ../internal/values.sandbox.yaml \
  --wait --timeout 15m

# 4. After ALBs provision (~2-3 min), create the 3 CNAMEs
ZONE_ID=$(aws route53 list-hosted-zones-by-name --profile sandbox --dns-name oryo-pd.click --query 'HostedZones[0].Id' --output text)
APP_ALB=$(kubectl -n oryo-sandbox get ingress oryo-oryo-platform-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
GW_ALB=$(kubectl -n oryo-sandbox get ingress oryo-oryo-platform-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
API_ALB=$(kubectl -n oryo-sandbox get ingress oryo-oryo-platform-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

cat > /tmp/dns.json <<EOF
{"Changes":[
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"app.oryo-pd.click","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$APP_ALB"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"gateway.oryo-pd.click","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$GW_ALB"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"api.oryo-pd.click","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$API_ALB"}]}}
]}
EOF
aws route53 change-resource-record-sets --profile sandbox --hosted-zone-id "$ZONE_ID" --change-batch file:///tmp/dns.json

# 5. Smoke test
curl -I https://app.oryo-pd.click/healthcheck
curl -I https://gateway.oryo-pd.click/healthcheck
curl -I https://api.oryo-pd.click/healthcheck
```

The grant-ECR-pull step (#2) only needs to run once per consumer account (idempotent). Future re-installs skip it.

## Related

- [customer/docs/runbook.md](../../customer/docs/runbook.md) — the customer install flow
- [internal/docs/prereq-setup.md](prereq-setup.md) — building the prerequisite AWS infrastructure from scratch
