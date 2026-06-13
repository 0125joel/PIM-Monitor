function Build-EmailSubject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [int] $RelevantCount,
        [int] $CoverageCount = 0,
        [string] $TenantName
    )

    $sevParts = @()
    if ($ChangesBySeverity.High.Count -gt 0)          { $sevParts += "$($ChangesBySeverity.High.Count) High" }
    if ($ChangesBySeverity.Medium.Count -gt 0)        { $sevParts += "$($ChangesBySeverity.Medium.Count) Medium" }
    if ($ChangesBySeverity.Low.Count -gt 0)           { $sevParts += "$($ChangesBySeverity.Low.Count) Low" }
    if ($ChangesBySeverity.Informational.Count -gt 0) { $sevParts += "$($ChangesBySeverity.Informational.Count) Info" }
    if ($CoverageCount -gt 0)                         { $sevParts += "$CoverageCount Classification" }

    $tenantTag = if ($TenantName) { "$TenantName" } else { 'PIM Monitor' }
    $prefix    = if ($TenantName) { "[PIM Monitor] ${tenantTag}: " } else { '[PIM Monitor] ' }

    # Lead with the highest severity present so triage is immediate from the inbox
    $top = if     ($ChangesBySeverity.High.Count    -gt 0) { @{ Label = 'HIGH';   Count = $ChangesBySeverity.High.Count } }
           elseif ($ChangesBySeverity.Medium.Count  -gt 0) { @{ Label = 'MEDIUM'; Count = $ChangesBySeverity.Medium.Count } }
           elseif ($ChangesBySeverity.Low.Count     -gt 0) { @{ Label = 'LOW';    Count = $ChangesBySeverity.Low.Count } }
           elseif ($CoverageCount -gt 0)                   { @{ Label = 'CLASSIFICATION'; Count = $CoverageCount } }
           elseif ($ChangesBySeverity.Informational.Count -gt 0) { @{ Label = 'INFO'; Count = $ChangesBySeverity.Informational.Count } }
           else { $null }

    $s = if ($RelevantCount -eq 1) { 'change' } else { 'changes' }

    if ($top) {
        $detail = if ($sevParts.Count -gt 1) { " ($($sevParts -join ', '))" } else { '' }
        return "${prefix}$($top.Label) severity, $RelevantCount $s$detail"
    }
    return "${prefix}$RelevantCount $s"
}

