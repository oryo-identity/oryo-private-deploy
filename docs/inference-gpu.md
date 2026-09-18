# GPU inference service (PII scanning)

The optional `inference` service runs the model behind the PII scan policy function. It detects PII and PHI in prompts and files by content, inline, as they pass through the gateway.

It is off by default (`inference.enabled: false`) and is the only component that needs special hardware: one amd64 node with an NVIDIA GPU. Everything else in the chart runs on the arm64 pool. Without it the platform works normally and PII scan rules simply do not fire (see [Fail-open behavior](#fail-open-behavior)).

## Why a GPU

The gateway holds the intercepted request while the model scans it, so a scan has a budget of a few hundred milliseconds. On a T4 GPU a 250-word scan takes about 80 ms. On CPU the same scan takes several seconds. There is no CPU fallback: a pod without a working GPU never becomes Ready.

Measured on `g4dn.xlarge` (NVIDIA T4):

| Input size | GPU | CPU (same box) |
|---|---|---|
| 15 words (typical prompt) | 13 ms | 1.4 s |
| 80 words | 23 ms | 2.2 s |
| 250 words (file chunk) | 79 ms | 5.7 s |

Model load takes about 5 s at boot, VRAM use is about 3.5 GB, and throughput is about 12 scans/s. One `g4dn.xlarge` is the sizing baseline. Any NVIDIA instance in the g4dn, g5, or g6 families with at least 4 GB VRAM works.

## What you will set up

1. A GPU NodePool or node group: one amd64 NVIDIA node, labeled and tainted for this workload.
2. `inference.enabled: true` in `values.custom.yaml`, then `helm upgrade`.

The chart wires the gateway to the service. The model ships inside the image, so there is no model download and no extra S3 access. The image uses the same GHCR pull token as the rest of the platform. It is several GB (CUDA runtime plus the model), so the first pull takes a few minutes.

## 1. Provide a GPU node

The inference pod schedules onto nodes labeled `oryo.io/role: gpu` and tolerates the taint `oryo.io/workload=gpu:NoSchedule`. The taint keeps other workloads off the GPU node. The label and an amd64 affinity keep the pod off the arm64 pool.

### EKS Auto Mode (recommended)

Create a dedicated NodePool, same pattern as `oryo-arm64` in [prereqs.md §4](prereqs.md):

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

Auto Mode GPU AMIs include the NVIDIA driver and device plugin, so nothing else is needed for `nvidia.com/gpu` to be schedulable. The `limits.nvidia.com/gpu: "1"` cap keeps this NodePool at one GPU. Raise it if you run more replicas.

No node appears when you apply this. Karpenter provisions the instance when the inference pod first goes Pending, which takes 2 to 3 minutes.

### Classic managed node groups

Without Auto Mode you need three things:

1. A node group with a GPU AMI (`AL2023_x86_64_NVIDIA`), instance type `g4dn.xlarge`, the label `oryo.io/role: gpu`, and the taint `oryo.io/workload=gpu:NoSchedule`.
2. The [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin), which advertises `nvidia.com/gpu` to the scheduler:
   ```bash
   helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
   helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
     --namespace kube-system \
     --set-json 'tolerations=[{"key":"oryo.io/workload","operator":"Exists","effect":"NoSchedule"},{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'
   ```
   The extra toleration matters. The plugin only tolerates the `nvidia.com/gpu` taint by default, so without it the plugin never lands on the tainted node and the node never advertises a GPU.
3. If you run the cluster autoscaler with the group scaled to zero, tag the ASG so a pending GPU pod can scale it up.

### Self-hosted clusters

The classic path applies to any Kubernetes ([on-prem-runbook.md](on-prem-runbook.md)): an amd64 node with an NVIDIA GPU, the driver on the host, the device plugin, and the same label and taint applied with `kubectl label node` and `kubectl taint node`. PII scanning makes no external calls, so it works in fully on-prem installs. Mirror the `inference` image like the others.

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

Use the longer timeout for this first upgrade. It covers GPU node provisioning plus the large image pull.

Enabling the flag deploys the inference Deployment and Service (ClusterIP only, never exposed through ingress) and sets `ORYO_INFERENCE_URL` on the gateway to the in-cluster service. To point the gateway somewhere else, set `gateway.env.ORYO_INFERENCE_URL` yourself and the chart leaves it alone.

Defaults under `inference:` in the chart's `values.yaml`: 1 replica, 1 to 2 CPU, 3 to 4 Gi memory, 1 GPU, a startup probe that allows about 5 minutes for model load, and an in-place rolling update so an upgrade never needs a second GPU node.

### Optional: shared auth token

The service is ClusterIP only, so the network is the gate by default. To also require a bearer token, set the same value on both sides:

```yaml
gateway:
  env:
    ORYO_INFERENCE_TOKEN: '<random>'
inference:
  env:
    ORYO_INFERENCE_TOKEN: '<random>'
```

## 3. Verify

Watch the rollout. Expect `0/1 Running` while the model loads. The healthcheck returns 503 until the model is ready.

```bash
kubectl -n <NAMESPACE> get pods -l app.kubernetes.io/component=inference -w
```

Once Ready, test the scan endpoint:

```bash
kubectl -n <NAMESPACE> port-forward svc/oryo-oryo-platform-inference 8080:80 &
curl -s localhost:8080/healthcheck
# {"status":"ok"}
curl -s -X POST localhost:8080/v1/detect \
  -H 'content-type: application/json' \
  -d '{"text":"Contact Maria Alvarez at maria.alvarez@example.com or 555-0142.","labels":["first_name","last_name","email","phone_number"]}'
# {"detections":[...],"scanned":1,"total":1,"incomplete":false}
```

Then try it from the dashboard: create a policy rule with the PII scan function, pick the PII types to detect, send a prompt containing PII through a monitored AI endpoint, and confirm the violation appears.

## Fail-open behavior

If the service is disabled, still loading, or unreachable, the gateway logs a warning and allows the request. A scanning outage never blocks AI traffic. Other policy rules on the same request still apply.

The gateway log line when scans are skipped:

```
pii_scan skipped, request allowed (fail-open): inference service unreachable at http://...
```

If you see this while the inference pod is Ready, check that the gateway's `ORYO_INFERENCE_URL` matches the service name in your namespace.

Two consequences:

- During an upgrade or node drain there is a short window (model load, about a minute on a warm node) where scans are skipped. Run 2 replicas on 2 GPU nodes if you need continuity.
- Scans are bounded (default 8 chunks or 5 s per request). Oversized files are partially scanned and flagged `incomplete`. The rule's "Flag Partially Checked Files" option, on by default, controls whether that counts as a risk.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `Pending`, no node appears | No node source matches. The NodePool or node group is missing, or lacks the `oryo.io/role: gpu` label. Check `kubectl describe pod` events. |
| Pod `Pending` on a running GPU node | `nvidia.com/gpu` is not advertised. If `kubectl describe node <gpu-node> \| grep nvidia` shows no capacity, the device plugin is missing or not tolerating the taint. |
| `ImagePullBackOff` | If only inference fails, your pull token predates the service. Ask Oryo for a new one. A slow first pull is normal. |
| Never Ready, healthcheck 503 | The pod has a GPU but the CUDA session failed. `kubectl logs` shows the error. Usually a non-NVIDIA AMI on a classic node group. |
| Scans return 429 `scan queue full` | Load beyond one GPU. Add a replica and a GPU node. |
| Rules never fire, no warnings | The PII scan rule has no PII types selected. Pick types or a preset in the rule editor. |

## Cost

One `g4dn.xlarge` on demand is about $0.53/hr (about $385/mo) in us-east-1. There is no per-scan cost. The pod holds the model resident, so it does not scale to zero. To stop paying, set `inference.enabled: false` and delete the NodePool.
