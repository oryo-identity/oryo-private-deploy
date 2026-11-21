# Prerequisites

Oryo's install kit creates nothing in your AWS account. The resources below need to exist before `helm install`. `verify.sh` then checks them and reports any gaps.

> Note: this doc is a guide for getting a green-field account to a working base state, with copy-pasteable CLI snippets that make reasonable choices for a first install. Most teams already run their own VPC, IRSA, and RDS conventions and will meet these requirements through their existing IaC. If that's you, treat this as reference: read the checklist at each section, confirm your setup meets the constraint, and skip the snippets.

Throughout, substitute:
- `<ACCOUNT_ID>`: your AWS account ID
- `<REGION>`: your cluster's region (e.g. `us-east-1`)
- `<CLUSTER_NAME>`: your EKS cluster name
- `<NAMESPACE>`: the k8s namespace you'll install into (e.g. `oryo`)
- `<BUCKET_NAME>`: a globally-unique S3 bucket name you pick
- `<DOMAIN>`: the domain you'll serve Oryo from (e.g. `oryo.example.com`)

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

> Bringing your own LLM ([byo-llm.md](byo-llm.md))? Drop the Bedrock statement from §2a and skip §5.

The pods assume an IAM role via IRSA. You create the role. The Helm chart creates the matching k8s ServiceAccount and annotates it with the role ARN.

### 2a. Permission policy (S3 + Bedrock)

Two statements: one for the object-storage bucket, one for the Bedrock models the agents call. By default the agents call two US cross-region inference profiles:

- `us.anthropic.claude-haiku-4-5-20251001-v1:0` (Claude Haiku 4.5) for every agent. Set `DEFAULT_LLM` to change it.
- `us.anthropic.claude-opus-5` (Claude Opus 5) for the inference validator, which judges newly discovered AI traffic. Set `SMART_LLM` to change it.

An inference profile is a model ID that Bedrock routes to any of several regions. Calling one needs two grants: the profile itself in `<REGION>`, and the underlying foundation model in every region the profile can route to. From `us-east-1`, `us-east-2` or `us-west-2`, these profiles route to those same three regions. From `us-west-1` or Canada they also route to the source region. The policy below uses `*` for the foundation-model region so it covers every case. `bedrock:InvokeModel` also authorizes the `Converse` API the agents use.

If you set `DEFAULT_LLM` or `SMART_LLM`, grant those IDs instead. If your cluster isn't in a US or Canada region, the `us.` profiles can't be called from it. Pick the matching profile for your geography (e.g. `eu.anthropic.claude-haiku-4-5-20251001-v1:0`) or point `global.env.AWS_REGION` at a US region.

See §5 for model access in your account, which is separate from the IAM grant.

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
      "Action": ["bedrock:InvokeModel"],
      "Resource": [
        "arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:<REGION>:<ACCOUNT_ID>:inference-profile/us.anthropic.claude-opus-5",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-5"
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

## 5. Bedrock model access (one-time per account)

Bedrock model access is separate from the IAM grant in §2. Without it, agent calls fail with `AccessDeniedException` even when IAM is correct.

Several Oryo features call Bedrock from the gateway and workers (auto-classification of prompts and tool uses, active discovery of new LLM endpoints, the DLP policy function, the parser fallback, enrichment). They degrade silently if model access is missing: installs still succeed, the proxy still intercepts, and policies still match on regex/allowlist rules, but auto-tagging, discovery, and the DLP policy stop working. See [runbook.md → AI-dependent features](runbook.md#ai-dependent-features) for the per-feature breakdown.

Models the agents call by default (both must work from `<REGION>`):

| Model | Inference profile ID | Foundation model ID | Override with |
|---|---|---|---|
| Anthropic Claude Haiku 4.5 | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | `anthropic.claude-haiku-4-5-20251001-v1:0` | `DEFAULT_LLM` |
| Anthropic Claude Opus 5 | `us.anthropic.claude-opus-5` | `anthropic.claude-opus-5` | `SMART_LLM` |

If you set `DEFAULT_LLM` or `SMART_LLM` under `global.env`, enable those models instead.

In commercial AWS regions there is no per-model request to submit. Access takes two one-time steps per AWS account:

1. Submit Anthropic's use-case form. In the Bedrock console, open either model from the Model catalog, or go to the Anthropic provider page, and fill in the form. It's needed once per account, or once in your organization's management account. It's usually approved within minutes.
2. Make one call to each model as an admin. The first call subscribes the account to the model through AWS Marketplace. That call needs `aws-marketplace:Subscribe` and `aws-marketplace:ViewSubscriptions`, which the Oryo role from §2 doesn't have. After that, the Oryo role can call the model with `bedrock:InvokeModel` alone. Opening each model in the console playground works, or run this as an admin:

```bash
for m in us.anthropic.claude-haiku-4-5-20251001-v1:0 us.anthropic.claude-opus-5; do
  aws bedrock-runtime converse --region <REGION> --model-id "$m" \
    --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
    --query 'output.message.content[0].text' --output text
done
```

Each line should print a short reply. In AWS GovCloud the console's Model access page still applies: enable both models there instead.

Confirm afterwards:

```bash
for m in anthropic.claude-haiku-4-5-20251001-v1:0 anthropic.claude-opus-5; do
  aws bedrock get-foundation-model-availability --region <REGION> --model-id "$m" \
    --query '[modelId,agreementAvailability.status]' --output text
done
```

Both rows should say `AVAILABLE`. `PENDING` means the use-case form is still being processed; calls fail until it clears. If the converse call says the model ID is invalid, the `us.` profiles aren't served from `<REGION>`. Use your geography's profile (see §2a), or set `global.env.AWS_REGION` in `values.yaml` to a US region (IRSA still uses the cluster's STS endpoint; only the Bedrock SDK target moves).

> Note: the two `AccessDeniedException` messages point at different fixes. `User is not authorized to perform: bedrock:InvokeModel` is the IAM policy in §2a. `You don't have access to the model with the specified model ID` is model access in this section.

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

## 8. GPU node for PII scanning (optional)

Only needed if you enable the inference service: one amd64 NVIDIA GPU node (`g4dn.xlarge` is the baseline), labeled `oryo.io/role: gpu` and tainted `oryo.io/workload=gpu:NoSchedule`, provisioned as a dedicated NodePool like the arm64 one in §4. The NodePool spec, the classic node group alternative, sizing, and cost are in [docs/inference-gpu.md](inference-gpu.md). `verify.sh` does not check this one.

---

When all of the above exist, run `./scripts/verify.sh`. It checks each one (except the optional §8) and tells you what's missing if anything isn't ready.
