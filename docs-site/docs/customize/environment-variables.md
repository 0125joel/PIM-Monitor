---
sidebar_position: 2
description: PIM Monitor environment variables reference. Complete list of configuration options for notifications, scheduling, reporting, severity, and Microsoft Graph settings.
---

# Environment Variables Reference

Complete reference of all environment variables that PIM Monitor recognizes.

## Quick Reference Table

| Variable | Type | Default | Valid values | Purpose |
|----------|------|---------|--------------|---------|
| `NOTIFICATION_EMAIL` | Secret | Unset | Email address | Email recipient for notifications |
| `NOTIFICATION_MAIL_FROM` | Secret | Unset | Service principal UPN | Sender mailbox |
| `NOTIFICATION_WEBHOOK_URL` | Secret | Unset | HTTPS URL | Teams/Slack/Discord/Custom webhook |
| `NOTIFICATION_MIN_SEVERITY` | Variable | `Medium` | High, Medium, Low, Informational | Minimum severity to notify |
| `EXPIRING_WINDOW_DAYS` | Variable | `14` | Integer (7, 14, 30, etc.) | Days ahead to flag expiring assignments |
| `REPORT_ARTIFACT` | Variable | Unset | `true` | Generate HTML scan report artifact |
| `MSGRAPH_VERSION` | Variable | `2.35.1` | Semantic version | Microsoft.Graph PowerShell module version |

## Notification Variables

### **NOTIFICATION_EMAIL**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Secrets
- **What it does**: Sets the email recipient for change notifications
- **Example**: `security-team@contoso.com`
- **Requirements**: Must be paired with `NOTIFICATION_MAIL_FROM`; Graph `Mail.Send` permission required
- **See also**: [Email Notifications](./email-notifications.md)

### **NOTIFICATION_MAIL_FROM**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Secrets
- **What it does**: Sets the sender mailbox (typically the service principal)
- **Example**: `pim-monitor@contoso.onmicrosoft.com`
- **Requirements**: Must be paired with `NOTIFICATION_EMAIL`; service principal must have Graph `Mail.Send` permission
- **See also**: [Email Notifications](./email-notifications.md)

### **NOTIFICATION_WEBHOOK_URL**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Secrets
- **What it does**: Sends change notifications to a webhook endpoint
- **Supported platforms**: Teams (Power Automate), Slack, Discord, custom JSON endpoints
- **Auto-detection**: URL pattern determines payload format:
  - `webhook.office.com` → Teams Adaptive Card
  - `hooks.slack.com` → Slack blocks
  - `discord.com/webhooks` → Discord embed
  - Other → Generic JSON
- **See also**: [Webhook Channels](./webhook-channels.md)

### **NOTIFICATION_MIN_SEVERITY**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables (not secret)
- **What it does**: Filters notifications by minimum severity level
- **Valid values**: `High`, `Medium`, `Low`, `Informational`
- **Default**: `Medium`
- **Behavior**:
  - Only changes at or above this level trigger notifications
  - Lower-severity changes are still detected and committed to inventory
  - Does NOT suppress the HTML scan report (if enabled)
- **Examples**:
  - `High` → Only critical security changes → minimal alerts
  - `Medium` (default) → Security + configuration changes → balanced
  - `Low` → Include all detected changes → verbose
  - `Informational` → All changes including metadata → very verbose

## Scan Configuration Variables

### **EXPIRING_WINDOW_DAYS**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Sets the number of days ahead to flag expiring PIM assignments
- **Default**: `14`
- **Example values**: `7` (1 week), `14` (2 weeks), `30` (1 month)
- **Behavior**: Assignments expiring within this window are flagged as `Informational` severity changes
- **Notes**: Does not prevent expiring assignments; only provides early warning
- **See also**: [Expiring Assignments](./expiring-assignments.md)

### **REPORT_ARTIFACT**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Enables HTML scan report generation and publication as pipeline artifact
- **Valid values**: `true` (case-sensitive; anything else is treated as disabled)
- **Default**: Unset (disabled)
- **Behavior**:
  - Only published when changes are detected
  - Stored in `BUILD_ARTIFACTSTAGINGDIRECTORY` (Azure DevOps) or artifacts folder (GitHub Actions)
  - Report includes severity breakdown, detailed change listing, and diffs
  - Cannot be disabled once enabled — no `false` value needed
