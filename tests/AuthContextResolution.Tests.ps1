BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $script:fixtures = Join-Path -Path $PSScriptRoot -ChildPath "fixtures"

    # Builds an inventory/authentication-contexts tree in TestDrive.
    #   -Contexts: displayName -> claim id (folder named by slug, with definition.json)
    #   -Seeds:    labels that get a config.json copied from the fixtures (no definition.json)
    function New-AuthContextInventory {
        param([string] $Name, [hashtable] $Contexts, [string[]] $Seeds = @())
        $root = Join-Path $TestDrive $Name
        foreach ($displayName in $Contexts.Keys) {
            $dir = Join-Path $root "authentication-contexts/$(Get-InventorySlug -Name $displayName)"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            @{ id = $Contexts[$displayName]; displayName = $displayName; description = ''; isAvailable = $true } |
                ConvertTo-Json | Set-Content -Path (Join-Path $dir 'definition.json') -Encoding utf8NoBOM
        }
        foreach ($seed in $Seeds) {
            $dir = Join-Path $root "authentication-contexts/$seed"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Copy-Item (Join-Path $script:fixtures "inventory/authentication-contexts/$seed/config.json") $dir
        }
        return $root
    }

    function New-Tier {
        param([string] $Name, [string] $AuthContext)
        [pscustomobject]@{
            name           = $Name
            severity       = 'High'
            roles          = @([pscustomobject]@{ id = '00000000-0000-0000-0000-0000000000aa' })
            expectedConfig = [pscustomobject]@{ requireMFA = $true; authContext = $AuthContext }
        }
    }
}

Describe "Seed auth context fixtures" {
    It "has a config.json for each of the four seeds" {
        foreach ($seed in 'phish-resistant-sif', 'phish-resistant-no-sif', 'phish-resistant-compliant-device', 'phish-resistant-compliant-device-sif') {
            $file = Join-Path $script:fixtures "inventory/authentication-contexts/$seed/config.json"
            Test-Path $file | Should -BeTrue -Because $seed
            $config = Get-Content -Raw $file | ConvertFrom-Json
            $config.requireState | Should -Be 'enabled'
            $config.requireAuthStrengthId | Should -Be '00000000-0000-0000-0000-000000000003'
        }
    }

    It "matches the sign-in frequency and compliant device columns of the docs" {
        $expected = @{
            'phish-resistant-sif'                   = @($true, $false)
            'phish-resistant-no-sif'                = @($false, $false)
            'phish-resistant-compliant-device'      = @($false, $true)
            'phish-resistant-compliant-device-sif'  = @($true, $true)
        }
        foreach ($seed in $expected.Keys) {
            $c = Get-Content -Raw (Join-Path $script:fixtures "inventory/authentication-contexts/$seed/config.json") | ConvertFrom-Json
            $c.requireSignInFrequencyEveryTime | Should -Be $expected[$seed][0] -Because "$seed sif"
            $c.PSObject.Properties['requireCompliantDevice']?.Value -eq $true | Should -Be $expected[$seed][1] -Because "$seed compliant device"
        }
    }
}

