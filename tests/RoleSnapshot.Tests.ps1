#Requires -Version 7.0

# Weekly catalog review automation: export, compare, report schema and the auto-merge gate.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:export = Join-Path $script:repoRoot 'catalog-automation/Export-RoleDefinitions.ps1'
    $script:compare = Join-Path $script:repoRoot 'catalog-automation/Compare-RoleSnapshots.ps1'
    $script:gate = Join-Path $script:repoRoot 'catalog-automation/Test-CatalogChangeIsAutoSafe.ps1'
    $script:schema = Join-Path $script:repoRoot 'schemas/entra-role-export-report-v1.json'
    $script:realCatalog = Join-Path $script:repoRoot 'docs-site/src/data/eam-role-catalog.json'
    $script:realDefaults = Join-Path $script:repoRoot 'docs-site/src/data/eam-catalog-defaults.json'

    function New-RoleDef {
        param([string] $Id, [string] $Name, [string[]] $Actions = @('microsoft.directory/users/basic/update'), [bool] $Privileged = $false, [bool] $BuiltIn = $true)
        [pscustomobject]@{
            id = $Id; templateId = $Id; displayName = $Name; description = "$Name description"
            isBuiltIn = $BuiltIn; isEnabled = $true; isPrivileged = $Privileged
            rolePermissions = @([pscustomobject]@{ allowedResourceActions = $Actions })
        }
    }

    function Write-Snapshot {
        param([string] $Dir, [array] $Roles)
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        foreach ($r in $Roles) { $r | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $Dir "$($r.templateId).json") }
    }

    # A catalog of two roles, with the level defaults of the real defaults file.
    function New-MiniCatalog {
        param([string] $Path, [array] $Roles)
        $defaults = Get-Content -Raw $script:realDefaults | ConvertFrom-Json
        $out = foreach ($r in $Roles) {
            $lvl = ($defaults.levels | Where-Object { $_.plane -eq $r.plane -and $_.securityLevel -eq $r.securityLevel }).expectedConfig
            $cfg = [ordered]@{}
            foreach ($f in 'maxActivationDuration', 'requireMFA', 'authContext', 'requireJustification', 'requireApproval') {
                if ($lvl.PSObject.Properties.Name -contains $f) { $cfg[$f] = $lvl.$f }
            }
            [ordered]@{
                templateId = $r.id; displayName = $r.name; plane = $r.plane; securityLevel = $r.securityLevel
                isPrivileged = [bool]$r.privileged; expectedConfig = $cfg; note = $null; reviewNeeded = [bool]$r.review
            }
        }
        @{ roles = @($out) } | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
    }

    $script:idA = '11111111-1111-1111-1111-111111111111'
    $script:idB = '22222222-2222-2222-2222-222222222222'
    $script:idC = '33333333-3333-3333-3333-333333333333'
}

Describe 'Export-RoleDefinitions' {
    It 'writes built-in roles only, one file per templateId, and never custom roles' {
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        $defs += New-RoleDef -Id 'ffffffff-0000-0000-0000-000000000000' -Name 'Custom role' -BuiltIn $false
        $out = Join-Path $TestDrive 'export1'
        & $script:export -OutputPath $out -Definitions $defs | Out-Null
        @(Get-ChildItem $out -Filter *.json).Count | Should -Be 120
        Test-Path (Join-Path $out 'ffffffff-0000-0000-0000-000000000000.json') | Should -BeFalse
    }

    It 'removes files of roles that no longer exist' {
        $out = Join-Path $TestDrive 'export2'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        '{}' | Set-Content (Join-Path $out '99999999-0000-0000-0000-000000000000.json')
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        & $script:export -OutputPath $out -Definitions $defs | Out-Null
        Test-Path (Join-Path $out '99999999-0000-0000-0000-000000000000.json') | Should -BeFalse
    }

    It 'refuses to overwrite the snapshot with a truncated response' {
        $out = Join-Path $TestDrive 'export3'
        { & $script:export -OutputPath $out -Definitions @(New-RoleDef -Id $script:idA -Name 'Only one') } | Should -Throw '*Refusing*'
    }

    It 'writes sorted deterministic JSON without tenant fields' {
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" -Actions @('b/read', 'a/read') })
        $out = Join-Path $TestDrive 'export4'
        & $script:export -OutputPath $out -Definitions $defs | Out-Null
        $json = Get-Content -Raw (Join-Path $out '00000001-0000-0000-0000-000000000000.json') | ConvertFrom-Json
        $json.rolePermissions[0].allowedResourceActions | Should -Be @('a/read', 'b/read')
        $json.PSObject.Properties.Name | Should -Not -Contain 'assignments'
    }
}

