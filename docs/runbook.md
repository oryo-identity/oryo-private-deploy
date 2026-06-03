# Sandbox / Private Deployment Bootstrap

How to bring up a fresh Oryo environment (the "private deployment" template). Covers what `helm install` does **not** — the surrounding AWS infra and one-time prep.

Example values throughout: account `221759618824`, region `us-east-2`, domain `oryo-pd.click`, cluster `cluster-pd-1`. Swap for the target environment.

---

## 0. AWS CLI access

Use SSO. One-time setup:

```bash
aws configure sso --profile sandbox
# SSO start URL = your Identity Center portal
# SSO region = wherever Identity Center lives (often us-east-1)
# pick the target account + role
# default region = us-east-2
```

Refresh whenever the token expires:

```bash
aws sso login --profile sandbox
```

Verify:

```bash
aws sts get-caller-identity --profile sandbox
# Account field must match the target sandbox account
```

---

## 1. Domain

Buy via Route 53. Console → Route 53 → Registered domains → Register domains. `.click` ~$3/yr is cheapest. Domain registration automatically creates the matching hosted zone in the same account. ICANN-required WHOIS contact uses privacy protection by default; billing follows the AWS account.

**Important:** register the domain in the **same AWS account** as the rest of the deployment. Cross-account DNS / cert validation is doable but painful.

---

## 2. ACM cert

```bash
aws acm request-certificate \
  --profile sandbox \
  --region us-east-2 \
  --domain-name '*.oryo-pd.click' \
  --subject-alternative-names 'oryo-pd.click' \
  --validation-method DNS
```

Validate ownership: console → Certificate Manager → us-east-2 → click cert → "Create records in Route 53" button. Wait ~5–10 min for status `ISSUED`.

Poll status:

```bash
aws acm describe-certificate \
  --profile sandbox --region us-east-2 \
  --certificate-arn <arn> \
  --query 'Certificate.Status'
```

---

## 3. EKS cluster

Out of scope here — assume the cluster exists. To confirm and connect:

```bash
aws eks list-clusters --profile sandbox --region us-east-2
aws eks update-kubeconfig --profile sandbox --region us-east-2 --name <cluster-name>
kubectl get nodes
```

Check cluster type. **If you see `nodeclaim/...` in pod events or `eks-auto-mode/compute`, the cluster is EKS Auto Mode.** Auto Mode includes a built-in load balancer controller, EBS CSI, and node provisioning — do NOT install AWS Load Balancer Controller manually; it crashes because Auto Mode nodes block IMDS.

For Auto Mode, just create the IngressClass that points at the built-in controller:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: eks.amazonaws.com/alb
EOF
```

For standard EKS (not Auto Mode), follow the official AWS Load Balancer Controller install guide.

---

## 4. S3 bucket (DEFAULT_BUCKET)

```bash
aws s3api create-bucket \
  --profile sandbox \
  --bucket oryo-sandbox-objects-221759618824-us-east-2 \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2
```

---

## 5. Workload IRSA role

App pods need S3 access. Create a namespace, IAM policy scoped to the bucket, and an IRSA-bound ServiceAccount.

```bash
kubectl create namespace oryo-sandbox

cat > /tmp/oryo-workload-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::oryo-sandbox-objects-221759618824-us-east-2",
      "arn:aws:s3:::oryo-sandbox-objects-221759618824-us-east-2/*"
    ]
  }]
}
EOF

aws iam create-policy \
  --policy-name OryoSandboxWorkloadPolicy \
  --policy-document file:///tmp/oryo-workload-policy.json

eksctl create iamserviceaccount \
  --cluster cluster-pd-1 \
  --namespace oryo-sandbox \
  --name oryo-platform-workload \
  --role-name OryoSandboxWorkloadRole \
  --attach-policy-arn arn:aws:iam::221759618824:policy/OryoSandboxWorkloadPolicy \
  --approve --region us-east-2

aws iam get-role --role-name OryoSandboxWorkloadRole --query 'Role.Arn' --output text
```

Save that ARN — goes into `values-sandbox.yaml` under `serviceAccount.annotations`.

---

## 6. K8s secrets

The Helm chart references these by name; they must exist in the namespace before `helm install`.

```bash
NS=oryo-sandbox

# Session secret (signs dashboard cookies)
kubectl -n $NS create secret generic oryo-session-secret \
  --from-literal=value="$(openssl rand -hex 32)"

# DB superuser (used only by the dbInit job)
kubectl -n $NS create secret generic oryo-db-admin \
  --from-literal=username=postgres \
  --from-literal=password='<the RDS master password>'

# Per-service role passwords (generated fresh; dbInit creates roles in Postgres)
for role in dashboard gateway worker; do
  kubectl -n $NS create secret generic oryo-db-$role \
    --from-literal=password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
done
```

---

## 7. Patch `values-<env>.yaml`

Replace placeholders (search for `REPLACE-` and `TODO`):

- IRSA role ARN (from step 5)
- ACM cert ARN (from step 2) — in 3 ingress blocks
- Domain (4 places: `DOMAIN`, `APP_BASE_URL`, 3 ingress hosts)
- S3 bucket name (from step 4) under `DEFAULT_BUCKET`

---

## 8. Helm install

```bash
helm install oryo packages/k8s-helm/chart \
  --namespace oryo-sandbox \
  --values packages/k8s-helm/values-sandbox.yaml
```

Watch:

```bash
kubectl -n oryo-sandbox get pods -w
```

`dbInit` runs as a hook first; runtime pods come up after it succeeds.

---

## 9. DNS records

After ALB is provisioned, point hostnames at it. Get the ALB hostname:

```bash
kubectl -n oryo-sandbox get ingress
```

Create CNAMEs in Route 53 for `app.<domain>`, `gateway.<domain>`, `api.<domain>` pointing at the ALB hostname. (Or install ExternalDNS to automate this.)

---

## Distributing chart + images to customers

For real private deployments (customer's own AWS account), they need to be able to pull both the Helm chart and the container images.

**Chart distribution — recommended: OCI via ECR Public**

```bash
helm package packages/k8s-helm/chart -d ./dist
helm push ./dist/oryo-platform-*.tgz oci://public.ecr.aws/oryo
```

Customer pulls: `helm install oryo oci://public.ecr.aws/oryo/oryo-platform --version 0.1.0 --values their-values.yaml`.

Alternatives: tarball on S3/GitHub Releases; private ECR with cross-account IAM grants; Helm HTTP repo.

**Image distribution — recommended: ECR Public for now**

Push release tags to `public.ecr.aws/oryo/{dashboard,gateway,api,workers,db-init}`. Anyone can pull, no auth. Customer sets `global.imageRegistry: public.ecr.aws/oryo` in their values file.

For security-conscious customers: document the "mirror to your own ECR" pattern (customer CI pulls public → tags → pushes private).

## Gotchas seen so far

- **Wrong AWS account via SSO.** `aws sts get-caller-identity` before every step. Cert/domain created in the wrong account = restart in the right one.
- **EKS Auto Mode masquerading as standard EKS.** Manual ALB controller install fails with `ec2imds GetMetadata` timeouts. Diagnosis: check pod events for `eks-auto-mode`.
- **Validation CNAMEs never created.** Requesting an ACM cert does not validate it — the "Create records in Route 53" console button is the missing step.
