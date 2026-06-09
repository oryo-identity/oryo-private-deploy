# Oryo — Private Deployment

Deploy Oryo in your own AWS account + EKS cluster.

> **Status:** early — the install path works end-to-end but is still being hardened against multiple customer environments. Expect refinements until v1.0.

## What you get

A Helm chart that runs the Oryo platform (dashboard, gateway, API, workers) inside your EKS cluster, pulling container images from Oryo's distribution registry, with TLS-terminated ingress and a Postgres backend you own.

## Architecture

```mermaid
flowchart LR
    BROWSER([Admin browser])
    SENSOR([Endpoint sensor])

    subgraph CUST["Customer AWS account"]
        direction TB
        ING["<b>3 ALBs</b> · wildcard ACM cert<br/>app.&lt;DOMAIN&gt; · api.&lt;DOMAIN&gt; · gateway.&lt;DOMAIN&gt;"]
        PODS["<b>EKS Auto Mode · arm64 pods</b><br/>dashboard · api · gateway · workers"]
        DATA["<b>Data plane</b><br/>RDS Postgres · S3 object storage"]
        ING --> PODS --> DATA
    end

    subgraph THIRD["Third-party + Oryo distribution"]
        direction TB
        RESEND[(Resend SMTP)]
        ECR[(Oryo ECR<br/>container images)]
        BIN[(Oryo S3<br/>sensor binaries)]
    end

    BROWSER --> ING
    SENSOR --> ING
    PODS -. image pull .-> ECR
    PODS -. login emails .-> RESEND
    SENSOR -. installer download .-> BIN

    classDef cust fill:#f0fff4,stroke:#3a7a4a,color:#0a3a1a
    classDef third fill:#fff5e6,stroke:#9c6b1d,color:#3a2a0a
    class CUST cust
    class THIRD third
```

**Reading the diagram:**
- Solid arrows = always-on runtime traffic. Dotted = once-per-event (image pull at pod start, login email send, sensor installer fetch).
- The "installer download" dotted line is the simplification of a two-hop: device fetches the install script from `api.<DOMAIN>`, which signed-redirects to Oryo's sensor-binaries S3. Bytes come from Oryo's bucket.
- Each pod connects to RDS as its **own least-privilege Postgres role** (`oryo-dashboard` / `oryo-gateway` / `oryo-worker`); pod → S3 uses IRSA, no static AWS credentials. See [customer/docs/glossary.md](docs/glossary.md#per-service-postgres-roles) for the details left out of the diagram.

## Prerequisites

This install kit **creates nothing in your AWS account.** You provision the AWS-side prerequisites yourself (per [customer/docs/prereqs.md](docs/prereqs.md)); `setup.sh` then verifies they exist before install and prints the values you need to drop into `values.yaml`.

You provide:

- AWS account + EKS cluster (Auto Mode recommended) in a supported region
- Postgres database (RDS recommended) reachable from the cluster
- A domain you control, with a Route 53 hosted zone in the same AWS account
- An ACM certificate for `*.<your-domain>` in the same region as the cluster (terminates HTTPS at the ALBs)
- The AWS-side prerequisites in [customer/docs/prereqs.md](docs/prereqs.md): S3 bucket, IAM policy + IRSA role, public-subnet tags, dedicated arm64 NodePool
- Oryo has added your AWS account ID to its ECR repository policies (contact your Oryo rep if your AWS account has not been provisioned access to our ECR images)

Tools on your machine:

- `aws` CLI (v2)
- `kubectl`
- `helm` (v3)
- `jq`
- `openssl` (only for `--bootstrap-secrets`)
- `eksctl` (only for the easy-path IRSA setup in prereqs.md §2b)

## Quick start

```bash
# 1. Provision the prerequisites in your AWS account per customer/docs/prereqs.md
#    (or have Oryo provision them on your behalf).

# 2. Preflight — verifies the prereqs and (with the flag) creates the
#    5 required k8s secrets.
cp .env.example .env
$EDITOR .env
./scripts/setup.sh --bootstrap-secrets

# 3. Fill in the values template
cp values.example.yaml values.yaml
$EDITOR values.yaml         # domain, cert ARN, role ARN, RDS host, etc.

# 4. Install
helm install oryo ./chart \
  --namespace oryo --create-namespace \
  --values values.yaml \
  --wait --timeout 10m

# 5. Point DNS at the ALBs
kubectl -n oryo get ingress
# create CNAMEs in Route 53 for app/gateway/api → ALB hostname

# 6. Smoke test
curl -I https://app.<your-domain>/healthcheck
```

See [customer/docs/runbook.md](docs/runbook.md) for the long form, including troubleshooting.

## What `setup.sh` does

It's a **preflight verifier** — by default it creates nothing in your AWS account, only checks. Run it before `helm install` against the `.env` you filled in.

Checks:

- Your `aws` profile is in the expected account, and `kubectl` is pointed at the right cluster
- The S3 object-storage bucket exists
- The IRSA workload role exists
- Public subnets are tagged `kubernetes.io/role/elb=1`
- A schedulable arm64 NodePool exists (Auto Mode `general-purpose` is amd64-only by default — see prereqs.md §4)
- The 5 required k8s secrets exist in the target namespace

Each `✗` points at the relevant section of [customer/docs/prereqs.md](docs/prereqs.md).

**Optional secret bootstrap.** Pass `--bootstrap-secrets` and the script generates + creates the 5 k8s secrets for you (session secret, `oryo-db-admin` from `.env`, three randomly-generated db-role passwords). Without the flag it only verifies they exist — bring your own (ESO, Vault, SealedSecrets, manual `kubectl`) if you prefer to manage secrets externally.

## License

Proprietary. See [LICENSE.md](LICENSE.md). Contact licensing@oryo.io.
