# Deploying the Oryo Sensor with Microsoft Intune (Windows)

This guide covers deploying `Oryo.msi` to Windows endpoints with Intune. It
lists the prerequisites, the resources you create, verification steps, and a
troubleshooting section. macOS is covered at the end.

The MSI carries no identity. It installs the sensor, the WFP redirect driver,
the updater task and the tray, and takes no command-line properties. Identity
comes separately: a registration token staged in the registry
(`HKLM\SOFTWARE\Policies\Oryo`) by an ADMX-backed policy. The sensor checks for
it every 30 seconds until one appears, then registers the device itself. So
nothing in this guide is per user or per device: one app, one registration
policy, one CA profile, one device group. Without the staged token a device
still installs, but has to be registered by hand from its tray icon.

## 1. Prerequisites

Confirm all three before creating any resources. Most "stuck on Waiting for
install status" cases are a missing prerequisite rather than a problem with the
package.

| Requirement | Reason | Check |
|---|---|---|
| Device is Microsoft Entra joined (not registered) | Only joined devices receive the Intune Management Extension (IME), which runs app installs. Registered or BYOD devices never receive it, so apps stay on "Waiting". | `dsregcmd /status` shows `AzureAdJoined : YES` |
| Windows edition is Pro, Enterprise, or Education | Windows Home cannot be Entra joined; it can only register. A Home device cannot receive this deployment. | `(Get-CimInstance Win32_OperatingSystem).Caption` |
| Device is enrolled in Intune | Enrollment delivers policies and apps. It happens automatically on Entra join when the MDM scope is set. | The device appears in Intune; `dsregcmd /status` shows an `MdmUrl` |

The enrollment scope lives in the Entra admin center (entra.microsoft.com), not
Intune. Set Devices > Device settings > "Users may join devices" to All, and
Devices > Mobility (MDM) > Microsoft Intune > MDM user scope to All, so an Entra
join auto-enrolls into Intune.

Endpoints also need outbound HTTPS to your Oryo API host (registration and
sensor config) and to the host your deployment's `SENSOR_DOWNLOAD_BASE_URL`
points at, which the on-device updater downloads new versions from.

To check that a device can receive apps at all, see whether any other app (for
example Chrome) shows Installed on it. If it does, IME works and any remaining
problem is specific to Oryo. If nothing installs, the blocker is one of the
prerequisites above.

## 2. Resources you create

1. CA certificate: a Trusted certificate profile. The MSI does not install the
   Oryo root CA, so Intune must.
2. Registration: an imported ADMX policy that stages the registration token and
   your deployment's sensor config URL (section 4).
3. The sensor app: `Oryo.msi` as a Line-of-business app. A fleet with Windows
   on ARM machines in it needs a second app for `Oryo-arm64.msi` (section 5).

Assign all three to the same device group. Order does not matter for
registration: the sensor waits for the token however late it lands.

## 3. CA certificate

1. Download the CA from the Oryo dashboard: Settings > Installation > Download
   CA (choose .cer / DER).
2. In Intune: Devices > Windows > Configuration profiles > Create > New policy >
   Windows 10 and later > Templates > Trusted certificate.
3. Upload the .cer. Set Destination store to Computer certificate store, Root.
4. Assign to the device group.

Without this, the sensor intercepts traffic but its certificates are rejected,
so browsers report certificate errors even while the sensor is running.

The MSI sets the machine environment variables `NODE_USE_SYSTEM_CA=1` and
`UV_SYSTEM_CERTS=1`, so Node (22.15 or later) and uv read the Windows Root
store. They only affect Oryo traffic once this profile has put the Oryo CA in
that store. Apps started before the install keep their old environment until
relaunched; uninstall removes both values.

## 4. Registration

An ADMX policy writes the two values the sensor reads:

```
HKLM\SOFTWARE\Policies\Oryo
  RegistrationToken   REG_SZ   sk_oryo_...
  SensorConfigURL     REG_SZ   https://api.<host>/v1/sensor/config
```

`SensorConfigURL` uses your deployment's API host. The token and the URL must
come from the same deployment; a token minted by one is rejected by another.
Tokens are listed under Settings > Registration on the dashboard, where they
can be revoked; they expire after a year.

A policy is used rather than a one-off script because Intune re-applies it,
reports on it, and removes the values when the profile is unassigned. The same
template works with on-prem Group Policy.

1. Dashboard: download `Oryo.admx` and `Oryo.adml` from Settings > Installation
   > Managed fleet (MDM), then click Generate registration token. The token and
   the sensor config URL are shown once; copy both.
