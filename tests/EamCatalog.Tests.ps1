#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Contract tests for the EAM role catalog: one source (docs-site/src/data/eam-role-catalog.json),
# the published file, its JSON Schema and the Examples/access-model starter files.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:catalogPath = Join-Path $script:repoRoot 'docs-site/src/data/eam-role-catalog.json'
    $script:publishedPath = Join-Path $script:repoRoot 'docs-site/static/catalog/v1/eam-catalog.json'
    $script:schemaPath = Join-Path $script:repoRoot 'schemas/eam-catalog-v1.json'
    $script:buildScript = Join-Path $script:repoRoot 'docs-site/scripts/Build-EamCatalog.ps1'
    $script:policyFields = @(
        'maxActivationDuration', 'requireMFA', 'authContext', 'requireJustification', 'requireTicketing',
        'requireApproval', 'allowPermanentEligible', 'maxEligibleDuration', 'allowPermanentActive', 'maxActiveDuration'
    )
}

Describe 'EAM role catalog source' {
    BeforeAll {
        $script:source = Get-Content -Raw -Path $script:catalogPath | ConvertFrom-Json
        $script:roles = @($script:source.roles)
    }

    It 'lists every role with a GUID templateId' {
        $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        $bad = @($script:roles | Where-Object { $_.templateId -notmatch $guid } | ForEach-Object displayName)
        $bad | Should -BeNullOrEmpty
    }

    It 'has no duplicate templateId' {
        $dupes = @($script:roles | Group-Object templateId | Where-Object Count -gt 1 | ForEach-Object Name)
        $dupes | Should -BeNullOrEmpty
    }

    It 'keeps roleCount in step with the roles array' {
        $script:source.roleCount | Should -Be $script:roles.Count
    }

    It 'uses only the allowed plane and security level values' {
        $badPlane = @($script:roles | Where-Object { $_.plane -notin 'Control', 'Management', 'Data' } | ForEach-Object displayName)
        $badLevel = @($script:roles | Where-Object { $_.securityLevel -notin 'Privileged', 'Specialized', 'Enterprise' } | ForEach-Object displayName)
        $badPlane | Should -BeNullOrEmpty
        $badLevel | Should -BeNullOrEmpty
    }

    It 'uses only expectedConfig field names the scanner knows' {
        $unknown = @($script:roles | ForEach-Object { $_.expectedConfig.PSObject.Properties.Name } | Sort-Object -Unique | Where-Object { $_ -notin $script:policyFields })
        $unknown | Should -BeNullOrEmpty
    }

    It 'uses an auth context slug from the seed list, never free text' {
        $defaults = Get-Content -Raw -Path (Join-Path $script:repoRoot 'docs-site/src/data/eam-catalog-defaults.json') | ConvertFrom-Json
        $slugs = @($defaults.authContexts.slug)
        $used = @($script:roles | Where-Object { $_.expectedConfig.PSObject.Properties.Name -contains 'authContext' } | ForEach-Object { $_.expectedConfig.authContext } | Sort-Object -Unique)
        $used | Where-Object { $_ -notin $slugs } | Should -BeNullOrEmpty
    }

    It 'sets requireMFA whenever a role has an auth context' {
        # requireMFA true means "MFA or an authentication context is on". With authContext present
        # the context is the activation requirement; without it, plain MFA.
        $roleWithoutMfa = @($script:roles | Where-Object { -not $_.expectedConfig.requireMFA -and $_.expectedConfig.PSObject.Properties.Name -contains 'authContext' })
        $roleWithoutMfa | Should -BeNullOrEmpty
    }
}

Describe 'Published catalog file' {
    It 'exists' {
        Test-Path $script:publishedPath | Should -BeTrue
    }

    It 'validates against schemas/eam-catalog-v1.json' {
        Test-Json -Json (Get-Content -Raw -Path $script:publishedPath) -SchemaFile $script:schemaPath | Should -BeTrue
    }

    It 'fails validation on an unknown field in a role' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json -AsHashtable
        $doc.roles[0].recommendedConfig = @{ maxActivation = 'PT1H' }
        $json = $doc | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'fails validation on an unknown field in expectedConfig' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json -AsHashtable
        $doc.roles[0].expectedConfig.requireMfa = $true
        $json = $doc | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'fails validation on an unknown top-level field' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json -AsHashtable
        $doc.extra = 'x'
        $json = $doc | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'fails validation on a plane outside the allowed values' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json -AsHashtable
        $doc.roles[0].plane = 'Workload'
        $json = $doc | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'fails validation on a templateId that is not a GUID' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json -AsHashtable
        $doc.roles[0].templateId = 'not-a-guid'
        $json = $doc | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'only references auth context slugs that exist in authContexts' {
        $doc = Get-Content -Raw -Path $script:publishedPath | ConvertFrom-Json
        $slugs = @($doc.authContexts.slug)
        $refs = @($doc.roles.expectedConfig + $doc.levels.expectedConfig + $doc.groups.member + $doc.groups.owner |
            Where-Object { $_.PSObject.Properties.Name -contains 'authContext' } | ForEach-Object authContext | Sort-Object -Unique)
        $refs | Where-Object { $_ -notin $slugs } | Should -BeNullOrEmpty
    }
}

Describe 'Generated files are up to date' {
    It 'matches what Build-EamCatalog.ps1 produces from the catalog (published file and starter files)' {
        $stale = @(& $script:buildScript -Check)
        $stale | Should -BeNullOrEmpty -Because 'run docs-site/scripts/Build-EamCatalog.ps1 and commit the result'
    }
}

Describe 'Examples/access-model starter files' {
    It 'list exactly the roles the catalog puts at that plane and level' {
        $source = Get-Content -Raw -Path $script:catalogPath | ConvertFrom-Json
        $folders = @{ Control = 'ControlPlane'; Management = 'ManagementPlane'; Data = 'DataWorkloadPlane' }
        $problems = foreach ($plane in $folders.Keys) {
            foreach ($level in 'Privileged', 'Specialized', 'Enterprise') {
                $expected = @($source.roles | Where-Object { $_.plane -eq $plane -and $_.securityLevel -eq $level } | ForEach-Object templateId | Sort-Object)
                $file = Join-Path $script:repoRoot "Examples/access-model/$($folders[$plane])/$level.json"
                if (-not (Test-Path $file)) {
                    if ($expected.Count -gt 0) { "$plane/$level has $($expected.Count) roles in the catalog but no starter file" }
                    continue
                }
                $actual = @((Get-Content -Raw -Path $file | ConvertFrom-Json).roles.id | Sort-Object)
                if (Compare-Object $expected $actual) { "$plane/$level starter file differs from the catalog" }
            }
        }
        $problems | Should -BeNullOrEmpty
    }
}

Describe 'Retired generator' {
    It 'is gone, with nothing left that reads it' {
        Test-Path (Join-Path $script:repoRoot 'docs-site/scripts/Generate-EamRoleCatalog.ps1') | Should -BeFalse
        Test-Path (Join-Path $script:repoRoot 'docs-site/src/data/eam-role-curated.json') | Should -BeFalse
    }
}
