---
sidebar_position: 1
description: Prerequisites for deploying PIM Monitor including Azure DevOps setup, Entra ID permissions, app registration configuration, and Graph API scopes.
---

# Prerequisites

You'll need the following before deploying PIM Monitor.

## Azure DevOps

- An Azure DevOps organization with pipelines enabled
- A git repo where PIM Monitor will push inventory changes
- Stakeholder access or higher (to create pipelines)

## Microsoft Entra ID

- Global Administrator or Privileged Role Administrator (to grant application consent)
- A custom app registration for Workload Identity Federation (WIF) authentication

### Service principal setup

**1. Create an app registration**

- Name: `PIM-Monitor-Pipeline`
- Supported account types: Single tenant
- No redirect URI needed

**2. Grant application permissions to Microsoft Graph**

| Permission | Purpose |
|---|---|
| `RoleManagement.Read.Directory` | Read role definitions and assignments |
| `RoleAssignmentSchedule.Read.Directory` | Read PIM active schedules |
| `RoleEligibilitySchedule.Read.Directory` | Read PIM eligible schedules |
| `RoleManagementPolicy.Read.Directory` | Read PIM policies |
| `Policy.Read.ConditionalAccess` | Read authentication contexts |
| `User.Read.All` | Resolve principal names |
| `Group.Read.All` | Read group details |
| `AdministrativeUnit.Read.All` | Read AU metadata |
| `AuditLog.Read.All` | Read activation events from audit log |
| `PrivilegedAccess.Read.AzureADGroup` | Read PIM Groups |
| `Mail.Send` (optional) | Send emails via Graph |

**3. Configure Workload Identity Federation**

Workload Identity Federation (WIF) lets Azure DevOps authenticate to Microsoft Graph without storing secrets.

**Important:** Complete the Azure DevOps service connection setup FIRST (step 5 below), then return here with the Issuer and Subject identifier that ADO generates for you. ADO creates these automatically, and you must use ADO's exact values (not manually constructed ones).

**Step 3a. Start the service connection in Azure DevOps:**

1. In your Azure DevOps project, go to **Project settings** > **Service connections**
2. Click **New service connection** and select **Azure Resource Manager**
3. Select authentication method: **Workload Identity Federation (automatic)**
4. Fill in subscription details (Subscription ID, Subscription name, Tenant ID, Client ID from step 4 above, Service connection name)
5. Click **Next** (do not click Verify and save yet)

This generates your WIF issuer and subject identifier. Copy these values now.

**Step 3b. Create the federated credential in Entra ID:**

In the app registration, go to **Certificates & secrets** > **Federated credentials** > **Add credential**.

Fill in these fields with the values ADO generated:

| Field | Value | Notes |
|---|---|---|
| **Federated credential scenario** | `Other issuer` | Do not select "Azure DevOps" |
| **Issuer** | From ADO Step 3 (Issuer field) | Copy the full URL, including `/v2.0` at the end. Do not truncate. |
| **Type** | `Explicit subject identifier` | Default radio button |
| **Subject identifier** | From ADO Step 3 (Subject identifier field) | Copy the full value exactly as shown in ADO |
| **Name** | `azure-devops-pim-monitor` | Cannot be changed after creation |
| **Description** | `WIF federation for PIM Monitor pipeline` | Optional |
| **Audience** | `api://AzureADTokenExchange` | Default. Do not change. |

Click **Save** when done.

**Important notes:**
- The Issuer is tenant-specific and includes `/v2.0`. Copy it exactly from ADO including the full URL.
- The Subject identifier is a long string generated uniquely for your ADO repo. Copy it in full.
- Both must match exactly what ADO provided. A mismatch will cause verification to fail (see troubleshooting below).

**4. Save your app registration IDs** (you'll need these for the service connection)

Go to the app registration **Overview** tab and copy:
- **Application (client) ID**
- **Directory (tenant) ID**

Save these somewhere safe. You'll paste them into Azure DevOps in the next step.

## Complete the Azure DevOps service connection

After creating the federated credential in Entra ID, return to Azure DevOps and complete the service connection.

1. Back in Azure DevOps service connection form (after clicking **Next** in step 3a), you should now see the **Issuer** and **Subject identifier** fields populated.

2. Click **Verify and save**.

Azure DevOps will test the WIF connection. If successful, your service connection is ready.

### Grant subscription permissions to the app registration

The app registration needs Reader role on the subscription to allow ADO to verify the connection.

1. Go to **Azure Portal** > **Subscriptions** > your subscription
2. Click **Access control (IAM)**
3. Click **Add** > **Add role assignment**
4. Select role: **Reader** (PIM Monitor only reads from Graph, not Azure resources, but ADO requires this for verification)
5. Click **Members** tab
6. Search for `PIM-Monitor-Pipeline` and select it
7. Click **Review + assign**

Return to Azure DevOps and click **Verify and save** again. The connection should now succeed.

## Local testing (optional)

If you want to test scripts locally before deploying:

- PowerShell 7+ (`choco install pwsh` on Windows, `brew install powershell` on macOS)
- Azure CLI (`az` available in PATH)
- Microsoft Graph PowerShell SDK (installed by the script, or `Install-Module Microsoft.Graph`)

## Troubleshooting

### "No matching federated identity record found" (AADSTS700211)

**Error message:** `AADSTS700211: No matching federated identity record found for presented assertion issuer`

**Cause:** The Issuer in your Entra ID federated credential does not match the Issuer that ADO is using.

**Solution:**
1. Delete the federated credential in Entra ID (trash icon)
2. In Azure DevOps service connection form, click in the **Issuer** field and select all (Cmd+A or Ctrl+A)
3. Copy the complete Issuer URL (ensure you capture the full URL including `/v2.0` at the end, not truncated)
4. In Entra ID, create a new federated credential and paste the full Issuer URL
5. Verify the Subject identifier also matches exactly
6. Click **Save**
7. In Azure DevOps, click **Verify and save** again

### "AuthorizationFailed" on subscription read (403 Forbidden)

**Error message:** `The client '...' does not have authorization to perform action 'Microsoft.Resources/subscriptions/read' over scope '/subscriptions/...'`

**Cause:** The app registration does not have permissions on the Azure subscription.

**Solution:**
1. Go to **Azure Portal** > **Subscriptions** > your subscription ID (shown in the error)
2. Click **Access control (IAM)**
3. Click **Add role assignment**
4. Select role: **Reader**
5. Search for and select `PIM-Monitor-Pipeline`
6. Click **Review + assign**
7. Return to Azure DevOps and click **Verify and save** again

### Service connection "Verify and save" hangs or times out

**Cause:** Network connectivity or service delays.

**Solution:**
1. Wait 30 seconds and try again
2. If it persists, delete the service connection draft and create a new one
3. Ensure your app registration has the Reader role on the subscription (see above)
4. Ensure the federated credential was successfully created in Entra ID

## Next

[Local Testing](./local-testing.md) - run a scan locally before deploying to the pipeline.
