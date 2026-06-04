# Private Deploy Readiness

Honest accounting of what we have and what's still rough, based on the sandbox bootstrap (account `221759618824`, domain `oryo-pd.click`, EKS Auto Mode cluster `cluster-pd-1`).

The short version: **the deployment model works end-to-end.** A customer's AWS account, their EKS cluster, their RDS, their domain, their ALBs — all working with Oryo's images pulled cross-account from prod ECR. What's left is polish on the distribution side (publishing the chart, dbInit handling more cases, configurable email) — not the deployment model itself.

---

## What's already a real private deploy

These match exactly what a paying customer's install would look like:

| Component | Sandbox state | Customer would do |
|---|---|---|
| **AWS account** | `221759618824` — no shared infra with Oryo dev (`149...`) or prod (`831...`) | Their own account |
| **EKS cluster** | Sandbox-owned `cluster-pd-1` (Auto Mode) | Their own cluster |
| **RDS** | Sandbox-owned `db-pd-1` (postgres) | Their own RDS |
| **S3 object storage** | Sandbox-owned bucket | Theirs |
| **Domain + Route 53 zone** | `oryo-pd.click` registered in sandbox account | Their domain |
| **ACM cert** | Wildcard cert in sandbox, validated via sandbox Route 53 | Theirs |
| **ALBs, ingresses, DNS** | All sandbox-provisioned via Auto Mode | Theirs |
| **IAM + IRSA role for pods** | Sandbox role bound to ServiceAccount | Theirs |
| **K8s secrets** | Generated and stored only in sandbox cluster | Theirs |
| **Container images** | Pulled cross-account from Oryo prod ECR (`831...`) via repo policy granted by `grant-ecr-pull.sh` | **Same model** — Oryo grants their account pull access, they pull at deploy time |
| **Default tenant** | Created in their database by dbInit | Theirs |

### Cross-account ECR works as the canonical distribution path

The "Oryo as image distributor, customer pulls" model is proven:

```
Oryo prod ECR (831622638566)
        │
        │  ecr:BatchGetImage etc. granted to consumer accounts
        │  via scripts/grant-ecr-pull.sh
        ▼
Customer ECR pull at deploy time → Customer EKS pulls images
```

No image mirroring required. No tags rebuilt. Onboarding a new customer's account into the ECR allowlist is one idempotent script run from Oryo prod.

### The 3-step customer install actually works

What a customer types after `setup.sh` finishes:

```bash
cp values.example.yaml values.yaml
$EDITOR values.yaml   # fill in domain, ARNs, RDS endpoint
helm install oryo ./chart -n oryo --values values.yaml --wait --timeout 15m
```

No platform-source-code access required. No build step. No image push. They consume images Oryo publishes.

---

## Where we cut corners (sandbox only — fix before first paying customer)

### Distribution / chart

| Corner | Why it's "OK for sandbox" | Cost to fix |
|---|---|---|
| Chart hand-copied from `oryo-platform/packages/k8s-helm/chart/` into this repo | We control both repos, manual sync is fine for now | Set up CI to publish chart to OCI ECR on each `oryo-platform` release; customer does `helm pull oci://...` |
| Customer needs to clone this private GitHub repo | We can grant them collaborator access for now | Once stable: make repo public *or* publish only the artifacts (chart tarball + setup script + docs) |
| Chart's arch-affinity is "preferred" by default in upstream `oryo-platform`; sandbox uses a local-only patch making it "required" | Sandbox works; customer would silently get the wrong behavior | Land the chart fix as a PR on `oryo-platform`. Filed. |

### Configuration constraints in the platform

| Corner | Why it's "OK for sandbox" | Cost to fix |
|---|---|---|
| `ENV_NAME` must be `local | dev | stage | prod` (Zod enum). Sandbox uses `stage`. Customer's "acmecorp-prod" would be rejected | One of the 4 values is *good enough* for any single deployment. Crashes silently though — bad customer experience. | Loosen schema in `packages/shared/src/env.ts`. Audit branching on ENV_NAME. Filed. |
| Dashboard's "Installation" page hardcoded sensor API URL by `ENV_NAME` | Fixed in `oryo-platform` PR #373 (merged). Sandbox's values now set `API_BASE_URL` explicitly. | Done. |
| `dbInit` assumes `DB_DATABASE` exists. RDS only ships with `postgres` + `rdsadmin` by default. | `setup.sh` works around it by creating the DB via a one-shot psql pod. | Move the create-if-missing into `db-init`'s startup. Filed. |
| Resend is the only email provider. No `RESEND_API_KEY` = login codes never delivered. Sandbox reads them straight out of `login_events`. | Sandbox is single-user, we can SQL the code. Customer cannot. | Add SMTP / SES / pluggable email provider. Filed. |

