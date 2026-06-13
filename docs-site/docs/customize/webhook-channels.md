---
sidebar_position: 9
description: Send PIM Monitor notifications to Teams, Slack, Discord, or a custom endpoint. Platform-specific payload formats and field reference.
---

# Webhook Channels & Customization

Send PIM Monitor notifications to Teams, Slack, Discord, or custom webhooks.

## Quick Setup

1. **Get webhook URL** from your platform (Teams, Slack, Discord)
2. **Set the variable**: `NOTIFICATION_WEBHOOK_URL = https://...`
3. **Run the pipeline**: scan results appear in your chat

PIM Monitor automatically detects the webhook type by URL pattern. To override the detection, set `NOTIFICATION_WEBHOOK_TYPE` to `Teams`, `Slack`, `Discord`, or `Generic`. The main case for this: a Logic App URL (`*.logic.azure.com`) is detected as Teams, but a Logic App built to consume the [generic JSON payload](#generic-json-custom-webhooks) needs `NOTIFICATION_WEBHOOK_TYPE=Generic`.

## Supported Channels

### Microsoft Teams (Power Automate)

**URL patterns detected as Teams**:
- `webhook.office.com`: legacy O365 incoming connector. Microsoft fully retired these in May 2026, so the URLs no longer deliver. Use a Power Automate workflow instead.
- `*.logic.azure.com`: Power Automate workflow (current recommended path)
- `*.azure-apim.net`: Power Automate via API Management gateway

**Setup (recommended, Power Automate workflow)**:
1. In Teams, install the **Workflows** app (Apps → search "Workflows" → Add)
2. Choose template **Post to a channel when a webhook request is received**
3. Pick channel → **Create** → copy the generated workflow URL
4. Set `NOTIFICATION_WEBHOOK_URL` to that URL

**Payload format**: Adaptive Card schema 1.6

**Card structure**:
- Title `PIM Monitor — change detected` + tenant subtitle + one-sentence executive summary
- FactSet with High / Medium / Low / Informational counts
- `CHANGES` parent header → severity-styled containers (`attention` / `warning` / `good` / `default`)
- `ACCESS MODEL` parent header → `Compliance` sub-section + `Coverage` flat list
- Per change: bullet description (with click-through to Entra portal for roles/groups) followed by a `ColumnSet` showing `Property` / `actual` (or `was`) / `expected` (or `changed to`) with monospace cells
- `View Diff` action at the bottom (when commit URL is inferable)

**Optional High-severity mention**:
Set `NOTIFICATION_TEAMS_MENTION` to one or more UPNs (comma-separated). When the scan finds High-severity changes, the card prefixes the executive summary with `<at>upn</at>` and includes a `msteams.entities` block so Teams renders a real @-mention (push-notifies the recipient on mobile). No mention fires for Medium/Low-only scans.

```
NOTIFICATION_TEAMS_MENTION = oncall@contoso.com,security-lead@contoso.com
```

### Slack

**URL pattern**: `hooks.slack.com`

**Setup**:
1. Go to **api.slack.com** → **Apps** → **Create New App**
2. **From scratch** → Name: "PIM Monitor", workspace: select yours
3. **Incoming Webhooks** → Turn on
4. **Add New Webhook to Workspace** → Select channel → **Allow**
5. Copy the webhook URL

**Payload format**: Slack Block Kit (`text` push-preview + `blocks`)

**Message structure**:
- `header` block: `PIM Monitor — change detected`
- `context` block: tenant name + scan timestamp
- `section` block: one-sentence executive summary (lead by highest severity present)
- `section` block: severity counts as fields (`High` / `Medium` / `Low` / `Informational` / `Classification`)
- `divider` + `header` `CHANGES` (only when git changes exist)
- Per severity: severity sub-header + one `section` per change containing description bullet and a triple-backtick codeblock of `key: was → changed to` lines
- `divider` + `header` `ACCESS MODEL` (only when compliance or coverage findings exist)
  - Compliance sub-sections per severity, codeblock labels `actual → expected`
  - Coverage as a single flat list section
- `actions` block: `View Diff` button (commit) + `Open HTML Report` button (when `REPORT_ARTIFACT=true` and the run page URL is inferable)

**Block-budget safeguard**: Slack limits messages to 50 blocks. Truncation per severity (max 15 git / 10 compliance / 10 coverage items) with `_+N more — see <HTML report|commit diff>_` overflow link. A defensive final trim ensures the message never exceeds 50 blocks.

**Mentions**: not supported. Slack requires workspace-specific user/group IDs (`<@U12345>`, `<!subteam^S123>`) that cannot be derived from email/UPN without a Slack API token. If you need oncall paging, prefer Microsoft Teams (which natively supports UPN-based `<at>` mentions, configured via `NOTIFICATION_TEAMS_MENTION`).

### Discord

**URL pattern**: `discord.com/api/webhooks`

**Setup**:
1. In Discord, go to **Server Settings** → **Integrations** → **Webhooks**
2. **Create Webhook**
3. Name + avatar: configure on the webhook itself in Discord (PIM Monitor does not override these)
4. Select channel: where notifications appear
5. **Copy Webhook URL** → set `NOTIFICATION_WEBHOOK_URL`

**Payload format**: multi-embed Discord webhook (one summary embed + one per severity + Access Model embeds, up to 10 total)

**Message structure**:
- **Summary embed**: title `PIM Monitor — change detected`, color = highest severity present, author block shows `Tenant: <name>` when supplied, description holds the one-sentence executive summary, fields show inline counters (Total / High / Medium / Low / Informational / Classification).
- **CHANGES embeds** (one per non-empty severity with git changes): title `CHANGES — <Severity> (N)`, color matches severity (red / amber / green / zinc per design palette). Each change is one field with the role/group name as field name and a triple-backtick codeblock value showing `property: actual -> expected` lines.
- **ACCESS MODEL — Compliance embed** (when present): title `ACCESS MODEL — Compliance (N)`, amber accent color, description explains the `actual -> expected` format, fields list the deviating entities with codeblock diffs.
- **ACCESS MODEL — Coverage embed** (when present): title `ACCESS MODEL — Coverage (N)`, zinc color, description holds a bullet list of unclassified role names (no per-item field consumption) followed by an inline pointer to `AccessModel/*.json`.
- **Reports field** on the last embed (only when at least one URL is inferable): `📄 Reports` field with `[Diff](commit-url) • [HTML report](run-url)` markdown links. `Get-CommitDiffUrl` and `Get-ArtifactReportUrl` from `notifications-shared.ps1` provide the URLs; the field is suppressed entirely when neither is available.

**Discord limits honoured**: max 10 embeds, max 25 fields per embed, max 1024 chars per field value. Defensive truncation per pass with `_+N more_` markers and a final clamp that drops trailing embeds if the 10-embed cap is hit.

**`allowed_mentions`**: the payload always sets `allowed_mentions.parse = []`, which guarantees no `@everyone`, `@here`, or role/user pings ever fire from a change description that happened to contain such a token. There is no `NOTIFICATION_DISCORD_MENTION` env-var: Discord is the community/chat channel; use Teams (`NOTIFICATION_TEAMS_MENTION`) for on-call paging.

### Generic JSON (Custom Webhooks)

**URL pattern**: any URL NOT matching Teams/Slack/Discord. Fallback for Logic Apps, n8n, SIEM ingest endpoints, custom integrations.

**Payload contract**: versioned, schema-backed. Current version: **`1.0.0`**.

**JSON Schema**: [`schemas/notification-payload-v1.json`](https://github.com/intothecloud/pim-monitor/blob/main/schemas/notification-payload-v1.json). Consumers should validate against this schema in their own CI. Future breaking changes get a new file (`notification-payload-v2.json`); additive changes bump the `schemaVersion` minor.

**Example payload**:

```json
{
  "$schema": "https://raw.githubusercontent.com/intothecloud/pim-monitor/main/schemas/notification-payload-v1.json",
  "schemaVersion": "1.0.0",
  "tenant": { "name": "Contoso" },
  "scan": {
    "timestamp":   "2026-05-21T11:36:24Z",
    "commitSha":   "a1b2c3d4e5",
    "minSeverity": "Medium"
  },
  "summary": {
    "text": "3 High-severity change(s) require review in tenant Contoso.",
    "counts": {
      "total": 5, "high": 3, "medium": 1, "low": 1, "informational": 0, "classification": 1
    }
  },
  "changes": [
    {
      "severity":    "High",
      "changeType":  "added",
      "fileType":    "git",
      "description": "Directory Roles > Global Administrator > assignment",
      "context":     "Global Administrator",
      "roleId":      "62e90394-69f5-4237-9190-012177145e10"
    }
  ],
  "coverage": [
    { "context": "Attack Payload Author", "entity": "9c6df0f2-..." }
  ],
  "urls": {
    "diff":   "https://github.com/.../commit/a1b2c3",
    "report": "https://dev.azure.com/.../buildId=12345"
  },
  "_legacy": {
    "text": "PIM Monitor — 5 change(s) detected",
    "summary": "<plain-text multi-line>",
    "changesBySeverity": { "high": 3, "medium": 1, "low": 1, "informational": 0, "total": 5 }
  }
}
```

**Key fields**:
- `schemaVersion`: always present. Lock your consumer to a major version.
- `scan.timestamp` / `scan.commitSha` / `scan.minSeverity`: scan provenance.
- `summary.text`: one-sentence human-readable summary (same wording as email/Teams/Slack).
- `summary.counts.*`: severity counts including `classification` (coverage findings).
- `changes[]`: up to 50 change objects (severity + changeType + fileType + description, plus optional `context` / `roleId` / `groupId`). Overflow signalled by `{ _truncated: true, remaining: N }` placeholder as the final array element.
- `coverage[]`: up to 50 unclassified entities (`context` + optional `entity` GUID). Same truncation placeholder.
- `urls.diff` / `urls.report`: only present when the CI platform is detectable and `REPORT_ARTIFACT=true` (report only).
- `_legacy`: deprecated in v1.0.0, removed in v2.0.0. Mirrors the pre-formalization fields (`text`, `summary`, `changesBySeverity`) so existing consumers keep working while they migrate to the v1 top-level equivalents.

**Validating in a consumer pipeline** (Node example):

```bash
npm i -D ajv ajv-formats
node -e "
  const Ajv = require('ajv').default; const af = require('ajv-formats');
  const schema = require('./notification-payload-v1.json');
  const payload = require('./incoming.json');
  const ajv = new Ajv(); af(ajv);
  const ok = ajv.compile(schema)(payload);
  console.log(ok ? 'valid' : ajv.errors);
"
```

**Validating in PowerShell** (built-in `Test-Json` since PS7):

```powershell
$payload | ConvertTo-Json -Depth 20 |
    Test-Json -SchemaFile ./notification-payload-v1.json
```

## How Auto-Detection Works

The `Get-WebhookType` function (`src/notifications-webhook.ps1`) inspects the URL:

```powershell
function Get-WebhookType {
    param([string] $Url)
    
    if ($Url -match "webhook\.office\.com") {
        return "Teams"
    }
    elseif ($Url -match "hooks\.slack\.com") {
        return "Slack"
    }
    elseif ($Url -match "discord\.com/api/webhooks") {
        return "Discord"
    }
    else {
        return "Generic"
    }
}
```

To detect a custom service, modify this function to add a new URL pattern:

```powershell
elseif ($Url -match "my-custom-api\.com") {
    return "MyCustom"
}
```

## Customizing Payloads

### Teams Adaptive Card

Edit `Build-TeamsPayload` in `src/notifications-webhook.ps1`:

```powershell
function Build-TeamsPayload {
    param($ChangesBySeverity)
    
    $card = @{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.5'
        body      = @(
            @{ type = 'TextBlock'; text = 'My Custom Title'; size = 'Large' }
            # ... add or remove blocks here
        )
    }
    
    return @{
        type = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            content     = $card
        })
    }
}
```

**Adaptive Card reference**: https://adaptivecards.io/

**Common customizations**:
- Add `backgroundColor` to style containers
- Add `action` buttons (Open URL, Submit action)
- Change `factSet` layout (currently lists High/Medium/Low summary)
- Add images with `Image` blocks

### Slack Blocks

Edit `Build-SlackPayload` in `src/notifications-webhook.ps1`:

```powershell
function Build-SlackPayload {
    param($ChangesBySeverity)
    
    $blocks = @(
        @{ type = 'header'; text = @{ type = 'plain_text'; text = 'My Title' } }
        @{ type = 'section'; text = @{ type = 'mrkdwn'; text = 'Custom markdown here' } }
        # ... build blocks
    )
    
    return @{ blocks = $blocks }
}
```

**Slack blocks reference**: https://api.slack.com/block-kit

**Common customizations**:
- Add `divider` blocks between sections
- Add `context` blocks for metadata/timestamps
- Add `button` elements with `action_id` and `value`
- Use `image` blocks for logos/diagrams

### Discord Embeds

Edit `Build-DiscordPayload` in `src/notifications-webhook.ps1`:

```powershell
function Build-DiscordPayload {
    param($ChangesBySeverity)
    
    $embed = @{
        title       = 'My Title'
        description = 'Description here'
        color       = 16711680  # Red in decimal (0xFF0000)
        fields      = @(...)
        thumbnail   = @{ url = 'https://example.com/image.png' }
        footer      = @{ text = 'Scan completed' }
    }
    
    return @{ embeds = @($embed) }
}
```

**Discord embed reference**: https://discord.com/developers/docs/resources/channel#embed-object

**Common customizations**:
- Change `color` (decimal format: 16711680 = red, 65280 = green)
- Add `thumbnail` or `image` URLs
- Add `footer` text
- Set `timestamp` to ISO 8601 UTC

### Generic JSON

Edit the fallback case in `Send-WebhookNotification`:

```powershell
default {
    @{
        text       = "[PIM Monitor] Scan completed"
        changeCount = $ChangesBySeverity.Total
        high       = $ChangesBySeverity.High.Count
        medium     = $ChangesBySeverity.Medium.Count
        low        = $ChangesBySeverity.Low.Count
        # ... add any custom fields
    }
}
```

## Adding a Custom Webhook Channel

### Step 1: Create a Payload Builder

```powershell
function Build-MyCustomPayload {
    param($ChangesBySeverity)
    
    @{
        title    = "PIM Monitor Scan"
        changes  = $ChangesBySeverity.Total
        severity = @{
            high    = $ChangesBySeverity.High.Count
            medium  = $ChangesBySeverity.Medium.Count
            low     = $ChangesBySeverity.Low.Count
        }
        changes_high = @($ChangesBySeverity.High | ForEach-Object { $_.description })
    }
}
```

### Step 2: Add URL Detection

In `Get-WebhookType`, add:

```powershell
elseif ($Url -match "my-service\.com") {
    return "MyService"
}
```

### Step 3: Add Case to Dispatcher

In `Send-WebhookNotification`, add:

```powershell
$payload = switch ($type) {
    'Teams'     { Build-TeamsPayload -ChangesBySeverity $ChangesBySeverity }
    'Slack'     { Build-SlackPayload -ChangesBySeverity $ChangesBySeverity }
    'Discord'   { Build-DiscordPayload -ChangesBySeverity $ChangesBySeverity }
    'MyService' { Build-MyCustomPayload -ChangesBySeverity $ChangesBySeverity }
    default     { Build-MyCustomPayload -ChangesBySeverity $ChangesBySeverity }
}
```

### Step 4: Test

Set `NOTIFICATION_WEBHOOK_URL` to your service's webhook URL and run the pipeline.

## Testing Webhooks Locally

### Using curl

```bash
# Test a Teams webhook (replace with your Power Automate workflow URL)
curl -X POST https://prod-00.westeurope.logic.azure.com/workflows/... \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "message",
    "attachments": [{
      "contentType": "application/vnd.microsoft.card.adaptive",
      "content": {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
          {"type": "TextBlock", "text": "Test Message"}
        ]
      }
    }]
  }'
```

### Using PowerShell

```powershell
$payload = @{
    type = "message"
    attachments = @(@{
        contentType = "application/vnd.microsoft.card.adaptive"
        content = @{
            type = "AdaptiveCard"
            version = "1.5"
            body = @(
                @{ type = 'TextBlock'; text = 'Test from PowerShell' }
            )
        }
    })
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json' -Body $payload
```

### Using Postman

1. Create new POST request
2. URL: Your webhook URL
3. Headers: `Content-Type: application/json`
4. Body (raw): Paste your payload JSON
5. Send

**Example Teams payload for Postman**:
```json
{
  "type": "message",
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": {
      "type": "AdaptiveCard",
      "version": "1.5",
      "body": [
        {
          "type": "TextBlock",
          "size": "Large",
          "weight": "Bolder",
          "text": "Test: PIM Monitor"
        }
      ]
    }
  }]
}
```

## Webhook Payload Size Limits

Different platforms have different size limits:

| Platform | Limit | Strategy |
|----------|-------|----------|
| **Teams** | ~28 KB | Truncate long changes to first 15 per severity |
| **Slack** | ~3 MB | Truncate long changes to first 20 per severity |
| **Discord** | 2000 chars/field | Truncate error messages to ~200 chars |
| **Generic** | Unlimited (depends on endpoint) | No truncation |

Payloads that exceed limits are automatically truncated with "... [more]" indicators.

## Troubleshooting Webhooks

### Webhook not receiving messages

**Check**:
1. Is webhook URL correct? Copy directly from platform (no typos)
2. Is endpoint still valid? Some platforms disable old webhooks
3. Check firewall/proxy not blocking outbound HTTPS
4. Look at workflow logs for HTTP error codes

**Common errors**:
- `404 Not Found` → Invalid webhook URL
- `401 Unauthorized` → Token/signature invalid
- `403 Forbidden` → Webhook disabled or revoked
- `429 Too Many Requests` → Rate limiting; try again later

### Wrong message format

**Check**:
1. Did `Get-WebhookType` correctly detect your platform?
2. Add debug logging: `Write-Host "Webhook type detected: $type"`
3. Is payload builder correct? Try testing locally with curl first

### Payload too large

**Check**:
1. How many changes were detected? Many changes = larger payload
2. Try filtering by `NOTIFICATION_MIN_SEVERITY` to reduce message size
3. Use `REPORT_ARTIFACT=true` for detailed info (instead of including all in webhook)

## Related Pages

- [Environment Variables](./environment-variables.md): NOTIFICATION_WEBHOOK_URL
- [Email Notifications](./email-notifications.md): email setup
- [Notifications](./notifications.md): general notification configuration
- [Scan Errors](./scan-errors.md): scan error webhook format
