#requires -Version 7.0
<#
.SYNOPSIS
    Measures how well the review routine classifies roles, against the hand-reconciled catalog.

.DESCRIPTION
    The 145 roles in the catalog were reconciled by hand, so they are a ground truth. The routine
    must re-derive plane and level for a blind sample of them from the role facts alone.

      -Mode Prepare   picks a stratified sample, writes input.json (facts and actions, no
                      classification), answer-key.json, and catalog-without-sample.json
      -Mode Score     compares the routine's verdicts (results.json) with the answer key

    Go-live criteria (defaults): no isPrivileged role below Privileged, and at least 90% level
    agreement. Roles the routine classifies more leniently than the catalog are listed separately,
    because too strict is annoying and too lenient is the real risk.

.PARAMETER RubricPath
    CLASSIFICATION-RUBRIC.md. Roles in its worked-examples table are left out of the sample: the routine
    has seen their answers, so scoring it on them would measure nothing.

.PARAMETER ExcludeDisplayNames
    More roles to leave out, for names the rubric mentions in prose (the escalation anchor) rather
    than in the examples table.

.PARAMETER SnapshotDir
    A role snapshot folder (role-definitions/). Supplies description and allowedResourceActions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Score')] [string] $Mode,
    [Parameter(Mandatory)] [string] $CatalogPath,
    [Parameter()] [string] $SnapshotDir,
    [Parameter()] [string] $OutDir,
    [Parameter()] [int] $Count = 20,
    [Parameter()] [int] $Seed = 1,
    [Parameter()] [string] $ResultsPath,
    [Parameter()] [string] $AnswerKeyPath,
    [Parameter()] [string] $RubricPath,
    [Parameter()] [string[]] $ExcludeDisplayNames = @(),
    [Parameter()] [double] $MinLevelAgreement = 0.9
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$levelRank = @{ Privileged = 0; Specialized = 1; Enterprise = 2 }   # lower is stricter

function Write-Json { param($Object, [string] $Path)
    [System.IO.File]::WriteAllText($Path, (($Object | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

if ($Mode -eq 'Prepare') {
    if (-not $SnapshotDir -or -not $OutDir) { throw 'Prepare needs -SnapshotDir and -OutDir.' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $catalog = Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json
    $roles = @($catalog.roles)
    if ($ExcludeDisplayNames.Count -gt 0) {
        $roles = @($roles | Where-Object { $_.displayName -notin $ExcludeDisplayNames })
    }
    if ($RubricPath) {
        $known = @(Select-String -Path $RubricPath -Pattern '^\| (.+?) \| (Control|Management|Data) \|' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        $roles = @($roles | Where-Object { $_.displayName -notin $known })
        Write-Host "Left out $($catalog.roles.Count - $roles.Count) roles that the rubric uses as examples."
    }

    # Stratified: round-robin over (plane, level) groups, each group shuffled with the seed, so
    # every group is represented before any group gets a second role. Deterministic per seed.
    $rng = [System.Random]::new($Seed)
    $groups = @($roles | Group-Object { "$($_.plane)|$($_.securityLevel)" } | Sort-Object Name | ForEach-Object {
            , @($_.Group | Sort-Object { $rng.Next() })
        })
    $picked = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($picked.Count -lt [Math]::Min($Count, $roles.Count)) {
        foreach ($g in $groups) {
            if ($picked.Count -ge $Count) { break }
            if ($i -lt $g.Count) { $picked.Add($g[$i]) }
        }
        $i++
    }

    $inputs = foreach ($r in $picked) {
        $file = Join-Path $SnapshotDir "$(([string]$r.templateId).ToLowerInvariant()).json"
        if (-not (Test-Path $file)) { throw "No snapshot file for $($r.displayName) ($($r.templateId))." }
        $snap = Get-Content -Raw -Path $file | ConvertFrom-Json
        $actions = @($snap.rolePermissions | ForEach-Object { $_.allowedResourceActions } | Where-Object { $_ } | Sort-Object -Unique)
        [ordered]@{
            templateId             = [string]$r.templateId
            displayName            = [string]$r.displayName
            description            = [string]($snap.PSObject.Properties['description']?.Value ?? '')
            isPrivileged           = [bool]$snap.isPrivileged
            allowedResourceActions = $actions
        }
    }
    $key = foreach ($r in $picked) {
        [ordered]@{ templateId = [string]$r.templateId; displayName = [string]$r.displayName; plane = [string]$r.plane; securityLevel = [string]$r.securityLevel; isPrivileged = [bool]$r.isPrivileged }
    }
    $sampleIds = @($picked | ForEach-Object { ([string]$_.templateId).ToLowerInvariant() })
    $remaining = @($roles | Where-Object { ([string]$_.templateId).ToLowerInvariant() -notin $sampleIds })
    $copy = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copy.roles = $remaining
    if ($copy.PSObject.Properties['roleCount']) { $copy.roleCount = $remaining.Count }

    Write-Json @($inputs) (Join-Path $OutDir 'input.json')
    Write-Json @($key) (Join-Path $OutDir 'answer-key.json')
    Write-Json $copy (Join-Path $OutDir 'catalog-without-sample.json')
    Write-Host "Sample of $($picked.Count) roles written to $OutDir. Give the routine input.json and catalog-without-sample.json, not answer-key.json."
    return
}

if (-not $ResultsPath -or -not $AnswerKeyPath) { throw 'Score needs -ResultsPath and -AnswerKeyPath.' }
$results = @(Get-Content -Raw -Path $ResultsPath | ConvertFrom-Json)
$key = @(Get-Content -Raw -Path $AnswerKeyPath | ConvertFrom-Json)
$byId = @{}
foreach ($r in $results) { $byId[([string]$r.templateId).ToLowerInvariant()] = $r }

$planeOk = 0; $levelOk = 0; $missing = @(); $floor = @(); $lenient = @(); $strict = @(); $mismatch = @()
foreach ($k in $key) {
    $id = ([string]$k.templateId).ToLowerInvariant()
    if (-not $byId.ContainsKey($id)) { $missing += $k.displayName; continue }
    $r = $byId[$id]
    if ($r.plane -eq $k.plane) { $planeOk++ } else { $mismatch += "$($k.displayName): plane $($r.plane), catalog $($k.plane)" }
    if ($r.securityLevel -eq $k.securityLevel) { $levelOk++ }
    else {
        $mismatch += "$($k.displayName): level $($r.securityLevel), catalog $($k.securityLevel)"
        if ($levelRank[[string]$r.securityLevel] -gt $levelRank[[string]$k.securityLevel]) { $lenient += $k.displayName } else { $strict += $k.displayName }
    }
    if ($k.isPrivileged -and $r.securityLevel -ne 'Privileged') { $floor += $k.displayName }
}
$n = [Math]::Max($key.Count, 1)
$planeAgreement = [Math]::Round($planeOk / $n, 3)
$levelAgreement = [Math]::Round($levelOk / $n, 3)
[pscustomobject]@{
    roles           = $key.Count
    planeAgreement  = $planeAgreement
    levelAgreement  = $levelAgreement
    floorViolations = @($floor)
    lenient         = @($lenient)
    strict          = @($strict)
    missing         = @($missing)
    mismatches      = @($mismatch)
    passed          = ($floor.Count -eq 0) -and ($missing.Count -eq 0) -and ($levelAgreement -ge $MinLevelAgreement)
}
