<#
.SYNOPSIS
    Webhook notification delivery for PIM Monitor changes and scan errors.

.DESCRIPTION
    Sends notifications via HTTP webhooks with platform-specific payloads.
    Supports Teams (Adaptive Cards), Slack (blocks), Discord (embeds), and custom JSON.
    Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Detects webhook type from URL.
#>
function Get-WebhookType {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Url)

    if ($Url -match 'webhook\.office\.com')      { return 'Teams' }
    if ($Url -match 'hooks\.slack\.com')         { return 'Slack' }
    if ($Url -match 'discord\.com/api/webhooks') { return 'Discord' }
    return 'Generic'
}

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
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha
    )

    $facts = @(
        @{ title = 'High';          value = "$($ChangesBySeverity.High.Count)"          }
        @{ title = 'Medium';        value = "$($ChangesBySeverity.Medium.Count)"        }
        @{ title = 'Low';           value = "$($ChangesBySeverity.Low.Count)"           }
        @{ title = 'Informational'; value = "$($ChangesBySeverity.Informational.Count)" }
    )

    $body = @(
        @{ type = 'TextBlock'; size = 'Large'; weight = 'Bolder'; text = 'PIM Monitor — change detected' }
        @{ type = 'FactSet';   facts = $facts }
    )

    # Teams Adaptive Card container styles: default, emphasis, good, attention, warning, accent
    # 'informational' is not a valid style — use 'default' as fallback
    $containerStyle = @{ High = 'attention'; Medium = 'warning'; Low = 'good'; Informational = 'default' }

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if ($bucket.Count -eq 0) { continue }

        # Use container with spacing for severity section
        $severityItems = @(
            @{ type = 'TextBlock'; weight = 'Bolder'; text = "$severity ($($bucket.Count))"; spacing = 'Medium' }
        )

        $fmtValWh = {
            param($v)
            if ($null -eq $v) { return '(none)' }
            if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
            if ($v -is [string]) { return $v }
            if ($v -is [System.Collections.IDictionary]) {
                if ($v.Contains('displayName')) { return [string]$v['displayName'] }
                return $v | ConvertTo-Json -Depth 2 -Compress
            }
            if ($v -is [System.Collections.IEnumerable]) {
                $arr = @($v); if ($arr.Count -eq 0) { return '(empty)' }
                return ($arr | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 2 -Compress } }) -join ', '
            }
            return $v | ConvertTo-Json -Depth 3 -Compress
        }
        $diffIgnoreWh = [System.Collections.Generic.HashSet[string]]::new($script:DiffIgnoreProperties, [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($change in ($bucket | Select-Object -First 15)) {
            $changeText = "• $($change.description)"
            $item = @{ type = 'TextBlock'; text = $changeText; wrap = $true; spacing = 'Small' }

            # Add portal link if change contains an entity ID we can link
            if ($change['roleId']) {
                $roleId = $change['roleId']
                $entraLink = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/RoleDetailsMenuBlade/~/Description/roleDefinitionId/$roleId"
                $item['selectAction'] = @{
                    type = 'Action.OpenUrl'
                    url  = $entraLink
                }
            }
            elseif ($change['groupId']) {
                $groupId = $change['groupId']
                $entraLink = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$groupId"
                $item['selectAction'] = @{
                    type = 'Action.OpenUrl'
                    url  = $entraLink
                }
            }

            $severityItems += $item

            $diffLines = @()
            $isScalarWh = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }
            if ($null -ne $change.old -and $null -ne $change.new) {
                if ((& $isScalarWh $change.old) -and (& $isScalarWh $change.new)) {
                    $diffLines += "value: $(& $fmtValWh $change.old) → $(& $fmtValWh $change.new)"
                } else {
                    try {
                        $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $shown = 0
                        foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                            if ($shown -ge 5) { break }
                            if ($diffIgnoreWh.Contains($k)) { continue }
                            $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                            $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                            if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                            if ($ov -is [System.Collections.IDictionary] -and $nv -is [System.Collections.IDictionary]) {
                                $subShown = 0
                                foreach ($sk in (@(@($ov.Keys) + @($nv.Keys)) | Sort-Object -Unique)) {
                                    if ($subShown -ge 8) { break }
                                    $sov = if ($ov.ContainsKey($sk)) { $ov[$sk] } else { $null }
                                    $snv = if ($nv.ContainsKey($sk)) { $nv[$sk] } else { $null }
                                    if ((ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
                                    if (-not ((& $isScalarWh $sov) -and (& $isScalarWh $snv))) { continue }
                                    $diffLines += "Property: ${k}.${sk}: $(& $fmtValWh $sov) → $(& $fmtValWh $snv)"
                                    $subShown++
                                }
                            } else {
                                $diffLines += "Property: ${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)"
                            }
                            $shown++
                        }
                    } catch {}
                }
            } elseif ($null -ne $change.new) {
                try {
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($nh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "+ ${k}: $(& $fmtValWh $nh[$k])"
                        $shown++
                    }
                } catch {}
            } elseif ($null -ne $change.old) {
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($oh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "- ${k}: $(& $fmtValWh $oh[$k])"
                        $shown++
                    }
                } catch {}
            }
            if ($diffLines.Count -gt 0) {
                $severityItems += @{ type = 'TextBlock'; text = $diffLines -join "`n"; wrap = $true; spacing = 'None'; isSubtle = $true; fontType = 'Monospace'; size = 'Small' }
            }
        }

        if ($bucket.Count -gt 15) {
            $severityItems += @{ type = 'TextBlock'; text = "... and $($bucket.Count - 15) more"; isSubtle = $true; spacing = 'Small' }
        }

        $body += @{ type = 'Container'; items = $severityItems; spacing = 'Medium'; style = $containerStyle[$severity] }
    }

    # Access model coverage section
    $covItems = if ($ChangesBySeverity['Coverage']) { @($ChangesBySeverity.Coverage) } else { @() }
    if ($covItems.Count -gt 0) {
        $covHeader = @{ type = 'TextBlock'; weight = 'Bolder'; text = "Access Model Coverage ($($covItems.Count))"; spacing = 'Medium' }
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
            $actions += @{
                type  = 'Action.OpenUrl'
                title = 'View Diff'
                url   = $diffUrl
            }
        }
    }

    $card = @{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.5'
        body      = $body
    }

    if ($actions.Count -gt 0) {
        $card['actions'] = $actions
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
        [string] $CommitSha
    )

    $blocks = @(
        @{ type = 'header'; text = @{ type = 'plain_text'; text = 'PIM Monitor — change detected' } }
        @{ type = 'section'; fields = @(
            @{ type = 'mrkdwn'; text = "*High:* $($ChangesBySeverity.High.Count)" }
            @{ type = 'mrkdwn'; text = "*Medium:* $($ChangesBySeverity.Medium.Count)" }
            @{ type = 'mrkdwn'; text = "*Low:* $($ChangesBySeverity.Low.Count)" }
            @{ type = 'mrkdwn'; text = "*Informational:* $($ChangesBySeverity.Informational.Count)" }
        )}
    )

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if ($bucket.Count -eq 0) { continue }

        $fmtValWh = {
            param($v)
            if ($null -eq $v) { return '(none)' }
            if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
            if ($v -is [string]) { return $v }
            if ($v -is [System.Collections.IDictionary]) {
                if ($v.Contains('displayName')) { return [string]$v['displayName'] }
                return $v | ConvertTo-Json -Depth 2 -Compress
            }
            if ($v -is [System.Collections.IEnumerable]) {
                $arr = @($v); if ($arr.Count -eq 0) { return '(empty)' }
                return ($arr | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 2 -Compress } }) -join ', '
            }
            return $v | ConvertTo-Json -Depth 3 -Compress
        }
        $diffIgnoreWh = [System.Collections.Generic.HashSet[string]]::new($script:DiffIgnoreProperties, [System.StringComparer]::OrdinalIgnoreCase)

        $text = "*$severity ($($bucket.Count))*`n"
        foreach ($change in ($bucket | Select-Object -First 20)) {
            $text += "• $($change.description)`n"
            $diffLines = @()
            $isScalarWh = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }
            if ($null -ne $change.old -and $null -ne $change.new) {
                if ((& $isScalarWh $change.old) -and (& $isScalarWh $change.new)) {
                    $diffLines += "  ``value: $(& $fmtValWh $change.old) → $(& $fmtValWh $change.new)``"
                } else {
                    try {
                        $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $shown = 0
                        foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                            if ($shown -ge 5) { break }
                            if ($diffIgnoreWh.Contains($k)) { continue }
                            $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                            $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                            if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                            if ($ov -is [System.Collections.IDictionary] -and $nv -is [System.Collections.IDictionary]) {
                                $subShown = 0
                                foreach ($sk in (@(@($ov.Keys) + @($nv.Keys)) | Sort-Object -Unique)) {
                                    if ($subShown -ge 8) { break }
                                    $sov = if ($ov.ContainsKey($sk)) { $ov[$sk] } else { $null }
                                    $snv = if ($nv.ContainsKey($sk)) { $nv[$sk] } else { $null }
                                    if ((ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
                                    if (-not ((& $isScalarWh $sov) -and (& $isScalarWh $snv))) { continue }
                                    $diffLines += "  ``Property: ${k}.${sk}: $(& $fmtValWh $sov) → $(& $fmtValWh $snv)``"
                                    $subShown++
                                }
                            } else {
                                $diffLines += "  ``Property: ${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)``"
                            }
                            $shown++
                        }
                    } catch {}
                }
            } elseif ($null -ne $change.new) {
                try {
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($nh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "  ``+ ${k}: $(& $fmtValWh $nh[$k])``"
                        $shown++
                    }
                } catch {}
            } elseif ($null -ne $change.old) {
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($oh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "  ``- ${k}: $(& $fmtValWh $oh[$k])``"
                        $shown++
                    }
                } catch {}
            }
            if ($diffLines.Count -gt 0) { $text += ($diffLines -join "`n") + "`n" }
        }
        if ($bucket.Count -gt 20) { $text += "_... and $($bucket.Count - 20) more_" }

        $blocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $text } }
    }

    $covItems = if ($ChangesBySeverity['Coverage']) { @($ChangesBySeverity.Coverage) } else { @() }
    if ($covItems.Count -gt 0) {
        $covText = "*Access Model Coverage ($($covItems.Count))*`n_Roles not in any access model definition — add to AccessModel/*.json or AccessModel/coverage-exclusions.json:_`n"
        foreach ($change in ($covItems | Sort-Object { $_['context'] } | Select-Object -First 20)) {
            $covText += "• $($change['context'])`n"
        }
        if ($covItems.Count -gt 20) { $covText += "_... and $($covItems.Count - 20) more_" }
        $blocks += @{ type = 'section'; text = @{ type = 'mrkdwn'; text = $covText } }
    }

    if ($CommitSha) {
        $diffUrl = Get-CommitDiffUrl -CommitSha $CommitSha
        if ($diffUrl) {
            $blocks += @{
                type = 'section'
                text = @{
                    type = 'mrkdwn'
                    text = "<$diffUrl|View Diff>"
                }
            }
        }
    }

    return @{ blocks = $blocks }
}

