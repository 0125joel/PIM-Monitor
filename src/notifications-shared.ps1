<#
.SYNOPSIS
    Shared notification formatting helpers for PIM Monitor.

.DESCRIPTION
    Centralized severity ranking and change formatting functions used by all notification channels
    (email, webhook, HTML reports). Dot-source before other notification modules.

    Requires: $script:DiffIgnoreProperties (HashSet[string]) from diff.ps1 — must be dot-sourced first.
#>

Add-Type -AssemblyName System.Web

$script:SeverityRank = @{ High = 3; Medium = 2; Low = 1; Informational = 0 }

<#
.SYNOPSIS
    Constructs the commit diff URL based on detected CI platform.

.DESCRIPTION
    Detects Azure DevOps or GitHub from environment variables and builds
    the appropriate URL to view the diff of the scan commit.

.PARAMETER CommitSha
    The commit SHA to link to.

.EXAMPLE
    $url = Get-CommitDiffUrl -CommitSha "a1b2c3d4"
    # Returns ADO URL if BUILD_REPOSITORY_URI is set, GitHub URL otherwise
#>
function Get-CommitDiffUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommitSha
    )

    if ($env:BUILD_REPOSITORY_URI) {
        # Strip any username@ prefix ADO injects (e.g. https://user@dev.azure.com/...)
        $baseUri = $env:BUILD_REPOSITORY_URI -replace 'https://[^@]+@', 'https://'
        return "$baseUri/commit/${CommitSha}?refName=refs%2Fheads%2Fmain"
    }
    elseif ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
        # GitHub: GITHUB_SERVER_URL=https://github.com, GITHUB_REPOSITORY=owner/repo
        return "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/commit/$CommitSha"
    }
    else {
        return $null
    }
}

<#
.SYNOPSIS
    Filters changes to those meeting the minimum severity threshold.
#>
function Select-ChangesForNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array] $Changes,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium'
    )

    $threshold = $script:SeverityRank[$MinSeverity]
    return @($Changes | Where-Object { $script:SeverityRank[$_.severity] -ge $threshold })
}

<#
.SYNOPSIS
    Builds a plain-text notification summary.

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER MinSeverity
    Lowest severity to include in detail lines (default Medium).
#>
function Format-ChangeSummaryText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium'
    )

    $lines = @()
    $lines += "PIM Monitor — change report"
    $lines += ""

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if (-not $ChangesBySeverity[$severity]) { continue }
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }

        $lines += "$($severity):"
        foreach ($item in $ChangesBySeverity[$severity]) {
            $lines += "  — $($item.description)"
        }
        $lines += ""
    }

    return $lines -join "`n"
}

<#
.SYNOPSIS
    Builds an HTML table of changes for inclusion in email or reports.

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER MinSeverity
    Lowest severity to include in the table (default Medium).

.PARAMETER CommitUrl
    Optional URL to link to the scan commit.
