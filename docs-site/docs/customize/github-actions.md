---
sidebar_position: 3
---

# GitHub Actions Setup

Complete guide for configuring PIM Monitor on GitHub Actions. The scan workflow is defined in `.github/workflows/scan.yml`.

## Initial Setup

### Prerequisites

- GitHub repository with write access
- Azure AD tenant with PIM-enabled roles
- Service principal with appropriate Graph API permissions
- GitHub environment (optional, for approval gates)

### 1. Set Up OIDC Authentication

PIM Monitor uses OpenID Connect (OIDC) for token exchange instead of storing credentials.

**In Azure AD:**
1. Register an app for your GitHub Actions workflow
2. Configure federated credentials:
   - Entity type: `GitHub Actions workflow`
   - Organization: `joel-prins` (your GitHub org)
   - Repository: `PIM-Monitor`
   - Entity type: Environment (optional)
   - Name: `production`

**In GitHub:**
1. Go to **Settings** → **Environments** → **New environment** → `production`
2. (Optional) Add required reviewers for approval gates
3. Store Azure values as **Secrets** → **Actions**:

```
AZURE_CLIENT_ID        = <app-id>
AZURE_TENANT_ID        = <tenant-id>
AZURE_SUBSCRIPTION_ID  = <subscription-id>
```

The workflow will use these to exchange the GitHub JWT for an Azure token.

### 2. Configure Secrets

**Notification credentials** (if using email or webhooks):

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**

| Secret Name | Value |
|---|---|
| `NOTIFICATION_EMAIL` | `security-team@contoso.com` |
| `NOTIFICATION_MAIL_FROM` | `pim-monitor@contoso.onmicrosoft.com` |
| `NOTIFICATION_WEBHOOK_URL` | `https://hooks.slack.com/services/...` |

### 3. Configure Variables (Non-secret)

1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click the **Variables** tab
3. Click **New repository variable**

| Variable Name | Value |
|---|---|
| `NOTIFICATION_MIN_SEVERITY` | `Medium` |
| `EXPIRING_WINDOW_DAYS` | `14` |
| `REPORT_ARTIFACT` | `true` |

## Workflow Configuration

### Understanding the Trigger

The workflow in `.github/workflows/scan.yml` is triggered by:

1. **Schedule** (default: every 6 hours)
   ```yaml
   schedule:
     - cron: '0 */6 * * *'
   ```

2. **Manual trigger** (workflow_dispatch)
   - Click **Actions** → **PIM Change Scan** → **Run workflow** in GitHub UI

### Changing the Schedule

Edit `.github/workflows/scan.yml`:

```yaml
on:
  schedule:
    - cron: '0 */6 * * *'   # every 6 hours (default)
  workflow_dispatch:         # allow manual trigger
```

**Common cron patterns:**
```
0 * * * *       = Every hour
0 */3 * * *     = Every 3 hours
0 9 * * 1-5     = Weekdays at 9 AM UTC
0 0 * * 0       = Weekly (Sunday midnight UTC)
```

### Job Configuration

The scan job has a few key settings:

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    environment: production  # optional: requires approval
    permissions:
      id-token: write       # required for OIDC
      contents: write       # required for git push
      packages: read        # for accessing artifacts
```

**Important**:
- `id-token: write` is required for OIDC token exchange
- `contents: write` is required to commit and push changes
- `timeout-minutes: 30` prevents long-running jobs; increase if needed

### Module Caching

The workflow caches the Microsoft.Graph PowerShell module to speed up runs:

```yaml
- name: Cache Microsoft.Graph module
  uses: actions/cache@v4
  with:
    path: ~/.local/share/powershell/Modules/Microsoft.Graph
    key: msgraph-${{ env.MSGRAPH_VERSION }}-${{ runner.os }}
```

**To invalidate the cache**: Change `MSGRAPH_VERSION` in `.github/workflows/scan.yml`.

## Environment-Specific Configuration

### Production Approval Gates

If you want approval before scans run in production:

1. Create a GitHub environment called `production`
2. Add required reviewers in **Settings** → **Environments** → **production** → **Required reviewers**
3. The workflow will wait for approval before executing

```yaml
jobs:
  scan:
    environment: production  # adds approval requirement
