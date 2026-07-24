# Deploying the Oryo Sensor with Microsoft Intune (Windows)

This guide covers deploying the Oryo sensor to Windows endpoints with Intune. It
lists the prerequisites, the resources you create, verification steps, and a
troubleshooting section. macOS is covered briefly at the end; see
[`macos-install-guide.txt`](../macos-install-guide.txt) for the full macOS flow.

## 1. Prerequisites

Confirm all three before creating any apps. Most "stuck on Waiting for install
status" cases are a missing prerequisite rather than a problem with the package.

| Requirement | Reason | Check |
|---|---|---|
| Device is Microsoft Entra joined (not registered) | Only joined devices receive the Intune Management Extension (IME), which runs Win32 app installs. Registered or BYOD devices never receive it, so Win32 apps stay on "Waiting". | `dsregcmd /status` shows `AzureAdJoined : YES` |
| Windows edition is Pro, Enterprise, or Education | Windows Home cannot be Entra joined; it can only register. A Home device cannot receive a Win32 deployment. | `(Get-CimInstance Win32_OperatingSystem).Caption` |
| Device is enrolled in Intune | Enrollment delivers policies and apps. It happens automatically on Entra join when the MDM scope is set. | The device appears in Intune; `dsregcmd /status` shows an `MdmUrl` |

The enrollment scope lives in the Entra admin center (entra.microsoft.com), not
Intune. Set Devices > Device settings > "Users may join devices" to All, and
Devices > Mobility (MDM) > Microsoft Intune > MDM user scope to All, so an Entra
join auto-enrolls into Intune.

To check that a device can receive Win32 apps at all, see whether any other Win32
app (for example Chrome) shows Installed on it. If it does, IME works and any
remaining problem is specific to Oryo. If nothing installs, the blocker is one of
the prerequisites above.

## 2. Resources you create

1. CA certificate: a Trusted certificate profile. The Windows installer verifies
   the Oryo CA but does not install it, so Intune must.
2. Registration token: either inline on the app's install command, or written to
   the registry by a platform script.
3. The sensor app: the `oryo-install.intunewin` Win32 package.

Assign all three to the same device group.

## 3. CA certificate

1. Download the CA from the Oryo dashboard: Settings > Installation > Download CA
   (choose .cer / DER).
2. In Intune: Devices > Windows > Configuration profiles > Create > New policy >
   Windows 10 and later > Templates > Trusted certificate.
3. Upload the .cer. Set Destination store to Computer certificate store, Root.
4. Assign to the device group.

Without this, the sensor intercepts traffic but its certificates are rejected, so
browsers report certificate errors even while the sensor is running.

## 4. Registration token

Choose one option.

### Option A: inline on the install command

Put the token on the app's install command in section 5. There is nothing else to
configure. The token is visible in the app's Intune configuration.

### Option B: platform script writes it to the registry

1. Devices > Scripts and remediations > Platform scripts > Add > Windows 10 and
   later.
2. Script body (a .ps1 file, with your token):
   ```powershell
   New-Item -Path "HKLM:\SOFTWARE\Policies\Oryo" -Force | Out-Null
   Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Oryo" -Name RegistrationToken -Value "sk_oryo_..."
   ```
3. Settings that matter:
   - Run this script using the logged-on credentials: No. The script writes HKLM,
     which requires SYSTEM.
   - Run script in 64-bit PowerShell Host: Yes. This prevents the HKLM\SOFTWARE
     write from landing in WOW6432Node, where the 64-bit installer would not find
     it.
   - Enforce script signature check: No.
4. Assign to the device group.

The installer reads `HKLM\SOFTWARE\Policies\Oryo\RegistrationToken` when no
`--registration-token` is on the command line. Rotating the token means editing
the script value; the app is not redeployed.

Note that platform script status reporting lags. The Device status count can read
0 for hours after a script has run, so do not treat "0 devices" as proof that it
did not run. Confirm on the device, or use Option A.

## 5. The Win32 app

Apps > Windows > Create > Windows app (Win32).

- App package file: upload `oryo-install.intunewin` from the release bucket
  (`.../executables/<version>/oryo-install.intunewin`).
- App information: Name `Oryo Sensor`, Publisher `Oryo Identity, Inc.`
- Program:

  | Field | Value |
  |---|---|
  | Install command | `oryo-install-windows-amd64.exe` (add `--registration-token "sk_oryo_..."` for token Option A; add `--sensor-config-url "https://api.<host>/v1/sensor/config"` for a non-prod environment) |
  | Uninstall command | `"C:\ProgramData\Oryo\bin\oryo-install.exe" --uninstall` |
  | Install behavior | System |

- Requirements: OS architecture 64-bit, minimum OS Windows 10 1903.
- Detection rule (the path is important; see troubleshooting):

  | Field | Value |
  |---|---|
  | Rule type | File |
  | Path | `C:\ProgramData\Oryo\bin` |
  | File or folder | `oryo-sensor.exe` |
  | Detection method | File or folder exists |
  | 32-bit app on 64-bit clients | No |

- Assignments: Required, the device group.

The username is auto-detected from the device's Entra identity. Do not pass
`--username`.

## 6. Assign, sync, verify

1. Assign all three resources to the device group.
2. Force delivery: Devices > (device) > Sync, or run the `PushLaunch` scheduled
   task on the device. The first Win32 delivery can take 15 to 60 minutes.
3. Portal check: Apps > Oryo Sensor > Device install status shows Installed.
   Because the detection rule checks for `bin\oryo-sensor.exe`, an Installed
   status confirms that file is present on the device.
