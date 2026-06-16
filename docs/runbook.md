# Oryo Private Deployment Runbook

How to install Oryo in your own AWS account. This targets EKS Auto Mode with arm64 (Graviton) nodes.

---

## Prerequisites

These need to exist before you start. The install kit doesn't create anything in your AWS account. You provision the resources, and `verify.sh` checks them. Exact specs for the AWS resources (S3 bucket, IAM role, subnet tags, arm64 NodePool, database) are in [docs/prereqs.md](prereqs.md).

| Requirement | Notes |
|---|---|
| AWS account | With SSO and admin access for the account you'll deploy into. |
| EKS cluster | Auto Mode recommended. Same AWS account and region as everything else. It must be able to provision arm64 (Graviton) nodes; see [docs/prereqs.md §4](prereqs.md). |
| S3 bucket, IAM role, subnet tags | You create these ([docs/prereqs.md §1–3](prereqs.md)); `verify.sh` checks them. |
| Bedrock model access | Per-region opt-in for Claude 3 Haiku and Nova Micro ([docs/prereqs.md §5](prereqs.md)). The install still succeeds without it, but auto-classification, active discovery, and the DLP policy won't work; see [Bedrock-dependent features](#bedrock-dependent-features). |
| Postgres database | RDS recommended. Reachable from the cluster VPC on port 5432. The target database must exist (the default `postgres` works); see [docs/prereqs.md §6](prereqs.md). |
| Domain, Route 53 zone, ACM cert | A Route 53 hosted zone for your domain in the same AWS account, and a wildcard ACM cert for `*.<your-domain>` in the cluster's region, in status `ISSUED`. See [docs/prereqs.md §7](prereqs.md). |
| Oryo ECR pull grant | Oryo grants your AWS account ID pull access to its image registry. Contact your Oryo rep if your account hasn't been provisioned access yet. |

`verify.sh` checks all of the above and can optionally bootstrap the in-cluster Kubernetes secrets. `helm install` does the rest.

---

## 0. Tools

You need these installed locally to follow the runbook:

- `aws` CLI (v2) — authentication and every AWS-side operation
- `kubectl` — to talk to your EKS cluster
- `helm` `>=4.0.0 <4.2.1` — to install and upgrade the chart. 4.2.1 can hang upgrades for several minutes per hook while cleaning up resources.
- `eksctl` — only for the eksctl IRSA path in [docs/prereqs.md §2b](prereqs.md) (skip it if you create the role manually)
- `jq` — used by `verify.sh` to inspect Auto Mode NodePools during preflight
- `openssl` — used by `verify.sh --bootstrap-secrets` to generate session and role passwords (the system default works on macOS and Linux)
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

Confirm the cluster is EKS Auto Mode:

```bash
kubectl get nodepool 2>/dev/null
# Rows like `general-purpose` / `system` mean Auto Mode.
# "no resources" means classic node groups, which this runbook doesn't cover.
```

## 2. Provision prerequisites, then run the preflight

The install kit doesn't create anything in your AWS account. Create the prerequisites yourself per [docs/prereqs.md](prereqs.md) (S3 bucket, IAM role, subnet tags, arm64 NodePool, Postgres database), using the console, CLI, or your own Terraform.

Then run `verify.sh`. It checks that everything exists and prints the values you'll need:

```bash
cd customer
cp .env.example .env
$EDITOR .env          # AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE, BUCKET_NAME

./scripts/verify.sh    # preflight — checks bucket, IAM role, subnet tags, arm64, secrets
```

It prints a pass/fail for each check, and points you at the right section of `prereqs.md` for anything that's missing. Once everything passes, it prints the role ARN and bucket name for `values.yaml`.

### Kubernetes secrets

The chart needs these secrets in your namespace: `oryo-session-secret`, `oryo-db-admin`, `oryo-db-dashboard`, `oryo-db-gateway`, `oryo-db-worker`, `oryo-resend-api-key`. Two options:

