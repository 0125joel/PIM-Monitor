---
sidebar_position: 5
---

# Notifications Overview

PIM Monitor supports multiple notification channels for scan results: email, webhooks (Teams, Slack, Discord, custom), and scan error alerts.

## Quick Start

### Email Notifications

1. Grant `Mail.Send` permission to service principal in Azure AD
2. Set `NOTIFICATION_EMAIL` = recipient address
3. Set `NOTIFICATION_MAIL_FROM` = sender mailbox (service principal)
4. Done! Emails sent on scan completion

See [Email Notifications](./email-notifications.md) for detailed setup and customization.

### Webhook Notifications (Teams / Slack / Discord)

1. Get webhook URL from your platform
2. Set `NOTIFICATION_WEBHOOK_URL` = the URL
3. Done! Messages sent on scan completion

PIM Monitor auto-detects the platform (Teams, Slack, Discord, or generic JSON) by URL pattern.

See [Webhook Channels](./webhook-channels.md) for setup, customization, and platform-specific details.

## Configuration

### Severity Threshold

Set `NOTIFICATION_MIN_SEVERITY` in your pipeline variables to control which severity levels trigger notifications:

```
NOTIFICATION_MIN_SEVERITY = Medium
```

**Valid values**: `High`, `Medium`, `Low`, `Informational`  
**Default**: `Medium`

**Behavior**:
- Only changes at or above this level send notifications
- Lower-severity changes are still detected and committed to inventory
- `Informational` is the lowest level (metadata only)

**Examples**:
- `High` → Only critical changes (new roles, permanent assignments)
- `Medium` → Security + configuration changes (default)
- `Low` → All changes including removals
- `Informational` → All changes including metadata updates

### Multiple Recipients

To send notifications to multiple channels:

**Email**:
- Use a distribution group as `NOTIFICATION_EMAIL`
- Or modify the script to loop over multiple addresses

**Webhooks**:
- Run multiple `Send-WebhookNotification` calls with different URLs
- Or configure multiple integrations in your chat platform (if supported)

## Notification Types

### Change Notifications

Sent when PIM changes are detected above the `NOTIFICATION_MIN_SEVERITY` threshold.

**Content includes**:
- Summary of changes by severity
- Description of each change
- Before/after diffs
- Links to Entra portal and repository
- Timestamp

**Format varies by channel**:
- **Email**: Rich HTML with collapsible details
- **Teams**: Adaptive Card with severity colors
- **Slack**: Block-kit message with sections
- **Discord**: Embed with fields
- **Generic JSON**: Custom structure

### Scan Error Notifications

Sent when one or more scan components fail, **independent from change notifications**.

**Content includes**:
- Which components failed (e.g., Directory Roles, PIM Groups)
- Error message from each component
- Timestamp

**Sent even if**:
- No changes were detected
- Regular change notifications are disabled
- No regular notification channels are configured

See [Scan Error Notifications](./scan-errors.md) for details on error handling and customization.

## Customization Guide

### Change Severity Threshold

See [Severity Rules](./severity-rules.md) for full details on severity classification.

To change only the notification threshold:

```powershell
# In your pipeline variables
NOTIFICATION_MIN_SEVERITY = High
```

### Customize Email Format

See [Email Notifications](./email-notifications.md) for detailed customization options.

Quick summary:
- Edit `Format-ChangeSummaryHtml` in `src/notifications.ps1` to change HTML layout
- Customize colors, sections, header, footer
- Add custom logic (e.g., approval instructions, links)

### Customize Webhook Payload

See [Webhook Channels](./webhook-channels.md) for detailed customization options.

Quick summary:
- Edit `Build-TeamsPayload`, `Build-SlackPayload`, or `Build-DiscordPayload` in `src/notifications.ps1`
- Reorder sections, change colors, add/remove fields
- Add custom channels by creating new payload builder

### Add a New Webhook Channel

1. Create payload builder function (see [Webhook Channels](./webhook-channels.md))
2. Add URL pattern to `Get-WebhookType`
3. Add case to `Send-WebhookNotification` switch statement

## Disabling Notifications

### Disable Email

Leave `NOTIFICATION_EMAIL` and `NOTIFICATION_MAIL_FROM` unset (or set to empty string).

### Disable Webhooks

Leave `NOTIFICATION_WEBHOOK_URL` unset (or set to empty string).

### Disable Scan Error Notifications

Scan error notifications are always sent if scan errors occur. To disable:
- Remove the scan error notification block from `Scan-PimState.ps1` (lines ~730-750)
- Or set empty webhook/email (errors won't have destination)

## Troubleshooting

**Notifications not sending?**
- Check `NOTIFICATION_EMAIL` / `NOTIFICATION_WEBHOOK_URL` are set correctly
- For email, verify `Mail.Send` permission is granted with admin consent
- Check pipeline logs for permission errors or HTTP failures
- See specific channel pages for troubleshooting

**Wrong severity level?**
- Verify `NOTIFICATION_MIN_SEVERITY` value (case-sensitive)
- Check that changes are classified correctly (see [Severity Rules](./severity-rules.md))
- Run with `REPORT_ARTIFACT=true` to see all detected changes

## Related Pages

- [Environment Variables](./environment-variables.md) — All NOTIFICATION_* variables
- [Email Notifications](./email-notifications.md) — Email setup and customization
- [Webhook Channels](./webhook-channels.md) — Teams, Slack, Discord, custom webhooks
- [Scan Error Notifications](./scan-errors.md) — Error handling and alerting
- [Severity Rules](./severity-rules.md) — How changes are classified
- [Expected Changes](./expected-changes.md) — Suppress known-good changes
