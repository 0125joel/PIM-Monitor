---
sidebar_position: 10
---

# Scan Error Notifications

Handle and notify when scan components fail gracefully.

## What Are Scan Errors?

When PIM Monitor scans your tenant, it fetches data from multiple sources:
- Directory Roles (definitions, policies, assignments)
- PIM Groups (definitions, policies, assignments)
- Authentication Contexts
- Administrative Units
- Activation Events (audit log)
- Expiring Assignments (detection)

Normally, if any component fails, the entire pipeline fails. **Scan error notifications** let failed components trigger a **separate notification** instead, allowing the pipeline to continue and succeed.

### Example Scenario

Your Directory Roles API call times out:
- **Old behavior**: Entire pipeline fails, no inventory update
- **New behavior**: 
  - Directory Roles section skips gracefully
  - Other components (PIM Groups, Admin Units, etc.) still run
  - A separate "scan error" notification is sent listing Directory Roles failure
  - Pipeline succeeds (exit code 0)
  - Partial inventory is committed

## When Scan Errors Occur

Scan errors are triggered by non-fatal failures in these components:

| Component | Reason it might fail |
|---|---|
| **Authentication Contexts** | Graph API timeout, permission denied |
| **Administrative Units** | Graph API error, malformed response |
| **Activation Events** | AuditLog.Read.All permission missing (graceful), API error (error notification) |
| **Directory Roles** | API timeout, throttling (429), 5xx server error |
| **PIM Groups** | Group discovery endpoint down, assignment fetch fails |
| **Expiring Assignments** | Malformed assignment date, missing required fields |

**NOT scan errors** (still cause pipeline failure):
- Token acquisition failure — impossible to proceed without auth
- Unrecoverable network issues

## How Scan Error Notifications Work

### Flow

1. **Component runs in try/catch block**
   ```powershell
   try {
       # Fetch Directory Roles
   }
   catch {
       Write-Warning "Directory Roles scan failed: $_"
       $scanErrors.Add(@{ Component = 'Directory Roles'; Error = $_.ToString() })
       # Continue to next component — no throw
   }
   ```

2. **Error recorded in $scanErrors accumulator**
   - Stores Component name and error message (full exception)
   - Component continues, next component runs

3. **After all components complete**
   - If `$scanErrors.Count -gt 0`, scan error notification is sent
   - Notification is **separate** from regular change notifications
   - Pipeline exits with code **0** (success)

4. **Partial inventory is committed**
   - Whatever data was successfully collected is committed
   - Inventory is still updated for successful components
   - Failed components have no inventory update (or partial update)

### Notification Payloads

#### Email Format

Subject: `[PIM Monitor] Scan completed with errors (2 component(s) failed)`

HTML body:
- Red header (to distinguish from regular change notifications)
- Count of failed components
- List of each failed component with truncated error message (~200 characters)
- Timestamp
- Collapsible details for each error

**Example email:**
```
[pim/monitor] scan errors
━━━━━━━━━━━━━━━━━━━━━━━━━
2 component(s) failed — partial scan data may be incomplete.
2026-04-27T18:42:15Z

▶ Directory Roles
  Error: The operation timed out. No response was received from the remote server.

▶ Activation Events
  Error: AuditLog.Read.All permission not granted. User does not have permissions...
```

#### Teams Adaptive Card

- Title: `[PIM Monitor] Scan completed with errors`
- Subtitle: Count and timestamp
- Red color (attention) to distinguish from regular changes
- Each failed component in a separate container with error message

#### Slack Message

- Header: `[PIM Monitor] Scan completed with errors`
- Body: ⚠️ icon, count, timestamp
- Divider
- Each component as a section with bold name and monospace error
- Links to workflow run (if available)

#### Discord Embed

