# oryo-private-deploy

Deployment kit for running Oryo in a customer's own AWS account, plus the internal tooling Oryo uses to manage that offering.

This repo is organized as:

```
oryo-private-deploy/
├── customer/    ← the install kit: chart, setup script, values template, runbook
└── internal/    ← reference deployment + onboarding mechanics
```

**Start with [customer/README.md](customer/README.md)** — everything you need for your install lives there. `internal/` holds a working reference configuration and the onboarding details.

## What's in `customer/`

- `chart/` — the Helm chart customers install
- `values.example.yaml` — sanitized values template
- `scripts/setup.sh` — idempotent AWS + k8s prep (S3, IAM, IRSA, secrets, IngressClass, NodePool patching, subnet tagging)
- `docs/runbook.md` — end-to-end install steps + gotchas
- `LICENSE.md`, `.env.example`

## What's in `internal/`

- `values.sandbox.yaml` — a complete, working reference `values` file
- `scripts/grant-ecr-pull.sh` — the access grant Oryo runs to authorize your account to pull images
- `docs/oryo-onboarding.md` — how the image-access grant works, with a worked example
- `docs/prereq-setup.md` — building the prerequisite AWS infrastructure (domain, cert, cluster, RDS) from scratch

## License

See [customer/LICENSE.md](customer/LICENSE.md). Contact licensing@oryo.io.
