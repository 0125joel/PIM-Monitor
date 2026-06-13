<#
.SYNOPSIS
    Shared notification formatting helpers for PIM Monitor.

.DESCRIPTION
    Centralized severity ranking and change formatting functions used by all notification channels
    (email, webhook, HTML reports). Dot-source after helpers.ps1.
#>

Add-Type -AssemblyName System.Web

$script:SeverityRank = @{ High = 3; Medium = 2; Low = 1; Informational = 0 }
$script:SeverityOrder = @('High', 'Medium', 'Low', 'Informational')

# Compliance fileTypes — shared by all notification renderers (email, Teams, Slack, Discord, HTML report).
# Items with these fileTypes render under the Access Model > Compliance sub-section with actual/expected
# diff labels. Everything else renders under CHANGES with was/changed to labels.
$script:ComplianceFileTypes = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('access-model-compliance', 'access-model-coverage', 'group-compliance', 'group-coverage', 'auth-context-policy-compliance'),
    [System.StringComparer]::OrdinalIgnoreCase
)

<#
.SYNOPSIS
    Returns the branch the scan runs on, for building repo links.

.DESCRIPTION
    Mirrors the branch resolution in Publish-InventoryChanges (git.ps1): ADO sets
    BUILD_SOURCEBRANCHNAME, GHA sets GITHUB_REF_NAME, fallback 'main'. Keeping both
    resolutions identical guarantees notification links point at the branch the
    scan commit was actually pushed to.
#>
function Get-ScanBranchName {
    [CmdletBinding()]
    param()

    if ($env:BUILD_SOURCEBRANCHNAME) { return $env:BUILD_SOURCEBRANCHNAME }
    if ($env:GITHUB_REF_NAME)        { return $env:GITHUB_REF_NAME }
    return 'main'
}

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
        $branch = Get-ScanBranchName
        $refName = [uri]::EscapeDataString("refs/heads/$branch")
        return "$baseUri/commit/${CommitSha}?refName=$refName"
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
    Constructs a deep-link to a single inventory file in the repo at a given commit.

.DESCRIPTION
    Mirrors Get-CommitDiffUrl: detects Azure DevOps or GitHub from environment
    variables and builds a tree-view URL to a specific path. Returns $null
    when the platform cannot be determined or required inputs are missing.

.PARAMETER RelativePath
    Repo-relative path, e.g. "inventory/directory-roles/global-administrator/policy.json".

.PARAMETER CommitSha
    The commit SHA to anchor the link to. Optional; falls back to default branch.
#>
function Get-InventoryFileUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,
        [string] $CommitSha
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    $safePath = ($RelativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

    if ($env:BUILD_REPOSITORY_URI) {
        $baseUri = $env:BUILD_REPOSITORY_URI -replace 'https://[^@]+@', 'https://'
        $version = if ($CommitSha) { "GC$CommitSha" } else { "GB$(Get-ScanBranchName)" }
        return "$baseUri`?path=/$safePath&version=$([uri]::EscapeDataString($version))"
    }
    elseif ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
        $ref = if ($CommitSha) { $CommitSha } else { Get-ScanBranchName }
        return "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/blob/$ref/$safePath"
    }
    return $null
}

<#
.SYNOPSIS
    Builds a Build Results URL for the current pipeline run, when REPORT_ARTIFACT is enabled.

.DESCRIPTION
    Returns a URL where reviewers can find the HTML scan report artifact. Detects Azure
    DevOps and GitHub Actions from environment variables. Returns $null when REPORT_ARTIFACT
    is not 'true' or when required env vars are missing — callers must handle null.

    Used by notification builders to add an "Open HTML Report" button when applicable.
#>
function Get-ArtifactReportUrl {
    [CmdletBinding()]
    param()

    # Honour the same gate as the artifact-emit step. If the operator did not enable
    # report generation, the URL would 404 and we should not advertise it.
    if ($env:REPORT_ARTIFACT -ne 'true') { return $null }

    if ($env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI -and $env:SYSTEM_TEAMPROJECT -and $env:BUILD_BUILDID) {
        $org     = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI.TrimEnd('/')
        $project = [uri]::EscapeDataString($env:SYSTEM_TEAMPROJECT)
        return "$org/$project/_build/results?buildId=$($env:BUILD_BUILDID)&view=artifacts&pathAsName=false&type=publishedArtifacts"
    }
    elseif ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
        return "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    }
    return $null
}

<#
.SYNOPSIS
    Constructs a file-anchored diff URL for a specific file within a commit.

