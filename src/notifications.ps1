<#
.SYNOPSIS
    Notification delivery for PIM Monitor — email and webhooks.

.DESCRIPTION
    Composes a change summary and delivers it via:
      - Microsoft Graph sendMail (if NOTIFICATION_EMAIL + NOTIFICATION_MAIL_FROM set)
      - Webhook POST (if NOTIFICATION_WEBHOOK_URL set)

    Webhook payload shape is auto-detected from the URL:
      webhook.office.com     → Teams Adaptive Card
      hooks.slack.com        → Slack blocks
      discord.com/webhooks   → Discord embed
      otherwise              → generic JSON

    Skip delivery entirely when no changes or only Low-severity changes
    (configurable via NOTIFICATION_MIN_SEVERITY: High|Medium|Low|Informational, default Medium).

    Requires: $script:DiffIgnoreProperties (HashSet[string]) from diff.ps1 — must be dot-sourced first.
#>

# System.Web provides HtmlEncode/HtmlAttributeEncode used in HTML formatting functions.
Add-Type -AssemblyName System.Web

# ============================================================================
# Content Building
# ============================================================================

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
    $lines += "Generated: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')"
    $lines += ""
    $lines += "Total: $($ChangesBySeverity.Total) | High: $($ChangesBySeverity.High.Count) | Medium: $($ChangesBySeverity.Medium.Count) | Low: $($ChangesBySeverity.Low.Count) | Informational: $($ChangesBySeverity.Informational.Count)"
    $lines += ""

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if (-not $bucket -or $bucket.Count -eq 0) { continue }

        $lines += "$severity ($($bucket.Count))"
        $lines += ("-" * 40)
        foreach ($change in $bucket) {
            $lines += "  - $($change.description)"
        }
        $lines += ""
    }

    return $lines -join "`n"
}

<#
.SYNOPSIS
    Builds an HTML notification summary (for email).

.PARAMETER CommitUrl
    Optional direct URL to the commit diff, rendered as a "View diff" button.
