# Oryo Private Deployment — Runbook

End-to-end bootstrap for installing Oryo in your own AWS account. Targets EKS Auto Mode with arm64 (Graviton) nodes.

---

## Prerequisites — what you bring

These must already exist before you start. **The install kit creates nothing in your AWS account** — you provision these, `setup.sh` verifies them. The AWS resources (S3 bucket, IAM role, subnet tags, NodePool arm64, database) have exact specs in **[prereqs.md](prereqs.md)**.

| Requirement | Notes |
|---|---|
| **AWS account** | With SSO + admin access for the account you'll deploy into. |
| **EKS cluster** | Auto Mode recommended. Same AWS account + region as the rest. Must be able to provision **arm64 (Graviton)** nodes — see [prereqs.md §4](prereqs.md). |
| **S3 bucket, IAM role, subnet tags** | You create these — [prereqs.md §1–3](prereqs.md). `setup.sh` verifies them. |
| **Postgres database** | RDS recommended. Reachable from the cluster VPC on 5432. The target DB must exist (default `postgres` works) — [prereqs.md §5](prereqs.md). |
| **Domain, Route 53 zone, ACM cert** | Route 53 hosted zone for your domain in the same AWS account; wildcard ACM cert for `*.<your-domain>` in the cluster's region, `ISSUED` — [prereqs.md §6](prereqs.md). |
| **Oryo ECR pull grant** | Oryo grants your AWS account ID pull access to its image registry. Contact your Oryo representative if you haven't been onboarded yet. |

`setup.sh` then verifies all of the above and (optionally) bootstraps the in-cluster k8s secrets; `helm install` does the rest.

---

## 0. Tools

Install locally:
- `aws` CLI (v2)
- `kubectl`
- `helm` (v3)
- `eksctl` (used by `setup.sh` to create the IRSA role)
- `jq` (used by `setup.sh` for NodePool patching)
- `openssl` (system default; used by `setup.sh` to generate secrets)
- `docker` (optional — only for local image verification)

## 1. Connect

```bash
# Authenticate to AWS
aws configure sso --profile <your-profile>   # one-time; pick the target account + admin role
aws sso login --profile <your-profile>
aws sts get-caller-identity --profile <your-profile>

# Wire kubectl to your EKS cluster
aws eks list-clusters --profile <your-profile> --region <your-region>
aws eks update-kubeconfig --profile <your-profile> --region <your-region> --name <cluster-name>
kubectl get nodes
```

Sanity-check the cluster is **EKS Auto Mode**:

```bash
kubectl get nodepool 2>/dev/null
# If this returns rows like `general-purpose` / `system` → Auto Mode. ✓
# If "no resources" → classic node groups (not currently supported by this runbook).
```

## 2. Provision prerequisites, then run the preflight

The install kit **creates nothing in your AWS account.** First create the prerequisites yourself per **[docs/prereqs.md](prereqs.md)** (S3 bucket, IAM role, subnet tags, NodePool arm64, Postgres database) — using the console, CLI, or your own Terraform.

Then run `setup.sh`, which **verifies** everything exists and prints the values you need:

```bash
cd customer
cp .env.example .env
$EDITOR .env          # AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE, BUCKET_NAME

./scripts/setup.sh    # preflight — checks bucket, IAM role, subnet tags, arm64, secrets
```

It prints a ✓/✗ for each check; if anything's missing it points you at the right section of `prereqs.md`. Once all green, it prints the role ARN + bucket name for `values.yaml`.

### K8s secrets

The chart needs these secrets in your namespace: `oryo-session-secret`, `oryo-db-admin`, `oryo-db-dashboard`, `oryo-db-gateway`, `oryo-db-worker` (+ optional `oryo-resend-api-key`). Two ways:

- **Bring your own** (ESO / Vault / SealedSecrets / manual `kubectl`) — `setup.sh` verifies they exist.
- **Let the script generate them** — fill `DB_ADMIN_USER` / `DB_ADMIN_PASSWORD` (and optionally `RESEND_API_KEY`) in `.env`, then:
  ```bash
  ./scripts/setup.sh --bootstrap-secrets
  ```
  This generates the random ones (session + per-service DB passwords) and creates `oryo-db-admin` from your `.env`. Re-running is idempotent.

> **Database note:** the target Postgres database must already exist (default `postgres` works, or create your own and name it in `values.yaml` → `global.db.database`). dbInit creates the per-service roles + schema, not the database itself.

> **Email note:** `values.example.yaml` enables Resend by default. If you don't set up the `oryo-resend-api-key` secret, remove the `dashboard.externalSecrets` block from `values.yaml`, or the dashboard pod won't start.

## 3. Fill in `values.yaml`

```bash
cp values.example.yaml values.yaml
$EDITOR values.yaml
```

