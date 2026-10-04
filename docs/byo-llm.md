# Bring your own LLM (LiteLLM)

Oryo's AI features call an LLM. That covers prompt and tool classification, DLP scanning, OTP-use detection, active discovery, and parser fallback. By default they call AWS Bedrock through the chart's IRSA role (see [prereqs.md §2 and §5](prereqs.md)).

Use this guide when you'd rather use your own models: Azure OpenAI, Google Vertex AI, the Anthropic API, or a model you host yourself. Oryo then sends every LLM call to a [LiteLLM](https://github.com/BerriAI/litellm) proxy that you run next to the chart. LiteLLM translates each call for your provider. You need no AWS account.

> Requires chart version **0.1.20** or later.

## How it fits

```
gateway / dashboard / workers  ──OpenAI format──▶  LiteLLM (your pod)  ──▶  your models
                                 + LiteLLM key                         (Azure, Vertex, Anthropic, self-hosted)
```

Oryo asks for two model names, and LiteLLM maps each one to a real model:

| Name Oryo asks for | Used by | Suggested model |
|---|---|---|
| `oryo-default` (`DEFAULT_LLM`) | every agent except one | a small, fast model (e.g. Claude Haiku 4.5, GPT-4o mini, Gemini Flash) |
| `oryo-smart` (`SMART_LLM`) | the inference validator, which judges newly discovered AI traffic | a stronger model (e.g. Claude Opus 5, GPT-4o, Gemini Pro) |

If you set only `DEFAULT_LLM`, that one model serves every agent.

## What has to exist

You write no code. The setup is all configuration. When you're done, these exist in the Oryo namespace:

| Object | Contents | Source |
|---|---|---|
| Secret `litellm-secrets` | `LITELLM_MASTER_KEY` (a password you make up) plus your provider's keys | Your secrets manager, or step 2 |
| ConfigMap `litellm-config` | Your model list, as `config.yaml` | A `models-*.yaml` file in [`examples/litellm/`](../examples/litellm/), edited |
| Deployment and Service `litellm` | The LiteLLM proxy on port 4000 | [`examples/litellm/litellm.yaml`](../examples/litellm/litellm.yaml) |
| Oryo chart values | `LLM_PROVIDER`, `LITELLM_BASE_URL`, `DEFAULT_LLM`, `SMART_LLM`, and the `LITELLM_API_KEY` secret ref | Your `values.custom.yaml` (step 5) |

Steps 2 and 3 create these with kubectl. If you manage the cluster with Helm, ArgoCD or Terraform, put the same manifest and secret there instead, so a rebuild brings LiteLLM back. Steps 4 and 6 are checks and use kubectl either way.

This takes about an hour for someone who installs things on Kubernetes regularly. Getting model access approved inside your cloud often takes longer than the setup itself.

