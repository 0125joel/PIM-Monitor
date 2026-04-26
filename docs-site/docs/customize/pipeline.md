---
sidebar_position: 3
---

# Pipeline behavior

## Change the scan schedule

Edit the cron expression in `monitor-pipeline.yml`:

```yaml
schedules:
  - cron: "0 * * * *"   # every hour instead of the default 4x daily
    displayName: "PIM Change Scan"
    branches:
      include: [main]
    always: true
```

## Change the commit message format

Edit the git step in `monitor-pipeline.yml`:

```bash
git commit -m "chore: pim scan at $(date -u +%Y-%m-%d)"
```

Any format works as long as it is unique enough to identify scans in `git log`.

## Store inventory in a subfolder

Edit `Scan-PimState.ps1` line 51:

```powershell
$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "security/pim-inventory"
```

Update the git step to match:

```bash
git add security/pim-inventory/
```

## Allow manual pipeline triggers

Add a manual trigger alongside the schedule in `monitor-pipeline.yml`:

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

Users can then click **Run** manually in the Azure DevOps UI without waiting for the next scheduled run.
