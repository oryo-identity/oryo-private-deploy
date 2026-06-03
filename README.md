# Oryo — Private Deployment

Deploy Oryo in your own AWS account + EKS cluster.

> **Status:** early — this repo is the source of truth for the private-deployment story but is still being hardened against multiple customer environments. Expect breaking changes until v1.0.

## What you get

A Helm chart that runs the Oryo platform (dashboard, gateway, API, workers) inside your EKS cluster, pulling container images from Oryo's distribution registry, with TLS-terminated ingress and a Postgres backend you own.

## Prerequisites

You provide:

- AWS account
- EKS cluster (Auto Mode recommended) in a supported region
- Postgres database (RDS recommended) reachable from the cluster
- A domain you control, with a Route 53 hosted zone in the same AWS account
- An ACM certificate for `*.<your-domain>` in the same region as the cluster
- Oryo has added your AWS account ID to its ECR repository policies (contact licensing@oryo.io)

Tools on your machine:

- `aws` CLI (v2)
- `kubectl`
- `helm` (v3)
- `eksctl` (only if not using your own IaC for IAM)

## Quick start (5 commands)

```bash
# 1. Run the AWS prep — creates S3 bucket, IAM role, k8s namespace + secrets
./scripts/setup.sh

# 2. Copy + edit the values template
cp values.example.yaml values.yaml
$EDITOR values.yaml          # fill in domain, cert ARN, role ARN, RDS host

# 3. Add Oryo's chart repo (OCI) and pull the chart
helm registry login public.ecr.aws  # if not already cached
helm pull oci://831622638566.dkr.ecr.us-east-1.amazonaws.com/oryo-platform --version <X.Y.Z>

# 4. Install
helm install oryo ./oryo-platform-<X.Y.Z>.tgz \
  --namespace oryo --create-namespace \
  --values values.yaml

# 5. Point DNS at the ALB
kubectl -n oryo get ingress
# create CNAMEs in Route 53 for app/gateway/api → ALB hostname
```

See [docs/runbook.md](docs/runbook.md) for the long form, including troubleshooting.

## What `setup.sh` does

Codifies the imperative AWS prep so each customer doesn't re-discover it:

- Creates the S3 object-storage bucket
- Creates a scoped IAM policy + IRSA role for the workload
- Creates the k8s namespace, ServiceAccount, and the 5 required Secrets
- Installs the `alb` IngressClass

Idempotent — safe to re-run. Reads from `.env` (see `.env.example`).

If you prefer your own IaC tool (Terraform / Pulumi / CDK), see [docs/setup-via-iac.md](docs/setup-via-iac.md) — the AWS CLI commands map 1:1.

## License

Proprietary. See [LICENSE.md](LICENSE.md). Contact licensing@oryo.io.
