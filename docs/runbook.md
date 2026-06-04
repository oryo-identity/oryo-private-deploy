# Oryo Private Deployment — Runbook

End-to-end bootstrap for a new Oryo deployment. Split into:

- **Part A — Oryo internal:** one-time per customer, run by Oryo to onboard them.
- **Part B — Customer (or sandbox tester):** run in the customer's own AWS account.

Example values throughout: customer account `221759618824`, region `us-east-2`, domain `oryo-pd.click`, cluster `cluster-pd-1`, Oryo prod ECR account `831622638566`. Swap as needed.

---

## Part A — Oryo internal (per customer)

Run these from a machine with SSO access to **Oryo prod** (account `831622638566`).

### A.1. Authenticate to Oryo prod

```bash
aws sso login --profile oryo-prod
aws sts get-caller-identity --profile oryo-prod
# Account must be 831622638566
```

### A.2. Grant the customer's account pull access to Oryo image repos

```bash
cd ~/Work/oryo-private-deploy
./scripts/grant-ecr-pull.sh <customer-account-id> oryo-prod
```

The script attaches a repository policy on each Oryo image repo in `us-east-1` (`dashboard`, `gateway`, `api`, `workers`, `db-init`) granting `BatchGetImage` / `GetDownloadUrlForLayer` etc. to the customer account. Idempotent — re-running with the same account ID is a no-op.

That's it for Oryo side. Hand the customer:
- This repo (`oryo-private-deploy`)
- The chart version / image tag they should install
- This runbook (specifically Part B)

---

## Part B — Customer-side bootstrap

Run in the customer's own AWS account.

### B.0. Tools

Need installed locally:
- `aws` CLI (v2)
- `kubectl`
- `helm` (v3)
- `eksctl` (used by `setup.sh` to create the IRSA role)
- `jq` (used by `setup.sh` for NodePool patching, and by `grant-ecr-pull.sh`)
- `openssl` (system default; used by `setup.sh` to generate secrets)
- `docker` (optional — only for local image verification)

### B.1. AWS SSO

```bash
aws configure sso --profile <your-profile>
# pick the target account + admin role
# default region: us-east-2 (or wherever your cluster lives)

aws sso login --profile <your-profile>
aws sts get-caller-identity --profile <your-profile>
```

### B.2. Register a domain (Route 53)

Console → **Route 53** → Registered domains → Register domains. Cheapest TLD is `.click` (~$3/yr). Registration auto-creates a matching hosted zone. WHOIS privacy protection is on by default. Domain charges go to the AWS account bill.

**Register the domain in the same account as the rest of the deployment** — cross-account hosted zones complicate cert validation.

### B.3. Request an ACM certificate

```bash
DOMAIN=oryo-pd.click

aws acm request-certificate \
  --profile <your-profile> \
  --region <your-region> \
  --domain-name "*.${DOMAIN}" \
  --subject-alternative-names "${DOMAIN}" \
  --validation-method DNS
```

Validate ownership via console:
1. **Certificate Manager** → region selector top-right (must match cluster region) → click the new cert.
2. "Domains" section → **"Create records in Route 53"** button → confirm.
3. Wait 5–10 min; status flips to `ISSUED`.

Poll from CLI:
```bash
aws acm describe-certificate \
  --profile <your-profile> --region <your-region> \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
```

Save the cert ARN — goes into `values.yaml`.

### B.4. EKS cluster

Assume the cluster already exists. Connect:

```bash
aws eks list-clusters --profile <your-profile> --region <your-region>
aws eks update-kubeconfig --profile <your-profile> --region <your-region> --name <cluster-name>
kubectl get nodes
```

**Detect cluster type.** EKS Auto Mode vs classic managed node groups differ significantly. Auto Mode tells:

```bash
kubectl get nodepool 2>/dev/null
# If this returns rows like `general-purpose` / `system` → Auto Mode.
# If "no resources" → classic node groups.
```

This runbook + `setup.sh` are written for **Auto Mode**. For classic node groups you must install the AWS Load Balancer Controller yourself first — out of scope here.

### B.5. Run `setup.sh`

Idempotent. Creates / patches:

1. S3 bucket (object storage)
2. IAM policy + IRSA role + bound k8s ServiceAccount
3. K8s namespace + 5 Secrets (session, db-admin, db-dashboard, db-gateway, db-worker)
4. Target Postgres database (creates `DB_NAME` if missing — workaround for dbInit not handling this)
5. `alb` IngressClass pointing at Auto Mode's built-in controller
6. **Patches the Auto Mode `general-purpose` NodePool to allow `arm64`** (default is amd64-only; Oryo images are arm64)
7. **Tags the cluster VPC's public subnets** with `kubernetes.io/role/elb=1` so the ALB controller can auto-discover them

