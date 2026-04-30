---
sidebar_position: 8
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

3. **Test**: Run the pipeline; you should receive an email

## Email Components

### Header

The email header identifies it as a PIM Monitor notification:
- Brand: "pim/monitor" (monospace font, red color)
- Subtitle: "Change Notification" (for regular changes) or "Scan Errors" (for errors)
- Timestamp: ISO 8601 UTC

### Severity Summary

High-level count of detected changes by severity:
- **Red**: High-severity changes (e.g., new role, permanent assignment)
- **Orange**: Medium-severity changes (e.g., policy updates, expiration)
- **Yellow**: Low-severity changes (e.g., removals, minor updates)
- **Gray**: Informational changes (e.g., display name changed)

Example:
```
[PIM Monitor] 2 High, 3 Medium, 1 Low changes

Changes by severity:
High (2)        ████████████████████░░░░░░░░
Medium (3)      ██████████████░░░░░░░░░░░░░░░
Low (1)         █████░░░░░░░░░░░░░░░░░░░░░░░
```

### Change Details

For each change, the email includes:
- **Description**: What changed (e.g., "Directory Roles > Global Administrator > policy")
- **Severity**: Color-coded badge
- **Old vs. new**: Collapsible diff with before/after values
- **Deep link**: Direct link to the entity in Entra portal (for roles/groups)

**Collapsible example:**
```
▶ Directory Roles > Global Administrator > policy

Severity: High

OLD → NEW:
- Enablement_EndUser_Assignment.enablement required: true
+ Enablement_EndUser_Assignment.enablement required: false
```

### Diff Links

If your scan commit is pushed to GitHub or Azure DevOps, the email includes links to view the full diff:
- **View diff in repository**: [link to commit in GitHub/Azure DevOps]
- **Timestamp**: Time scan completed

### Footer

Scan metadata:
- **Scanned entities**: Count of roles, groups, units checked
- **Scan time**: When the scan ran (ISO 8601 UTC)
- **Commit SHA**: Git commit hash (if pushed)

## Customizing Email Format

All email formatting is done in `src/notifications-email.ps1`.

### Edit the HTML Layout

The main HTML formatter is `Format-ChangeSummaryHtml`:

```powershell
function Format-ChangeSummaryHtml {
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
$s = "Bold, Italic, Red, UPPERCASE — whatever you want"

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
- Should see: ✓ `Mail.Send` (Application)

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

**In Scan-PimState.ps1**, update the notification block:

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

**Check permission errors** in workflow logs:
```
Send-EmailNotification: "Authorization_RequestDenied"
```

**Solutions**:
1. Verify `Mail.Send` permission is granted (see Service Principal Setup)
2. Verify permission has **admin consent** (not user consent)
3. Verify service principal is owner/delegate of shared mailbox (if applicable)
4. Wait 5-10 minutes after granting permission for sync

### Email sent but not received

**Check**:
1. Is `NOTIFICATION_EMAIL` correct? Check logs for address
2. Check recipient's spam/junk folder (emails from service principals often flagged)
3. Is the mailbox valid? Try sending a test email manually
4. Check Exchange Online rules — may be blocking service principal emails

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
- Report is published as an artifact (if enabled) — stored separately
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
- Use **private email addresses** for `NOTIFICATION_EMAIL`
- If using **shared mailbox**, limit access to authorized users
- Emails are **not encrypted** in transit — use **TLS** if available
- Review email recipient permissions regularly

### Service Principal Credentials

Never commit service principal secrets. Use:
- **Azure DevOps**: Pipeline → Variables (mark secret)
- **GitHub Actions**: Settings → Secrets (encrypted)

## Related Pages

- [Environment Variables](./environment-variables.md) — NOTIFICATION_EMAIL, NOTIFICATION_MAIL_FROM
- [Notifications](./notifications.md) — General notification configuration
- [Webhook Channels](./webhook-channels.md) — Teams, Slack, Discord alternatives
- [Scan Errors](./scan-errors.md) — Error notification format
- [Reporting](./reporting.md) — HTML report artifact setup