function Send-EmailNotification {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [Parameter(Mandatory)] [string] $ToAddress,
        [Parameter(Mandatory)] [string] $FromAddress,
        [Parameter(Mandatory)] [string] $AccessToken,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitSha,
        [hashtable] $AuthContextLookup = @{},
        [string] $TenantName
    )

    # Coverage violations always count as Medium regardless of MinSeverity
    $relevantCount = 0
    foreach ($sev in $script:SeverityOrder) {
        if ($script:SeverityRank[$sev] -ge $script:SeverityRank[$MinSeverity]) {
            $relevantCount += $ChangesBySeverity.$sev.Count
        }
    }
    $covCount = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
    if ($script:SeverityRank['Medium'] -ge $script:SeverityRank[$MinSeverity]) {
        $relevantCount += $covCount
    }

    if ($relevantCount -eq 0) {
        Write-Host "  No changes at or above $MinSeverity severity — skipping email"
        return
    }

    $commitUrl = if ($CommitSha) { Get-CommitDiffUrl -CommitSha $CommitSha } else { $null }
    $htmlBody = Build-EmailChangeHtml `
        -ChangesBySeverity $ChangesBySeverity `
        -MinSeverity $MinSeverity `
        -CommitUrl $commitUrl `
        -AuthContextLookup $AuthContextLookup `
        -TenantName $TenantName

    $subject = Build-EmailSubject `
        -ChangesBySeverity $ChangesBySeverity `
        -RelevantCount $relevantCount `
        -CoverageCount $covCount `
        -TenantName $TenantName

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

    if (-not $PSCmdlet.ShouldProcess($ToAddress, 'Send email notification')) { return }

    try {
        $sendBody = $payload | ConvertTo-Json -Depth 10
        Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $sendBody }.GetNewClosure() -OperationName "sendMail to $ToAddress" | Out-Null
        Write-Host "  Email sent to $ToAddress"
    }
    catch {
        Write-Warning "  Email send failed: $_"
    }
}

function Build-ScanErrorEmailHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $ScanErrors)

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $rows = @()

    foreach ($err in $ScanErrors) {
        $truncatedError = if ($err.Error.Length -gt 200) {
            $err.Error.Substring(0, 200) + '...'
        } else {
            $err.Error
        }
        $compE  = [System.Web.HttpUtility]::HtmlEncode($err.Component)
        $errE   = [System.Web.HttpUtility]::HtmlEncode($truncatedError)

        $rows += "<tr><td style=`"padding:2px 32px;`">" +
            "<details style=`"border-left:3px solid #ef4444;background-color:#fef2f2;border-radius:0 3px 3px 0;`">" +
            "<summary style=`"padding:10px 14px;cursor:pointer;list-style:none;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:14px;font-weight:600;color:#1a1a1a;`">$compE</summary>" +
            "<div style=`"padding:4px 14px 10px;border-top:1px solid #d4d4d4;font-family:'Courier New','Lucida Console',monospace;font-size:11px;color:#b91c1c;line-height:1.6;`">$errE</div>" +
            "</details></td></tr>"
    }
    $rowsHtml = $rows -join ''

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
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:20px;font-weight:600;letter-spacing:-0.01em;color:#ef4444;">pim/monitor</div>
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#a3a3a3;margin-top:4px;letter-spacing:0.12em;text-transform:uppercase;">scan errors</div>
</td></tr>
<tr><td style="padding:14px 32px;background-color:#fef2f2;border-top:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;">
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#b91c1c;font-weight:600;">$($ScanErrors.Count) component(s) failed — partial scan data may be incomplete.</div>
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;margin-top:8px;letter-spacing:0.06em;">$timestamp</div>
</td></tr>
$rowsHtml
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
    Builds an HTML email body summarising detected changes.

.DESCRIPTION
    Email-safe HTML: table-only layout (Outlook MSO compatible), hidden preheader text
    for inbox preview, executive summary, severity-grouped sections without <details>,
    bulletproof VML+table buttons, and a dark-mode stylesheet that targets both standards-
    compliant clients (prefers-color-scheme) and Outlook.com ([data-ogsc]).

.PARAMETER ChangesBySeverity
    Output of Group-ChangesBySeverity.

.PARAMETER MinSeverity
    Lowest severity to include in the table (default Medium).

.PARAMETER CommitUrl
    Optional URL to link to the scan commit.

.PARAMETER TenantName
    Optional tenant display name, shown in header and preheader for triage.
