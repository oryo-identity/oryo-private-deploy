# Reference & Onboarding

Oryo's reference deployment and the onboarding mechanics for the private-deployment offering. These complement the customer install flow in [`../customer/`](../customer/).

## Contents

| Path | Purpose |
|---|---|
| `internal/docs/prereq-setup.md` | How to set up the AWS-side prerequisites (domain, ACM cert, EKS cluster, RDS) that [`customer/docs/runbook.md`](../customer/docs/runbook.md) assumes already exist. Useful if you're building an environment from scratch. |
| `internal/docs/oryo-onboarding.md` | The one-time access grant Oryo performs to authorize your AWS account to pull the container images, plus a worked end-to-end example. |
| `scripts/grant-ecr-pull.sh` | The script Oryo runs (from its registry account) to grant a consumer AWS account pull access to the image repos. Idempotent. Included for transparency. |
| `scripts/provision.sh` | The mutating counterpart to `customer/scripts/setup.sh` — creates the AWS prerequisites (bucket, IAM policy + IRSA role with S3 + Bedrock, subnet tags, NodePool arm64) and probes Bedrock model access. Oryo uses it to stand up the sandbox or to provision on a customer's behalf. Each step maps 1:1 to a section of `customer/docs/prereqs.md`, with the rationale inline. Bedrock model access itself stays a console step — there's no public API to grant it. |

## How onboarding works

1. Oryo grants your AWS account pull access to the image registry (`grant-ecr-pull.sh`).
2. You follow [`customer/docs/runbook.md`](../customer/docs/runbook.md) in your own account.
3. If you're standing up the prerequisite infrastructure from scratch (domain, cert, cluster, RDS), [`internal/docs/prereq-setup.md`](docs/prereq-setup.md) walks through it.

See `internal/docs/oryo-onboarding.md` for the full picture.
