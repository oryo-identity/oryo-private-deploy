# Installing Sensors

Ways to get the Oryo sensor onto endpoints. Route 1 (the dashboard one-liner) is the default
path. Routes 2 and 3 are for environments where endpoints can't (or shouldn't) reach Oryo's
public download bucket: pull the binaries yourself over OCI, and optionally serve them from
an internal mirror.

> Route status: route 1 is the documented production path. Routes 2 and 3 are **[pending
> validation]**; the commands are correct per the release tooling but haven't been walked
> end-to-end in a lab yet. Flip this note when they have.
>
> MDM fleet rollout (Intune, JAMF, etc.) will get its own section once it's documented as a
> standalone flow rather than "run route 1 from a run-script policy."

## Prerequisites (all routes)

- **A running platform** (see [runbook.md](runbook.md) or [on-prem-runbook.md](on-prem-runbook.md)).
- **Tenant CA trust.** Each tenant has its own sensor root CA. Download it from the dashboard
  (Settings → Installation → Download CA) and push it to endpoints as a trusted root
  certificate before installing; MDM certificate profiles are the usual vehicle.
- **A registration token** from Settings → Registration Tokens (see [Route 1](#route-1-dashboard-one-liner-default) for how to create one).
- **`SENSOR_DOWNLOAD_BASE_URL`** set in the platform's `values.custom.yaml` (routes 1 and 2
  download the sensor binary through it; route 3 replaces it with your mirror). Without it the
  install-script routes return 503.
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

### Get a registration token

Tokens are issued from the dashboard (there's no CLI or API for minting them):

1. Open `https://app.<DOMAIN>` and sign in.
2. Go to **Settings → Registration Tokens** and click **Create** (give it a name, e.g. the
   rollout or team it's for).
3. Copy the token (`sk_oryo_...`) immediately. It's shown **once** and can't be retrieved
   afterward; if you lose it, create another.

One token can register many devices, and deleting it from that same page revokes it. On
**Settings → Installation** you can pick a token from a dropdown and the page prefills the
commands below with it, so you don't have to paste it by hand.

### Install

The dashboard's **Settings → Installation** page shows these per-OS commands prefilled for
your deployment. Substitute your registration token, the username to register the device
under, and your `api.<DOMAIN>`:

**macOS** (Terminal):
```bash
export REGISTRATION_TOKEN=sk_oryo_... ORYO_USERNAME=jane.doe@company.com API_BASE_URL=https://api.<DOMAIN>
curl -fsSL "https://api.<DOMAIN>/install.sh" | bash
```

**Windows** (PowerShell as Administrator):
```powershell
$Registration_Token="sk_oryo_..."; $Oryo_Username="jane.doe@company.com"; $env:API_BASE_URL="https://api.<DOMAIN>"
irm https://api.<DOMAIN>/install.ps1 | iex
```

**Linux** (systemd):
```bash
curl -fsSL https://api.<DOMAIN>/install-linux.sh \
  | sudo REGISTRATION_TOKEN=sk_oryo_... ORYO_USERNAME=jane.doe@company.com API_BASE_URL=https://api.<DOMAIN> bash
```

What it does:

- Your platform serves the script, rewritten to your `API_BASE_URL`.
- The script downloads the installer from `SENSOR_DOWNLOAD_BASE_URL` and verifies it against `SHA256SUMS`.
- The installer runs, registers the device, and fetches the sensor config.
- It downloads the sensor binary and installs the service.

## Route 2: OCI pull + manual install  [pending validation]

Each sensor release is published as one OCI artifact at
`ghcr.io/oryo-identity/sensor/oryo-sensor:<vX.Y.Z>`. It bundles, for every supported platform
(`darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`, `windows-amd64`):

- `oryo-sensor-<platform>`: the sensor itself
- `oryo-install-<platform>`: the installer
- `oryo-updater-<platform>`: the self-updater
- `oryo-darwin-<arch>.pkg`: signed macOS installer packages
- `SHA256SUMS`: checksums to verify the download

Note the tag carries a leading `v`, unlike the chart's `sensor_version` input.

```bash
# same GHCR credentials as the image pull secret (account + read:packages token)
oras login ghcr.io

oras pull ghcr.io/oryo-identity/sensor/oryo-sensor:<vX.Y.Z> -o ./sensor-bundle
cd sensor-bundle && shasum -a 256 -c SHA256SUMS
```

Copy the installer for the endpoint's platform and run it directly with the same flags the
route 1 script passes:

**macOS / Linux** (pick the matching `<platform>`):
```bash
sudo ./oryo-install-<platform> \
  --registration-token sk_oryo_... \
  --username jane.doe@company.com \
  --sensor-config-url https://api.<DOMAIN>/v1/sensor/config
```

**Windows** (PowerShell as Administrator):
```powershell
.\oryo-install-windows-amd64.exe `
  --registration-token sk_oryo_... `
  --username jane.doe@company.com `
  --sensor-config-url https://api.<DOMAIN>/v1/sensor/config
```

The installer still downloads the sensor binary from the platform-configured
`SENSOR_DOWNLOAD_BASE_URL`, so the endpoint needs to reach it (or use route 3).

## Route 3: internal mirror (no-egress endpoints)  [pending validation]

For endpoints with no path to Oryo's public bucket, host the release bundle yourself:

1. Pull the bundle as in route 2.
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
| Installer downloads fail on the endpoint | No path to the download base URL | Use route 3, or open egress to the bucket |
| TLS errors on watched sites after install | Tenant CA missing from the endpoint's trust store | Re-push the CA; note the CA regenerates if the platform is reinstalled |
| Device registers but no traffic appears | Endpoint can't reach `gateway.<DOMAIN>` | DNS + cert trust for the gateway hostname |
| Wrong sensor version installed | Mirror staged a version that differs from the platform's pin | Stage the pinned version from the release notes |