2. Intune: Devices > Windows > Configuration profiles > Import ADMX > Import.
   Upload `Oryo.admx` as the ADMX file and `Oryo.adml` as the ADML file. The
   template is self-contained, so `Windows.admx` does not need to be imported
   first.
3. Devices > Windows > Configuration profiles > Create > New policy > Windows
   10 and later > Templates > Imported Administrative templates. Under Oryo >
   Sensor, set Registration token and Sensor config URL to Enabled and paste
   the values from step 1.
4. Assign to the device group.

## 5. The app

`Oryo.msi` is a plain MSI, so it uploads directly as a Line-of-business app. It
needs no `.intunewin` wrapping and no Content Prep Tool.

Apps > Windows > Create > Line-of-business app.

- App package file: upload `Oryo.msi`. Download it from the dashboard at
  Settings > Installation, or take it from the release bucket
  (`.../executables/<version>/Oryo.msi`). On an all-x64 fleet this is the only
  app to create; for Windows on ARM see "Two architectures" below.
- App information: Name `Oryo Sensor`, Publisher `Oryo Identity, Inc.`
- Command-line arguments: none. Registration comes from section 4.
- Assignments: Required, the device group.

Intune derives detection from the MSI product code, and uninstall is
`msiexec /x` against that same code. Neither needs configuring, which is the
main reason to use the Line-of-business app type here rather than a Win32
wrapper.

Upgrades: do not create a new app per version. The MSI keeps the same
`UpgradeCode` across releases, and the on-device updater task handles new
versions on its own. Every hour, as SYSTEM, it compares the running version
with the release your deployment names and installs it when they differ
(log: `C:\Windows\Temp\oryo-msi-upgrade.log`).
Replace the app's package file in Intune only when you want to change the
version a fresh device starts from.

### Two architectures

Every release publishes `Oryo.msi` (x64) and `Oryo-arm64.msi` beside it. There
is no combined package: Windows Installer has no multi-architecture MSI, and
the x64 one fails outright on an ARM64 machine, since its install steps and the
WFP redirect driver are native code that x64 emulation does not cover.

So a fleet with Windows on ARM devices creates two Line-of-business apps,
identical apart from the package and the name:

| App name | Package | Assigned to |
|---|---|---|
| `Oryo Sensor` | `Oryo.msi` | the device group, filtered to x64 |
| `Oryo Sensor (ARM64)` | `Oryo-arm64.msi` | the device group, filtered to ARM64 |

Keep them on the same device group and separate them with an assignment filter
rather than by sorting devices into groups by hand. Tenant administration >
Filters > Create, platform Windows 10 and later, one filter each:

```
(device.cpuArchitecture -eq "amd64")
(device.cpuArchitecture -eq "arm64")
```

On each app's Required assignment, pick the group, then Edit filter > Include
filtered devices in assignment and select the matching filter. Without the
filters an ARM64 device is offered the x64 app and reports a failure against it
for as long as it stays assigned.

Both packages share an `UpgradeCode` and the updater behaves the same on
either, so the upgrade note above still applies.

## 6. Assign, sync, verify

1. Assign all three resources to the device group.
2. Force delivery: Devices > (device) > Sync, or run the `PushLaunch` scheduled
   task on the device. The first delivery can take 15 to 60 minutes.
3. Portal check: Apps > Oryo Sensor > Device install status shows Installed.
4. Device check, in an elevated PowerShell:
   ```powershell
   Get-Service OryoSensor
   Get-ScheduledTask OryoUpdater
   Get-ItemProperty HKLM:\SOFTWARE\Policies\Oryo
   Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Oryo*"
   ```
5. Confirm registration. Installed does not mean reporting. With the token
   staged, the device appears on the dashboard within a minute of the service
   starting, and `C:\ProgramData\Oryo\config.json` contains a
   `resource_token`. Until then the sensor runs but fetches no rules and
   reports nothing. If the registration policy was skipped, click the Oryo tray
   icon on each device and follow it to the dashboard instead.

Recommend a reboot after the first install. Long-running applications hold
open TLS sessions, so the redirect and the new CA only cover connections opened
afterward. A restart provides full coverage.

## 7. Key paths

