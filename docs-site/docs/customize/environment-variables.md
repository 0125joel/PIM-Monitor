---
sidebar_position: 2
description: PIM Monitor environment variables reference. Complete list of configuration options for notifications, scheduling, reporting, severity, and Microsoft Graph settings.
---

# Environment Variables Reference

Complete reference of all environment variables that PIM Monitor recognizes.

## Quick Reference Table

| Variable | Type | Default | Valid values | Purpose |
|----------|------|---------|--------------|---------|
| `NOTIFY_UPSTREAM_UPDATE` | Variable | Enabled | `false` to disable | Send notification when a newer release is published upstream |
| `NOTIFICATION_EMAIL` | Secret | Unset | Email address | Email recipient for notifications |
| `NOTIFICATION_MAIL_FROM` | Secret | Unset | Service principal UPN | Sender mailbox |
| `NOTIFICATION_WEBHOOK_URL` | Secret | Unset | HTTPS URL | Teams/Slack/Discord/Custom webhook |
| `NOTIFICATION_TEAMS_MENTION` | Variable | Unset | Comma-separated UPNs | @-mention recipients in Teams card; fires only on High-severity changes |
| `NOTIFICATION_MIN_SEVERITY` | Variable | `Medium` | High, Medium, Low, Informational | Minimum severity to notify |
| `EXPIRING_WINDOW_DAYS` | Variable | `14` | Integer (7, 14, 30, etc.) | Days ahead to flag expiring assignments |
| `REPORT_ARTIFACT` | Variable | Unset | `true` | Generate HTML scan report artifact |
| `EAM_COVERAGE_SCOPE` | Variable | `privileged` | `privileged`, `all` | Scope for unclassified role detection (Enterprise Access Model) |
| `FAIL_ON_COMPONENT_ERROR` | Variable | Unset | `true` | Fail the pipeline run (non-zero exit) when one or more components error, instead of exiting green |


## Pipeline Control Variables

### **NOTIFY_UPSTREAM_UPDATE**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Controls whether a webhook/email notification is sent when the pipeline detects that the upstream GitHub repository has a newer release than the `VERSION` file in your copy. The pipeline log warning is always written regardless of this setting.
- **Default**: Enabled (leave the variable unset)
- **To disable**: Set `NOTIFY_UPSTREAM_UPDATE` = `false` in pipeline variables
- **Applies to**: Both Azure DevOps and GitHub Actions. Both runtimes run from a checked-out copy of the repo and can drift behind upstream releases, so both perform the version check.
- **See also**: [Pipeline Configuration](./pipeline.md)

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
- **Where to set**: Azure DevOps → Pipelines → Variables (**mark as secret**) | GitHub Actions → Secrets
- **Security note**: A webhook URL is a bearer credential. Anyone with it can post to your channel, so always store it as a secret variable, not a plain variable.
- **What it does**: Sends change notifications to a webhook endpoint
- **Supported platforms**: Teams (Power Automate), Slack, Discord, custom JSON endpoints
- **Auto-detection**: URL pattern determines payload format:
  - `webhook.office.com` → Teams Adaptive Card (legacy O365 connector, fully retired by Microsoft May 2026 and no longer delivering, migrate to Power Automate)
  - `*.logic.azure.com`, `*.azure-apim.net` → Teams Adaptive Card (Power Automate workflow, recommended)
  - `hooks.slack.com` → Slack blocks
  - `discord.com/api/webhooks` → Discord embed
  - Other → Generic JSON
- **See also**: [Webhook Channels](./webhook-channels.md)

### **NOTIFICATION_WEBHOOK_TYPE**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables (not secret)
- **What it does**: Overrides the URL-based payload auto-detection
- **Valid values**: `Teams`, `Slack`, `Discord`, `Generic`
- **Default**: unset (auto-detection by URL pattern)
- **When to use**: `*.logic.azure.com` URLs are detected as Teams. A Logic App that consumes the [generic JSON schema](./webhook-channels.md) instead of forwarding to Teams needs `NOTIFICATION_WEBHOOK_TYPE=Generic` to receive the documented payload rather than an Adaptive Card.
- **Behavior**: An unrecognized value is ignored with a pipeline warning; auto-detection then applies. The override also applies to scan error notifications.
- **See also**: [Webhook Channels](./webhook-channels.md)