#>
function Build-EmailChangeHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $MinSeverity = 'Medium',
        [string] $CommitUrl,
        [hashtable] $AuthContextLookup = @{},
        [string] $TenantName
    )

    # Design system tokens (light defaults; dark overrides via <style> block at end)
    $sevBorder     = @{ High = '#ef4444'; Medium = '#d97706'; Low = '#22c55e'; Informational = '#737373' }
    $sevBgLight    = @{ High = '#fef2f2'; Medium = '#fffbeb'; Low = '#f0fdf4'; Informational = '#f9fafb' }
    $sevLabelLight = @{ High = '#b91c1c'; Medium = '#92400e'; Low = '#166534'; Informational = '#374151' }

    $timestamp = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $cov = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
    $tot = $ChangesBySeverity.Total

    # Stat row: only colorize counts that are > 0; mute zeros
    $hiColor  = if ($hi  -gt 0) { '#b91c1c' } else { '#a3a3a3' }
    $medColor = if ($med -gt 0) { '#92400e' } else { '#a3a3a3' }
    $loColor  = if ($lo  -gt 0) { '#166534' } else { '#a3a3a3' }
    $covColor = if ($cov -gt 0) { '#1d4ed8' } else { '#a3a3a3' }

    # Shared HashSet (defined at the top of this file).
    $complianceTypes = $script:ComplianceFileTypes

    # Split counts for the stats row second line (unfiltered, like Total/High/Med/Low)
    $gitCount = 0
    $complianceCount = 0
    foreach ($sev in $script:SeverityOrder) {
        foreach ($chg in $ChangesBySeverity.$sev) {
            $ft = $chg['fileType']
            if ($ft -and $complianceTypes.Contains($ft)) { $complianceCount++ } else { $gitCount++ }
        }
    }

    # Shared rendering helpers (hoisted — avoid re-creating per change item)
    $monoBase     = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;line-height:1.9;"
    $diffDivStyle = "padding:4px 14px 10px;border-top:1px solid #d4d4d4;"

    $diffIgnore = [System.Collections.Generic.HashSet[string]]::new(
        $script:DiffIgnoreProperties,
        [System.StringComparer]::OrdinalIgnoreCase
    )

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
            return "<div class=`"pm-muted`" style=`"$monoBase color:#737373;margin-top:8px;`">Property: $ke</div>" +
                   "<div style=`"$monoBase color:#dc2626;`">${oldLabel}: $ove</div>" +
                   "<div style=`"$monoBase color:#16a34a;`">${newLabel}: $nve</div>"
        } elseif ($null -ne $newVal) {
            $nve = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $newVal -AuthContextLookup $AuthContextLookup))
            return "<div style=`"$monoBase color:#16a34a`">${ke}: ${nve}</div>"
        } elseif ($null -ne $oldVal) {
            $ove = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $oldVal -AuthContextLookup $AuthContextLookup))
            return "<div style=`"$monoBase color:#dc2626`">${ke}: ${ove}</div>"
        }
        return ''
    }

    # Renders a single change entry as a collapsible <details> table row.
    # $oldLabel / $newLabel are passed explicitly so each rendering pass controls labels independently.
    $renderChangeItem = {
        param($change, $bc, $bg, [string]$oldLabel, [string]$newLabel)

        $desc        = [System.Web.HttpUtility]::HtmlEncode($change['description'])
        $diffContent = ''

        if ($null -ne $change['old'] -and $null -ne $change['new']) {
            if ((Test-DiffScalar $change['old']) -and (Test-DiffScalar $change['new'])) {
                $ove = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $change['old'] -AuthContextLookup $AuthContextLookup))
                $nve = [System.Web.HttpUtility]::HtmlEncode((Format-DiffValue -Value $change['new'] -AuthContextLookup $AuthContextLookup))
                $html = "<div style=`"$monoBase color:#dc2626`">${oldLabel}: $ove</div>" +
                        "<div style=`"$monoBase color:#16a34a`">${newLabel}: $nve</div>"
                $diffContent = "<div style=`"$diffDivStyle`">$html</div>"
            } else {
                try {
                    $oh = $change['old'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $nh = $change['new'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                    $lines = @()
                    foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                        if ($diffIgnore.Contains($k)) { continue }
                        $ov = if ($k -in $oh.Keys) { $oh[$k] } else { $null }
                        $nv = if ($k -in $nh.Keys) { $nh[$k] } else { $null }
                        if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                        $lines += & $renderPropertyBlock $k $ov $nv $oldLabel $newLabel
                    }
                    if ($lines.Count -gt 0) {
                        $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                    }
                } catch { Write-Warning "HTML diff rendering failed for '$($change['description'])': $_" }
            }
        } elseif ($null -ne $change['new']) {
            try {
                $nh    = $change['new'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                $lines = @()
                foreach ($k in ($nh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $lines += & $renderPropertyBlock $k $null $nh[$k] $oldLabel $newLabel
                }
                if ($lines.Count -gt 0) {
                    $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                }
            } catch { Write-Warning "HTML diff rendering failed for '$($change['description'])': $_" }
        } elseif ($null -ne $change['old']) {
            try {
                $oh    = $change['old'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
                $lines = @()
                foreach ($k in ($oh.Keys | Sort-Object)) {
                    if ($diffIgnore.Contains($k)) { continue }
                    $lines += & $renderPropertyBlock $k $oh[$k] $null $oldLabel $newLabel
                }
                if ($lines.Count -gt 0) {
                    $diffContent = "<div style=`"$diffDivStyle`">$($lines -join '')</div>"
                }
            } catch { Write-Warning "HTML diff rendering failed for '$($change['description'])': $_" }
        }

        # Always-expanded card (no <details> — Outlook desktop and Gmail web do not collapse it,
        # and Apple Mail's collapse hides the diff that triages this notification).
        # cardStyle uses the severity-tinted light bg-color inline; .pm-card class in dark
        # mode overrides it to a uniform dark surface. The border-left severity color stays
        # in both modes because it is saturated enough to be legible against both backgrounds.
        $cardStyle   = "border-left:3px solid $bc;background-color:$bg;border-radius:0 3px 3px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;"
        $headerStyle = "padding:10px 14px;line-height:1.5;"

        $changeType = $change['changeType']
        $addTypes   = @('added', 'created', 'rule_added', 'policy_added', 'new_property')
        $delTypes   = @('removed', 'deleted', 'rule_removed', 'policy_removed', 'removed_property')
        $sigilChar  = if ($addTypes -contains $changeType) { '+' } elseif ($delTypes -contains $changeType) { '&#8722;' } else { 'M' }
        $sigilColor = if ($addTypes -contains $changeType) { '#16a34a' } elseif ($delTypes -contains $changeType) { '#dc2626' } else { '#d97706' }
        $sigilStyle = "font-weight:700;display:inline-block;width:1em;text-align:center;color:$sigilColor;"
        $sigilAria  = if ($addTypes -contains $changeType) { 'added' } elseif ($delTypes -contains $changeType) { 'removed' } else { 'modified' }

        $headerHtml = if ($change['context']) {
            $ctx       = [System.Web.HttpUtility]::HtmlEncode($change['context'])
            $shortDesc = [System.Web.HttpUtility]::HtmlEncode(($change['description'] -replace '\s*\([^)]*\)\s*$', ''))
            "<span class=`"pm-text`" style=`"display:block;font-size:14px;font-weight:600;color:#1a1a1a;`">$ctx</span>" +
            "<span class=`"pm-muted`" style=`"display:block;font-size:12px;color:#525252;margin-top:2px;`"><span style=`"$sigilStyle`" aria-label=`"$sigilAria`">$sigilChar</span> $shortDesc</span>"
        } else {
            "<span class=`"pm-text`" style=`"display:block;font-size:13px;color:#1a1a1a;`"><span style=`"$sigilStyle`" aria-label=`"$sigilAria`">$sigilChar</span> $desc</span>"
        }

        "<tr><td style=`"padding:2px 32px;`">" +
        "<div class=`"pm-card`" style=`"$cardStyle`"><div style=`"$headerStyle`">$headerHtml</div>" +
        $diffContent +
        "</div></td></tr>"
    }

    # Top-level section header (CHANGES, ACCESS MODEL) — bold sans, brand-amber underline.
    # Kept inline as a closure so the style stays in one place and dark-mode classes apply.
    $renderSectionHeader = {
        param([string]$label)
        $style = "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:15px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:#1a1a1a;border-bottom:2px solid #d97706;padding:0 0 6px;"
        "<tr><td class=`"pm-section-hd`" style=`"padding:28px 32px 0;`"><div class=`"pm-text`" style=`"$style`">$label</div></td></tr>"
    }

    # Sub-section label under a parent (Compliance / Coverage). Amber brand accent, equal weight.
    $renderSubLabel = {
        param([string]$label)
        $style = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:#d97706;"
        "<tr><td style=`"padding:16px 32px 6px;`"><div style=`"$style`">$label</div></td></tr>"
    }

    # Pass 1 — Git changes (was / changed to)
    $rows = @()
    $hasGitChanges = $false
    $gitRows = @()
    foreach ($severity in $script:SeverityOrder) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        $gitItems = @($ChangesBySeverity.$severity | Where-Object { -not $complianceTypes.Contains($_['fileType']) })
        if ($gitItems.Count -eq 0) { continue }
        $hasGitChanges = $true

        $bc  = $sevBorder[$severity]
        $bg  = $sevBgLight[$severity]
        $lc  = $sevLabelLight[$severity]
        $sevClass = "pm-sev-$($severity.ToLower())"

        $labelStyle = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:$lc;"
        $gitRows += "<tr><td style=`"padding:14px 32px 6px;`"><div class=`"$sevClass`" style=`"$labelStyle`">$severity ($($gitItems.Count))</div></td></tr>"

        foreach ($change in @($gitItems | Sort-Object { $_['changeType'] })) {
            $gitRows += & $renderChangeItem $change $bc $bg 'was' 'changed to'
        }
        $gitRows += '<tr><td style="padding:6px 0;"></td></tr>'
    }
    if ($hasGitChanges) {
        $rows += & $renderSectionHeader 'Changes'
        $rows += $gitRows
    }

    # Access Model parent section (Compliance + Coverage live underneath)
    $hasComplianceItems = $complianceCount -gt 0
    $hasCoverageItems   = $cov -gt 0
    if ($hasComplianceItems -or $hasCoverageItems) {
        $rows += & $renderSectionHeader 'Access Model'
    }

    # Pass 2 — Access Model > Compliance (actual / expected)
    if ($hasComplianceItems) {
        $rows += & $renderSubLabel 'Compliance'
        foreach ($severity in $script:SeverityOrder) {
            if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
            $compItems = @($ChangesBySeverity.$severity | Where-Object { $complianceTypes.Contains($_['fileType']) })
            if ($compItems.Count -eq 0) { continue }

            $bc  = $sevBorder[$severity]
            $bg  = $sevBgLight[$severity]
            $lc  = $sevLabelLight[$severity]
            $sevClass = "pm-sev-$($severity.ToLower())"

            $labelStyle = "font-family:'Courier New','Lucida Console',monospace;font-size:11px;letter-spacing:0.15em;text-transform:uppercase;color:$lc;"
            $rows += "<tr><td style=`"padding:14px 32px 6px;`"><div class=`"$sevClass`" style=`"$labelStyle`">$severity ($($compItems.Count))</div></td></tr>"

            foreach ($change in @($compItems | Sort-Object { $_['changeType'] })) {
                $rows += & $renderChangeItem $change $bc $bg 'actual' 'expected'
            }
            $rows += '<tr><td style="padding:6px 0;"></td></tr>'
        }
    }

    # Pass 3 — Access Model > Coverage (unclassified roles, flat list, no diff blocks)
    if ($hasCoverageItems) {
        $rows += & $renderSubLabel "Coverage ($cov)"
        $rows += "<tr><td class=`"pm-muted`" style=`"padding:0 32px 8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#737373;`">Roles in inventory not in any access model definition. Add to <code>AccessModel/*.json</code> or <code>AccessModel/coverage-exclusions.json</code> to suppress.</td></tr>"

        foreach ($change in @($ChangesBySeverity.Coverage | Sort-Object { $_['context'] })) {
            $ctx  = [System.Web.HttpUtility]::HtmlEncode($change['context'])
            $id   = if ($change['entity']) { [System.Web.HttpUtility]::HtmlEncode($change['entity']) } else { '' }
            $rows += "<tr><td style=`"padding:1px 32px;`">" +
                "<div class=`"pm-card`" style=`"border-left:3px solid #525252;background-color:#f9fafb;border-radius:0 3px 3px 0;padding:8px 14px;`">" +
                "<span class=`"pm-text`" style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:14px;font-weight:600;color:#1a1a1a;`">$ctx</span>" +
                $(if ($id) { "<span class=`"pm-muted`" style=`"display:block;font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#737373;margin-top:2px;`">$id</span>" } else { '' }) +
                "</div></td></tr>"
        }
        $rows += '<tr><td style="padding:6px 0;"></td></tr>'
    }

    $sectionsHtml = $rows -join ''

    # Bulletproof button (table + VML for Outlook desktop). Renders inside an outer <tr>.
    $buttonHtml = ''
    if ($CommitUrl) {
        $safeUrl   = [System.Web.HttpUtility]::HtmlAttributeEncode($CommitUrl)
        $btnColor  = '#d97706'
        $btnLabel  = 'View diff'
        $buttonHtml = @"
<tr><td style="padding:16px 32px 4px;">
  <!--[if mso]>
  <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="$safeUrl" style="height:36px;v-text-anchor:middle;width:140px;" arcsize="10%" strokecolor="$btnColor" fillcolor="$btnColor">
    <w:anchorlock/>
    <center style="color:#ffffff;font-family:Arial,sans-serif;font-size:12px;font-weight:bold;letter-spacing:1px;">$btnLabel</center>
  </v:roundrect>
  <![endif]-->
  <!--[if !mso]><!-- -->
  <a href="$safeUrl" style="background-color:$btnColor;border:1px solid $btnColor;border-radius:4px;color:#ffffff;display:inline-block;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:12px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;line-height:36px;text-align:center;text-decoration:none;width:140px;-webkit-text-size-adjust:none;">$btnLabel</a>
  <!--<![endif]-->
</td></tr>
"@
    }

    # Executive summary: one sentence describing the scan outcome at a glance.
    $tenantNameEnc = if ($TenantName) { [System.Web.HttpUtility]::HtmlEncode($TenantName) } else { '' }
    $execLine = Get-ExecutiveSummaryLine -ChangesBySeverity $ChangesBySeverity -TenantName $TenantName
    $execLine = [System.Web.HttpUtility]::HtmlEncode($execLine)

    # Preheader: hidden inbox-preview text (~90 chars). Format: count-by-severity + tenant.
    $preheaderParts = @()
    if ($hi  -gt 0) { $preheaderParts += "${hi}H" }
    if ($med -gt 0) { $preheaderParts += "${med}M" }
    if ($lo  -gt 0) { $preheaderParts += "${lo}L" }
    if ($inf -gt 0) { $preheaderParts += "${inf}I" }
    if ($cov -gt 0) { $preheaderParts += "${cov}C" }
    $preheaderCore = if ($preheaderParts.Count -gt 0) { ($preheaderParts -join ' / ') } else { '0 changes' }
    $preheaderText = "$preheaderCore detected$(if ($tenantNameEnc) { " in $tenantNameEnc" }) at $timestamp"

    # Tenant subline in header
    $tenantHeaderHtml = if ($tenantNameEnc) {
        "<div class=`"pm-muted`" style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:12px;color:#525252;margin-top:2px;`">$tenantNameEnc</div>"
    } else { '' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>PIM Monitor change report</title>
<style>
  /* Dark-mode overrides — !important so they beat inline color styles that older email
     clients (and Outlook) need for baseline rendering. Severity tones (red/amber/green/zinc)
     swap to the brighter dark-mode variants from docs/Design/visual-style-guide.md. */
  @media (prefers-color-scheme: dark) {
    .pm-bg          { background-color: #0a0a0a !important; }
    .pm-card-bg    { background-color: #18181b !important; border-color: #27272a !important; }
    .pm-band       { background-color: #18181b !important; border-color: #27272a !important; }
    .pm-text       { color: #e5e5e5 !important; }
    .pm-muted      { color: #a1a1aa !important; }
    .pm-border     { border-color: #27272a !important; }
    .pm-card       { background-color: #1f1f23 !important; }
    .pm-sev-high          { color: #ef4444 !important; }
    .pm-sev-medium        { color: #d97706 !important; }
    .pm-sev-low           { color: #22c55e !important; }
    .pm-sev-informational { color: #a1a1aa !important; }
  }
  /* Outlook.com dark-mode targeting */
  [data-ogsc] .pm-bg          { background-color: #0a0a0a !important; }
  [data-ogsc] .pm-card-bg    { background-color: #18181b !important; border-color: #27272a !important; }
  [data-ogsc] .pm-band       { background-color: #18181b !important; border-color: #27272a !important; }
  [data-ogsc] .pm-text       { color: #e5e5e5 !important; }
  [data-ogsc] .pm-muted      { color: #a1a1aa !important; }
  [data-ogsc] .pm-border     { border-color: #27272a !important; }
  [data-ogsc] .pm-card       { background-color: #1f1f23 !important; }
  [data-ogsc] .pm-sev-high          { color: #ef4444 !important; }
  [data-ogsc] .pm-sev-medium        { color: #d97706 !important; }
  [data-ogsc] .pm-sev-low           { color: #22c55e !important; }
  [data-ogsc] .pm-sev-informational { color: #a1a1aa !important; }
</style>
</head>
<body class="pm-bg" style="margin:0;padding:0;background-color:#fafafa;">
<span class="pm-muted" style="display:none!important;visibility:hidden;opacity:0;color:transparent;height:0;width:0;overflow:hidden;mso-hide:all;">$([System.Web.HttpUtility]::HtmlEncode($preheaderText))</span>
<table role="presentation" class="pm-bg" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fafafa;"><tr><td align="center" style="padding:24px 16px;">
<table role="presentation" class="pm-card-bg pm-border" width="600" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;background-color:#ffffff;border:1px solid #e5e5e5;border-radius:4px;">
<tr><td style="padding:28px 32px 16px;">
  <div style="font-family:'Courier New','Lucida Console',monospace;font-size:20px;font-weight:600;letter-spacing:-0.01em;color:#d97706;">pim/monitor</div>
  <div class="pm-muted" style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#a3a3a3;margin-top:4px;letter-spacing:0.12em;text-transform:uppercase;">change report</div>
  $tenantHeaderHtml
</td></tr>
<tr><td class="pm-band pm-border" style="padding:16px 32px;background-color:#fafafa;border-top:1px solid #e5e5e5;border-bottom:1px solid #e5e5e5;">
  <div class="pm-text" style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.5;color:#1a1a1a;">$execLine</div>
  <div class="pm-muted" style="font-family:'Courier New','Lucida Console',monospace;font-size:11px;color:#737373;margin-top:6px;letter-spacing:0.04em;">Scan completed $timestamp$(if ($CommitUrl) { " · commit linked below" })</div>
</td></tr>
<tr><td class="pm-band pm-border" style="padding:14px 32px;background-color:#fafafa;border-bottom:1px solid #e5e5e5;">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
    <td class="pm-muted" style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Total <b class="pm-text" style="color:#0a0a0a;">$tot</b></td>
    <td class="$(if ($hi  -gt 0) { 'pm-sev-high' }  else { 'pm-muted' })" style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$hiColor;" aria-label="High severity count">High $hi</td>
    <td class="$(if ($med -gt 0) { 'pm-sev-medium' } else { 'pm-muted' })" style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$medColor;" aria-label="Medium severity count">Medium $med</td>
    <td class="$(if ($lo  -gt 0) { 'pm-sev-low' }    else { 'pm-muted' })" style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$loColor;" aria-label="Low severity count">Low $lo</td>
    <td class="pm-muted" style="padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;color:#525252;">Info $inf</td>
    $(if ($cov -gt 0) { "<td class=`"pm-sev-medium`" style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:13px;font-weight:600;color:$covColor;`" aria-label=`"Classification coverage count`">Classification $cov</td>" })
  </tr></table>
  $(if ($complianceCount -gt 0) { "<table role=`"presentation`" cellpadding=`"0`" cellspacing=`"0`" border=`"0`" style=`"margin-top:6px;`"><tr><td class=`"pm-muted`" style=`"padding-right:16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#525252;`">Git <b class=`"pm-text`" style=`"color:#0a0a0a;`">$gitCount</b></td><td class=`"pm-muted`" style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;font-size:11px;color:#525252;`">Compliance <b class=`"pm-text`" style=`"color:#0a0a0a;`">$complianceCount</b></td></tr></table>" })
</td></tr>
$sectionsHtml
$buttonHtml
<tr><td class="pm-border" style="padding:20px 32px 24px;border-top:1px solid #e5e5e5;">
  <div class="pm-muted" style="font-family:'Courier New','Lucida Console',monospace;font-size:10px;color:#a3a3a3;letter-spacing:0.06em;">PIM Monitor · automated scan notification</div>
</td></tr>
</table>
</td></tr></table>
</body>
</html>
"@
}
