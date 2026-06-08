# Reference & Onboarding

Oryo's reference deployment and the onboarding mechanics for the private-deployment offering. These complement the customer install flow in [`../customer/`](../customer/).

## Contents

| Path | Purpose |
|---|---|
| `docs/prereq-setup.md` | How to set up the AWS-side prerequisites (domain, ACM cert, EKS cluster, RDS) that [`customer/docs/runbook.md`](../customer/docs/runbook.md) assumes already exist. Useful if you're building an environment from scratch. |
| `docs/oryo-onboarding.md` | The one-time access grant Oryo performs to authorize your AWS account to pull the container images, plus a worked end-to-end example. |
| `scripts/grant-ecr-pull.sh` | The script Oryo runs (from its registry account) to grant a consumer AWS account pull access to the image repos. Idempotent. Included for transparency. |
| `values.sandbox.yaml` | A complete, working reference `values` file (Oryo's own sandbox deployment) — a concrete example alongside the sanitized [`customer/values.example.yaml`](../customer/values.example.yaml). |

## How onboarding works

1. Oryo grants your AWS account pull access to the image registry (`grant-ecr-pull.sh`).
2. You follow [`customer/docs/runbook.md`](../customer/docs/runbook.md) in your own account.
3. If you're standing up the prerequisite infrastructure from scratch (domain, cert, cluster, RDS), [`docs/prereq-setup.md`](docs/prereq-setup.md) walks through it.

See `docs/oryo-onboarding.md` for the full picture.
