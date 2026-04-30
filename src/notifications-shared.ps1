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
        [string] $CommitUrl
    )

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

    $html = @()
    $html += '<table style="font-family:sans-serif;font-size:13px;border-collapse:collapse;width:100%;margin:12px 0;">'

    foreach ($severity in @('High', 'Medium', 'Low', 'Informational')) {
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }
        if (-not $ChangesBySeverity[$severity]) { continue }

        $bgColor = @{ High = '#fca5a5'; Medium = '#fcd34d'; Low = '#d1d5db'; Informational = '#bfdbfe' }[$severity]
        $textColor = @{ High = '#7f1d1d'; Medium = '#78350f'; Low = '#1f2937'; Informational = '#1e3a8a' }[$severity]

        $html += "<tr style='background:$bgColor;'>"
        $html += "  <td colspan='2' style='padding:8px;font-weight:600;color:$textColor;'>$severity</td>"
        $html += "</tr>"

        foreach ($item in $ChangesBySeverity[$severity]) {
            $ctx      = if ($item.context) { [System.Web.HttpUtility]::HtmlEncode($item.context) } else { '' }
            $shortDesc = if ($item.context) {
                [System.Web.HttpUtility]::HtmlEncode(($item.description -replace '\s*\([^)]*\)\s*$', ''))
            } else {
                [System.Web.HttpUtility]::HtmlEncode($item.description)
            }
            $html += "<tr style='border-bottom:1px solid #e5e7eb;'>"
            $html += "  <td style='padding:6px 8px;font-weight:600;width:25%;'>$ctx</td>"
            $html += "  <td style='padding:6px 8px;'>$shortDesc</td>"
            $html += "</tr>"
        }
    }

    $html += '</table>'

    if ($CommitUrl) {
        $safeUrl = [System.Web.HttpUtility]::HtmlAttributeEncode($CommitUrl)
        $html += "<p style='font-family:sans-serif;font-size:11px;color:#6b7280;margin:4px 0;'>" +
            "<a href='$safeUrl' style='color:#6b7280;'>View diff</a></p>"
    }

    return $html -join "`n"
}