| Item | Path |
|---|---|
| Sensor binary | `C:\ProgramData\Oryo\bin\oryo-sensor.exe` |
| Updater | `C:\ProgramData\Oryo\bin\oryo-updater.exe` |
| Tray | `C:\Program Files\Oryo\Oryo.exe` |
| Redirect driver | `C:\ProgramData\Oryo\driver\oryo-redirect.sys` |
| Config | `C:\ProgramData\Oryo\config.json` |
| Logs | `C:\ProgramData\Oryo\logs\` |
| Staged registration | `HKLM\SOFTWARE\Policies\Oryo` (`RegistrationToken`, `SensorConfigURL`) |

## 8. Troubleshooting

### App stays on "Waiting for install status" and nothing runs

IME is not on the device. The device is either Entra registered (not joined) or
running Windows Home. Neither can receive Intune app deployments. Use an Entra
joined Pro or Enterprise device. Confirm with `dsregcmd /status`
(`AzureAdJoined: YES`) and `(Get-CimInstance Win32_OperatingSystem).Caption`
(not Home).

### Install fails on a Windows on ARM device (error 1633)

`This installation package is not supported by this processor type` means the
x64 `Oryo.msi` reached an ARM64 machine. Add `Oryo-arm64.msi` as its own app
and put the architecture filters on both assignments (section 5, "Two
architectures"). Confirm the device's architecture with
`$env:PROCESSOR_ARCHITECTURE` in an elevated PowerShell. It shows `ARM64`
there, while Intune reports `arm64` in `device.cpuArchitecture`.

### Install fails with "Oryo is already installed in DNS routing mode"

The device still has the older `oryo-install`-based sensor. The MSI refuses to
install over it, because the two share a directory, a service name and a
loopback address. Remove the old sensor first.

The MSI looks for `C:\ProgramData\Oryo\bin\oryo-install.exe`. If the
uninstaller is run from that folder, it cannot delete its own running file, so
the file stays until a reboot and the MSI keeps refusing. Run it from a temp
copy instead, in an elevated PowerShell:

```powershell
Copy-Item C:\ProgramData\Oryo\bin\oryo-install.exe $env:TEMP -Force
& "$env:TEMP\oryo-install.exe" --uninstall
```

Confirm `Test-Path C:\ProgramData\Oryo\bin\oryo-install.exe` returns False (or
reboot if it was already run from that folder), then re-sync.

Uninstalling also removes `config.json`. A device with a staged token (section
4) registers itself again on reinstall, since the MSI never touches
`HKLM\SOFTWARE\Policies\Oryo`. A device registered from the tray has to be
registered again by hand.

### Sensor is installed but the dashboard shows no device

It has not been registered. First check the staged token:
`Get-ItemProperty HKLM:\SOFTWARE\Policies\Oryo`. No key means the policy has
not reached the device yet (sync, and check its status in the portal). A key
that is present but no registration within a minute or two of the service
starting means the token was revoked, has expired, or belongs to a different
deployment than `SensorConfigURL`. The sensor log in `C:\ProgramData\Oryo\logs\`
shows "Staged registration failed" every 30 seconds. Mint a new token and
replace the policy value. Confirm registration with
`Test-Path C:\ProgramData\Oryo\config.json` and look for `resource_token` in
it.

### Sensor runs but browsers report certificate errors

The Oryo CA is not trusted. The MSI does not install it. Deploy it with the
Trusted certificate profile (section 3), or import it manually:
`Import-Certificate -FilePath oryo-ca.cer -CertStoreLocation Cert:\LocalMachine\Root`.

### Sensor runs but some traffic is not intercepted

The redirect driver covers TCP ports 80 and 443 only. HTTP/3 (QUIC) traffic and
anything on another port pass through untouched. Handle HTTP/3 with browser
policy.

### IME installs other apps but not this one, or reports an internal exception

The Intune Management Extension processes apps in batches and sometimes hits an
internal error, for example `V3Processor ... Encountered an exception ... Stop
processing`. This can leave one app unprocessed while others install. Run
`Restart-Service IntuneManagementExtension`, reboot, or wait for the hourly
check-in; it usually clears on a later pass. Confirm progress in
`AppWorkload.log` by searching for `Oryo`.

## 9. Test rig: an Azure VM

A local Windows Home machine cannot do this, since Home cannot Entra join. An
Azure VM is a convenient test rig: it runs Enterprise, which can join.

1. Create a Windows 11 Enterprise VM (B2s is sufficient) with a local admin
   account. Optionally, the Management tab's "Login with Microsoft Entra ID"
   option joins it at deploy time; otherwise join from inside the OS (below).
2. Set the enrollment prerequisites in entra.microsoft.com: Devices > Device
   settings > "Users may join devices" to All, and Devices > Mobility (MDM) >
   Microsoft Intune > MDM user scope to All.
3. RDP in with the local admin. Run `start ms-settings:workplace`, click Connect,
   click "Join this device to Microsoft Entra ID" at the bottom of the dialog,
   sign in, and reboot.
4. Verify the join and wait for IME. First delivery can take 15 to 60 minutes; a
   reboot speeds the IME install:
   ```powershell
   dsregcmd /status | findstr /C:"AzureAdJoined" /C:"MdmUrl"
   Get-Service IntuneManagementExtension
   ```
5. Once IME is present, the assigned app installs on its own.

## 10. macOS

macOS uses `Oryo.dmg`, which installs the Oryo app and its system extensions,
and six Intune resources. Download the files from the dashboard at Settings >
Installation > Managed fleet (MDM) > macOS.

Create and assign the profiles and script before the app. A Mac that launches
Oryo before the profiles arrive gets stuck at `activated waiting for user`
until the extension record is cleared and the extension is activated again.

1. Trusted certificate profile carrying the Oryo root CA, as in section 3
   (macOS > Templates > Trusted certificate).
2. System extension approval, as a Settings catalog profile: Devices > macOS >
   Configuration profiles > Create > New policy > Settings catalog. Add System
   Configuration > System Extensions and set Allowed Team Identifiers to
   `7WBM56KDNK`. This is what approves the extension without user action.
   Intune does not apply the system extension allow-list from a Custom
   profile: the profile installs, but the allow-list never takes effect, so
   without this Settings catalog profile every Mac stops at a "would like to
   use a new network extension" dialog. The older Extensions template is
   deprecated; use Settings catalog.
3. Transparent proxy profile, as a Custom profile: Devices > macOS >
   Configuration profiles > Create > New policy > Templates > Custom, upload
   `oryo-macos.mobileconfig`. Deployment channel: Device. The profile is tied
   to the extension in a specific release, so keep it paired with the
   `Oryo.dmg` of the same release. It also grants the security extension
   (process tracking) Full Disk Access, which macOS requires for it. Its
   system extension allow-list does nothing on Intune (see step 2) but is kept
   for MDMs such as Jamf that do apply it.
4. Registration profile, as a Custom profile: download
   `oryo-macos-registration.mobileconfig` from the dashboard (each download
   creates a fresh registration token and embeds it) and upload it as a second
   Custom profile, Deployment channel: Device. The sensor reads the token on
   first launch and registers itself, so no one touches the device. The token
   is listed under Settings > Registration and can be revoked there.
5. Shell script: Devices > macOS > Scripts, upload `intune-first-launch.sh`.
   Run script as signed-in user: No (it runs as root); Script frequency: Every
   1 day. It launches the app so it can start its background service and
   activate the extension. It exits without doing anything when Oryo is
   already running, so the daily run only catches apps that arrived late or
   were reinstalled.
6. The app: Apps > macOS > Create > macOS app (DMG), upload `Oryo.dmg`. App
   information (Intune only fills in the file name): Name `Oryo Sensor`,
   Description `Oryo sensor. Endpoint EDR for AI agents.`, Publisher
   `Oryo Identity, Inc.`, Information URL `https://oryo.io`. Detection rules:
   included app `io.oryo.app`; Ignore app version: Yes. Assign as Required
   only.

