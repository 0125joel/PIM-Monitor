---
sidebar_position: 10
description: Scan error notifications for PIM Monitor. Configure partial-failure handling where component errors trigger separate notifications without failing the pipeline.
---

# Scan Error Notifications

When a component fails, the rest of the scan continues. You get a separate notification naming exactly what broke, and the pipeline exits clean.

## What Are Scan Errors?

When PIM Monitor scans your tenant, it fetches data from multiple sources:
- Directory Roles (definitions, policies, assignments)
- PIM Groups (definitions, policies, assignments)
- Authentication Contexts
- Administrative Units
- Activation Events (audit log)
- Expiring Assignments (detection)

Normally, if any resource fails, the rest of the pipeline continues. Scan error notifications let failed components trigger a separate notification, so the pipeline can succeed while still reporting exactly what went wrong.

### Example Scenario

One Directory Role API call fails after all retries are exhausted:
- **What happens**:
  - That specific role is skipped; all other roles still process normally
  - A separate "scan error" notification is sent naming the exact role that failed
  - Pipeline succeeds (exit code 0)
  - Inventory is committed for all successfully fetched roles

## Granularity

Scan errors are reported at the finest possible level:

| Workload | Granularity | Example component name |
|---|---|---|
| **Directory Roles** | Per role | `Directory Role: Global Administrator` |
| **PIM Groups** | Per group | `PIM Group: Tier-0 Admins` |
| **Authentication Contexts** | Whole workload | `Authentication Contexts` |
| **Administrative Units** | Whole workload | `Administrative Units` |
| **Activation Events** | Whole workload | `Activation Events` |
| **Expiring Assignments** | Whole workload | `Expiring Assignments` |

Directory Roles and PIM Groups use per-resource granularity because they are the highest-value workloads. A single failing role or group should not prevent the scan from processing and reporting on all others.

## When Scan Errors Occur

Scan errors are triggered by non-fatal failures. All Graph API calls use exponential backoff with up to 6 attempts before giving up (see Retry Behavior below), so transient throttling and network errors resolve automatically without triggering a scan error.

| Component | Reason it might produce an error |
|---|---|
| **Authentication Contexts** | Graph API timeout, permission denied |
| **Administrative Units** | Graph API error, malformed response |
| **Activation Events** | AuditLog.Read.All permission missing (graceful), API error (error notification) |
| **Directory Roles** | Persistent API failure for a specific role after 6 retry attempts |
| **PIM Groups** | Group definition or assignment fetch fails after 6 retry attempts |
| **Expiring Assignments** | Malformed assignment date, missing required fields |

**NOT scan errors** (still cause pipeline failure):
- Token acquisition failure, impossible to proceed without auth
- Unrecoverable network issues

## How Scan Error Notifications Work

### Flow

1. **Each resource runs in its own try/catch block**

   For per-resource workloads (Directory Roles, PIM Groups), each individual role or group has its own error boundary:
   ```powershell
   # Inside the parallel block (Directory Roles)
   try {
       # Fetch policy, assignments for this specific role
       @{ definition = $role; ...; error = $null }
   }
   catch {
       Write-Warning "Failed to fetch data for role $roleDisplayName : $_"
       @{ definition = $role; slug = $slugName; error = $_.ToString() }
   }
   
   # Post-processing loop
   if ($result.error) {
       $scanErrors.Add(@{ Component = "Directory Role: $($result.definition.displayName)"; Error = $result.error })
       continue  # skip this role; all others continue normally
   }
   ```

   For other workloads (Auth Contexts, Admin Units, Activation Events), the whole section runs in a catch:
   ```powershell
   catch {
       Write-Warning "Authentication contexts scan failed: $_"
       $scanErrors.Add(@{ Component = 'Authentication Contexts'; Error = $_.ToString() })
   }
   ```

2. **Error recorded in `$scanErrors` accumulator**
   - Stores `Component` name and full error message
   - For Directory Roles/PIM Groups: other resources in the same workload continue
   - For other workloads: entire workload is skipped on failure

3. **After all components complete**
   - If `$scanErrors.Count -gt 0`, scan error notification is sent
   - Notification is separate from regular change notifications
   - Pipeline exits with code 0 (success)

