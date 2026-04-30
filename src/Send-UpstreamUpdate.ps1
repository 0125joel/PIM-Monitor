<#
.SYNOPSIS
    Sends an upstream-update notification via webhook and/or email.

.DESCRIPTION
    Called by monitor-pipeline.yml when upstream commits are available.
    Reads NOTIFICATION_WEBHOOK_URL, NOTIFICATION_EMAIL, NOTIFICATION_MAIL_FROM,
    and UPSTREAM_COMMITS_AHEAD from environment variables.
    Uses Get-AzAccessToken (Az.Accounts) for the Graph sendMail call.
#>

#Requires -Version 7.0

Add-Type -AssemblyName System.Web

$ahead   = $env:UPSTREAM_COMMITS_AHEAD
$repoUrl = "https://github.com/0125joel/PIM-Monitor"
$textMsg = "PIM Monitor: $ahead new commit(s) available upstream. Review and update from $repoUrl"

if ($env:NOTIFICATION_WEBHOOK_URL -and $env:NOTIFICATION_WEBHOOK_URL -notmatch '^\$\(') {
    $webhookUrl = $env:NOTIFICATION_WEBHOOK_URL
    $payload = if ($webhookUrl -match 'discord\.com/webhooks') {
        @{ content = $textMsg } | ConvertTo-Json
    } else {
        @{ text = $textMsg } | ConvertTo-Json
    }
    try {
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json"
        Write-Host "Upstream update webhook sent"
    } catch {
        Write-Warning "Upstream update webhook failed: $_"
    }
}

if ($env:NOTIFICATION_EMAIL -and $env:NOTIFICATION_EMAIL -notmatch '^\$\(' -and
    $env:NOTIFICATION_MAIL_FROM -and $env:NOTIFICATION_MAIL_FROM -notmatch '^\$\(') {

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $htmlBody = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
</head>
<body style="margin:0;padding:0;background-color:#fafafa;">
<table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fafafa;"><tr><td align="center" style="padding:24px 16px;">
<table width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;background-color:#ffffff;border:1px solid #e5e5e5;border-radius:4px;">
<tr><td style="padding:28px 32px 20px;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:20px;font-weight:600;letter-spacing:-0.01em;color:#d97706;">pim/monitor</div>
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#a3a3a3;margin-top:4px;letter-spacing:0.12em;text-transform:uppercase;">upstream updates</div>
</td></tr>
<tr><td style="padding:20px 32px;">
  <div style="border:1px solid rgba(217,119,6,0.5);border-left-width:2px;border-radius:4px;padding:12px 14px;background:rgba(217,119,6,0.05);">
    <div style="font-weight:600;font-size:13px;color:#fcd34d;font-family:'Courier New','Lucida Console',monospace;margin-bottom:4px;">$ahead commit(s) available</div>
    <div style="font-size:12px;color:#fcd34d;line-height:1.5;">New commits are available on the upstream repository. Review and pull updates to keep your local copy current.</div>
  </div>
</td></tr>
<tr><td style="padding:8px 32px;">
  <a href="$([System.Web.HttpUtility]::HtmlAttributeEncode($repoUrl))" style="display:inline-block;font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.12em;text-transform:uppercase;color:#d97706;text-decoration:none;border:1px solid #d97706;border-radius:3px;padding:6px 14px;">View on GitHub</a>
</td></tr>
<tr><td style="padding:14px 32px;background-color:#fafafa;border-top:1px solid #e5e5e5;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;letter-spacing:0.06em;">$timestamp</div>
</td></tr>
<tr><td style="padding:20px 32px 24px;border-top:1px solid #e5e5e5;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;letter-spacing:0.06em;">PIM Monitor · automated scan notification</div>
</td></tr>
</table>
</td></tr></table>
</body>
</html>
"@

    $rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
    $token = if ($rawToken -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $rawToken).Password
    } else { $rawToken }

    $body = @{
        message = @{
            subject      = "PIM Monitor: $ahead upstream update(s) available"
            body         = @{ contentType = "HTML"; content = $htmlBody }
            toRecipients = @(@{ emailAddress = @{ address = $env:NOTIFICATION_EMAIL } })
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($env:NOTIFICATION_MAIL_FROM)/sendMail" `
            -Method Post -Headers @{ Authorization = "Bearer $token" } `
            -Body $body -ContentType "application/json"
        Write-Host "Upstream update email sent"
    } catch {
        Write-Warning "Upstream update email failed: $_"
    }
}