<#
.SYNOPSIS
    Builds a Discord embed payload.

.PARAMETER CommitSha
    Optional commit SHA for linking to the inventory diff.
#>
function Build-DiscordPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha
    )

    # Color by highest severity present
    $color = 5763719  # green = Low/none
    if ($ChangesBySeverity.Medium.Count -gt 0) { $color = 15844367 }  # orange
    if ($ChangesBySeverity.High.Count -gt 0)   { $color = 15548997 }  # red

    $fields = @()
    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if ($bucket.Count -eq 0) { continue }

        $fmtValWh = {
            param($v)
            if ($null -eq $v) { return '(none)' }
            if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
            if ($v -is [string]) { return $v }
            if ($v -is [System.Collections.IDictionary]) {
                if ($v.Contains('displayName')) { return [string]$v['displayName'] }
                return $v | ConvertTo-Json -Depth 2 -Compress
            }
            if ($v -is [System.Collections.IEnumerable]) {
                $arr = @($v); if ($arr.Count -eq 0) { return '(empty)' }
                return ($arr | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 2 -Compress } }) -join ', '
            }
            return $v | ConvertTo-Json -Depth 3 -Compress
        }
        $diffIgnoreWh = [System.Collections.Generic.HashSet[string]]::new($script:DiffIgnoreProperties, [System.StringComparer]::OrdinalIgnoreCase)

        $value = ""
        foreach ($change in ($bucket | Select-Object -First 10)) {
            $value += "• $($change.description)`n"
            $diffLines = @()
            $isScalarWh = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }
            if ($null -ne $change.old -and $null -ne $change.new) {
                if ((& $isScalarWh $change.old) -and (& $isScalarWh $change.new)) {
                    $diffLines += "  value: $(& $fmtValWh $change.old) → $(& $fmtValWh $change.new)"
                } else {
                    try {
                        $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $shown = 0
                        foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                            if ($shown -ge 5) { break }
                            if ($diffIgnoreWh.Contains($k)) { continue }
                            $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                            $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                            if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                            if ($ov -is [System.Collections.IDictionary] -and $nv -is [System.Collections.IDictionary]) {
                                $subShown = 0
                                foreach ($sk in (@(@($ov.Keys) + @($nv.Keys)) | Sort-Object -Unique)) {
                                    if ($subShown -ge 8) { break }
                                    $sov = if ($ov.ContainsKey($sk)) { $ov[$sk] } else { $null }
                                    $snv = if ($nv.ContainsKey($sk)) { $nv[$sk] } else { $null }
                                    if ((ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
                                    if (-not ((& $isScalarWh $sov) -and (& $isScalarWh $snv))) { continue }
                                    $diffLines += "  Property: ${k}.${sk}: $(& $fmtValWh $sov) → $(& $fmtValWh $snv)"
                                    $subShown++
                                }
                            } else {
                                $diffLines += "  Property: ${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)"
                            }
                            $shown++
                        }
                    } catch {}
                }
            } elseif ($null -ne $change.new) {
                try {
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($nh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "  + ${k}: $(& $fmtValWh $nh[$k])"
                        $shown++
                    }
                } catch {}
            } elseif ($null -ne $change.old) {
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $shown = 0
                    foreach ($k in ($oh.Keys | Sort-Object)) {
                        if ($shown -ge 5) { break }
                        if ($diffIgnoreWh.Contains($k)) { continue }
                        $diffLines += "  - ${k}: $(& $fmtValWh $oh[$k])"
                        $shown++
                    }
                } catch {}
            }
            if ($diffLines.Count -gt 0) { $value += ($diffLines -join "`n") + "`n" }
        }
        if ($bucket.Count -gt 10) { $value += "_... +$($bucket.Count - 10) more_" }
        # Discord caps field value at 1024 chars
        if ($value.Length -gt 1020) { $value = $value.Substring(0, 1020) + '...' }

        $fields += @{ name = "$severity ($($bucket.Count))"; value = $value; inline = $false }
    }

    $covItems = if ($ChangesBySeverity['Coverage']) { @($ChangesBySeverity.Coverage) } else { @() }
    if ($covItems.Count -gt 0) {
        $covValue = "Roles not in any access model definition:`n"
        foreach ($change in ($covItems | Sort-Object { $_['context'] } | Select-Object -First 10)) {
            $covValue += "• $($change['context'])`n"
        }
        if ($covItems.Count -gt 10) { $covValue += "_... +$($covItems.Count - 10) more_" }
        if ($covValue.Length -gt 1020) { $covValue = $covValue.Substring(0, 1020) + '...' }
        $fields += @{ name = "Access Model Coverage ($($covItems.Count))"; value = $covValue; inline = $false }
    }

    $embed = @{
        title       = 'PIM Monitor — change detected'
        description = "Total: $($ChangesBySeverity.Total) changes"
        color       = $color
        timestamp   = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
        fields      = $fields
    }

    if ($CommitSha) {
        $diffUrl = Get-CommitDiffUrl -CommitSha $CommitSha
        if ($diffUrl) {
            $embed['url'] = $diffUrl
        }
    }

    return @{
        embeds = @($embed)
    }
}