```bash
cd ~/Work/oryo-private-deploy

cp .env.example .env
$EDITOR .env
# Fill in: AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE,
# BUCKET_NAME (must be globally unique), DB_HOST, DB_NAME, DB_ADMIN_USER, DB_ADMIN_PASSWORD

./scripts/setup.sh
```

Output prints the IRSA role ARN — copy that for the next step.

### B.6. Fill in `values.yaml`

```bash
cp values.example.yaml values.yaml
$EDITOR values.yaml
```

Replace placeholders (search for `TODO`):
- **`global.env.DOMAIN`** + **`APP_BASE_URL`** + **`API_BASE_URL`** — your domain.
- **`global.env.DEFAULT_BUCKET`** — bucket name from `.env`.
- **`global.db.host` / `database`** — your RDS endpoint and database name.
- **`serviceAccount.annotations.eks.amazonaws.com/role-arn`** — IRSA role ARN from `setup.sh`.
- **`alb.ingress.kubernetes.io/certificate-arn`** — ACM cert ARN from B.3 (3 ingresses use it).
- **Ingress hostnames** — `app.<DOMAIN>`, `gateway.<DOMAIN>`, `api.<DOMAIN>`.
- **`dbInit.defaultTenant`** — your org name + owner email.
- **`global.env.ENV_NAME`** — must be one of `local | dev | stage | prod` (Zod enum constraint in the platform). For private deploys use `prod` (or `stage` for a non-production sandbox). Tracked for relaxation in a follow-up task.

### B.7. `helm install`

```bash
helm install oryo ./chart \
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 15m
```

**Timeout matters.** Auto Mode dynamic node provisioning takes 2–5 min per node, plus image pull + container startup. The dbInit pre-install hook adds another minute. 5 min isn't enough; 10–15 min is safe.

The pre-install hook runs the `dbInit` Job: connects to RDS as the admin user, ensures the database exists (creation is in `setup.sh` for now), creates the per-service Postgres roles using the passwords from the k8s Secrets, applies schema and RLS policies, seeds the default tenant.

Watch:
```bash
kubectl -n <NAMESPACE> get pods
kubectl -n <NAMESPACE> logs job/oryo-oryo-platform-db-init --tail=50
```

### B.8. Point DNS at the ALBs

After install, Auto Mode provisions ALBs (~2–3 min). Get the hostnames:

```bash
kubectl -n <NAMESPACE> get ingress
```

The `ADDRESS` column shows hostnames like `k8s-...elb.<region>.amazonaws.com`. **Note:** the chart's `alb.ingress.kubernetes.io/group.name` annotation should merge all 3 ingresses into 1 ALB, but in practice we've observed 3 separate ALBs being created. Each ingress gets its own ALB hostname — that's not broken, just slightly more billing. Worth investigating in a follow-up.

Create CNAMEs in your Route 53 hosted zone:
- `app.<DOMAIN>` → dashboard's ALB hostname
- `gateway.<DOMAIN>` → gateway's ALB hostname
- `api.<DOMAIN>` → api's ALB hostname

Or install [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) to automate this. CNAMEs propagate in 1–5 min.

### B.9. Smoke test

```bash
curl -I https://app.<DOMAIN>/healthcheck
curl -I https://gateway.<DOMAIN>/healthcheck
curl -I https://api.<DOMAIN>/healthcheck
# Expect 200 OK on all three
```

Open `https://app.<DOMAIN>` in a browser. The login flow currently logs the code to dashboard pod logs (no email provider configured by default):

```bash
kubectl -n <NAMESPACE> logs deploy/oryo-oryo-platform-dashboard | grep -i 'login code'
```

(Setting `RESEND_API_KEY` enables real email. Pluggable email provider is a planned improvement — see project tasks.)

---

## Upgrades

```bash
helm upgrade oryo ./chart \
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 15m
```

The `dbInit` hook re-runs on every upgrade (idempotent — schema additions are `IF NOT EXISTS`).

To skip the dbInit hook on upgrades (faster), set `dbInit.enabled: false` in `values.yaml` before running `helm upgrade`.

---

## Gotchas seen so far

### Auth / accounts
- **Wrong AWS account via SSO.** Always run `aws sts get-caller-identity` before any state-changing command. Cert/domain/IAM created in the wrong account = restart in the right one.

