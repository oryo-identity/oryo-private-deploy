# Oryo Private Deployment — Runbook

End-to-end bootstrap for installing Oryo in your own AWS account. Targets EKS Auto Mode with arm64 (Graviton) nodes.

---

## Prerequisites — what you bring

These must already exist before you start. **The install kit creates nothing in your AWS account** — you provision these, `setup.sh` verifies them. The AWS resources (S3 bucket, IAM role, subnet tags, NodePool arm64, database) have exact specs in **[customer/docs/prereqs.md](prereqs.md)**.

| Requirement | Notes |
|---|---|
| **AWS account** | With SSO + admin access for the account you'll deploy into. |
| **EKS cluster** | Auto Mode recommended. Same AWS account + region as the rest. Must be able to provision **arm64 (Graviton)** nodes — see [customer/docs/prereqs.md §4](prereqs.md). |
| **S3 bucket, IAM role, subnet tags** | You create these — [customer/docs/prereqs.md §1–3](prereqs.md). `setup.sh` verifies them. |
| **Bedrock model access** | Per-region opt-in for Claude 3 Haiku + Nova Micro — [customer/docs/prereqs.md §5](prereqs.md). Optional in the sense the install still succeeds without it, but auto-classification, active discovery, and the DLP policy go dark — see [Bedrock-dependent features](#bedrock-dependent-features). |
| **Postgres database** | RDS recommended. Reachable from the cluster VPC on 5432. The target DB must exist (default `postgres` works) — [customer/docs/prereqs.md §6](prereqs.md). |
| **Domain, Route 53 zone, ACM cert** | Route 53 hosted zone for your domain in the same AWS account; wildcard ACM cert for `*.<your-domain>` in the cluster's region, `ISSUED` — [customer/docs/prereqs.md §7](prereqs.md). |
| **Oryo ECR pull grant** | Oryo grants your AWS account ID pull access to its image registry. Contact your Oryo rep if your AWS account has not been provisioned access to our ECR images. |

`setup.sh` then verifies all of the above and (optionally) bootstraps the in-cluster k8s secrets; `helm install` does the rest.

---

## 0. Tools

These tools need to be installed locally to successfully go through the full flow of this runbook:

- `aws` CLI (v2) — auth + every AWS-side operation
- `kubectl` — talk to your EKS cluster
- `helm` (v3) — install + upgrade the chart
- `eksctl` — only needed for the eksctl-path IRSA setup in [customer/docs/prereqs.md §2b](prereqs.md) (skip if you create the role manually)
- `jq` — used by `setup.sh` to inspect Auto Mode NodePools during preflight
- `openssl` — used by `setup.sh --bootstrap-secrets` to generate session + role passwords (system default works on macOS/Linux)
- `docker` (optional) — only for local image verification

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

The install kit **creates nothing in your AWS account.** First create the prerequisites yourself per **[customer/docs/prereqs.md](prereqs.md)** (S3 bucket, IAM role, subnet tags, NodePool arm64, Postgres database) — using the console, CLI, or your own Terraform.

Then run `setup.sh`, which **verifies** everything exists and prints the values you need:

```bash
cd customer
cp .env.example .env
$EDITOR .env          # AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE, BUCKET_NAME

./scripts/setup.sh    # preflight — checks bucket, IAM role, subnet tags, arm64, secrets
```

It prints a ✓/✗ for each check; if anything's missing it points you at the right section of `prereqs.md`. Once all green, it prints the role ARN + bucket name for `values.yaml`.

### K8s secrets

The chart needs these secrets in your namespace: `oryo-session-secret`, `oryo-db-admin`, `oryo-db-dashboard`, `oryo-db-gateway`, `oryo-db-worker`, `oryo-resend-api-key`. Two ways:

- **Bring your own** (ESO / Vault / SealedSecrets / manual `kubectl`) — `setup.sh` verifies they exist.
- **Let the script generate them** — fill `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD`, and `RESEND_API_KEY` in `.env`, then:
  ```bash
  ./scripts/setup.sh --bootstrap-secrets
  ```
  This generates the random ones (session + per-service DB passwords) and creates `oryo-db-admin` from your `.env`. Re-running is idempotent.

> **Database note:** the target Postgres database must already exist (default `postgres` works, or create your own and name it in `values.yaml` → `global.db.database`). dbInit creates the per-service roles + schema, not the database itself.

> **Email note:** `RESEND_API_KEY` is required — the dashboard emails login codes via Resend (without it, users can't sign in). Use your own Resend API key (https://resend.com) or ask the Oryo team to provide one for your install.

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
- **`global.env.ENV_NAME`** — must be one of `local | dev | stage | prod` (Zod enum). **For now, set this to `stage`** for all private-deploy installs while the offering is still being hardened — that way private-deploy traffic is distinguishable from Oryo's own `prod` and we can roll back/adjust behavior per environment without disrupting customers. We'll graduate the recommendation to `prod` once the kit is GA.

## 4. `helm install`

```bash
helm install oryo ./chart \
  --namespace <NAMESPACE> --create-namespace \
  --values values.yaml \
  --wait --timeout 10m
```

> If you bootstrapped secrets with `setup.sh --bootstrap-secrets`, the namespace already exists — `--create-namespace` is a harmless no-op.

**Timeout matters.** First install on a cold cluster pulls images, provisions new arm64 nodes, runs the dbInit hook, then waits for all pods to become Ready — a single end-to-end pass that can take a few minutes. 10 minutes is usually plenty of headroom; bump it higher if your cluster is provisioning capacity from scratch.

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

> **Login email:** login codes are emailed via Resend using `RESEND_API_KEY` (required, set in `.env`; the chart wires the corresponding `oryo-resend-api-key` secret into the dashboard pod). SMTP / SES support is in flight.

---

## 7. Install a sensor (end-to-end verification)

The real proof a deployment works: install a sensor and confirm it intercepts AI traffic using the global rules seeded at install.

Detailed instructions — registration token, install one-liner, CA download — live in the dashboard at **Settings → Installation**. This section is the high-level shape; follow the dashboard for the actual commands.

### MDM fleet rollout (Intune / JAMF / etc.)

1. **Push the Oryo CA** from **Settings → Installation → Download CA** as a trusted root certificate via your MDM's standard certificate-distribution profile.
2. **Push the install one-liner** (also from **Settings → Installation**) via your MDM's run-script policy.
3. **Confirm** — the dashboard's Devices page populates as sensors register.

### Manual testing (one device)

Download the CA from **Settings → Installation → Download CA**, add it to your system's trust store, then run the install one-liner from the same page. Visit a watched site (e.g. `chatgpt.com`) — should load with no TLS error and show up in the dashboard within a few seconds.

> **NOTE:** Each tenant has its own root CA. If you tear down and reinstall the platform, the CA regenerates — re-download and re-trust before retesting.

---

## Upgrades

```bash
helm upgrade oryo ./chart \
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 10m
```

The `dbInit` hook re-runs on every upgrade (idempotent — schema additions are `IF NOT EXISTS`).

To skip the dbInit hook on upgrades (faster), set `dbInit.enabled: false` in `values.yaml` before running `helm upgrade`.

---

## Secret rotation

The chart consumes 6 k8s Secrets (`oryo-session-secret`, `oryo-db-admin`, `oryo-db-{dashboard,gateway,worker}`, `oryo-resend-api-key`). Rotating them in production has different choreography depending on which one — these are the Oryo-specific gotchas. Coordinate with your secrets store (Vault, AWS Secrets Manager, ESO, etc.) for the actual key delivery; the dance below is what the chart expects.

### `oryo-session-secret`

Rotating it **logs every signed-in user out**. The dashboard verifies incoming cookies with the current key; cookies signed with the old key fail HMAC verification and the user gets bounced to login.

Procedure:
1. Update the Secret with the new value.
2. Restart dashboard pods (`kubectl rollout restart deploy/oryo-oryo-platform-dashboard`).

No multi-key / overlap window is supported. If user-facing downtime matters, pick a low-traffic window.

### Per-service DB role passwords (`oryo-db-{dashboard,gateway,worker}`)

The chart's `dbInit` hook **does not** re-issue `ALTER ROLE … WITH PASSWORD` on existing roles — re-doing it on every helm upgrade churns the Postgres catalog for no benefit when the k8s Secret is stable, so password rotation is treated as a separate explicit operation. That means rotation requires syncing the Postgres role's password with the new k8s Secret yourself, in this order:

1. Generate the new password.
2. `ALTER ROLE "oryo-<service>" WITH PASSWORD '<new>'` against RDS (use a debug pod that mounts `oryo-db-admin`, see "Ad-hoc DB access" below).
3. Update the k8s Secret with the same new value.
4. Restart the affected service pods.

If you do step 3 before step 2, the new pods crashloop on `28P01 invalid_password` until step 2 lands. If you do step 2 before step 4, the old pods (still using the old password) crashloop on `28P01` until they restart. Either ordering works — just don't leave a gap between them.

### `oryo-db-admin` (RDS master)

Used only by the `dbInit` hook during `helm install` / `helm upgrade` — long-running pods don't mount it.

Procedure:
1. Rotate the password on the RDS instance (`aws rds modify-db-instance --master-user-password`).
2. Update the k8s Secret.
3. Next `helm upgrade` picks it up. (You don't need to bounce anything.)

If the rotation happens **between** upgrades, no pod is affected — only the next dbInit run will use it.

### `oryo-resend-api-key`

Rotate on the Resend side, update the k8s Secret, restart dashboard pods. Mid-rotation in-flight login codes may fail to send; users will retry.

### Ad-hoc DB access (for the `ALTER ROLE` step)

```bash
NS=<NAMESPACE>
ADMIN_PW=$(kubectl -n $NS get secret oryo-db-admin -o jsonpath='{.data.password}' | base64 -d)
RDS=$(kubectl -n $NS get configmap oryo-oryo-platform-env -o jsonpath='{.data.DB_HOST}' 2>/dev/null \
       || echo '<your-rds-endpoint>')

kubectl -n $NS run psql-debug --rm -it --restart=Never --image=postgres:15 \
  --env="PGPASSWORD=$ADMIN_PW" -- \
  psql "host=$RDS user=postgres dbname=postgres sslmode=require"
```

The pod is ephemeral (`--rm`) and never persists the password to disk. Quit with `\q` and the pod is gone.

> **NOTE:** k8s Secrets are base64 (not encrypted) in etcd by default. For production, enable EKS envelope encryption with KMS — see [AWS docs](https://docs.aws.amazon.com/eks/latest/userguide/enable-kms.html). Without it, anyone with `secrets/get` RBAC sees the plaintext.

---

## Gotchas

Standard AWS / k8s / Helm operational gotchas (wrong-account SSO, ACM `PENDING_VALIDATION`, RDS security group reachability for `dbInit`, etc.) aren't repeated here. These are the Oryo-specific quirks that have actually surprised people:

- **Don't patch the built-in `general-purpose` NodePool to add arm64.** Auto Mode reconciles it back to default. Use the dedicated `oryo-arm64` NodePool from [customer/docs/prereqs.md §4](prereqs.md).
- **Don't install the standalone `aws-load-balancer-controller`.** Auto Mode ships its own ALB controller; the standalone one crashes with `ec2imds GetMetadata` timeouts and fights it for ingress reconciliation. The chart's `IngressClass` already routes to the built-in controller.
- **`group.name` ingress annotation doesn't merge ALBs in practice.** Chart sets `alb.ingress.kubernetes.io/group.name: oryo` intending one shared ALB across the 3 ingresses; Auto Mode currently provisions one per ingress. Functional, just slightly more billing.
- **`dbInit` hook failure rolls back the install** and the Job is cleaned up automatically — post-mortem logs are gone. Either stream `kubectl -n <NS> logs job/oryo-oryo-platform-db-init -f` during the install, or use `--no-hooks` to debug the rest separately and run dbInit manually.
- **Bedrock failures degrade silently.** Without model access or IRSA bedrock perms, classification / active discovery / DLP / parser fallback / enricher quietly stop producing output — install still succeeds, regex/allowlist rules still match. See [Bedrock-dependent features](#bedrock-dependent-features) below for the per-feature breakdown and how to tell IAM-missing from model-access-missing apart.

### Bedrock-dependent features

Several gateway/worker code paths call Bedrock (Claude 3 Haiku for classification + discovery + DLP + parser fallback, Nova Micro for enrichment). The platform is built to **degrade silently** if Bedrock is unreachable — the install succeeds, the proxy intercepts, regex/allowlist policy rules still match. What stops working:

| Surface | When Bedrock is missing |
|---|---|
| **DLP policy function** | Returns `undefined` with a warning log. Rules of type "DLP scan" never trigger; other policy rules unaffected. |
| **Gateway active discovery** (`POST /active-discovery`, `/inference-discovery`) | 5xx with `AccessDeniedException`. New LLM endpoints don't get auto-detected; you can still add interception rules by hand. |
| **Worker classification jobs** (`tool-classification`, `tool-use-classification`, prompt classification) | Throws inside `pMap`; tool uses + prompts stay untagged. Dashboard shows raw conversations with no category badges. |
| **Parser fallback** | Deterministic parsing still works; when it can't, the prompt renders raw instead of structured. |
| **Enricher** | Enrichment metadata absent. |

Two failure modes look the same in the dashboard (no tags, no discovery) but have different causes:
- **IAM**: pod-side AWS calls return `AccessDeniedException: User is not authorized to perform: bedrock:InvokeModel` → fix the IRSA policy ([customer/docs/prereqs.md §2a](prereqs.md#2-iam-policy--role-irsa--lets-the-pods-reach-s3--bedrock)).
- **Model access**: same call returns `AccessDeniedException: You don't have access to the model with the specified model ID` → enable model access in the Bedrock console ([customer/docs/prereqs.md §5](prereqs.md#5-bedrock-model-access-per-region-opt-in)).

Quick check from inside the cluster:

```bash
kubectl -n <NS> exec deploy/oryo-gateway -- env | grep -E 'AWS_REGION|AWS_ROLE_ARN'
# AWS_REGION should match a region where Haiku 3 + Nova Micro are enabled.
# AWS_ROLE_ARN should be the IRSA role you created in prereqs §2.
```
