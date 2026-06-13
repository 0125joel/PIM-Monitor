---
sidebar_position: 8
description: Send PIM Monitor change summaries via email using Microsoft Graph sendMail. Configure the sender mailbox and Mail.Send permission.
---

# Email Notifications

Configure email notifications for PIM Monitor scan results.

## Quick Setup

1. **Grant permissions to service principal**:
   - Azure AD → **App registrations** → [Your app]
   - **API permissions** → **Add permission**
   - Select **Microsoft Graph** → **Application permissions**
   - Search for **Mail.Send** → select it → **Grant admin consent**

2. **Set environment variables** (in your pipeline):
   - `NOTIFICATION_EMAIL` = recipient email address
   - `NOTIFICATION_MAIL_FROM` = service principal UPN (sender mailbox)

3. **Test**: Run the pipeline. Verify an email arrives in the inbox.

## Email Components

### Subject Line

Formatted to enable triage from the inbox without opening the email. The highest severity present leads, followed by tenant name and a breakdown.

```
[PIM Monitor] Contoso: HIGH severity, 7 changes (3 High, 2 Medium, 1 Low, 1 Classification)
```

When no tenant name is available (older deployments), the prefix falls back to `[PIM Monitor] `.

### Preheader (inbox preview)

A hidden span at the top of the body that most mail clients show next to the subject in the inbox list. Format:

```
3H / 2M / 1L / 1C detected in Contoso at 2026-05-21T11:36:24Z
```

### Header

- Brand: "pim/monitor" (monospace, amber `#d97706`)
- Subtitle: "change report"
- Tenant display name (when provided)

### Executive summary

A single-sentence summary directly under the header, biased toward the highest severity present. Example:

```
3 High-severity change(s) require review in tenant Contoso.
Scan completed 2026-05-21T11:36:24Z, commit linked below.
```

### Severity counts

A compact row showing Total / High / Medium / Low / Info, with non-zero severities color-coded and zeros muted. A secondary Git vs Compliance split is shown when compliance findings are present.

### Change cards

Each detected change renders as an always-expanded card (no `<details>` toggle, since several email clients including Outlook desktop and Gmail web do not implement it). Each card shows:

- Context (e.g., role or group name) and a one-line description, prefixed by a `+`, `-`, or `M` sigil to indicate added, removed, or modified
- Inline diff with property names, old value (red), and new value (green)
- Severity-colored left border matching the design system

Sections are grouped by severity, then split into Git changes (with `was` / `changed to` labels) and Access Model Compliance (policy deviates from `expectedConfig`, labels `actual` / `expected`). Access Model Coverage findings (roles or groups not present in any access-model file) appear last as a flat list.

### Bulletproof "View diff" button

A standards-compliant button with a VML fallback for Outlook desktop. Links to the scan commit in GitHub or Azure DevOps when `CommitSha` is available.

### Dark mode

The body declares `color-scheme: light dark` and includes both a `prefers-color-scheme: dark` media query and an Outlook.com `[data-ogsc]` selector. In dark-mode-capable clients (Apple Mail, iOS Mail, Outlook 2019+, Outlook.com), the email switches to the dark palette: `#0a0a0a` background, `#e5e5e5` text, `#27272a` borders.

### Accessibility

- `<html lang="en">`
- Layout tables marked `role="presentation"`
- Change-type sigils carry `aria-label` (added / removed / modified)
- Severity count cells carry descriptive `aria-label` attributes

### Footer

Scan metadata:
- **Scanned entities**: Count of roles, groups, units checked
- **Scan time**: When the scan ran (ISO 8601 UTC)
- **Commit SHA**: Git commit hash (if pushed)

## Customizing Email Format

All email formatting is done in `src/notifications-email.ps1`.

### Edit the HTML Layout

The main HTML formatter is `Build-EmailChangeHtml`:

```powershell
function Build-EmailChangeHtml {
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $CommitSha
    )
    
    # Build HTML string...
    # Access: $ChangesBySeverity.High, .Medium, .Low, .Informational
    # Each change has: .workload, .entity, .fileType, .description, .severity
    
    return $htmlString
}
```

### Customize Colors

Edit the inline styles to change colors:

```html
<!-- High severity -->
<div style="color: #dc2626;">...</div>  <!-- red, currently #dc2626 -->

<!-- Medium severity -->
<div style="color: #ea580c;">...</div>  <!-- orange, currently #ea580c -->

<!-- Low severity -->
<div style="color: #eab308;">...</div>  <!-- yellow, currently #eab308 -->
```

### Customize Severity Labels

Edit the header text:

```powershell
$s = "Bold, Italic, Red, UPPERCASE, whatever you want"

# Example: change from "pim/monitor" to "Azure Identity Governance"
<div style="...">Azure Identity Governance</div>
```

### Remove or Reorder Sections

Delete or rearrange parts of the HTML:

```powershell
# Example: remove commit diff links
# Delete or comment out the section that builds $commitDiffUrl

# Example: add a custom footer with approval instructions
<div>Please review and approve all High changes within 24 hours</div>
```

### Change the Subject Line

Edit the subject construction in `Send-EmailNotification` (`src/notifications-email.ps1`):

