<#
.SYNOPSIS
    Webhook dispatcher for PIM Monitor notifications.

.DESCRIPTION
    Auto-detects the webhook platform from the URL and delegates payload
    construction to a per-platform module (notifications-webhook-teams.ps1,
    -slack.ps1, -discord.ps1). Generic JSON fallback is built inline here.

    Dot-source order (handled by Scan-PimState.ps1):
        notifications-shared.ps1
        notifications-webhook-teams.ps1
        notifications-webhook-slack.ps1
        notifications-webhook-discord.ps1
        notifications-webhook.ps1   (this file — dispatcher)
#>

<#
.SYNOPSIS
    Detects webhook type from URL, with an optional explicit override.

.DESCRIPTION
    NOTIFICATION_WEBHOOK_TYPE (Teams, Slack, Discord, Generic) overrides URL detection.
    This matters for Logic App / Power Automate URLs (*.logic.azure.com), which are
    detected as Teams by default: a Logic App consuming the generic JSON schema needs
    NOTIFICATION_WEBHOOK_TYPE=Generic to receive the documented payload instead of an
    Adaptive Card. An unrecognized override value is ignored with a warning.
#>
function Get-WebhookType {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Url)

    $override = Get-PipelineEnvVar -Name 'NOTIFICATION_WEBHOOK_TYPE'
    if ($override) {
        $known = @('Teams', 'Slack', 'Discord', 'Generic') | Where-Object { $_ -eq $override }
        if ($known) { return [string]$known }
        Write-Warning "NOTIFICATION_WEBHOOK_TYPE '$override' is not one of Teams/Slack/Discord/Generic; falling back to URL detection"
    }

    # Teams: legacy O365 incoming connector (fully retired by Microsoft in May 2026 — these
    # URLs no longer deliver) and current Power Automate workflow URLs. Workflow URLs are
    # regional (prod-NN.<region>.logic.azure.com) or routed through the API Management
    # gateway (*.azure-apim.net). The webhook.office.com match is kept only so a stale URL
    # is still labelled Teams in logs; new setups must use Power Automate.
    if ($Url -match 'webhook\.office\.com')      { return 'Teams' }
    if ($Url -match '\.logic\.azure\.com')       { return 'Teams' }
    if ($Url -match '\.azure-apim\.net')         { return 'Teams' }
    if ($Url -match 'hooks\.slack\.com')         { return 'Slack' }
    if ($Url -match 'discord\.com/api/webhooks') { return 'Discord' }
    return 'Generic'
}

<#
.SYNOPSIS
    Builds the v1.0.0 generic JSON payload for unknown webhook endpoints.

.DESCRIPTION
    Versioned, schema-backed payload suitable for Logic Apps, n8n, SIEMs, and
    custom integrations. The shape is described by `schemas/notification-payload-v1.json`.
    Consumers should validate against that schema.

    Backwards compat: the pre-formalization fields (`text`, `summary`,
    `changesBySeverity`) live under `_legacy.*` and are deprecated in v1.0.0;
    they will be removed in v2.0.0.
