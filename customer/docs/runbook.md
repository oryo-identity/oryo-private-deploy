# Oryo Private Deployment — Runbook

End-to-end bootstrap for installing Oryo in your own AWS account. Targets EKS Auto Mode with arm64 (Graviton) nodes.

---

## Prerequisites — what you bring

These must already exist before you start. The runbook assumes them and won't create them for you.

| Requirement | Notes |
|---|---|
| **AWS account** | With SSO + admin access for the account you'll deploy into. |
| **EKS cluster** | Auto Mode recommended. Same AWS account + region as the rest. arm64 (Graviton) nodes — Auto Mode will provision these automatically once `setup.sh` patches the NodePool. |
| **Postgres database** | RDS recommended. Reachable from the EKS cluster's VPC on port 5432 (security group rule). We don't create or manage the DB instance; you point us at it. The chart will use the default `postgres` database unless you tell it otherwise. |
| **Domain + Route 53 hosted zone** | Registered in Route 53, in the same AWS account. Subdomains for `app.`, `gateway.`, `api.` will be added during install. |
| **ACM certificate** | Wildcard cert for `*.<your-domain>` in the same region as the cluster, in `ISSUED` status. ARN goes into `values.yaml`. |
| **Oryo ECR pull grant** | Oryo grants your AWS account ID pull access to its image registry. Contact your Oryo representative if you haven't been onboarded yet. |

The runbook walks you through creating everything else (S3 bucket, IAM role, IngressClass, k8s secrets, helm install, DNS records).

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

## 2. Run `setup.sh`

Idempotent. Creates / patches:

1. S3 bucket (object storage)
2. IAM policy + IRSA role + bound k8s ServiceAccount
3. K8s namespace + 5 Secrets (session, db-admin, db-dashboard, db-gateway, db-worker)
4. `alb` IngressClass pointing at Auto Mode's built-in controller
5. **Patches the Auto Mode `general-purpose` NodePool to allow `arm64`** (default is amd64-only; Oryo images are arm64)
6. **Tags the cluster VPC's public subnets** with `kubernetes.io/role/elb=1` so the ALB controller can auto-discover them

```bash
cd customer

cp .env.example .env
$EDITOR .env
# Fill in: AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE,
# BUCKET_NAME (must be globally unique), DB_ADMIN_USER, DB_ADMIN_PASSWORD

./scripts/setup.sh
```

Output prints the IRSA role ARN — copy that for the next step.

> **Database note:** `setup.sh` does NOT create the Postgres database. The
> default `postgres` database that ships with RDS works fine — put `postgres`
> in `values.yaml` under `global.db.database`. If you'd rather use a named
> database (e.g. `oryo` or `acme`), create it yourself first via your RDS
> tooling (`CREATE DATABASE oryo;`) and put that name in `values.yaml`.

> **Email note:** `values.example.yaml` enables Resend by default for the
> dashboard login flow. If you set `RESEND_API_KEY` in `.env`, `setup.sh`
> creates the matching k8s secret and login codes get emailed. If you leave
> `RESEND_API_KEY` blank, you MUST also remove the `dashboard.externalSecrets`
> block from `values.yaml`, otherwise the dashboard pod will fail to start
> with a missing-secret error.

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
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 15m
```

**Timeout matters.** Auto Mode dynamic node provisioning takes 2–5 min per node, plus image pull + container startup. The dbInit pre-install hook adds another minute. 5 min isn't enough; 10–15 min is safe.

The pre-install hook runs the `dbInit` Job: connects to RDS as the admin user, creates the per-service Postgres roles using the passwords from the k8s Secrets, applies schema and RLS policies, seeds the default tenant. **The target database must already exist** — use the default `postgres` database or create your own beforehand.

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

The `ADDRESS` column shows hostnames like `k8s-...elb.<region>.amazonaws.com`.

Create CNAMEs in your Route 53 hosted zone:
- `app.<DOMAIN>` → dashboard's ALB hostname
- `gateway.<DOMAIN>` → gateway's ALB hostname
- `api.<DOMAIN>` → api's ALB hostname

Or install [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) to automate this. CNAMEs propagate in 1–5 min.

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
- **Pre-install hook failure rolls back the release.** When `dbInit` fails, helm cleans up resources and you can't `kubectl logs` after the fact. Either capture logs live, or run with `--no-hooks` to debug the rest, then dbInit separately.