Upgrades: managed Macs do not update on their own yet. Intune installs the
app owned by root, and the app's built-in updater (Sparkle) needs an
administrator password to replace an app owned by root.

Verify one Mac before rolling out to the fleet: `systemextensionsctl list`
shows both `io.oryo.network-extension` and `io.oryo.security-extension` as
`[activated enabled]`, with no dialogs on screen.

The per-architecture `oryo-darwin-<arch>.pkg` (macOS app (PKG) type) installs
only the bare sensor binaries, with no extension and no interception, and needs
none of the profiles above.

### Removing the older `oryo-install` sensor (macOS)

Unlike the MSI, `Oryo.dmg` does not refuse to install over the older
`oryo-install`-based sensor, and the two conflict: both use the launchd label
`io.oryo.sensor` and the folder `/Library/Application Support/Oryo`. A leftover
`config.json` makes the new sensor keep the old device identity, and leftover
pf firewall rules or a `127.0.0.3` DNS server break networking. Remove the old
sensor first, as root:

```bash
"/Library/Application Support/Oryo/bin/oryo-install" --uninstall
```

The uninstaller resets DNS only on network services that are active at the
time, so clear `127.0.0.3` from the others with
`networksetup -setdnsservers "<service>" Empty`. Before the app is assigned,
confirm all of these: `launchctl print system/io.oryo.sensor` finds no service,
`/etc/pf.io.oryo.conf` and `/Library/Application Support/Oryo/config.json` are
gone, and `scutil --dns | grep 127.0.0.3` prints nothing.
