# Prerequisites — what needs to exist in your AWS account

Oryo's install kit **creates nothing in your AWS account**. The resources below need to exist before `helm install` — `setup.sh` then verifies them and prints any gaps.

> **NOTE:** This doc is a **helpful guide to get a green-field account to a base state**, with copy-pasteable CLI snippets that make sane choices for a first install. Most teams already run their own VPC / IRSA / RDS conventions and will satisfy these requirements through their existing IaC. If that's you, treat this as context — read the checklist at each section, confirm your setup meets the constraint, and skim past the snippets.

Throughout, substitute:
- `<ACCOUNT_ID>` — your AWS account ID
- `<REGION>` — your cluster's region (e.g. `us-east-1`)
- `<CLUSTER_NAME>` — your EKS cluster name
- `<NAMESPACE>` — the k8s namespace you'll install into (e.g. `oryo`)
- `<BUCKET_NAME>` — a globally-unique S3 bucket name you pick
- `<DOMAIN>` — the domain you'll serve Oryo from (e.g. `oryo.example.com`)

The ServiceAccount the pods run as is `oryo-platform` in `<NAMESPACE>` (set by `serviceAccount.name` in `values.yaml` — keep it as `oryo-platform` so the IAM trust policy below matches).

---

## 1. S3 bucket (object storage)

A private bucket in your account + region. The workers/api store files here.

```bash
aws s3api create-bucket --bucket <BUCKET_NAME> --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION>
```

> **NOTE:** `us-east-1` is a historical S3 quirk — omit `--create-bucket-configuration` entirely for that region; the CLI rejects `LocationConstraint=us-east-1`.

Put the name in `values.yaml` → `global.env.DEFAULT_BUCKET`.

---

## 2. IAM policy + role (IRSA — lets the pods reach the bucket)

The pods assume an IAM role via IRSA. You create the **role**; the Helm chart creates the matching k8s ServiceAccount and annotates it with the role ARN.

### 2a. Permission policy — S3 access scoped to your bucket

```bash
cat > /tmp/oryo-workload-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::<BUCKET_NAME>",
      "arn:aws:s3:::<BUCKET_NAME>/*"
    ]
  }]
}
EOF

aws iam create-policy \
  --policy-name OryoWorkloadPolicy \
  --policy-document file:///tmp/oryo-workload-policy.json
```

This prints the policy ARN (`arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy`); you'll plug it into §2b.

### 2b. IAM role with IRSA trust policy

The role needs a trust policy binding it to the `oryo-platform` ServiceAccount via your cluster's OIDC provider. Two paths — **pick one**:

#### Option A — eksctl (recommended, one command)

`eksctl` looks up your cluster's OIDC issuer, builds the trust policy below for you, creates the role, and attaches the policy — in a single command:

```bash
eksctl create iamserviceaccount \
  --cluster <CLUSTER_NAME> --region <REGION> \
  --namespace <NAMESPACE> --name oryo-platform \
  --role-only --role-name OryoWorkloadRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy \
  --approve
```

> **NOTE:** `--role-only` is important — the Helm chart creates the ServiceAccount itself. If eksctl creates one too, the trust policy ends up bound to the wrong SA name and IRSA breaks silently.

If your cluster doesn't have an IAM OIDC provider yet, `eksctl` will tell you. To create one:

```bash
eksctl utils associate-iam-oidc-provider --cluster <CLUSTER_NAME> --region <REGION> --approve
```

#### Option B — manual (no eksctl)

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

EKS Auto Mode's load-balancer controller finds where to place ALBs by scanning the cluster's VPC for public subnets tagged `kubernetes.io/role/elb=1`. Without the tag, ingresses never get an address.

```bash
VPC_ID=$(aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

aws ec2 describe-subnets --region <REGION> \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text \
| xargs aws ec2 create-tags --region <REGION> \
    --tags Key=kubernetes.io/role/elb,Value=1 --resources
```

> **NOTE:** `xargs` splits on any whitespace (tabs included), and `--resources` accepts multiple subnet IDs — so this is one `create-tags` call. Works in bash and zsh.

> **NOTE:** Internal-only ALBs (no public traffic) use `kubernetes.io/role/internal-elb=1` on private subnets — out of scope here.

---

## 4. Provide arm64 nodes

Oryo's images are arm64 (Graviton). EKS Auto Mode's default `general-purpose` NodePool only provisions amd64, so pods stay `Pending` until arm64 nodes are available.

**Create a dedicated arm64 NodePool** — do *not* edit `general-purpose`. Auto Mode reconciles its built-in NodePools back to defaults, so a patch to `general-purpose` silently reverts (and your pods go `Pending` again later). A separate NodePool is durable:

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

> **NOTE:** Using classic managed node groups instead of Auto Mode? Ensure at least one arm64 node group exists; you don't need a NodePool object.

---

## 5. Postgres database

Your RDS instance must:
- Be reachable from the cluster's VPC on port 5432 (security group allows the cluster).
- Have the target database present — the default `postgres` database works; or create your own and name it in `values.yaml` → `global.db.database`.

You provide the endpoint (`global.db.host`) and master credentials (in `.env`, used once by the dbInit hook).

---

## 6. ACM certificate + Route 53 hosted zone

Each Oryo service is served over HTTPS at its own subdomain (`app.<DOMAIN>`, `api.<DOMAIN>`, `gateway.<DOMAIN>`). The ALBs terminate TLS using a **wildcard ACM certificate** you provide.

**Requirements:**

- A **Route 53 hosted zone** for `<DOMAIN>` in the same AWS account as the cluster (so the validation CNAME and subdomain records can be managed in-place).
- A **wildcard ACM certificate for `*.<DOMAIN>`** in the **same region as the cluster** (ALBs can only use certs from their own region — unlike CloudFront, which requires `us-east-1`).

```bash
aws acm request-certificate \
  --domain-name '*.<DOMAIN>' \
  --validation-method DNS \
  --region <REGION>
```

Then add the DNS-validation CNAME ACM tells you about to your Route 53 zone — ACM uses it to verify domain ownership and to keep the cert renewable. The cert needs to reach status `ISSUED` (typically within a few minutes of the CNAME being live) before you install.

> **NOTE:** Once the cert is `ISSUED`, copy the cert ARN into `values.yaml` under each ingress's `alb.ingress.kubernetes.io/certificate-arn` annotation. After `helm install`, you'll create CNAMEs in this same hosted zone pointing `app.<DOMAIN>` / `api.<DOMAIN>` / `gateway.<DOMAIN>` at the ALB hostnames — see [runbook.md §5](runbook.md#5-point-dns-at-the-albs).

---

When all of the above exist, run `./scripts/setup.sh` — it verifies each one and tells you exactly what's missing if anything isn't ready.
