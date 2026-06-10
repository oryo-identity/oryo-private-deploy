# Oryo — Private Deployment

Deploy Oryo in your own AWS account + EKS cluster.

> **Status:** early — the install path works end-to-end but is still being hardened against multiple customer environments. Expect refinements until v1.0.

## What you get

A Helm chart ([`oryo-platform/`](oryo-platform/)) that runs the Oryo platform (dashboard, gateway, API, workers) inside your EKS cluster, pulling container images from Oryo's distribution registry, with TLS-terminated ingress and a Postgres backend you own.

## Repository layout

```
oryo-private-deploy/
├── oryo-platform/        ← the Helm chart (Chart.yaml, values.yaml, templates/)
├── values.example.yaml   ← starting-point values; copy to values.yaml and fill in
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

**Reading the diagram:**
- **Solid** arrows = always-on runtime traffic (admin → dashboard, sensor → gateway, pod → DB / S3). **Dotted** = once-per-event (image pull, login emails, installer fetch).
- The two-hop installer fetch — `sensor → api.<DOMAIN>` retrieves the install script, which signed-redirects to `Oryo S3`; the bytes come from Oryo's bucket directly.
- Each pod connects to RDS as its **own least-privilege Postgres role** (`oryo-dashboard` / `oryo-gateway` / `oryo-worker`); pod → S3 uses IRSA, no static AWS credentials. See [docs/glossary.md](docs/glossary.md#per-service-postgres-roles) for the per-role details the diagram leaves out.

## Prerequisites

This install kit **creates nothing in your AWS account.** You provision the AWS-side prerequisites yourself (per [docs/prereqs.md](docs/prereqs.md)); `verify.sh` then verifies they exist before install and prints the values you need to drop into `values.yaml`.

You provide:

- AWS account + EKS cluster (Auto Mode recommended) in a supported region
- Postgres database (RDS recommended) reachable from the cluster
- A domain you control, with a Route 53 hosted zone in the same AWS account
- An ACM certificate for `*.<your-domain>` in the same region as the cluster (terminates HTTPS at the ALBs)
- The AWS-side prerequisites in [docs/prereqs.md](docs/prereqs.md): S3 bucket, IAM policy + IRSA role (S3 + Bedrock), public-subnet tags, dedicated arm64 NodePool, Bedrock model access (Claude 3 Haiku + Nova Micro) enabled in the cluster's region
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
# 1. Provision the prerequisites in your AWS account per docs/prereqs.md
#    (or have Oryo provision them on your behalf).

# 2. Preflight — verifies the prereqs and (with the flag) creates the
#    5 required k8s secrets.
cp .env.example .env
$EDITOR .env
./scripts/verify.sh --bootstrap-secrets

# 3. Fill in the values template
cp values.example.yaml values.yaml
$EDITOR values.yaml         # domain, cert ARN, role ARN, RDS host, etc.

# 4. Install
helm install oryo ./oryo-platform \
  --namespace oryo --create-namespace \
  --values values.yaml \
  --wait --timeout 10m

# 5. Point DNS at the ALBs
kubectl -n oryo get ingress
# create CNAMEs in Route 53 for app/gateway/api → ALB hostname

# 6. Smoke test
curl -I https://app.<your-domain>/healthcheck
```

See [docs/runbook.md](docs/runbook.md) for the long form, including troubleshooting.

## What `verify.sh` does

It's a **preflight verifier** — by default it creates nothing in your AWS account, only checks. Run it before `helm install` against the `.env` you filled in.

Checks:

- Your `aws` profile is in the expected account, and `kubectl` is pointed at the right cluster
- The S3 object-storage bucket exists
- The IRSA workload role exists
- Bedrock model access (Claude 3 Haiku + Nova Micro) is enabled in your region
- Public subnets are tagged `kubernetes.io/role/elb=1`
- A schedulable arm64 NodePool exists (Auto Mode `general-purpose` is amd64-only by default — see prereqs.md §4)
- The 5 required k8s secrets exist in the target namespace

Each `✗` points at the relevant section of [docs/prereqs.md](docs/prereqs.md).

**Optional secret bootstrap.** Pass `--bootstrap-secrets` and the script generates + creates the 5 k8s secrets for you (session secret, `oryo-db-admin` from `.env`, three randomly-generated db-role passwords). Without the flag it only verifies they exist — bring your own (ESO, Vault, SealedSecrets, manual `kubectl`) if you prefer to manage secrets externally.

## License

Proprietary. See [LICENSE.md](LICENSE.md). Contact licensing@oryo.io.