- Title: `[PIM Monitor] Scan completed with errors`
- Description: Count and warning
- Color: Red (#EF4444)
- Fields: Each component and its error
- Timestamp

#### Generic JSON Webhook

```json
{
  "text": "[PIM Monitor] Scan completed with errors",
  "scanErrors": [
    {
      "component": "Directory Roles",
      "error": "The operation timed out..."
    },
    {
      "component": "Activation Events",
      "error": "AuditLog.Read.All permission not granted..."
    }
  ]
}
```

## Customizing Scan Error Notifications

### Change the Email Format

Edit `Format-ScanErrorHtml` in `src/notifications.ps1`:

```powershell
function Format-ScanErrorHtml {
    param([Parameter(Mandatory)] [array] $ScanErrors)
    
    # Customize HTML here
    # $ScanErrors[i].Component = component name
    # $ScanErrors[i].Error = error message (full)
    
    return $htmlString
}
```

### Change the Webhook Payload

Edit the appropriate builder in `src/notifications.ps1`:

```powershell
function Build-ScanErrorTeamsPayload {
    param([Parameter(Mandatory)] [array] $ScanErrors)
    # Customize Teams Adaptive Card
}

function Build-ScanErrorSlackPayload {
    param([Parameter(Mandatory)] [array] $ScanErrors)
    # Customize Slack blocks
}

function Build-ScanErrorDiscordPayload {
    param([Parameter(Mandatory)] [array] $ScanErrors)
    # Customize Discord embed
}
```

### Add a New Webhook Channel for Scan Errors

In `Send-ScanErrorNotification`, add a new switch case:

```powershell
$payload = switch ($type) {
    'Teams'   { Build-ScanErrorTeamsPayload   -ScanErrors $ScanErrors }
    'Slack'   { Build-ScanErrorSlackPayload   -ScanErrors $ScanErrors }
    'Discord' { Build-ScanErrorDiscordPayload -ScanErrors $ScanErrors }
    'MyCustom' {
        @{
            text = "[PIM Monitor] Scan errors: $($ScanErrors.Count) components failed"
            errors = @($ScanErrors | ForEach-Object { @{
                component = $_.Component
                message = $_.Error
            }})
        }
    }
    default { ... }
}
```

Then add URL detection:

```powershell
if ($WebhookUrl -match "my-custom-domain\.com") {
    $type = "MyCustom"
}
```

## Behavior Details

### Partial Inventory Updates

When a component fails:
- Successfully fetched data from **other components** is still committed
- The failed component's folder may be outdated or partially populated
- Git history shows what was committed, when, and which components succeeded

**Example**: Directory Roles API fails → Admin Units, Auth Contexts, PIM Groups still update inventory normally

### Error Message Truncation

Error messages in notifications are truncated to **~200 characters** to keep payloads reasonable:

```
"The operation timed out. No response was received from the remote server..."
↓ (after truncation)
"The operation timed out. No response was received from the remote server (1..."
```

Full error messages are always available in:
- Workflow logs (Azure DevOps / GitHub Actions)
- Pipeline run summary

### Retry Behavior

Scan error notifications do NOT trigger automatic retries. If a component fails:
- The notification alerts you to the issue
- The next scheduled scan will attempt the failed component again
- Manual re-run is possible via the pipeline UI

### Scan Success Despite Errors

The pipeline **succeeds** (exit code 0) even when scan errors occur. This is intentional:
- Partial data is valuable — you want to see what succeeded
- Manual intervention is not triggered (no on-call page)
- You can review the scan error notification at your convenience

## Common Scan Errors and Solutions

### Error: "The operation timed out"

**Cause**: Graph API endpoint too slow, large response

**Solutions**:
1. Retry automatically — the next scheduled scan may succeed
2. Run scan manually at off-peak hours
3. Check Azure tenant health dashboard for API issues
4. If persistent, contact Microsoft support

### Error: "AuditLog.Read.All permission not granted"

**Cause**: Service principal missing AuditLog.Read.All for Activation Events

**Solutions**:
1. This is expected if you don't have audit access requirements
2. Grant AuditLog.Read.All permission to service principal
3. Or configure audit collection manually via PIM Manager

### Error: "Authentication failed / 401 Unauthorized"

**Cause**: Service principal token expired, credentials invalid, insufficient permissions

**Solutions**:
1. Verify service principal credentials (OIDC token in Azure DevOps/GitHub Actions)
2. Check service principal hasn't been deleted or disabled
3. Verify Graph API permissions are still granted (admin consent)
4. Re-authenticate: run pipeline manually

### Error: "429 Too Many Requests"

**Cause**: Graph API throttling

**Solutions**:
1. Next scan retry will likely succeed
2. Reduce scanning frequency if you have many roles/groups
3. Spread workloads across time
4. Contact Microsoft if throttling is excessive

## Monitoring Scan Errors

### View in Workflow Logs

**Azure DevOps**:
1. **Pipelines** → **PIM Monitor** → **[latest run]**
2. Scroll to logs, search for "Scan errors in:"

**GitHub Actions**:
1. **Actions** → **PIM Change Scan** → **[latest run]**
2. Expand **scan** job, search for "Scan errors in:"

### View in Notifications

Scan error notifications go to the same channels as regular change notifications:
- Email (`NOTIFICATION_EMAIL`)
- Webhook (`NOTIFICATION_WEBHOOK_URL`)

**Note**: Scan error notifications are sent **independently** of regular change notifications, even if the scan also detected changes.

### Alert on Specific Errors

Add custom logic to your notifications to escalate specific errors:

```powershell
# Example: escalate Directory Roles failures to on-call
if ($scanErrors | Where-Object Component -eq "Directory Roles") {
    Send-OnCallAlert "Directory Roles scan failed"
}
```

## Related Pages

- [Environment Variables](./environment-variables.md) — NOTIFICATION_* variables
- [Email Notifications](./email-notifications.md) — Email configuration
- [Webhook Channels](./webhook-channels.md) — Teams, Slack, Discord setup
- [Pipeline Configuration](./pipeline.md) — Retry configuration
