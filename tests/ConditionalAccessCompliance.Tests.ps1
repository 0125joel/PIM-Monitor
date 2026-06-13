BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $caPoliciesPath  = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/ca-policies"
    $inventoryPath   = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/inventory"

    function Load-Fixture {
        param([string] $Path)
        return Get-Content -Path $Path -Raw -Encoding utf8NoBOM | ConvertFrom-Json
    }
}

Describe "Get-AuthContextPolicyCompliance" {

    It "returns no violations when compliant enforcing policy matches all requirements" {
        $policy     = Load-Fixture (Join-Path $caPoliciesPath "policy-enforcing.json")
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inventoryPath)
        $violations.Count | Should -Be 0
    }

    It "emits a High violation when no CA policy covers the auth context claim" {
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @() -InventoryPath $inventoryPath)
        $violations.Count | Should -BeGreaterThan 0
        $v = $violations | Where-Object { $_.ruleId -eq 'policyExists' }
        $v | Should -Not -BeNullOrEmpty
        $v.severity | Should -Be 'High'
        $v.workload  | Should -Be 'conditional-access'
        $v.fileType  | Should -Be 'auth-context-policy-compliance'
    }

    It "emits a High violation when only a report-only policy is found" {
        $policy     = Load-Fixture (Join-Path $caPoliciesPath "policy-report-only.json")
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inventoryPath)
        $stateViolations = @($violations | Where-Object { $_.ruleId -eq 'requireState' })
        $stateViolations.Count | Should -Be 1
        $stateViolations[0].old | Should -Be 'enabledForReportingButNotEnforced'
        $stateViolations[0].new | Should -Be 'enabled'
        $stateViolations[0].severity | Should -Be 'High'
    }

    It "emits a violation when auth strength ID does not match" {
        $policy     = Load-Fixture (Join-Path $caPoliciesPath "policy-weak-auth.json")
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inventoryPath)
        $strengthViolations = @($violations | Where-Object { $_.ruleId -eq 'requireAuthStrengthId' })
        $strengthViolations.Count | Should -Be 1
        $strengthViolations[0].old | Should -Be '00000000-0000-0000-0000-000000000001'
        $strengthViolations[0].new | Should -Be '00000000-0000-0000-0000-000000000003'
    }

    It "emits a violation when sign-in frequency is not everyTime but required" {
        $policy = Load-Fixture (Join-Path $caPoliciesPath "policy-weak-auth.json")
        # policy-weak-auth has null sessionControls, so SIF requirement should fail
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inventoryPath)
        $sifViolations = @($violations | Where-Object { $_.ruleId -eq 'requireSignInFrequencyEveryTime' })
        $sifViolations.Count | Should -Be 1
    }

    It "emits no violation for requireSignInFrequencyEveryTime when policy has everyTime" {
        $policy     = Load-Fixture (Join-Path $caPoliciesPath "policy-enforcing.json")
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $inventoryPath)
        $sifViolations = @($violations | Where-Object { $_.ruleId -eq 'requireSignInFrequencyEveryTime' })
        $sifViolations.Count | Should -Be 0
    }

    It "emits no SIF violation when requireSignInFrequencyEveryTime is false" {
        # Create a temporary inventory without SIF requirement
        $tempInventory = Join-Path $TestDrive "inventory-no-sif"
        $tempDir = Join-Path $tempInventory "authentication-contexts/no-sif-ctx"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @{ id = "c9"; displayName = "Test No SIF"; isAvailable = $true } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "definition.json") -Encoding utf8NoBOM

        @{ requireSignInFrequencyEveryTime = $false; requireState = "enabled"; requireAuthStrengthId = "00000000-0000-0000-0000-000000000003" } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "config.json") -Encoding utf8NoBOM

        $policy = [pscustomobject]@{
            state      = "enabled"
            conditions = [pscustomobject]@{
                applications = [pscustomobject]@{
                    includeAuthenticationContextClassReferences = @("c9")
                }
            }
            grantControls = [pscustomobject]@{
                authenticationStrength = [pscustomobject]@{ id = "00000000-0000-0000-0000-000000000003" }
            }
            sessionControls = $null
            displayName = "Test Policy"
        }

        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $tempInventory)
        $sifViolations = @($violations | Where-Object { $_.ruleId -eq 'requireSignInFrequencyEveryTime' })
        $sifViolations.Count | Should -Be 0
    }

    It "emits a violation when requireCompliantDevice is true but compliantDevice not in builtInControls" {
        # Use policy-weak-auth: it has no builtInControls, but compliant device is not required by
        # the phish-resistant-sif fixture (requireCompliantDevice not set). Use enforcing fixture
        # and a config that requires compliant device but points to a policy without it.
        $tempInventory = Join-Path $TestDrive "inventory-compliant-device"
        $tempDir = Join-Path $tempInventory "authentication-contexts/compliant-ctx"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @{ id = "c8"; displayName = "Compliant Device Required"; isAvailable = $true } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "definition.json") -Encoding utf8NoBOM

        @{ requireCompliantDevice = $true; requireState = "enabled"; requireAuthStrengthId = "00000000-0000-0000-0000-000000000003" } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "config.json") -Encoding utf8NoBOM

        # Policy with no builtInControls
        $policy = [pscustomobject]@{
            state      = "enabled"
            conditions = [pscustomobject]@{
                applications = [pscustomobject]@{
                    includeAuthenticationContextClassReferences = @("c8")
                }
            }
            grantControls = [pscustomobject]@{
                authenticationStrength = [pscustomobject]@{ id = "00000000-0000-0000-0000-000000000003" }
                builtInControls = @()
            }
            sessionControls = $null
            displayName = "No Compliant Device Policy"
        }

        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policy) -InventoryPath $tempInventory)
        $deviceViolations = @($violations | Where-Object { $_.ruleId -eq 'requireCompliantDevice' })
        $deviceViolations.Count | Should -Be 1
    }

    It "returns empty array when CaPolicies is empty and no config.json exists" {
        $tempInventory = Join-Path $TestDrive "inventory-empty"
        $tempDir = Join-Path $tempInventory "authentication-contexts/no-config-ctx"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        @{ id = "c7"; displayName = "No Config"; isAvailable = $true } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "definition.json") -Encoding utf8NoBOM

        # No config.json — folder should be silently skipped
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @() -InventoryPath $tempInventory)
        $violations.Count | Should -Be 0
    }

    It "skips auth context folders without config.json without error" {
        $tempInventory = Join-Path $TestDrive "inventory-skip"
        $tempDir = Join-Path $tempInventory "authentication-contexts/skip-ctx"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        @{ id = "c6"; displayName = "Skip"; isAvailable = $true } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "definition.json") -Encoding utf8NoBOM

        { Get-AuthContextPolicyCompliance -CaPolicies @() -InventoryPath $tempInventory } | Should -Not -Throw
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @() -InventoryPath $tempInventory)
        $violations.Count | Should -Be 0
    }

    It "emits warning and continues when definition.json is missing" {
        $tempInventory = Join-Path $TestDrive "inventory-no-def"
        $tempDir = Join-Path $tempInventory "authentication-contexts/no-def-ctx"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        @{ requireState = "enabled" } |
            ConvertTo-Json | Set-Content (Join-Path $tempDir "config.json") -Encoding utf8NoBOM

        { Get-AuthContextPolicyCompliance -CaPolicies @() -InventoryPath $tempInventory -WarningAction SilentlyContinue } | Should -Not -Throw
    }

    It "passes when multiple policies target the claim and at least one is compliant" {
        $policyEnforcing  = Load-Fixture (Join-Path $caPoliciesPath "policy-enforcing.json")
        $policyReportOnly = Load-Fixture (Join-Path $caPoliciesPath "policy-report-only.json")
        # Both target c2; enforcing policy satisfies all requirements
        $violations = @(Get-AuthContextPolicyCompliance -CaPolicies @($policyReportOnly, $policyEnforcing) -InventoryPath $inventoryPath)
        $violations.Count | Should -Be 0
    }
}