Replace placeholders (search for `TODO`):
- **`global.env.DOMAIN`** + **`APP_BASE_URL`** + **`API_BASE_URL`** — your domain.
- **`global.env.DEFAULT_BUCKET`** — bucket name from `.env`.
- **`global.db.host` / `database`** — your RDS endpoint and database name.
- **`serviceAccount.annotations.eks.amazonaws.com/role-arn`** — IRSA role ARN from `setup.sh`.
- **`alb.ingress.kubernetes.io/certificate-arn`** — ACM cert ARN (from prereqs; 3 ingresses use it).
- **Ingress hostnames** — `app.<DOMAIN>`, `gateway.<DOMAIN>`, `api.<DOMAIN>`.
- **`dbInit.defaultTenant`** — your org name + owner email.
- **`global.env.ENV_NAME`** — must be one of `local | dev | stage | prod` (Zod enum constraint). For production deploys use `prod`.

## 4. `helm install`

```bash
helm install oryo ./chart \
  --namespace <NAMESPACE> --create-namespace \
  --values values.yaml \
  --wait --timeout 15m
```

> If you bootstrapped secrets with `setup.sh --bootstrap-secrets`, the namespace already exists — `--create-namespace` is a harmless no-op.

**Timeout matters.** Auto Mode dynamic node provisioning takes 2–5 min per node, plus image pull + container startup. The dbInit hook adds another minute. 5 min isn't enough; 10–15 min is safe.

The `dbInit` hook (pre-install + pre-upgrade) connects to RDS as the admin user, creates the per-service Postgres roles using the passwords from the k8s Secrets, applies schema and RLS policies, seeds global rules, seeds the default tenant. Everything is idempotent, so it runs on every install and upgrade. **The target database must already exist** — use the default `postgres` database or create your own beforehand.

Watch:
```bash
kubectl -n <NAMESPACE> get pods
kubectl -n <NAMESPACE> logs job/oryo-oryo-platform-db-init --tail=50
```

## 5. Point DNS at the ALBs

After install, Auto Mode provisions ALBs (~2–3 min). Get the hostnames:

```bash
kubectl -n <NAMESPACE> get ingress
```

The `ADDRESS` column shows hostnames like `k8s-...elb.<region>.amazonaws.com`. The chart's `alb.ingress.kubernetes.io/group.name` annotation is intended to merge all 3 ingresses into 1 ALB, but Auto Mode currently creates 3 separate ALBs — that's functional, just slightly more billing.

You need 3 CNAMEs in your Route 53 hosted zone pointing each subdomain at its ALB:
- `app.<DOMAIN>` → dashboard's ALB hostname
- `gateway.<DOMAIN>` → gateway's ALB hostname
- `api.<DOMAIN>` → api's ALB hostname

### CLI (recommended)

```bash
# ----- vars -----
DOMAIN=<your-domain>
NAMESPACE=<your-namespace>
# ----------------

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --query 'HostedZones[0].Id' --output text)
APP_ALB=$(kubectl -n "$NAMESPACE" get ingress oryo-oryo-platform-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
GW_ALB=$(kubectl  -n "$NAMESPACE" get ingress oryo-oryo-platform-gateway   -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
API_ALB=$(kubectl -n "$NAMESPACE" get ingress oryo-oryo-platform-api       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

cat > /tmp/dns.json <<EOF
{"Changes":[
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"app.$DOMAIN","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$APP_ALB"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"gateway.$DOMAIN","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$GW_ALB"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"api.$DOMAIN","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"$API_ALB"}]}}
]}
EOF

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch file:///tmp/dns.json
```

`UPSERT` = create-or-replace, safe to re-run if you tweak something.

### Console alternative

Route 53 → Hosted zones → your zone → **Create record** three times:
- Record name: `app` / `gateway` / `api` (just the subdomain)
- Record type: `CNAME`
- Value: paste the corresponding ALB hostname from `kubectl get ingress`
- TTL: 60

### Automatic alternative

Install [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) once; it watches Ingresses and writes Route 53 records automatically. Worth it if you redeploy a lot.

CNAMEs propagate in 1–5 min after creation.

## 6. Smoke test

```bash
curl -I https://app.<DOMAIN>/healthcheck
curl -I https://gateway.<DOMAIN>/healthcheck
curl -I https://api.<DOMAIN>/healthcheck
# Expect 200 OK on all three
```

Open `https://app.<DOMAIN>` in a browser to access the dashboard.

> **Login email:** if you set `RESEND_API_KEY` in `.env` AND uncommented the `dashboard.externalSecrets.RESEND_API_KEY` block in `values.yaml`, login codes are emailed via Resend. Otherwise codes are generated but never delivered — you'll have to SQL the `login_events` table to read them. SMTP / SES support is in flight.

---

## 7. Install a sensor (end-to-end verification)

The real proof a deployment works: install a sensor on a device and confirm it intercepts AI traffic using the global rules seeded at install.

1. In the dashboard: **Settings → Installation**. Copy the generated one-liner for your OS. It already includes `SENSOR_CONFIG_URL=https://api.<DOMAIN>/v1/sensor/config` pointing at *your* deployment, plus a registration token.
2. Run it on the device. Expected output includes a config fetch like:
   ```
   Configuration fetched successfully  watch_domains=19  route_rules=37  message_rules=4
   ```
   Non-zero counts = your seeded global rules reached the sensor.