#>
function Build-GenericPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [int] $RelevantCount,
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha,
        [string] $TenantName
    )

    # Collect git + compliance changes at or above threshold, sorted High → Informational.
    $allChanges = @()
    foreach ($sev in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$sev] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $allChanges += @($ChangesBySeverity.$sev | ForEach-Object { ConvertTo-ChangePayloadObject -Change $_ })
    }
    if ($allChanges.Count -gt 50) {
        $changesArr = @($allChanges | Select-Object -First 49) + @(@{ _truncated = $true; remaining = ($allChanges.Count - 49) })
    } else {
        $changesArr = $allChanges
    }
    [object[]]$changesArr = $changesArr  # force array shape so ConvertTo-Json never unwraps a single element

    # Coverage (unclassified roles/groups) — separate array, same truncation rule.
    $covArr = @()
    if ($ChangesBySeverity['Coverage']) {
        $covRaw = @($ChangesBySeverity.Coverage | ForEach-Object {
            $o = [ordered]@{ context = [string]$_['context'] }
            if ($_['entity']) { $o['entity'] = [string]$_['entity'] }
            if ($o['context']) { $o } else { $null }
        } | Where-Object { $_ })
        if ($covRaw.Count -gt 50) {
            $covArr = @($covRaw | Select-Object -First 49) + @(@{ _truncated = $true; remaining = ($covRaw.Count - 49) })
        } else {
            $covArr = $covRaw
        }
        [object[]]$covArr = $covArr  # force array shape (avoid ConvertTo-Json single-element unwrap)
    }

    $payload = [ordered]@{
        '$schema'     = 'https://raw.githubusercontent.com/intothecloud/pim-monitor/main/schemas/notification-payload-v1.json'
        schemaVersion = '1.0.0'
        scan          = (Get-ScanMetadata -CommitSha $CommitSha -MinSeverity $MinSeverity)
        summary       = [ordered]@{
            text   = (Get-ExecutiveSummaryLine -ChangesBySeverity $ChangesBySeverity -TenantName $TenantName)
            counts = [ordered]@{
                total          = $ChangesBySeverity.Total
                high           = $ChangesBySeverity.High.Count
                medium         = $ChangesBySeverity.Medium.Count
                low            = $ChangesBySeverity.Low.Count
                informational  = $ChangesBySeverity.Informational.Count
                classification = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
            }
        }
        changes       = $changesArr
    }

    if ($TenantName)    { $payload['tenant']   = @{ name = $TenantName } }
    if ($covArr.Count)  { $payload['coverage'] = $covArr }

    # urls block — only emit when at least one URL is inferable from env.
    $urls = [ordered]@{}
    if ($CommitSha) {
        $diff = Get-CommitDiffUrl -CommitSha $CommitSha
        if ($diff) { $urls['diff'] = $diff }
    }
    $report = Get-ArtifactReportUrl
    if ($report) { $urls['report'] = $report }
    if ($urls.Count -gt 0) { $payload['urls'] = $urls }

    # Backwards-compat block: mirrors the pre-v1.0.0 shape. Deprecated; removed in v2.0.0.
    $payload['_legacy'] = [ordered]@{
        text              = "PIM Monitor — $RelevantCount change(s) detected"
        summary           = Format-ChangeSummaryText -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity
        changesBySeverity = [ordered]@{
            high          = $ChangesBySeverity.High.Count
            medium        = $ChangesBySeverity.Medium.Count
            low           = $ChangesBySeverity.Low.Count
            informational = $ChangesBySeverity.Informational.Count
            total         = $ChangesBySeverity.Total
        }
    }

    return $payload
}

<#
.SYNOPSIS
    Sends a change summary to a webhook endpoint.

.DESCRIPTION
    Auto-detects payload shape from URL (Teams / Slack / Discord / generic)
    and delegates to the matching builder. Skips when no changes meet the
    minimum severity threshold.

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER WebhookUrl
    Full webhook URL.

.PARAMETER MinSeverity
    Skip if no changes meet this threshold (default Medium).

.PARAMETER CommitSha
    Optional commit SHA to include as a diff link in the payload.

.PARAMETER TenantName
    Optional tenant display name, used in header/subtitle for triage.

.PARAMETER MentionUpns
    Teams-only: UPNs to @-mention on High-severity changes.
#>
function Send-WebhookNotification {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $WebhookUrl,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string]   $MinSeverity = 'Medium',
        [string]   $CommitSha,
        [string]   $TenantName,
        [string[]] $MentionUpns = @()
    )

    $relevantCount = 0
    foreach ($sev in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$sev] -ge $script:SeverityRank[$MinSeverity]) {
            $relevantCount += $ChangesBySeverity.$sev.Count
        }
    }
    if ($ChangesBySeverity['Coverage'] -and $script:SeverityRank['Medium'] -ge $script:SeverityRank[$MinSeverity]) {
        $relevantCount += $ChangesBySeverity.Coverage.Count
    }
    if ($relevantCount -eq 0) {
        Write-Host "  No changes at or above $MinSeverity severity — skipping webhook"
        return
    }

    $type = Get-WebhookType -Url $WebhookUrl
    $payload = switch ($type) {
        'Teams'   { Build-TeamsPayload   -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha -TenantName $TenantName -MentionUpns $MentionUpns }
        'Slack'   { Build-SlackPayload   -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha -TenantName $TenantName }
        'Discord' { Build-DiscordPayload -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha -TenantName $TenantName }
        default   { Build-GenericPayload -ChangesBySeverity $ChangesBySeverity -RelevantCount $relevantCount -MinSeverity $MinSeverity -CommitSha $CommitSha -TenantName $TenantName }
    }

    if (-not $PSCmdlet.ShouldProcess($WebhookUrl, 'Send webhook notification')) { return }

    $body = $payload | ConvertTo-Json -Depth 20
    try {
        Invoke-WithRetry -ScriptBlock {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body | Out-Null
        }.GetNewClosure() -OperationName "webhook ($type)"
        Write-Host "  Webhook sent ($type)"
    }
    catch {
        Write-Warning "  Webhook send failed: $_"
    }
}

