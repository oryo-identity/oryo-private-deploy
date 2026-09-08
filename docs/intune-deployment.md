# Deploying the Oryo Sensor with Microsoft Intune (Windows)

How to push `Oryo.msi` to a Windows fleet with Intune, pointed at **your**
deployment rather than Oryo's hosted service: prerequisites, the resources you
create, verification, and troubleshooting. macOS is covered briefly at the end.

The package is not built per customer. One signed `Oryo.msi` installs against
any deployment; which one it talks to is a value you stage on the device, not
something baked into the download. [Section 4](#4-point-the-sensor-at-your-deployment)
is the part that makes it yours — skip it and the sensor falls back to Oryo's
hosted service.

## 1. Prerequisites

Confirm all three before creating any apps. Most "stuck on Waiting for install
status" cases are a missing prerequisite rather than a problem with the package.

| Requirement | Reason | Check |
|---|---|---|
| Device is Microsoft Entra joined (not registered) | Only joined devices receive the Intune Management Extension (IME), which runs app installs. Registered or BYOD devices never receive it, so apps stay on "Waiting". | `dsregcmd /status` shows `AzureAdJoined : YES` |
| Windows edition is Pro, Enterprise, or Education | Windows Home cannot be Entra joined; it can only register. A Home device cannot receive the deployment. | `(Get-CimInstance Win32_OperatingSystem).Caption` |
| Device is enrolled in Intune | Enrollment delivers policies and apps. It happens automatically on Entra join when the MDM scope is set. | The device appears in Intune; `dsregcmd /status` shows an `MdmUrl` |

The enrollment scope lives in the Entra admin center (entra.microsoft.com), not
Intune. Set Devices > Device settings > "Users may join devices" to All, and
Devices > Mobility (MDM) > Microsoft Intune > MDM user scope to All, so an Entra
join auto-enrolls into Intune.

Endpoints also need outbound HTTPS to `api.<your-domain>` (registration and
sensor config). They do not need to reach Oryo — the packages come from
wherever `SENSOR_DOWNLOAD_BASE_URL` points, which for an air-gapped deployment
is a mirror you host.

To check that a device can receive apps at all, see whether any other app (for
example Chrome) shows Installed on it. If it does, IME works and any remaining
problem is specific to Oryo. If nothing installs, the blocker is one of the
prerequisites above.

## 2. Resources you create

1. **CA certificate** — a Trusted certificate profile. The MSI does not install
   the Oryo root CA, so Intune must.
2. **Registration** — a platform script or an imported ADMX policy that stages
   the registration token *and* your deployment's config URL (section 4).
3. **The sensor app** — `Oryo.msi` as a Line-of-business app (section 5).

Assign all three to the same device group. Order does not matter: the sensor
waits for the values however late they land.

## 3. CA certificate

1. Download the CA from your dashboard at `https://app.<your-domain>`:
   Settings > Installation > Download CA (choose .cer / DER).
2. In Intune: Devices > Windows > Configuration profiles > Create > New policy >
   Windows 10 and later > Templates > Trusted certificate.
3. Upload the .cer. Set Destination store to Computer certificate store, Root.
4. Assign to the device group.

Without this, the sensor intercepts traffic but its forged leaf certificates are
rejected, so browsers report certificate errors even while the sensor runs.

## 4. Point the sensor at your deployment

This is the step that makes a stock package a deployment-specific install.

The sensor resolves its config URL from the first of these that is set:

| Precedence | Where | Set by |
|---|---|---|
| 1 | `C:\ProgramData\Oryo\config.json` | the sensor itself, when the device registers |
| 2 | `HKLM\SOFTWARE\Policies\Oryo\SensorConfigURL` | Intune ADMX policy, Group Policy, or a platform script |
| 3 | `HKLM\SOFTWARE\Oryo\SensorConfigURL` | the MSI's `SENSORCONFIGURL` property |
| 4 | compiled-in default | the build — Oryo's hosted service, for packages Oryo publishes |

For a fleet, use level 2. It is managed state: Intune re-applies it, reports on
it, and removes it when the profile is unassigned, and it overrides whatever an
installer wrote. Both options below stage the same two values:

```
HKLM\SOFTWARE\Policies\Oryo
  RegistrationToken   REG_SZ   sk_oryo_…
  SensorConfigURL     REG_SZ   https://api.<your-domain>/v1/sensor/config
```

The token and the URL must come from the **same** deployment — a token minted
by one means nothing to another. This is also how you run a dev fleet against a
dev deployment: same package, a dev token and `https://api.<dev-domain>/v1/sensor/config`.

Tokens are created under Settings > Registration on your dashboard, where they
can also be revoked; they expire after a year.

### Option A: platform script

One file with the token embedded, uploaded once.

1. Dashboard: Settings > Installation > Managed fleet (MDM) > Windows >
   **Download registration script**. Each download mints a fresh token and
   embeds it, along with this deployment's config URL, in
   `oryo-windows-registration.ps1`.
2. Intune: Devices > Windows > Scripts and remediations > Platform scripts >
   Add. Upload the script. Run this script using the logged on credentials:
   **No** (it writes HKLM, which needs SYSTEM); Enforce script signature check:
   **No**; Run script in 64 bit PowerShell Host: **Yes** (otherwise the write
   lands in `WOW6432Node`, where the 64-bit sensor will not find it).
3. Assign to the device group.

Intune re-runs the script only when its content changes, so replacing a revoked
token means uploading a new download. This is also the path for tools with no
policy engine (NinjaOne, Iru): run the same script as SYSTEM, once per device.

Platform script status reporting lags — the Device status count can read 0 for
hours after a script has run, so do not treat "0 devices" as proof it did not.
Confirm on the device with `Get-ItemProperty HKLM:\SOFTWARE\Policies\Oryo`.

### Option B: ADMX policy

Managed state rather than a one-off. The same template works with on-prem Group
Policy.

1. Dashboard: download `Oryo.admx` and `Oryo.adml` from the same page, then
   **Generate registration token**. The token and the config URL are shown
   once; copy both.
2. Intune: Devices > Windows > Configuration profiles > **Import ADMX** >
   Import. Upload `Oryo.admx` as the ADMX file and `Oryo.adml` as the ADML
   file. The template is self-contained, so `Windows.admx` need not be
   imported first.
3. Devices > Windows > Configuration profiles > Create > New policy > Windows
   10 and later > Templates > **Imported Administrative templates**. Under
   Oryo > Sensor, set **Registration token** and **Sensor config URL** to
   Enabled and paste the values from step 1.
4. Assign to the device group.

### Option C: the MSI property

For a one-off install, a dev box, or an RMM that runs a command line but has no
policy engine:

```
msiexec /i Oryo.msi /qn SENSORCONFIGURL="https://api.<your-domain>/v1/sensor/config"
```

This writes level 3 in the table above, so a policy assigned later still wins.
An upgrade that passes no property keeps the installed value, so the on-device
updater does not revert it. The MSI takes no registration token — that still
comes from Option A or B, which keeps the secret out of MSI logs.

### Why this matters before the device registers

Until a device registers there is no `config.json`, and both the enrollment link
the tray offers and the origin the sensor will accept a registration from are
derived from the config URL. A device that was never told otherwise sends its
user to Oryo's hosted dashboard rather than yours, and refuses the registration
your dashboard tries to make. Staging the URL is what prevents that.

## 5. The app

`Oryo.msi` is a plain MSI, so it uploads directly as a Line-of-business app — no
`.intunewin` wrapping and no Content Prep Tool.

Apps > Windows > Create > **Line-of-business app**.

- App package file: upload `Oryo.msi` from your dashboard's Settings >
  Installation download, or from the release source your deployment mirrors
  (`.../executables/<version>/Oryo.msi`).
- App information: Name `Oryo Sensor`, Publisher `Oryo Identity, Inc.`
- Command-line arguments: leave empty. Section 4's policy is the fleet path;
  `SENSORCONFIGURL` is for command-line installs.
- Assignments: Required, the device group.

Intune derives detection from the MSI product code automatically, and uninstall
is `msiexec /x` against that same code — neither needs configuring, which is the
main reason to prefer the LOB app type here over a Win32 wrapper.

**Upgrades.** Do not create a new app per version. The MSI carries a stable
`UpgradeCode`, and the on-device updater task handles version drift on its own:
hourly, as SYSTEM, it compares the running version against the release your
platform names and runs `msiexec /i ... /qn /norestart` when they differ
(log: `C:\ProgramData\Oryo\logs\msi-upgrade.log`). Replace the app's package
file in Intune only when you want to change the *baseline* a fresh device gets.

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
5. **Confirm registration, and confirm it went to you.** Installed is not the
   same as reporting. With the token staged, the device appears on your
   dashboard within a minute of the service starting, and
   `C:\ProgramData\Oryo\config.json` carries both a `resource_token` and a
   `sensor_config_url` naming `api.<your-domain>`. If that URL names a
   different host, section 4 did not take — fix it there rather than editing
   the file, or the next policy refresh undoes your edit.

Recommend a reboot after the first install. Long-running applications hold open
TLS sessions, so the redirect and the new CA only cover connections opened
afterward. A restart provides full coverage.

## 7. Key paths

| Item | Path |
|---|---|
| Sensor binary | `C:\ProgramData\Oryo\bin\oryo-sensor.exe` |
| Updater | `C:\ProgramData\Oryo\bin\oryo-updater.exe` |
| Tray | `C:\ProgramData\Oryo\bin\Oryo.exe` |
| Redirect driver | `C:\ProgramData\Oryo\driver\oryo-redirect.sys` |
| Config | `C:\ProgramData\Oryo\config.json` |
| Logs | `C:\ProgramData\Oryo\logs\` |
| Install folder marker | `HKLM\SOFTWARE\Oryo\InstallFolder` |
| Staged registration | `HKLM\SOFTWARE\Policies\Oryo` (`RegistrationToken`, `SensorConfigURL`) |
| Installer-set config URL | `HKLM\SOFTWARE\Oryo\SensorConfigURL` (MSI `SENSORCONFIGURL`) |

## 8. Troubleshooting

### The tray sends users to Oryo's dashboard instead of ours

No config URL is staged, so the sensor is on its compiled-in default. Set one
per section 4 and restart the service. Check with
`Get-ItemProperty HKLM:\SOFTWARE\Policies\Oryo` and
`Get-ItemProperty HKLM:\SOFTWARE\Oryo`.

### Token rejected: wrong environment

The token and the config URL are from different deployments. A dev token with
no staged URL falls back to the compiled-in default and is rejected there. Pair
a dev token with `https://api.<dev-domain>/v1/sensor/config`.

### App stays on "Waiting for install status" and nothing runs

IME is not on the device. The device is either Entra registered (not joined) or
running Windows Home. Neither can receive apps. Use an Entra joined Pro or
Enterprise device. Confirm with `dsregcmd /status` (`AzureAdJoined: YES`) and
`(Get-CimInstance Win32_OperatingSystem).Caption` (not Home).

### App reports failed and the sensor is not on the device

Read the result in `AppWorkload.log`, which you can retrieve with Collect
diagnostics on the device (under the overflow menu on the device Overview
page). The install does not depend on a registration token, so a missing token
is not the cause here — it shows up as an installed sensor that never reports.

### Sensor runs but browsers report certificate errors

The Oryo CA is not trusted. The MSI does not install it. Deploy it with the
Trusted certificate profile (section 3), or import it manually:
`Import-Certificate -FilePath oryo-ca.cer -CertStoreLocation Cert:\LocalMachine\Root`.

### Sensor runs but some traffic is not intercepted

Watched domains reached over DoH (DNS over HTTPS) bypass interception. Handle
DoH with browser policy.

### Portal reports Installed but the sensor is an old or unexpected build

Detection is by product code, so a device that already carried a sensor reports
Installed without the install command running. For a reliable test, uninstall
any pre-existing sensor first (`msiexec /x` against the product code, or Apps >
Oryo Sensor > Uninstall), confirm the device is clean
(`Test-Path C:\ProgramData\Oryo\bin\oryo-sensor.exe` returns False), then run
the deploy and verify `config.json` names your deployment.

### IME installs other apps but not this one, or reports an internal exception

The Intune Management Extension processes apps in batches and sometimes hits an
internal error, for example `V3Processor ... Encountered an exception ... Stop
processing`. This can leave one app unprocessed while others install. Run
`Restart-Service IntuneManagementExtension`, reboot, or wait for the hourly
check-in; it usually clears on a later pass. Confirm progress in
`AppWorkload.log` by searching for `Oryo`.

## 9. Test rig: an Azure VM

A local Windows Home machine cannot do this, since Home cannot Entra join. An
Azure VM is a convenient test rig: it runs Enterprise, which can.

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

For a single throwaway box you can skip Intune entirely and install by hand,
which is the quickest way to check a new deployment end to end:

```powershell
msiexec /i Oryo.msi /qn SENSORCONFIGURL="https://api.<your-domain>/v1/sensor/config"
New-Item -Path "HKLM:\SOFTWARE\Policies\Oryo" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Oryo" -Name RegistrationToken -Value "sk_oryo_..."
Restart-Service OryoSensor
```

## 10. macOS

Two Intune resources, no script editing:

1. Custom configuration profile: the organization's signed `.mobileconfig`,
   which carries `RegistrationToken`, `SensorConfigURL` and `Username` set to
   `{{userprincipalname}}` (Intune substitutes this per user). Deployment
   channel Device. Requires user-affinity enrollment. `SensorConfigURL` plays
   exactly the role section 4 describes for Windows.
2. macOS app: `Oryo.dmg` from your dashboard's Settings > Installation.

The sensor reads the staged values from
`/Library/Managed Preferences/io.oryo.sensor.plist`.
