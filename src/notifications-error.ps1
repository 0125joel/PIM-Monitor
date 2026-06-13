function Send-ScanErrorNotification {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [array]  $ScanErrors,
        [Parameter(Mandatory)] [string] $AccessToken,
        [string] $ToAddress,
        [string] $FromAddress,
        [string] $WebhookUrl
    )

    if ($ScanErrors.Count -eq 0) { return }
    if (-not $PSCmdlet.ShouldProcess('scan-error notification', 'Send')) { return }

    $componentList = ($ScanErrors | ForEach-Object { $_.Component }) -join ', '
    Write-Host "  Scan errors in: $componentList"

    if ($ToAddress -and $FromAddress) {
        $htmlBody = Build-ScanErrorEmailHtml -ScanErrors $ScanErrors
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
            $sendBody = $payload | ConvertTo-Json -Depth 10
            Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $sendBody }.GetNewClosure() -OperationName "scan-error sendMail to $ToAddress" | Out-Null
            Write-Host "  Scan-error email sent to $ToAddress"
        }
        catch {
            Write-Warning "  Scan-error email send failed: $_"
        }
    }

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

        $body = $payload | ConvertTo-Json -Depth 10
        try {
            Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body | Out-Null
            }.GetNewClosure() -OperationName "scan-error webhook ($type)"
            Write-Host "  Scan-error webhook sent ($type)"
        }
        catch {
            Write-Warning "  Scan-error webhook send failed: $_"
        }
    }
}
