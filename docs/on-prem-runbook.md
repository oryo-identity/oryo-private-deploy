# Oryo On-Prem Deployment Runbook (experimental)

> **Status: experimental.** The supported, hardened install path today is AWS/EKS — see
> [runbook.md](runbook.md). This guide covers running Oryo on a **self-managed Kubernetes
> cluster with no AWS**, substituting on-prem equivalents for the AWS-managed services.
> Sections are marked **[validated]** (confirmed working in a lab) or **[planned]** (the
> intended approach, not yet confirmed end-to-end). Air-gapped installs are out of scope here.

## Who this is for

On-prem / non-AWS deployments — e.g. a Kubernetes cluster running on Hyper-V or vSphere VMs.
Tested on a single-node [k3s](https://k3s.io) cluster on an amd64 Ubuntu VM.

## Architecture (on-prem)

Same shape as the AWS deployment — sensors on the endpoints report to one platform running on
Kubernetes — with the AWS-managed services swapped for on-prem equivalents:

| AWS (default) | On-prem substitute | Status |
|---|---|---|
| EKS | k3s / RKE2 / any conformant Kubernetes | [validated] (k3s) |
| ECR images (arm64) | GHCR, multi-arch (amd64 + arm64) | [validated] |
| RDS Postgres | self-hosted Postgres | [validated] |
| S3 object storage | No longer required (removed upstream) | n/a |
| ALB + ACM + Route 53 | ingress-nginx + internal CA cert + internal DNS | [validated] (lab: self-signed + hosts file) |
| Bedrock (AI models) | *no substitute today* — AI features degrade, see Limitations | open |
| IRSA | not needed off-AWS | n/a |

---

## Prerequisites

- One or more **amd64** Linux hosts for the cluster (Ubuntu LTS tested).
- A **Kubernetes cluster**. k3s is shown here; **RKE2** is a good hardened/FIPS-capable choice for production.
- Internet egress to pull images (or a mirrored registry for air-gap — not covered here).
- **GHCR pull credentials** (a token; for customers, a dedicated deploy account — see §2).
- A **DNS name** you control that the endpoints can resolve, and a **CA the endpoints trust**
  (an internal CA pushed by your MDM/AD works well).
- **Postgres** reachable from the cluster.
- Tools on the machine you run the install from — none are preinstalled on a stock Ubuntu server:
  - `kubectl` (k3s bundles one; see §1)
  - `helm` `>=4.0.0 <4.2.1` (install command in §3c)
  - `openssl` — cert + secret generation (present on stock Ubuntu)
  - `skopeo` (optional) — the §2 image-manifest check; `sudo apt install -y skopeo`

---

## 1. Kubernetes cluster  [validated]

Single-node k3s:

```bash
curl -sfL https://get.k3s.io | sh -
sudo k3s kubectl get nodes        # node should be Ready
```

Set up `kubectl` for your user:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc && source ~/.bashrc
kubectl get nodes
```

> **Stable node IP matters.** A Kubernetes node's IP must not change. Use a static IP or a DHCP
> reservation. If the cluster API becomes unreachable after a reboot, check the node's IP first.

---

## 2. Image access (GHCR)  [validated]

Images live at `ghcr.io/oryo-identity/<service>:<tag>` and are **multi-arch** — Kubernetes
auto-selects amd64 on amd64 nodes. Optional check (`skopeo` isn't preinstalled on Ubuntu —
`sudo apt install -y skopeo`, or skip this and let the pull itself confirm it):

```bash
skopeo inspect --raw docker://ghcr.io/oryo-identity/api:<tag>
# Expect platform entries for both amd64 and arm64.
```

Create a pull secret in the install namespace:

```bash
kubectl create namespace oryo
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-account> \
  --docker-password=<token-with-read:packages> \
  --namespace oryo
```

> **For customers:** don't share a personal token. Use a dedicated deploy account with a
> per-customer token scoped to `read:packages`, so access can be revoked per customer.

---

## 3. Dependencies

### 3a. Postgres (replaces RDS)  [validated]

The platform needs a Postgres database it can reach on 5432, with the target database already present.
The chart's `dbInit` hook creates the per-service roles + schema inside it. Two ways:

**Option A — point at an existing or dedicated Postgres (recommended for production).**
Don't deploy anything here. Make sure the DB is reachable from the cluster, then in `values.custom.yaml`:
```yaml
global:
  db: { host: <your-postgres-host>, port: 5432, database: postgres, sslmode: require }
```
…and set the `oryo-db-admin` secret to that DB's admin username + password — `dbInit` does the rest. On
Hyper-V this is typically a dedicated Postgres VM (persistent, backed up, kept alive by the failover
cluster), or an existing Postgres the customer already runs.

**Option B — in-cluster Postgres pod (lab / testing only).**
Quick, but **ephemeral — the data is lost if the pod restarts**, so never use it for production:

```bash
kubectl apply -n oryo -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:15
          env:
            - name: POSTGRES_PASSWORD
              value: change-me        # lab only — use a secret in prod
            - name: POSTGRES_DB
              value: postgres
          ports:
            - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector: { app: postgres }
  ports:
    - { port: 5432, targetPort: 5432 }
EOF
```

Verify it's reachable in-cluster:

```bash
kubectl run psql-test --rm -it --restart=Never -n oryo \
  --image=postgres:15 --env="PGPASSWORD=change-me" -- \
  psql "host=postgres user=postgres dbname=postgres" -c "select version();"
```

For Option B, point the chart at it with `global.db.host: postgres`.

### 3b. Object storage — not required

A recent change removed the platform's dependency on S3 object storage, so no MinIO /
S3-compatible store is needed on-prem. (If you're on an older chart that still references a
bucket, upgrade to the release that dropped it.)

### 3c. Ingress controller (replaces the ALB)  [validated]

The chart ships AWS ALB ingress annotations — harmless, nginx ignores them. On-prem you provide the
ingress controller here. Everything TLS lives in §7: the cert, the ingress wiring, and DNS all deal
with resources that don't exist until the chart creates them at install time.

**Disable k3s's built-in Traefik** (it owns 80/443; nginx needs them):
```bash
echo 'disable: traefik' | sudo tee /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
kubectl -n kube-system delete helmchart traefik 2>/dev/null
```

**Install Helm** (chart needs `>=4.0.0 <4.2.1`) **and ingress-nginx:**
```bash
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v4.2.0-linux-amd64.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp && sudo install /tmp/linux-amd64/helm /usr/local/bin/helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.ingressClassResource.name=nginx \
  --set controller.service.type=LoadBalancer
```
On k3s the controller Service takes the node IP as its `EXTERNAL-IP` (`kubectl get svc -n ingress-nginx`).

---

## 4. Secrets

The chart expects these in the namespace: `oryo-session-secret`, `oryo-db-admin`,
`oryo-db-dashboard`, `oryo-db-gateway`, `oryo-db-worker`, `oryo-resend-api-key`. Create them with
`kubectl` or your secret store:

```bash
# session signing key
kubectl -n oryo create secret generic oryo-session-secret --from-literal=value=$(openssl rand -hex 32)
# Postgres admin login — password MUST match your actual Postgres
kubectl -n oryo create secret generic oryo-db-admin \
  --from-literal=username=postgres --from-literal=password=<your-postgres-password>
# per-service DB role passwords (dbInit creates the roles with these)
kubectl -n oryo create secret generic oryo-db-dashboard --from-literal=password=$(openssl rand -hex 16)
kubectl -n oryo create secret generic oryo-db-gateway   --from-literal=password=$(openssl rand -hex 16)
kubectl -n oryo create secret generic oryo-db-worker    --from-literal=password=$(openssl rand -hex 16)
# Resend key for login-code emails (placeholder installs fine, but login codes won't send)
kubectl -n oryo create secret generic oryo-resend-api-key --from-literal=value=<resend-key-or-placeholder>
```

(The `ghcr-pull` image pull secret is created separately in §2.)

> **Two things that bite:**
> - `oryo-db-admin` must hold the **real password of your Postgres** (username + password). A
>   mismatch makes `dbInit` crash with `28P01`.
> - `oryo-resend-api-key` is **required for the chart to install, but login won't work with a
>   placeholder.** The dashboard emails sign-in codes via Resend, so put a real key in before
>   go-live and restart the dashboard:
>   `kubectl -n oryo rollout restart deploy/oryo-oryo-platform-dashboard`.

---

## 5. Chart overrides for on-prem (`values.custom.yaml`)  [validated]

Keep your overrides in a separate file so they carry across upgrades. This is the exact set that
produced a clean install on k3s:

```yaml
global:
  imageRegistry: ghcr.io/oryo-identity        # GHCR instead of ECR
  imagePullSecrets:
    - name: ghcr-pull
  nodeArchitecture: amd64                      # schedule on amd64 (don't leave the arm64 default)
  createIngressClass: false                    # nginx already owns the class
  ingressClassName: nginx
  db:
    host: postgres                             # your Postgres endpoint
    port: 5432
    database: postgres
    sslmode: disable                           # set to require if your Postgres serves TLS
  env:
    ENV_NAME: stage                            # always 'stage' for customer installs
    DOMAIN: oryo.local
    APP_BASE_URL: https://app.oryo.local
    API_BASE_URL: https://api.oryo.local
    # Where sensor install scripts + binaries come from. On-prem deployments have no
    # sensor bucket of their own, so point at Oryo's public one (or your own mirror).
    # Without it, GET /install.sh|.ps1 returns 503 and sensors can't be installed
    # from the dashboard one-liner. See §7.
    SENSOR_DOWNLOAD_BASE_URL: https://binaries-pub-prod-us-east-1-oryo.s3.amazonaws.com
serviceAccount:
  annotations: {}                              # no IRSA role-arn off AWS
dbInit:
  defaultTenant:
    name: "Your Org"
    owner: "admin@oryo.local"
dashboard:
  ingress: { className: nginx, host: app.oryo.local }
gateway:
  ingress: { className: nginx, host: gateway.oryo.local }
api:
  ingress: { className: nginx, host: api.oryo.local }
```

> The chart's leftover ALB annotations (`alb.ingress.kubernetes.io/*`) are harmless — nginx
> ignores them. Wiring the TLS cert + internal DNS to actually *reach* the services happens after
> the install (§7). The pods themselves install and run with the above.

---

## 6. Install  [validated]

```bash
helm registry login ghcr.io                    # or the chart's OCI host, with your token
helm upgrade --install oryo \
  oci://<registry-host>/charts/oryo-platform --version <version> \
  --namespace oryo --create-namespace \
  -f values.custom.yaml \
  --cleanup-on-fail --wait --timeout 10m
```

> **While debugging, leave `--atomic` off.** Atomic rolls back on failure and deletes the failed
> pods, taking the evidence with it. Add `--atomic` back once the install is reliable.

Watch the rollout and the dbInit hook:

```bash
kubectl -n oryo get pods
kubectl -n oryo logs job/oryo-oryo-platform-db-init -f
```

---

## 7. Wire TLS + DNS, then install sensors

The install created the three ingresses, so the TLS chain can go in now.

**Create the cert** — an internal CA cert in prod; self-signed for the lab:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt -subj "/CN=app.<DOMAIN>" \
  -addext "subjectAltName=DNS:app.<DOMAIN>,DNS:api.<DOMAIN>,DNS:gateway.<DOMAIN>"
kubectl -n oryo create secret tls oryo-tls --cert=/tmp/tls.crt --key=/tmp/tls.key
```

**Wire the cert into the ingresses:**
```bash
for ing in dashboard api gateway; do
  host="app"; [ "$ing" = api ] && host="api"; [ "$ing" = gateway ] && host="gateway"
  kubectl -n oryo patch ingress oryo-oryo-platform-$ing --type=merge \
    -p "{\"spec\":{\"tls\":[{\"hosts\":[\"$host.<DOMAIN>\"],\"secretName\":\"oryo-tls\"}]}}"
done
```

**Name resolution** — `app/api/gateway.<DOMAIN>` must resolve to the ingress IP:
- **Prod:** a record in the customer's internal DNS → ingress IP.
- **Lab:** a hosts-file line on the machine you browse from (Windows: `C:\Windows\System32\drivers\etc\hosts`):
  `<ingress-ip>  app.<DOMAIN> api.<DOMAIN> gateway.<DOMAIN>`.

> **Why this matters for login:** the dashboard sets a `Secure` session cookie, so you must reach it
> over **https at the hostname** — not `http://<ip>` or a port-forward, or the second step of login
> silently fails (the browser won't store a `Secure` cookie over plain http).

**Trust the cert on every machine that talks to the platform** — not just the endpoints:
- every **admin machine you browse the dashboard from** — on a Hyper-V setup that's typically both
  the Hyper-V host and your own workstation, if you browse from both;
- every **endpoint that will run a sensor** (push the internal CA via MDM/AD).

ingress-nginx sends an HSTS header on every TLS response by default. Once a browser has recorded it
for your domain, it **refuses untrusted certs with no "proceed anyway" option** — so importing the
cert (or its issuing CA) into each machine's trust store is required, not a nicety. Also avoid
internal domains under HSTS-preloaded TLDs like `.dev` or `.app`; browsers hard-require trusted TLS
there from the first visit.

**Install sensors** per the dashboard's **Settings → Installation** (CA download + install
one-liner; roll out via Intune/MDM). Two platform env vars control this flow:

- `SENSOR_DOWNLOAD_BASE_URL` (§5) — on-prem deployments have no sensor-binaries bucket, so without
  it the install-script routes return 503 and the sensor config names no release. Point it at Oryo's
  public bucket (endpoints fetch binaries from there over HTTPS; **registration and sensor config
  still go to your platform** — the served script is rewritten to your `API_BASE_URL`), or at an
  internal mirror if endpoints have no egress.
- `SENSOR_PINNED_VERSION` — stamped into the chart at release time; it pins every install and
  update to the sensor build the release was tested with. You don't set it yourself, but on charts
  that carry it the API requires `SENSOR_DOWNLOAD_BASE_URL` to be set, so treat that value as
  required, not optional.

---

## Limitations (on-prem, today)

- **AI features need AWS Bedrock.** Auto-classification, active discovery, DLP scan, parser
  fallback, and enrichment call Bedrock and have **no on-prem substitute yet**. They degrade
  silently — the install succeeds and regex/allowlist rules still match, but model-driven features
  stop producing output. See [runbook.md → Bedrock-dependent features](runbook.md#bedrock-dependent-features).
- **Ingress** — the chart's ALB annotations need an on-prem swap (§3c).
- **Login depends on Resend** — sign-in codes are emailed via Resend (an external SaaS). Compliance-
  sensitive customers may object to auth emails leaving their network; SMTP/SES support is reportedly
  on the way. Confirm the customer's stance before go-live.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `ImagePullBackOff` + `FailedToRetrieveImagePullSecret` / 401 | The Kubernetes pull secret doesn't exist. **Gotcha:** pulling with `k3s ctr --user` authenticates *containerd*, not Kubernetes — pods still need the secret. | Create it: `kubectl -n oryo create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username=<acct> --docker-password=<token>` |
| `exec format error` | Wrong-arch image on the node | `uname -m` on the node vs the image's platforms (`skopeo inspect --raw`) |
| `db-init` `CrashLoopBackOff` / `28P01 password authentication failed` | The `oryo-db-admin` secret password doesn't match the actual Postgres password | Recreate `oryo-db-admin` with the DB's real password, then re-run the install |
| Rerun fails: *"another operation in progress"* | A killed/interrupted install left the release `pending-install` | `helm uninstall oryo -n oryo`, then re-run `helm upgrade --install` |
| `dbInit` job fails then vanishes | Hook rolled back and was cleaned up (avoid `--atomic` while debugging) | Stream it live: `kubectl logs job/oryo-oryo-platform-db-init -f`, or install with `--no-hooks` to debug separately |
| Cluster API unreachable after reboot | Node IP changed | Confirm the node's static IP / DHCP reservation |
| Sensor can't reach the platform | DNS or cert | Endpoint must resolve the hostname to the ingress IP and trust the cert |
| Login code rejected even when fresh/correct | Accessing over `http` (port-forward or raw IP) drops the `Secure` session cookie set in login step 1 | Reach the app over **https at its hostname** (cert + DNS/hosts), not the IP |
| Browser blocks the site with a cert error and **no "proceed anyway" link** | HSTS (sent by ingress-nginx by default) + a cert this machine doesn't trust | Import the cert/CA into **this machine's** trust store (§7) — every machine that browses the dashboard needs it, not just the endpoints |
| `GET /install.sh` or `/install.ps1` returns 503 | `SENSOR_DOWNLOAD_BASE_URL` not set — the deployment has no sensor-binaries source | Set it in `values.custom.yaml` (§5) and upgrade |
| No email provider in the lab — can't receive the login code | Resend is stubbed, so the code email never arrives | Pull it straight from Postgres: `SELECT token FROM login_events ORDER BY created_at DESC LIMIT 1;` |

---

*Maintained alongside lab validation. As each [planned] section is confirmed end-to-end, update
its status to [validated] and record what was needed.*
