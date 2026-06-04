# Oryo Private Deployment — Internal

Oryo-only tooling and reference deployments for the private-deploy offering. Customers never see this directory.

## Contents

| Path | Purpose |
|---|---|
| `values.sandbox.yaml` | Reference deployment values for the Oryo sandbox at `app.oryo-pd.click` (AWS account `221759618824`). Treated as our integration test. |
| `scripts/grant-ecr-pull.sh` | Run from Oryo prod (`831622638566`) once per new customer to grant their AWS account pull access to image repos. Idempotent. |
| `docs/oryo-onboarding.md` | What Oryo does per-customer. Includes step-by-step rebuild of the sandbox. |
| `docs/readiness.md` | Honest accounting of what's customer-equivalent vs corners cut. Internal commentary — not for external distribution. |

## Typical Oryo flows

### Onboard a new customer

See [docs/oryo-onboarding.md](docs/oryo-onboarding.md). One-time per customer. Mostly just running `grant-ecr-pull.sh` and handing them the `customer/` directory.

### Rebuild the sandbox

See the "Reference: rebuilding the Oryo sandbox from scratch" section of [docs/oryo-onboarding.md](docs/oryo-onboarding.md). Used as our integration test before any chart change ships.

### Assess readiness

See [docs/readiness.md](docs/readiness.md) before promising customer milestones. Reflects ground truth, not aspirational state.

## Open work

Tracked in Linear under the [Private Deployment](https://linear.app/oryo/project/private-deployment-5c0bbd4ee8d5) project. Key items:

- ENG-101 — Automate backoffice strip on chart sync
- ENG-102 — Audit chart for Oryo-internal-only content before public OCI publish
- ENG-103 — Pre-first-customer punch list (chart, email, db-init, OCI, ENV_NAME, ALB group)
- ENG-104 — Split this repo into internal vs customer-facing
