# Microsoft Entra ID integration

Oryo reads your user directory through an app registration you create in your own Entra tenant. It signs in with a client secret; no certificate is needed. It only reads, and never changes anything in your tenant.

Granting admin consent (step 3) needs Global Administrator or Privileged Role Administrator.

## 1. Create the app registration

1. In the Azure portal (`portal.azure.com`, or `portal.azure.us` for Azure Government), open **App registrations** → **New registration**.
2. Name it anything, for example `Oryo Platform`. Pick **Accounts in this organizational directory only**. Leave the redirect URI blank.
3. Click **Register**. From the **Overview** page, copy the **Application (client) ID** and the **Directory (tenant) ID**.

## 2. Create a client secret

1. Open **Certificates & secrets** → **Client secrets** → **New client secret**. Pick an expiry and click **Add**.
2. Copy the **Value** column right away. Azure shows it only once.

> The list has two columns, **Value** and **Secret ID**. Oryo needs the **Value**. Pasting the Secret ID is the most common reason the credential test fails.

## 3. Grant the Graph permission

1. Open **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions** (not Delegated).
2. Tick `User.Read.All` and click **Add permissions**.
3. Click **Grant admin consent for \<your organization\>**. The row should show a green check.

## 4. Enter the credentials in Oryo

In the dashboard, add the Microsoft Entra ID integration:

| Oryo field | Value from Azure |
|---|---|
| Account ID | Directory (tenant) ID |
| Client ID | Application (client) ID |
| Client Secret | the secret's **Value** |

The **Account ID** field takes the tenant ID. Oryo uses it to know which tenant to sign in to.

Then run the credential test. It gets a token and reads one user from Microsoft Graph.

## Azure Government (GCC High / DoD)

Oryo signs in against the commercial cloud by default. For an Azure Government tenant, set the government endpoints under `global.env` in your values file and run `helm upgrade`:

```yaml
global:
  env:
    MICROSOFT_AUTHORITY: https://login.microsoftonline.us
    MICROSOFT_GRAPH: https://graph.microsoft.us
```

Without them, the credential test fails even when the app registration is right. Commercial and GCC (non-High) tenants need nothing here. The full list of endpoint overrides is in [runbook.md](runbook.md#cloud-partition-and-endpoint-overrides-optional).

## When the credential test fails

Microsoft's exact error is in the workers log:

```bash
kubectl -n <namespace> get deploy | grep workers
kubectl -n <namespace> logs deploy/<workers-deployment> --since=1h | grep -A3 "Credentials check failed"
```

| Error | Usual cause |
|---|---|
| `AADSTS7000215` invalid client secret | The Secret ID was pasted instead of the Value, or the secret expired. |
| `AADSTS90002` tenant not found | Account ID isn't the tenant ID, or an Azure Government tenant is missing the settings above. |
| `Authorization_RequestDenied` | `User.Read.All` was added as Delegated, or admin consent wasn't granted. |
| Timeout or connection error | The cluster can't reach `login.microsoftonline.com` and `graph.microsoft.com` (or the `.us` hosts) over HTTPS. |

## What Oryo reads

User profile fields only: id, display name, email, user principal name, given name, surname, account enabled, user type, created date, job title, department, office location and mobile phone. Credentials are stored encrypted, per tenant.

When the secret nears expiry, create a new one and paste its Value into the integration.