### ACM cert
- **Cert stuck in `PENDING_VALIDATION`.** Requesting a cert does NOT validate it. Use the "Create records in Route 53" console button (or create the validation CNAMEs manually with the CLI).

### EKS Auto Mode

EKS Auto Mode shifts a lot of plumbing AWS-side. Most of it Just Works™, but the parts that don't tend to be silent / non-obvious:

- **NodePool defaults to amd64 only.** The `general-purpose` NodePool that ships with Auto Mode only provisions amd64. Oryo's images are arm64 (Graviton, matching prod). Without a patch (now in `setup.sh`), every workload pod stays `Pending` forever with:
  ```
  incompatible requirements, key kubernetes.io/arch, In [arm64] not in [amd64]
  ```
  Diagnose with `kubectl describe pod <pending-pod>` — the FailedScheduling event spells it out.
- **Existing arm64 nodes are tainted `CriticalAddonsOnly:NoSchedule`.** Those belong to the `system` NodePool, reserved for cluster add-ons. They look like usable workload nodes in `kubectl get nodes` — they're not.
- **Manual ALB controller NEVER on Auto Mode.** Don't install the standalone `aws-load-balancer-controller` Helm chart on Auto Mode. It crashes with `ec2imds GetMetadata` timeouts because Auto Mode nodes block IMDS. The chart's IngressClass routes to Auto Mode's built-in controller (`controller: eks.amazonaws.com/alb`) — that's what you want.
- **ALB controller needs subnets tagged for auto-discovery.** Public subnets need `kubernetes.io/role/elb=1`. Without this, Ingresses sit forever with empty `ADDRESS` and events say `Failed build model due to couldn't auto-discover subnets`. `setup.sh` tags these now.
- **`kubectl exec` fails with TLS errors on Auto Mode.** Workaround: use one-shot pods that print to stdout, then read via `kubectl logs`. Don't rely on `kubectl exec -it` for debug.
- **Auto Mode provisioning is slow.** Each new node = 2–5 min from "pod Pending" → "node Ready → pod scheduled → container running". `--wait --timeout 15m` is the safe default.

### Chart / images

- **Chart's arch affinity is *preferred*, not *required*.** Default lets Auto Mode silently provision amd64 nodes even when `global.nodeArchitecture: arm64` is set. Combined with the NodePool issue, pods land on wrong arch → `exec format error`. There's an in-flight chart fix to make it *required*. Until then, `setup.sh`'s NodePool patch is the working unblock.
- **`ENV_NAME` rejected by Zod.** `SharedEnvZ` constrains to `local | dev | stage | prod`. Customer install must pick one of those four, not `sandbox` / `customer-1` / etc. Crashes in <1s with no useful pod logs (Zod throw on module load). Use `prod` (or `stage`). Relaxation tracked.
- **`group.name` annotation didn't merge ALBs.** Expected: 1 ALB serving all 3 ingresses via the `alb.ingress.kubernetes.io/group.name` annotation. Observed: 3 separate ALBs. Functional but slightly more billing. Worth investigating with Auto Mode's controller.

### Database

- **dbInit assumes `DB_DATABASE` already exists.** RDS Postgres ships with only `postgres` + `rdsadmin`. dbInit tries to connect to `DB_NAME` and crashes if not present. `setup.sh` works around this by creating the database via an in-cluster psql pod. Proper fix tracked: dbInit should bootstrap its own database.
- **RDS unreachable from cluster.** dbInit hangs if the RDS security group doesn't allow inbound from the EKS pod CIDR. Fix: ensure the cluster's SG (or workload node SG) is in RDS's inbound allowlist on port 5432.

### Helm

- **`--dry-run` prints NOTES.** Don't mistake dry-run output for a successful install. `helm list -A` is the ground truth.
- **Pre-install hook failure rolls back the release.** When `dbInit` fails, helm cleans up resources and you can't `kubectl logs` after the fact. Either capture logs live, or run with `--no-hooks` to debug the rest, then dbInit separately.

---

## Reference: rebuilding the sandbox from scratch

For Oryo internal — this repo's `values.sandbox.yaml` is the canonical "did it actually work" deployment. To rebuild:

```bash
cd ~/Work/oryo-private-deploy

# 1. .env is already populated for sandbox (gitignored — keep a copy somewhere safe)
./scripts/setup.sh

# 2. Cross-account ECR pull (run from prod, one-time, idempotent)
./scripts/grant-ecr-pull.sh 221759618824 oryo-prod

# 3. Install (use --no-hooks first if you want to validate non-dbInit pods come up clean)
helm install oryo ./chart \
  --namespace oryo-sandbox \
  --values values.sandbox.yaml \
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
