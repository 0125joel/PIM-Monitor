#requires -Version 7.0
<#
.SYNOPSIS
    Measures how well the review routine classifies roles, against the hand-reconciled catalog.

.DESCRIPTION
    The roles in the catalog were reconciled by hand, so they are a ground truth. The routine
    must re-derive plane and level for a blind sample of them from the role facts alone.

      -Mode Prepare    picks a sample, writes input.json (facts and actions, no classification),
                       answer-key.json, catalog-without-sample.json and meta.json
      -Mode Score      compares the routine's verdicts (results.json) with the answer key. Takes
                       several result and answer-key files, so the folds of one pass score as one
      -Mode Stability  compares two independent passes over the same roles: does the routine give
                       the same answer twice?

    Two ways to sample:
      -Count n         the first n roles of a stratified order (every plane and level group before
                       any group gets a second role)
      -Folds k -Fold i the whole pool, cut into k folds; fold i is the sample. Run all k folds, each
                       in its own fresh session, and every role in the pool is measured once.

    The pool is every catalog role, minus the roles the rubric names (-RubricPath) and minus
    -ExcludeDisplayNames. catalog-without-sample.json is the full catalog minus the sample only, so
    the classifier sees the same neighbours as the routine does in production.

    Go-live criteria (defaults): no isPrivileged role below Privileged, and at least 90% level
    agreement. `autoEligible` repeats the check for the roles the routine would label `auto`
    (confidence high or medium): the routine never auto-merges a low-confidence verdict, so a miss
    it flagged as low is caught by design. `passed` stays on all roles; `passedAutoEligible` is
    the same test on that subset. Roles the routine classifies more leniently than the catalog are
    listed separately, because too strict is annoying and too lenient is the real risk.

.PARAMETER RubricPath
    CLASSIFICATION-RUBRIC.md. Every role the rubric names, in the worked-examples table or in the
    prose (anchors, tie-breakers), is left out of the sample: the routine has been told about them, so
    scoring it on them would measure nothing. Names are matched by their full display name, case-
    sensitive, with line breaks treated as spaces, so the rubric must spell roles out in full.

.PARAMETER ExcludeDisplayNames
    More roles to leave out by name, on top of what -RubricPath finds.

.PARAMETER SnapshotDir
    A role snapshot folder (role-definitions/). Supplies description and allowedResourceActions.

.PARAMETER ResultsPath / AnswerKeyPath
    Score: one or more verdict files and the answer keys that go with them (one per fold).
    Stability: -ResultsPath is the first pass, -SecondResultsPath the second.

