# oryo-private-deploy

Deployment kit for running Oryo in a customer's own AWS account.

**Start with [customer/README.md](customer/README.md)** — everything you need for your install lives there.

## What's in `customer/`

- `chart/` — the Helm chart customers install
- `values.example.yaml` — sanitized values template
- `scripts/setup.sh` — preflight verifier (creates nothing in AWS; optionally bootstraps k8s secrets)
- `docs/prereqs.md` — the AWS-side prerequisites customers provision before install
- `docs/runbook.md` — end-to-end install steps + gotchas
- `LICENSE.md`, `.env.example`

## License

See [customer/LICENSE.md](customer/LICENSE.md). Contact licensing@oryo.io.
