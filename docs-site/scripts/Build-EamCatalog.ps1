#requires -Version 7.0
<#
.SYNOPSIS
    Builds everything derived from the EAM role catalog: the published catalog file and the
    Examples/access-model starter files.

.DESCRIPTION
    Inputs (hand-maintained, the only sources):
      docs-site/src/data/eam-role-catalog.json     per-role plane, level and policy
      docs-site/src/data/eam-catalog-defaults.json catalogVersion, publishedAt, level defaults,
                                                   PIM for Groups defaults, auth context seeds

    Outputs (generated, never edit by hand):
      docs-site/static/catalog/v1/eam-catalog.json  published at https://pimmonitor.com/catalog/v1/eam-catalog.json
      Examples/access-model/<Plane>/<Level>.json    role lists of the starter files

    The outputs are committed. Run this script after you change an input and commit the result.
    tests/EamCatalog.Tests.ps1 runs it with -Check and fails when an output is out of date.

    Bump catalogVersion and publishedAt in eam-catalog-defaults.json when the content of the
    published file changes in a way consumers should notice (a new role, a changed policy).

.PARAMETER Check
    Write nothing. Return the repo-relative paths of outputs that are missing or out of date.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
$catalogPath = Join-Path $repoRoot 'docs-site/src/data/eam-role-catalog.json'
$defaultsPath = Join-Path $repoRoot 'docs-site/src/data/eam-catalog-defaults.json'
$publishedRel = 'docs-site/static/catalog/v1/eam-catalog.json'
$starterRoot = 'Examples/access-model'

$catalog = Get-Content -Raw -Path $catalogPath | ConvertFrom-Json
$defaults = Get-Content -Raw -Path $defaultsPath | ConvertFrom-Json

$planes = @('Control', 'Management', 'Data')
$levels = @('Privileged', 'Specialized', 'Enterprise')
$starterFolder = @{ Control = 'ControlPlane'; Management = 'ManagementPlane'; Data = 'DataWorkloadPlane' }
$planeTitle = @{ Control = 'Control Plane'; Management = 'Management Plane'; Data = 'Data/Workload Plane' }
$newFileDescription = @{
    'Management|Enterprise' = 'Management Plane roles whose permissions are read-only or low impact. Microsoft Graph isPrivileged = false. PIM provides the audit trail; approval overhead is not warranted.'
}

function ConvertTo-StableJson {
    param($InputObject)
    ($InputObject | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
}

# Role fields in the published file, in a fixed order. Sparse: only the fields the catalog sets.
function Get-PublishedRole {
    param($Role)
    $cfg = [ordered]@{}
    foreach ($name in 'maxActivationDuration', 'requireMFA', 'authContext', 'requireJustification', 'requireApproval') {
        if ($Role.expectedConfig.PSObject.Properties.Name -contains $name) { $cfg[$name] = $Role.expectedConfig.$name }
    }
    [ordered]@{
        templateId     = $Role.templateId
        displayName    = $Role.displayName
        plane          = $Role.plane
        securityLevel  = $Role.securityLevel
        isPrivileged   = $Role.isPrivileged
        expectedConfig = $cfg
        note           = $Role.note
        reviewNeeded   = $Role.reviewNeeded
    }
}

function Get-PublishedCatalog {
    $roles = @($catalog.roles | Sort-Object displayName | ForEach-Object { Get-PublishedRole $_ })
    [ordered]@{
        schemaVersion  = '1.0.0'
        catalogVersion = $defaults.catalogVersion
        publishedAt    = $defaults.publishedAt
        source         = [ordered]@{
            repository = 'https://github.com/0125joel/PIM-Monitor'
            path       = 'docs-site/src/data/eam-role-catalog.json'
        }
        roles          = $roles
        levels         = @($defaults.levels)
        groups         = @($defaults.groups)
        authContexts   = @($defaults.authContexts)
    }
}

function Get-StarterFileText {
    param([string]$Plane, [string]$Level)
    $roles = @($catalog.roles | Where-Object { $_.plane -eq $Plane -and $_.securityLevel -eq $Level } | Sort-Object displayName)
    if ($roles.Count -eq 0) { return $null }

    $relPath = "$starterRoot/$($starterFolder[$Plane])/$Level.json"
    $existing = Join-Path $repoRoot $relPath
    $name = "$($planeTitle[$Plane]) - $Level"
    $description = $newFileDescription["$Plane|$Level"]
    if (Test-Path $existing) {
        $old = Get-Content -Raw -Path $existing | ConvertFrom-Json
        $name = $old.name
        $description = $old.description
    }
    if (-not $description) { throw "No description for new starter file $relPath. Add one to `$newFileDescription." }

    $config = ($defaults.levels | Where-Object { $_.plane -eq $Plane -and $_.securityLevel -eq $Level }).expectedConfig
    $configJson = (ConvertTo-StableJson $config) -split "`n" | ForEach-Object { "  $_" }
    $configJson[0] = $configJson[0].TrimStart()

    $roleLines = $roles | ForEach-Object {
        $n = $_.displayName | ConvertTo-Json -Compress
        "    { `"id`": `"$($_.templateId)`", `"displayName`": $n }"
    }
    $lines = @(
        '{'
        "  `"name`": $($name | ConvertTo-Json -Compress),"
        "  `"description`": $($description | ConvertTo-Json -Compress),"
        "  `"plane`": `"$Plane`","
        "  `"securityLevel`": `"$Level`","
        '  "roles": ['
        ($roleLines -join ",`n")
        '  ],'
        "  `"expectedConfig`": $($configJson -join "`n")"
        '}'
    )
    ($lines -join "`n") + "`n"
}

$outputs = [ordered]@{}
$outputs[$publishedRel] = (ConvertTo-StableJson (Get-PublishedCatalog)) + "`n"
foreach ($plane in $planes) {
    foreach ($level in $levels) {
        $text = Get-StarterFileText -Plane $plane -Level $level
        if ($text) { $outputs["$starterRoot/$($starterFolder[$plane])/$level.json"] = $text }
    }
}

# Compare as parsed JSON re-serialised the same way, so line endings and PowerShell version
# differences in ConvertTo-Json formatting cannot cause a false "out of date".
function Get-Normalized {
    param([string]$Text)
    ConvertTo-StableJson ($Text | ConvertFrom-Json)
}

if ($Check) {
    foreach ($rel in $outputs.Keys) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path $full)) { $rel; continue }
        if ((Get-Normalized (Get-Content -Raw -Path $full)) -ne (Get-Normalized $outputs[$rel])) { $rel }
    }
    return
}

foreach ($rel in $outputs.Keys) {
    $full = Join-Path $repoRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $outputs[$rel], [System.Text.UTF8Encoding]::new($false))
    Write-Host "wrote $rel"
}