- Bring your own (ESO, Vault, SealedSecrets, or manual `kubectl`). `verify.sh` checks that they exist.
- Let the script generate them. Fill in `DB_ADMIN_USER`, `DB_ADMIN_PASSWORD`, and `RESEND_API_KEY` in `.env`, then run:
  ```bash
  ./scripts/verify.sh --bootstrap-secrets
  ```
  This generates the random secrets (session and per-service DB passwords) and creates `oryo-db-admin` from your `.env`. It's safe to re-run.

> Database note: the target Postgres database must already exist (the default `postgres` works, or create your own and set it in `values.yaml` → `global.db.database`). dbInit creates the per-service roles and schema but doesn't create the database itself.

> Email note: `RESEND_API_KEY` is required. The dashboard emails login codes through Resend, so without it users can't sign in. Use your own Resend API key (https://resend.com) or ask the Oryo team to provide one.

## 3. Fill in `values.custom.yaml`

The published chart already pins the registry, image tags, and sensor range. You just add your own overrides in a `values.custom.yaml` (gitignored). Keep this file outside the chart so it carries over on upgrades.

```bash
$EDITOR values.custom.yaml
```

To see the keys and their defaults, dump the published chart's values:

```bash
helm show values oci://<registry-host>/charts/oryo-platform --version <version>
```

Override at least these:
- `global.env.DOMAIN`, `APP_BASE_URL`, `API_BASE_URL` — your domain.
- `global.env.DEFAULT_BUCKET` — the bucket name from `.env`.
- `global.db.host` / `database` — your RDS endpoint and database name.
- `serviceAccount.annotations.eks.amazonaws.com/role-arn` — the IRSA role ARN from `verify.sh`.
- `alb.ingress.kubernetes.io/certificate-arn` — the ACM cert ARN from prereqs (all 3 ingresses use it).
- Ingress hostnames — `app.<DOMAIN>`, `gateway.<DOMAIN>`, `api.<DOMAIN>`.
- `dbInit.defaultTenant` — your org name and owner email.
- `global.env.ENV_NAME` — must be one of `local | dev | stage | prod` (Zod enum). Set this to `stage` for every private-deploy install. `stage` is the private-deploy value. It's how the platform tells customer-managed clusters apart from Oryo's own infrastructure, which lets us add per-environment behavior (telemetry sampling, alert routing, opt-in features) without affecting either side. `prod` is reserved for Oryo's own SaaS.

## 4. Install from the registry

The chart is published to Oryo's registry as a versioned OCI artifact. The `oci://` URL and `<version>` are in each [GitHub Release](https://github.com/oryo-identity/oryo-private-deploy/releases), along with the image digests you can check against later.

Log in to the registry first, using the credentials provided with your release:

```bash
helm registry login <registry-host>
```

`helm` prompts for the username and token, or you can pass them with `--username` and `--password-stdin`. Log in to the registry host only, with no `/charts/...` path. Your account needs Oryo's pull grant for the registry; if login works but the install gets a 403 on the pull, that grant is missing, so contact your Oryo rep.

Then install the version you want:

```bash
helm upgrade --install oryo \
  oci://<registry-host>/charts/oryo-platform --version <version> \
  --namespace <NAMESPACE> --create-namespace \
  -f values.custom.yaml \
  --atomic --cleanup-on-fail --wait --timeout 10m
```

Use `helm upgrade --install` for both the first install and later upgrades. It installs if the release is missing and upgrades if it's there, so you won't hit `Error: ... has no deployed releases` from running `helm upgrade` too early. Pass only `-f values.custom.yaml`. The published chart already has the right registry, image tags, and sensor range, so don't re-pass a local `values.yaml`.

`--atomic --cleanup-on-fail` rolls a failed install or upgrade back to the previous state instead of leaving it half-applied.

If you bootstrapped secrets with `verify.sh --bootstrap-secrets`, the namespace already exists and `--create-namespace` is a no-op.

