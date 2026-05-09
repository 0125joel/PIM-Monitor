<#
.SYNOPSIS
    Email notification delivery for PIM Monitor changes.

.DESCRIPTION
    Sends change summaries via Microsoft Graph sendMail API.
    Requires Mail.Send application permission on the service principal.
    Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Sends a change summary email via Graph sendMail.

.DESCRIPTION
    Requires Mail.Send application permission on the service principal.
    Uses the sender address from NOTIFICATION_MAIL_FROM env var.

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER ToAddress
    Recipient email address (from NOTIFICATION_EMAIL env var).

.PARAMETER FromAddress
    Sender email address (from NOTIFICATION_MAIL_FROM env var).

.PARAMETER AccessToken
    Graph API access token.

.PARAMETER MinSeverity
    Skip sending if no changes meet this threshold (default Medium).
#>
function Send-EmailNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $ToAddress,
        [Parameter(Mandatory)] [string] $FromAddress,
        [Parameter(Mandatory)] [string] $AccessToken,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha,
        [hashtable] $AuthContextLookup = @{}
    )

    # Count changes meeting threshold
    $relevantCount = 0
    foreach ($sev in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$sev] -ge $script:SeverityRank[$MinSeverity]) {
            $relevantCount += $ChangesBySeverity.$sev.Count
        }
    }

    if ($relevantCount -eq 0) {
        Write-Host "  No changes at or above $MinSeverity severity — skipping email"
        return
    }

    $commitUrl = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $htmlBody = Format-ChangeSummaryHtml -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitUrl $commitUrl -AuthContextLookup $AuthContextLookup

    $sevParts = @()
    if ($ChangesBySeverity.High.Count -gt 0)          { $sevParts += "$($ChangesBySeverity.High.Count) High" }
    if ($ChangesBySeverity.Medium.Count -gt 0)        { $sevParts += "$($ChangesBySeverity.Medium.Count) Medium" }
    if ($ChangesBySeverity.Low.Count -gt 0)           { $sevParts += "$($ChangesBySeverity.Low.Count) Low" }
    if ($ChangesBySeverity.Informational.Count -gt 0) { $sevParts += "$($ChangesBySeverity.Informational.Count) Info" }
    $s       = if ($relevantCount -eq 1) { 'change' } else { 'changes' }
    $subject = if ($sevParts.Count -eq 1) {
        "[PIM Monitor] $($sevParts[0]) ${s}"
    } else {
        "[PIM Monitor] $relevantCount ${s}: $($sevParts -join ', ')"
    }

    $payload = @{
        message = @{
            subject = $subject
            body = @{
                contentType = 'HTML'
                content     = $htmlBody
            }
            toRecipients = @(
                @{ emailAddress = @{ address = $ToAddress } }
            )
        }
        saveToSentItems = $false
    }

    $uri = "https://graph.microsoft.com/v1.0/users/$FromAddress/sendMail"
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
            -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null
        Write-Host "  Email sent to $ToAddress"
    }
    catch {
        Write-Warning "  Email send failed: $_"
    }
}

<#
.SYNOPSIS
    Formats scan error email body as HTML.

.PARAMETER ScanErrors
    Array of @{Component = string; Error = string} hashtables.
#>
function Format-ScanErrorHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $ScanErrors)

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $rows = @()

    foreach ($err in $ScanErrors) {
        $truncatedError = if ($err.Error.Length -gt 200) {
            $err.Error.Substring(0, 200) + '...'
        } else {
            $err.Error
        }
        $compE  = [System.Web.HttpUtility]::HtmlEncode($err.Component)
        $errE   = [System.Web.HttpUtility]::HtmlEncode($truncatedError)

        $rows += "<tr><td style=`"padding:2px 32px;`">" +
            "<details style=`"border-left:3px solid #ef4444;background-color:#fef2f2;border-radius:0 3px 3px 0;`">" +
            "<summary style=`"padding:10px 14px;cursor:pointer;list-style:none;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:14px;font-weight:600;color:#1a1a1a;`">$compE</summary>" +
            "<div style=`"padding:4px 14px 10px;border-top:1px solid #d4d4d4;font-family:'Courier New','Lucida Console',monospace;font-size:11px;color:#b91c1c;line-height:1.6;`">$errE</div>" +
            "</details></td></tr>"
    }
    $rowsHtml = $rows -join ''

    return @"
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
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:20px;font-weight:600;letter-spacing:-0.01em;color:#ef4444;">pim/monitor</div>
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#a3a3a3;margin-top:4px;letter-spacing:0.12em;text-transform:uppercase;">scan errors</div>
</td></tr>
<tr><td style="padding:14px 32px;background-color:#fef2f2;border-top:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;">
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#b91c1c;font-weight:600;">$($ScanErrors.Count) component(s) failed — partial scan data may be incomplete.</div>
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;margin-top:8px;letter-spacing:0.06em;">$timestamp</div>
</td></tr>
$rowsHtml
<tr><td style="padding:20px 32px 24px;border-top:1px solid #e5e5e5;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;letter-spacing:0.06em;">PIM Monitor · automated scan notification</div>
</td></tr>
</table>
</td></tr></table>
</body>
</html>
"@
}
