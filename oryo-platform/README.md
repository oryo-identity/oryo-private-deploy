# oryo-platform

Helm chart for the Oryo Platform. It deploys the dashboard, gateway, API, and
workers to a Kubernetes cluster (EKS Auto Mode, arm64), with TLS-terminated ALB
ingress and a customer-owned Postgres backend.

This chart is one piece of the [oryo-private-deploy](../README.md) kit. Read the
[runbook](../docs/runbook.md) for the end-to-end install and the
[prerequisites](../docs/prereqs.md) for the AWS-side setup that has to exist
first.

## Install

```bash
# from the repo root, after creating values.custom.yaml with your overrides
helm install oryo ./oryo-platform \
  --namespace oryo --create-namespace \
  --values oryo-platform/values.yaml \
  --values oryo-platform/values.custom.yaml \
  --wait --timeout 10m
```

The chart creates nothing in AWS. It assumes the S3 bucket, IRSA role, Bedrock
model access, subnet tags, arm64 NodePool, RDS database, and ACM cert already
exist. `../scripts/verify.sh` checks them, and the
[prerequisites doc](../docs/prereqs.md) explains how to provision them.

## Parameters

Full defaults and inline docs live in [`values.yaml`](values.yaml). Every
must-set value is flagged `# TODO`. Put overrides in `values.custom.yaml`
(gitignored) and layer it as the second `-f` to `helm install`. The values you
must provide:

| Key | Description | Source |
|---|---|---|
| `global.env.DOMAIN` | Your serving domain (`app/api/gateway.<DOMAIN>`) | you pick |
| `global.env.APP_BASE_URL` / `API_BASE_URL` | `https://app.<DOMAIN>` / `https://api.<DOMAIN>` | derived from DOMAIN |
| `global.env.DEFAULT_BUCKET` | S3 object-storage bucket | [prereqs §1](../docs/prereqs.md) |
| `global.db.host` / `database` | RDS endpoint + database name | [prereqs §6](../docs/prereqs.md) |
| `serviceAccount.annotations."eks.amazonaws.com/role-arn"` | IRSA workload role ARN | [prereqs §2](../docs/prereqs.md) / `verify.sh` output |
| `dashboard.ingress.host`, `gateway.ingress.host`, `api.ingress.host` | per-service subdomains | derived from DOMAIN |
| ACM cert ARN (ingress annotation) | wildcard `*.<DOMAIN>` cert | [prereqs §7](../docs/prereqs.md) |

Values with safe defaults you usually leave alone: `global.env.ENV_NAME`
(`stage`, the private-deploy value), and all `resources`, `replicas`,
`autoscaling`, `affinity`, `tolerations`, and `imageTag`.

Secrets (`oryo-session-secret`, `oryo-db-*`, `oryo-resend-api-key`) are
referenced by the chart but created out-of-band, either by `verify.sh
--bootstrap-secrets` or by your own secrets manager. See the
[runbook](../docs/runbook.md) secrets section.

## See also

- [Repository overview](../README.md)
- [Install runbook](../docs/runbook.md)
- [AWS prerequisites](../docs/prereqs.md)
- [Glossary](../docs/glossary.md)
