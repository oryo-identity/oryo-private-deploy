# Prerequisites — what you create in your AWS account

Oryo's install kit **creates nothing in your AWS account**. You provision these resources yourself (console, CLI, Terraform — your choice), and `setup.sh` verifies they exist before install. This doc gives the exact specs.

Throughout, substitute:
- `<ACCOUNT_ID>` — your AWS account ID
- `<REGION>` — your cluster's region (e.g. `us-east-1`)
- `<CLUSTER_NAME>` — your EKS cluster name
- `<NAMESPACE>` — the k8s namespace you'll install into (e.g. `oryo`)
- `<BUCKET_NAME>` — a globally-unique S3 bucket name you pick

The ServiceAccount the pods run as is `oryo-platform` in `<NAMESPACE>` (set by `serviceAccount.name` in `values.yaml` — keep it as `oryo-platform` so the IAM trust policy below matches).

---

## 1. S3 bucket (object storage)

A private bucket in your account + region. The workers/api store files here.

```bash
aws s3api create-bucket --bucket <BUCKET_NAME> --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION>
```
(us-east-1 omits `--create-bucket-configuration`.)

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

### 2b. Trust policy — only the Oryo ServiceAccount can assume it

Requires an IAM OIDC provider associated with your cluster. If you don't have one:
```bash
eksctl utils associate-iam-oidc-provider --cluster <CLUSTER_NAME> --region <REGION> --approve
```

Get your cluster's OIDC issuer (drop the `https://`):
```bash
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.identity.oidc.issuer' --output text
# e.g. oidc.eks.us-east-1.amazonaws.com/id/ABCDEF0123...
```

Trust policy (`<OIDC>` = that value without `https://`):
```json
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
```

### Easiest path (if you use eksctl) — role only, no ServiceAccount

```bash
eksctl create iamserviceaccount \
  --cluster <CLUSTER_NAME> --region <REGION> \
  --namespace <NAMESPACE> --name oryo-platform \
  --role-only --role-name OryoWorkloadRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/OryoWorkloadPolicy \
  --approve
```
`--role-only` is important — the Helm chart creates the ServiceAccount itself.

Put the role ARN in `values.yaml` → `serviceAccount.annotations.eks.amazonaws.com/role-arn`.

---

## 3. Tag public subnets for ALB discovery

EKS Auto Mode's load-balancer controller finds where to place ALBs by scanning the cluster's VPC for public subnets tagged `kubernetes.io/role/elb=1`. Without the tag, ingresses never get an address.

```bash
VPC_ID=$(aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region <REGION> \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text)

aws ec2 create-tags --region <REGION> --resources $PUBLIC_SUBNETS \
  --tags Key=kubernetes.io/role/elb,Value=1
```

(Internal-only ALBs use `kubernetes.io/role/internal-elb=1` on private subnets — out of scope here.)

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

(Classic managed node groups instead of Auto Mode? Ensure at least one arm64 node group exists.)

---

## 5. Postgres database

Your RDS instance must:
- Be reachable from the cluster's VPC on port 5432 (security group allows the cluster).
- Have the target database present — the default `postgres` database works; or create your own and name it in `values.yaml` → `global.db.database`.

You provide the endpoint (`global.db.host`) and master credentials (in `.env`, used once by the dbInit hook).

---

## ACM certificate + domain

Covered in [runbook.md](runbook.md) prerequisites — a wildcard ACM cert for `*.<your-domain>` and a Route 53 hosted zone in this account.

---

When all of the above exist, run `./scripts/setup.sh` — it verifies each one and tells you exactly what's missing if anything isn't ready.
