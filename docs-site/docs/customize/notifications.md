---
sidebar_position: 5
---

# Notifications

## Change the severity threshold

Set `NOTIFICATION_MIN_SEVERITY` in your pipeline variables:

```
NOTIFICATION_MIN_SEVERITY = High
```

Valid values: `High`, `Medium`, `Low`. Default is `Medium`.

## Add a new webhook channel

Edit `src/notifications.ps1` and add a new payload builder:

```powershell
function Build-MyCustomPayload {
    param($ChangesBySeverity)
    return @{
        text    = "PIM Monitor: $($ChangesBySeverity.total) changes"
        high    = $ChangesBySeverity.high
        medium  = $ChangesBySeverity.medium
        low     = $ChangesBySeverity.low
    }
}
```

Then add URL detection in `Send-WebhookNotification`:

```powershell
$payload = if ($WebhookUrl -match "my-custom-domain\.com") {
    Build-MyCustomPayload -ChangesBySeverity $ChangesBySeverity
} elseif ($WebhookUrl -match "hooks\.slack\.com") {
    Build-SlackPayload -ChangesBySeverity $ChangesBySeverity
} # ...
```

## Change the email format

Edit `Build-EmailBody` in `src/notifications.ps1`. The function receives `$ChangesBySeverity` and returns an HTML string. Any valid HTML works.

## Disable notifications for specific severity levels

Instead of using the threshold variable, you can filter in the script itself:

```powershell
$filtered = $changes | Where-Object { $_.severity -ne "Low" }
```