.DESCRIPTION
    Like Get-InventoryFileUrl, but anchors to the diff of that specific file
    within the commit page, rather than the file tree view.
    GitHub: appends #diff-{sha256(path)} anchor (matches GitHub's current diff anchor scheme).
    Azure DevOps: uses ?path=...&_a=compare to open file-diff view.

.PARAMETER RelativePath
    Repo-relative path, e.g. "inventory/directory-roles/global-administrator/policy.json".

.PARAMETER CommitSha
    The commit SHA to anchor the diff to.
#>
function Get-FileDiffUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CommitSha,
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    $safePath = ($RelativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

    if ($env:BUILD_REPOSITORY_URI) {
        $baseUri = $env:BUILD_REPOSITORY_URI -replace 'https://[^@]+@', 'https://'
        return "$baseUri/commit/$CommitSha`?path=/$safePath&_a=compare"
    }
    elseif ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
        $sha256    = [System.Security.Cryptography.SHA256]::Create()
        $bytes     = [System.Text.Encoding]::UTF8.GetBytes($RelativePath)
        $hash      = $sha256.ComputeHash($bytes)
        $sha256.Dispose()
        $hexAnchor = -join ($hash | ForEach-Object { $_.ToString('x2') })
        return "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/commit/$CommitSha#diff-$hexAnchor"
    }
    return $null
}

<#
.SYNOPSIS
    Maps a severity label to a 24-bit RGB integer (Discord embed color format).

.DESCRIPTION
    Values follow the PIM Monitor design palette (see docs/Design/visual-style-guide.md).
    Unknown severities fall back to the Informational zinc. Used by Discord
    embeds and any future channel that consumes integer colors.
#>
function Get-SeverityColorInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Severity
    )

    switch ($Severity) {
        'High'          { return 15684676 } # #EF4444 red
        'Medium'        { return 14251270 } # #D97706 amber
        'Low'           { return  2278750 } # #22C55E green
        'Informational' { return  7566195 } # #737373 zinc-light
        'Coverage'      { return  5395026 } # #525252 zinc-mid
        'AccessModel'   { return 14251270 } # brand amber for parent
        default         { return  7566195 } # zinc-light
    }
}

<#
.SYNOPSIS
    Builds a one-sentence executive summary of a scan's outcome.

.DESCRIPTION
    Shared across email, Teams, Slack so wording stays consistent. The first non-zero
    severity bucket dictates the lead phrase. Tenant clause is appended when supplied.
#>
function Get-ExecutiveSummaryLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ChangesBySeverity,
        [string] $TenantName
    )

    $hi  = $ChangesBySeverity.High.Count
    $med = $ChangesBySeverity.Medium.Count
    $lo  = $ChangesBySeverity.Low.Count
    $inf = $ChangesBySeverity.Informational.Count
    $cov = if ($ChangesBySeverity['Coverage']) { $ChangesBySeverity.Coverage.Count } else { 0 }
    $tot = $hi + $med + $lo + $inf + $cov

    $tenantClause = if ($TenantName) { " in tenant $TenantName" } else { '' }

    if ($hi -gt 0) {
        return "$hi High-severity change(s) require review$tenantClause."
    }
    if ($med -gt 0) {
        return "$med Medium-severity change(s) detected$tenantClause."
    }
    if ($lo -gt 0 -or $inf -gt 0 -or $cov -gt 0) {
        return "$tot change(s) detected$tenantClause; none at High severity."
    }
    return "Scan complete$tenantClause; no qualifying changes."
}

<#
.SYNOPSIS
    Formats a single value for inclusion in a diff line.

.DESCRIPTION
    Shared scalar/dict/array formatter used by every notification renderer
    (email, Teams, Slack, Discord). Returns a short, human-readable string.
    Null becomes '(none)', booleans render lowercase, dictionaries with a
    'displayName' key collapse to that name, long JSON is truncated.
#>
function Format-DiffValue {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] $Value,
        [hashtable] $AuthContextLookup = @{}
    )

    if ($null -eq $Value) { return '(none)' }
    if ($Value -is [bool])   { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) {
        # Resolve CA auth context claim IDs (e.g. "c2") to display names when a lookup is available.
        if ($AuthContextLookup -and $AuthContextLookup.Count -gt 0 -and $Value -in $AuthContextLookup.Keys) {
            return "$($AuthContextLookup[$Value]) ($Value)"
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('displayName')) { return [string]$Value['displayName'] }
        $json = $Value | ConvertTo-Json -Depth 2 -Compress
        if ($json.Length -gt 120) { return $json.Substring(0, 100) + '...' }
        return $json
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @($Value); if ($arr.Count -eq 0) { return '(empty)' }
        $result = ($arr | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Depth 2 -Compress } }) -join ', '
        if ($result.Length -gt 120) { return $result.Substring(0, 100) + '...' }
        return $result
    }
    $json = $Value | ConvertTo-Json -Depth 3 -Compress
    if ($json.Length -gt 120) { return $json.Substring(0, 100) + '...' }
    return $json
}

