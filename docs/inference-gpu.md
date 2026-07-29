# GPU inference service (PII scanning)

How to spin up the optional `inference` service in a private deployment. It serves the ML model behind the **PII scan** policy function: a GLiNER-based PII/PHI detector that scans prompts and files inline, as they pass through the gateway.

It is the one component with special hardware needs — everything else in the chart runs on the arm64 pool, this runs on a single NVIDIA GPU node. It's disabled by default (`inference.enabled: false`), and the platform is fully functional without it: PII-scan policy rules simply don't fire (see [Fail-open behavior](#fail-open-behavior)). Enable it when you want DLP rules that detect PII/PHI by content rather than by regex.

---

## Why a GPU

PII scanning runs inline: the gateway holds the intercepted request while the model scans it, so the scan budget is a couple hundred milliseconds. On a T4 GPU a 250-word scan completes in about 80 ms (p95); the same scan on CPU takes several seconds — orders of magnitude past the budget. There is deliberately **no CPU fallback**: a pod without a GPU never becomes Ready rather than silently serving 30× slower scans.

Measured on `g4dn.xlarge` (NVIDIA T4), real model artifact:

| Input size | GPU | CPU (same box) |
|---|---|---|
| 15 words (typical prompt) | 13 ms | 1.4 s |
| 80 words | 23 ms | 2.2 s |
| 250 words (file chunk) | 79 ms | 5.7 s |

Model load takes ~5 s at boot, VRAM footprint is ~3.5 GB, and throughput is ~12 scans/s serialized. One `g4dn.xlarge` (~$0.53/hr on-demand in us-east-1) is the sizing baseline; any NVIDIA instance of the g4dn/g5/g6 families with ≥4 GB VRAM works.

## What you'll set up

1. A GPU NodePool (or node group) — one amd64 NVIDIA node, labeled and tainted for this workload.
2. `inference.enabled: true` in `values.custom.yaml`, then `helm upgrade`.
3. Nothing else — the chart wires the gateway to the service automatically, and the model is baked into the image (no model download, no extra S3 access).

The image is pulled with the same Oryo GHCR token as the rest of the platform. Note it is much larger than the other images (several GB — CUDA runtime plus the embedded model), so the first pull takes a few minutes.

---

## 1. Provide a GPU node

The inference pod schedules onto nodes carrying the label `oryo.io/role: gpu` and tolerates the taint `oryo.io/workload=gpu:NoSchedule`. The taint keeps general workloads off the (expensive) GPU node; the label and an amd64 affinity keep the pod off your arm64 pool. You create a node source that matches.

### EKS Auto Mode (recommended)

Create a dedicated NodePool, same pattern as the `oryo-arm64` one from [prereqs.md §4](prereqs.md):

```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: oryo-gpu
spec:
  template:
    metadata:
      labels:
        oryo.io/role: gpu
    spec:
      taints:
        - key: oryo.io/workload
          value: gpu
          effect: NoSchedule
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: eks.amazonaws.com/instance-family
          operator: In
          values: ["g4dn", "g5", "g6"]
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
  limits:
    nvidia.com/gpu: "1"
EOF
```

Auto Mode's GPU-capable AMIs ship the NVIDIA driver and device plugin — you don't install anything for `nvidia.com/gpu` to be schedulable. The `limits.nvidia.com/gpu: "1"` cap is a cost guard: this NodePool can never scale past one GPU. Raise it if you later run more replicas.

No node appears when you apply this — Karpenter provisions the instance on demand, when the inference pod first goes Pending (2–3 minutes).

### Classic managed node groups

Without Auto Mode you need three things the Auto Mode path gives you for free:

1. A node group with a GPU AMI (driver included) and the same label + taint:
   - AMI type: `AL2023_x86_64_NVIDIA`
   - Instance type: `g4dn.xlarge`
   - Label `oryo.io/role: gpu`, taint `oryo.io/workload=gpu:NoSchedule`
2. The [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin), which advertises `nvidia.com/gpu` to the scheduler:
   ```bash
   helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
   helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
     --namespace kube-system \
     --set-json 'tolerations=[{"key":"oryo.io/workload","operator":"Exists","effect":"NoSchedule"},{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
   ```
   The extra toleration matters: the plugin's default only tolerates the `nvidia.com/gpu` taint, so without it the plugin DaemonSet can't land on the tainted GPU node and the node never advertises a GPU.
3. If you run the cluster autoscaler with the group scaled to zero, tag the ASG so a pending GPU pod can scale it up (`k8s.io/cluster-autoscaler/enabled`, plus the taint/label resource tags).

### Self-hosted / on-prem clusters

The classic path above generalizes to any Kubernetes ([on-prem-runbook.md](on-prem-runbook.md)): an amd64 node with an NVIDIA GPU, the NVIDIA driver on the host, the device plugin (step 2), and the same label + taint applied with `kubectl label node` / `kubectl taint node`. Unlike the Bedrock-backed AI features, PII scanning makes no external calls — the model ships inside the image — so it works in Fully on-prem installs (mirror the `inference` image like the others).

## 2. Enable the service

In `values.custom.yaml`:

```yaml
inference:
  enabled: true
```

Then upgrade as usual (see [runbook.md §4](runbook.md#4-install-from-the-registry)):

```bash
helm upgrade --install oryo \
  oci://<registry-host>/charts/oryo-platform --version <version> \
  --namespace <NAMESPACE> \
  -f values.custom.yaml \
  --atomic --cleanup-on-fail --wait --timeout 15m
```

Bump the timeout for this first upgrade: it covers GPU node provisioning (2–3 min) plus the large image pull (a few minutes).

Enabling the flag does two things: deploys the inference Deployment/Service (ClusterIP-only, never exposed via ingress), and injects `ORYO_INFERENCE_URL` into the gateway pointing at the in-cluster service. If you need to point the gateway elsewhere (e.g. a shared GPU cluster), set `gateway.env.ORYO_INFERENCE_URL` yourself — the chart then leaves it alone.

Defaults you can override under `inference:` (see the chart's `values.yaml` for the full list): 1 replica, `Guaranteed`-ish resources (1–2 CPU / 3–4 Gi / 1 GPU), a startup probe that allows ~5 minutes for model load, and a rolling-update strategy of `maxSurge: 0` — an upgrade replaces the pod in place instead of requiring a second GPU node.

### Optional: shared auth token

The service is ClusterIP-only, so the network is the gate by default. To also require a bearer token (e.g. under stricter network policies), set the same value on both sides:

```yaml
gateway:
  env:
    ORYO_INFERENCE_TOKEN: '<random>'
inference:
  env:
    ORYO_INFERENCE_TOKEN: '<random>'
```

## 3. Verify

Watch the rollout — expect `0/1 Running` for a bit while the model loads (the healthcheck returns 503 until the model is ready; the pod is never Ready while unable to scan):

```bash
kubectl -n <NAMESPACE> get pods -l app.kubernetes.io/component=inference -w
```

Once Ready, smoke-test the scan endpoint from your machine:

```bash
kubectl -n <NAMESPACE> port-forward svc/oryo-oryo-platform-inference 8080:80 &
curl -s localhost:8080/healthcheck
# {"status":"ok"}
curl -s -X POST localhost:8080/v1/detect \
  -H 'content-type: application/json' \
  -d '{"text":"Contact Maria Alvarez at maria.alvarez@example.com or 555-0142.","labels":["first_name","last_name","email","phone_number"]}'
# {"detections":[...email + name + phone hits...],"scanned":1,"total":1,"incomplete":false}
```

Then use it from the dashboard: create a policy rule with the **PII scan** function (pick the PII types to detect — presets exist for GDPR special categories and PHI), send a prompt containing PII through a monitored AI endpoint, and confirm the violation appears.

## Fail-open behavior

PII scanning fails open by design: if the service is disabled, unready, or unreachable, the gateway logs a warning and **allows the request** — a scanning outage must not take down AI traffic. Other policy rules on the same request still apply.

What that looks like in gateway logs when scans are being skipped:

```
pii_scan skipped, request allowed (fail-open): inference service unreachable at http://...
```

If you see this while the inference pod claims to be Ready, check the gateway's `ORYO_INFERENCE_URL` matches the service name in your namespace.

Consequences worth knowing:

- During an upgrade or node drain there's a brief window (model load, ~1 min on a warm node) where scans are skipped. With 1 replica that's accepted; run 2 replicas on 2 GPU nodes if you need scan continuity.
- Scans are bounded (default: 8 chunks / 5 s per request). Oversized files are partially scanned and flagged `incomplete`; the PII-scan rule's "Flag Partially Checked Files" option (on by default) controls whether that counts as a risk.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `Pending`, no node appears | No node source matches: NodePool/node group missing, or missing the `oryo.io/role: gpu` label. Check `kubectl describe pod` events. |
| Pod `Pending` on a running GPU node | `nvidia.com/gpu` not advertised: `kubectl describe node <gpu-node> \| grep nvidia` shows no capacity → device plugin missing or not tolerating the taint (classic node groups, see §1). |
| `ImagePullBackOff` | Same GHCR token/secret as other services — if only inference fails, your token predates the service; ask Oryo for a refreshed one. Also: slow first pull is normal (several GB), distinguish from a real failure. |
| Ready never reached, healthcheck 503 forever | The pod has a GPU but the CUDA session failed — `kubectl logs` will show the ORT error. Most common on classic node groups with a non-NVIDIA AMI (no driver). |
| Scans return 429 `scan queue full` | Sustained load beyond one GPU's throughput (~12 scans/s). Add a replica + GPU node. |
| Rules never fire, no warnings | The PII-scan rule has no PII types selected — nothing is selected by default; pick types or a preset in the rule editor. |

## Cost

The single default node is the entire marginal cost: one `g4dn.xlarge` on-demand ≈ **$0.53/hr (~$385/mo)** in us-east-1. There is no per-scan cost — the model runs on your node. Scale-to-zero isn't supported by the service itself (the pod holds the model resident); to stop paying, set `inference.enabled: false` and delete the NodePool.
