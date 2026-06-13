<#
.SYNOPSIS
    Microsoft Teams payload builders for PIM Monitor.

.DESCRIPTION
    Build-TeamsPayload (change notifications, Adaptive Card 1.6) and
    Build-ScanErrorTeamsPayload (scan-error card). Dispatched from
    notifications-webhook.ps1 based on URL detection (legacy O365 connector
    or Power Automate workflow). Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Builds a Teams Adaptive Card payload.

.PARAMETER CommitSha
    Optional commit SHA for linking to the inventory diff.
#>
function Build-TeamsPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [string]   $MinSeverity = 'Medium',
        [string]   $CommitSha,
        [string]   $TenantName,
        [string[]] $MentionUpns = @()
    )

    $complianceTypes = $script:ComplianceFileTypes

    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $cov = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
    $tot = $hi + $med + $lo + $inf + $cov

    # Build the at-mention prefix once; only fires when High changes are present.
    $mentionPrefix = ''
    $mentionEntities = @()
    if ($MentionUpns.Count -gt 0 -and $hi -gt 0) {
        $mentionPrefix = (($MentionUpns | ForEach-Object { "<at>$_</at>" }) -join ' ') + ' '
        $mentionEntities = @($MentionUpns | ForEach-Object {
            @{ type = 'mention'; text = "<at>$_</at>"; mentioned = @{ id = $_; name = $_ } }
        })
    }

    # Shared executive-summary helper (consistent wording across email, Teams, Slack).
    $execLine = Get-ExecutiveSummaryLine -ChangesBySeverity $ChangesBySeverity -TenantName $TenantName

    $body = @(
        @{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; text = 'PIM Monitor — change detected'; wrap = $true }
    )
    if ($TenantName) {
        $body += @{ type = 'TextBlock'; text = "Tenant: $TenantName"; isSubtle = $true; spacing = 'None'; size = 'Small' }
    }
    $body += @{ type = 'TextBlock'; text = "$mentionPrefix$execLine"; wrap = $true; spacing = 'Small' }
    $body += @{ type = 'FactSet'; facts = @(
        @{ title = 'High';          value = "$hi"  }
        @{ title = 'Medium';        value = "$med" }
        @{ title = 'Low';           value = "$lo"  }
        @{ title = 'Informational'; value = "$inf" }
    ) }

    # Teams Adaptive Card container styles: default, emphasis, good, attention, warning, accent.
    # 'informational' is not a valid style — fall back to 'default'.
    $containerStyle = @{ High = 'attention'; Medium = 'warning'; Low = 'good'; Informational = 'default' }

    # Builds a 3-column header + per-row triplet (Property | left | right).
    # Text values are capped at 1000 chars to stay within Teams AdaptiveCard field limits.
    $buildDiffColumnSet = {
        param([array]$rows, [string]$leftLabel, [string]$rightLabel)
        if ($null -eq $rows -or $rows.Count -eq 0) { return @() }
        $cap = { param($s) if ($s.Length -gt 1000) { $s.Substring(0, 997) + '...' } else { $s } }
        $blocks = @(
            @{ type = 'ColumnSet'; spacing = 'Small'; columns = @(
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = 'Property';   weight = 'Bolder'; size = 'Small'; isSubtle = $true }) }
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = $leftLabel;  weight = 'Bolder'; size = 'Small'; isSubtle = $true; color = 'Attention' }) }
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = $rightLabel; weight = 'Bolder'; size = 'Small'; isSubtle = $true; color = 'Good' }) }
            )}
        )
        foreach ($r in $rows) {
            $blocks += @{ type = 'ColumnSet'; spacing = 'None'; columns = @(
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = (& $cap "$($r.Key)");    wrap = $true; fontType = 'Monospace'; size = 'Small' }) }
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = (& $cap "$($r.Actual)"); wrap = $true; fontType = 'Monospace'; size = 'Small'; color = 'Attention' }) }
                @{ width = 'stretch'; items = @(@{ type = 'TextBlock'; text = (& $cap "$($r.New)");    wrap = $true; fontType = 'Monospace'; size = 'Small'; color = 'Good' }) }
            )}
        }
        return $blocks
    }

    # Renders a single severity section (Changes pass) or compliance severity section.
    $renderSeveritySection = {
        param($items, [string]$severity, [string]$leftLabel, [string]$rightLabel)
        $sevItems = @(
            @{ type = 'TextBlock'; weight = 'Bolder'; text = "$severity ($($items.Count))"; spacing = 'Medium' }
        )
        foreach ($change in ($items | Select-Object -First 15)) {
            $changeBlock = @{ type = 'TextBlock'; text = "• $($change['description'])"; wrap = $true; spacing = 'Small' }
            if ($change['roleId']) {
                $changeBlock['selectAction'] = @{ type = 'Action.OpenUrl'; url = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/RoleDetailsMenuBlade/~/Description/roleDefinitionId/$($change['roleId'])" }
            } elseif ($change['groupId']) {
                $changeBlock['selectAction'] = @{ type = 'Action.OpenUrl'; url = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$($change['groupId'])" }
            }
            $sevItems += $changeBlock

            $rows = @(Get-ChangeDiffRows -Change $change)
            if ($rows.Count -gt 0) {
                $sevItems += & $buildDiffColumnSet $rows $leftLabel $rightLabel
            }
        }
        if ($items.Count -gt 15) {
            $sevItems += @{ type = 'TextBlock'; text = "... and $($items.Count - 15) more"; isSubtle = $true; spacing = 'Small' }
        }
        return @{ type = 'Container'; items = $sevItems; spacing = 'Medium'; style = $containerStyle[$severity] }
    }

    # Pass 1 — Git changes (was / changed to)
    $hasGit = $false
    $gitContainers = @()
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $gitItems = @($ChangesBySeverity.$severity | Where-Object { -not $complianceTypes.Contains($_['fileType']) })
        if ($gitItems.Count -eq 0) { continue }
        $hasGit = $true
        $gitContainers += & $renderSeveritySection $gitItems $severity 'was' 'changed to'
    }
    if ($hasGit) {
        $body += @{ type = 'TextBlock'; text = 'CHANGES'; weight = 'Bolder'; size = 'Medium'; spacing = 'Large'; separator = $true }
        $body += $gitContainers
    }

    # Pass 2 + 3 — Access Model (Compliance + Coverage)
    $compContainers = @()
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $compItems = @($ChangesBySeverity.$severity | Where-Object { $complianceTypes.Contains($_['fileType']) })
        if ($compItems.Count -eq 0) { continue }
        $compContainers += & $renderSeveritySection $compItems $severity 'actual' 'expected'
    }
    $hasCompliance = $compContainers.Count -gt 0
    $hasCoverage   = $cov -gt 0
    if ($hasCompliance -or $hasCoverage) {
        $body += @{ type = 'TextBlock'; text = 'ACCESS MODEL'; weight = 'Bolder'; size = 'Medium'; spacing = 'Large'; separator = $true }
    }
    if ($hasCompliance) {
        $body += @{ type = 'TextBlock'; text = 'Compliance'; weight = 'Bolder'; size = 'Small'; isSubtle = $true; spacing = 'Small' }
        $body += $compContainers
    }
    if ($hasCoverage) {
        $covItems  = @($ChangesBySeverity.Coverage)
        $covHeader = @{ type = 'TextBlock'; weight = 'Bolder'; text = "Coverage ($($covItems.Count))"; spacing = 'Medium' }
        $covNote   = @{ type = 'TextBlock'; text = 'Roles not in any access model definition. Add to AccessModel/*.json or AccessModel/coverage-exclusions.json to suppress.'; wrap = $true; isSubtle = $true; size = 'Small'; spacing = 'None' }
        $covBlock  = @{ type = 'Container'; style = 'accent'; spacing = 'Medium'; items = @($covHeader, $covNote) }
        foreach ($change in ($covItems | Sort-Object { $_['context'] } | Select-Object -First 15)) {
            $covBlock.items += @{ type = 'TextBlock'; text = "• $($change['context'])"; wrap = $true; spacing = 'Small' }
        }
        if ($covItems.Count -gt 15) {
            $covBlock.items += @{ type = 'TextBlock'; text = "... and $($covItems.Count - 15) more"; isSubtle = $true; spacing = 'Small' }
        }
        $body += $covBlock
    }

    $actions = @()
    if ($CommitSha) {
        $diffUrl = Get-CommitDiffUrl -CommitSha $CommitSha
        if ($diffUrl) {
            $actions += @{ type = 'Action.OpenUrl'; title = 'View Diff'; url = $diffUrl }
        }
    }

    $card = @{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.6'
        body      = $body
    }
    if ($actions.Count -gt 0) { $card['actions'] = $actions }
    if ($mentionEntities.Count -gt 0) {
        $card['msteams'] = @{ entities = $mentionEntities }
    }

    return @{
        type = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                content     = $card
            }
        )
    }
}

