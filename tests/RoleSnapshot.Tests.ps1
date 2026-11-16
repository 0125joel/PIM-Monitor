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
        param([string] $Id, [string] $Name, [string[]] $Actions = @('microsoft.directory/users/basic/update'), [bool] $Privileged = $false, [bool] $BuiltIn = $true, [string] $Condition)
        $perm = [pscustomobject]@{ allowedResourceActions = $Actions }
        if ($Condition) { $perm | Add-Member -NotePropertyName condition -NotePropertyValue $Condition }
        [pscustomobject]@{
            id = $Id; templateId = $Id; displayName = $Name; description = "$Name description"
            isBuiltIn = $BuiltIn; isEnabled = $true; isPrivileged = $Privileged
            rolePermissions = @($perm)
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

    It 'fetches a documented property that no role has, with $select, and merges it by id' {
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        $selects = [System.Collections.Generic.List[string]]::new()
        $fetch = {
            param([string] $Select)
            $selects.Add($Select)
            @(1..120 | ForEach-Object { [pscustomobject]@{ id = ('{0:x8}-0000-0000-0000-000000000000' -f $_); allowedPrincipalTypes = @('user', 'servicePrincipal'); resourceScopes = @('/'); version = '1.0' } })
        }.GetNewClosure()
        $out = Join-Path $TestDrive 'fetch/role-definitions'
        & $script:export -OutputPath $out -Definitions $defs -FetchSelect $fetch | Out-Null
        $selects.Count | Should -Be 1
        $selects[0] | Should -Be 'id,allowedPrincipalTypes,resourceScopes,version'
        $json = Get-Content -Raw (Join-Path $out '00000001-0000-0000-0000-000000000000.json') | ConvertFrom-Json
        @($json.allowedPrincipalTypes) | Should -Be @('servicePrincipal', 'user')
        $json.version | Should -Be '1.0'
        $status = Get-Content -Raw (Join-Path $TestDrive 'fetch/export-status.json') | ConvertFrom-Json
        @($status.missingDocumentedProperties).Count | Should -Be 0
        @($status.properties) | Should -Contain 'allowedPrincipalTypes'
    }

    It 'lists a documented property the API still does not return, and does not throw' {
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        $partial = {
            param([string] $Select)
            @(1..120 | ForEach-Object { [pscustomobject]@{ id = ('{0:x8}-0000-0000-0000-000000000000' -f $_); version = '1.0' } })
        }
        $out = Join-Path $TestDrive 'partial/role-definitions'
        { & $script:export -OutputPath $out -Definitions $defs -FetchSelect $partial -WarningAction SilentlyContinue | Out-Null } | Should -Not -Throw
        $status = Get-Content -Raw (Join-Path $TestDrive 'partial/export-status.json') | ConvertFrom-Json
        @($status.missingDocumentedProperties) | Should -Be @('allowedPrincipalTypes', 'resourceScopes')
        (Get-Content -Raw (Join-Path $out '00000001-0000-0000-0000-000000000000.json') | ConvertFrom-Json).version | Should -Be '1.0'
    }

    It 'makes no extra call when only -Definitions is given, and reports the missing properties' {
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        $out = Join-Path $TestDrive 'nofetch/role-definitions'
        & $script:export -OutputPath $out -Definitions $defs 3>$null | Out-Null
        $status = Get-Content -Raw (Join-Path $TestDrive 'nofetch/export-status.json') | ConvertFrom-Json
        @($status.missingDocumentedProperties) | Should -Be @('allowedPrincipalTypes', 'resourceScopes', 'version')
        $status.roles | Should -Be 120
    }

    It 'refuses to write when a core property every previous file had is gone, and leaves the folder unchanged' {
        $out = Join-Path $TestDrive 'regress/role-definitions'
        $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        & $script:export -OutputPath $out -Definitions $defs 3>$null | Out-Null
        $before = @{}
        foreach ($f in Get-ChildItem $out -File) { $before[$f.Name] = Get-Content -Raw $f.FullName }
        $statusBefore = Get-Content -Raw (Join-Path $TestDrive 'regress/export-status.json')
        $without = @(1..120 | ForEach-Object { $r = New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_"; $r.PSObject.Properties.Remove('rolePermissions'); $r })
        { & $script:export -OutputPath $out -Definitions $without 3>$null } | Should -Throw '*API shape regression*rolePermissions*'
        $after = @{}
        foreach ($f in Get-ChildItem $out -File) { $after[$f.Name] = Get-Content -Raw $f.FullName }
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] }
        Get-Content -Raw (Join-Path $TestDrive 'regress/export-status.json') | Should -Be $statusBefore
    }

    It 'writes on when a non-core property disappears, and records it as lost' {
        $out = Join-Path $TestDrive 'lost/role-definitions'
        $withFlag = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" | Add-Member -NotePropertyName resourceScopes -NotePropertyValue @('/') -PassThru })
        & $script:export -OutputPath $out -Definitions $withFlag 3>$null | Out-Null
        $without = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
        & $script:export -OutputPath $out -Definitions $without 3>$null | Out-Null
        (Get-Content -Raw (Join-Path $out '00000001-0000-0000-0000-000000000000.json') | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'resourceScopes'
        @((Get-Content -Raw (Join-Path $TestDrive 'lost/export-status.json') | ConvertFrom-Json).lostProperties) | Should -Be @('resourceScopes')
    }

    It 'writes export-status.json without a timestamp, identical on two runs with the same input' {
        $fetch = {
            param([string] $Select)
            @(1..120 | ForEach-Object { [pscustomobject]@{ id = ('{0:x8}-0000-0000-0000-000000000000' -f $_); allowedPrincipalTypes = @('user'); resourceScopes = @('/'); version = '1.0' } })
        }
        foreach ($run in 'st1', 'st2') {
            $defs = @(1..120 | ForEach-Object { New-RoleDef -Id ('{0:x8}-0000-0000-0000-000000000000' -f $_) -Name "Role $_" })
            & $script:export -OutputPath (Join-Path $TestDrive "$run/role-definitions") -Definitions $defs -FetchSelect $fetch | Out-Null
        }
        $a = Get-Content -Raw (Join-Path $TestDrive 'st1/export-status.json')
        $a | Should -Be (Get-Content -Raw (Join-Path $TestDrive 'st2/export-status.json'))
        $a | Should -Not -Match '\d{4}-\d{2}-\d{2}'
        $a | Should -Not -Match 'generated|timestamp|updated'
        ($a | ConvertFrom-Json).roles | Should -Be 120
        Get-Content -Raw (Join-Path $TestDrive 'st1/role-definitions/00000001-0000-0000-0000-000000000000.json') | Should -Be (Get-Content -Raw (Join-Path $TestDrive 'st2/role-definitions/00000001-0000-0000-0000-000000000000.json'))
    }
}

Describe 'Export-ResourceActions' {
    BeforeAll {
        $script:exportActions = Join-Path $script:repoRoot 'catalog-automation/Export-ResourceActions.ps1'
        $script:raSnap = Join-Path $TestDrive 'ra-snap'
        Write-Snapshot $script:raSnap @(
            (New-RoleDef 'aaaaaaaa-0000-0000-0000-000000000001' 'One' -Actions @('microsoft.directory/users/password/update', 'microsoft.office365.supportTickets/allEntities/allTasks')),
            (New-RoleDef 'aaaaaaaa-0000-0000-0000-000000000002' 'Two' -Actions @('microsoft.directory/users/standard/read'))
        )
        $script:raGood = {
            param($ns)
            switch ($ns) {
                'microsoft.directory' { @(
                        [pscustomobject]@{ name = 'microsoft.directory/users/standard/read'; description = 'Read users'; isPrivileged = $false },
                        [pscustomobject]@{ name = 'microsoft.directory/users/password/update'; description = 'Reset passwords'; isPrivileged = $true }) }
                'microsoft.office365.supportTickets' { @([pscustomobject]@{ name = 'microsoft.office365.supportTickets/allEntities/allTasks'; description = 'Manage tickets'; isPrivileged = $false }) }
            }
        }
    }

    It 'writes one sorted file per namespace the roles use, and an index with coverage' {
        $out = Join-Path $TestDrive 'ra-out'
        & $script:exportActions -RoleDefinitionsDir $script:raSnap -OutputPath $out -Fetch $script:raGood | Out-Null
        @(Get-ChildItem $out -Filter '*.json').Name | Sort-Object | Should -Be @('index.json', 'microsoft.directory.json', 'microsoft.office365.supportTickets.json')
        $dir = Get-Content -Raw (Join-Path $out 'microsoft.directory.json') | ConvertFrom-Json
        @($dir.actions.name) | Should -Be @('microsoft.directory/users/password/update', 'microsoft.directory/users/standard/read')
        ($dir.actions | Where-Object name -like '*password*').isPrivileged | Should -BeTrue
        $tickets = Get-Content -Raw (Join-Path $out 'microsoft.office365.supportTickets.json') | ConvertFrom-Json
        $tickets.actions[0].isPrivileged | Should -BeNullOrEmpty -Because 'Microsoft applies isPrivileged only to the microsoft.directory namespace'
        $idx = Get-Content -Raw (Join-Path $out 'index.json') | ConvertFrom-Json
        $idx.roleActions | Should -Be 3
        $idx.described | Should -Be 3
        $idx.namespaces.'microsoft.directory'.status | Should -Be 'ok'
    }

    It 'keeps the previous file of a namespace that fails, and says so in the index' {
        $out = Join-Path $TestDrive 'ra-out'
        $before = Get-Content -Raw (Join-Path $out 'microsoft.directory.json')
        $bad = { param($ns) if ($ns -eq 'microsoft.directory') { throw 'HTTP 503' } else { & $script:raGood $ns } }
        & $script:exportActions -RoleDefinitionsDir $script:raSnap -OutputPath $out -Fetch $bad | Out-Null
        Get-Content -Raw (Join-Path $out 'microsoft.directory.json') | Should -Be $before
        $idx = Get-Content -Raw (Join-Path $out 'index.json') | ConvertFrom-Json
        $idx.namespaces.'microsoft.directory'.status | Should -Be 'failed-kept-previous'
        $idx.namespaces.'microsoft.directory'.error | Should -BeLike '*503*'
    }

    It 'treats an empty response as a failure, not as a namespace without actions' {
        $out = Join-Path $TestDrive 'ra-empty'
        & $script:exportActions -RoleDefinitionsDir $script:raSnap -OutputPath $out -Fetch { param($ns) @() } | Out-Null
        Test-Path (Join-Path $out 'microsoft.directory.json') | Should -BeFalse
        $idx = Get-Content -Raw (Join-Path $out 'index.json') | ConvertFrom-Json
        $idx.namespaces.'microsoft.directory'.status | Should -Be 'failed'
        $idx.described | Should -Be 0
        @($idx.undescribed).Count | Should -Be 3
    }
}

Describe 'Live (default) Graph path of the export scripts' {
    BeforeAll {
        # A fake repo layout: the real scripts, the real endpoints, and a fake helpers.ps1 that
        # replaces only the Graph access. No -Definitions / -FetchSelect / -Fetch is passed, so the
        # scripts take the same path as in the workflow.
        $script:fakeRepo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeRepo 'catalog-automation'), (Join-Path $script:fakeRepo 'src') | Out-Null
        foreach ($s in 'Export-RoleDefinitions.ps1', 'Export-ResourceActions.ps1') {
            Copy-Item (Join-Path $script:repoRoot "catalog-automation/$s") (Join-Path $script:fakeRepo 'catalog-automation')
        }
        Copy-Item (Join-Path $script:repoRoot 'src/graphEndpoints.ps1') (Join-Path $script:fakeRepo 'src')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'src/helpers.ps1'), [ref]$null, [ref]$null)
        $json = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-DeterministicJson' }, $false)[0].Extent.Text
        $fake = @'

