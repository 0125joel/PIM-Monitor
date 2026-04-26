# 09 — Authentication

## Table of Contents

1. [Workload Identity Federation](#1-workload-identity-federation)
2. [App Registration Setup](#2-app-registration-setup)
3. [Required Application Permissions](#3-required-application-permissions)
4. [Service Connection Setup](#4-service-connection-setup)
5. [Token Acquisition in the Pipeline](#5-token-acquisition-in-the-pipeline)
6. [SecureString Handling](#6-securestring-handling)
7. [Token Usage in Scripts](#7-token-usage-in-scripts)
8. [Scoping Mail.Send](#8-scoping-mailsend)

---

## 1. Workload Identity Federation

PIM Monitor uses **Workload Identity Federation (WIF)** for authentication. No client secrets, no certificates, no rotation, no leakage risk.

How WIF works:

```
Azure DevOps Pipeline (Run)
        │
        │  OIDC token (signed by ADO)
        ▼
Microsoft Entra ID (OIDC exchange)
        │
        │  Verifies: issuer + subject claim match federated credential on App Registration
        │
        ▼
Access token issued (App Registration identity, application permissions)
        │
        ▼
Microsoft Graph API
```

The pipeline's identity is the App Registration. The App Registration has application permissions directly (not delegated). No user is involved in the auth flow.

This is the same approach used by [Maester.dev](https://maester.dev/docs/monitoring/azure-devops/) for Azure DevOps-based monitoring pipelines. It is the Microsoft-recommended authentication pattern for CI/CD pipelines accessing Graph API.

---

## 2. App Registration Setup

1. In the Azure portal (or Entra admin center), navigate to **App registrations** → **New registration**.
2. Name: `pim-monitor` (or any name; the name is only for display purposes).
3. Supported account types: **Single tenant** (the tenant you want to monitor).
4. Redirect URI: leave empty (not needed for application permissions).
5. Click **Register**.
6. Note the **Application (client) ID** and **Directory (tenant) ID** — you will need these for the service connection.

---

## 3. Required Application Permissions

On the App Registration, navigate to **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**.

| Permission | Purpose |
|---|---|
| `RoleManagement.Read.Directory` | Role definitions and permanent assignments |
| `RoleAssignmentSchedule.Read.Directory` | Active (PIM-activated) assignment schedules |
| `RoleEligibilitySchedule.Read.Directory` | Eligible assignment schedules |
| `RoleManagementPolicy.Read.Directory` | PIM policy rules |
| `AuditLog.Read.All` | PIM activation events (audit log) |
| `PrivilegedAccess.Read.AzureADGroup` | PIM Group assignments and policies |
| `Mail.Send` | Email notifications (optional — only needed if email is configured) |

After adding permissions, click **Grant admin consent for {tenant}**. All permissions must show a green checkmark before the pipeline can run successfully.

> [!NOTE]
> `AuditLog.Read.All` is required for the activation events section. If this permission is not granted, the scan logs a warning and skips activation events. All other scan sections continue normally.

> [!NOTE]
> `Mail.Send` is a broad permission. If email notifications are needed but you want to limit the scope, configure an application access policy (see Section 8).

---

## 4. Service Connection Setup

In Azure DevOps, navigate to **Project settings** → **Service connections** → **New service connection** → **Azure Resource Manager** → **Workload Identity Federation (manual)**.

> [!TIP]
> Choose **manual** (not automatic). Automatic creates a new App Registration; manual uses the one you just created.

Required fields:

| Field | Value |
|---|---|
| Environment | Azure Cloud |
| Scope level | Subscription (pick any; WIF for Graph API does not need subscription access) |
| Subscription | Any accessible subscription |
| Service connection name | `pim-monitor-service-connection` (must match `monitor-pipeline.yml`) |

After creating the service connection, copy the **Issuer** and **Subject identifier** values shown in the ADO UI. In the App Registration, add a federated credential:
- **Federated credential scenario**: Other issuer
- **Issuer**: the issuer URL from ADO
- **Subject identifier**: the subject identifier from ADO
- **Name**: any descriptive name

---

## 5. Token Acquisition in the Pipeline

The `AzurePowerShell@5` task performs the OIDC exchange and makes the Az PowerShell context available within the task:

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "pim-monitor-service-connection"
    ScriptType: "FilePath"
    ScriptPath: "$(Build.SourcesDirectory)/src/Scan-PimState.ps1"
    azurePowerShellVersion: "LatestVersion"
    pwsh: true
```

Within the task context, `Get-AzAccessToken` can request a token for any resource that the App Registration has permissions to. PIM Monitor requests a token for Microsoft Graph:

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
```

The `-ResourceTypeName MSGraph` parameter is a friendly alias for the Microsoft Graph resource ID (`https://graph.microsoft.com`).

---

## 6. SecureString Handling

Starting with Az.Accounts 3.0 (part of Az module 12.0+), `Get-AzAccessToken` returns `.Token` as a `SecureString` rather than a plain string. The `-AsPlainText` parameter was not yet available in the versions tested during development.

PIM Monitor unwraps the token safely without `-AsPlainText`:

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else {
    $rawToken  # older Az versions return a plain string
}
```

`NetworkCredential::new('', $secureString).Password` extracts the plain text from a `SecureString` without writing it to disk or exposing it in memory longer than necessary. The `else` branch handles older Az versions for forward/backward compatibility.

---

## 7. Token Usage in Scripts

The plain-text token is stored in `$token` (a local variable in the orchestrator) and passed explicitly to functions that need it. It is never stored in a file or environment variable.

All Graph API calls use the token as a Bearer header:

```powershell
$headers = @{ Authorization = "Bearer $token" }
Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
```

For `Get-AllGraphItems`:

```powershell
$results = Get-AllGraphItems -Uri $uri -AccessToken $token
```

For `Send-EmailNotification`:

```powershell
Send-EmailNotification -AccessToken $token ...
```

---

## 8. Scoping Mail.Send

`Mail.Send` as an application permission allows the App Registration to send email as any mailbox in the tenant. To restrict it to a specific sender mailbox, configure an [application access policy](https://learn.microsoft.com/en-us/graph/auth-limit-mailbox-access):

```powershell
# Requires Exchange Online PowerShell
New-ApplicationAccessPolicy `
    -AppId "<App Registration client ID>" `
    -PolicyScopeGroupId "<mailbox or mail-enabled security group>" `
    -AccessRight RestrictAccess `
    -Description "Restrict PIM Monitor to pim-monitor@contoso.com"
```

This policy restricts `sendMail` to the specified mailbox only, without changing the permission grant on the App Registration. Any attempt to send from a different mailbox will be rejected by Graph.