```powershell
$subject = "[PIM Monitor] $($changesBySeverity.High.Count) High, $($changesBySeverity.Medium.Count) Medium"
# Change to:
$subject = "[SECURITY] $($changesBySeverity.Total) PIM changes detected"
```

## Email Configuration

### Service Principal Setup

The service principal sending email needs:
- **Mail.Send** permission on Microsoft Graph
- **Exchange Online** mailbox (if using shared mailbox, grant Send As permission)

**Grant Mail.Send permission:**

1. Azure AD → **App registrations** → [Your app]
2. **API permissions** → **Add permission**
3. **Microsoft Graph** → **Application permissions**
4. Search **Mail.Send** → select → **Grant admin consent**

**Verify in Azure AD:**
- Go to **App registrations** → [Your app] → **API permissions**
- Should see: `Mail.Send` (Application) listed and granted

### Sender Mailbox Considerations

The `NOTIFICATION_MAIL_FROM` must be:
- A real mailbox in your tenant
- Able to send mail (not a resource mailbox)
- Have the service principal as an owner or delegate (if using shared mailbox)

**Options:**
1. **Service principal's own mailbox** (if assigned Office 365 license)
2. **Shared mailbox**: Grant service principal Send As permission

**Grant Send As permission to shared mailbox:**
```powershell
Add-MailboxPermission -Identity "shared-mailbox@contoso.com" `
    -User "pim-monitor-app@contoso.onmicrosoft.com" `
    -AccessRights SendAs
```

### Multiple Recipients

To send to multiple addresses, modify the script:

In `Scan-PimState.ps1`, update the notification block:

```powershell
$notifEmails = @(
    "security-team@contoso.com",
    "compliance@contoso.com",
    "audit@contoso.com"
)

foreach ($email in $notifEmails) {
    Send-EmailNotification `
        -ChangesBySeverity $changesBySeverity `
        -ToAddress $email `
        -FromAddress $notifFrom `
        -AccessToken $token
}
```

Or use a distribution group as `NOTIFICATION_EMAIL`:

```
NOTIFICATION_EMAIL = security-team@contoso.com
# (where security-team is a distribution group)
```

## Troubleshooting Email Issues

### Email not sending

**Check** permission errors in workflow logs:
```
Send-EmailNotification: "Authorization_RequestDenied"
```

**Solutions**:
1. Verify `Mail.Send` permission is granted (see Service Principal Setup)
2. Verify permission has admin consent (not user consent)
3. Verify service principal is owner/delegate of shared mailbox (if applicable)
4. Wait 5-10 minutes after granting permission for sync

### Email sent but not received

**Check**:
1. Is `NOTIFICATION_EMAIL` correct? Check logs for address
2. Check recipient's spam/junk folder (emails from service principals often flagged)
3. Is the mailbox valid? Try sending a test email manually
4. Check Exchange Online rules, which may be blocking service principal emails

### Subject line wrong or missing

**Check**:
1. Are there any detected changes? If 0 changes, email not sent
2. Verify `$changesBySeverity` is populated before email step
3. Search logs for "Email not sent" or "skipping email"

### HTML rendering looks wrong

**Check**:
1. Email client may not support all CSS; test in Gmail, Outlook web
2. Verify all HTML is valid (check for unclosed tags)
3. Inline styles only (external stylesheets not supported in email)

## HTML Report vs. Email

There are two separate email features:

| Feature | Triggered by | Content |
|---|---|---|
| **Change Email** | Detected PIM changes | Summary of changes by severity, diffs, deep links |
| **HTML Report Artifact** | `REPORT_ARTIFACT=true` | Full scan report (all detected changes, metadata, timestamp) |

**Relationship**:
- Email is sent automatically when changes are detected
- Report is published as an artifact (if enabled), stored separately
- Both use same severity classification, but different formatting

**Example workflow**:
1. Scan runs, detects 5 changes
2. Email is sent immediately to `NOTIFICATION_EMAIL`
3. HTML report is generated and stored as artifact (if `REPORT_ARTIFACT=true`)
4. User can download report from artifact storage for archival/compliance

## Security Considerations

### Sensitive Data in Email

Email notifications include:
- Display names of roles, groups, administrative units
- Properties that changed (e.g., "MFA required" → "true")
- Commit links (git diff visible to anyone with repo access)

**Recommendations**:
- Use private email addresses for `NOTIFICATION_EMAIL`
- If using a shared mailbox, limit access to authorized users
- Emails are not encrypted in transit, so use TLS if available
- Review email recipient permissions regularly

### Service Principal Credentials

Never commit service principal secrets. Use:
- **Azure DevOps**: Pipeline → Variables (mark secret)
- **GitHub Actions**: Settings → Secrets (encrypted)

## Related Pages

- [Environment Variables](./environment-variables.md): NOTIFICATION_EMAIL, NOTIFICATION_MAIL_FROM
- [Notifications](./notifications.md): general notification configuration
- [Webhook Channels](./webhook-channels.md): Teams, Slack, Discord alternatives
- [Scan Errors](./scan-errors.md): error notification format
- [Reporting](./reporting.md): HTML report artifact setup
