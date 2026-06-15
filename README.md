# Oryo Private Deployment

Deploy Oryo in your own AWS account and EKS cluster.

> Status: early. The install path works end-to-end but is still being hardened across different customer environments. Expect changes before v1.0.

## What you get

A Helm chart ([`oryo-platform/`](oryo-platform/)) that runs the Oryo platform (dashboard, gateway, API, workers) inside your EKS cluster. It pulls container images from Oryo's distribution registry and runs against TLS-terminated ingress and a Postgres backend you own.

## Repository layout

```
oryo-private-deploy/
├── oryo-platform/        ← the Helm chart (Chart.yaml, values.yaml, templates/)
├── scripts/verify.sh      ← preflight verifier (creates nothing in AWS)
├── docs/
│   ├── prereqs.md        ← AWS-side prerequisites you provision before install
│   ├── runbook.md        ← end-to-end install steps + gotchas
│   └── glossary.md       ← terms + concepts
├── .env.example          ← verify.sh inputs
└── LICENSE.md
```

## Architecture

```mermaid
flowchart LR
    BROWSER([Admin browser])
    SENSOR([Endpoint sensor])

    subgraph CUST["Customer AWS account"]
        direction TB
        subgraph ING["3 ALBs · wildcard ACM cert"]
            direction TB
            ALB_APP[app.&lt;DOMAIN&gt;]
            ALB_API[api.&lt;DOMAIN&gt;]
            ALB_GW[gateway.&lt;DOMAIN&gt;]
        end
        PODS["<b>EKS Auto Mode · arm64 pods</b><br/>dashboard · api · gateway · workers"]
        DATA["<b>Data plane</b><br/>RDS Postgres · S3 object storage"]
        ING --> PODS --> DATA
    end

    subgraph EXTDEPS["External dependencies"]
        RESEND[(Resend SMTP)]
    end

    subgraph ORYO["Oryo · cross-account"]
        direction TB
        ECR[(ECR<br/>container images)]
        BIN[(S3<br/>sensor binaries)]
    end

    BROWSER --> ALB_APP
    SENSOR --> ALB_GW
    SENSOR -. installer fetch .-> ALB_API
    SENSOR -. installer bytes .-> BIN
    PODS -. login emails .-> RESEND
    PODS -. image pull .-> ECR

    classDef cust fill:#f0fff4,stroke:#3a7a4a,color:#0a3a1a
    classDef oryo fill:#fff5e6,stroke:#9c6b1d,color:#3a2a0a
    classDef ext fill:#eef0ff,stroke:#4a5fa5,color:#1a2a5a
    class CUST,ING cust
    class ORYO oryo
    class EXTDEPS ext
```

## Prerequisites

- EKS cluster (Auto Mode recommended)
- Postgres database (RDS recommended)
- A domain you control, with a Route 53 hosted zone in the same AWS account
- An ACM certificate for `*.<your-domain>` in the same region as the cluster (terminates HTTPS at the ALBs)
- The AWS-side resources in [docs/prereqs.md](docs/prereqs.md):
    - S3 bucket
    - IAM policy + IRSA role (S3 + Bedrock)
    - public-subnet tags
    - dedicated arm64 NodePool
    - Bedrock model access (Claude 3 Haiku + Nova Micro)
- Oryo's account ID grant to its ECR repository policies. Contact your Oryo rep if your AWS account hasn't been provisioned access to the ECR images yet.

## Quick start

```bash
# 1. Provision the prerequisites in your AWS account per docs/prereqs.md
#    (or have Oryo provision them on your behalf).

# 2. Preflight: verify the prereqs and (with the flag) create the
#    5 required k8s secrets.
cp .env.example .env
$EDITOR .env
./scripts/verify.sh

# 3. Override what you need to (domain, cert ARN, role ARN, RDS host, etc.)
$EDITOR oryo-platform/values.custom.yaml   # gitignored; create with just your overrides

# 4. Install
helm install oryo ./oryo-platform \
  --namespace oryo --create-namespace \
  --values oryo-platform/values.yaml \
  --values oryo-platform/values.custom.yaml \
  --atomic --cleanup-on-fail --wait --timeout 10m

# 5. Point DNS at the ALBs
kubectl -n oryo get ingress
# create CNAMEs in Route 53 for app/gateway/api → ALB hostname
```

See [docs/runbook.md](docs/runbook.md) for the long form, including troubleshooting.

## License

Proprietary. See [LICENSE.md](LICENSE.md). Contact info@oryo.io.