If you're working on the chart itself, you can install from the local source dir instead: `helm install oryo ./oryo-platform --values oryo-platform/values.yaml -f values.custom.yaml`. That skips the published, version-pinned artifact, so it's only for chart development, not customer installs.

The timeout matters. The first install on a cold cluster pulls images, provisions arm64 nodes, runs the dbInit hook, and then waits for every pod to become Ready. That can take a few minutes. 10 minutes is usually plenty. Raise it if your cluster is provisioning capacity from scratch.

The `dbInit` hook (pre-install and pre-upgrade) connects to RDS as the admin user, creates the per-service Postgres roles using the passwords from the Kubernetes secrets, applies the schema and RLS policies, seeds the global rules, and seeds the default tenant. It's idempotent, so it runs on every install and upgrade. The target database must already exist. Use the default `postgres` database or create your own beforehand.

Watch the rollout:
```bash
kubectl -n <NAMESPACE> get pods
kubectl -n <NAMESPACE> logs job/oryo-oryo-platform-db-init --tail=50
```

## 5. Point DNS at the ALBs

After install, Auto Mode provisions the ALBs (about 2–3 minutes). Get the hostnames:

```bash
kubectl -n <NAMESPACE> get ingress
```

The `ADDRESS` column shows hostnames like `k8s-...elb.<region>.amazonaws.com`. The chart's `alb.ingress.kubernetes.io/group.name` annotation is meant to merge all 3 ingresses onto one ALB, but Auto Mode currently creates a separate ALB per ingress. That works fine, just with a bit more billing.

You need 3 CNAMEs in your Route 53 hosted zone, one per subdomain:
- `app.<DOMAIN>` → the dashboard's ALB hostname
- `gateway.<DOMAIN>` → the gateway's ALB hostname
- `api.<DOMAIN>` → the api's ALB hostname

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

`UPSERT` means create-or-replace, so it's safe to re-run if you change something.

### Console

Route 53 → Hosted zones → your zone → Create record, three times:
- Record name: `app`, `gateway`, or `api` (just the subdomain)
- Record type: `CNAME`
- Value: the matching ALB hostname from `kubectl get ingress`
- TTL: 60

### Automatic (ExternalDNS)

Install [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) once and it watches your Ingresses and writes the Route 53 records for you. Worth it if you redeploy often.

CNAMEs propagate within 1–5 minutes.

## 6. Smoke test

```bash
curl -I https://app.<DOMAIN>/healthcheck
curl -I https://gateway.<DOMAIN>/healthcheck
curl -I https://api.<DOMAIN>/healthcheck
# Expect 200 OK on all three
```

Then open `https://app.<DOMAIN>` in a browser to reach the dashboard.

> Login email: login codes are emailed through Resend using `RESEND_API_KEY` (required, set in `.env`). The chart wires the `oryo-resend-api-key` secret into the dashboard pod. SMTP/SES support is on the way.

---

## 7. Install a sensor (end-to-end verification)

The best way to confirm a deployment works is to install a sensor and watch it intercept AI traffic using the global rules seeded at install.

The detailed steps (registration token, install one-liner, CA download) are in the dashboard under Settings → Installation. This section covers the overall shape. Follow the dashboard for the exact commands.

### MDM fleet rollout (Intune, JAMF, etc.)

1. Push the Oryo CA from Settings → Installation → Download CA as a trusted root certificate, using your MDM's certificate-distribution profile.
2. Push the install one-liner (also under Settings → Installation) using your MDM's run-script policy.
3. Confirm the dashboard's Devices page fills in as sensors register.

### Manual test (one device)

Download the CA from Settings → Installation → Download CA, add it to your system trust store, then run the install one-liner from the same page. Visit a watched site (for example `chatgpt.com`). It should load with no TLS error and appear in the dashboard within a few seconds.

> Note: each tenant has its own root CA. If you tear down and reinstall the platform, the CA regenerates, so re-download and re-trust it before testing again.

---

## Checking your version

To see which chart version is installed:

```bash
helm list -A
# CHART = oryo-platform-<chartVersion>;  APP VERSION = the platform build it deploys
```

