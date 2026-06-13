<#
.SYNOPSIS
    HTML scan report generation for PIM Monitor.

.DESCRIPTION
    Generates standalone HTML scan reports with dark mode support and browser optimization.
    Dot-source notifications-shared.ps1 first.
#>

<#
.SYNOPSIS
    Derives the inventory path for a change object (best-effort).

.DESCRIPTION
    Given a change object, attempts to construct the likely inventory file path
    using the context name and description hints. Returns $null when the path
    cannot be reliably derived (e.g., compliance violations, coverage items).

.PARAMETER Change
    The change object containing context, description, and fileType.

.EXAMPLE
    $path = Get-ChangeInventoryPath -Change $change
    # Returns: "inventory/directory-roles/global-administrator/policy.json" (if derivable)
#>
function Get-ChangeInventoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Change
    )

    # Compliance and coverage items don't map to single files; skip
    $fileType = $Change['fileType']
    if ($fileType -and $script:ComplianceFileTypes.Contains($fileType)) { return $null }
    if ($fileType -eq 'coverage') { return $null }

    $context = $Change['context']
    if ([string]::IsNullOrWhiteSpace($context)) { return $null }

    # Derive the slug from context (display name → kebab-case)
    $slug = Get-InventorySlug -Name $context
    if ([string]::IsNullOrWhiteSpace($slug)) { return $null }

    $description = $Change['description']
    $workload = $Change['workload']
    if (-not $workload) {
        $workload = if ($description -match 'PIM Groups') { 'pim-groups' } else { 'directory-roles' }
    }

    # Heuristic: infer file from description keywords
    $fileName = if ($description -match 'policy|rule') {
        'policy.json'
    } elseif ($description -match 'assignment|eligible|active|permanent') {
        'assignments.json'
    } elseif ($description -match 'definition|enabled|privilege|permission') {
        'definition.json'
    } else {
        $null
    }

    if ($fileName) {
        return "inventory/$workload/$slug/$fileName"
    }
    return $null
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
function Build-HtmlReport {
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

    # Check if CI environment allows URL generation for evidence-links
    $canBuildUrls = -not ([string]::IsNullOrWhiteSpace($CommitSha)) -and `
                    ($env:BUILD_REPOSITORY_URI -or ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY))

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

    $renderLine = {
        param([string]$cls, [string]$key, $val)
        $ke = [System.Web.HttpUtility]::HtmlEncode($key)
        $ve = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $val -AuthContextLookup $AuthContextLookup))
        "<div class=`"diff-line $cls`">${ke}: ${ve}</div>"
    }

    $renderPropertyBlock = {
        param([string]$key, $oldVal, $newVal, [string]$oldLabel = 'actual', [string]$newLabel = 'expected')

        $diffMode  = $null -ne $oldVal -and $null -ne $newVal
        $oldIsDict = $oldVal -is [System.Collections.IDictionary]
        $newIsDict = $newVal -is [System.Collections.IDictionary]

        if ($oldIsDict -or $newIsDict) {
            $oldDict = if ($oldIsDict) { $oldVal } else { [ordered]@{} }
            $newDict = if ($newIsDict) { $newVal } else { [ordered]@{} }
            $allSubs = @(@($oldDict.Keys) + @($newDict.Keys)) | Sort-Object -Unique
            $blocks  = @()
            foreach ($sk in $allSubs) {
                $sov = if ($sk -in $oldDict.Keys) { $oldDict[$sk] } else { $null }
                $snv = if ($sk -in $newDict.Keys) { $newDict[$sk] } else { $null }
                if ($diffMode -and (ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
                $blocks += & $renderPropertyBlock "$key.$sk" $sov $snv $oldLabel $newLabel
            }
            return ($blocks -join '')
        }

        $ke = [System.Web.HttpUtility]::HtmlEncode($key)
        if ($diffMode) {
            $ove = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $oldVal -AuthContextLookup $AuthContextLookup))
            $nve = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $newVal -AuthContextLookup $AuthContextLookup))
            return "<div class=`"diff-prop`">Property: $ke</div>" +
                   "<div class=`"diff-line del`">${oldLabel}: $ove</div>" +
                   "<div class=`"diff-line add`">${newLabel}: $nve</div>"
        } elseif ($null -ne $newVal) {
            $nve = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $newVal -AuthContextLookup $AuthContextLookup))
            return "<div class=`"diff-line add`">${ke}: ${nve}</div>"
        } elseif ($null -ne $oldVal) {
            $ove = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $oldVal -AuthContextLookup $AuthContextLookup))
            return "<div class=`"diff-line del`">${ke}: ${ove}</div>"
        }
        return ''
    }

    $diffIgnore = [System.Collections.Generic.HashSet[string]]::new(
        $script:DiffIgnoreProperties,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # Compliance type set — used for rendering split and label selection
    $complianceTypes = $script:ComplianceFileTypes

    # Split counts for the stats area second line
    $gitCount = 0
    $complianceCount = 0
    foreach ($sev in $script:SeverityOrder) {
        foreach ($chg in $ChangesBySeverity.$sev) {
            $ft = $chg['fileType']
            if ($ft -and $complianceTypes.Contains($ft)) { $complianceCount++ } else { $gitCount++ }
        }
    }

    # Renders a single change entry as a <details> element.
    # $oldLabel / $newLabel are passed explicitly so each rendering pass controls labels independently.
    $renderChangeEntry = {
        param($change, $cls, [string]$oldLabel, [string]$newLabel)

        $desc = [System.Web.HttpUtility]::HtmlEncode($change['description'])

        # Build evidence-links (view file + view diff) when CI env allows
        $evidenceHtml = ''
        if ($canBuildUrls) {
            $invPath = Get-ChangeInventoryPath -Change $change
            if ($invPath) {
                $fileUrl = Get-InventoryFileUrl -RelativePath $invPath -CommitSha $CommitSha
                $diffUrl = Get-FileDiffUrl -CommitSha $CommitSha -RelativePath $invPath
                $links   = @()
                if ($fileUrl) {
                    $safeUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($fileUrl)
                    $links += "<a href=`"$safeUrl`" class=`"ev-link`" target=`"_blank`" rel=`"noopener`">view file</a>"
                }
                if ($diffUrl) {
                    $safeUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($diffUrl)
                    $links += "<a href=`"$safeUrl`" class=`"ev-link`" target=`"_blank`" rel=`"noopener`">view diff</a>"
                }
                if ($links.Count -gt 0) {
                    $evidenceHtml = "<div class=`"ev-block`">$($links -join ' · ')</div>"
                }
            }
        }

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

        $changeType = $change['changeType']
        $addTypes   = @('added', 'created', 'rule_added', 'policy_added', 'new_property', 'non-compliant', 'unclassified')
        $delTypes   = @('removed', 'deleted', 'rule_removed', 'policy_removed', 'removed_property')
        $sigilChar  = if ($addTypes -contains $changeType) { '+' } elseif ($delTypes -contains $changeType) { '&#8722;' } else { 'M' }
        $sigilCls   = if ($addTypes -contains $changeType) { 'add' } elseif ($delTypes -contains $changeType) { 'del' } else { 'mod' }
        $sigilHtml  = "<span class=`"evt-sig $sigilCls`">$sigilChar</span>"

        $headerHtml = if ($change['context']) {
            $ctxE      = [System.Web.HttpUtility]::HtmlEncode($change['context'])
            $shortDesc = [System.Web.HttpUtility]::HtmlEncode(($change['description'] -replace '\s*\([^)]*\)\s*$', ''))
            "<div class=`"al-meta`"><div class=`"al-title`">$ctxE</div><div class=`"al-desc`">$sigilHtml $shortDesc</div></div>"
        } else {
            "<div class=`"al-meta`"><div class=`"al-title`">$sigilHtml $desc</div></div>"
        }

        $diffLines = @()
        if ($null -ne $change['old'] -and $null -ne $change['new']) {
            if ((Test-DiffScalar $change['old']) -and (Test-DiffScalar $change['new'])) {
                $diffLines += & $renderLine 'del' $oldLabel $change['old']
                $diffLines += & $renderLine 'add' $newLabel $change['new']
            } else {
                try {
                    $oh = $change['old'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $nh = $change['new'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $ov = if ($k -in $oh.Keys) { $oh[$k] } else { $null }
                        $nv = if ($k -in $nh.Keys) { $nh[$k] } else { $null }
                        if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                        $diffLines += & $renderPropertyBlock $k $ov $nv $oldLabel $newLabel
                    }
                } catch { Write-Warning "Diff rendering failed for '$($change['description'])': $_" }
            }
        } elseif ($null -ne $change['new']) {
            try {
                $nh = $change['new'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                foreach ($k in ($nh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $diffLines += & $renderPropertyBlock $k $null $nh[$k] $oldLabel $newLabel
                }
            } catch { Write-Warning "Diff rendering failed for '$($change['description'])': $_" }
        } elseif ($null -ne $change['old']) {
            try {
                $oh = $change['old'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                foreach ($k in ($oh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $diffLines += & $renderPropertyBlock $k $oh[$k] $null $oldLabel $newLabel
                }
            } catch { Write-Warning "Diff rendering failed for '$($change['description'])': $_" }
        }

        $diffHtml = if ($diffLines.Count -gt 0) { "<div class=`"diff`">$($diffLines -join '')</div>" } else { '' }
        "<details class=`"al $cls`"><summary>$headerHtml$entraHtml</summary>$evidenceHtml$diffHtml</details>"
    }

    $sevClass = @{ High = 'high'; Medium = 'med'; Low = 'low'; Informational = 'inf'; Coverage = 'inf' }
    $chipMap  = @{
        High          = '<span class="sev chip-h"><span class="br">[</span><span class="gl">!!</span><span class="br">]</span><span class="tx">high</span></span>'
        Medium        = '<span class="sev chip-m"><span class="br">[</span><span class="gl">!</span><span class="br">]</span><span class="tx">med</span></span>'
        Low           = '<span class="sev chip-l"><span class="br">[</span><span class="gl">~</span><span class="br">]</span><span class="tx">low</span></span>'
        Informational = '<span class="sev chip-i"><span class="br">[</span><span class="gl">·</span><span class="br">]</span><span class="tx">info</span></span>'
        Coverage      = '<span class="sev chip-i"><span class="br">[</span><span class="gl">?</span><span class="br">]</span><span class="tx">coverage</span></span>'
    }
    # Render the parent section header (CHANGES, ACCESS MODEL) — bold sans, brand-amber underline.
    # Mirrors the email's Build-EmailChangeHtml hierarchy so the report and email stay visually aligned.
    $renderSectionHeader = {
        param([string]$label)
        "<div class=`"pm-section-hd`">$label</div>"
    }
    # Render a sub-section label (COMPLIANCE, COVERAGE) — amber monospace.
    $renderSubLabel = {
        param([string]$label)
        "<div class=`"pm-sub-lbl`">$label</div>"
    }

    $sections = @()

    # Pass 1 — Git changes (was / changed to), wrapped in a "CHANGES" parent section
    $hasGitChanges = $false
    $gitSections = @()
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $gitItems = @($ChangesBySeverity.$severity | Where-Object { -not $complianceTypes.Contains($_['fileType']) })
        if ($gitItems.Count -eq 0) { continue }
        $hasGitChanges = $true
        $cls = $sevClass[$severity]
        $gitSections += "<div class=`"sec-lbl`">$($chipMap[$severity]) ($($gitItems.Count))</div>"
        foreach ($change in @($gitItems | Sort-Object { $_['changeType'] })) {
            $gitSections += & $renderChangeEntry $change $cls 'was' 'changed to'
        }
    }
    if ($hasGitChanges) {
        $sections += & $renderSectionHeader 'Changes'
        $sections += $gitSections
    }

    # Access Model parent section (Compliance + Coverage live underneath)
    $hasComplianceItems = $complianceCount -gt 0
    $coverageItems = @()
    if ($ChangesBySeverity['Coverage']) {
        $coverageItems = @($ChangesBySeverity['Coverage'])
    }
    $hasCoverageItems = $coverageItems.Count -gt 0

    if ($hasComplianceItems -or $hasCoverageItems) {
        $sections += & $renderSectionHeader 'Access Model'
    }

    # Pass 2 — Access Model > Compliance (actual / expected)
    if ($hasComplianceItems) {
        $sections += & $renderSubLabel 'Compliance'
        foreach ($severity in $script:SeverityOrder) {
            if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
            $compItems = @($ChangesBySeverity.$severity | Where-Object { $complianceTypes.Contains($_['fileType']) })
            if ($compItems.Count -eq 0) { continue }
            $cls = $sevClass[$severity]
            $sections += "<div class=`"sec-lbl`">$($chipMap[$severity]) ($($compItems.Count))</div>"
            foreach ($change in @($compItems | Sort-Object { $_['changeType'] })) {
                $sections += & $renderChangeEntry $change $cls 'actual' 'expected'
            }
        }
    }

    # Pass 3 — Access Model > Coverage (unclassified entities)
    if ($hasCoverageItems) {
        $sections += & $renderSubLabel "Coverage ($($coverageItems.Count))"
        foreach ($change in $coverageItems) {
            $sections += & $renderChangeEntry $change 'inf' 'actual' 'expected'
        }
    }

    $severityViewHtml = $sections -join "`n"

    # Entity-view: group changes by context, sorted by severity count then name.
    # Includes Coverage (unclassified-entity items) alongside severity buckets so the
    # entity-view shows the full audit picture, not just severity-classified changes.
    $entityGroups = @{}
    $severityBuckets = @($script:SeverityOrder)
    if ($ChangesBySeverity['Coverage']) {
        $severityBuckets += 'Coverage'
    }
    foreach ($severity in $severityBuckets) {
        $bucket = $ChangesBySeverity.$severity
        if (-not $bucket) { continue }
        foreach ($change in $bucket) {
            $ctx = $change['context'] ?? 'Other'
            if (-not ($ctx -in $entityGroups.Keys)) {
                $entityGroups[$ctx] = @{ changes = @(); severityMap = @{ High = 0; Medium = 0; Low = 0; Informational = 0; Coverage = 0 } }
            }
            $entityGroups[$ctx].changes += @{ change = $change; severity = $severity }
            $entityGroups[$ctx].severityMap[$severity]++
        }
    }

    $entitySections = @()
    if ($entityGroups.Count -gt 0) {
        $entitySections += & $renderSectionHeader 'By Entity'
    }
    foreach ($entity in ($entityGroups.Keys | Sort-Object {
        $sm = $entityGroups[$_].severityMap
        [System.Tuple]::Create(
            -$sm.High,
            -$sm.Medium,
            -$sm.Low,
            $_
        )
    })) {
        $group = $entityGroups[$entity]
        $sm = $group.severityMap
        $statChip = ''
        if ($sm.High -gt 0)   { $statChip += " / High: $($sm.High)" }
        if ($sm.Medium -gt 0) { $statChip += " / Med: $($sm.Medium)" }
        if ($sm.Low -gt 0)    { $statChip += " / Low: $($sm.Low)" }
        if ($sm.Informational -gt 0) { $statChip += " / Info: $($sm.Informational)" }
        if ($sm.Coverage -gt 0) { $statChip += " / Coverage: $($sm.Coverage)" }

        $entitySections += "<div class=`"entity-block`"><div class=`"entity-name`">$([System.Web.HttpUtility]::HtmlEncode($entity))$statChip</div>"

        foreach ($item in $group.changes) {
            $sev = $item.severity
            $change = $item.change
            $cls = $sevClass[$sev]
            $ft = $change['fileType']
            $label1 = if ($ft -and $complianceTypes.Contains($ft)) { 'actual' } else { 'was' }
            $label2 = if ($ft -and $complianceTypes.Contains($ft)) { 'expected' } else { 'changed to' }
            $entitySections += & $renderChangeEntry $change $cls $label1 $label2
        }
        $entitySections += '</div>'
    }

    $entityViewHtml = $entitySections -join "`n"

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

    # View-tabs HTML (anchor-based CSS toggle) — small pill, lives in the header row.
    $viewTabsHtml = @"
<nav class="view-tabs" aria-label="View mode">
  <a href="#view-severity">By severity</a>
  <a href="#view-entity">By entity</a>
</nav>
"@

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="format-detection" content="telephone=no">
<style>
*{box-sizing:border-box}
html,body{margin:0;background:#0a0a0a;color:#e5e5e5;font-family:'JetBrains Mono','Fira Mono','Cascadia Code','Consolas','Courier New',monospace}
.wrap{max-width:720px;margin:0 auto;padding:40px 32px}
.hdr{display:flex;align-items:flex-start;gap:24px}
.hdr-l{min-width:0;flex:1}
.hdr-r{flex-shrink:0;margin-left:auto}
@media (max-width:560px){.hdr{flex-direction:column}.hdr-r{margin-left:0}}
.brand{font-size:20px;font-weight:600;color:#d97706;letter-spacing:-0.01em}
.brand-sub{font-size:11px;color:#525252;letter-spacing:0.12em;text-transform:uppercase;margin-top:4px}
.tenant-name{font-size:13px;color:#a3a3a3;margin-top:10px;letter-spacing:-0.005em}
.tenant{font-size:11px;color:#525252;margin-top:2px}
.st-breakdown{font-family:'JetBrains Mono','Fira Mono','Cascadia Code','Consolas','Courier New',monospace;font-size:10px;color:#525252;letter-spacing:0.08em;padding:8px 0 4px}
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
.diff-prop{font-size:11px;color:#a3a3a3;margin-top:8px;line-height:1.6;word-break:break-word}
.diff-prop:first-child{margin-top:0}
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
/* View toggle — small pill in the header area, not a full-width nav. */
.view-tabs{display:inline-flex;gap:2px;background:#141414;border:1px solid #27272a;border-radius:4px;padding:2px;margin-top:16px}
.view-tabs a{color:#737373;font-family:inherit;font-size:10px;text-transform:uppercase;letter-spacing:0.08em;text-decoration:none;padding:5px 10px;border-radius:3px;transition:all 0.15s}
.view-tabs a:hover{color:#e5e5e5}
/* Default visibility — severity shown, entity hidden */
#view-severity{display:block}
#view-entity{display:none}
/* Use body:has() so we can switch both views and tab-states regardless of DOM order
   (tabs sit BEFORE sections; sibling combinator ~ would only reach forward). */
body:has(#view-entity:target) #view-severity{display:none}
body:has(#view-entity:target) #view-entity{display:block}
/* Active tab styling — default (no #view-entity in URL) lights up "by severity" */
.view-tabs a[href="#view-severity"]{background:#d97706;color:#0a0a0a;font-weight:600}
body:has(#view-entity:target) .view-tabs a[href="#view-severity"]{background:transparent;color:#737373;font-weight:normal}
body:has(#view-entity:target) .view-tabs a[href="#view-entity"]{background:#d97706;color:#0a0a0a;font-weight:600}
/* Email-style hierarchy headers — mirror Build-EmailChangeHtml. */
.pm-section-hd{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:15px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:#e5e5e5;border-bottom:2px solid #d97706;padding:0 0 6px;margin:32px 0 16px}
.pm-section-hd:first-child{margin-top:0}
.pm-sub-lbl{font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:#d97706;margin:18px 0 8px}
.ev-block{margin:8px 0 12px;padding:8px 14px;background:#1a1a1a;border-left:2px solid #27272a;border-radius:2px;font-size:10px}
.ev-link{color:#d97706;text-decoration:none;margin:0 2px}
.ev-link:hover{text-decoration:underline}
.entity-block{margin-bottom:24px;border-left:2px solid #27272a;padding-left:16px}
.entity-name{font-size:13px;font-weight:600;color:#e5e5e5;margin-bottom:8px}
.entity-stats{font-size:10px;color:#525252;margin-left:0}
@media print{
  body{background:#ffffff!important;color:#18181b!important}
  .wrap{padding:20px}
  .view-tabs{display:none!important}
  .hdr-r{display:none!important}
  .pm-section-hd{color:#18181b!important;border-bottom-color:#d97706!important}
  .pm-sub-lbl{color:#d97706!important}
  #view-entity{display:none!important}
  details{display:block!important}
  details>summary{display:block!important}
  details.al>summary::after{display:none!important}
  section.severity-view,section.entity-view{page-break-before:auto;margin-bottom:40px}
  .sec-lbl{border-bottom:1px solid #d4d4d4;page-break-after:avoid}
  .diff{border-top:1px solid #d4d4d4!important}
  a[href]{color:#18181b;text-decoration:underline}
  /* Print URLs after every link so the printed PDF is a self-contained audit trail */
  a[href^="http"]::after{content:' ('attr(href)')';font-size:9pt;color:#71717a;word-break:break-all}
  /* Suppress URL printing for in-page anchors (view-tabs already hidden, but defensive) */
  a[href^="#"]::after{content:none}
  .view-diff-wrap,.footer{display:none!important}
  .sev-bar{display:none!important}
}
</style>
</head>
<body>
<div class="wrap">
<div class="hdr">
  <div class="hdr-l">
    <div class="brand">pim/monitor</div>
    <div class="brand-sub">scan report</div>
    $tenantHtml
  </div>
  <div class="hdr-r">$viewTabsHtml</div>
</div>
<div class="st">
  <div class="s now"><div class="sd">NOW</div><div class="sv">$tot</div><div class="sl">changes</div></div>
  <div class="s"><div class="sd">HIGH</div><div class="sv">$hi</div><div class="sl"></div></div>
  <div class="s"><div class="sd">MED</div><div class="sv">$med</div><div class="sl"></div></div>
  <div class="s"><div class="sd">LOW</div><div class="sv">$lo</div><div class="sl"></div></div>
</div>
$(if ($complianceCount -gt 0) { "<div class=`"st-breakdown`">git $gitCount &middot; compliance $complianceCount</div>" })
$barHtml
<section id="view-severity" class="severity-view">
$severityViewHtml
</section>
<section id="view-entity" class="entity-view">
$entityViewHtml
</section>
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
    [CmdletBinding(SupportsShouldProcess)]
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

    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Write HTML scan report')) { return }

    $commitUrl = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $html = Build-HtmlReport `
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