function Get-GraphAccessTokenString { 'fake' }
function Get-AllGraphItems {
    param([string] $Uri, [string] $AccessToken)
    if ($AccessToken -ne 'fake') { throw "unexpected token '$AccessToken'" }
    if ($Uri -like '*resourceActions*') {
        if ($env:PIMFAKE_FAIL_ACTIONS) { throw 'fake actions failure' }
        return @(
            [pscustomobject]@{ name = 'microsoft.directory/users/basic/update'; description = 'Update users'; isPrivileged = $false }
            [pscustomobject]@{ name = 'microsoft.directory/users/password/update'; description = 'Reset passwords'; isPrivileged = $true }
        )
    }
    if ($Uri -like '*$select=*') {
        if ($env:PIMFAKE_FAIL_SELECT) { throw 'fake select failure' }
        return @(1..120 | ForEach-Object { [pscustomobject]@{ id = ('{0:x8}-0000-0000-0000-000000000000' -f $_); allowedPrincipalTypes = 'user,servicePrincipal' } })
    }
    if ($env:PIMFAKE_FAIL_LIST) { throw 'fake list failure' }
    return @(1..120 | ForEach-Object {
            [pscustomobject]@{
                id = ('{0:x8}-0000-0000-0000-000000000000' -f $_); templateId = ('{0:x8}-0000-0000-0000-000000000000' -f $_)
                displayName = "Role $_"; description = "Role $_ description"; isBuiltIn = $true; isEnabled = $true; isPrivileged = $false
                rolePermissions = @([pscustomobject]@{ allowedResourceActions = @('microsoft.directory/users/basic/update') })
            }
        })
}
'@
        Set-Content -Path (Join-Path $script:fakeRepo 'src/helpers.ps1') -Value ($json + $fake)
        $script:liveExport = Join-Path $script:fakeRepo 'catalog-automation/Export-RoleDefinitions.ps1'
        $script:liveActions = Join-Path $script:fakeRepo 'catalog-automation/Export-ResourceActions.ps1'
    }
    AfterEach {
        $env:PIMFAKE_FAIL_SELECT = $null; $env:PIMFAKE_FAIL_LIST = $null; $env:PIMFAKE_FAIL_ACTIONS = $null
    }

    It 'exports with only -OutputPath: the supplementary $select call resolves Get-AllGraphItems' {
        $out = Join-Path $TestDrive 'live1/role-definitions'
        & $script:liveExport -OutputPath $out 3>&1 | Out-Null
        @(Get-ChildItem $out -Filter *.json).Count | Should -Be 120
        $role = Get-Content -Raw (Join-Path $out '00000001-0000-0000-0000-000000000000.json') | ConvertFrom-Json
        $role.PSObject.Properties.Name | Should -Contain 'allowedPrincipalTypes'
        $st = Get-Content -Raw (Join-Path $TestDrive 'live1/export-status.json') | ConvertFrom-Json
        $st.missingDocumentedProperties | Should -Not -Contain 'allowedPrincipalTypes'
        $st.supplementaryFetchError | Should -BeNullOrEmpty
        $st.PSObject.Properties.Name | Should -Contain 'supplementaryFetchError'
    }

    It 'still writes the snapshot when the supplementary call fails, and records the error' {
        $env:PIMFAKE_FAIL_SELECT = '1'
        $out = Join-Path $TestDrive 'live2/role-definitions'
        { & $script:liveExport -OutputPath $out 3>$null } | Should -Not -Throw
        @(Get-ChildItem $out -Filter *.json).Count | Should -Be 120
        $st = Get-Content -Raw (Join-Path $TestDrive 'live2/export-status.json') | ConvertFrom-Json
        $st.supplementaryFetchError | Should -BeLike '*fake select failure*'
        $st.missingDocumentedProperties | Should -Contain 'allowedPrincipalTypes'
    }

    It 'a lost non-core property (present before, missing now) is written and recorded, not fatal' {
        $out = Join-Path $TestDrive 'live2b/role-definitions'
        & $script:liveExport -OutputPath $out 3>$null | Out-Null
        $env:PIMFAKE_FAIL_SELECT = '1'
        { & $script:liveExport -OutputPath $out 3>$null } | Should -Not -Throw
        $st = Get-Content -Raw (Join-Path $TestDrive 'live2b/export-status.json') | ConvertFrom-Json
        $st.lostProperties | Should -Contain 'allowedPrincipalTypes'
        $st.supplementaryFetchError | Should -BeLike '*fake select failure*'
        @(Get-ChildItem $out -Filter *.json).Count | Should -Be 120
    }

    It 'a failure of the main list call still throws and writes nothing' {
        $env:PIMFAKE_FAIL_LIST = '1'
        $out = Join-Path $TestDrive 'live3/role-definitions'
        { & $script:liveExport -OutputPath $out } | Should -Throw '*fake list failure*'
        Test-Path $out | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'live3/export-status.json') | Should -BeFalse
    }

    It 'Export-ResourceActions with only -RoleDefinitionsDir and -OutputPath uses Get-AllGraphItems' {
        $roles = Join-Path $TestDrive 'live4/role-definitions'
        & $script:liveExport -OutputPath $roles 3>$null | Out-Null
        $out = Join-Path $TestDrive 'live4/resource-actions'
        & $script:liveActions -RoleDefinitionsDir $roles -OutputPath $out | Out-Null
        Test-Path (Join-Path $out 'microsoft.directory.json') | Should -BeTrue
        $idx = Get-Content -Raw (Join-Path $out 'index.json') | ConvertFrom-Json
        $idx.namespaces.'microsoft.directory'.status | Should -Be 'ok'
        $idx.namespaces.'microsoft.directory'.actions | Should -Be 2
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

Describe 'Invoke-CatalogBacktest' {
    BeforeAll {
        $script:backtest = Join-Path $script:repoRoot 'catalog-automation/Invoke-CatalogBacktest.ps1'
        # Real catalog plus a synthetic snapshot built from it, so the sample has facts to read.
        $script:btSnap = Join-Path $TestDrive 'bt-snap'
        $real = Get-Content -Raw $script:realCatalog | ConvertFrom-Json
        Write-Snapshot $script:btSnap @($real.roles | ForEach-Object { New-RoleDef -Id ([string]$_.templateId).ToLowerInvariant() -Name $_.displayName -Privileged ([bool]$_.isPrivileged) })
        $script:btOut = Join-Path $TestDrive 'bt-out'
        & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir $script:btOut -Count 20 | Out-Null
    }

    It 'samples the requested number of roles, covering every plane and level group first' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $key.Count | Should -Be 20
        @($key | Group-Object { "$($_.plane)|$($_.securityLevel)" }).Count | Should -Be 8
    }

    It 'is deterministic per seed' {
        $o2 = Join-Path $TestDrive 'bt-out2'
        & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir $o2 -Count 20 | Out-Null
        (Get-Content -Raw (Join-Path $o2 'answer-key.json')) | Should -Be (Get-Content -Raw (Join-Path $script:btOut 'answer-key.json'))
    }

    It 'keeps every classification out of the blind input and out of the reduced catalog' {
        $in = Get-Content -Raw (Join-Path $script:btOut 'input.json')
        $in | Should -Not -Match 'securityLevel'
        $in | Should -Not -Match '"plane"'
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $reduced = Get-Content -Raw (Join-Path $script:btOut 'catalog-without-sample.json') | ConvertFrom-Json
        $reduced.roles.Count | Should -Be (@((Get-Content -Raw $script:realCatalog | ConvertFrom-Json).roles).Count - 20)
        @($reduced.roles.templateId | Where-Object { $_ -in $key.templateId }).Count | Should -Be 0
    }

    It 'passes a perfect result' {
        $key = Get-Content -Raw (Join-Path $script:btOut 'answer-key.json')
        $res = Join-Path $TestDrive 'bt-perfect.json'; $key | Set-Content $res
        $s = & $script:backtest -Mode Score -CatalogPath $script:realCatalog -ResultsPath $res -AnswerKeyPath (Join-Path $script:btOut 'answer-key.json')
        $s.passed | Should -BeTrue
        $s.levelAgreement | Should -Be 1
    }

    It 'fails when an isPrivileged role is placed below Privileged' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $victim = $key | Where-Object isPrivileged | Select-Object -First 1
        $victim.securityLevel = 'Specialized'
        $res = Join-Path $TestDrive 'bt-floor.json'; $key | ConvertTo-Json -Depth 5 | Set-Content $res
        $s = & $script:backtest -Mode Score -CatalogPath $script:realCatalog -ResultsPath $res -AnswerKeyPath (Join-Path $script:btOut 'answer-key.json')
        $s.passed | Should -BeFalse
        $s.floorViolations | Should -Contain $victim.displayName
        $s.lenient | Should -Contain $victim.displayName
    }

    It 'separates lenient from strict disagreements and fails below the agreement threshold' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $res = Join-Path $TestDrive 'bt-bad.json'
        $bad = $key | ForEach-Object { $c = $_ | ConvertTo-Json | ConvertFrom-Json; if (-not $c.isPrivileged) { $c.securityLevel = 'Privileged' }; $c }
        $bad | ConvertTo-Json -Depth 5 | Set-Content $res
        $s = & $script:backtest -Mode Score -CatalogPath $script:realCatalog -ResultsPath $res -AnswerKeyPath (Join-Path $script:btOut 'answer-key.json') -MinLevelAgreement 0.99
        $s.strict.Count | Should -BeGreaterThan 0
        $s.lenient.Count | Should -Be 0
        $s.passed | Should -BeFalse
    }

    It 'reports a role the routine did not answer as missing' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $res = Join-Path $TestDrive 'bt-missing.json'; $key[1..($key.Count - 1)] | ConvertTo-Json -Depth 5 | Set-Content $res
        $s = & $script:backtest -Mode Score -CatalogPath $script:realCatalog -ResultsPath $res -AnswerKeyPath (Join-Path $script:btOut 'answer-key.json')
        $s.missing | Should -Contain $key[0].displayName
        $s.passed | Should -BeFalse
    }

    It 'leaves out the roles the rubric uses as worked examples' {
        $rubric = Join-Path $script:repoRoot 'catalog-automation/CLASSIFICATION-RUBRIC.md'
        $o = Join-Path $TestDrive 'bt-rubric'
        & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir $o -Count 40 -RubricPath $rubric | Out-Null
        $names = @(Get-Content -Raw (Join-Path $o 'answer-key.json') | ConvertFrom-Json).displayName
        foreach ($example in 'Global Administrator', 'Exchange Administrator', 'Reports Reader', 'People Administrator') {
            $names | Should -Not -Contain $example
        }
        $names.Count | Should -Be 40
    }

    It 'cuts the whole pool into disjoint folds that together cover it once' {
        $all = @(Get-Content -Raw $script:realCatalog | ConvertFrom-Json).roles
        $seen = foreach ($f in 1..5) {
            $o = Join-Path $TestDrive "bt-fold$f"
            & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir $o -Seed 7 -Folds 5 -Fold $f | Out-Null
            $ids = @(Get-Content -Raw (Join-Path $o 'answer-key.json') | ConvertFrom-Json).templateId
            # The classifier sees the full catalog minus its own fold, as the routine does in production.
            $ctx = (Get-Content -Raw (Join-Path $o 'catalog-without-sample.json') | ConvertFrom-Json).roles
            $ctx.Count | Should -Be ($all.Count - $ids.Count)
            @($ctx.templateId | Where-Object { $_ -in $ids }).Count | Should -Be 0
            [math]::Abs($ids.Count - ($all.Count / 5)) | Should -BeLessThan 1
            $ids
        }
        @($seen).Count | Should -Be $all.Count
        @($seen | Sort-Object -Unique).Count | Should -Be $all.Count
    }

    It 'writes meta.json with seed, fold and the hashes of what it measured' {
        $o = Join-Path $TestDrive 'bt-fold1'
        $m = Get-Content -Raw (Join-Path $o 'meta.json') | ConvertFrom-Json
        $m.seed | Should -Be 7
        $m.folds | Should -Be 5
        $m.fold | Should -Be 1
        $m.catalogSha256 | Should -Be ((Get-FileHash -Algorithm SHA256 $script:realCatalog).Hash.ToLowerInvariant())
        $m.snapshotSha256 | Should -Match '^[0-9a-f]{64}$'
        @($m.sampleTemplateIds).Count | Should -Be $m.sampleSize
    }

    It 'rejects a fold outside the range' {
        { & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir (Join-Path $TestDrive 'bt-bad-fold') -Folds 5 -Fold 6 } | Should -Throw '*between 1 and 5*'
    }

    It 'scores the folds of one pass together and writes a record' {
        $keys = 1..5 | ForEach-Object { Join-Path $TestDrive "bt-fold$_/answer-key.json" }
        $metas = 1..5 | ForEach-Object { Join-Path $TestDrive "bt-fold$_/meta.json" }
        $rec = Join-Path $TestDrive 'bt-record.json'
        $s = & $script:backtest -Mode Score -ResultsPath $keys -AnswerKeyPath $keys -MetaPath $metas -RecordPath $rec
        $s.roles | Should -Be @((Get-Content -Raw $script:realCatalog | ConvertFrom-Json).roles).Count
        $s.levelAgreement | Should -Be 1
        $r = Get-Content -Raw $rec | ConvertFrom-Json
        @($r.meta).Count | Should -Be 5
        $r.score.roles | Should -Be $s.roles
    }

    It 'refuses to score overlapping answer keys as one pass' {
        $k = Join-Path $TestDrive 'bt-fold1/answer-key.json'
        { & $script:backtest -Mode Score -ResultsPath $k -AnswerKeyPath $k, $k } | Should -Throw '*overlap*'
    }

    It 'measures whether two passes give the same answer' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $p1 = Join-Path $TestDrive 'stab-1.json'; $p2 = Join-Path $TestDrive 'stab-2.json'
        $key | ForEach-Object { $_ | Add-Member confidence 'high' -Force; $_ } | ConvertTo-Json -Depth 5 | Set-Content $p1
        $flip = $key | Where-Object { -not $_.isPrivileged } | Select-Object -First 1
        $key | ForEach-Object { $c = $_ | ConvertTo-Json | ConvertFrom-Json; if ($c.templateId -eq $flip.templateId) { $c.securityLevel = if ($c.securityLevel -eq 'Privileged') { 'Enterprise' } else { 'Privileged' } }; $c } | ConvertTo-Json -Depth 5 | Set-Content $p2
        $same = & $script:backtest -Mode Stability -ResultsPath $p1 -SecondResultsPath $p1
        $same.levelAgreement | Should -Be 1
        $same.passed | Should -BeTrue
        $s = & $script:backtest -Mode Stability -ResultsPath $p1 -SecondResultsPath $p2 -MinLevelAgreement 0.99
        $s.levelAgreement | Should -Be ([Math]::Round(($key.Count - 1) / $key.Count, 3))
        $s.confidentLevelContradictions | Should -Contain $flip.templateId
        $s.passed | Should -BeFalse
    }

    It 'leaves out every role the rubric names in prose, also across a line break' {
        $rubric = Join-Path $TestDrive 'mini-rubric.md'
        # Anchor in prose, one name broken over two lines, one only in the table; none of them may be sampled.
        @(
            'Anchor on SharePoint Administrator and Azure DevOps'
            'Administrator. Exchange Recipient Administrator stays Specialized. Cloud App Security Administrator too.'
            ''
            '| Role | Plane | Level | Why |'
            '| Reports Reader | Data | Enterprise | example |'
        ) | Set-Content $rubric
        $o = Join-Path $TestDrive 'bt-prose'
        & $script:backtest -Mode Prepare -CatalogPath $script:realCatalog -SnapshotDir $script:btSnap -OutDir $o -Count 200 -RubricPath $rubric | Out-Null
        $names = @(Get-Content -Raw (Join-Path $o 'answer-key.json') | ConvertFrom-Json).displayName
        foreach ($named in 'SharePoint Administrator', 'Azure DevOps Administrator', 'Exchange Recipient Administrator', 'Cloud App Security Administrator', 'Reports Reader') {
            $names | Should -Not -Contain $named
        }
        $names | Should -Contain 'Exchange Administrator' -Because 'a name that is only part of a longer named role is not named itself'
        $names | Should -Contain 'Security Administrator' -Because 'the tail of a longer named role is not named itself'
        $names.Count | Should -Be (@((Get-Content -Raw $script:realCatalog | ConvertFrom-Json).roles).Count - 5)
    }

    It 'scores the roles the routine would auto-label separately from low-confidence verdicts' {
        $key = @(Get-Content -Raw (Join-Path $script:btOut 'answer-key.json') | ConvertFrom-Json)
        $res = Join-Path $TestDrive 'bt-conf.json'
        $out = $key | ForEach-Object {
            $c = $_ | ConvertTo-Json | ConvertFrom-Json
            $c | Add-Member -NotePropertyName confidence -NotePropertyValue 'high' -Force
            $c
        }
        # One wrong but low-confidence verdict on a non-privileged role: strict, flagged low.
        $victim = $out | Where-Object { -not $_.isPrivileged -and $_.securityLevel -eq 'Specialized' } | Select-Object -First 1
        $victim.securityLevel = 'Privileged'; $victim.confidence = 'low'
        $out | ConvertTo-Json -Depth 5 | Set-Content $res
        $s = & $script:backtest -Mode Score -CatalogPath $script:realCatalog -ResultsPath $res -AnswerKeyPath (Join-Path $script:btOut 'answer-key.json') -MinLevelAgreement 0.99
        $s.passed | Should -BeFalse
        $s.autoEligible | Should -Be 19
        $s.autoEligibleLevelAgreement | Should -Be 1
        $s.passedAutoEligible | Should -BeTrue
    }
}