4. **Partial inventory is committed**
   - Successfully fetched data from other roles/groups/workloads is committed
   - Failed resources have no inventory update for this run
   - The next scheduled scan will retry failed resources automatically

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
2 component(s) failed. Partial scan data may be incomplete.
2026-04-27T18:42:15Z

▶ Directory Role: Global Administrator
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
- Body: warning icon, count, timestamp
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
      "component": "Directory Role: Global Administrator",
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

Edit `Format-ScanErrorHtml` in `src/notifications-email.ps1`:

```powershell
function Format-ScanErrorHtml {
    param([Parameter(Mandatory)] [array] $ScanErrors)
    
    # Customize HTML here
    # $ScanErrors[i].Component = component name (e.g. "Directory Role: Global Administrator")
    # $ScanErrors[i].Error = error message (full)
    
    return $htmlString
}
```

### Change the Webhook Payload

Edit the appropriate builder in `src/notifications-webhook.ps1`:

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

In `Send-ScanErrorNotification` (`src/notifications-error.ps1`), add a new switch case:

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
- Successfully fetched data from other components is still committed
- The failed component's folder may be outdated or partially populated
- Git history shows what was committed, when, and which components succeeded

**Example**: Directory Roles API fails → Admin Units, Auth Contexts, PIM Groups still update inventory normally

### Error Message Truncation

Error messages in notifications are truncated to ~200 characters to keep payloads reasonable:

```
"The operation timed out. No response was received from the remote server..."
↓ (after truncation)
"The operation timed out. No response was received from the remote server (1..."
```

Full error messages are always available in:
- Workflow logs (Azure DevOps / GitHub Actions)
- Pipeline run summary

### Retry Behavior

All Graph API calls use exponential backoff with jitter (up to 6 attempts, capped at 32 seconds per wait, respecting `Retry-After` headers). A scan error is only triggered when all retries are exhausted.

Scan error notifications do NOT trigger automatic retries beyond that. If a resource still fails:
- The notification alerts you to the issue
- The next scheduled scan will retry the failed resource automatically
- Manual re-run is possible via the pipeline UI

### Scan Success Despite Errors

The pipeline succeeds (exit code 0) even when scan errors occur. This is intentional:
- Partial data is valuable: you want to see what succeeded
- Manual intervention is not triggered (no on-call page)
- You can review the scan error notification at your convenience

## Common Scan Errors and Solutions

### Error: "The operation timed out"

**Cause**: Graph API endpoint too slow, large response

**Solutions**:
1. Retry automatically: the next scheduled scan may succeed
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

**Cause**: Graph API throttling that persisted beyond all retry attempts (typically requires sustained rate limiting)

**Solutions**:
1. Transient throttling is handled automatically via retry backoff: check if it resolved on the next run
2. Reduce scanning frequency if you have many roles/groups
3. Contact Microsoft if throttling is excessive (>6 consecutive 429 responses)

## Monitoring Scan Errors

### View in Workflow Logs

**Azure DevOps**:
1. **Pipelines** → **PIM Monitor** → **[latest run]**
2. Scroll to logs, search for "Scan errors in:"

**GitHub Actions**:
1. **Actions** → **PIM Change Scan** → **[latest run]**
2. Expand the `scan` job, search for "Scan errors in:"

### View in Notifications

Scan error notifications go to the same channels as regular change notifications:
- Email (`NOTIFICATION_EMAIL`)
- Webhook (`NOTIFICATION_WEBHOOK_URL`)

**Note**: Scan error notifications are sent **independently** of regular change notifications, even if the scan also detected changes.

### Alert on Specific Errors

Add custom logic to your notifications to escalate specific errors:

```powershell
# Example: escalate a specific role failure to on-call
if ($scanErrors | Where-Object { $_.Component -eq "Directory Role: Global Administrator" }) {
    Send-OnCallAlert "Global Administrator role scan failed"
}

# Example: escalate any Directory Role failure
if ($scanErrors | Where-Object { $_.Component -like "Directory Role:*" }) {
    Send-OnCallAlert "One or more Directory Role scans failed"
}
```

## Related Pages

- [Environment Variables](./environment-variables.md): NOTIFICATION_* variables
- [Email Notifications](./email-notifications.md): email configuration
- [Webhook Channels](./webhook-channels.md): Teams, Slack, Discord setup
- [Pipeline Configuration](./pipeline.md): retry configuration
