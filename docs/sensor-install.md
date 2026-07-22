# Installing Sensors

Ways to get the Oryo sensor onto endpoints. Route 1 (the dashboard one-liner) is the default
path. Routes 2 and 3 are for environments where endpoints can't (or shouldn't) reach Oryo's
public download bucket: pull the binaries yourself over OCI, and optionally serve them from
an internal mirror. For fleet rollout, package the route 1 one-liner (or a route 2/3 install
command) into your MDM's run-script policy.

## Prerequisites (all routes)

- **A running platform** (see [runbook.md](runbook.md) or [on-prem-runbook.md](on-prem-runbook.md)).
- **Tenant CA trust.** Each tenant has its own sensor root CA. Download it from the dashboard
  (Settings → Installation → Download CA) and push it to endpoints as a trusted root
  certificate before installing; MDM certificate profiles are the usual vehicle.
- **A registration token** from Settings → Registration Tokens (see [Route 1](#route-1-dashboard-one-liner-default) for how to create one).
- **`SENSOR_DOWNLOAD_BASE_URL`** set in the platform's `values.custom.yaml`: the bucket or
  mirror **root** (the api appends `/executables/<pinned-version>` itself). Routes 1 and 2
  resolve the download through it; route 3 points it at your mirror. Without it the
  install-script routes return 503.
- The endpoint must reach `api.<DOMAIN>` (registration + config) and `gateway.<DOMAIN>`
  (traffic), and resolve + trust both.

## Version pinning

The platform serves the sensor version pinned into the chart at release time
(`SENSOR_PINNED_VERSION`); installs and updates use that exact build. The pin is the sensor
release tag verbatim, **including its leading `v`** (e.g. `v0.5.0-pd`): the same string used
for the git tag, the OCI tag, and the bucket's `executables/<version>/` directory. If you
stage binaries on a mirror, reuse that exact `v`-prefixed directory name. The chart's GitHub
Release notes list the pinned version.

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

## Route 2: OCI pull + manual install

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
route 1 script passes. `oras pull` restores the files without the execute bit, so mark the
installer executable first (otherwise `sudo` reports it as `command not found`, not
`permission denied`):

**macOS / Linux** (pick the matching `<platform>`):
```bash
chmod +x oryo-install-<platform>
sudo ./oryo-install-<platform> \
  --registration-token sk_oryo_... \
  --username jane.doe@company.com \
  --sensor-config-url https://api.<DOMAIN>/v1/sensor/config
```

> macOS: if Gatekeeper blocks it (the binaries are Developer-ID signed, so this is rare via
> an `oras` pull), clear the quarantine flag: `sudo xattr -d com.apple.quarantine oryo-install-<platform>`.

**Windows** (PowerShell as Administrator):
```powershell
.\oryo-install-windows-amd64.exe `
  --registration-token sk_oryo_... `
  --username jane.doe@company.com `
  --sensor-config-url https://api.<DOMAIN>/v1/sensor/config
```

After registering, the installer fetches the updater and sensor binaries from the download
URL in the platform's remote config (built from `SENSOR_DOWNLOAD_BASE_URL`). If the platform
serves no download URL (the config logs `download_url=""`, e.g. `SENSOR_DOWNLOAD_BASE_URL` is
unset), point the installer straight at the versioned bucket directory with
`--download-base-url`. That value is the **full** path including `/executables/<vX.Y.Z>`:

```bash
--download-base-url https://binaries-pub-prod-us-east-1-oryo.s3.amazonaws.com/executables/<vX.Y.Z>
```

It's the same flag route 3 uses for a mirror, and it takes precedence over the remote config.

## Route 3: internal mirror (no-egress endpoints)

For endpoints with no path to Oryo's public bucket, host the release bundle yourself:

1. Pull the bundle as in route 2.
2. Serve the files from any internal HTTPS server in the same layout as Oryo's bucket:
   `https://mirror.internal/executables/<vX.Y.Z>/<file>`. The version directory keeps the
   **leading `v`** (it's the sensor release tag, e.g. `executables/v0.5.0-pd/`).
3. Point installs at the mirror. The two knobs take **different forms**, so mind the difference:

   - **Per install:** `--download-base-url` is the **full versioned directory**; the installer
     appends only the filename:
     ```bash
     sudo ./oryo-install-darwin-arm64 \
       --registration-token sk_oryo_... \
       --username jane.doe@company.com \
       --sensor-config-url https://api.<DOMAIN>/v1/sensor/config \
       --download-base-url https://mirror.internal/executables/<vX.Y.Z>
     ```
   - **Platform-wide:** `global.env.SENSOR_DOWNLOAD_BASE_URL` is the mirror **root**; the api
     appends `/executables/<pinned-version>` itself. Set it in `values.custom.yaml` and upgrade,
     and route 1 one-liners serve from the mirror too:
     ```yaml
     global:
       env:
         SENSOR_DOWNLOAD_BASE_URL: https://mirror.internal
     ```

`--download-base-url` takes precedence over the URL in the remote config, so you can point a
single endpoint at a mirror (or straight at Oryo's bucket) before switching the whole platform
over.

---

## Verify

Whichever route: visit a watched site (for example `chatgpt.com`) from the endpoint. It
should load with no TLS error and appear in the dashboard within a few seconds. The Devices
page shows the registered sensor and its version.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `sudo ./oryo-install-...: command not found` (file is present) | OCI pull dropped the execute bit; `sudo` reports a non-executable file as not-found | `chmod +x oryo-install-<platform>` and re-run (route 2) |
| `GET /install.sh` returns 503 | `SENSOR_DOWNLOAD_BASE_URL` unset on the platform | Set it in `values.custom.yaml` and upgrade |
| Install fails: "the server returned no release to download" / config logs `download_url=""` | Platform has no `SENSOR_DOWNLOAD_BASE_URL`, so it serves no download URL | Set it (`values.custom.yaml`) and upgrade, or pass `--download-base-url <base>/executables/<vX.Y.Z>` for a one-off |
| `403`/`404` fetching a binary | The version directory isn't at that path (usually a missing or extra leading `v`) | The dir is `executables/<vX.Y.Z>/`, `v`-prefixed, matching the sensor release tag |
| Installer downloads fail on the endpoint | No network path to the download base URL | Use route 3 (mirror), or open egress to the bucket |
| TLS errors on watched sites after install | Tenant CA missing from the endpoint's trust store | Re-push the CA; note the CA regenerates if the platform is reinstalled |
| Device registers but no traffic appears | Endpoint can't reach `gateway.<DOMAIN>` | DNS + cert trust for the gateway hostname |
| Wrong sensor version installed | Mirror staged a version that differs from the platform's pin | Stage the pinned version from the release notes |
