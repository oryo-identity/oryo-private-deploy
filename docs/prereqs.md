# Prerequisites

Oryo's install kit creates nothing in your AWS account. The resources below need to exist before `helm install`. `verify.sh` then checks them and reports any gaps.

> Note: this doc is a guide for getting a green-field account to a working base state, with copy-pasteable CLI snippets that make reasonable choices for a first install. Most teams already run their own VPC, IRSA, and RDS conventions and will meet these requirements through their existing IaC. If that's you, treat this as reference: read the checklist at each section, confirm your setup meets the constraint, and skip the snippets.

Throughout, substitute:
- `<ACCOUNT_ID>` — your AWS account ID
- `<REGION>` — your cluster's region (e.g. `us-east-1`)
- `<CLUSTER_NAME>` — your EKS cluster name
- `<NAMESPACE>` — the k8s namespace you'll install into (e.g. `oryo`)
- `<BUCKET_NAME>` — a globally-unique S3 bucket name you pick
- `<DOMAIN>` — the domain you'll serve Oryo from (e.g. `oryo.example.com`)

The pods run as the `oryo-platform` ServiceAccount in `<NAMESPACE>` (set by `serviceAccount.name` in `values.yaml`). Keep it as `oryo-platform` so the IAM trust policy below matches.

---

## 1. S3 bucket (object storage)

A private bucket in your account and region. The workers and api store files here.

```bash
aws s3api create-bucket --bucket <BUCKET_NAME> --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION>
```

> Note: `us-east-1` is a historical S3 quirk. Omit `--create-bucket-configuration` entirely for that region. The CLI rejects `LocationConstraint=us-east-1`.

Put the name in `values.yaml` → `global.env.DEFAULT_BUCKET`.

---

## 2. IAM policy + role (IRSA for S3 + Bedrock)

The pods assume an IAM role via IRSA. You create the role. The Helm chart creates the matching k8s ServiceAccount and annotates it with the role ARN.

### 2a. Permission policy (S3 + Bedrock)

Two statements: one for the object-storage bucket, one for the Bedrock foundation models the agents call. The Bedrock action covers the `Converse` API used by every agent (`anthropic.claude-3-haiku-20240307-v1:0` and `amazon.nova-micro-v1:0`). See §5 for enabling model access in your account, which is separate from the IAM grant.

```bash
cat > /tmp/oryo-workload-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<BUCKET_NAME>",
        "arn:aws:s3:::<BUCKET_NAME>/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel", "bedrock:Converse"],
      "Resource": [
        "arn:aws:bedrock:<REGION>::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
        "arn:aws:bedrock:<REGION>::foundation-model/amazon.nova-micro-v1:0"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name OryoWorkloadPolicy \
  --policy-document file:///tmp/oryo-workload-policy.json
```

This prints the policy ARN (`arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy`). You'll plug it into §2b.

### 2b. IAM role with IRSA trust policy

The role needs a trust policy binding it to the `oryo-platform` ServiceAccount via your cluster's OIDC provider. There are two paths. Pick one.

#### Option A: eksctl (recommended)

`eksctl` looks up your cluster's OIDC issuer, builds the trust policy for you, creates the role, and attaches the policy, all in one command:

```bash
eksctl create iamserviceaccount \
  --cluster <CLUSTER_NAME> --region <REGION> \
  --namespace <NAMESPACE> --name oryo-platform \
  --role-only --role-name OryoWorkloadRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy \
  --approve
```

> Note: `--role-only` matters. The Helm chart creates the ServiceAccount itself. If eksctl creates one too, the trust policy ends up bound to the wrong SA name and IRSA breaks silently.

If your cluster doesn't have an IAM OIDC provider yet, `eksctl` will tell you. To create one:

```bash
eksctl utils associate-iam-oidc-provider --cluster <CLUSTER_NAME> --region <REGION> --approve
```

#### Option B: manual (no eksctl)

Get your cluster's OIDC issuer (drop the `https://`):

```bash
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.identity.oidc.issuer' --output text
# e.g. oidc.eks.us-east-1.amazonaws.com/id/ABCDEF0123...
```

Save the trust policy (substitute `<OIDC>` = that value without `https://`):

```bash
cat > /tmp/oryo-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/<OIDC>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<OIDC>:sub": "system:serviceaccount:<NAMESPACE>:oryo-platform",
        "<OIDC>:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role --role-name OryoWorkloadRole \
  --assume-role-policy-document file:///tmp/oryo-trust.json

aws iam attach-role-policy --role-name OryoWorkloadRole \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy
```

---

Put the role ARN in `values.yaml` → `serviceAccount.annotations.eks.amazonaws.com/role-arn`.

---

## 3. Tag public subnets for ALB discovery

EKS Auto Mode's load-balancer controller decides where to place ALBs by scanning the cluster's VPC for public subnets tagged `kubernetes.io/role/elb=1`. Without the tag, ingresses never get an address.

```bash
VPC_ID=$(aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

aws ec2 describe-subnets --region <REGION> \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text \
| xargs aws ec2 create-tags --region <REGION> \
    --tags Key=kubernetes.io/role/elb,Value=1 --resources
```

