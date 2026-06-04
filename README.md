# oryo-private-deploy

Deployment kit for running Oryo in a customer's own AWS account, plus the internal tooling Oryo uses to manage that offering.

This repo is split by audience:

```
oryo-private-deploy/
├── customer/    ← what customers see and run
└── internal/    ← Oryo-only: sandbox, onboarding scripts, candid docs
```

If you're inside Oryo working on the private-deploy story, read both. If you're a customer reading this, the answer is **[customer/README.md](customer/README.md)** — everything you need for your install lives there.

## What's in `customer/`

- `chart/` — the Helm chart customers install
- `values.example.yaml` — sanitized values template
- `scripts/setup.sh` — idempotent AWS + k8s prep (S3, IAM, IRSA, secrets, IngressClass, NodePool patching, subnet tagging)
- `docs/runbook.md` — end-to-end install steps + gotchas
- `LICENSE.md`, `.env.example`

## What's in `internal/`

- `values.sandbox.yaml` — Oryo's reference deployment values (sandbox AWS account)
- `scripts/grant-ecr-pull.sh` — run from Oryo prod to grant a new customer pull access to image repos
- `docs/oryo-onboarding.md` — what Oryo does per-customer; also rebuild instructions for the sandbox
- `docs/readiness.md` — honest accounting of what's customer-equivalent vs corners cut

## When syncing the chart from `oryo-platform`

The chart in `customer/chart/` is sourced from `oryo-platform/packages/k8s-helm/chart/` with one deliberate omission:

**`templates/backoffice/` and the `backoffice:` values block are stripped.**

Backoffice is Oryo's internal admin UI (auth gated by `@oryo.io` Google accounts) and is not shipped to customers. When syncing the chart, remove both. Eventually this will be automated by a CI publish step (see Linear ENG-101).

## License

See [customer/LICENSE.md](customer/LICENSE.md). Contact licensing@oryo.io.
