---
sidebar_position: 1
---

# Pipeline YAML Configuration

The `monitor-pipeline.yml` file defines how and when PIM Monitor runs in Azure DevOps.

## Schedule

```yaml
schedules:
  - cron: "0 */6 * * *"
    displayName: "PIM Change Scan (4x daily)"
    branches:
      include: [main]
    always: true
```

Common patterns:

| Pattern | Meaning |
|---|---|
| `0 */6 * * *` | Every 6 hours (4x daily, default) |
| `0 * * * *` | Every hour |
| `0 9 * * *` | Daily at 9 AM UTC |
| `0 9 * * 1-5` | Weekdays at 9 AM UTC |

Standard cron syntax: `minute hour day month day-of-week`

## Service connection

```yaml
steps:
  - task: AzurePowerShell@5
    inputs:
      azureSubscription: "pim-monitor-service-connection"
```

Replace `pim-monitor-service-connection` with the name of your Workload Identity Federation service connection (created during [installation](../getting-started/installation.md)).

## Environment variables

```yaml
variables:
  NOTIFICATION_EMAIL: $(NOTIFICATION_EMAIL)
  NOTIFICATION_MAIL_FROM: $(NOTIFICATION_MAIL_FROM)
  NOTIFICATION_WEBHOOK_URL: $(NOTIFICATION_WEBHOOK_URL)
  NOTIFICATION_MIN_SEVERITY: $(NOTIFICATION_MIN_SEVERITY)
```

These reference pipeline variables set in the Azure DevOps UI. Leave them unset to disable notifications.

### Setting variables in Azure DevOps

1. Go to **Pipelines** > **PIM Monitor**
2. Click **Edit** > **Variables** (top right)
3. Add your variables:

| Name | Example value |
|---|---|
| `NOTIFICATION_EMAIL` | `security-team@contoso.com` |
| `NOTIFICATION_MAIL_FROM` | `pim-monitor@contoso.com` |
| `NOTIFICATION_WEBHOOK_URL` | `https://outlook.webhook.office.com/webhookb2/...` |
| `NOTIFICATION_MIN_SEVERITY` | `Medium` |

All are optional. See [Notifications](./notifications.md) for details.

## Pipeline steps

### 1. Checkout

```yaml
- checkout: self
  persistCredentials: true
  displayName: "Checkout repository"
```

Clones the repo and sets up git credentials for pushing. Required.

### 2. Install Microsoft.Graph module

```yaml
- task: PowerShell@2
  inputs:
    script: |
      Install-Module -Name Microsoft.Graph -Force -SkipPublisherCheck
```

Optional but recommended. The scripts also work with `Invoke-RestMethod` directly.

### 3. Run the scan

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "pim-monitor-service-connection"
    ScriptPath: "$(Build.SourcesDirectory)/src/Scan-PimState.ps1"
    pwsh: true
```

Runs the main scan script using a token acquired via WIF. Required.

### 4. Configure git

```yaml
- script: |
    git config user.name "PIM Monitor"
    git config user.email "pim-monitor@pipeline"
  displayName: "Configure git user"
```

Sets the commit author. Required for git operations.

### 5. Commit and push

```yaml
- script: |
    git add inventory/ expected-changes.json 2>/dev/null || true
    if git diff --cached --quiet; then
      echo "##[section] No changes detected"
    else
      git commit -m "scan: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      git push origin HEAD:main
    fi
  displayName: "Commit and push inventory changes"
```

Only commits and pushes when files have changed. `expected-changes.json` is included so consumed/expired suppression entries are cleaned up in the same commit. Required.

## Common customizations

### Change the commit message format

```bash
git commit -m "chore: pim scan at $(date -u +%Y-%m-%d)"
```

### Store inventory in a subfolder

Edit `Scan-PimState.ps1` line 51:

```powershell
$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "security/pim-inventory"
```

Update the git step to match:

```bash
git add security/pim-inventory/
```

### Allow manual triggers

Add this to the top of the pipeline file:

```yaml
trigger: none
pr: none

schedules:
  - cron: "0 */6 * * *"
    displayName: "PIM Change Scan (4x daily)"
    branches:
      include: [main]
    always: true
```

Users can now click **Run** manually in the Azure DevOps UI.

### Enable HTML report artifacts

Set `REPORT_ARTIFACT` to `true` as a pipeline variable. When enabled, the pipeline writes a `scan-report.html` file and publishes it as a build artifact after each run that detected changes. Runs with no changes produce no artifact.

The report uses the same HTML format as the email notification. Find it under **Pipelines** > select a run > **Artifacts** > `scan-report`.

| Variable | Value |
|---|---|
| `REPORT_ARTIFACT` | `true` |

Leave the variable unset (or set it to anything other than `true`) to disable this feature.

## Troubleshooting

**Pipeline runs but nothing gets committed**
- Check logs for errors in the scan step
- Verify `persistCredentials: true` is set on checkout
- Ensure the service connection has `admin:repo_hook` scope (if using a PAT)

**`Unauthorized` error from Graph API**
- Verify the WIF federated credential is configured correctly
- Check that the service principal has the required Graph API permissions

See [Installation troubleshooting](../getting-started/installation.md#troubleshooting) for more help.

## Next

[Notifications](./notifications.md) - configure email and webhook alerts.
