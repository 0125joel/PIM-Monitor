<#
.SYNOPSIS
    Scan error notification delivery for PIM Monitor.

.DESCRIPTION
    Sends notifications when scan components fail.
    Requires dot-sourcing notifications-email.ps1 and notifications-webhook.ps1 first.
#>

<#
.SYNOPSIS
    Sends a scan-error notification listing which components failed.

.DESCRIPTION
    Called when one or more scan components caught a non-fatal exception.
    Uses the same NOTIFICATION_EMAIL, NOTIFICATION_MAIL_FROM, and
    NOTIFICATION_WEBHOOK_URL env vars as Send-EmailNotification /
    Send-WebhookNotification, but delivers an entirely separate payload.

.PARAMETER ScanErrors
    Array of @{Component = string; Error = string} hashtables.

.PARAMETER AccessToken
    Graph API bearer token.

.PARAMETER ToAddress
    Recipient address. Null/empty skips email delivery.

.PARAMETER FromAddress
    Sender address. Null/empty skips email delivery.

.PARAMETER WebhookUrl
    Full webhook URL. Null/empty skips webhook delivery.
#>
function Send-ScanErrorNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]  $ScanErrors,
        [Parameter(Mandatory)] [string] $AccessToken,
        [string] $ToAddress,
        [string] $FromAddress,
        [string] $WebhookUrl
    )

    if ($ScanErrors.Count -eq 0) { return }

    $componentList = ($ScanErrors | ForEach-Object { $_.Component }) -join ', '
    Write-Host "  Scan errors in: $componentList"

    # ---- Email ----
    if ($ToAddress -and $FromAddress) {
        $htmlBody = Format-ScanErrorHtml -ScanErrors $ScanErrors
        $s        = if ($ScanErrors.Count -eq 1) { 'component' } else { 'components' }
        $subject  = "[PIM Monitor] Scan completed with errors ($($ScanErrors.Count) $s failed)"

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

        $uri     = "https://graph.microsoft.com/v1.0/users/$FromAddress/sendMail"
        $headers = @{
            Authorization  = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
        }

        try {
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null
            Write-Host "  Scan-error email sent to $ToAddress"
        }
        catch {
            Write-Warning "  Scan-error email send failed: $_"
        }
    }

    # ---- Webhook ----
    if ($WebhookUrl) {
        $type = Get-WebhookType -Url $WebhookUrl

        $payload = switch ($type) {
            'Teams'   { Build-ScanErrorTeamsPayload   -ScanErrors $ScanErrors }
            'Slack'   { Build-ScanErrorSlackPayload   -ScanErrors $ScanErrors }
            'Discord' { Build-ScanErrorDiscordPayload -ScanErrors $ScanErrors }
            default   {
                @{
                    text       = "[PIM Monitor] Scan completed with errors"
                    scanErrors = @($ScanErrors | ForEach-Object {
                        @{ component = $_.Component; error = $_.Error }
                    })
                }
            }
        }

        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post `
                -ContentType 'application/json' `
                -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null
            Write-Host "  Scan-error webhook sent ($type)"
        }
        catch {
            Write-Warning "  Scan-error webhook send failed: $_"
        }
    }
}