Describe "Get-AuthContextMap" {
    It "finds a context by the slug of its display name" {
        $inv = New-AuthContextInventory -Name 'bySlug' -Contexts @{ 'Phish-resistant & SIF' = 'c2' }
        $map = Get-AuthContextMap -InventoryPath $inv
        $map['phish-resistant-sif'] | Should -Be 'c2'
    }

    It "does not find a differently named context by slug alone" {
        $inv = New-AuthContextInventory -Name 'otherName' -Contexts @{ 'Auth Context - Phish-resistant & SIF' = 'c5' }
        $map = Get-AuthContextMap -InventoryPath $inv
        $map.ContainsKey('phish-resistant-sif') | Should -BeFalse
        $map['auth-context-phish-resistant-sif'] | Should -Be 'c5'
    }

    It "resolves a label through the mapping file, by claim value" {
        $inv = New-AuthContextInventory -Name 'mapClaim' -Contexts @{ 'Auth Context - Phish-resistant & SIF' = 'c5' }
        $mapFile = Join-Path $TestDrive 'mapClaim.json'
        '{ "phish-resistant-sif": "c5" }' | Set-Content -Path $mapFile
        (Get-AuthContextMap -InventoryPath $inv -MappingFile $mapFile)['phish-resistant-sif'] | Should -Be 'c5'
    }

    It "resolves a label through the mapping file, by display name" {
        $inv = New-AuthContextInventory -Name 'mapName' -Contexts @{ 'Auth Context - Phish-resistant & SIF' = 'c5' }
        $mapFile = Join-Path $TestDrive 'mapName.json'
        '{ "phish-resistant-sif": "Auth Context - Phish-resistant & SIF" }' | Set-Content -Path $mapFile
        (Get-AuthContextMap -InventoryPath $inv -MappingFile $mapFile)['phish-resistant-sif'] | Should -Be 'c5'
    }

    It "prefers the mapping file over the slug rule" {
        $inv = New-AuthContextInventory -Name 'mapWins' -Contexts @{ 'Phish-resistant & SIF' = 'c2'; 'Other' = 'c9' }
        $mapFile = Join-Path $TestDrive 'mapWins.json'
        '{ "phish-resistant-sif": "c9" }' | Set-Content -Path $mapFile
        (Get-AuthContextMap -InventoryPath $inv -MappingFile $mapFile)['phish-resistant-sif'] | Should -Be 'c9'
    }

    It "ignores a mapping entry that matches no tenant context" {
        $inv = New-AuthContextInventory -Name 'mapBad' -Contexts @{ 'Phish-resistant & SIF' = 'c2' }
        $mapFile = Join-Path $TestDrive 'mapBad.json'
        '{ "phish-resistant-no-sif": "c99" }' | Set-Content -Path $mapFile
        $map = Get-AuthContextMap -InventoryPath $inv -MappingFile $mapFile 3>$null
        $map.ContainsKey('phish-resistant-no-sif') | Should -BeFalse
    }

    It "resolves a seed by requirements when exactly one context qualifies" {
        $inv = New-AuthContextInventory -Name 'byReq' -Contexts @{ 'Auth Context - Phish-resistant & SIF' = 'c2'; 'Unrelated' = 'c3' } -Seeds @('phish-resistant-sif')
        $policy = Get-Content -Raw (Join-Path $script:fixtures 'ca-policies/policy-enforcing.json') | ConvertFrom-Json
        $map = Get-AuthContextMap -InventoryPath $inv -CaPolicies @($policy)
        $map['phish-resistant-sif'] | Should -Be 'c2'
    }

    It "leaves a seed unresolved when no context qualifies" {
        $inv = New-AuthContextInventory -Name 'noReq' -Contexts @{ 'Something' = 'c3' } -Seeds @('phish-resistant-sif')
        $policy = Get-Content -Raw (Join-Path $script:fixtures 'ca-policies/policy-enforcing.json') | ConvertFrom-Json
        (Get-AuthContextMap -InventoryPath $inv -CaPolicies @($policy)).ContainsKey('phish-resistant-sif') | Should -BeFalse
    }

    It "leaves a seed unresolved when several contexts qualify" {
        $inv = New-AuthContextInventory -Name 'twoReq' -Contexts @{ 'First' = 'c2'; 'Second' = 'c3' } -Seeds @('phish-resistant-sif')
        $p2 = Get-Content -Raw (Join-Path $script:fixtures 'ca-policies/policy-enforcing.json') | ConvertFrom-Json
        $p3 = Get-Content -Raw (Join-Path $script:fixtures 'ca-policies/policy-enforcing.json') | ConvertFrom-Json
        $p3.conditions.applications.includeAuthenticationContextClassReferences = @('c3')
        (Get-AuthContextMap -InventoryPath $inv -CaPolicies @($p2, $p3)).ContainsKey('phish-resistant-sif') | Should -BeFalse
    }
}

Describe "Auth context not found is reported, not silent" {
    It "emits one auth-context-resolution entry per unresolved slug for role tiers" {
        $roleResults = @(@{ error = $true; definition = @{ id = 'x' } })
        $tiers = @((New-Tier -Name 'Control - Privileged' -AuthContext 'phish-resistant-sif'), (New-Tier -Name 'Management - Privileged' -AuthContext 'phish-resistant-sif'))
        $violations = @(Get-ComplianceViolations -TierDefinitions $tiers -RoleResults $roleResults -AuthContextMap @{} 3>$null)
        $entries = @($violations | Where-Object { $_.fileType -eq 'auth-context-resolution' })
        $entries.Count | Should -Be 1
        $entries[0].ruleId | Should -Be 'authContextUnresolved'
        $entries[0].entity | Should -Be 'phish-resistant-sif'
        $entries[0].severity | Should -Be 'Medium'
        $entries[0].isAlert | Should -BeTrue
    }

    It "emits nothing when the slug resolves" {
        $roleResults = @(@{ error = $true; definition = @{ id = 'x' } })
        $tiers = @(New-Tier -Name 'Control - Privileged' -AuthContext 'phish-resistant-sif')
        $violations = @(Get-ComplianceViolations -TierDefinitions $tiers -RoleResults $roleResults -AuthContextMap @{ 'phish-resistant-sif' = 'c2' })
        @($violations | Where-Object { $_.fileType -eq 'auth-context-resolution' }).Count | Should -Be 0
    }

    It "renders the new fileType under the compliance section of notifications" {
        . (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../src')) 'notifications-shared.ps1')
        $script:ComplianceFileTypes.Contains('auth-context-resolution') | Should -BeTrue
    }

    It "checks a seed folder against the context it resolved to" {
        $inv = New-AuthContextInventory -Name 'seedCheck' -Contexts @{ 'Auth Context - Phish-resistant & SIF' = 'c2' } -Seeds @('phish-resistant-sif')
        $policy = Get-Content -Raw (Join-Path $script:fixtures 'ca-policies/policy-weak-auth.json') | ConvertFrom-Json
        $policy.conditions.applications.includeAuthenticationContextClassReferences = @('c2')
        $v = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inv -AuthContextMap @{ 'phish-resistant-sif' = 'c2' })
        @($v | Where-Object { $_.ruleId -eq 'requireAuthStrengthId' }).Count | Should -Be 1
    }
}