**Already run an LLM gateway** (LiteLLM or another one that speaks the OpenAI format)? Skip to [step 5](#5-point-oryo-at-litellm) and use your gateway's URL, key, and model names.

---

## 1. Get model access in your provider

| Provider | What you need |
|---|---|
| Azure OpenAI | An Azure OpenAI resource, a deployment for each model, and its API key |
| Google Vertex AI | Vertex AI enabled in your project, and a Google service account that can call it, bound to the LiteLLM pod's Kubernetes ServiceAccount with GKE Workload Identity |
| Anthropic API | An API key created **inside a workspace** in console.anthropic.com. A key that isn't tied to a workspace is rejected. |
| Self-hosted | A running vLLM (or other OpenAI-format) server reachable from the cluster |

Pick the matching model list in [`examples/litellm/`](../examples/litellm/): `models-azure.yaml`, `models-vertex.yaml`, `models-anthropic.yaml`, or `models-self-hosted.yaml`. Edit the deployment or model names to yours.

## 2. Create the LiteLLM secret

The master key is a password you make up. LiteLLM checks it on every call, and Oryo sends it. Add your provider's values to the same secret, using the names in your model list's header comment.

Example for Anthropic. `read -s` keeps the key out of your shell history:

```bash
read -s "PROVIDER_KEY?Anthropic API key: " && echo
kubectl -n <NS> create secret generic litellm-secrets \
  --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)" \
  --from-literal=ANTHROPIC_API_KEY="$PROVIDER_KEY"
unset PROVIDER_KEY
```

For Azure, add `AZURE_API_KEY`, `AZURE_API_BASE` and `AZURE_API_VERSION` instead. For Vertex, add `VERTEXAI_PROJECT` and `VERTEXAI_LOCATION`.

## 3. Deploy LiteLLM

Load your model list, then apply the Deployment and Service. `$SA` is the Kubernetes ServiceAccount the LiteLLM pod runs as. Use the chart's (`oryo-platform`) unless your cloud identity is bound to a different one.

```bash
kubectl -n <NS> create configmap litellm-config --from-file=config.yaml=examples/litellm/models-anthropic.yaml
sed "s/__SERVICE_ACCOUNT__/$SA/" examples/litellm/litellm.yaml | kubectl -n <NS> apply -f -
kubectl -n <NS> rollout status deploy/litellm --timeout 5m
```

The logs should list both model names:

```bash
kubectl -n <NS> logs deploy/litellm | grep -A2 "Set models"
```

## 4. Test LiteLLM from inside the cluster

This calls LiteLLM from a gateway pod, on the same network path Oryo uses. The gateway image has no `curl`, so it uses Node's `fetch`.

```bash
KEY=$(kubectl -n <NS> get secret litellm-secrets -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
kubectl -n <NS> exec deploy/oryo-oryo-platform-gateway -- node -e '
fetch("http://litellm:4000/v1/chat/completions", {
  method: "POST",
  headers: { authorization: "Bearer " + process.argv[1], "content-type": "application/json" },
  body: JSON.stringify({ model: "oryo-default", messages: [{ role: "user", content: "Reply with the word ok" }] }),
}).then(async (r) => console.log(r.status, await r.text()))' "$KEY"
```

Expect `200` and an answer that says "ok". Any other result names the problem. See [Troubleshooting](#troubleshooting).

## 5. Point Oryo at LiteLLM

Add to your `values.custom.yaml`:

```yaml
global:
  env:
    LLM_PROVIDER: litellm
    LITELLM_BASE_URL: http://litellm:4000/v1
    DEFAULT_LLM: oryo-default
    SMART_LLM: oryo-smart
  externalSecrets:
    LITELLM_API_KEY:
      secretName: litellm-secrets
      key: LITELLM_MASTER_KEY
```

Then `helm upgrade` as usual, and check the pods picked it up:

```bash
kubectl -n <NS> exec deploy/oryo-oryo-platform-gateway -- printenv LLM_PROVIDER LITELLM_BASE_URL DEFAULT_LLM SMART_LLM
```

If `LITELLM_BASE_URL` or `DEFAULT_LLM` is missing, the pods refuse to start and their logs name the missing setting.

Other settings, only if you need them:

| Setting | Default | Set when |
|---|---|---|
| `LITELLM_JSON_MODE` | `json_schema` | Your gateway rejects `response_format: json_schema`. Try `json_object`, then `none`. |
| `LITELLM_TIMEOUT_MS` | `60000` | Your models are slow and calls time out. |
| `LITELLM_HEADERS` | none | Your gateway needs extra headers, as a JSON object, e.g. an API-management subscription key. Put it in `externalSecrets` if it carries a key. |

## 6. Check it end to end

Run the self-check in a gateway pod. It sends known examples through each agent and fails if any answer is wrong or an agent falls back to its default:

```bash
kubectl -n <NS> exec deploy/oryo-oryo-platform-gateway -- node llm-check.cjs
```

Expect `All checks passed`. Then send a few prompts through a sensor. LiteLLM's log shows `POST /v1/chat/completions ... 200`, and this prints nothing:

```bash
for p in $(kubectl -n <NS> get pods -o name | grep -E 'gateway|workers|dashboard'); do
  kubectl -n <NS> logs $p --since 1h | grep -E "did not match the schema|Error invoking agent|LLM endpoint returned"
done
```

---

## Troubleshooting

| You see | Cause | Fix |
|---|---|---|
| Pods crash: `LITELLM_BASE_URL: required` or `DEFAULT_LLM: required` | A setting from step 5 is missing or misspelled | Fix `values.custom.yaml`, then `helm upgrade` |
| `ENOTFOUND litellm` | LiteLLM Service missing, or in another namespace | `kubectl -n <NS> get svc litellm`, or use `http://litellm.<ns>.svc.cluster.local:4000/v1` |
| `ECONNREFUSED` | LiteLLM pod not ready | `kubectl -n <NS> get pods -l app=litellm`, then its logs |
| `401` | Oryo's key doesn't match LiteLLM's master key | Both must read `litellm-secrets` / `LITELLM_MASTER_KEY`. Then restart the Oryo pods. |
| `400` naming a model | `DEFAULT_LLM` or `SMART_LLM` isn't a `model_name` in the model list | Names must match exactly |
| `400` from Anthropic: `not scoped to a workspace` | The key isn't tied to a workspace | Create the key inside a workspace (step 1) |
| Provider errors about the key or permissions | Provider access not granted, or the wrong key | Check step 1. For Vertex, check the Workload Identity binding on `$SA`. |
| `reply did not match the schema` on every call | Your gateway or model ignores the JSON format request | Set `LITELLM_JSON_MODE` to `json_object`, then `none` |
| Pod rejected: `violates PodSecurity` | The namespace requires non-root pods; the stock LiteLLM image runs as root | Run LiteLLM in a namespace that allows it and use its full Service name in `LITELLM_BASE_URL` |
| A model list edit has no effect | Pods don't restart when a ConfigMap changes | `kubectl -n <NS> rollout restart deploy/litellm` |

When LiteLLM is down, Oryo keeps running. Each call is retried, then the agents fall back to their defaults and log the error. Regex and allowlist policy rules keep matching. See [runbook.md → AI-dependent features](runbook.md#ai-dependent-features).

## Switching back to Bedrock

Remove `LLM_PROVIDER` (or set it to `bedrock`) and `helm upgrade`. Bedrock then needs the IRSA permissions and model access from [prereqs.md](prereqs.md). Remove LiteLLM when you're done:

```bash
sed "s/__SERVICE_ACCOUNT__/$SA/" examples/litellm/litellm.yaml | kubectl -n <NS> delete -f -
kubectl -n <NS> delete configmap litellm-config
kubectl -n <NS> delete secret litellm-secrets
```