<#
.SYNOPSIS
    Returns $true when a value is a primitive (string/bool/number).
#>
function Test-DiffScalar {
    [CmdletBinding()]
    param($Value)
    return $Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]
}

<#
.SYNOPSIS
    Recursively expands a property pair into rows for a diff renderer.

.DESCRIPTION
    Walks dictionary structures and yields one hashtable per leaf change:
    @{ Key = 'a.b.c'; Actual = '...'; New = '...' }.
    Dictionaries with no per-key change are skipped. Used by every notification
    builder so the diff semantics stay identical across channels.
#>
function Get-DiffPropertyRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Key,
        $OldValue,
        $NewValue
    )

    $diffMode  = $null -ne $OldValue -and $null -ne $NewValue
    $oldIsDict = $OldValue -is [System.Collections.IDictionary]
    $newIsDict = $NewValue -is [System.Collections.IDictionary]

    if ($oldIsDict -or $newIsDict) {
        $oldDict = if ($oldIsDict) { $OldValue } else { [ordered]@{} }
        $newDict = if ($newIsDict) { $NewValue } else { [ordered]@{} }
        $allSubs = @(@($oldDict.Keys) + @($newDict.Keys)) | Sort-Object -Unique
        $rows    = [System.Collections.Generic.List[object]]::new()
        foreach ($sk in $allSubs) {
            $sov = if ($sk -in $oldDict.Keys) { $oldDict[$sk] } else { $null }
            $snv = if ($sk -in $newDict.Keys) { $newDict[$sk] } else { $null }
            if ($diffMode -and (ConvertTo-DeterministicJson -InputObject $sov) -eq (ConvertTo-DeterministicJson -InputObject $snv)) { continue }
            foreach ($r in @(Get-DiffPropertyRows -Key "$Key.$sk" -OldValue $sov -NewValue $snv)) { $rows.Add($r) }
        }
        return $rows.ToArray()
    }
    if ($diffMode)            { return ,@{ Key = $Key; Actual = (Format-DiffValue $OldValue); New = (Format-DiffValue $NewValue) } }
    if ($null -ne $NewValue)  { return ,@{ Key = $Key; Actual = '(none)';                     New = (Format-DiffValue $NewValue) } }
    if ($null -ne $OldValue)  { return ,@{ Key = $Key; Actual = (Format-DiffValue $OldValue); New = '(removed)' } }
    return @()
}

<#
.SYNOPSIS
    Collects up to $MaxRows diff rows for a single change object.

.DESCRIPTION
    Reads $change.old and $change.new, JSON-roundtrips them to hashtables so
    enumeration is stable, skips ignored properties, and returns at most
    $MaxRows rows. Shared by webhook payload builders.
#>
function Get-ChangeDiffRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Change,
        [int] $MaxRows = 5
    )

    $ignore = [System.Collections.Generic.HashSet[string]]::new($script:DiffIgnoreProperties, [System.StringComparer]::OrdinalIgnoreCase)
    $rows   = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $Change.old -and $null -ne $Change.new) {
        if ((Test-DiffScalar $Change.old) -and (Test-DiffScalar $Change.new)) {
            return ,@{ Key = 'value'; Actual = (Format-DiffValue $Change.old); New = (Format-DiffValue $Change.new) }
        }
        try {
            $oh = $Change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
            $nh = $Change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
            foreach ($k in (@(@($oh.Keys) + @($nh.Keys)) | Sort-Object -Unique)) {
                if ($rows.Count -ge $MaxRows) { break }
                if ($ignore.Contains($k)) { continue }
                $ov = if ($k -in $oh.Keys) { $oh[$k] } else { $null }
                $nv = if ($k -in $nh.Keys) { $nh[$k] } else { $null }
                if ((ConvertTo-DeterministicJson -InputObject $ov) -eq (ConvertTo-DeterministicJson -InputObject $nv)) { continue }
                foreach ($r in @(Get-DiffPropertyRows -Key $k -OldValue $ov -NewValue $nv)) {
                    if ($rows.Count -ge $MaxRows) { break }
                    $rows.Add($r)
                }
            }
        } catch {}
    } elseif ($null -ne $Change.new) {
        try {
            $nh = $Change.new | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
            foreach ($k in ($nh.Keys | Sort-Object)) {
                if ($rows.Count -ge $MaxRows) { break }
                if ($ignore.Contains($k)) { continue }
                foreach ($r in @(Get-DiffPropertyRows -Key $k -OldValue $null -NewValue $nh[$k])) {
                    if ($rows.Count -ge $MaxRows) { break }
                    $rows.Add($r)
                }
            }
        } catch {}
    } elseif ($null -ne $Change.old) {
        try {
            $oh = $Change.old | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
            foreach ($k in ($oh.Keys | Sort-Object)) {
                if ($rows.Count -ge $MaxRows) { break }
                if ($ignore.Contains($k)) { continue }
                foreach ($r in @(Get-DiffPropertyRows -Key $k -OldValue $oh[$k] -NewValue $null)) {
                    if ($rows.Count -ge $MaxRows) { break }
                    $rows.Add($r)
                }
            }
        } catch {}
    }
    return $rows.ToArray()
}

