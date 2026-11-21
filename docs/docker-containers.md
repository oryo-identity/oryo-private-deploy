# Docker containers and the Oryo CA

The sensor inspects container traffic along with the rest of the host's. It re-signs TLS to inspected hosts with your tenant's Oryo CA. Containers don't use the host's trust store, so clients inside them reject that certificate:

- Go, curl, OpenSSL: `x509: certificate signed by unknown authority` or `unable to get local issuer certificate`
- Node: `SELF_SIGNED_CERT_IN_CHAIN` or `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`
- Python: `SSLCertVerificationError: certificate verify failed`

## What already works

`docker pull` and `docker push`. Docker Desktop on macOS and Windows copies the host's trusted CAs into its engine at startup, and `dockerd` on Linux uses the system store. Once the Oryo CA is on the host, restart Docker and registry traffic verifies.

## Host-side options

As far as we can tell, there isn't a reliable host-side or MDM way to do this today. A container's trust store comes from its image, and we haven't found a certificate setting in Docker Desktop's admin settings (`admin-settings.json`). Docker's own guidance for TLS-inspecting proxies is to add the CA when the image is built. If your team knows a central approach that works in your environment, we're happy to test it with you.

## Get the CA

Dashboard → Settings → Installation → **Download CA** (`oryo-ca.pem`). It's specific to your tenant. Keep a copy where your image builds can read it, such as your artifact store or a repo.

## Option 1 (recommended): internal base images

Make one thin wrapper per upstream base image you use and push it to your registry. Have CI rebuild it when the upstream image changes.

**Debian / Ubuntu**

```dockerfile
FROM python:3.12
COPY oryo-ca.pem /usr/local/share/ca-certificates/oryo-ca.crt
RUN update-ca-certificates
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
```

**Alpine**

```dockerfile
FROM node:22-alpine
RUN apk add --no-cache ca-certificates
COPY oryo-ca.pem /usr/local/share/ca-certificates/oryo-ca.crt
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
```

**RHEL / UBI**

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi
COPY oryo-ca.pem /etc/pki/ca-trust/source/anchors/oryo-ca.pem
RUN update-ca-trust
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
    NODE_EXTRA_CA_CERTS=/etc/pki/tls/certs/ca-bundle.crt
```

**JVM**: also import the CA into the JDK keystore:

```dockerfile
RUN keytool -importcert -noprompt -cacerts -storepass changeit \
      -alias oryo -file /usr/local/share/ca-certificates/oryo-ca.crt
```

Teams then change `FROM python:3.12` to `FROM <registry>/base/python:3.12`. In a multi-stage build, the CA has to be in the stage that ships, not just the build stage.

## Option 2: mount the CA at run time

For third-party images you run but don't build. Node can take the Oryo CA on its own. Python, and anything else that reads `SSL_CERT_FILE`, replaces its bundle instead of adding to it, so give it a combined bundle: the public roots plus the Oryo CA. On a Linux host with the CA installed, that's `/etc/ssl/certs/ca-certificates.crt`.

```bash
docker run \
  -v /etc/ssl/certs/ca-certificates.crt:/etc/oryo/ca-bundle.crt:ro \
  -e SSL_CERT_FILE=/etc/oryo/ca-bundle.crt \
  -e REQUESTS_CA_BUNDLE=/etc/oryo/ca-bundle.crt \
  -e NODE_EXTRA_CA_CERTS=/etc/oryo/ca-bundle.crt \
  <image>
```

In Compose, define it once and merge it into each service:

```yaml
x-oryo-ca: &oryo-ca
  volumes:
    - /etc/ssl/certs/ca-certificates.crt:/etc/oryo/ca-bundle.crt:ro
  environment:
    SSL_CERT_FILE: /etc/oryo/ca-bundle.crt
    REQUESTS_CA_BUNDLE: /etc/oryo/ca-bundle.crt
    NODE_EXTRA_CA_CERTS: /etc/oryo/ca-bundle.crt

services:
  app:
    <<: *oryo-ca
    image: <image>
```

macOS and Windows hosts have no `/etc/ssl/certs` bundle to mount, so export a combined bundle to a file first. Tools that ship their own CA list and ignore all of this, such as some Rust binaries and statically built Go with embedded roots, need option 1.

## Option 3: skip inspection for containers

If neither option is worth the effort, talk to us about excluding Docker traffic from inspection. The trade-off is that AI calls made from containers won't be visible.

## Check it worked

From inside a container:

```bash
curl -sv https://api.anthropic.com 2>&1 | grep -E 'issuer|SSL certificate verify'
```

You should see the Oryo issuer and `SSL certificate verify ok`.

## Why the environment variables

| Runtime | Uses the system store? | What to set |
|---|---|---|
| Go, curl, OpenSSL, most CLIs | Yes | nothing (`SSL_CERT_FILE` overrides it) |
| Node.js | No, it has its own roots | `NODE_EXTRA_CA_CERTS` (adds to them) |
| Python `requests` / pip | No, it uses `certifi` | `REQUESTS_CA_BUNDLE` (replaces it) |
| Python stdlib `ssl` / `urllib` | Yes, through OpenSSL | nothing (`SSL_CERT_FILE` overrides it) |
| Python `httpx` | No, it uses `certifi` | `SSL_CERT_FILE` (replaces it) |
| JVM | No, it has its own `cacerts` keystore | `keytool` import |