### Operational / k8s quirks (Auto Mode-specific, surfaced via sandbox)

| Corner | Why it's "OK for sandbox" | Cost to fix |
|---|---|---|
| `setup.sh` patches the Auto Mode `general-purpose` NodePool to allow `arm64` (default is amd64 only) | Necessary for customer too — script does it, fully idempotent | Already in `setup.sh`. Document why prominently in customer-facing README. |
| `setup.sh` tags VPC public subnets with `kubernetes.io/role/elb=1` | Necessary for customer too — script does it | Same — already automated. |
| `alb.ingress.kubernetes.io/group.name` annotation didn't merge ingresses into a single ALB; we got 3 ALBs | Functional. Slightly more billing (~$60/mo for 2 extra ALBs). | Investigate why Auto Mode's controller didn't honor the group. Filed. |
| Database creation requires sandbox to have a one-shot pod that can reach RDS | Works fine inside the cluster | Belongs in dbInit; see above |

### Repo hygiene / process

| Corner | Why it's "OK for sandbox" | Cost to fix |
|---|---|---|
| `LICENSE.md` is a proprietary stub, not a real EULA | We control distribution for now | Legal review before any external distribution |
| `values.sandbox.yaml` (Oryo's reference deploy) is committed alongside the customer-facing `values.example.yaml` | Repo is private; sandbox doubles as our integration test | OK long-term; just be careful never to commit secrets here. `.env` (gitignored) holds the actual passwords |
| Runbook captures the gotchas but isn't yet structured as numbered manual steps a customer would follow on day 1 | Internal team can follow it | One pass to rewrite for a customer reading it cold; add screenshots of console steps |

---

## What it would take to onboard a real first customer

In order:

1. **Land the chart fixes upstream in `oryo-platform`:**
   - Strict arch affinity (`requiredDuringScheduling...`) gated by `global.nodeArchitectureStrict` (default true)
   - (Already merged) Configurable `API_BASE_URL` — PR #373
2. **Publish the chart as an OCI artifact on each `oryo-platform` release.** Push to ECR Public so anonymous `helm pull` works, OR keep private and customers pull via their granted IAM. Customer install line changes from `./chart` to `oci://...`.
3. **Fix dbInit to create `DB_DATABASE` if missing.** Removes `setup.sh`'s DB-creation block.
4. **Pluggable email provider** so customers don't need a Resend account. SMTP at minimum.
5. **Relax `ENV_NAME` enum** so customer names don't crash the platform.
6. **Real EULA from legal.**
7. **Polish the customer-facing README** with a 5-minute happy-path: install tools → SSO → setup.sh → values → helm install → DNS → smoke test. Optional: screenshots of console steps.

Estimated 2–4 weeks of focused work before this is comfortable to ship to a first paying customer. The longest items are #2 (publishing) and #4 (email), depending on how much email-provider abstraction we want.

---

## What ISN'T a corner

Worth being explicit about what looks suspicious but actually isn't:

- **Sandbox = Oryo-owned account, not external customer account.** Doesn't matter — AWS account boundaries are AWS account boundaries. No shared infra means no shared anything. The model is proven.
- **Sandbox pulls from Oryo prod ECR.** That IS the customer model. Production-equivalent.
- **`setup.sh` is bash, not Terraform.** AWS CLI is the lowest common denominator. Customers using Terraform / Pulumi / CDK can wrap it; nobody has to use what we picked.
- **EKS Auto Mode dependency in `setup.sh` (NodePool patch, IngressClass).** Setup script is honest: it checks for the NodePool before patching, skips if absent. For classic node groups customers, the manual ALB Controller install would be required — out of scope today, but the boundary is clear.

---

## TL;DR

**Sandbox proves the deployment model.** The work remaining is polish + safety nets for customers who aren't us. None of it is "this approach doesn't work."
