<#
.SYNOPSIS
    HTML scan report generation for PIM Monitor.

.DESCRIPTION
    Generates standalone HTML scan reports with dark mode support and browser optimization.
    Dot-source notifications-shared.ps1 first.
#>

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
        [string] $CommitUrl,
        [hashtable] $AuthContextLookup = @{}
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
            $addTypes   = @('added', 'created', 'rule_added', 'policy_added', 'new_property')
            $delTypes   = @('removed', 'deleted', 'rule_removed', 'policy_removed', 'removed_property')
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
        [string] $CommitSha,
        [hashtable] $AuthContextLookup = @{}
    )

    $commitUrl = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $html = Format-ScanReportHtml `
        -ChangesBySeverity $ChangesBySeverity `
        -MinSeverity $MinSeverity `
        -TenantId $TenantId `
        -TenantName $TenantName `
        -CommitSha $CommitSha `
        -CommitUrl $commitUrl `
        -AuthContextLookup $AuthContextLookup
    Set-Content -Path $OutputPath -Value $html -Encoding UTF8
    Write-Host "  Scan report written to $OutputPath"
}
