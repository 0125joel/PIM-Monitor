---
sidebar_position: 4
description: Configure the PIM Monitor pipeline schedule, trigger conditions, and pipeline variables in Azure DevOps and GitHub Actions.
---

# Pipeline Configuration

Configure scan schedule, commit behavior, inventory storage, module versions, and more.

## Quick Reference

| Setting | File | Default | Purpose |
|---------|------|---------|---------|
| Schedule (cron) | `monitor-pipeline.yml` / `.github/workflows/scan.yml` | `0 */6 * * *` | How often scan runs |
| Upstream update check | `NOTIFY_UPSTREAM_UPDATE` | Enabled | Notify when a newer release is published upstream |
| Inventory path | `src/Scan-PimState.ps1` | `./inventory/` | Where state is stored |
| Commit message | `monitor-pipeline.yml` / `.github/workflows/scan.yml` | ISO 8601 timestamp | Git commit format |
| Git author | `src/git.ps1` | "PIM Monitor" | Author name |
| Module version | `monitor-pipeline.yml` / `.github/workflows/scan.yml` | `2.35.1` | PowerShell module version |
| HTML report | Pipeline variable | Unset | Generate scan report artifact |
| Expiring window | Pipeline variable | `14` days | Expiring assignment detection |

## Schedule & Triggers

### Change the scan schedule

Edit the cron expression in `monitor-pipeline.yml` (Azure DevOps) or `.github/workflows/scan.yml` (GitHub Actions):

**Azure DevOps**:
```yaml
schedules:
  - cron: "0 */6 * * *"
    displayName: "PIM Change Scan (4x daily)"
    branches:
      include: [main]
    always: true
```

**GitHub Actions**:
```yaml
on:
  schedule:
    - cron: '0 */6 * * *'
```

### Cron Pattern Guide

```
0 */6 * * *   = Every 6 hours (default)
0 * * * *     = Every hour
0 */3 * * *   = Every 3 hours
0 9 * * *     = Daily at 9 AM UTC
0 9 * * 1-5   = Weekdays at 9 AM UTC
0 0 * * 0     = Weekly (Sunday midnight UTC)
*/30 * * * *  = Every 30 minutes
```

**Why not every minute?**
- Graph API throttling (429 errors on frequent requests)
- Noise reduction (PIM changes rarely occur every minute)
- Cost efficiency (fewer pipeline runs = lower compute costs)

### Check for upstream updates on GitHub

At the start of each run, the pipeline compares the `VERSION` file in your copy against the latest published release of the upstream repository. If a newer release exists, a warning is written to the run log. If notification channels are configured, a notification is also sent via webhook and/or email.

This check runs before the scan so the warning appears early in the run log. The notification is sent at the very end of the run (after artifact publishing), using the same channels configured for PIM change notifications.

**What it checks**: the latest release tag of `https://github.com/0125joel/PIM-Monitor` against your local `VERSION` file, compared with semantic version ordering.

**Run log output** (when an update is available):
```
PIM Monitor 0.4.0 is available (running 0.3.0). See https://github.com/0125joel/PIM-Monitor/releases/tag/v0.4.0
```

**Disabling the notification**: set `NOTIFY_UPSTREAM_UPDATE` to `false` in your pipeline variables (Azure DevOps) or repository variables (GitHub Actions). The check step itself still runs and logs; only the webhook/email notification is suppressed.

:::note
This runs on both Azure DevOps and GitHub Actions. Both run from a checked-out copy of the repo and can drift behind upstream releases, so both perform the version check.
:::

### Allow manual triggers

**Azure DevOps**:
```yaml
trigger: none
pr: none

schedules:
  - cron: "0 */6 * * *"
    displayName: "PIM Change Scan"
    branches:
      include: [main]
    always: true
```

Users can then click **Run** in the Azure DevOps UI without waiting for schedule.

**GitHub Actions** (enabled by default):
```yaml
on:
  schedule:
    - cron: '0 */6 * * *'
  workflow_dispatch:  # Manual trigger
```

## Commit & Repository

### Change the commit message format

Edit the git step in `monitor-pipeline.yml` (Azure DevOps) or `.github/workflows/scan.yml` (GitHub Actions):

