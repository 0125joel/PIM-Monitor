---
sidebar_position: 9
---

# Webhook Channels & Customization

Send PIM Monitor notifications to Teams, Slack, Discord, or custom webhooks.

## Quick Setup

1. **Get webhook URL** from your platform (Teams, Slack, Discord)
2. **Set the variable**: `NOTIFICATION_WEBHOOK_URL = https://...`
3. **Run the pipeline** — scan results appear in your chat

PIM Monitor **automatically detects** the webhook type by URL pattern.

## Supported Channels

### Microsoft Teams (Power Automate)

**URL pattern**: `webhook.office.com`

**Setup**:
1. In Teams, go to the channel where you want notifications
2. Click **[...]** → **Connectors** → **Configure**
3. Search **Power Automate** → **Configure**
4. Give it a name: "PIM Monitor"
5. **Create** → Copy the webhook URL

**Payload format**: Adaptive Card

**Example**:
```
┌─────────────────────────────────┐
│ PIM Monitor                     │
│ 2 High, 1 Medium changes       │
│                                 │
│ ■ Directory Roles (High)        │
│   Global Administrator > policy │
│                                 │
│ ■ Auth Contexts (Medium)        │
│   Conditional Access rule       │
│                                 │
│ [View diff] 2026-04-27T18:42Z   │
└─────────────────────────────────┘
```

### Slack

**URL pattern**: `hooks.slack.com`

**Setup**:
1. Go to **api.slack.com** → **Apps** → **Create New App**
2. **From scratch** → Name: "PIM Monitor", workspace: select yours
3. **Incoming Webhooks** → Turn on
4. **Add New Webhook to Workspace** → Select channel → **Allow**
5. Copy the webhook URL

**Payload format**: Slack blocks (with markdown, colors)

**Example**:
```
📊 PIM Monitor
━━━━━━━━━━━━━━━━━━━━━━━━━
2 High, 1 Medium changes

🔴 High (2)
• Directory Roles > policy change
• Auth Contexts > rule update

🟠 Medium (1)
• PIM Groups > expiration adjusted

[View diff] 2026-04-27 18:42 UTC
```

### Discord

**URL pattern**: `discord.com/api/webhooks`

**Setup**:
1. In Discord, go to **Server Settings** → **Integrations** → **Webhooks**
2. **Create Webhook**
3. Name: "PIM Monitor"
4. Select channel: where notifications appear
5. **Copy Webhook URL**

**Payload format**: Discord embed (with colors, timestamps)

**Example**:
```
╔═════════════════════════════════╗
║ PIM Monitor                     ║
║ Scan completed: 3 changes       ║
╠═════════════════════════════════╣
║ 🔴 High (2)                     ║
║ • role policy change            ║
║                                 ║
║ 🟠 Medium (1)                   ║
║ • expiration update             ║
║                                 ║
║ 2026-04-27 18:42:15 UTC         ║
╚═════════════════════════════════╝
```

### Generic JSON (Custom Webhooks)

**URL pattern**: Any URL NOT matching Teams/Slack/Discord

For custom APIs, webhooks, or other platforms.

**Payload format**: Plain JSON

```json
{
  "text": "[PIM Monitor] 3 changes detected",
  "summary": "2 High, 1 Medium",
  "changesBySeverity": {
    "High": [
      {
        "workload": "directory-roles",
        "entity": "global-administrator",
        "description": "policy updated",
        "severity": "High"
      }
    ],
    "Medium": [...],
    "Low": [...],
    "Informational": [...]
  }
}
```

## How Auto-Detection Works

The `Get-WebhookType` function (notifications.ps1) inspects the URL:

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

**To detect a custom service**, modify this function to add a new URL pattern:

```powershell
elseif ($Url -match "my-custom-api\.com") {
    return "MyCustom"
}
```

## Customizing Payloads

### Teams Adaptive Card

Edit `Build-TeamsPayload` in `src/notifications.ps1` (lines ~837–1000):

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

Edit `Build-SlackPayload` in `src/notifications.ps1` (lines ~1009–1117):

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

Edit `Build-DiscordPayload` in `src/notifications.ps1` (lines ~1126–1236):

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
# Test a Teams webhook (replace with your actual URL)
curl -X POST https://outlook.webhook.office.com/webhookb2/... \
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

- [Environment Variables](./environment-variables.md) — NOTIFICATION_WEBHOOK_URL
- [Email Notifications](./email-notifications.md) — Email setup
- [Notifications](./notifications.md) — General notification configuration
- [Scan Errors](./scan-errors.md) — Scan error webhook format