> Note: `xargs` splits on any whitespace (tabs included), and `--resources` accepts multiple subnet IDs, so this is a single `create-tags` call. It works in bash and zsh.

> Note: internal-only ALBs (no public traffic) use `kubernetes.io/role/internal-elb=1` on private subnets. Out of scope here.

---

## 4. Provide arm64 nodes

Oryo's images are arm64 (Graviton). EKS Auto Mode's default `general-purpose` NodePool only provisions amd64, so pods stay `Pending` until arm64 nodes are available.

Create a dedicated arm64 NodePool. Don't edit `general-purpose`. Auto Mode reconciles its built-in NodePools back to defaults, so a patch to `general-purpose` silently reverts (and your pods go `Pending` again later). A separate NodePool sticks:

```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: oryo-arm64
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
  limits:
    cpu: "1000"
EOF
```

> Note: using classic managed node groups instead of Auto Mode? Make sure at least one arm64 node group exists. You don't need a NodePool object.

---

## 5. Bedrock model access (per-region opt-in)

Bedrock foundation models are opt-in per account, per region, separate from the IAM grant in §2. Without it, agent calls fail with `AccessDeniedException` even when IAM is correct.

Several Oryo features call Bedrock from the gateway and workers (auto-classification of prompts and tool uses, active discovery of new LLM endpoints, the DLP policy function, the parser fallback, enrichment). They degrade silently if model access is missing: installs still succeed, the proxy still intercepts, and policies still match on regex/allowlist rules, but auto-tagging, discovery, and the DLP policy stop working. See [runbook.md → Bedrock-dependent features](runbook.md#bedrock-dependent-features) for the per-feature breakdown.

Models to enable (both must be on in `<REGION>`):

| Model | ID |
|---|---|
| Anthropic Claude 3 Haiku | `anthropic.claude-3-haiku-20240307-v1:0` |
| Amazon Nova Micro | `amazon.nova-micro-v1:0` |

Enable in the console: Bedrock → Model access in `<REGION>` → request the two models above. Anthropic models require a one-time use-case form (usually approved within minutes). Amazon models are instant.

Confirm afterwards:

```bash
aws bedrock list-foundation-models --region <REGION> \
  --query 'modelSummaries[?modelId==`anthropic.claude-3-haiku-20240307-v1:0` || modelId==`amazon.nova-micro-v1:0`].[modelId,modelLifecycle.status]' \
  --output table
```

Both rows should be `ACTIVE`. If a row is missing, the model isn't available in `<REGION>`. Pick a Bedrock-supported region, or set `global.env.AWS_REGION` in `values.yaml` to point the agents at a region that has them (IRSA still uses the cluster's STS endpoint; only the Bedrock SDK target moves).

> Note: `list-foundation-models` shows which models exist in the region rather than whether your account has opted in. The real check is a `bedrock-runtime invoke-model` call: if model access is missing you'll get `AccessDeniedException: You don't have access to the model with the specified model ID`. `verify.sh` runs a smoke call against Haiku 3 and reports the result.

---

## 6. Postgres database

Your RDS instance must:
- Be reachable from the cluster's VPC on port 5432 (the security group allows the cluster).
- Have the target database present. The default `postgres` database works, or create your own and set it in `values.yaml` → `global.db.database`.

You provide the endpoint (`global.db.host`) and master credentials (in `.env`, used once by the dbInit hook).

---

## 7. ACM certificate + Route 53 hosted zone

Each Oryo service is served over HTTPS at its own subdomain (`app.<DOMAIN>`, `api.<DOMAIN>`, `gateway.<DOMAIN>`). The ALBs terminate TLS using a wildcard ACM certificate you provide.

Requirements:

- A Route 53 hosted zone for `<DOMAIN>` in the same AWS account as the cluster, so the validation CNAME and subdomain records can be managed in place.
- A wildcard ACM certificate for `*.<DOMAIN>` in the same region as the cluster. ALBs can only use certs from their own region, unlike CloudFront, which requires `us-east-1`.

```bash
aws acm request-certificate \
  --domain-name '*.<DOMAIN>' \
  --validation-method DNS \
  --region <REGION>
```

Then add the DNS-validation CNAME that ACM gives you to your Route 53 zone. ACM uses it to verify domain ownership and to keep the cert renewable. The cert needs to reach status `ISSUED` (usually within a few minutes of the CNAME going live) before you install.

> Note: once the cert is `ISSUED`, copy the cert ARN into `values.yaml` under each ingress's `alb.ingress.kubernetes.io/certificate-arn` annotation. After `helm install`, you'll create CNAMEs in this same hosted zone pointing `app.<DOMAIN>` / `api.<DOMAIN>` / `gateway.<DOMAIN>` at the ALB hostnames. See [runbook.md §5](runbook.md#5-point-dns-at-the-albs).

---

When all of the above exist, run `./scripts/verify.sh`. It checks each one and tells you what's missing if anything isn't ready.
