# Oryo — Private Deployment

Deploy Oryo in your own AWS account + EKS cluster.

> **Status:** early — the install path works end-to-end but is still being hardened against multiple customer environments. Expect refinements until v1.0.

## What you get

A Helm chart that runs the Oryo platform (dashboard, gateway, API, workers) inside your EKS cluster, pulling container images from Oryo's distribution registry, with TLS-terminated ingress and a Postgres backend you own.

## Prerequisites

You provide:

- AWS account
- EKS cluster (Auto Mode recommended) in a supported region
- Postgres database (RDS recommended) reachable from the cluster
- A domain you control, with a Route 53 hosted zone in the same AWS account
- An ACM certificate for `*.<your-domain>` in the same region as the cluster
- Oryo has added your AWS account ID to its ECR repository policies (contact your Oryo representative)

Tools on your machine:

- `aws` CLI (v2)
- `kubectl`
- `helm` (v3)
- `eksctl`
- `jq`
- `openssl`

## Quick start

```bash
# 1. Run the AWS prep — creates S3 bucket, IAM role, k8s namespace + secrets,
#    NodePool patch, subnet tags.
cp .env.example .env
$EDITOR .env
./scripts/setup.sh

# 2. Copy + edit the values template
cp values.example.yaml values.yaml
$EDITOR values.yaml          # fill in domain, cert ARN, role ARN, RDS host

# 3. Install
helm install oryo ./chart \
  --namespace oryo --create-namespace \
  --values values.yaml \
  --wait --timeout 15m

# 4. Point DNS at the ALBs
kubectl -n oryo get ingress
# create CNAMEs in Route 53 for app/gateway/api → ALB hostname

# 5. Smoke test
curl -I https://app.<your-domain>/healthcheck
```

See [docs/runbook.md](docs/runbook.md) for the long form, including troubleshooting.

## What `setup.sh` does

Codifies the imperative AWS prep so you don't have to re-discover it. Idempotent — safe to re-run.

- Creates the S3 object-storage bucket
- Creates a scoped IAM policy + IRSA role for the workload pods
- Creates the k8s namespace, ServiceAccount, and 5 required Secrets
- Bootstraps the target Postgres database
- Installs the `alb` IngressClass for EKS Auto Mode's built-in controller
- Patches the Auto Mode `general-purpose` NodePool to allow arm64
- Tags VPC public subnets for ALB auto-discovery

Reads from `.env` (see `.env.example`).

If you prefer your own IaC tool (Terraform / Pulumi / CDK), the AWS CLI commands inside `setup.sh` map 1:1 — wrap them in whatever shape your team uses.

## License

Proprietary. See [LICENSE.md](LICENSE.md). Contact licensing@oryo.io.
