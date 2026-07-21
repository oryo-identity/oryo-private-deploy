# Installing Sensors

Every way to get the Oryo sensor onto endpoints, from the dashboard one-liner to a fully
mirrored no-egress rollout. Routes 1 and 2 are the standard paths; routes 3 and 4 are for
environments where endpoints can't (or shouldn't) reach Oryo's public download bucket.

> Route status: 1 and 2 are the documented production paths. 3 and 4 are **[pending
> validation]**; the commands are correct per the release tooling but haven't been walked
> end-to-end in a lab yet. Flip this note when they have.

## Prerequisites (all routes)

- **A running platform** (see [runbook.md](runbook.md) or [on-prem-runbook.md](on-prem-runbook.md)).
- **Tenant CA trust.** Each tenant has its own sensor root CA. Download it from the dashboard
  (Settings → Installation → Download CA) and push it to endpoints as a trusted root
  certificate before installing; MDM certificate profiles are the usual vehicle.
- **A registration token** from Settings → Installation.
- **`SENSOR_DOWNLOAD_BASE_URL`** set in the platform's `values.custom.yaml` (routes 1 and 2
  download through it; route 4 replaces it with your mirror). Without it the install-script
  routes return 503.
- The endpoint must reach `api.<DOMAIN>` (registration + config) and `gateway.<DOMAIN>`
  (traffic), and resolve + trust both.

## Version pinning

The platform serves the sensor version pinned into the chart at release time
(`SENSOR_PINNED_VERSION`). Installs and updates use that exact build, so the version you
stage on a mirror must match the pin. Check the chart's GitHub Release notes for the pinned
version.

> **Never use `:latest`** on the sensor OCI repo or the S3 bucket paths when staging
> binaries. The tag tracks whatever was promoted most recently and can lag or lead your
> platform's pin. Pull the explicit version.

---

## Route 1: dashboard one-liner (default)

Before you run it, confirm two things (both from the shared prerequisites above):

- **`global.env.SENSOR_DOWNLOAD_BASE_URL` is set** on the platform. The script downloads
  `oryo-install` and the sensor binary through it, so if it's unset the one-liner's
  `GET /install.sh` returns 503 and nothing installs. Set it in `values.custom.yaml` and
  upgrade first.
- **The tenant CA is trusted on the endpoint.** Download it from Settings → Installation →
  Download CA and add it to the endpoint's trust store before installing, or the sensor's
  intercepted TLS fails on watched sites afterward.

The dashboard's Settings → Installation page shows the exact command for your deployment.
The shape (macOS shown; Windows uses `install.ps1`):

```bash
export REGISTRATION_TOKEN=sk_oryo_... ORYO_USERNAME=jane.doe@company.com
curl -fsSL https://api.<DOMAIN>/install.sh | bash
```

What it does: your platform serves the script (rewritten to your `API_BASE_URL`), the script
downloads `oryo-install-<platform>` from `SENSOR_DOWNLOAD_BASE_URL`, verifies it against
`SHA256SUMS`, and runs it with your token. The installer registers the device, fetches the
sensor config, downloads the sensor binary, and installs the service.

## Route 2: MDM fleet rollout (Intune, JAMF, etc.)

1. Push the tenant CA (Settings → Installation → Download CA) as a trusted root certificate
   via your MDM's certificate-distribution profile.
2. Push the route 1 one-liner via your MDM's run-script policy. On macOS the signed
   `oryo-darwin-<arch>.pkg` from the release bundle is an alternative payload.
3. Watch the dashboard's Devices page fill in as sensors register.

## Route 3: OCI pull + manual install  [pending validation]

Each sensor release is published as one OCI artifact at
`ghcr.io/oryo-identity/sensor/oryo-sensor:<vX.Y.Z>` containing all platform binaries
(`oryo-sensor-*`, `oryo-install-*`, `oryo-updater-*`), the signed macOS `.pkg`s, and
`SHA256SUMS`. Note the tag carries a leading `v`, unlike the chart's `sensor_version` input.

```bash
# same GHCR credentials as the image pull secret (account + read:packages token)
oras login ghcr.io

oras pull ghcr.io/oryo-identity/sensor/oryo-sensor:<vX.Y.Z> -o ./sensor-bundle
cd sensor-bundle && shasum -a 256 -c SHA256SUMS
```

Copy the matching installer to the endpoint and run it directly (this is exactly what the
route 1 script automates):

```bash
# macOS arm64 example; Windows: oryo-install-windows-amd64.exe from an elevated shell
sudo ./oryo-install-darwin-arm64 \
  --registration-token sk_oryo_... \
  --username jane.doe@company.com \
  --sensor-config-url https://api.<DOMAIN>/v1/sensor/config
```

The installer still downloads the sensor binary from the platform-configured
`SENSOR_DOWNLOAD_BASE_URL`, so the endpoint needs to reach it (or use route 4).

## Route 4: internal mirror (no-egress endpoints)  [pending validation]

For endpoints with no path to Oryo's public bucket, host the release bundle yourself:

1. Pull the bundle as in route 3.
2. Serve it from any internal HTTPS server in the layout the installer expects:
   `https://mirror.internal/executables/<version>/<file>` (version without the leading `v`,
   matching the platform's pinned version).
3. Point installs at the mirror, either per-install:

   ```bash
   sudo ./oryo-install-darwin-arm64 \
     --registration-token sk_oryo_... \
     --username jane.doe@company.com \
     --sensor-config-url https://api.<DOMAIN>/v1/sensor/config \
     --download-base-url https://mirror.internal/executables
   ```

   or platform-wide, by setting `global.env.SENSOR_DOWNLOAD_BASE_URL` to the mirror in
   `values.custom.yaml` and upgrading; route 1 one-liners then also serve from the mirror.

`--download-base-url` takes precedence over the URL in the remote config, so a single
endpoint can be tested against a mirror before switching the whole platform over.

---

## Verify

Whichever route: visit a watched site (for example `chatgpt.com`) from the endpoint. It
should load with no TLS error and appear in the dashboard within a few seconds. The Devices
page shows the registered sensor and its version.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `GET /install.sh` returns 503 | `SENSOR_DOWNLOAD_BASE_URL` unset on the platform | Set it in `values.custom.yaml` and upgrade |
| Installer downloads fail on the endpoint | No path to the download base URL | Use route 4, or open egress to the bucket |
| TLS errors on watched sites after install | Tenant CA missing from the endpoint's trust store | Re-push the CA; note the CA regenerates if the platform is reinstalled |
| Device registers but no traffic appears | Endpoint can't reach `gateway.<DOMAIN>` | DNS + cert trust for the gateway hostname |
| Wrong sensor version installed | Mirror staged a version that differs from the platform's pin | Stage the pinned version from the release notes |