To see what's actually running (the source of truth, immutable image digests):

```bash
kubectl get pods -n <ns> \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

The chart version and the platform version (`APP VERSION`) move independently. A chart
fix can ship without a platform change, so report both when you file an issue.

---

## Upgrades

Same command as the install, with `--version` pointed at the newer release:

```bash
helm upgrade --install oryo \
  oci://<registry-host>/charts/oryo-platform --version <new-version> \
  --namespace <NAMESPACE> \
  -f values.custom.yaml \
  --atomic --cleanup-on-fail --wait --timeout 10m
```

No DNS changes are needed for an upgrade. Afterwards, confirm the pods picked up the new build (see [Checking your version](#checking-your-version)).

The `dbInit` hook re-runs on every upgrade. It's idempotent, since schema additions use `IF NOT EXISTS`.

To skip it on upgrades and save time, set `dbInit.enabled: false` in your `values.custom.yaml` before running the upgrade.

`--atomic` rolls the release back automatically if the upgrade fails or times out, so a bad run can't leave it half-applied. If an upgrade is interrupted before it finishes (for example, the process is killed mid-run), the release can be left in a `pending-upgrade` state that blocks the next upgrade with `another operation (install/upgrade/rollback) is in progress`. Clear it and retry:

```bash
helm rollback oryo --namespace <NAMESPACE>
```

---

## Secret rotation

The chart consumes 6 Kubernetes secrets (`oryo-session-secret`, `oryo-db-admin`, `oryo-db-{dashboard,gateway,worker}`, `oryo-resend-api-key`). Rotating them in production works differently depending on which one, and there are a few Oryo-specific things to watch for. Coordinate the actual key delivery with your secrets store (Vault, AWS Secrets Manager, ESO, etc.). The steps below are what the chart expects.

### `oryo-session-secret`

Rotating this logs every signed-in user out. The dashboard verifies incoming cookies with the current key, so cookies signed with the old key fail HMAC verification and the user is bounced to login.

Steps:
1. Update the secret with the new value.
2. Restart the dashboard pods (`kubectl rollout restart deploy/oryo-oryo-platform-dashboard`).

There's no multi-key overlap window. If user-facing downtime matters, pick a low-traffic window.

### Per-service DB role passwords (`oryo-db-{dashboard,gateway,worker}`)

The `dbInit` hook does not re-issue `ALTER ROLE … WITH PASSWORD` on existing roles. Doing that on every helm upgrade would churn the Postgres catalog for no benefit when the secret hasn't changed, so password rotation is a separate, explicit operation. You sync the Postgres role's password with the new Kubernetes secret yourself, in this order:

1. Generate the new password.
2. Run `ALTER ROLE "oryo-<service>" WITH PASSWORD '<new>'` against RDS (use a debug pod that mounts `oryo-db-admin`, see "Ad-hoc DB access" below).
3. Update the Kubernetes secret with the same value.
4. Restart the affected service pods.

If you do step 3 before step 2, the new pods crashloop on `28P01 invalid_password` until step 2 lands. If you do step 2 before step 4, the old pods (still using the old password) crashloop on `28P01` until they restart. Either order works. Just don't leave a gap between the steps.

### `oryo-db-admin` (RDS master)

Used only by the `dbInit` hook during `helm install` and `helm upgrade`. Long-running pods don't mount it.

Steps:
1. Rotate the password on the RDS instance (`aws rds modify-db-instance --master-user-password`).
2. Update the Kubernetes secret.
3. The next `helm upgrade` picks it up. (You don't need to restart anything.)

If you rotate it between upgrades, no pod is affected. Only the next dbInit run uses it.

### `oryo-resend-api-key`

Rotate it on the Resend side, update the Kubernetes secret, and restart the dashboard pods. In-flight login codes during the rotation may fail to send. Users will retry.

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

The pod is ephemeral (`--rm`) and never writes the password to disk. Quit with `\q` and the pod is gone.

> Note: Kubernetes secrets are only base64-encoded in etcd by default, so they aren't encrypted at rest. For production, enable EKS envelope encryption with KMS (see [AWS docs](https://docs.aws.amazon.com/eks/latest/userguide/enable-kms.html)). Without it, anyone with `secrets/get` RBAC can read the plaintext.

---

## Gotchas

Standard AWS, Kubernetes, and Helm gotchas (wrong-account SSO, ACM stuck in `PENDING_VALIDATION`, RDS security-group reachability for `dbInit`, etc.) aren't repeated here. These are the Oryo-specific ones that have actually tripped people up:

- Don't patch the built-in `general-purpose` NodePool to add arm64. Auto Mode reconciles it back to default. Use the dedicated `oryo-arm64` NodePool from [docs/prereqs.md §4](prereqs.md).
- Don't install the standalone `aws-load-balancer-controller`. Auto Mode ships its own ALB controller. The standalone one crashes with `ec2imds GetMetadata` timeouts and fights it for ingress reconciliation. The chart's `IngressClass` already routes to the built-in controller.
- The `group.name` ingress annotation doesn't actually merge ALBs. The chart sets `alb.ingress.kubernetes.io/group.name: oryo` to put all 3 ingresses on one ALB, but Auto Mode currently provisions one per ingress. It works, just at slightly higher cost.
- A `dbInit` hook failure rolls back the install, and the Job is cleaned up automatically, so the logs are gone afterward. Either stream `kubectl -n <NS> logs job/oryo-oryo-platform-db-init -f` during the install, or use `--no-hooks` to debug the rest separately and run dbInit by hand.
- Bedrock failures degrade silently. Without model access or IRSA Bedrock permissions, classification, active discovery, DLP, parser fallback, and the enricher quietly stop producing output. The install still succeeds, and regex/allowlist rules still match. See [Bedrock-dependent features](#bedrock-dependent-features) for the per-feature breakdown and how to tell a missing IAM grant from missing model access.

### Bedrock-dependent features

Several gateway and worker code paths call Bedrock (Claude 3 Haiku for classification, discovery, DLP, and parser fallback; Nova Micro for enrichment). The platform is built to degrade silently if Bedrock is unreachable: the install succeeds, the proxy intercepts, and regex/allowlist policy rules still match. What stops working:

| Surface | When Bedrock is missing |
|---|---|
| DLP policy function | Returns `undefined` with a warning log. "DLP scan" rules never trigger; other policy rules are unaffected. |
| Gateway active discovery (`POST /active-discovery`, `/inference-discovery`) | Returns 5xx with `AccessDeniedException`. New LLM endpoints aren't auto-detected; you can still add interception rules by hand. |
| Worker classification jobs (`tool-classification`, `tool-use-classification`, prompt classification) | Throws inside `pMap`; tool uses and prompts stay untagged. The dashboard shows raw conversations with no category badges. |
| Parser fallback | Deterministic parsing still works; when it can't parse, the prompt renders raw instead of structured. |
| Enricher | Enrichment metadata is absent. |

Two failure modes show up the same way in the dashboard — tags and discovery both go missing — but they have different causes:
- IAM: pod-side AWS calls return `AccessDeniedException: User is not authorized to perform: bedrock:InvokeModel`. Fix the IRSA policy ([docs/prereqs.md §2a](prereqs.md#2-iam-policy--role-irsa-for-s3--bedrock)).
- Model access: the same call returns `AccessDeniedException: You don't have access to the model with the specified model ID`. Enable model access in the Bedrock console ([docs/prereqs.md §5](prereqs.md#5-bedrock-model-access-per-region-opt-in)).

Quick check from inside the cluster:

```bash
kubectl -n <NS> exec deploy/oryo-gateway -- env | grep -E 'AWS_REGION|AWS_ROLE_ARN'
# AWS_REGION should match a region where Haiku 3 + Nova Micro are enabled.
# AWS_ROLE_ARN should be the IRSA role you created in prereqs §2.
```
