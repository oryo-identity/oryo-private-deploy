# Sensor install on headless Linux

For Linux machines with no desktop session, and so no tray icon to register from. Everything here runs over SSH or from a provisioning tool.

Supported: Ubuntu and Debian with systemd and nftables. RHEL and Fedora aren't supported yet.

## What you need

| Item | Where to get it |
|---|---|
| `oryo-ca.pem`, your tenant's root CA | Dashboard → Settings → Installation → Linux, step 1 |
| `oryo_amd64.deb` or `oryo_arm64.deb` | Same page, or `https://<api-host>/oryo.deb` (add `?arch=arm64` for arm64) |
| A registration token (`sk_oryo_…`) | Dashboard → Settings → Registration |
| Your API and dashboard URLs | The Linux tab's "Point the sensor at this deployment" step |

## 1. Trust the CA

The sensor won't start until the CA is in the system store.

```bash
sudo cp oryo-ca.pem /usr/local/share/ca-certificates/oryo-ca.crt
sudo update-ca-certificates
```

To check it's there:

```bash
awk -v cmd='openssl x509 -noout -subject' '/BEGIN/{close(cmd)};{print | cmd}' \
  < /etc/ssl/certs/ca-certificates.crt | grep -i oryo
```

## 2. Install the package

```bash
sudo apt install -y ./oryo_amd64.deb    # x86_64
sudo apt install -y ./oryo_arm64.deb    # aarch64
```

This pulls in nftables, creates the service user and starts `oryo-sensor`.

## 3. Point the sensor at your deployment

```bash
sudo mkdir -p /etc/oryo
sudo tee /etc/oryo/config.json >/dev/null <<'EOF'
{
  "sensor": {
    "sensor_config_url": "https://<api-host>/v1/sensor/config",
    "dashboard_url": "https://<dashboard-host>"
  }
}
EOF
sudo systemctl restart oryo-sensor
```

The dashboard's Linux tab shows this same snippet with your hosts filled in.

## 4. Register

The sensor listens for registration on loopback:

```bash
curl -sS -X POST http://127.0.0.1:62687/v1/register \
  -H 'Content-Type: application/json' \
  -d '{"registrationToken":"sk_oryo_REPLACE","identityKey":"owner@example.com"}'
```

`identityKey` says who the machine belongs to. An email ties it to that person. Any other string, such as the hostname, registers it as a device, which suits shared servers and build agents.

The machine shows up under **AI Inventory** once it reports in.

## Fleet rollout

Steps 1–4 can run as one script from Ansible, cloud-init or similar. Only `identityKey` changes per host. Keep the registration token in your secrets manager, not in the script.

```bash
#!/usr/bin/env bash
set -euo pipefail
API=https://<api-host>
DASH=https://<dashboard-host>
IDENTITY="${ORYO_IDENTITY:-$(hostname -f)}"

install -m 0644 oryo-ca.pem /usr/local/share/ca-certificates/oryo-ca.crt
update-ca-certificates

ARCH=$(dpkg --print-architecture)   # amd64 | arm64
curl -fsSLo /tmp/oryo.deb "$API/oryo.deb?arch=$ARCH"
apt-get install -y /tmp/oryo.deb

mkdir -p /etc/oryo
cat >/etc/oryo/config.json <<EOF
{ "sensor": { "sensor_config_url": "$API/v1/sensor/config", "dashboard_url": "$DASH" } }
EOF
systemctl restart oryo-sensor

# retries while the restarted sensor comes up
curl -sS --retry 10 --retry-connrefused --retry-delay 2 \
  -X POST http://127.0.0.1:62687/v1/register \
  -H 'Content-Type: application/json' \
  -d "{\"registrationToken\":\"$ORYO_REGISTRATION_TOKEN\",\"identityKey\":\"$IDENTITY\"}"
```

## Notes

- **Docker on the same host:** container traffic is inspected too, and containers don't use the host's trust store. See [docker-containers.md](docker-containers.md).
- **Status and logs:** `systemctl status oryo-sensor` and `journalctl -u oryo-sensor -f`.
- **Uninstall:** `sudo apt remove oryo` keeps the registration; `sudo apt purge oryo` drops it. To retire the host fully, also delete `/usr/local/share/ca-certificates/oryo-ca.crt` and rerun `update-ca-certificates`.
