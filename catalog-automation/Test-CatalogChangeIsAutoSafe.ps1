#requires -Version 7.0
<#
.SYNOPSIS
    Deterministic gate for catalog changes proposed by the weekly review routine.

.DESCRIPTION
    Decides what may happen to a catalog PR without a person: the routine proposes, this script
    decides. The rule is asymmetric: a change may only make protection stricter, or add a flagged
    new role. Anything that lowers protection waits, anything unexpected needs a person.

    Verdicts (the strictest one found wins):
      merge-now   only additions and tightenings
      wait        a lowering (level, plane change, removed role): merge after the cooling period
      human       anything else: stays a normal PR for a person

    Checks:
      - changed files are only catalog outputs and the review state file
      - every role in the head catalog follows the floor: isPrivileged = true means Privileged
      - every role's expectedConfig is the level default (levels[] in the defaults file)
      - levels, groups and authContexts in the defaults file are unchanged (those are policy)
      - new roles carry reviewNeeded = true

.PARAMETER BaseCatalogPath / HeadCatalogPath
    eam-role-catalog.json before and after.

.PARAMETER BaseDefaultsPath / HeadDefaultsPath
    eam-catalog-defaults.json before and after.

.PARAMETER ChangedFiles
    Repo-relative paths changed by the PR.

.PARAMETER SnapshotDir
    Current role snapshot (entra-role-export branch). When given, the catalog must agree with it:
    every snapshot role is listed with the same isPrivileged value. This stops a proposal from
    leaving a privileged role at a lower level by copying the flag wrongly.

.OUTPUTS
    Object with verdict and reasons.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseCatalogPath,
    [Parameter(Mandatory)] [string] $HeadCatalogPath,
    [Parameter(Mandatory)] [string] $BaseDefaultsPath,
    [Parameter(Mandatory)] [string] $HeadDefaultsPath,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ChangedFiles,
    [Parameter()] [string] $SnapshotDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$levelRank = @{ Privileged = 0; Specialized = 1; Enterprise = 2 }   # lower number is stricter
$allowedFilePatterns = @(
    '^docs-site/src/data/eam-role-catalog\.json$'
    '^docs-site/src/data/eam-catalog-defaults\.json$'
    '^docs-site/src/data/eam-review-state\.json$'
    '^docs-site/static/catalog/v1/eam-catalog\.json$'
    '^Examples/access-model/[A-Za-z]+/(Privileged|Specialized|Enterprise)\.json$'
)
$policyFields = 'maxActivationDuration', 'requireMFA', 'authContext', 'requireJustification', 'requireApproval'

$human = [System.Collections.Generic.List[string]]::new()
$wait = [System.Collections.Generic.List[string]]::new()

foreach ($f in $ChangedFiles) {
    $path = ($f -replace '\\', '/').Trim()
    if (-not $path) { continue }
    if (-not ($allowedFilePatterns | Where-Object { $path -match $_ })) { $human.Add("File outside the catalog outputs: $path") }
}

$baseCatalog = Get-Content -Raw -Path $BaseCatalogPath | ConvertFrom-Json
$headCatalog = Get-Content -Raw -Path $HeadCatalogPath | ConvertFrom-Json
$baseDefaults = Get-Content -Raw -Path $BaseDefaultsPath | ConvertFrom-Json
$headDefaults = Get-Content -Raw -Path $HeadDefaultsPath | ConvertFrom-Json

foreach ($section in 'levels', 'groups', 'authContexts') {
    $a = $baseDefaults.$section | ConvertTo-Json -Depth 20 -Compress
    $b = $headDefaults.$section | ConvertTo-Json -Depth 20 -Compress
    if ($a -ne $b) { $human.Add("Policy section '$section' changed in the defaults file") }
}

$baseById = @{}
foreach ($r in $baseCatalog.roles) { $baseById[([string]$r.templateId).ToLowerInvariant()] = $r }
$headById = @{}
foreach ($r in $headCatalog.roles) {
    $id = ([string]$r.templateId).ToLowerInvariant()
    if ($headById.ContainsKey($id)) { $human.Add("Duplicate templateId $id") }
    $headById[$id] = $r
}

foreach ($id in $headById.Keys) {
    $r = $headById[$id]
    $name = "$($r.displayName) ($id)"

    if ($r.plane -notin 'Control', 'Management', 'Data' -or $r.securityLevel -notin $levelRank.Keys) {
        $human.Add("$name has a plane or level outside the allowed values"); continue
    }
    if ($r.isPrivileged -and $r.securityLevel -ne 'Privileged') {
        $human.Add("$name is isPrivileged but not Privileged (floor violated)")
    }

    $levelDefault = ($headDefaults.levels | Where-Object { $_.plane -eq $r.plane -and $_.securityLevel -eq $r.securityLevel } | Select-Object -First 1)
    if (-not $levelDefault) { $human.Add("$name has no level default for $($r.plane)/$($r.securityLevel)"); continue }
    foreach ($field in $policyFields) {
        $want = $levelDefault.expectedConfig.PSObject.Properties[$field]?.Value
        $have = $r.expectedConfig.PSObject.Properties[$field]?.Value
        if ("$want" -ne "$have") { $human.Add("$name expectedConfig.$field is '$have', the level default is '$want'") }
    }

    if (-not $baseById.ContainsKey($id)) {
        if (-not $r.reviewNeeded) { $human.Add("New role $name is not flagged reviewNeeded") }
        continue
    }

    $old = $baseById[$id]
    if ($old.plane -ne $r.plane) { $wait.Add("$name plane changed from $($old.plane) to $($r.plane)") }
    if ($levelRank[[string]$r.securityLevel] -gt $levelRank[[string]$old.securityLevel]) {
        $wait.Add("$name level lowered from $($old.securityLevel) to $($r.securityLevel)")
    }
}

foreach ($id in $baseById.Keys) {
    if (-not $headById.ContainsKey($id)) { $wait.Add("Role $($baseById[$id].displayName) ($id) removed") }
}

if ($SnapshotDir) {
    foreach ($file in Get-ChildItem -Path $SnapshotDir -Filter '*.json' -File) {
        $snap = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json
        $id = ([string]$snap.templateId).ToLowerInvariant()
        if (-not $headById.ContainsKey($id)) { $human.Add("Snapshot role $($snap.displayName) ($id) is missing from the catalog"); continue }
        $snapPriv = [bool]($snap.PSObject.Properties['isPrivileged']?.Value)
        if ([bool]$headById[$id].isPrivileged -ne $snapPriv) {
            $human.Add("$($snap.displayName) ($id): catalog isPrivileged is $($headById[$id].isPrivileged), the snapshot says $snapPriv")
        }
    }
}

$verdict = if ($human.Count -gt 0) { 'human' } elseif ($wait.Count -gt 0) { 'wait' } else { 'merge-now' }
[pscustomobject]@{
    verdict = $verdict
    reasons = @($human) + @($wait)
}
