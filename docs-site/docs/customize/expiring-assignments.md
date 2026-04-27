---
sidebar_position: 6
---

# Expiring Assignments Detection

Configure early warning for PIM assignments approaching expiration.

## What It Does

PIM Monitor periodically scans for assignments expiring within a configurable window. When found, they're flagged as `Informational` severity changes in the scan report.

**Example**:
- Window: 14 days
- Current date: 2026-04-27
- Assignment expires: 2026-05-10 (13 days from now)
- Result: Flagged as expiring

## Configuration

### Set the Expiring Window

Set `EXPIRING_WINDOW_DAYS` in your pipeline variables:

**Azure DevOps**:
1. **Pipelines** → **PIM Monitor** → **Edit** → **Variables**
2. Add: `EXPIRING_WINDOW_DAYS` = `14`

**GitHub Actions**:
1. **Settings** → **Secrets and variables** → **Actions** → **Variables**
2. Add: `EXPIRING_WINDOW_DAYS` = `14`

### Window Values

| Window | Use case | Warning level |
|--------|----------|---------------|
| `7` days | Weekly reviews | Aggressive (short notice) |
| `14` days | Default; bi-weekly planning | Balanced |
| `30` days | Monthly batch renewals | Conservative (long notice) |
| `90` days | Quarterly planning | Very early notice |

**Default**: `14` days (2 weeks)

## How Expiring Assignments Work

### Detection Logic

For each PIM assignment (Directory Roles and PIM Groups):

1. **Check if assignment has expiration date** — Permanent assignments are skipped
2. **Compare expiration against today + window** — If expiring within window, flag it
3. **Classify as Informational severity** — Expiring assignments are low-priority alerts
4. **Include in scan report** — Listed separately from other changes

### Types of Assignments Checked

- **Directory Roles**:
  - Eligible role assignments (expiration date = activation timeout + current policy duration)
  - Active role assignments (expiration date = next review date)
  
- **PIM Groups**:
  - Eligible member/owner assignments
  - Active member/owner assignments

### What Gets Reported

Expiring assignments appear in the scan report as `Informational` severity changes:

```
Informational (3)
▼ Directory Roles > Global Administrator > assignments
  - Principal: [User] expires in 13 days
  - Principal: [Group] expires in 8 days
▼ PIM Groups > Tier-0-Admins > assignments
  - Member: [User] expires in 5 days
```

## Notification Behavior

### Included in Notifications?

Expiring assignments are included in notifications **only if** `NOTIFICATION_MIN_SEVERITY` includes `Informational`:

| Setting | Include expiring? | Example output |
|---------|---|---|
| `High` | ❌ No | Only critical changes |
| `Medium` | ❌ No | Security + config (default) |
| `Low` | ❌ No | All changes except metadata |
| `Informational` | ✅ Yes | All changes including expiring |

**To receive expiring assignment alerts**, set:
```
NOTIFICATION_MIN_SEVERITY = Informational
```

### Separate Reports

Even if notifications are disabled, expiring assignments appear in:
- `inventory/` files (committed to git)
- HTML scan report (if `REPORT_ARTIFACT=true`)
- Pipeline logs

## Best Practices

### Window Size Selection

**Too small (7 days)**: Too many false alarms, insufficient lead time for renewals
**Optimal (14 days)**: Enough notice to plan renewals, not too noisy
**Too large (90 days)**: Most assignments appear expiring; loses signal-to-noise

**Recommendation**: Start with `14`, adjust based on your renewal SLA.

### Combining with Expected Changes

If you intentionally expire assignments and don't want notifications:

1. Create `expected-changes.json` entry:
   ```json
   {
     "workload": "directory-roles",
     "entity": "global-administrator",
     "fileType": "assignments",
     "reason": "Planned rotation per security review",
     "expiresUtc": "2026-05-10T17:00:00Z"
   }
   ```

2. Set window to `14` days (normal)
3. Matching expiring assignments won't trigger notifications
4. Entry auto-deletes after expiration

### Regular Review Cycle

Set up a schedule to review expiring assignments:

**Bi-weekly (14-day window)**:
- Every Monday: Review scan report for expiring assignments
- Tuesday: Plan renewals if needed
- Wednesday: Execute renewals in PIM Manager
- Thursday scan: Updates reflect new expiration dates

**Monthly (30-day window)**:
- First of month: Review scan report
- Plan bulk renewals
- Execute renewal batch
- Next scan: Confirms updates

## Customizing Expiration Detection

### Change Assignment Severity

Edit `src/diff.ps1` to change expiring assignments from `Informational` to a different severity:

**Current** (line ~1054):
```powershell
$severity = "Informational"  # Expiring assignments
```

**Change to**:
```powershell
$severity = "Low"  # Or "Medium" / "High"
```

### Change Detection Window in Code

The window is controlled by the `EXPIRING_WINDOW_DAYS` variable at runtime. To hardcode a default:

Edit `src/Scan-PimState.ps1` (line ~560):
```powershell
$windowDays = if ([int]::TryParse($env:EXPIRING_WINDOW_DAYS, [ref]$parsed)) { 
    $parsed 
} else { 
    14   # Default if variable unset
}
```

### Add Additional Criteria

To skip assignments from certain roles or groups:

Edit `Find-ExpiringAssignments` in `src/diff.ps1` (lines ~1033–1094):

```powershell
function Find-ExpiringAssignments {
    param($Assignments, $WindowDays)
    
    # Add filter:
    if ($slug -match "^(break-glass|emergency)") {
        continue  # Skip break-glass accounts
    }
    
    # ... rest of logic
}
```

## Troubleshooting

### No expiring assignments detected

**Check**:
1. Are there any assignments with expiration dates? Permanent assignments ignored
2. Are expiration dates actually within the window? Check inventory files
3. Is window size appropriate? If set to 7 days, only finds assignments expiring within week

### Too many expiring assignments reported

**Check**:
1. Is window too large? (90 days captures ~3 months of expirations)
2. Do policies have short max durations? (e.g., 30-day assignments = 30 updates per month)
3. Reduce window: `EXPIRING_WINDOW_DAYS = 7`

### Expiring assignments not in notifications

**Check**:
1. Is `NOTIFICATION_MIN_SEVERITY` set to `Informational`? (required for expiring to be notified)
2. Check notifications are enabled (`NOTIFICATION_EMAIL` or `NOTIFICATION_WEBHOOK_URL` set)
3. Review `inventory/` files to confirm expiring assignments exist

## Related Pages

- [Environment Variables](./environment-variables.md) — EXPIRING_WINDOW_DAYS details
- [Pipeline Configuration](./pipeline.md) — Where EXPIRING_WINDOW_DAYS is set
- [Notifications](./notifications.md) — NOTIFICATION_MIN_SEVERITY and severity threshold
- [Severity Rules](./severity-rules.md) — How changes are classified
- [Expected Changes](./expected-changes.md) — Suppressing known-good expirations