3. **Trust the CA** (the install will tell you if it isn't trusted). Download the CA from **Settings → Installation → Download CA**, then on macOS:
   ```bash
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/oryo-ca.pem
   ```
   Fully quit + reopen the browser afterward.
4. Visit a watched site (e.g. `chatgpt.com`). It should load with **no TLS error** — the sensor's leaf cert chains to the now-trusted CA.

### Sensor / CA gotchas — read this, it's where time gets lost

- **The CA is per-tenant, not per-domain.** `CN=Oryo Sensor Root CA, OU=<tenantId>`. Switching domains is irrelevant; the OU (tenant) is what matters.
- **The registration token and the CA download MUST be from the same tenant.** If you download the CA while viewing tenant A but install with a token minted under tenant B, the sensor presents leaves signed by B's CA while you trusted A's → `NET::ERR_CERT_AUTHORITY_INVALID`. Confirm they match:
  ```bash
  # CA the sensor actually uses (token from config.json):
  TOKEN=$(sudo python3 -c "import json;print(json.load(open('/Library/Application Support/Oryo/config.json'))['registration']['resource_token'])")
  curl -fsS -H "Authorization: Bearer $TOKEN" https://api.<DOMAIN>/v1/sensor/ca | openssl x509 -noout -subject
  # The CA you trusted:
  openssl x509 -in ~/Downloads/oryo-ca.pem -noout -subject
  ```
  The `OU=` must match. If not, trust the one the sensor uses (the curl output above) or re-mint the token from the right tenant.
- **`security verify-cert` passing ≠ the sensor accepting it.** They can disagree if the sensor fetches a different cert (different tenant). Compare the actual SHA-256, not just "is some Oryo CA trusted."
- **Re-deploys mint a new CA.** A full teardown/rebuild creates a new tenant + new root CA. Any CA you trusted before is now stale — re-download.
- **macOS: imported ≠ trusted.** Double-clicking adds to Keychain without a trust setting. Use `add-trusted-cert -r trustRoot` (as above), and restart the browser — it snapshots the trust store at launch.
- **Firefox uses its own trust store**, not the OS one — import the CA in Firefox settings separately.

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

## Gotchas

### Auth / accounts
- **Wrong AWS account via SSO.** Always run `aws sts get-caller-identity` before any state-changing command. Cert/domain/IAM created in the wrong account = restart in the right one.

### ACM cert
- **Cert stuck in `PENDING_VALIDATION`.** Requesting a cert does NOT validate it. Use the "Create records in Route 53" console button (or create the validation CNAMEs manually with the CLI).

### EKS Auto Mode

EKS Auto Mode shifts a lot of plumbing AWS-side. Most of it Just Works™, but the parts that don't tend to be silent / non-obvious:

- **NodePool defaults to amd64 only.** The `general-purpose` NodePool that ships with Auto Mode only provisions amd64. Oryo's images are arm64. Without a patch (now in `setup.sh`), every workload pod stays `Pending` forever with:
  ```
  incompatible requirements, key kubernetes.io/arch, In [arm64] not in [amd64]
  ```
  Diagnose with `kubectl describe pod <pending-pod>` — the FailedScheduling event spells it out.
- **Existing arm64 nodes are tainted `CriticalAddonsOnly:NoSchedule`.** Those belong to the `system` NodePool, reserved for cluster add-ons. They look like usable workload nodes in `kubectl get nodes` — they're not.
- **Manual ALB controller NEVER on Auto Mode.** Don't install the standalone `aws-load-balancer-controller` Helm chart on Auto Mode. It crashes with `ec2imds GetMetadata` timeouts. The chart's IngressClass routes to Auto Mode's built-in controller (`controller: eks.amazonaws.com/alb`) — that's what you want.
- **ALB controller needs subnets tagged for auto-discovery.** Public subnets need `kubernetes.io/role/elb=1`. Without this, Ingresses sit forever with empty `ADDRESS` and events say `Failed build model due to couldn't auto-discover subnets`. `setup.sh` tags these now.
- **Auto Mode provisioning is slow.** Each new node = 2–5 min from "pod Pending" → "node Ready → pod scheduled → container running". `--wait --timeout 15m` is the safe default.
- **`group.name` ingress annotation may not merge into a single ALB.** The chart's `alb.ingress.kubernetes.io/group.name: oryo` annotation is intended to share one ALB across all 3 ingresses. With Auto Mode's built-in controller we've observed 3 separate ALBs. Functional but slightly more billing.

### Database

- **RDS unreachable from cluster.** dbInit hangs if the RDS security group doesn't allow inbound from the EKS pod CIDR. Fix: ensure the cluster's SG (or workload node SG) is in RDS's inbound allowlist on port 5432.

### Helm

- **`--dry-run` prints NOTES.** Don't mistake dry-run output for a successful install. `helm list -A` is the ground truth.
- **dbInit hook failure fails the install/upgrade.** When `dbInit` fails, helm rolls back and you can't `kubectl logs` after the fact (the hook job is cleaned up). Either capture logs live, or run with `--no-hooks` to debug the rest, then run dbInit separately.