<#
.SYNOPSIS
    Sends a change summary to a webhook endpoint.

.DESCRIPTION
    Auto-detects payload shape from URL (Teams / Slack / Discord / generic).

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER WebhookUrl
    Full webhook URL.

.PARAMETER MinSeverity
    Skip if no changes meet this threshold (default Medium).

.PARAMETER CommitSha
    Optional commit SHA to include as a diff link in the payload.
#>
function Send-WebhookNotification {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $WebhookUrl,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha
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
        'Teams'   { Build-TeamsPayload   -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha }
        'Slack'   { Build-SlackPayload   -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha }
        'Discord' { Build-DiscordPayload -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitSha $CommitSha }
        default   { @{
                        text             = "PIM Monitor — $relevantCount change(s) detected"
                        summary          = Format-ChangeSummaryText -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity
                        changesBySeverity = @{
                            high          = $ChangesBySeverity.High.Count
                            medium        = $ChangesBySeverity.Medium.Count
                            low           = $ChangesBySeverity.Low.Count
                            informational = $ChangesBySeverity.Informational.Count
                            total         = $ChangesBySeverity.Total
                        }
                    } }
    }

    if (-not $PSCmdlet.ShouldProcess($WebhookUrl, 'Send webhook notification')) { return }

    try {
        # ConvertTo-Json here serializes the webhook payload body — not an inventory file.
        # Key ordering is intentionally left non-deterministic; Teams/Slack/Discord card
        # schemas depend on insertion order for array rendering.
        Invoke-RestMethod -Uri $WebhookUrl -Method Post `
            -ContentType 'application/json' `
            -Body ($payload | ConvertTo-Json -Depth 20) | Out-Null
        Write-Host "  Webhook sent ($type)"
    }
    catch {
        Write-Warning "  Webhook send failed: $_"
    }
}

# Scan Error Webhook Payloads

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
        color       = 15548997
        timestamp   = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
        fields      = $fields
    }

    return @{ embeds = @($embed) }
}
