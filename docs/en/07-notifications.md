# 07 — Notifications

## Table of Contents

1. [Overview](#1-overview)
2. [Severity Filtering](#2-severity-filtering)
3. [Email — Graph sendMail](#3-email--graph-sendmail)
4. [Webhooks](#4-webhooks)
5. [Teams Payload (Adaptive Card)](#5-teams-payload-adaptive-card)
6. [Slack Payload (Block Kit)](#6-slack-payload-block-kit)
7. [Discord Payload (Embed)](#7-discord-payload-embed)
8. [Generic Webhook Payload](#8-generic-webhook-payload)
9. [HTML Scan Report](#9-html-scan-report)
10. [Commit Diff URL](#10-commit-diff-url)
11. [Adding a New Notification Channel](#11-adding-a-new-notification-channel)

---

## 1. Overview

PIM Monitor supports two notification channels: email (via Microsoft Graph `sendMail`) and webhooks. Both are optional and independently configurable via pipeline variables. Neither channel requires adding secrets to the pipeline — all credentials are handled by the WIF service connection.

Notifications are dispatched in `Scan-PimState.ps1` after the git commit, so the commit SHA is available to include as a "View Diff" link.

```
$changesBySeverity.Total > 0
        │
        ├── NOTIFICATION_EMAIL + NOTIFICATION_MAIL_FROM set?
        │       └── Send-EmailNotification
        │
        └── NOTIFICATION_WEBHOOK_URL set?
                └── Send-WebhookNotification
                        │
                        ├── URL matches webhook.office.com → Teams
                        ├── URL matches hooks.slack.com → Slack
                        ├── URL matches discord.com/api/webhooks → Discord
                        └── otherwise → Generic
```

> [!NOTE]
> ADO pipeline variables that are not set in the UI are passed to the script as literal `$(VARIABLE_NAME)` strings. `Scan-PimState.ps1` detects this pattern via `-notmatch '^\$\('` and treats unresolved macros as not configured.

---

## 2. Severity Filtering

Both channels respect `NOTIFICATION_MIN_SEVERITY` (default `Medium`). Changes below the threshold are omitted from the notification payload.

The severity rank is:

```powershell
$script:SeverityRank = @{ High = 3; Medium = 2; Low = 1; Informational = 0 }
```

`Select-ChangesForNotification` filters by `$script:SeverityRank[$change.severity] -ge $script:SeverityRank[$MinSeverity]`.

Setting `NOTIFICATION_MIN_SEVERITY=Low` includes all changes. Setting `High` suppresses everything except High-severity changes.

---

## 3. Email — Graph sendMail

### Configuration

| Variable | Required | Description |
|---|---|---|
| `NOTIFICATION_EMAIL` | Yes | Recipient email address |
| `NOTIFICATION_MAIL_FROM` | Yes | Sender mailbox (must exist in the tenant) |

### Required permissions

`Mail.Send` application permission on the App Registration. To limit the permission to the sender mailbox only, configure an [application access policy](https://learn.microsoft.com/en-us/graph/auth-limit-mailbox-access).

### API call

```
POST https://graph.microsoft.com/v1.0/users/{mailFrom}/sendMail
```

Payload:

```json
{
  "message": {
    "subject": "[PIM Monitor] 2 changes: 1 High, 1 Medium",
    "body": { "contentType": "HTML", "content": "..." },
    "toRecipients": [{ "emailAddress": { "address": "admin@contoso.com" } }]
  },
  "saveToSentItems": false
}
```

The subject line format:
- Single severity: `[PIM Monitor] 1 High change`
- Multiple severities: `[PIM Monitor] 3 changes: 1 High, 2 Medium`

### HTML email structure

`Format-ChangeSummaryHtml` generates a responsive HTML email. Design tokens:

| Element | High | Medium | Low | Informational |
|---|---|---|---|---|
| Border color | `#ef4444` (red) | `#d97706` (amber) | `#22c55e` (green) | `#737373` (gray) |
| Background | `#fef2f2` | `#fffbeb` | `#f0fdf4` | `#f9fafb` |
| Label color | `#b91c1c` | `#92400e` | `#166534` | `#374151` |

Each change is rendered as a collapsible `<details>/<summary>` card:
- Header: entity name (bold) + short description (muted, below)
- Expanded: field-level diff rendered in monospace (red for old values, green for new values)

The email header shows a stat row: Total / High / Medium / Low / Informational, with non-zero counts colored by severity.

---

## 4. Webhooks

### Configuration

| Variable | Required | Description |
|---|---|---|
| `NOTIFICATION_WEBHOOK_URL` | Yes | Full webhook URL |

Webhook type is auto-detected from the URL pattern:

| URL pattern | Type |
|---|---|
| `webhook.office.com` | Teams |
| `hooks.slack.com` | Slack |
| `discord.com/api/webhooks` | Discord |
| anything else | Generic |

---

## 5. Teams Payload (Adaptive Card)

Teams webhooks require a **Power Automate workflow** as the target ("When a Teams webhook request is received" trigger). The old O365 Incoming Webhook connector is deprecated.

The payload uses the Adaptive Card format (`type: "AdaptiveCard"`, schema `1.5`):

```json
{
  "type": "message",
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": {
      "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
      "type": "AdaptiveCard",
      "version": "1.5",
      "body": [
        { "type": "TextBlock", "size": "Large", "weight": "Bolder", "text": "PIM Monitor — change detected" },
        { "type": "FactSet", "facts": [...] },
        { "type": "Container", "style": "attention", "items": [...] }
      ],
      "actions": [{ "type": "Action.OpenUrl", "title": "View Diff", "url": "..." }]
    }
  }]
}
```

Container styles per severity: `attention` (High), `warning` (Medium), `good` (Low), `default` (Informational).

Up to 15 change entries are rendered per severity section. If there are more, a "... and N more" line is appended.

Where available, change entries include `selectAction` with a direct link to the Entra portal entry for the affected role or group.

---

## 6. Slack Payload (Block Kit)

```json
{
  "blocks": [
    { "type": "header", "text": { "type": "plain_text", "text": "PIM Monitor — change detected" } },
    { "type": "section", "fields": [
      { "type": "mrkdwn", "text": "*High:* 2" },
      { "type": "mrkdwn", "text": "*Medium:* 1" }
    ]},
    { "type": "section", "text": { "type": "mrkdwn", "text": "*High (2)*\n• ...\n• ..." } }
  ]
}
```

Up to 20 change entries per severity section. "View Diff" link appended as a mrkdwn section if a commit SHA is available.

---

## 7. Discord Payload (Embed)

```json
{
  "embeds": [{
    "title": "PIM Monitor — change detected",
    "description": "Total: 3 changes",
    "color": 15548997,
    "timestamp": "2026-04-25T10:00:00Z",
    "url": "https://dev.azure.com/.../commit/...",
    "fields": [
      { "name": "High (1)", "value": "• ...", "inline": false }
    ]
  }]
}
```

Embed color by highest severity present: red (`15548997`) for High, orange (`15844367`) for Medium, green (`5763719`) for Low or none.

Discord field values are capped at 1024 characters. Up to 10 changes per field; overflow truncated with `...`.

---

## 8. Generic Webhook Payload

For URLs not matching Teams / Slack / Discord, the payload is a flat JSON object:

```json
{
  "text": "PIM Monitor — 3 change(s) detected",
  "summary": "PIM Monitor — change report\nGenerated: ...\n\nTotal: 3 | High: 1 | ...",
  "changesBySeverity": {
    "high": 1,
    "medium": 2,
    "low": 0,
    "informational": 0,
    "total": 3
  }
}
```

`summary` is the plain-text output of `Format-ChangeSummaryText`, suitable for logging or display.

---

## 9. HTML Scan Report

When `REPORT_ARTIFACT=true`, `Export-ScanReport` writes the HTML report to `$BUILD_ARTIFACTSTAGINGDIRECTORY/scan-report.html`. The `PublishBuildArtifacts@1` pipeline task then makes it available as a pipeline artifact named `scan-report`.

The HTML content is identical to the email body, using the same `Format-ChangeSummaryHtml` function. The `MinSeverity` default for the report is `Low` (show everything), while the email default is `Medium`.

---

## 10. Commit Diff URL

`Get-CommitDiffUrl` constructs a link to view the inventory diff in the hosting platform:

| Platform | Detection | URL format |
|---|---|---|
| Azure DevOps | `$env:BUILD_REPOSITORY_URI` is set | `{repoUri}/commit/{sha}?refName=refs%2Fheads%2Fmain` |
| GitHub | `$env:GITHUB_SERVER_URL` and `$env:GITHUB_REPOSITORY` are set | `{serverUrl}/{repo}/commit/{sha}` |
| Neither | Neither env var is set | `$null` (link omitted from notification) |

The ADO URL strips any `user@` prefix injected by ADO into `BUILD_REPOSITORY_URI`.

---

## 11. Adding a New Notification Channel

To add a new channel (e.g., Google Chat):

1. Add a URL detection case in `Get-WebhookType`:
   ```powershell
   if ($Url -match 'chat\.googleapis\.com') { return 'GoogleChat' }
   ```

2. Add a payload builder function `Build-GoogleChatPayload` in `notifications.ps1`.

3. Add a case in the `switch ($type)` block in `Send-WebhookNotification`:
   ```powershell
   'GoogleChat' { Build-GoogleChatPayload ... }
   ```

4. Document the new channel in the Docusaurus user docs (`docs-site/docs/configuration/notifications.md`).

No changes to the orchestrator are needed. The webhook URL auto-detection handles the dispatch.
