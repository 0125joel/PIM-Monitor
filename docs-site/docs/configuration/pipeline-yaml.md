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

## Variables

### Internal pipeline variables

```yaml
variables:
  MSGRAPH_VERSION: "2.35.1"
```

`MSGRAPH_VERSION` is the only variable defined in the YAML. It pins the Microsoft.Graph module version used by the caching step and is not meant to be changed via the UI.

### User-configurable variables

User-configurable variables are set in the Azure DevOps **Variables** panel, not in the YAML. Setting them in the YAML would shadow the UI values and make them impossible to change without editing the file.

Go to **Pipelines** > **PIM Monitor** > **Edit** > **Variables** and add whichever you need:

| Variable | Default | Purpose |
|---|---|---|
| `NOTIFICATION_EMAIL` | _(unset)_ | Email recipient |
| `NOTIFICATION_MAIL_FROM` | _(unset)_ | Sender mailbox (requires `Mail.Send`) |
| `NOTIFICATION_WEBHOOK_URL` | _(unset)_ | Teams, Slack, Discord, or custom webhook |
| `NOTIFICATION_MIN_SEVERITY` | `Medium` | Minimum severity to notify on |
| `EXPIRING_WINDOW_DAYS` | `14` | Days ahead to flag expiring assignments |
| `REPORT_ARTIFACT` | _(unset)_ | Set to `true` to publish an HTML report artifact |

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

The module install uses three steps: path detection, cache restore, and a conditional install that is skipped on a cache hit.

```yaml
- task: PowerShell@2
  name: cacheVars
  inputs:
    script: |
      $p = $env:PSModulePath.Split([IO.Path]::PathSeparator) |
           Where-Object { $_ -match 'home|user' } |
           Select-Object -First 1
      "##vso[task.setvariable variable=psUserModulePath]$p" | Write-Host
  displayName: "Detect user module path"

- task: Cache@2
  inputs:
    key: '"MSGraph" | "$(MSGRAPH_VERSION)" | "$(Agent.OS)"'
    path: "$(psUserModulePath)"
    cacheHitVar: MODULES_CACHE_HIT
  displayName: "Restore Microsoft.Graph module cache"

- task: PowerShell@2
  condition: ne(variables['MODULES_CACHE_HIT'], 'true')
  inputs:
    script: |
      Install-Module -Name Microsoft.Graph -RequiredVersion "$(MSGRAPH_VERSION)" `
        -Scope CurrentUser -Force -SkipPublisherCheck -Repository PSGallery
  displayName: "Install Microsoft.Graph module"
```

The cache key includes the module version and agent OS, so a version bump in `MSGRAPH_VERSION` automatically invalidates the cache.

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