#>
function Format-ChangeSummaryHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitUrl
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

    # Build severity sections as table rows
    $rows = @()
    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if (-not $bucket -or $bucket.Count -eq 0) { continue }

        $bc  = $sevBorder[$severity]
        $bg  = $sevBgLight[$severity]
        $lc  = $sevLabelLight[$severity]
        $cnt = $bucket.Count

        $labelStyle = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:$lc;"
        $rows += "<tr><td style=`"padding:24px 32px 8px;`"><div style=`"$labelStyle`">$severity ($cnt)</div></td></tr>"

        foreach ($change in @($bucket | Sort-Object { $_['changeType'] })) {
            $desc = [System.Web.HttpUtility]::HtmlEncode($change.description)

            # Build diff content
            $diffContent  = ''
            $monoBase     = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;line-height:1.9;"
            $diffDivStyle = "padding:4px 14px 10px;border-top:1px solid #d4d4d4;"

            # Fields to skip: API metadata + structural fields that never carry config signal
            $diffIgnore = [System.Collections.Generic.HashSet[string]]::new(
                $script:DiffIgnoreProperties,
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $diffIgnore.Add('target') | Out-Null

            # Format a field value for display: arrays as comma-joined, booleans/strings as-is
            $fmtVal = {
                param($v)
                if ($null -eq $v) { return '(none)' }
                if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
                if ($v -is [string]) { return $v }
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

            # Render two lines per field: old in red, new in green
            $renderFieldDiff = {
                param([string]$key, $oldVal, $newVal)
                $ke  = [System.Web.HttpUtility]::HtmlEncode($key)
                $ove = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $oldVal))
                $nve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $newVal))
                "<div style=`"$monoBase color:#dc2626`">${ke}: ${ove}</div>" +
                "<div style=`"$monoBase color:#16a34a`">${ke}: ${nve}</div>"
            }

            if ($null -ne $change.old -and $null -ne $change.new) {
                $isScalar = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }
                if ((& $isScalar $change.old) -and (& $isScalar $change.new)) {
                    # Top-level scalar change (e.g. a definition property)
                    $html = & $renderFieldDiff 'value' $change.old $change.new
                    $diffContent = "<div style=`"$diffDivStyle`">$html</div>"
                } else {
                    # Object change: compare field-by-field, skip noise fields
                    try {
                        $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $lines = @()
                        foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                            if ($diffIgnore.Contains($k)) { continue }
                            $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                            $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                            # -InputObject prevents PowerShell from unrolling arrays through the pipeline
                            $oj = ConvertTo-DeterministicJson -InputObject $ov
                            $nj = ConvertTo-DeterministicJson -InputObject $nv
                            if ($oj -eq $nj) { continue }
                            $lines += & $renderFieldDiff $k $ov $nv
                        }
                        if ($lines.Count -gt 0) {
                            $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                        }
                    } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
                }
            } elseif ($null -ne $change.new) {
                # Rule/entity added: show non-ignored fields as green lines
                try {
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $lines = @()
                    foreach ($k in ($nh.Keys | Sort-Object)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $nv  = $nh[$k]
                        $ke  = [System.Web.HttpUtility]::HtmlEncode($k)
                        $nve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $nv))
                        $lines += "<div style=`"$monoBase color:#16a34a`">${ke}: ${nve}</div>"
                    }
                    if ($lines.Count -gt 0) {
                        $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                    }
                } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
            } elseif ($null -ne $change.old) {
                # Rule/entity removed: show non-ignored fields as red lines
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $lines = @()
                    foreach ($k in ($oh.Keys | Sort-Object)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $ov  = $oh[$k]
                        $ke  = [System.Web.HttpUtility]::HtmlEncode($k)
                        $ove = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $ov))
                        $lines += "<div style=`"$monoBase color:#dc2626`">${ke}: ${ove}</div>"
                    }
                    if ($lines.Count -gt 0) {
                        $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                    }
                } catch { Write-Warning "HTML diff rendering failed for '$($change.description)': $_" }
            }

            $detailsStyle = "border-left:3px solid $bc;background-color:$bg;border-radius:0 3px 3px 0;color:#1a1a1a;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;"
            $sumStyle     = "padding:10px 14px;cursor:pointer;display:block;list-style:none;line-height:1.5;color:#1a1a1a;"

            $changeType = $change.PSObject.Properties['changeType']?.Value
            $addTypes   = @('added', 'rule_added', 'policy_added', 'new_property')
            $delTypes   = @('removed', 'rule_removed', 'policy_removed', 'removed_property')
            $sigilChar  = if ($addTypes -contains $changeType) { '+' } elseif ($delTypes -contains $changeType) { '&#8722;' } else { 'M' }
            $sigilColor = if ($addTypes -contains $changeType) { '#16a34a' } elseif ($delTypes -contains $changeType) { '#dc2626' } else { '#d97706' }
            $sigilStyle = "font-weight:700;display:inline-block;width:1em;text-align:center;color:$sigilColor;"

            # Two-line header when context is available: role name + what changed
            $headerHtml = if ($change.context) {
                $ctx       = [System.Web.HttpUtility]::HtmlEncode($change.context)
                $shortDesc = [System.Web.HttpUtility]::HtmlEncode(($change.description -replace '\s*\([^)]*\)\s*$', ''))
                "<span style=`"display:block;font-size:14px;font-weight:600`">$ctx</span>" +
                "<span style=`"display:block;font-size:12px;color:#525252;margin-top:2px`"><span style=`"$sigilStyle`">$sigilChar</span> $shortDesc</span>"
            } else {
                "<span style=`"display:block;font-size:13px`"><span style=`"$sigilStyle`">$sigilChar</span> $desc</span>"
            }

            $rows += "<tr><td style=`"padding:2px 32px;`">" +
                "<details style=`"$detailsStyle`">" +
                "<summary style=`"$sumStyle`">$headerHtml</summary>" +
                $diffContent +
                "</details></td></tr>"
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
    <td style="padding-right:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Total <b style="color:#0a0a0a;">$tot</b></td>
    <td style="padding-right:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$hiColor;">High $hi</td>
    <td style="padding-right:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$medColor;">Medium $med</td>
    <td style="padding-right:20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$loColor;">Low $lo</td>
    <td style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Info $inf</td>
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

<#
.SYNOPSIS
    Builds a standalone HTML scan report artifact (browser-optimized, not email).

.DESCRIPTION
    Generates a self-contained HTML file with dark mode support, a severity bar,
    inline diff per change, Entra portal links, and a collapsible metadata section.
    Uses CSS custom properties and prefers-color-scheme — not email-safe by design.

.PARAMETER CommitUrl
    Optional URL to the commit diff, rendered as a "View diff" button and commit link.

.PARAMETER TenantId
    Optional tenant GUID displayed in the report header and metadata.

.PARAMETER CommitSha
    Optional commit SHA displayed in metadata, linked to CommitUrl if provided.
#>
function Format-ScanReportHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Low',
        [string] $TenantId,
        [string] $TenantName,
        [string] $CommitSha,
        [string] $CommitUrl
    )

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $tot = $ChangesBySeverity.Total

    # Severity bar: proportional segments using flex, only rendered severities shown
    $barSegs = @()
    if ($hi  -gt 0) { $barSegs += "<div class=`"sbs`" style=`"flex:$hi 1 0;background:#ef4444`"></div>" }
    if ($med -gt 0) { $barSegs += "<div class=`"sbs`" style=`"flex:$med 1 0;background:#d97706`"></div>" }
    if ($lo  -gt 0) { $barSegs += "<div class=`"sbs`" style=`"flex:$lo 1 0;background:#22c55e`"></div>" }
    if ($inf -gt 0) { $barSegs += "<div class=`"sbs`" style=`"flex:$inf 1 0;background:#737373`"></div>" }
    $barHtml = if ($barSegs.Count -gt 0) { "<div class=`"sev-bar`">$($barSegs -join '')</div>" } else { '' }

    # Shared helpers for diff rendering
    $fmtVal = {
        param($v)
        if ($null -eq $v) { return '(none)' }
        if ($v -is [bool])   { return $(if ($v) { 'true' } else { 'false' }) }
        if ($v -is [string]) { return $v }
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

    $renderLine = {
        param([string]$cls, [string]$key, $val)
        $ke = [System.Web.HttpUtility]::HtmlEncode($key)
        $ve = [System.Web.HttpUtility]::HtmlEncode((& $fmtVal $val))
        "<div class=`"diff-line $cls`">${ke}: ${ve}</div>"
    }

    $diffIgnore = [System.Collections.Generic.HashSet[string]]::new(
        $script:DiffIgnoreProperties,
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $diffIgnore.Add('target') | Out-Null

    # Build change sections
    $sevClass = @{ High = 'high'; Medium = 'med'; Low = 'low'; Informational = 'inf' }
    $chipMap  = @{
        High          = '<span class="sev chip-h"><span class="br">[</span><span class="gl">!!</span><span class="br">]</span><span class="tx">high</span></span>'
        Medium        = '<span class="sev chip-m"><span class="br">[</span><span class="gl">!</span><span class="br">]</span><span class="tx">med</span></span>'
        Low           = '<span class="sev chip-l"><span class="br">[</span><span class="gl">~</span><span class="br">]</span><span class="tx">low</span></span>'
        Informational = '<span class="sev chip-i"><span class="br">[</span><span class="gl">·</span><span class="br">]</span><span class="tx">info</span></span>'
    }
    $sections = @()

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $bucket = $ChangesBySeverity.$severity
        if (-not $bucket -or $bucket.Count -eq 0) { continue }
        $cls = $sevClass[$severity]
        $cnt = $bucket.Count
        $sections += "<div class=`"sec-lbl`">$($chipMap[$severity]) ($cnt)</div>"

        foreach ($change in @($bucket | Sort-Object { $_['changeType'] })) {
            $desc = [System.Web.HttpUtility]::HtmlEncode($change.description)

            # Entra portal link (item 6)
            $entraHtml = ''
            $roleId  = $change['roleId']
            $groupId = $change['groupId']
            if ($roleId) {
                $safeId = [System.Web.HttpUtility]::HtmlAttributeEncode($roleId)
                $entraHtml = "<a href=`"https://entra.microsoft.com/#view/Microsoft_AAD_IAM/RoleDetailsMenuBlade/~/Description/roleDefinitionId/$safeId`" class=`"entra-link`" target=`"_blank`" rel=`"noopener`">Entra</a>"
            } elseif ($groupId) {
                $safeId = [System.Web.HttpUtility]::HtmlAttributeEncode($groupId)
                $entraHtml = "<a href=`"https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$safeId`" class=`"entra-link`" target=`"_blank`" rel=`"noopener`">Entra</a>"
            }

            # Sigil: git-porcelain style event marker (design 09)
            $changeType = $change['changeType']
            $addTypes   = @('added', 'rule_added', 'policy_added', 'new_property')
            $delTypes   = @('removed', 'rule_removed', 'policy_removed', 'removed_property')
            $sigilChar  = if ($addTypes -contains $changeType) { '+' } elseif ($delTypes -contains $changeType) { '&#8722;' } else { 'M' }
            $sigilCls   = if ($addTypes -contains $changeType) { 'add' } elseif ($delTypes -contains $changeType) { 'del' } else { 'mod' }
            $sigilHtml  = "<span class=`"evt-sig $sigilCls`">$sigilChar</span>"

            # Two-line header when context is available
            $headerHtml = if ($change.context) {
                $ctxE      = [System.Web.HttpUtility]::HtmlEncode($change.context)
                $shortDesc = [System.Web.HttpUtility]::HtmlEncode(($change.description -replace '\s*\([^)]*\)\s*$', ''))
                "<div class=`"al-meta`"><div class=`"al-title`">$ctxE</div><div class=`"al-desc`">$sigilHtml $shortDesc</div></div>"
            } else {
                "<div class=`"al-meta`"><div class=`"al-title`">$sigilHtml $desc</div></div>"
            }

            # Diff lines
            $diffLines = @()
            $isScalar = { param($v) $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double] }

            if ($null -ne $change.old -and $null -ne $change.new) {
                if ((& $isScalar $change.old) -and (& $isScalar $change.new)) {
                    $diffLines += & $renderLine 'del' 'value' $change.old
                    $diffLines += & $renderLine 'add' 'value' $change.new
                } else {
                    try {
                        $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                        foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                            if ($diffIgnore.Contains($k)) { continue }
                            $ov = if ($oh.ContainsKey($k)) { $oh[$k] } else { $null }
                            $nv = if ($nh.ContainsKey($k)) { $nh[$k] } else { $null }
                            if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                            $diffLines += & $renderLine 'del' $k $ov
                            $diffLines += & $renderLine 'add' $k $nv
                        }
                    } catch { Write-Warning "Diff rendering failed for '$($change.description)': $_" }
                }
            } elseif ($null -ne $change.new) {
                try {
                    $nh = $change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    foreach ($k in ($nh.Keys | Sort-Object)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $diffLines += & $renderLine 'add' $k $nh[$k]
                    }
                } catch { Write-Warning "Diff rendering failed for '$($change.description)': $_" }
            } elseif ($null -ne $change.old) {
                try {
                    $oh = $change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    foreach ($k in ($oh.Keys | Sort-Object)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $diffLines += & $renderLine 'del' $k $oh[$k]
                    }
                } catch { Write-Warning "Diff rendering failed for '$($change.description)': $_" }
            }

            $diffHtml = if ($diffLines.Count -gt 0) { "<div class=`"diff`">$($diffLines -join '')</div>" } else { '' }
            $sections += "<details class=`"al $cls`"><summary>$headerHtml$entraHtml</summary>$diffHtml</details>"
        }
    }
    $sectionsHtml = $sections -join "`n"

    # View diff button
    $viewDiffHtml = ''
    if ($CommitUrl) {
        $safeUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($CommitUrl)
        $viewDiffHtml = "<div class=`"view-diff-wrap`"><a href=`"$safeUrl`" class=`"btn btn-secondary`" target=`"_blank`" rel=`"noopener`">View diff</a></div>"
    }

    # Metadata section (item 5)
    $metaRows = @("<tr><td>scan time</td><td>$timestamp</td></tr>")
    if ($TenantId) {
        $metaRows += "<tr><td>tenant</td><td>$([System.Web.HttpUtility]::HtmlEncode($TenantId))</td></tr>"
    }
    if ($CommitSha) {
        $short = $CommitSha.Substring(0, [Math]::Min(8, $CommitSha.Length))
        $shaCell = if ($CommitUrl) {
            "<a href=`"$([System.Web.HttpUtility]::HtmlAttributeEncode($CommitUrl))`">$([System.Web.HttpUtility]::HtmlEncode($short))</a>"
        } else {
            [System.Web.HttpUtility]::HtmlEncode($short)
        }
        $metaRows += "<tr><td>commit</td><td>$shaCell</td></tr>"
    }
    $buildNumber = $env:BUILD_BUILDNUMBER
    $buildId     = $env:BUILD_BUILDID
    $collUri     = ($env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI -replace '/$', '')
    $project     = $env:SYSTEM_TEAMPROJECT
    if ($buildNumber) {
        $runCell = if ($buildId -and $collUri -and $project) {
            $runUrl = [System.Web.HttpUtility]::HtmlAttributeEncode("$collUri/$project/_build/results?buildId=$buildId")
            "<a href=`"$runUrl`">$([System.Web.HttpUtility]::HtmlEncode($buildNumber))</a>"
        } else {
            [System.Web.HttpUtility]::HtmlEncode($buildNumber)
        }
        $metaRows += "<tr><td>pipeline run</td><td>$runCell</td></tr>"
    }
    $metaHtml = @"
<details class="meta">
<summary>scan metadata</summary>
<table>$($metaRows -join '')</table>
</details>
"@

    # Tenant block: name (if known) above GUID
    $tenantHtml = if ($TenantId -or $TenantName) {
        $lines = @()
        if ($TenantName) { $lines += "<div class=`"tenant-name`">$([System.Web.HttpUtility]::HtmlEncode($TenantName))</div>" }
        if ($TenantId)   { $lines += "<div class=`"tenant`">$([System.Web.HttpUtility]::HtmlEncode($TenantId))</div>" }
        $lines -join ''
    } else { '' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box}
html,body{margin:0;background:#0a0a0a;color:#e5e5e5;font-family:'JetBrains Mono','Fira Mono','Cascadia Code','Consolas','Courier New',monospace}
.wrap{max-width:720px;margin:0 auto;padding:40px 32px}
.brand{font-size:20px;font-weight:600;color:#d97706;letter-spacing:-0.01em}
.brand-sub{font-size:11px;color:#525252;letter-spacing:0.12em;text-transform:uppercase;margin-top:4px}
.tenant-name{font-size:13px;color:#a3a3a3;margin-top:10px;letter-spacing:-0.005em}
.tenant{font-size:11px;color:#525252;margin-top:2px}
.scan-ts{font-size:10px;color:#525252;letter-spacing:0.06em;margin-top:6px}
.st{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:#1a1a1a;border:1px solid #1a1a1a;margin:28px 0 0}
.s{padding:20px 22px;background:#0a0a0a}
.s.now{background:linear-gradient(180deg,#1a0f05 0%,#0a0a0a 100%)}
.sd{font-size:10px;color:#525252;letter-spacing:0.18em;text-transform:uppercase}
.s.now .sd{color:#d97706}
.sv{font-size:30px;font-weight:500;letter-spacing:-0.02em;margin-top:8px;line-height:1;color:#e5e5e5}
.s.now .sv{color:#fcd34d}
.sl{font-size:11px;color:#737373;margin-top:6px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif}
.sev-bar{display:flex;height:4px;gap:2px;background:#1a1a1a;margin-top:1px}
.sbs{border-radius:0}
.sec-lbl{font-size:10px;letter-spacing:0.22em;text-transform:uppercase;color:#525252;display:flex;align-items:center;gap:10px;margin:28px 0 10px}
.sec-lbl::after{content:"";flex:1;height:1px;background:#1a1a1a}
.sev{display:inline-flex;align-items:baseline;gap:0;font-size:12px;font-weight:500;letter-spacing:0.02em;line-height:1}
.sev .br{color:#404040}
.sev .gl{width:1.6em;text-align:center;font-weight:700}
.sev .tx{margin-left:8px;color:#a3a3a3;text-transform:lowercase}
.chip-h .gl{color:#ef4444}
.chip-m .gl{color:#d97706}
.chip-l .gl{color:#22c55e}
.chip-i .gl{color:#737373}
details.al{border:1px solid;border-left-width:2px;border-radius:4px;margin-bottom:6px;overflow:hidden}
details.al.high{border-color:rgba(239,68,68,0.4);background:rgba(239,68,68,0.04)}
details.al.med{border-color:rgba(217,119,6,0.4);background:rgba(217,119,6,0.04)}
details.al.low{border-color:rgba(34,197,94,0.4);background:rgba(34,197,94,0.04)}
details.al.inf{border-color:rgba(115,115,115,0.3);background:#141414}
details.al>summary{padding:12px 14px;cursor:pointer;list-style:none;display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
details.al>summary::-webkit-details-marker{display:none}
details.al>summary::after{content:'›';font-size:16px;color:#404040;flex-shrink:0;transition:transform 0.15s;line-height:1;margin-top:1px}
details.al[open]>summary::after{transform:rotate(90deg)}
.al-meta{flex:1;min-width:0}
.al-title{font-weight:600;font-size:13px;letter-spacing:-0.005em;color:#e5e5e5}
.al-desc{font-size:12px;color:#a3a3a3;margin-top:2px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;line-height:1.4}
.evt-sig{font-weight:700;display:inline-block;width:1em;text-align:center}
.evt-sig.add{color:#22c55e}
.evt-sig.mod{color:#d97706}
.evt-sig.del{color:#ef4444}
.entra-link{font-size:10px;color:#525252;text-decoration:none;border:1px solid #262626;border-radius:2px;padding:2px 6px;white-space:nowrap;flex-shrink:0;margin-top:3px}
.entra-link:hover{color:#d97706;border-color:#d97706}
.diff{padding:4px 14px 10px;border-top:1px solid #1a1a1a;overflow:hidden}
.diff-line{font-size:11px;line-height:1.9;word-break:break-word;overflow-wrap:break-word}
.diff-line.del{color:#f87171}
.diff-line.add{color:#4ade80}
.btn{height:32px;display:inline-flex;align-items:center;justify-content:center;padding:0 14px;border-radius:4px;font-family:inherit;font-size:13px;font-weight:500;letter-spacing:-0.005em;border:1px solid transparent;text-decoration:none;white-space:nowrap}
.btn-secondary{background:transparent;color:#a3a3a3;border-color:#262626}
.btn-secondary:hover{color:#e5e5e5;border-color:#404040}
.view-diff-wrap{margin-top:20px}
details.meta{margin-top:8px}
details.meta>summary{font-size:10px;color:#525252;letter-spacing:0.06em;cursor:pointer;list-style:none;display:inline-flex;align-items:center;gap:6px}
details.meta>summary::-webkit-details-marker{display:none}
details.meta>summary::after{content:'›';font-size:13px;color:#404040;transition:transform 0.15s;line-height:1}
details.meta[open]>summary::after{transform:rotate(90deg)}
details.meta table{margin-top:8px;border-collapse:collapse}
details.meta td{font-size:11px;padding:2px 16px 2px 0;vertical-align:top}
details.meta td:first-child{color:#525252;white-space:nowrap}
details.meta td:last-child{color:#a3a3a3;word-break:break-all}
details.meta a{color:#d97706;text-decoration:none}
.footer{margin-top:24px;font-size:10px;color:#525252;letter-spacing:0.06em}
</style>
</head>
<body>
<div class="wrap">
<div>
  <div class="brand">pim/monitor</div>
  <div class="brand-sub">scan report</div>
  $tenantHtml
</div>
<div class="st">
  <div class="s now"><div class="sd">NOW</div><div class="sv">$tot</div><div class="sl">changes</div></div>
  <div class="s"><div class="sd">HIGH</div><div class="sv">$hi</div><div class="sl"></div></div>
  <div class="s"><div class="sd">MED</div><div class="sv">$med</div><div class="sl"></div></div>
  <div class="s"><div class="sd">LOW</div><div class="sv">$lo</div><div class="sl"></div></div>
</div>
<div class="scan-ts">$timestamp</div>
$barHtml
$sectionsHtml
$viewDiffHtml
$metaHtml
<div class="footer">PIM Monitor · automated scan notification</div>
</div>
</body>
</html>
"@
}

<#
.SYNOPSIS
    Writes the HTML scan report artifact to disk.

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER OutputPath
    Full file path to write (e.g. $(Build.ArtifactStagingDirectory)/scan-report.html).

.PARAMETER MinSeverity
    Lowest severity to include in the report (default Low — show everything).

.PARAMETER TenantId
    Optional tenant GUID displayed in the report header and metadata.

.PARAMETER CommitSha
    Optional commit SHA for the "View diff" link and metadata.
#>
function Export-ScanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $OutputPath,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Low',
        [string] $TenantId,
        [string] $TenantName,
        [string] $CommitSha
    )

    $commitUrl = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $html = Format-ScanReportHtml `
        -ChangesBySeverity $ChangesBySeverity `
        -MinSeverity $MinSeverity `
        -TenantId $TenantId `
        -TenantName $TenantName `
        -CommitSha $CommitSha `
        -CommitUrl $commitUrl
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Host "  Scan report written to $OutputPath"
}

# ============================================================================
# Email — Microsoft Graph sendMail
# ============================================================================

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
        [string] $CommitSha
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
    $htmlBody = Format-ChangeSummaryHtml -ChangesBySeverity $ChangesBySeverity -MinSeverity $MinSeverity -CommitUrl $commitUrl

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

# ============================================================================
# Webhook — Teams / Slack / Discord / Generic
# ============================================================================

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
        $diffIgnoreWh.Add('target') | Out-Null

        foreach ($change in ($bucket | Select-Object -First 15)) {
            $changeText = "• $($change.description)"
            $item = @{ type = 'TextBlock'; text = $changeText; wrap = $true; spacing = 'Small' }

            # Add portal link if change contains an entity ID we can link
            if ($change.PSObject.Properties.Name -contains 'roleId') {
                $roleId = $change.roleId
                $entraLink = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/RoleDetailsMenuBlade/~/Description/roleDefinitionId/$roleId"
                $item['selectAction'] = @{
                    type = 'Action.OpenUrl'
                    url  = $entraLink
                }
            }
            elseif ($change.PSObject.Properties.Name -contains 'groupId') {
                $groupId = $change.groupId
                $entraLink = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$groupId"
                $item['selectAction'] = @{
                    type = 'Action.OpenUrl'
                    url  = $entraLink
                }
            }

            $severityItems += $item

            $diffLines = @()
            if ($null -ne $change.old -and $null -ne $change.new) {
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
                        $diffLines += "${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)"
                        $shown++
                    }
                } catch {}
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
        $diffIgnoreWh.Add('target') | Out-Null

        $text = "*$severity ($($bucket.Count))*`n"
        foreach ($change in ($bucket | Select-Object -First 20)) {
            $text += "• $($change.description)`n"
            $diffLines = @()
            if ($null -ne $change.old -and $null -ne $change.new) {
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
                        $diffLines += "  ``${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)``"
                        $shown++
                    }
                } catch {}
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
        $diffIgnoreWh.Add('target') | Out-Null

        $value = ""
        foreach ($change in ($bucket | Select-Object -First 10)) {
            $value += "• $($change.description)`n"
            $diffLines = @()
            if ($null -ne $change.old -and $null -ne $change.new) {
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
                        $diffLines += "  ${k}: $(& $fmtValWh $ov) → $(& $fmtValWh $nv)"
                        $shown++
                    }
                } catch {}
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
    [CmdletBinding()]
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

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post `
            -ContentType 'application/json' `
            -Body ($payload | ConvertTo-Json -Depth 20) | Out-Null
        Write-Host "  Webhook sent ($type)"
    }
    catch {
        Write-Warning "  Webhook send failed: $_"
    }
}