Describe 'Compare-RoleSnapshots' {
    BeforeAll {
        $script:catalogPath = Join-Path $TestDrive 'catalog.json'
        New-MiniCatalog -Path $script:catalogPath -Roles @(
            @{ id = $script:idA; name = 'Alpha'; plane = 'Management'; securityLevel = 'Specialized'; privileged = $false },
            @{ id = $script:idB; name = 'Beta'; plane = 'Data'; securityLevel = 'Enterprise'; privileged = $false })
        function Invoke-Compare {
            param([array] $Base, [array] $Head, [string] $Name)
            $b = Join-Path $TestDrive "$Name-base"; $h = Join-Path $TestDrive "$Name-head"; $o = Join-Path $TestDrive "$Name.json"
            Write-Snapshot $b $Base; Write-Snapshot $h $Head
            & $script:compare -BaseDir $b -HeadDir $h -CatalogPath $script:catalogPath -OutputPath $o -GeneratedAt ([datetime]'2026-10-05T04:00:00Z') | Out-Null
            Get-Content -Raw $o | ConvertFrom-Json
        }
    }

    It 'reports a role the catalog does not list as new, with the isPrivileged floor' {
        $a = New-RoleDef $script:idA 'Alpha'; $b = New-RoleDef $script:idB 'Beta'
        $c = New-RoleDef $script:idC 'Gamma' -Privileged $true
        $r = Invoke-Compare -Base @($a, $b) -Head @($a, $b, $c) -Name 'new'
        $r.summary.newRoles | Should -Be 1
        $r.newRoles[0].templateId | Should -Be $script:idC
        $r.newRoles[0].floorLevel | Should -Be 'Privileged'
        $r.summary.needsReview | Should -BeTrue
    }

    It 'reports a catalog role missing from the snapshot as removed' {
        $a = New-RoleDef $script:idA 'Alpha'
        $r = Invoke-Compare -Base @($a) -Head @($a) -Name 'removed'
        $r.removedRoles.templateId | Should -Contain $script:idB
    }

    It 'reports a flipped isPrivileged and an added write action' {
        $a1 = New-RoleDef $script:idA 'Alpha' -Actions @('x/read')
        $a2 = New-RoleDef $script:idA 'Alpha' -Actions @('x/read', 'x/allProperties/update') -Privileged $true
        $b = New-RoleDef $script:idB 'Beta'
        $r = Invoke-Compare -Base @($a1, $b) -Head @($a2, $b) -Name 'changed'
        $r.summary.changedRoles | Should -Be 1
        $c = $r.changedRoles[0]
        $c.isPrivileged.old | Should -BeFalse
        $c.isPrivileged.new | Should -BeTrue
        $c.addedActions | Should -Contain 'x/allProperties/update'
        $c.currentLevel | Should -Be 'Specialized'
        $c.floorLevel | Should -Be 'Privileged'
    }

    It 'counts read-only action changes without listing them' {
        $a1 = New-RoleDef $script:idA 'Alpha' -Actions @('x/read')
        $a2 = New-RoleDef $script:idA 'Alpha' -Actions @('x/read', 'y/read')
        $b = New-RoleDef $script:idB 'Beta'
        $r = Invoke-Compare -Base @($a1, $b) -Head @($a2, $b) -Name 'readonly'
        $r.summary.changedRoles | Should -Be 0
        $r.summary.readOnlyChanges | Should -Be 1
        $r.summary.needsReview | Should -BeFalse
    }

    It 'writes a report that validates against the schema, also when empty' {
        $a = New-RoleDef $script:idA 'Alpha'; $b = New-RoleDef $script:idB 'Beta'
        $null = Invoke-Compare -Base @($a, $b) -Head @($a, $b) -Name 'empty'
        Test-Json -Json (Get-Content -Raw (Join-Path $TestDrive 'empty.json')) -SchemaFile $script:schema | Should -BeTrue
        $c = New-RoleDef $script:idC 'Gamma' -Privileged $true
        $null = Invoke-Compare -Base @($a, $b) -Head @($a, $b, $c) -Name 'full'
        Test-Json -Json (Get-Content -Raw (Join-Path $TestDrive 'full.json')) -SchemaFile $script:schema | Should -BeTrue
    }

    It 'fails schema validation on an unknown field' {
        $doc = Get-Content -Raw (Join-Path $TestDrive 'empty.json') | ConvertFrom-Json -AsHashtable
        $doc.extra = 1
        Test-Json -Json ($doc | ConvertTo-Json -Depth 10) -SchemaFile $script:schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'works on the first run when there is no base snapshot' {
        $h = Join-Path $TestDrive 'first-head'; Write-Snapshot $h @((New-RoleDef $script:idA 'Alpha'))
        & $script:compare -BaseDir (Join-Path $TestDrive 'nope') -HeadDir $h -CatalogPath $script:catalogPath -OutputPath (Join-Path $TestDrive 'first.json') | Out-Null
        (Get-Content -Raw (Join-Path $TestDrive 'first.json') | ConvertFrom-Json).summary.changedRoles | Should -Be 0
    }
}

Describe 'Test-CatalogChangeIsAutoSafe' {
    BeforeAll {
        $script:okFiles = @('docs-site/src/data/eam-role-catalog.json', 'docs-site/static/catalog/v1/eam-catalog.json')
        function Invoke-Gate {
            param([array] $Base, [array] $Head, [string[]] $Files = $script:okFiles, [string] $HeadDefaults = $script:realDefaults, [string] $SnapshotDir)
            $bp = Join-Path $TestDrive "gate-base-$([guid]::NewGuid()).json"; $hp = Join-Path $TestDrive "gate-head-$([guid]::NewGuid()).json"
            New-MiniCatalog $bp $Base; New-MiniCatalog $hp $Head
            $args = @{ BaseCatalogPath = $bp; HeadCatalogPath = $hp; BaseDefaultsPath = $script:realDefaults; HeadDefaultsPath = $HeadDefaults; ChangedFiles = $Files }
            if ($SnapshotDir) { $args.SnapshotDir = $SnapshotDir }
            & $script:gate @args
        }
        $script:baseRoles = @(@{ id = $script:idA; name = 'Alpha'; plane = 'Management'; securityLevel = 'Specialized'; privileged = $false })
    }

    It 'merges a new flagged role now' {
        $head = $script:baseRoles + @{ id = $script:idC; name = 'Gamma'; plane = 'Control'; securityLevel = 'Specialized'; privileged = $false; review = $true }
        (Invoke-Gate -Base $script:baseRoles -Head $head).verdict | Should -Be 'merge-now'
    }

    It 'sends a new role that is not flagged reviewNeeded to a person' {
        $head = $script:baseRoles + @{ id = $script:idC; name = 'Gamma'; plane = 'Control'; securityLevel = 'Specialized'; privileged = $false }
        (Invoke-Gate -Base $script:baseRoles -Head $head).verdict | Should -Be 'human'
    }

    It 'merges a tightening now' {
        $head = @(@{ id = $script:idA; name = 'Alpha'; plane = 'Management'; securityLevel = 'Privileged'; privileged = $true; review = $true })
        (Invoke-Gate -Base $script:baseRoles -Head $head).verdict | Should -Be 'merge-now'
    }

    It 'makes a lowering wait' {
        $head = @(@{ id = $script:idA; name = 'Alpha'; plane = 'Management'; securityLevel = 'Enterprise'; privileged = $false })
        $r = Invoke-Gate -Base $script:baseRoles -Head $head
        $r.verdict | Should -Be 'wait'
        $r.reasons -join ' ' | Should -BeLike '*lowered*'
    }

    It 'makes a plane change wait' {
        $head = @(@{ id = $script:idA; name = 'Alpha'; plane = 'Control'; securityLevel = 'Specialized'; privileged = $false })
        (Invoke-Gate -Base $script:baseRoles -Head $head).verdict | Should -Be 'wait'
    }

    It 'makes a removed role wait' {
        (Invoke-Gate -Base $script:baseRoles -Head @()).verdict | Should -Be 'wait'
    }

    It 'sends an isPrivileged role below Privileged to a person (floor)' {
        $head = @(@{ id = $script:idA; name = 'Alpha'; plane = 'Management'; securityLevel = 'Specialized'; privileged = $true })
        $r = Invoke-Gate -Base $script:baseRoles -Head $head
        $r.verdict | Should -Be 'human'
        $r.reasons -join ' ' | Should -BeLike '*floor*'
    }

    It 'sends a file outside the catalog outputs to a person' {
        (Invoke-Gate -Base $script:baseRoles -Head $script:baseRoles -Files @('src/compliance.ps1')).verdict | Should -Be 'human'
        (Invoke-Gate -Base $script:baseRoles -Head $script:baseRoles -Files @('.github/workflows/scan.yml')).verdict | Should -Be 'human'
    }

    It 'sends a changed level default to a person' {
        $d = Get-Content -Raw $script:realDefaults | ConvertFrom-Json
        $d.levels[0].expectedConfig.maxActivationDuration = 'PT24H'
        $dp = Join-Path $TestDrive 'defaults-changed.json'; $d | ConvertTo-Json -Depth 20 | Set-Content $dp
        (Invoke-Gate -Base $script:baseRoles -Head $script:baseRoles -HeadDefaults $dp).verdict | Should -Be 'human'
    }

    It 'sends a role whose policy differs from its level default to a person' {
        $bp = Join-Path $TestDrive 'pol-base.json'; $hp = Join-Path $TestDrive 'pol-head.json'
        New-MiniCatalog $bp $script:baseRoles; New-MiniCatalog $hp $script:baseRoles
        $c = Get-Content -Raw $hp | ConvertFrom-Json; $c.roles[0].expectedConfig.maxActivationDuration = 'PT24H'; $c | ConvertTo-Json -Depth 10 | Set-Content $hp
        (& $script:gate -BaseCatalogPath $bp -HeadCatalogPath $hp -BaseDefaultsPath $script:realDefaults -HeadDefaultsPath $script:realDefaults -ChangedFiles $script:okFiles).verdict | Should -Be 'human'
    }

    It 'sends a catalog that disagrees with the snapshot on isPrivileged to a person' {
        $snap = Join-Path $TestDrive 'gate-snap'; Write-Snapshot $snap @((New-RoleDef $script:idA 'Alpha' -Privileged $true))
        $r = Invoke-Gate -Base $script:baseRoles -Head $script:baseRoles -SnapshotDir $snap
        $r.verdict | Should -Be 'human'
        $r.reasons -join ' ' | Should -BeLike '*snapshot says*'
    }

    It 'sends a snapshot role missing from the catalog to a person' {
        $snap = Join-Path $TestDrive 'gate-snap2'; Write-Snapshot $snap @((New-RoleDef $script:idA 'Alpha'), (New-RoleDef $script:idC 'Gamma'))
        (Invoke-Gate -Base $script:baseRoles -Head $script:baseRoles -SnapshotDir $snap).verdict | Should -Be 'human'
    }

    It 'passes the real catalog against itself' {
        $real = Get-Content -Raw $script:realCatalog | ConvertFrom-Json
        $r = & $script:gate -BaseCatalogPath $script:realCatalog -HeadCatalogPath $script:realCatalog -BaseDefaultsPath $script:realDefaults -HeadDefaultsPath $script:realDefaults -ChangedFiles @()
        $r.reasons | Should -BeNullOrEmpty -Because 'the committed catalog must satisfy its own gate'
        $r.verdict | Should -Be 'merge-now'
    }
}
