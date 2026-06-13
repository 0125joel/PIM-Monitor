<#
.SYNOPSIS
    Discord payload builders for PIM Monitor.

.DESCRIPTION
    Build-DiscordPayload (change notifications, multi-embed structure) and
    Build-ScanErrorDiscordPayload (scan-error embed). Dispatched from
    notifications-webhook.ps1 when the webhook URL matches discord.com/api/webhooks.
    Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Builds a Discord webhook payload with a summary embed plus per-severity
    and Access Model embeds (max 10 embeds per message).

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER MinSeverity
    Skip severities below this threshold (default Medium).

.PARAMETER CommitSha
    Optional commit SHA used by the Reports field's "Diff" link.

.PARAMETER TenantName
    Optional tenant display name, shown as the summary embed's author.
#>
function Build-DiscordPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha,
        [string] $TenantName
    )

    $complianceTypes = $script:ComplianceFileTypes
    $timestamp       = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'

    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $cov = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
    $tot = $hi + $med + $lo + $inf + $cov

    $diffUrl   = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $reportUrl = Get-ArtifactReportUrl

    # Determines top severity color for the summary embed.
    $topColor = if     ($hi  -gt 0) { Get-SeverityColorInt 'High' }
                elseif ($med -gt 0) { Get-SeverityColorInt 'Medium' }
                elseif ($lo  -gt 0) { Get-SeverityColorInt 'Low' }
                else                { Get-SeverityColorInt 'Informational' }

    # Renders the diff for a single change as a Discord codeblock string. Returns the
    # full field value (description bullet + optional codeblock) capped at 1024 chars.
    $renderChangeFieldValue = {
        param($change)
        $rows = Get-ChangeDiffRows -Change $change -MaxRows 5
        if ($null -eq $rows -or $rows.Count -eq 0) { return '' }
        $lines = @($rows | ForEach-Object { "$($_.Key): $($_.Actual) -> $($_.New)" })
        $code  = "``````" + "`n" + ($lines -join "`n") + "`n" + "``````"
        if ($code.Length -gt 1020) { $code = $code.Substring(0, 1017) + '...' }
        return $code
    }

    # Builds an array of field objects for one set of changes. Honors Discord limits:
    # max 25 fields per embed, max 1024 chars per field value. Truncates with a final
    # field "_+N more_" if exceeded.
    $buildChangeFields = {
        param($items, [int]$maxItems = 24)  # 24 to leave room for a possible "+N more" field
        $fields = @()
        $shown  = 0
        foreach ($change in $items) {
            if ($shown -ge $maxItems) { break }
            $name = if ($change['context']) { [string]$change['context'] } else { [string]$change['description'] }
            if ($name.Length -gt 256) { $name = $name.Substring(0, 253) + '...' }
            $value = & $renderChangeFieldValue $change
            if (-not $value) { $value = "_$([string]$change['description'])_" }  # Discord rejects empty field value
            if ($value.Length -gt 1024) { $value = $value.Substring(0, 1021) + '...' }
            $fields += @{ name = $name; value = $value; inline = $false }
            $shown++
        }
        if ($items.Count -gt $shown) {
            $fields += @{ name = '...'; value = "_+$($items.Count - $shown) more_"; inline = $false }
        }
        return $fields
    }

    # -------------------- Embed 1: Summary --------------------
    $execLine = Get-ExecutiveSummaryLine -ChangesBySeverity $ChangesBySeverity -TenantName $TenantName

    $summaryFields = @(
        @{ name = 'Total';         value = "$tot"; inline = $true }
        @{ name = 'High';          value = "$hi";  inline = $true }
        @{ name = 'Medium';        value = "$med"; inline = $true }
        @{ name = 'Low';           value = "$lo";  inline = $true }
        @{ name = 'Informational'; value = "$inf"; inline = $true }
    )
    if ($cov -gt 0) {
        $summaryFields += @{ name = 'Classification'; value = "$cov"; inline = $true }
    }

    $summaryEmbed = @{
        title       = 'PIM Monitor — change detected'
        description = $execLine
        color       = $topColor
        timestamp   = $timestamp
        fields      = $summaryFields
    }
    if ($TenantName) {
        $summaryEmbed['author'] = @{ name = "Tenant: $TenantName" }
    }

    $embeds = @($summaryEmbed)

    # -------------------- Pass 1: CHANGES — one embed per severity with git items --------------------
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $gitItems = @($ChangesBySeverity.$severity | Where-Object { -not $complianceTypes.Contains($_['fileType']) })
        if ($gitItems.Count -eq 0) { continue }

        $sorted = @($gitItems | Sort-Object { $_['changeType'] })
        $embeds += @{
            title  = "CHANGES — $severity ($($gitItems.Count))"
            color  = (Get-SeverityColorInt $severity)
            fields = @(& $buildChangeFields $sorted 20)
        }
    }

    # -------------------- Pass 2: ACCESS MODEL — Compliance embed --------------------
    $compItems = @()
    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $compItems += @($ChangesBySeverity.$severity | Where-Object { $complianceTypes.Contains($_['fileType']) })
    }
    if ($compItems.Count -gt 0) {
        $embeds += @{
            title       = "ACCESS MODEL — Compliance ($($compItems.Count))"
            description = 'Policy deviates from `expectedConfig`. Format: `property: actual -> expected`.'
            color       = (Get-SeverityColorInt 'AccessModel')
            fields      = @(& $buildChangeFields $compItems 20)
        }
    }

    # -------------------- Pass 3: ACCESS MODEL — Coverage embed --------------------
    if ($cov -gt 0) {
        $covItems = @($ChangesBySeverity.Coverage | Sort-Object { $_['context'] })
        $lines    = @($covItems | Select-Object -First 30 | ForEach-Object { "• $($_['context'])" })
        $body     = $lines -join "`n"
        if ($covItems.Count -gt 30) { $body += "`n_+$($covItems.Count - 30) more_" }
        if ($body.Length -gt 4090) { $body = $body.Substring(0, 4087) + '...' }

        $embeds += @{
            title       = "ACCESS MODEL — Coverage ($($covItems.Count))"
            description = "$body`n`n_Roles not in any access model definition. Add to AccessModel/*.json or AccessModel/coverage-exclusions.json._"
            color       = (Get-SeverityColorInt 'Coverage')
        }
    }

    # -------------------- Reports field on the last embed --------------------
    $reportsParts = @()
    if ($diffUrl)   { $reportsParts += "[Diff]($diffUrl)" }
    if ($reportUrl) { $reportsParts += "[HTML report]($reportUrl)" }
    if ($reportsParts.Count -gt 0) {
        $last = $embeds[-1]
        if (-not ('fields' -in $last.Keys)) { $last['fields'] = @() }
        # Avoid breaching 25-field limit; drop the last existing field if needed.
        if ($last.fields.Count -ge 25) { $last.fields = $last.fields[0..23] }
        $last.fields += @{ name = '📄 Reports'; value = ($reportsParts -join ' • '); inline = $false }
    }

    # -------------------- Embed-count guard (Discord hard limit = 10) --------------------
    if ($embeds.Count -gt 10) {
        $embeds = $embeds[0..9]
    }

    # allowed_mentions explicit empty so any stray @tokens never trigger mass-pings.
    return @{
        embeds          = $embeds
        allowed_mentions = @{ parse = @() }
    }
}

function Build-ScanErrorDiscordPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $ScanErrors)

    $fields = @()
    foreach ($err in $ScanErrors) {
        $truncatedError = if ($err.Error.Length -gt 200) {
            $err.Error.Substring(0, 200) + '...'
        } else {
            $err.Error
        }
        $fields += @{
            name   = $err.Component
            value  = $truncatedError
            inline = $false
        }
    }

    $embed = @{
        title       = '[PIM Monitor] Scan completed with errors'
        description = "$($ScanErrors.Count) component(s) failed. Partial scan data may be incomplete."
        color       = (Get-SeverityColorInt 'High')
        timestamp   = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
        fields      = $fields
    }

    return @{ embeds = @($embed); allowed_mentions = @{ parse = @() } }
}
