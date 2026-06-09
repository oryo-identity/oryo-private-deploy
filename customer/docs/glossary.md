# Glossary — Oryo-specific terms

Terms used across this kit that aren't standard k8s / AWS jargon. For anything else, the AWS and Kubernetes docs are the authoritative source.

---

### `dbInit` (a.k.a. dbInit hook, dbInit Job)

The Helm `pre-install` / `pre-upgrade` hook that bootstraps the Postgres schema. Runs once per `helm install` / `helm upgrade` against your RDS master role, then exits. Creates per-service Postgres roles (`oryo-dashboard`, `oryo-gateway`, `oryo-worker`), creates tables, applies RLS policies, seeds default data (tenants, interception rules, session extractors).

Long-running pods never mount `oryo-db-admin` — only `dbInit` does. After it exits, the admin password sits unused in etcd until the next upgrade.

See `runbook.md` § Gotchas → Database for failure-mode debugging.

---

### `oryo-session-secret`

A single random ≥32-byte value (HMAC key) used by the dashboard to sign session cookies. **Not** a `{username, password}` pair like the DB secrets. Must be the same across all dashboard replicas (otherwise users get logged out when load-balanced between pods).

Rotating it logs everyone out — that's the design, not a bug.

---

### Per-service Postgres roles

Each long-running service connects to RDS as its own non-admin role with **least-privilege grants**:

| Service | Postgres role | Authority |
|---|---|---|
| dashboard | `oryo-dashboard` | DML on user-facing tables, scoped by RLS |
| api | `oryo-dashboard` | (same role as dashboard) |
| gateway | `oryo-gateway` | DML for sensor-ingest tables, scoped by RLS |
| workers | `oryo-worker` | DML on queue + usage tables, can write across tenants |

A pod compromise gives the attacker that role only — no DDL, no cross-service tables. The `oryo-db-{dashboard,gateway,worker}` k8s Secrets carry the per-role passwords.

---

### RLS (Row-Level Security) tenant isolation

Postgres `CREATE POLICY` filters every query on tenant-scoped tables by `current_setting('rls.tenant_id')::uuid`. The dashboard/gateway/workers set that GUC at connection time via middleware. The `oryo-dashboard` role can't see another tenant's rows even if a SQL injection bypasses application-level checks.

Non-RLS tables (`tenants`, `access`, system tables) still need explicit `WHERE tenant_id = $1`.

> **NOTE for private deployments:** RLS is primarily a multi-tenant SaaS safety net. A private install is expected to run as a **single tenant** (the one created by `dbInit.defaultTenant`), so cross-tenant leakage isn't a realistic concern in this environment. RLS still runs — it just doesn't have anything to isolate against. You can treat it as defense-in-depth, not as a load-bearing security boundary.

---

### Per-tenant sensor root CA

Each tenant gets its own Certificate Authority (CN: `Oryo Sensor Root CA, OU=<tenantId>`). The dashboard exposes the CA bundle for admins to deploy via Intune/JAMF. Sensors generate a CSR per device and request a 7-day leaf cert from `POST /v1/sensor/cert`; the gateway signs it with the tenant's CA. Sensors trust only their tenant's CA, so a compromised sensor in tenant A can't impersonate one in tenant B.

The CA private key stays server-side; only leaf certs go to devices.

---

### ECR pull grant

Oryo's container images live in Oryo's prod ECR (`831622638566.dkr.ecr.us-east-1.amazonaws.com`). For a customer cluster to pull them, Oryo runs `grant-ecr-pull.sh` from the registry account to add the customer's account ID to each repo's `aws_ecr_repository_policy`. This is one-time per customer account.

You send Oryo your AWS account ID + region; Oryo grants pull access to `api`, `dashboard`, `gateway`, `workers`, `db-init`. See `docs/onboarding.md`.

---

### gateway vs api

Two HTTPS-exposed services with different roles:

- **`gateway`** receives **sensor traffic** — encrypted intercepted requests from deployed Oryo sensors. Handles cert issuance (`/v1/sensor/cert`), config delivery (`/v1/sensor/config`), and traffic ingestion (`/v1/sensor/traffic`).
- **`api`** is the **management API** — used by the dashboard, third-party integrations, and the sensor install scripts (`/v1/installs/install.sh`). Not a sensor traffic endpoint.

Both sit behind ALBs (`gateway.<DOMAIN>` and `api.<DOMAIN>` respectively).

---

### `oryo-platform` ServiceAccount

The k8s ServiceAccount the long-running pods run as. Annotated with the IRSA role ARN, which the pods assume to reach S3. The name `oryo-platform` is hard-pinned in `values.example.yaml` so the IRSA trust policy (which binds `system:serviceaccount:<NAMESPACE>:oryo-platform` to the role) keeps working.

Change it and IRSA breaks silently — pods start fine but S3 calls return AccessDenied.

---

### EKS Auto Mode

AWS-managed Karpenter + ALB controller + node OS shipped with new EKS clusters (2024+). You don't run any of the controllers yourself. Trade-off: AWS reconciles its built-in NodePools (`general-purpose`, `system`) back to defaults, so customizations to those silently revert. Custom NodePools (like our `oryo-arm64`) are preserved.

Relevant chart annotation: `kubernetes.io/ingress.class: alb` routes to Auto Mode's built-in ALB controller (`controller: eks.amazonaws.com/alb`). Don't install the standalone `aws-load-balancer-controller` — it conflicts.

---

### Karpenter (arm64 NodePool)

Auto Mode's underlying node autoscaler. Watches pending pods, provisions EC2 instances matching their requirements. Our chart's `nodeSelector: kubernetes.io/arch: arm64` requires Karpenter to launch Graviton instances; the default Auto Mode `general-purpose` NodePool is amd64-only, so we ship a dedicated `oryo-arm64` NodePool (see prereqs.md §4) Karpenter picks up.

---

### IRSA (IAM Roles for Service Accounts)

EKS feature that lets a k8s ServiceAccount assume an IAM role via the cluster's OIDC provider. Pods using that SA get short-lived AWS credentials with the role's permissions automatically (`AWS_WEB_IDENTITY_TOKEN_FILE` is mounted by the EKS pod identity webhook). No baked-in IAM keys, no instance-profile inheritance.

The chart's `oryo-platform` ServiceAccount gets annotated with `eks.amazonaws.com/role-arn: <your role ARN>` — that's IRSA in action.
