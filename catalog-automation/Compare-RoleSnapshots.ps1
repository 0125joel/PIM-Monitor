#requires -Version 7.0
<#
.SYNOPSIS
    Compares two role snapshots and the catalog, and writes report.json (schemas/role-snapshot-report-v1.json).

.DESCRIPTION
    Deterministic: no judgement here. The routine that reads the report decides plane and level.

      newRoles      roles in the head snapshot that the catalog does not list
      removedRoles  roles the catalog lists that the head snapshot no longer has
      changedRoles  roles whose isPrivileged or allowedResourceActions differ between base and head

    A change is "relevant" when isPrivileged flips or when any added or removed action is not a
    read action (does not end in /read). Read-only changes are counted but not listed in detail.
    The report also carries floorLevel: Privileged when isPrivileged is true, the only fully
    mechanical step of the classification waterfall.

.PARAMETER BaseDir
    Snapshot folder of the last reviewed state. May be missing or empty on the first run.

.PARAMETER HeadDir
    Snapshot folder of the current state.

.PARAMETER CatalogPath
    docs-site/src/data/eam-role-catalog.json.

.PARAMETER OutputPath
    Where to write report.json.
#>
[CmdletBinding()]
param(
    [Parameter()] [string] $BaseDir,
    [Parameter(Mandatory)] [string] $HeadDir,
    [Parameter(Mandatory)] [string] $CatalogPath,
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter()] [string] $BaseSha = '',
    [Parameter()] [string] $HeadSha = '',
    [Parameter()] [datetime] $GeneratedAt = (Get-Date).ToUniversalTime()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Snapshot {
    param([string] $Dir)
    $map = @{}
    if ($Dir -and (Test-Path $Dir -PathType Container)) {
        foreach ($f in Get-ChildItem -Path $Dir -Filter '*.json' -File) {
            $r = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json
            $map[([string]$r.templateId).ToLowerInvariant()] = $r
        }
    }
    return $map
}

function Get-Actions {
    param($Role)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($perm in @($Role.PSObject.Properties['rolePermissions']?.Value)) {
        foreach ($a in @($perm.PSObject.Properties['allowedResourceActions']?.Value)) { if ($a) { [void]$set.Add([string]$a) } }
    }
    return $set
}

function Get-IsPrivileged {
    param($Role)
    [bool]($Role.PSObject.Properties['isPrivileged']?.Value)
}

$base = Read-Snapshot $BaseDir
$head = Read-Snapshot $HeadDir
$catalog = Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json
$catalogById = @{}
foreach ($r in $catalog.roles) { $catalogById[([string]$r.templateId).ToLowerInvariant()] = $r }

$newRoles = foreach ($id in ($head.Keys | Sort-Object)) {
    if ($catalogById.ContainsKey($id)) { continue }
    $role = $head[$id]
    $actions = @(Get-Actions $role | Sort-Object)
    [ordered]@{
        templateId             = $id
        displayName            = [string]$role.displayName
        description            = [string]($role.PSObject.Properties['description']?.Value ?? '')
        isPrivileged           = (Get-IsPrivileged $role)
        floorLevel             = if (Get-IsPrivileged $role) { 'Privileged' } else { $null }
        allowedResourceActions = $actions
    }
}

$removedRoles = foreach ($id in ($catalogById.Keys | Sort-Object)) {
    if ($head.ContainsKey($id)) { continue }
    [ordered]@{
        templateId  = $id
        displayName = [string]$catalogById[$id].displayName
        plane       = [string]$catalogById[$id].plane
        securityLevel = [string]$catalogById[$id].securityLevel
    }
}

$readOnlyChanges = 0
$changedRoles = foreach ($id in ($head.Keys | Sort-Object)) {
    if (-not $base.ContainsKey($id)) { continue }
    $old = Get-Actions $base[$id]
    $new = Get-Actions $head[$id]
    $added = @($new | Where-Object { -not $old.Contains($_) } | Sort-Object)
    $removed = @($old | Where-Object { -not $new.Contains($_) } | Sort-Object)
    $oldPriv = Get-IsPrivileged $base[$id]
    $newPriv = Get-IsPrivileged $head[$id]
    if ($added.Count -eq 0 -and $removed.Count -eq 0 -and $oldPriv -eq $newPriv) { continue }

    $flipped = $oldPriv -ne $newPriv
    $nonRead = @(($added + $removed) | Where-Object { $_ -notmatch '/read$' })
    if (-not $flipped -and $nonRead.Count -eq 0) { $readOnlyChanges++; continue }

    $current = $catalogById[$id]
    [ordered]@{
        templateId       = $id
        displayName      = [string]$head[$id].displayName
        inCatalog        = [bool]$current
        currentPlane     = if ($current) { [string]$current.plane } else { $null }
        currentLevel     = if ($current) { [string]$current.securityLevel } else { $null }
        isPrivileged     = [ordered]@{ old = $oldPriv; new = $newPriv }
        floorLevel       = if ($newPriv) { 'Privileged' } else { $null }
        addedActions     = $added
        removedActions   = $removed
    }
}

$newRoles = @($newRoles)
$removedRoles = @($removedRoles)
$changedRoles = @($changedRoles)

$report = [ordered]@{
    schemaVersion = '1.0.0'
    generatedAt   = $GeneratedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    base          = [ordered]@{ sha = $BaseSha }
    head          = [ordered]@{ sha = $HeadSha }
    summary       = [ordered]@{
        newRoles        = $newRoles.Count
        removedRoles    = $removedRoles.Count
        changedRoles    = $changedRoles.Count
        readOnlyChanges = $readOnlyChanges
        needsReview     = ($newRoles.Count + $removedRoles.Count + $changedRoles.Count) -gt 0
    }
    newRoles      = $newRoles
    removedRoles  = $removedRoles
    changedRoles  = $changedRoles
}

$json = ($report | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
$outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
[System.IO.File]::WriteAllText($OutputPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "Report: $($newRoles.Count) new, $($removedRoles.Count) removed, $($changedRoles.Count) changed (relevant), $readOnlyChanges read-only changes"