- **Requirements**: Azure DevOps artifact staging directory must be available
- **See also**: [Reporting & Artifacts](./reporting.md)

## Module Management Variables

### **MSGRAPH_VERSION**
- **Where to set**: `monitor-pipeline.yml` (Azure DevOps) or `.github/workflows/scan.yml` (GitHub Actions)
- **What it does**: Pins the Microsoft.Graph PowerShell module version
- **Default**: `2.35.1`
- **Format**: Semantic versioning (e.g., `2.35.0`, `2.36.1`)
- **Behavior**:
  - Pipeline caches this version; changing it invalidates the cache
  - Automatic re-download on version change
  - Ensures reproducible runs across all agents
- **When to change**: Only when Microsoft Graph API behavior changes require a newer version
- **Notes**: Do NOT set as a pipeline variable; edit the YAML directly
- **See also**: [Pipeline Configuration](./pipeline.md)

## Platform-Specific Variables (Auto-populated)

These are automatically set by Azure DevOps or GitHub Actions. You do NOT set them manually.

### **Azure DevOps**
- `BUILD_REPOSITORY_URI` — Repository URL (used to build diff links in notifications)
- `BUILD_ARTIFACTSTAGINGDIRECTORY` — Where HTML reports are staged

### **GitHub Actions**
- `GITHUB_SERVER_URL` — GitHub base URL (https://github.com or Enterprise URL)
- `GITHUB_REPOSITORY` — Repo in format OWNER/REPO
- `GITHUB_REF_NAME` — Branch name

## Setting Variables by Platform

### **Azure DevOps**

1. Navigate to **Pipelines** → **PIM Monitor** → **Edit**
2. Click **Variables** (top right)
3. Add variables:
   - **Name**: `NOTIFICATION_EMAIL`
   - **Value**: `security-team@contoso.com`
   - **Scope**: Pipeline
   - **Keep value secret** ✓ (for credentials only)

4. Repeat for each variable

### **GitHub Actions**

**For secrets** (EMAIL, WEBHOOK_URL, etc.):
1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository secret**
3. **Name**: `NOTIFICATION_EMAIL`
4. **Value**: `security-team@contoso.com`

**For non-secret variables**:
1. Go to **Settings** → **Secrets and variables** → **Actions**
2. Click **New repository variable** (separate tab)
3. **Name**: `NOTIFICATION_MIN_SEVERITY`
4. **Value**: `Medium`

## Environment Variable Usage Pattern

All variables follow this pattern in the PowerShell script:

```powershell
# Unset/missing variables are null
$email = if ($env:NOTIFICATION_EMAIL -and $env:NOTIFICATION_EMAIL -notmatch '^\$\(') { 
    $env:NOTIFICATION_EMAIL 
} else { 
    $null 
}

# Variables can then be passed to functions
Send-EmailNotification -ToAddress $email -FromAddress $fromAddress
```

**Note**: The regex pattern `-notmatch '^\$\('` filters out Azure DevOps macro references like `$(VAR_NAME)` when a variable is not configured.

## Troubleshooting

### Variable not taking effect
- **Check**: Is the variable set in the correct location? (Pipeline Variables, not script)
- **Check**: For secrets, is the variable marked as secret?
- **Check**: Azure DevOps pipelines cache variables; try running a new pipeline instance

### Notifications not sending
- See [Email Notifications](./email-notifications.md) or [Webhook Channels](./webhook-channels.md) for setup

### Wrong severity level
- Check `NOTIFICATION_MIN_SEVERITY` value (case-sensitive)
- Run a test scan with `REPORT_ARTIFACT=true` to see all detected changes

## Related Pages

- [Email Notifications](./email-notifications.md) — Email setup & configuration
- [Webhook Channels](./webhook-channels.md) — Teams, Slack, Discord, custom webhooks
- [Pipeline Configuration](./pipeline.md) — Schedule, commit format, inventory paths
- [Expiring Assignments](./expiring-assignments.md) — Window configuration & behavior
- [Reporting](./reporting.md) — HTML artifact generation