<#
.SYNOPSIS
    Maps a change object to the v1 generic-webhook payload form.

.DESCRIPTION
    Returns a hashtable with the essential fields per change (severity,
    changeType, fileType, description, optional context/roleId/groupId).
    Null/empty optional fields are omitted so the JSON stays minimal.
    Used by Build-GenericPayload; intentionally not channel-specific.
#>
function ConvertTo-ChangePayloadObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Change)

    $obj = [ordered]@{
        severity    = [string]$Change.severity
        changeType  = [string]$Change['changeType']
        fileType    = [string]$Change['fileType']
        description = [string]$Change.description
    }
    if ($Change['context']) { $obj['context'] = [string]$Change['context'] }
    if ($Change['roleId'])  { $obj['roleId']  = [string]$Change['roleId'] }
    if ($Change['groupId']) { $obj['groupId'] = [string]$Change['groupId'] }
    return $obj
}

<#
.SYNOPSIS
    Builds the scan-metadata block (timestamp + commit + minSeverity) for the
    v1 generic-webhook payload.

.DESCRIPTION
    Timestamp is generated at call time (ISO 8601 UTC). CommitSha is omitted
    when not supplied so the JSON does not carry empty strings.
#>
function Get-ScanMetadata {
    [CmdletBinding()]
    param(
        [string] $CommitSha,
        [string] $MinSeverity = 'Medium'
    )

    $meta = [ordered]@{
        timestamp   = Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ'
        minSeverity = $MinSeverity
    }
    if ($CommitSha) { $meta['commitSha'] = $CommitSha }
    return $meta
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

    foreach ($severity in $script:SeverityOrder) {
        if (-not $ChangesBySeverity[$severity]) { continue }
        if ($script:SeverityRank[$severity] -lt $script:SeverityRank[$MinSeverity]) { continue }

        $lines += "$($severity):"
        foreach ($item in $ChangesBySeverity[$severity]) {
            $lines += "  — $($item.description)"
        }
        $lines += ""
    }

    $covItems = @()
    if ($ChangesBySeverity['Coverage']) { $covItems = @($ChangesBySeverity.Coverage) }
    if ($covItems.Count -gt 0) {
        $lines += "Access Model Coverage ($($covItems.Count)):"
        $lines += "  Roles not in any access model definition — add to AccessModel/*.json or AccessModel/coverage-exclusions.json:"
        foreach ($item in ($covItems | Sort-Object { $_['context'] })) {
            $lines += "  — $($item['context'])"
        }
        $lines += ""
    }

    return $lines -join "`n"
}

<#
.SYNOPSIS
    Counts changes by severity from a grouped changes hashtable.

.DESCRIPTION
    Extracts High, Medium, Low, and Informational counts from a ChangesBySeverity hashtable
    for use in summary statistics. Handles missing severity buckets gracefully.

.PARAMETER ChangesBySeverity
    Hashtable with High, Medium, Low, Informational, Coverage, and Total keys.

.EXAMPLE
    $counts = Get-ChangeCounts -ChangesBySeverity $changesBySeverity
    "Changes: H=$($counts.High) M=$($counts.Medium) L=$($counts.Low) I=$($counts.Informational)"
#>
function Get-ChangeCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $ChangesBySeverity
    )

    return @{
        High          = @($ChangesBySeverity['High']).Count
        Medium        = @($ChangesBySeverity['Medium']).Count
        Low           = @($ChangesBySeverity['Low']).Count
        Informational = @($ChangesBySeverity['Informational']).Count
    }
}