**Current format** (ISO 8601 timestamp):
```bash
git commit -m "scan: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

**Example commit messages**:
```
scan: 2026-04-27T18:42:15Z
chore: pim scan at 2026-04-27
feat: pim changes on 2026-04-27
SCAN: Daily security check
```

Any format works as long as it's unique enough to identify scans in `git log`.

### Customize git commit author

Edit `src/git.ps1`:

```powershell
git config user.name "PIM Monitor"
git config user.email "pim-monitor@noreply.github.com"
```

Change to:
```powershell
git config user.name "Azure Security Team"
git config user.email "security@contoso.com"
```

The name and email appear in git history and commit metadata.

### Store inventory in a subfolder

Edit `src/Scan-PimState.ps1` (line ~51):

```powershell
$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "inventory"
```

Change to:
```powershell
$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "security/pim-inventory"
```

Then update the git add step to match:

**Azure DevOps** `monitor-pipeline.yml`:
```bash
git add security/pim-inventory/ expected-changes.json 2>/dev/null || true
```

**GitHub Actions** `.github/workflows/scan.yml`:
```bash
git add security/pim-inventory/ expected-changes.json
```

## Reporting & Artifacts

### Enable HTML scan report artifact

Set `REPORT_ARTIFACT=true` in your pipeline variables.

**Azure DevOps**:
1. **Pipelines** → **PIM Monitor** → **Edit** → **Variables**
2. Add: `REPORT_ARTIFACT` = `true`

**GitHub Actions**:
1. **Settings** → **Secrets and variables** → **Actions** → **Variables**
2. Add: `REPORT_ARTIFACT` = `true`

The scan generates `scan-report.html` and publishes it as an artifact.

**Report includes**:
- Severity summary with counts
- All detected changes organized by severity
- Before/after diffs
- Tenant info and timestamp
- Commit SHA (if available)

See [Reporting & Artifacts](./reporting.md) for details.

### Expiring assignments window

Set `EXPIRING_WINDOW_DAYS` in your pipeline variables to control early warning for expiring PIM assignments.

**Default**: `14` days

**Examples**:
- `7` = 1 week advance notice
- `14` = 2 weeks (default)
- `30` = 1 month

Assignments expiring within this window are flagged as `Medium` severity changes.

See [Expiring Assignments](./expiring-assignments.md) for details.

## Environment-Specific Configuration

### Staging vs. Production

If you have multiple Azure AD tenants or want different schedules per environment, create separate pipeline files:

**Azure DevOps**:
```yaml
# monitor-pipeline-prod.yml
schedules:
  - cron: "0 */6 * * *"
    
# monitor-pipeline-staging.yml
schedules:
  - cron: "0 0 * * 0"  # Weekly
```

Then configure two pipelines in Azure DevOps UI pointing to different files.

**GitHub Actions**:
```yaml
# .github/workflows/scan-prod.yml
# .github/workflows/scan-staging.yml
```

## Platform Comparison

| Setting | Azure DevOps | GitHub Actions |
|---------|---|---|
| **Schedule location** | `monitor-pipeline.yml` | `.github/workflows/scan.yml` |
| **Manual trigger** | Built-in (click Run) | `workflow_dispatch:` in YAML |
| **Module cache** | Via pipeline cache | `actions/cache@v4` |
| **Artifacts** | Build artifacts storage | Artifact storage |
| **Cron syntax** | Same cron format | Same cron format |

## Troubleshooting

### Pipeline not running on schedule

**Check**:
- Is the `main` branch the default branch? Scheduled runs only on default branch
- Are workflows enabled? (GitHub Actions)
- Check pipeline run history for errors
- Verify cron syntax (test at https://crontab.guru/)

### Inventory not committing

**Check**:
- Are there any changes to commit? No-change scans skip commit
- Verify git config is correct (user.name, user.email set in `src/git.ps1`)
- Check pipeline permissions: must have write access to repository

### Artifact not generating

**Check**:
- Is `REPORT_ARTIFACT=true` set in variables?
- Were changes detected? Report only generates on changes
- Check pipeline logs for permission errors

## Related Pages

- [Environment Variables](./environment-variables.md): REPORT_ARTIFACT, EXPIRING_WINDOW_DAYS
- [GitHub Actions Setup](../getting-started/installation-github.md): Full GitHub Actions configuration
- [Expiring Assignments](./expiring-assignments.md): EXPIRING_WINDOW_DAYS details
- [Reporting](./reporting.md): HTML report artifact details
- [Notifications](./notifications.md): Notification triggers and configuration
