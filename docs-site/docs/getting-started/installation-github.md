---
sidebar_position: 2
---

# Installation . GitHub Actions

Deploy PIM Monitor on GitHub using GitHub Actions and OIDC authentication.

## Prerequisites

- GitHub repository
- Azure subscription with Entra ID admin access
- Global Administrator or Privileged Role Administrator (to grant application consent)

## Step 1: Create Azure App Registration

In Azure Entra ID:

1. **App registration**: Create new app `PIM Monitor GitHub`
2. **Grant application permissions** (Microsoft Graph):

| Permission | Purpose |
|---|---|
| `RoleManagement.Read.Directory` | Read role definitions and assignments |
| `RoleAssignmentSchedule.Read.Directory` | Read PIM active schedules |
| `RoleEligibilitySchedule.Read.Directory` | Read PIM eligible schedules |
| `RoleManagementPolicy.Read.Directory` | Read PIM policies |
| `PrivilegedAccess.Read.AzureADGroup` | Read PIM Groups |
| `Policy.Read.ConditionalAccess` | Read authentication contexts |
| `User.Read.All` | Resolve principal names |
| `Group.Read.All` | Read group details |
| `AdministrativeUnit.Read.All` | Read AU metadata |
| `AuditLog.Read.All` | Read activation events from audit log |
| `Mail.Send` _(optional)_ | Send email notifications via Graph |

3. **Federated credentials**: Add a GitHub federation
   - Scenario: `GitHub Actions deploying Azure resources`
   - Organization / Repository: your GitHub repo (`OWNER/REPO`)
   - Entity type: `Branch`
   - Branch: `main` (or your default branch)

Record your **Client ID**, **Tenant ID**, and **Subscription ID** from the app registration overview.

## Step 2: Configure repository secrets and variables

In your GitHub repository go to **Settings** > **Secrets and variables** > **Actions**.

**Secrets** (sensitive values, never visible after saving):

| Secret | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID |
| `AZURE_TENANT_ID` | Tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID |
| `NOTIFICATION_EMAIL` | _(optional)_ Email recipient |
| `NOTIFICATION_MAIL_FROM` | _(optional)_ Sender mailbox (requires `Mail.Send`) |
| `NOTIFICATION_WEBHOOK_URL` | _(optional)_ Teams, Slack, Discord, or custom webhook URL |

**Variables** (non-sensitive config, set on the Variables tab):

| Variable | Default | Values | Purpose |
|---|---|---|---|
| `NOTIFICATION_MIN_SEVERITY` | `Medium` | `High` `Medium` `Low` `Informational` | Minimum severity to notify on |
| `EXPIRING_WINDOW_DAYS` | `14` | any number | Days ahead to flag expiring assignments |
| `REPORT_ARTIFACT` | _(unset)_ | `true` | Upload HTML report as workflow artifact |

Leave notification secrets unset to run without notifications. The workflow will still scan and commit inventory changes.

## Step 3: Set workflow permissions

In your GitHub repository go to **Settings** > **Actions** > **General**:

- **Workflow permissions**: select **Read and write permissions**

This allows the workflow to commit inventory changes back to the repository.

## Step 4: Verify the workflow file

The workflow file `.github/workflows/scan.yml` is already in the repository. Confirm two things before the first run:

- The trigger schedule matches your requirement (default: every 6 hours, `cron: '0 */6 * * *'`)
- The `environment: production` line matches your GitHub environment name, or remove it if you are not using GitHub environments

The `MSGRAPH_VERSION` variable in the workflow pins the Microsoft.Graph module version used for scanning. Update it when you want to upgrade the module.

## Step 5: First run

1. Go to **Actions** in your repository
2. Select **PIM Monitor Scan** from the workflow list
3. Click **Run workflow** > **Run workflow**
4. Watch the run logs for:
   - `Authenticate to Azure` completing successfully
   - `Run PIM Monitor scan` fetching roles and groups
   - `Commit and push changes` (only appears if changes were found)

The first run always detects changes because there is no previous inventory to compare against.

## GitHub Environments (optional)

GitHub Environments add approval gates and environment-scoped secrets on top of repository-level secrets.

To use one:

1. In **Settings** > **Environments**, create an environment named `production`
2. Move the Azure and notification secrets to the environment (remove them from repository secrets)
3. Configure protection rules (e.g., require a reviewer before the workflow runs)

The workflow already references `environment: production`. Remove that line if you are not using environments.

## OIDC Federation Details

The federated credential subject must match exactly what GitHub sends during the workflow run.

| Scenario | Subject |
|---|---|
| Specific branch (recommended) | `repo:OWNER/REPO:ref:refs/heads/main` |
| GitHub environment | `repo:OWNER/REPO:environment:production` |
| Any branch (less secure) | `repo:OWNER/REPO:ref:*` |

Replace `OWNER/REPO` with your repository path and `main` with your default branch.

If you use a GitHub environment, the subject must use the `environment:` form, not the `ref:` form.

## Testing with `act` (optional)

Test the workflow locally before pushing using [act](https://nektosact.com):

```bash
# Install (macOS)
brew install act

# Create a secrets file in the repo root (never commit this)
cat > .secrets <<EOF
AZURE_CLIENT_ID=<value>
AZURE_TENANT_ID=<value>
AZURE_SUBSCRIPTION_ID=<value>
EOF

# Run the scan workflow locally
act -j scan --secret-file .secrets
```

OIDC token exchange does not work in `act`. For local scanning without OIDC, use the [interactive local test](./local-testing.md) instead.

## GitHub Actions vs Azure DevOps

| Feature | GitHub Actions | Azure DevOps |
|---|---|---|
| **Authentication** | OIDC (built-in) | WIF via AzurePowerShell@5 |
| **Secrets** | Settings → Secrets | Pipeline → Variables |
| **Schedule** | `on: schedule` | `schedules:` |
| **Approval gates** | GitHub Environments | Pipeline checks |
| **Module cache** | actions/cache@v4 | Built-in pipeline caching |
| **Artifacts** | Built-in artifact storage | Artifact Storage |

## Troubleshooting

---

### Authentication fails (AADSTS error)

The OIDC token exchange between GitHub and Entra ID failed.

- Verify the federated credential subject matches your repository and branch exactly (copy it from the Azure portal, do not type it manually)
- Check that `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` are set correctly in repository secrets
- Ensure all Graph API permissions have admin consent granted in the app registration

---

### No changes committed after first run

The scan completed but wrote nothing to git.

- Check the workflow logs for errors in the `Run PIM Monitor scan` step
- Verify all required Graph API permissions have admin consent (not just requested)
- Confirm **Read and write permissions** is enabled under Settings > Actions > General

---

### Notifications not sent

- Verify `NOTIFICATION_WEBHOOK_URL` or `NOTIFICATION_EMAIL` are set as repository secrets
- Check that the sender mailbox has `Mail.Send` permission on the app registration with admin consent
- Check that `NOTIFICATION_MIN_SEVERITY` is set to a level that includes the detected changes (`Informational` captures everything)

---

### Module installation is slow

`Install-Module Microsoft.Graph` takes 1-2 minutes on the first run. This is expected. Subsequent runs restore the module from the runner cache and skip the install step entirely.

---

## Next

[Customize PIM Monitor](../customize/index.md) - schedule, notifications, severity rules, and more.
