# Building a customer-style prereq state (Oryo internal)

How to set up the AWS-side prerequisites that the customer runbook assumes are already in place: domain + Route 53 hosted zone, ACM cert, EKS cluster, RDS Postgres, VPC connectivity. Once these exist, you can run the customer flow in [customer/docs/runbook.md](../../customer/docs/runbook.md) cold and have it succeed.

Useful for:
- **Standing up Oryo's own private-deploy sandbox** (sandbox account `221759618824`, where we test the customer flow end-to-end).
- **Walking a customer through setup** if they need help getting to the prereq state.
- **Reviewing what a "customer-ready" AWS environment actually requires** before sales conversations.

This is not a customer doc. Customers usually already have most of this (existing AWS account, cluster, RDS, domain). This is the from-scratch path.

> **Defaults below** are the Oryo sandbox values (account `221759618824`, region `us-east-2`, profile `sandbox`, domain `oryo-pd.click`, cluster `cluster-pd-1`). Tweak the `VARS` block at the top of each step for a different environment.

---

## 0. Pre-prep

```bash
export AWS_PROFILE=sandbox
export AWS_REGION=us-east-2
export ACCOUNT_ID=221759618824

aws sts get-caller-identity --query Account --output text
# Output must equal $ACCOUNT_ID
```

You need IAM admin in that account. If you're driving setup for a customer, they need it.

## 1. Register a domain (Route 53)

Console-only step — Route 53 → Registered domains → Register domains.

- Cheapest: `.click` TLD (~$3/yr).
- Registration auto-creates a matching hosted zone in the same account. **Don't manually create the zone before registration** — duplicates cause delegation issues.
- WHOIS privacy is on by default. Domain charges go to the AWS account bill.

**Critical:** register the domain in the same AWS account as everything else. Cross-account hosted zones make ACM validation painful.

If the domain is registered elsewhere (e.g. GoDaddy), point its NS records at a Route 53 hosted zone you create here. Doable but more steps.

## 2. ACM certificate

```bash
# ----- vars (sandbox defaults) -----
export AWS_PROFILE=sandbox
export AWS_REGION=us-east-2
export DOMAIN=oryo-pd.click
# -----------------------------------

# Request the wildcard cert
CERT_ARN=$(aws acm request-certificate \
  --region "$AWS_REGION" \
  --domain-name "*.${DOMAIN}" \
  --subject-alternative-names "${DOMAIN}" \
  --validation-method DNS \
  --query CertificateArn --output text)
echo "$CERT_ARN"
```

Save the ARN — you'll paste it into `values.yaml` later.

**Validate ownership.** Console (easier):
1. **Certificate Manager** → top-right region → click the new cert.
2. "Domains" section → **"Create records in Route 53"** button → confirm.
3. Wait 5–10 min; status flips to `ISSUED`.

Or CLI (no console needed):

```bash
# ----- vars -----
export AWS_PROFILE=sandbox
export AWS_REGION=us-east-2
export DOMAIN=oryo-pd.click
export CERT_ARN=<paste-from-above>
# ----------------

# Fetch the hosted zone ID for the domain
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text)

# Write the validation CNAME into Route 53
aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json \
  | jq '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:.Name,Type:.Type,TTL:60,ResourceRecords:[{Value:.Value}]}}]}' \
  | aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file:///dev/stdin
```

Poll for ISSUED:

```bash
aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.Status'
```

## 3. EKS cluster

```bash
# ----- vars (sandbox defaults) -----
export AWS_PROFILE=sandbox
export AWS_REGION=us-east-2
export CLUSTER_NAME=cluster-pd-1
# -----------------------------------
```

If the cluster already exists (typical customer case), skip to verify. If not, create:

```bash
eksctl create cluster \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --enable-auto-mode \
  --node-private-networking false
```

Auto Mode is what the customer runbook + `setup.sh` assume. Classic node groups are not supported by `setup.sh` today.

Verify:

```bash
aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query 'cluster.{Status:status, VpcId:resourcesVpcConfig.vpcId, ClusterSG:resourcesVpcConfig.clusterSecurityGroupId}'

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl get nodes
kubectl get nodepool   # Auto Mode confirmation — should show `general-purpose` + `system`
```

**Save the VPC ID and cluster security group ID** — you'll need them for step 4.

## 4. RDS Postgres

If the RDS already exists, skip to verify. If not, console RDS → Create database → PostgreSQL. Settings that matter:

- **VPC:** same VPC as the EKS cluster (saved above).
- **Subnet group:** include the same subnets the cluster uses.
- **Public access:** `No` (keep it private).
- **Security group:** add an inbound rule for port 5432 from the **cluster security group** (the `sg-...` from step 3).
- **Engine version:** Postgres 14+ is fine.
- **Database name (initial):** leave blank (default `postgres` ships regardless).
- **Master username / password:** save these — they become `DB_ADMIN_USER` / `DB_ADMIN_PASSWORD` in customer `.env`.

Verify connectivity from inside the cluster (laptops usually can't reach private RDS):

```bash
# ----- vars (sandbox defaults) -----
export RDS_HOST=db-pd-1.cxyccack2h4y.us-east-2.rds.amazonaws.com
export RDS_USER=postgres
export RDS_PASS='<your-master-password>'   # 1Password or customer/.env DB_ADMIN_PASSWORD
# -----------------------------------

kubectl run psql-test --image=postgres:16-alpine --restart=Never --rm -i --command -- \
  sh -c "PGPASSWORD='$RDS_PASS' psql 'host=$RDS_HOST port=5432 dbname=postgres user=$RDS_USER sslmode=require' -c 'SELECT version();'"
```

Should print the Postgres version. If it hangs / times out, the security group isn't allowing the cluster → RDS path.

## 5. Hand off to customer flow

At this point the customer prereqs are all satisfied:

- ✅ AWS account + SSO
- ✅ Domain registered + Route 53 hosted zone
- ✅ ACM cert ISSUED
- ✅ EKS Auto Mode cluster running
- ✅ RDS Postgres reachable from the cluster

ECR pull grant is a separate per-customer step Oryo runs from prod — see [oryo-onboarding.md](oryo-onboarding.md).

Now follow [customer/docs/runbook.md](../../customer/docs/runbook.md) starting at step 0 (Tools) — should run clean end to end.

---

## Sandbox cheat sheet

For the Oryo sandbox specifically (account `221759618824`), the prereqs already exist:

| Resource | Value |
|---|---|
| Domain | `oryo-pd.click` (Route 53 in `221759618824`) |
| Hosted zone | auto-created with the domain |
| EKS cluster | `cluster-pd-1` in `us-east-2`, Auto Mode |
| RDS | `db-pd-1.cxyccack2h4y.us-east-2.rds.amazonaws.com` |
| RDS admin password | in 1Password / `customer/.env` `DB_ADMIN_PASSWORD` |
| Cluster security group | `sg-0a6187cfbf3d3ca47` (already in RDS allowlist) |
| ACM cert | re-request on each teardown; ARN goes into `internal/values.sandbox.yaml` |

For a sandbox rebuild, the only step you usually need from this doc is **step 2 (ACM cert re-request)**. The rest is already provisioned.
