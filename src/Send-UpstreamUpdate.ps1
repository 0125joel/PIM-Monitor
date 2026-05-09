#Requires -Version 7.0

. (Join-Path -Path $PSScriptRoot -ChildPath "helpers.ps1")

Add-Type -AssemblyName System.Web

$latestVersion  = $env:UPSTREAM_LATEST_VERSION
$currentVersion = $env:UPSTREAM_CURRENT_VERSION
$repoUrl        = $env:UPSTREAM_REPO_URL
$releaseUrl     = "$repoUrl/releases/tag/v$latestVersion"

$releaseNotes = ""
try {
    $apiRepoPath = $repoUrl -replace '^https://github\.com/', ''
    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$apiRepoPath/releases/latest" `
        -Headers @{ Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" } `
        -TimeoutSec 10
    $releaseNotes = $release.PSObject.Properties['body']?.Value ?? ""
} catch {
    Write-Warning "Could not fetch release notes: $_"
}

$textMsg = "PIM Monitor $latestVersion is available (running $currentVersion). See $releaseUrl"

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

    $notesHtml = if ($releaseNotes) {
        $escaped = [System.Web.HttpUtility]::HtmlEncode($releaseNotes)
        "<tr><td style=`"padding:4px 32px 20px;`"><pre style=`"font-family:'Courier New','Lucida Console',monospace;font-size:11px;color:#525252;line-height:1.6;white-space:pre-wrap;margin:0;`">$escaped</pre></td></tr>"
    } else { "" }

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
    <div style="font-weight:600;font-size:13px;color:#fcd34d;font-family:'Courier New','Lucida Console',monospace;margin-bottom:4px;">v$latestVersion available</div>
    <div style="font-size:12px;color:#fcd34d;line-height:1.5;">A new version of PIM Monitor is available. You are running v$currentVersion. Review the release notes and update your deployment.</div>
  </div>
</td></tr>
$notesHtml<tr><td style="padding:8px 32px;">
  <a href="$([System.Web.HttpUtility]::HtmlAttributeEncode($releaseUrl))" style="display:inline-block;font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.12em;text-transform:uppercase;color:#d97706;text-decoration:none;border:1px solid #d97706;border-radius:3px;padding:6px 14px;">View release on GitHub</a>
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
            subject      = "PIM Monitor $latestVersion available (running $currentVersion)"
            body         = @{ contentType = "HTML"; content = $htmlBody }
            toRecipients = @(@{ emailAddress = @{ address = $env:NOTIFICATION_EMAIL } })
        }
    } | ConvertTo-Json -Depth 10

    try {
        $mailUri     = "https://graph.microsoft.com/v1.0/users/$($env:NOTIFICATION_MAIL_FROM)/sendMail"
        $mailHeaders = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $mailUri -Method Post -Headers $mailHeaders -Body $body }.GetNewClosure() -OperationName "sendMail (upstream update)" | Out-Null
        Write-Host "Upstream update email sent"
    } catch {
        Write-Warning "Upstream update email failed: $_"
    }
}