```

### Multiple Environments

If you have dev/staging/prod, create separate workflows or branch triggers:

```yaml
name: PIM Scan - Production
on:
  schedule:
    - cron: '0 */6 * * *'
jobs:
  scan:
    if: github.ref == 'refs/heads/main'
    # ... rest of job
```

## Artifacts & Reports

### Enabling HTML Report Artifact

Set `REPORT_ARTIFACT=true` in your repository variables.

The workflow will generate `scan-report.html` and attach it to the run:

1. Go to **Actions** → **PIM Change Scan** → **[latest run]**
2. Scroll down to **Artifacts**
3. Download `scan-report.html`

### Accessing Artifacts Programmatically

```bash
# Download latest report from main branch
gh run download -n scan-report.html -D . \
  -R owner/PIM-Monitor
```

## Local Testing with `act`

Test your workflow locally before pushing:

### Install `act`

```bash
# macOS
brew install act

# Linux
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash
```

### Set Up Secrets Locally

Create `.secrets` file in repo root:

```
AZURE_CLIENT_ID=<value>
AZURE_TENANT_ID=<value>
AZURE_SUBSCRIPTION_ID=<value>
NOTIFICATION_EMAIL=test@example.com
NOTIFICATION_WEBHOOK_URL=https://...
```

### Run Workflow Locally

```bash
# Run the scan workflow
act -j scan --secret-file .secrets

# View available jobs
act --list

# Run with debug output
act -j scan --secret-file .secrets --verbose
```

**Note**: OIDC token exchange may not work in local `act` environment; you may need to mock the token response.

## Troubleshooting

### Workflow not running on schedule

**Check**: 
- Is the repository public? (GitHub free plan requires public repos for scheduled workflows)
- Are workflows enabled? **Actions** → check that workflows aren't disabled
- Branch default is `main`? Schedule only runs on default branch

### OIDC token exchange failing

**Error**: `"Failed to acquire Graph API access token"`

**Solutions**:
1. Verify federated credential is configured in Azure AD (see Initial Setup step 1)
2. Check `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` are correct secrets
3. Ensure app has Graph API permissions: `Directory.Read.All`, `RoleAssignmentSchedule.Read.Directory`, `Mail.Send` (if email enabled)
4. If recently created, wait 5-10 minutes for credential sync

### Notifications not sending

**Check**:
1. Are `NOTIFICATION_EMAIL` + `NOTIFICATION_MAIL_FROM` both set? (both required)
2. Does the service principal have `Mail.Send` permission? Check Azure AD app permissions
3. Is `NOTIFICATION_MIN_SEVERITY` set to a valid value? (High, Medium, Low, Informational)
4. Check workflow run logs: **Actions** → **[workflow]** → **scan** → Scroll for warning messages

### Module cache not working

**Check**:
1. Is `MSGRAPH_VERSION` set correctly? (default: 2.35.1)
2. Changed version recently? Cache key includes version; old cache is invalid
3. Is cache key path correct? Should be `~/.local/share/powershell/Modules/Microsoft.Graph`

### Artifacts not generated

**Check**:
1. Is `REPORT_ARTIFACT=true` set in repository variables?
2. Were any changes detected? Reports only generate when changes exist
3. Check workflow logs for permission errors on artifact staging

## Compared to Azure DevOps

| Feature | GitHub Actions | Azure DevOps |
|---------|---|---|
| **Authentication** | OIDC (built-in) | WIF/OIDC (via AzurePowerShell@5) |
| **Secrets** | Settings → Secrets | Pipeline → Variables |
| **Artifacts** | Built-in artifact storage | Artifact Storage |
| **Environment** | GitHub Environments | Deployment jobs |
| **Approval Gates** | Environment approval | Checks |
| **Caching** | actions/cache@v4 | Built-in pipeline caching |

## Related Pages

- [Environment Variables](./environment-variables.md) — All configurable variables
- [Pipeline Configuration](./pipeline.md) — Schedule, commit format, and Azure DevOps setup
- [Email Notifications](./email-notifications.md) — Email setup
- [Webhook Channels](./webhook-channels.md) — Teams, Slack, Discord webhooks
