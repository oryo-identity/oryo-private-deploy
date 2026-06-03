# Oryo Private Deployment — Runbook

End-to-end bootstrap for a new Oryo deployment. Split into:

- **Part A — Oryo internal:** one-time per customer, run by Oryo to onboard them
- **Part B — Customer (or sandbox tester):** run in the customer's own AWS account

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
- `jq` (used by `grant-ecr-pull.sh`; not needed if Oryo runs Part A for you)
- `openssl` (system default; used by `setup.sh` to generate secrets)
- `docker` (optional — only for local image-pull verification)

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
1. **Certificate Manager** → region selector top-right (must match cluster region) → click the new cert
2. "Domains" section → **"Create records in Route 53"** button → confirm
3. Wait 5–10 min; status flips to `ISSUED`

Poll from CLI:
```bash
aws acm describe-certificate \
  --profile <your-profile> --region <your-region> \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
```

Save the cert ARN — goes into `values.yaml`.

### B.4. EKS cluster

Assume the cluster already exists. To connect:

```bash
aws eks list-clusters --profile <your-profile> --region <your-region>

aws eks update-kubeconfig --profile <your-profile> --region <your-region> --name <cluster-name>

kubectl get nodes
```

**Check cluster type.** Run `kubectl get nodes -o wide` and look for `eks-auto-mode/compute` or `nodeclaim/...` in pod events on the cluster. If present, the cluster is **EKS Auto Mode** — this matters because Auto Mode includes a built-in load balancer controller and node provisioner, and certain things (like the standalone AWS Load Balancer Controller) must NOT be installed.

`setup.sh` (next step) creates an IngressClass that targets Auto Mode's built-in controller. For standard (non-Auto-Mode) EKS, you must install the AWS Load Balancer Controller separately first — see [docs/non-auto-mode.md](non-auto-mode.md) (TODO).

### B.5. Run `setup.sh`

This creates the S3 bucket, IAM policy + IRSA role, k8s namespace + ServiceAccount + Secrets, and the `alb` IngressClass. Idempotent.

```bash
cd ~/Work/oryo-private-deploy

cp .env.example .env
$EDITOR .env
# Fill in: AWS_PROFILE, AWS_REGION, ACCOUNT_ID, CLUSTER_NAME, NAMESPACE,
# BUCKET_NAME (must be globally unique), DB_ADMIN_USER, DB_ADMIN_PASSWORD

./scripts/setup.sh
```

Output prints the IRSA role ARN — copy that for the next step.

### B.6. Fill in `values.yaml`

```bash
cp values.example.yaml values.yaml
$EDITOR values.yaml
```

Replace placeholders (search for `TODO`):
- **`global.env.DOMAIN`** + **`APP_BASE_URL`** — your domain
- **`global.env.DEFAULT_BUCKET`** — bucket name from `.env`
- **`global.db.host` / `database`** — your RDS endpoint and database name
- **`serviceAccount.annotations.eks.amazonaws.com/role-arn`** — IRSA role ARN from `setup.sh`
- **`alb.ingress.kubernetes.io/certificate-arn`** — ACM cert ARN from B.3 (3 ingresses use it)
- **Ingress hostnames** — `app.<DOMAIN>`, `gateway.<DOMAIN>`, `api.<DOMAIN>`
- **`dbInit.defaultTenant`** — your org name + owner email

### B.7. `helm install`

```bash
helm install oryo ./chart \
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 5m
```

`--wait` blocks until all pods report Ready (or 5 min times out). On success you'll see `STATUS: deployed`.

The pre-install hook runs the `dbInit` Job: connects to RDS as the admin user, creates the database (if missing), creates the per-service roles using the passwords from the k8s Secrets, applies schema and RLS policies, seeds the default tenant. Watch:

```bash
kubectl -n <NAMESPACE> get pods
kubectl -n <NAMESPACE> logs job/oryo-oryo-platform-db-init --tail=50
```

### B.8. Point DNS at the ALB

Auto Mode provisions an ALB ~2–3 min after install. Get the hostname:

```bash
kubectl -n <NAMESPACE> get ingress
```

The `ADDRESS` column will show something like `k8s-oryosandbox-...elb.us-east-2.amazonaws.com`.

In Route 53, create CNAMEs in your hosted zone:
- `app.<DOMAIN>` → ALB hostname
- `gateway.<DOMAIN>` → ALB hostname
- `api.<DOMAIN>` → ALB hostname

Or install [ExternalDNS](https://kubernetes-sigs.github.io/external-dns/) to automate this. CNAMEs propagate in 1–5 min.

### B.9. Smoke test

```bash
curl -I https://app.<DOMAIN>/healthcheck
# expect 200 OK
```

Then open `https://app.<DOMAIN>` in a browser. The login flow currently logs the code to dashboard pod logs (no email provider configured by default) — read it with:

```bash
kubectl -n <NAMESPACE> logs deploy/oryo-oryo-platform-dashboard | grep -i 'login code'
```

(Setting `RESEND_API_KEY` enables real email. Pluggable email providers is a planned improvement — see project task.)

---

## Upgrades

```bash
helm upgrade oryo ./chart \
  --namespace <NAMESPACE> \
  --values values.yaml \
  --wait --timeout 5m
```

The `dbInit` hook re-runs on every upgrade (idempotent — schema additions are `IF NOT EXISTS`).

To skip the dbInit hook on upgrades (faster), set `dbInit.enabled: false` in `values.yaml` before running `helm upgrade`.

---

## Gotchas seen so far

- **Wrong AWS account via SSO.** Always run `aws sts get-caller-identity` before any state-changing command. Cert/domain created in the wrong account = restart in the right one.
- **EKS Auto Mode + manual ALB controller.** Don't install the standalone AWS Load Balancer Controller on Auto Mode — it crashes with `ec2imds GetMetadata` timeouts because Auto Mode nodes block IMDS for security.
- **ACM cert stuck in PENDING_VALIDATION.** Requesting a cert does not validate it. Use the "Create records in Route 53" console button (or create the validation CNAMEs manually).
- **`helm install --dry-run` prints NOTES.** Don't mistake dry-run output for a successful install. `helm list -A` is the ground truth.
- **RDS unreachable from cluster.** dbInit Job hangs if the RDS security group doesn't allow inbound from the EKS pod CIDR. Fix: add an SG rule allowing port 5432 from the cluster's VPC CIDR.
- **`ENV_NAME` rejected.** dbInit crashes silently in <1s if `global.env.ENV_NAME` is not one of `local | dev | stage | prod` (enum-constrained by `SharedEnvZ` in the platform). Use `prod` for any real customer install. Tracked for relaxation — see project task list.
- **`kubectl exec` fails with TLS error on EKS Auto Mode.** Workaround: use one-shot pods that print to stdout, then read via `kubectl logs`. Don't rely on `kubectl exec -it` for debug.

---

## Reference: the actual sandbox

For Oryo internal — this repo's `values.sandbox.yaml` is the reference deployment. To rebuild it from scratch:

```bash
cd ~/Work/oryo-private-deploy

# .env is already populated for sandbox (gitignored)
./scripts/setup.sh

# Cross-account ECR pull (run from prod, one-time)
./scripts/grant-ecr-pull.sh 221759618824 oryo-prod

helm install oryo ./chart \
  --namespace oryo-sandbox \
  --values values.sandbox.yaml \
  --wait --timeout 5m
```