.PARAMETER RecordPath / MetaPath
    Score: write a record (meta of every fold, score, answer keys, verdicts) to -RecordPath, with the
    meta.json files Prepare wrote. Commit it under catalog-automation/backtests/.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Score', 'Stability')] [string] $Mode,
    [Parameter()] [string] $CatalogPath,
    [Parameter()] [string] $SnapshotDir,
    [Parameter()] [string] $OutDir,
    [Parameter()] [int] $Count = 20,
    [Parameter()] [int] $Seed = 1,
    [Parameter()] [int] $Folds = 0,
    [Parameter()] [int] $Fold = 0,
    [Parameter()] [string[]] $ResultsPath,
    [Parameter()] [string[]] $AnswerKeyPath,
    [Parameter()] [string[]] $SecondResultsPath,
    [Parameter()] [string[]] $MetaPath = @(),
    [Parameter()] [string] $RecordPath,
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
function Get-Sha256 { param([string] $Path) (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant() }
function Read-JsonArray { param([string[]] $Paths)
    @(foreach ($p in $Paths) { Get-Content -Raw -Path $p | ConvertFrom-Json })
}
function Get-Id { param($Role) ([string]$Role.templateId).ToLowerInvariant() }
# A verdict without a confidence is treated as low: the routine never auto-merges it.
function Get-Confidence { param($Verdict) [string]($Verdict.PSObject.Properties['confidence']?.Value ?? 'low') }

if ($Mode -eq 'Prepare') {
    if (-not $CatalogPath -or -not $SnapshotDir -or -not $OutDir) { throw 'Prepare needs -CatalogPath, -SnapshotDir and -OutDir.' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $catalog = Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json
    $roles = @($catalog.roles)
    $excluded = [System.Collections.Generic.List[string]]::new()
    if ($ExcludeDisplayNames.Count -gt 0) {
        $roles | Where-Object { $_.displayName -in $ExcludeDisplayNames } | ForEach-Object { $excluded.Add($_.displayName) }
        $roles = @($roles | Where-Object { $_.displayName -notin $ExcludeDisplayNames })
    }
    if ($RubricPath) {
        # Leave out every role the rubric names anywhere: the worked-examples table, and the prose
        # (anchors, tie-breakers). Whitespace is collapsed first, so a name broken over two lines
        # still counts. A role the routine has been told about cannot measure anything.
        # Longest names first, and each match is blanked out of the text, so "Security Administrator"
        # does not count as named just because "Cloud App Security Administrator" is.
        $text = (Get-Content -Raw -Path $RubricPath) -replace '\s+', ' '
        $known = foreach ($name in @($catalog.roles.displayName | Sort-Object { $_.Length } -Descending)) {
            $pattern = '(?<![A-Za-z0-9])' + ([regex]::Escape($name) -replace '\\ ', ' ') + '(?![A-Za-z0-9])'
            if ($text -cmatch $pattern) {
                $text = [regex]::Replace($text, $pattern, '#')
                if ($name -in $roles.displayName) { $name }
            }
        }
        $known = @($known)
        $known | ForEach-Object { $excluded.Add($_) }
        $before = $roles.Count
        $roles = @($roles | Where-Object { $_.displayName -notin $known })
        Write-Host "Left out $($before - $roles.Count) roles that the rubric names (examples table and prose)."
    }

    # Stratified order: round-robin over (plane, level) groups, each group shuffled with the seed,
    # so every group is represented before any group gets a second role. Deterministic per seed.
    $rng = [System.Random]::new($Seed)
    $groups = @($roles | Group-Object { "$($_.plane)|$($_.securityLevel)" } | Sort-Object Name | ForEach-Object {
            , @($_.Group | Sort-Object { $rng.Next() })
        })
    $ordered = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($ordered.Count -lt $roles.Count) {
        foreach ($g in $groups) { if ($i -lt $g.Count) { $ordered.Add($g[$i]) } }
        $i++
    }

    if ($Folds -gt 0) {
        if ($Folds -gt $ordered.Count) { throw "-Folds $Folds is more than the $($ordered.Count) roles in the pool." }
        if ($Fold -lt 1 -or $Fold -gt $Folds) { throw "-Fold must be between 1 and $Folds." }
        # Deal the stratified order out like cards, so every fold gets a mix of groups.
        $picked = @(for ($k = 0; $k -lt $ordered.Count; $k++) { if (($k % $Folds) -eq ($Fold - 1)) { $ordered[$k] } })
    }
    else {
        $picked = @($ordered | Select-Object -First ([Math]::Min($Count, $ordered.Count)))
    }

    $inputs = foreach ($r in $picked) {
        $file = Join-Path $SnapshotDir "$(Get-Id $r).json"
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
    $sampleIds = @($picked | ForEach-Object { Get-Id $_ })
    $context = @($catalog.roles | Where-Object { (Get-Id $_) -notin $sampleIds })
    $copy = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copy.roles = $context
    if ($copy.PSObject.Properties['roleCount']) { $copy.roleCount = $context.Count }

    $snapFiles = @(Get-ChildItem -Path $SnapshotDir -Filter '*.json' -File | Sort-Object Name)
    $snapHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes((($snapFiles | ForEach-Object { "$($_.Name):$(Get-Sha256 $_.FullName)" }) -join "`n")))
    $meta = [ordered]@{
        seed            = $Seed
        folds           = $Folds
        fold            = $Fold
        count           = if ($Folds -gt 0) { $null } else { $Count }
        poolSize        = $ordered.Count
        sampleSize      = $picked.Count
        excluded        = @($excluded | Sort-Object -Unique)
        catalogSha256   = Get-Sha256 $CatalogPath
        rubricSha256    = if ($RubricPath) { Get-Sha256 $RubricPath } else { $null }
        snapshotSha256  = [Convert]::ToHexString($snapHash).ToLowerInvariant()
        sampleTemplateIds = $sampleIds
    }

    Write-Json @($inputs) (Join-Path $OutDir 'input.json')
    Write-Json @($key) (Join-Path $OutDir 'answer-key.json')
    Write-Json $copy (Join-Path $OutDir 'catalog-without-sample.json')
    Write-Json $meta (Join-Path $OutDir 'meta.json')
    Write-Host "Sample of $($picked.Count) roles written to $OutDir. Give the routine input.json and catalog-without-sample.json, not answer-key.json or meta.json."
    return
}

if ($Mode -eq 'Stability') {
    if (-not $ResultsPath -or -not $SecondResultsPath) { throw 'Stability needs -ResultsPath and -SecondResultsPath.' }
    $a = @{}; foreach ($r in (Read-JsonArray $ResultsPath)) { $a[(Get-Id $r)] = $r }
    $b = @{}; foreach ($r in (Read-JsonArray $SecondResultsPath)) { $b[(Get-Id $r)] = $r }
    $missing = @(@($a.Keys | Where-Object { -not $b.ContainsKey($_) }) + @($b.Keys | Where-Object { -not $a.ContainsKey($_) }))
    $both = @($a.Keys | Where-Object { $b.ContainsKey($_) } | Sort-Object)
    $planeSame = 0; $levelSame = 0; $diff = @(); $confident = @()
    foreach ($id in $both) {
        $x = $a[$id]; $y = $b[$id]
        if ($x.plane -eq $y.plane) { $planeSame++ }
        if ($x.securityLevel -eq $y.securityLevel) { $levelSame++ }
        if ($x.plane -ne $y.plane -or $x.securityLevel -ne $y.securityLevel) {
            $diff += "${id}: $($x.plane)/$($x.securityLevel) ($(Get-Confidence $x)) vs $($y.plane)/$($y.securityLevel) ($(Get-Confidence $y))"
            if ($x.securityLevel -ne $y.securityLevel -and (Get-Confidence $x) -in 'high', 'medium' -and (Get-Confidence $y) -in 'high', 'medium') { $confident += $id }
        }
    }
    $n = [Math]::Max($both.Count, 1)
    $levelAgreement = [Math]::Round($levelSame / $n, 3)
    $stability = [pscustomobject]@{
        roles                       = $both.Count
        planeAgreement              = [Math]::Round($planeSame / $n, 3)
        levelAgreement              = $levelAgreement
        disagreements               = @($diff)
        confidentLevelContradictions = @($confident)
        missing                     = @($missing)
        passed                      = ($missing.Count -eq 0) -and ($levelAgreement -ge $MinLevelAgreement)
    }
    if ($RecordPath) { Write-Json ([ordered]@{ stability = $stability }) $RecordPath }
    return $stability
}

if (-not $ResultsPath -or -not $AnswerKeyPath) { throw 'Score needs -ResultsPath and -AnswerKeyPath.' }
$results = Read-JsonArray $ResultsPath
$key = Read-JsonArray $AnswerKeyPath
$dupes = @($key | Group-Object { Get-Id $_ } | Where-Object Count -gt 1 | ForEach-Object Name)
if ($dupes.Count) { throw "Answer keys overlap on $($dupes -join ', '): folds of one pass must be disjoint." }
$byId = @{}
foreach ($r in $results) { $byId[(Get-Id $r)] = $r }

$planeOk = 0; $levelOk = 0; $missing = @(); $floor = @(); $lenient = @(); $strict = @(); $mismatch = @()
foreach ($k in $key) {
    $id = Get-Id $k
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
$eligible = @($key | Where-Object { $byId.ContainsKey((Get-Id $_)) -and (Get-Confidence $byId[(Get-Id $_)]) -in 'high', 'medium' })
$eligibleOk = @($eligible | Where-Object { $byId[(Get-Id $_)].securityLevel -eq $_.securityLevel }).Count
$eligibleLenient = @($eligible | Where-Object { $levelRank[[string]$byId[(Get-Id $_)].securityLevel] -gt $levelRank[[string]$_.securityLevel] } | ForEach-Object displayName)
$eligibleAgreement = if ($eligible.Count) { [Math]::Round($eligibleOk / $eligible.Count, 3) } else { 0 }
$n = [Math]::Max($key.Count, 1)
$planeAgreement = [Math]::Round($planeOk / $n, 3)
$levelAgreement = [Math]::Round($levelOk / $n, 3)
$score = [pscustomobject]@{
    roles           = $key.Count
    planeAgreement  = $planeAgreement
    levelAgreement  = $levelAgreement
    floorViolations = @($floor)
    lenient         = @($lenient)
    strict          = @($strict)
    missing         = @($missing)
    mismatches      = @($mismatch)
    passed          = ($floor.Count -eq 0) -and ($missing.Count -eq 0) -and ($levelAgreement -ge $MinLevelAgreement)
    autoEligible    = $eligible.Count
    autoEligibleLevelAgreement = $eligibleAgreement
    passedAutoEligible = ($floor.Count -eq 0) -and ($missing.Count -eq 0) -and ($eligibleLenient.Count -eq 0) -and ($eligibleAgreement -ge $MinLevelAgreement)
}
if ($RecordPath) {
    Write-Json ([ordered]@{
            meta      = @(foreach ($m in $MetaPath) { Get-Content -Raw -Path $m | ConvertFrom-Json })
            score     = $score
            answerKey = @($key)
            verdicts  = @($results)
        }) $RecordPath
}
$score