### **NOTIFICATION_TEAMS_MENTION**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Comma-separated list of UPNs to @-mention in the Teams Adaptive Card when a scan finds **High-severity** changes. The card prefixes the executive summary with `<at>upn</at>` and includes a `msteams.entities` block, so Teams pushes a real mention notification (mobile push, channel highlight).
- **Example**: `oncall@contoso.com,security-lead@contoso.com`
- **Behavior**:
  - Only fires when at least one High-severity change is present in the scan
  - No effect when used without `NOTIFICATION_WEBHOOK_URL`
  - No effect on Slack, Discord, or generic webhooks
- **Requirements**: UPNs must be addressable in the Teams tenant the workflow targets

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
- **Behavior**: Assignments expiring within this window are flagged as `Medium` severity changes
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
  - Cannot be disabled once enabled: no `false` value needed
  - When enabled, the Slack notification adds an **Open HTML Report** button linking to the pipeline run page (Azure DevOps Build Results or GitHub Actions run). Teams gets the same treatment in a future phase.
- **Requirements**: Azure DevOps artifact staging directory must be available
- **See also**: [Reporting & Artifacts](./reporting.md)

### **EAM_COVERAGE_SCOPE**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Controls which **directory roles** are checked for access-model classification during the coverage check
- **Default**: `privileged` (only roles where `isPrivileged=true` in Entra ID)
- **Valid values**:
  - `privileged`: only built-in privileged roles are flagged as unclassified
  - `all`: every role in the inventory is checked, including non-privileged roles
- **Requires**: An `AccessModel/` directory in the repository root; if absent, this variable has no effect
- **Note**: This variable only affects directory roles. PIM Groups are always checked in full, regardless of this setting. See [Access Model: PIM Groups](../access-model/pim-groups.md) for group classification.
- **See also**: [Access Model and Desired-State Compliance](../access-model/overview.mdx)

### **FAIL_ON_COMPONENT_ERROR**
- **Where to set**: Azure DevOps → Pipelines → Variables | GitHub Actions → Variables
- **What it does**: Controls how the pipeline reports a scan in which one or more components failed (for example, the PIM Groups fetch threw while directory roles succeeded)
- **Valid values**: `true` (case-sensitive; anything else is treated as disabled)
- **Default**: Unset (disabled)
- **Behavior**:
  - Disabled (default): the scan is resilient. It commits what succeeded, sends the scan-error notification, and exits with success. The pipeline run shows green even though a component failed.
  - Enabled: after the scan-error notification is sent, the script exits non-zero so the pipeline run shows as failed. Use this when you want a degraded scan to be visible in the pipeline itself, not only through notifications.
  - Token-acquisition failure always fails the run regardless of this setting.
- **See also**: [Notifications](./notifications.md)

## Platform-Specific Variables (Auto-populated)

These are set automatically by Azure DevOps or GitHub Actions. Do not set them manually.

### **Azure DevOps**
- `BUILD_REPOSITORY_URI`: Repository URL (used to build diff links in notifications)
- `BUILD_ARTIFACTSTAGINGDIRECTORY`: Where HTML reports are staged

### **GitHub Actions**
- `GITHUB_SERVER_URL`: GitHub base URL (https://github.com or Enterprise URL)
- `GITHUB_REPOSITORY`: Repo in format OWNER/REPO
- `GITHUB_REF_NAME`: Branch name

## Setting Variables by Platform

### **Azure DevOps**

1. Navigate to **Pipelines** → **PIM Monitor** → **Edit**
2. Click **Variables** (top right)
3. Add variables:
   - **Name**: `NOTIFICATION_EMAIL`
   - **Value**: `security-team@contoso.com`
   - **Scope**: Pipeline
   - **Keep value secret** (for credentials only)

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

- [Email Notifications](./email-notifications.md): Email setup & configuration
- [Webhook Channels](./webhook-channels.md): Teams, Slack, Discord, custom webhooks
- [Pipeline Configuration](./pipeline.md): Schedule, commit format, inventory paths
- [Expiring Assignments](./expiring-assignments.md): Window configuration & behavior
- [Reporting](./reporting.md): HTML artifact generation