4. Device check, in an elevated PowerShell:
   ```powershell
   Get-Service OryoSensor
   & "C:\ProgramData\Oryo\bin\oryo-install.exe" --detect
   Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*Oryo*"
   ```

Recommend a reboot after the first install. Long-running applications cache DNS
and hold open TLS sessions, so the sensor's routing and the new CA only cover
connections opened afterward. A restart provides full coverage.

## 7. Key paths

| Item | Path |
|---|---|
| Sensor binary | `C:\ProgramData\Oryo\bin\oryo-sensor.exe` |
| Installer (`--uninstall`, `--detect`) | `C:\ProgramData\Oryo\bin\oryo-install.exe` |
| Updater | `C:\ProgramData\Oryo\bin\oryo-updater.exe` |
| Config | `C:\ProgramData\Oryo\config.json` |
| Install log | `C:\ProgramData\Oryo\logs\install.log` |
| Registration token (Option B) | `HKLM\SOFTWARE\Policies\Oryo\RegistrationToken` |

## 8. Troubleshooting

### App stays on "Waiting for install status" and nothing runs

IME is not on the device. The device is either Entra registered (not joined) or
running Windows Home. Neither can receive Win32 apps. Use an Entra joined Pro or
Enterprise device. Confirm with `dsregcmd /status` (`AzureAdJoined: YES`) and
`(Get-CimInstance Win32_OperatingSystem).Caption` (not Home).

### "Agent installation failed", error code 0x0, and the sensor is present on the device

Detection rule path mismatch. The rule points somewhere other than
`C:\ProgramData\Oryo\bin\oryo-sensor.exe`, so Intune cannot detect a sensor that
is present and reports it as failed. Correct the detection rule to the `bin` path
(section 5) and re-sync.

### App reports failed and the sensor is not on the device

The install failed, usually because there was no registration token. The platform
script (Option B) did not run, ran in the wrong context, or wrote to WOW6432Node.
Switch to token Option A (inline `--registration-token`), or confirm the script
runs as SYSTEM in a 64-bit host. The actual result is recorded in
`AppWorkload.log`, which you can retrieve with Collect diagnostics on the device
(under the overflow menu on the device Overview page).

### Install fails at "Downloading sensor ... : no such host" on a static-DNS machine

The OS resolver reset during install can leave a machine with no DNS when its
network provides none over DHCP. This is fixed in the installer's `osdns` restore
logic, which strips only the sensor's loopback alias and keeps the real servers.
Use a build that includes the fix. Machines that get DNS from DHCP are unaffected.

### Sensor runs but browsers report certificate errors

The Oryo CA is not trusted. The Windows installer only verifies the CA; it does
not install it. Deploy it with the Trusted certificate profile (section 3), or
import it manually:
`Import-Certificate -FilePath oryo-ca.cer -CertStoreLocation Cert:\LocalMachine\Root`.

### Sensor runs but some traffic is not intercepted

Watched domains reached over IPv6 (AAAA) or DoH (DNS over HTTPS) bypass the
loopback redirect. Handle DoH with browser policy. IPv6 coverage is tracked
separately.

### Portal reports Installed but the sensor is an old or unexpected build

The detection rule checks only that `bin\oryo-sensor.exe` exists; it does not
check how the file got there. If the device already had a sensor (a manual
install, or one the updater auto-upgraded), detection passes and Intune reports
Installed without running the install command. For a reliable test, uninstall any
pre-existing sensor first (`oryo-install.exe --uninstall`), confirm the device is
clean (`Test-Path C:\ProgramData\Oryo\bin\oryo-sensor.exe` returns False), then
run the deploy. Verify that `config.json` points at the environment you
configured.

### Token rejected due to wrong environment

The token and the config URL must be from the same environment. A dev token with
no `--sensor-config-url` uses the prod default and is rejected. Pair a dev token
with `--sensor-config-url "https://api.<dev-host>/v1/sensor/config"`. A prod token
uses the bare command, since prod is the default.

### IME installs other apps but not this one, or reports an internal exception

The Intune Management Extension processes apps in batches and sometimes hits an
internal error, for example `V3Processor ... Encountered an exception ... Stop
processing`, or `InvalidOperationException: Desired state must be set prior to
setting enforcement state`. This can leave one app unprocessed while others
install. Run `Restart-Service IntuneManagementExtension`, reboot, or wait for the
hourly check-in; it usually clears on a later pass. Confirm progress in
`AppWorkload.log` by searching for `oryo-install` or `oryo-sensor`. If there are
no matching lines, IME has not reached the app yet.

## 9. Test rig: an Azure VM

A local Windows Home machine cannot do this, since Home cannot Entra join. An
Azure VM is a convenient test rig: it runs Enterprise (which can join) and gets
DNS from DHCP (so the static-DNS issue does not apply).

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

Two Intune resources, no script editing:

1. Custom configuration profile: the organization's signed .mobileconfig, which
   carries `RegistrationToken` and `Username` set to `{{userprincipalname}}`
   (Intune substitutes this per user). Deployment channel Device. Requires
   user-affinity enrollment.
2. macOS app (PKG): `oryo-darwin-<arch>.pkg` with a post-install script that runs
   `/usr/local/bin/oryo-install`.

The installer reads the token and username from
`/Library/Managed Preferences/io.oryo.sensor.plist`. See
[`macos-install-guide.txt`](../macos-install-guide.txt) for full details.
