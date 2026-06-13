<#
.SYNOPSIS
    Slack payload builders for PIM Monitor.

.DESCRIPTION
    Build-SlackPayload (change notifications, Block Kit) and
    Build-ScanErrorSlackPayload (scan-error message). Dispatched from
    notifications-webhook.ps1 when the webhook URL matches hooks.slack.com.
    Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Builds a Slack blocks payload.

.PARAMETER CommitSha
    Optional commit SHA for linking to the inventory diff.
#>
function Build-SlackPayload {
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
    $diffUrl   = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $reportUrl = Get-ArtifactReportUrl

    # Renders one change as a single Slack section block: bullet + codeblock of the diff.
    # Triple-backtick codeblocks preserve monospace alignment for Property → value pairs.
    $renderChangeSection = {
        param($change, [string]$leftLabel, [string]$rightLabel)
        $desc = $change['description']
        $rows = @(Get-ChangeDiffRows -Change $change)
        $text = "• $desc"
        if ($rows.Count -gt 0) {
            $diffLines = @($rows | ForEach-Object { "$($_.Key): $($_.Actual) → $($_.New)" })
            $code      = ($diffLines -join "`n")
            if ($code.Length -gt 2800) { $code = $code.Substring(0, 2797) + '...' }
            # Slack ignores leftLabel/rightLabel inside codeblock; using arrow direction keeps it terse.
            $text += "`n``````$code``````"
        }
        return @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
    }

    $moreLink = {
        param([int]$moreCount)
        if ($moreCount -le 0) { return $null }
        if ($reportUrl)       { return @{ type='context'; elements=@(@{ type='mrkdwn'; text="_+$moreCount more — see <$reportUrl|HTML report>_" }) } }
        if ($diffUrl)         { return @{ type='context'; elements=@(@{ type='mrkdwn'; text="_+$moreCount more — see <$diffUrl|commit diff>_" }) } }
        return @{ type='context'; elements=@(@{ type='mrkdwn'; text="_+$moreCount more (truncated)_" }) }
    }

    # ---------------- Header + context + exec summary + counts ----------------
    $execLine = Get-ExecutiveSummaryLine -ChangesBySeverity $ChangesBySeverity -TenantName $TenantName

    $blocks = @(
        @{ type = 'header'; text = @{ type = 'plain_text'; text = 'PIM Monitor — change detected' } }
    )
    $contextElements = @()
    if ($TenantName) { $contextElements += @{ type = 'mrkdwn'; text = "*Tenant:* $TenantName" } }
    $contextElements += @{ type = 'mrkdwn'; text = $timestamp }
    $blocks += @{ type = 'context'; elements = $contextElements }
    $blocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $execLine } }

    $countFields = @(
        @{ type = 'mrkdwn'; text = "*High:* $hi"  }
        @{ type = 'mrkdwn'; text = "*Medium:* $med" }
        @{ type = 'mrkdwn'; text = "*Low:* $lo"  }
        @{ type = 'mrkdwn'; text = "*Informational:* $inf" }
    )
    if ($cov -gt 0) { $countFields += @{ type = 'mrkdwn'; text = "*Classification:* $cov" } }
    $blocks += @{ type = 'section'; fields = $countFields }

    # ---------------- Pass 1 — CHANGES ----------------
    $gitBlocks = @()
    $hasGit    = $false
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $gitItems = @($ChangesBySeverity.$severity | Where-Object { -not $complianceTypes.Contains($_['fileType']) })
        if ($gitItems.Count -eq 0) { continue }
        $hasGit = $true
        $gitBlocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = "*$severity ($($gitItems.Count))*" } }
        $shown = 0
        foreach ($change in ($gitItems | Sort-Object { $_['changeType'] } | Select-Object -First 15)) {
            $gitBlocks += & $renderChangeSection $change 'was' 'changed to'
            $shown++
        }
        if ($gitItems.Count -gt 15) {
            $more = & $moreLink ($gitItems.Count - 15)
            if ($more) { $gitBlocks += $more }
        }
    }
    if ($hasGit) {
        $blocks += @{ type = 'divider' }
        $blocks += @{ type = 'header'; text = @{ type = 'plain_text'; text = 'CHANGES' } }
        $blocks += $gitBlocks
    }

    # ---------------- Pass 2 + 3 — ACCESS MODEL (Compliance + Coverage) ----------------
    $compBlocks = @()
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $compItems = @($ChangesBySeverity.$severity | Where-Object { $complianceTypes.Contains($_['fileType']) })
        if ($compItems.Count -eq 0) { continue }
        $compBlocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = "*Compliance — $severity ($($compItems.Count))*" } }
        foreach ($change in ($compItems | Sort-Object { $_['changeType'] } | Select-Object -First 10)) {
            $compBlocks += & $renderChangeSection $change 'actual' 'expected'
        }
        if ($compItems.Count -gt 10) {
            $more = & $moreLink ($compItems.Count - 10)
            if ($more) { $compBlocks += $more }
        }
    }

    $hasCompliance = $compBlocks.Count -gt 0
    $hasCoverage   = $cov -gt 0
    if ($hasCompliance -or $hasCoverage) {
        $blocks += @{ type = 'divider' }
        $blocks += @{ type = 'header'; text = @{ type = 'plain_text'; text = 'ACCESS MODEL' } }
    }
    if ($hasCompliance) { $blocks += $compBlocks }
    if ($hasCoverage) {
        $covItemsArr = @($ChangesBySeverity.Coverage)
        $covLines    = @($covItemsArr | Sort-Object { $_['context'] } | Select-Object -First 10 | ForEach-Object { "• $($_['context'])" })
        $covText     = "*Coverage ($($covItemsArr.Count))*`n_Roles not in any access model definition — add to AccessModel/*.json or AccessModel/coverage-exclusions.json._`n" + ($covLines -join "`n")
        $blocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $covText } }
        if ($covItemsArr.Count -gt 10) {
            $more = & $moreLink ($covItemsArr.Count - 10)
            if ($more) { $blocks += $more }
        }
    }

    # ---------------- Actions (View Diff + Open HTML Report) ----------------
    $buttons = @()
    if ($diffUrl)   { $buttons += @{ type = 'button'; text = @{ type = 'plain_text'; text = 'View Diff' };         url = $diffUrl; style = 'primary' } }
    if ($reportUrl) { $buttons += @{ type = 'button'; text = @{ type = 'plain_text'; text = 'Open HTML Report' };  url = $reportUrl } }
    if ($buttons.Count -gt 0) {
        $blocks += @{ type = 'actions'; elements = $buttons }
    }

    # Defensive block-budget enforcement (Slack hard limit = 50). If we somehow exceeded,
    # trim middle blocks and append a notice so the message still posts.
    if ($blocks.Count -gt 50) {
        $kept     = $blocks[0..47]
        $kept    += @{ type = 'context'; elements = @(@{ type = 'mrkdwn'; text = '_Message truncated to fit Slack 50-block limit._' }) }
        $kept    += $blocks[-1]
        $blocks   = $kept
    }

    # `text` field is the push-notification preview Slack uses when blocks cannot render.
    $previewText = $execLine
    return @{ text = $previewText; blocks = $blocks }
}
function Build-ScanErrorSlackPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $ScanErrors)

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'

    $blocks = @(
        @{
            type = 'header'
            text = @{ type = 'plain_text'; text = '[PIM Monitor] Scan completed with errors' }
        }
        @{
            type = 'section'
            text = @{
                type = 'mrkdwn'
                text = ":warning: *$($ScanErrors.Count) component(s) failed.* Partial scan data may be incomplete.`n_$timestamp_"
            }
        }
        @{ type = 'divider' }
    )

    foreach ($err in $ScanErrors) {
        $truncatedError = if ($err.Error.Length -gt 200) {
            $err.Error.Substring(0, 200) + '...'
        } else {
            $err.Error
        }

        $blocks += @{
            type = 'section'
            text = @{
                type = 'mrkdwn'
                text = "*$($err.Component)*`n``$truncatedError``"
            }
        }
    }

    return @{ blocks = $blocks }
}