#>
function Format-ChangeSummaryHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitUrl,
        [hashtable] $AuthContextLookup = @{}
    )

    # Design system tokens
    $sevBorder     = @{ High = '#ef4444'; Medium = '#d97706'; Low = '#22c55e'; Informational = '#737373' }
    $sevBgLight    = @{ High = '#fef2f2'; Medium = '#fffbeb'; Low = '#f0fdf4'; Informational = '#f9fafb' }
    $sevLabelLight = @{ High = '#b91c1c'; Medium = '#92400e'; Low = '#166534'; Informational = '#374151' }

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $tot = $ChangesBySeverity.Total

    # Stat row: only colorize counts that are > 0; mute zeros
    $hiColor  = if ($hi  -gt 0) { '#b91c1c' } else { '#a3a3a3' }
    $medColor = if ($med -gt 0) { '#92400e' } else { '#a3a3a3' }
    $loColor  = if ($lo  -gt 0) { '#166534' } else { '#a3a3a3' }
    # Shared rendering helpers (hoisted — avoid re-creating per change item)
    $monoBase     = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;line-height:1.9;"
    $diffDivStyle = "padding:4px 14px 10px;border-top:1px solid #d4d4d4;"

    $diffIgnore = [System.Collections.Generic.HashSet[string]]::new(
        $script:DiffIgnoreProperties,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Format a field value for display. Resolves known auth context IDs (e.g. "c1") to
    # "Display Name (c1)" using the lookup built from the authentication-contexts inventory.
    $fmtVal = {
        param($v)
        if ($null -eq $v) { return '(none)' }
        if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
        if ($v -is [string]) {
            if ($AuthContextLookup.Count -gt 0 -and $AuthContextLookup.ContainsKey($v)) {
                return "$($AuthContextLookup[$v]) ($v)"
            }
            return $v
        }
        if ($v -is [System.Collections.IDictionary]) {
            if ($v.Contains('displayName')) { return [string]$v['displayName'] }
            return $v | ConvertTo-Json -Depth 2 -Compress
        }
        if ($v -is [System.Collections.IEnumerable]) {
            $arr = @($v)
            if ($arr.Count -eq 0) { return '(empty)' }
            return ($arr | ForEach-Object {
                if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 2 -Compress }
            }) -join ', '
        }
        return $v | ConvertTo-Json -Depth 3 -Compress
    }

    $renderPropertyBlock = {
        param([string]$key, $oldVal, $newVal, [string]$oldLabel = 'actual', [string]$newLabel = 'expected')

        $isComplexVal = { param($v) -not ($null -eq $v -or $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) }

        if ($oldVal -is [System.Collections.IDictionary] -and $newVal -is [System.Collections.IDictionary]) {
            $blocks = @()
            foreach ($sk in (@(@($oldVal.Keys) + @($newVal.Keys)) | Sort-Object -Unique)) {
                $sov = if ($oldVal.ContainsKey($sk)) { $oldVal[$sk] } else { $null }
                $snv = if ($newVal.ContainsKey($sk)) { $newVal[$sk] } else { $null }
                if ((ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
                if ((& $isComplexVal $sov) -or (& $isComplexVal $snv)) { continue }
                $flatKey = [System.Web.HttpUtility]::HtmlEncode("$key.$sk")
                $sove    = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $sov))
                $snve    = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $snv))
                $blocks += "<div style=`"$monoBase color:#737373;margin-top:8px`">Property: $flatKey</div>"
                $blocks += "<div style=`"$monoBase color:#dc2626`">${oldLabel}: $sove</div>"
                $blocks += "<div style=`"$monoBase color:#16a34a`">${newLabel}: $snve</div>"
            }
            if ($blocks.Count -gt 0) {
                $blocks -join ''
                return
            }
        }

        $ke  = [System.Web.HttpUtility]::HtmlEncode($key)
        $ove = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $oldVal))
        $nve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $newVal))
        "<div style=`"$monoBase color:#737373;margin-top:8px`">Property: $ke</div>" +
        "<div style=`"$monoBase color:#dc2626`">${oldLabel}: $ove</div>" +
        "<div style=`"$monoBase color:#16a34a`">${newLabel}: $nve</div>"
    }

    $isScalar = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }

    # Renders a single change entry as a collapsible <details> table row.
    # $oldLabel / $newLabel are passed explicitly so each rendering pass controls labels independently.
    $renderChangeItem = {
        param($change, $bc, $bg, [string]$oldLabel, [string]$newLabel)

        $desc        = [System.Web.HttpUtility]::HtmlEncode($change.description)
        $diffContent = ''

        if ($null -ne $change.old -and $null -ne $change.new) {
            if ((& $isScalar $change.old) -and (& $isScalar $change.new)) {
                $ove = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $change.old))
                $nve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $change.new))
                $html = "<div style=`"$monoBase color:#dc2626`">${oldLabel}: $ove</div>" +
                        "<div style=`"$monoBase color:#16a34a`">${newLabel}: $nve</div>"
                $diffContent = "<div style=`"$diffDivStyle`">$html</div>"
            } else {
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $lines = @()
                    foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                        $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                        if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                        $lines += & $renderPropertyBlock $k $ov $nv $oldLabel $newLabel
                    }
                    if ($lines.Count -gt 0) {
                        $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                    }
                } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
            }
        } elseif ($null -ne $change.new) {
            try {
                $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                $lines = @()
                foreach ($k in ($nh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $ke  = [System.Web.HttpUtility]::HtmlEncode($k)
                    $nve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $nh[$k]))
                    $lines += "<div style=`"$monoBase color:#16a34a`">${ke}: ${nve}</div>"
                }
                if ($lines.Count -gt 0) {
                    $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                }
            } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
        } elseif ($null -ne $change.old) {
            try {
                $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                $lines = @()
                foreach ($k in ($oh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $ke  = [System.Web.HttpUtility]::HtmlEncode($k)
                    $ove = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $oh[$k]))
                    $lines += "<div style=`"$monoBase color:#dc2626`">${ke}: ${ove}</div>"
                }
                if ($lines.Count -gt 0) {
                    $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                }
            } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
        }

        $detailsStyle = "border-left:3px solid $bc;background-color:$bg;border-radius:0 3px 3px 0;color:#1a1a1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;"
        $sumStyle     = "padding:10px 14px;cursor:pointer;display:block;list-style:none;line-height:1.5;color:#1a1a1a;"

        $changeType = $change['changeType']
        $addTypes   = @('added', 'created', 'rule_added', 'policy_added', 'new_property')
        $delTypes   = @('removed', 'deleted', 'rule_removed', 'policy_removed', 'removed_property')
        $sigilChar  = if ($addTypes -contains $changeType) { '+' } elseif ($delTypes -contains $changeType) { '&#8722;' } else { 'M' }
        $sigilColor = if ($addTypes -contains $changeType) { '#16a34a' } elseif ($delTypes -contains $changeType) { '#dc2626' } else { '#d97706' }
        $sigilStyle = "font-weight:700;display:inline-block;width:1em;text-align:center;color:$sigilColor;"

        $headerHtml = if ($change.context) {
            $ctx       = [System.Web.HttpUtility]::HtmlEncode($change.context)
            $shortDesc = [System.Web.HttpUtility]::HtmlEncode(($change.description -replace '\s*\([^)]*\)\s*$', ''))
            "<span style=`"display:block;font-size:14px;font-weight:600`">$ctx</span>" +
            "<span style=`"display:block;font-size:12px;color:#525252;margin-top:2px`"><span style=`"$sigilStyle`">$sigilChar</span> $shortDesc</span>"
        } else {
            "<span style=`"display:block;font-size:13px`"><span style=`"$sigilStyle`">$sigilChar</span> $desc</span>"
        }

        "<tr><td style=`"padding:2px 32px;`">" +
        "<details style=`"$detailsStyle`"><summary style=`"$sumStyle`">$headerHtml</summary>" +
        $diffContent +
        "</details></td></tr>"
    }

    $rows = @()
    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if (-not $bucket -or $bucket.Count -eq 0) { continue }

        $bc  = $sevBorder[$severity]
        $bg  = $sevBgLight[$severity]
        $lc  = $sevLabelLight[$severity]

        $labelStyle = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:$lc;"
        $rows += "<tr><td style=`"padding:24px 32px 8px;`"><div style=`"$labelStyle`">$severity ($($bucket.Count))</div></td></tr>"

        foreach ($change in @($bucket | Sort-Object { $_['changeType'] })) {
            $rows += & $renderChangeItem $change $bc $bg 'was' 'changed to'
        }
        $rows += '<tr><td style="padding:6px 0;"></td></tr>'
    }

    $sectionsHtml = $rows -join ''

    $commitHtml = ''
    if ($CommitUrl) {
        $safeUrl  = [System.Web.HttpUtility]::HtmlAttributeEncode($CommitUrl)
        $btnStyle = "display:inline-block;font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.12em;text-transform:uppercase;color:#d97706;text-decoration:none;border:1px solid #d97706;border-radius:3px;padding:6px 14px;"
        $commitHtml = "<tr><td style=`"padding:8px 32px 0;`"><a href=`"$safeUrl`" style=`"$btnStyle`">View diff</a></td></tr>"
    }

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
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:20px;font-weight:600;letter-spacing:-0.01em;color:#d97706;">pim/monitor</div>
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#a3a3a3;margin-top:4px;letter-spacing:0.12em;text-transform:uppercase;">change report</div>
</td></tr>
<tr><td style="padding:14px 32px;background-color:#fafafa;border-top:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;">
  <table cellpadding="0" cellspacing="0" border="0"><tr>
    <td style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Total <b style="color:#0a0a0a;">$tot</b></td>
    <td style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$hiColor;">High $hi</td>
    <td style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$medColor;">Medium $med</td>
    <td style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$loColor;">Low $lo</td>
    <td style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Info $inf</td>
  </tr></table>
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;margin-top:8px;letter-spacing:0.06em;">$timestamp</div>
</td></tr>
$sectionsHtml
$commitHtml
<tr><td style="padding:20px 32px 24px;border-top:1px solid #e5e5e5;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;letter-spacing:0.06em;">PIM Monitor · automated scan notification</div>
</td></tr>
</table>
</td></tr></table>
</body>
</html>
"@
}