function Build-ScanErrorTeamsPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $ScanErrors)

    $title = '[PIM Monitor] Scan completed with errors'
    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'

    $body = @(
        @{
            type   = 'TextBlock'
            size   = 'Large'
            weight = 'Bolder'
            text   = $title
            color  = 'Attention'
        }
        @{
            type    = 'TextBlock'
            text    = "$($ScanErrors.Count) component(s) failed. Partial scan data may be incomplete."
            wrap    = $true
            isSubtle = $true
        }
        @{
            type = 'TextBlock'
            text = $timestamp
            size = 'Small'
            isSubtle = $true
        }
    )

    foreach ($err in $ScanErrors) {
        $truncatedError = if ($err.Error.Length -gt 200) {
            $err.Error.Substring(0, 200) + '...'
        } else {
            $err.Error
        }

        $body += @{
            type    = 'Container'
            style   = 'attention'
            spacing = 'Medium'
            items   = @(
                @{ type = 'TextBlock'; weight = 'Bolder'; text = $err.Component }
                @{ type = 'TextBlock'; text = $truncatedError; wrap = $true; isSubtle = $true; fontType = 'Monospace'; size = 'Small'; spacing = 'None' }
            )
        }
    }

    $card = @{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.5'
        body      = $body
    }

    return @{
        type = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                content     = $card
            }
        )
    }
}
