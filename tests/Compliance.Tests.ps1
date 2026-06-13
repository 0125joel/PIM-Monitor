BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $tiersPath    = Join-Path -Path $PSScriptRoot -ChildPath "fixtures"
    $policiesPath = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/policies"

    # IDs that match the tier fixtures (ControlPlane.json, ManagementPlane.json, DataWorkloadPlane.json)
    $controlPlaneGlobalAdminId          = "62e90394-69f5-4237-9190-012177145e10"
    $controlPlaneSecurityAdminId        = "194ae4cb-b126-40b2-bd5b-6091b380977d"
    $managementPlaneDomainNameId        = "8329153b-31d0-4727-b945-745eb3bc5f31"
    $dataWorkloadPlaneComplianceAdminId = "e8611ab8-c189-46e8-94e1-60213cd1e3ee"
}

Describe "Get-TierDefinitions" {
    It "loads all tier JSON files" {
        $tiers = @(Get-TierDefinitions -TiersPath $tiersPath)
        @($tiers).Count | Should -Be 4
    }

    It "returns empty on nonexistent path" {
        $tiers = @(Get-TierDefinitions -TiersPath "nonexistent/path")
        @($tiers).Count | Should -Be 0
    }

    It "preserves tier properties" {
        $tiers = @(Get-TierDefinitions -TiersPath $tiersPath)
        $highTier = $tiers | Where-Object { $_.severity -eq "High" } | Select-Object -First 1
        $highTier.name | Should -Be "Control Plane - Identity Infrastructure"
        $highTier.severity | Should -Be "High"
    }

    It "loads roles from access-model files" {
        $tiers = @(Get-TierDefinitions -TiersPath $tiersPath)
        $highTier = $tiers | Where-Object { $_.severity -eq "High" } | Select-Object -First 1
        @($highTier.roles).Count | Should -BeGreaterThan 0
    }
}

Describe "Get-CoverageExclusions" {
    It "returns empty on missing file" {
        $excl = Get-CoverageExclusions -TiersPath $tiersPath
        @($excl).Count | Should -Be 0
    }

    It "loads exclusions from file" {
        $file = Join-Path -Path $tiersPath -ChildPath "coverage-exclusions.json"
        @{ excludedRoleIds = @( @{ id = "test-1" } ) } | ConvertTo-Json | Set-Content -Path $file -Encoding utf8NoBOM

        $excl = Get-CoverageExclusions -TiersPath $tiersPath
        $excl.Contains("test-1") | Should -Be $true

        Remove-Item -Path $file -Force
    }
}

Describe "Test-RolePolicyCompliance" {
    BeforeEach {
        $compliantPolicy    = Get-Content (Join-Path $policiesPath "policy-compliant.json") | ConvertFrom-Json
        $noncompliantPolicy = Get-Content (Join-Path $policiesPath "policy-noncompliant.json") | ConvertFrom-Json
    }

    It "returns empty for null expectedConfig" {
        $v = @(Test-RolePolicyCompliance -RolePolicy $compliantPolicy -ExpectedConfig $null)
        @($v).Count | Should -Be 0
    }

    It "detects compliant requireApproval field" {
        $expected = @{ requireApproval = $true }
        $v = @(Test-RolePolicyCompliance -RolePolicy $compliantPolicy -ExpectedConfig $expected)
        @($v).Count | Should -Be 0
    }

    It "detects noncompliant requireApproval field" {
        $expected = @{ requireApproval = $true }
        $v = @(Test-RolePolicyCompliance -RolePolicy $noncompliantPolicy -ExpectedConfig $expected)
        @($v).Count | Should -Be 1
        $v[0].field | Should -Be "requireApproval"
        $v[0].actual | Should -Be $false
        $v[0].expected | Should -Be $true
    }

    It "detects noncompliant maxActivationDuration" {
        $expected = @{ maxActivationDuration = "PT1H" }
        $v = @(Test-RolePolicyCompliance -RolePolicy $noncompliantPolicy -ExpectedConfig $expected)
        @($v).Count | Should -Be 1
        $v[0].field | Should -Be "maxActivationDuration"
        $v[0].actual | Should -Be "PT8H"
    }

    It "detects noncompliant requireMFA via AuthContext" {
        $expected = @{ requireMFA = $true }
        $v = @(Test-RolePolicyCompliance -RolePolicy $noncompliantPolicy -ExpectedConfig $expected)
        @($v).Count | Should -Be 1
        $v[0].field | Should -Be "requireMFA"
    }

    It "supports sparse config — only checks present keys" {
        $expected = @{ requireMFA = $true }
        $v = @(Test-RolePolicyCompliance -RolePolicy $noncompliantPolicy -ExpectedConfig $expected)
        @($v).Count | Should -Be 1
    }

    It "ignores unknown expectedConfig fields with warning" {
        $expected = @{ unknownField = "value" }
        $v = @(Test-RolePolicyCompliance -RolePolicy $compliantPolicy -ExpectedConfig $expected -WarningAction SilentlyContinue)
        @($v).Count | Should -Be 0
    }
}

Describe "Get-ComplianceViolations" {
    BeforeEach {
        $noncomplPolicy = Get-Content (Join-Path $policiesPath "policy-noncompliant.json") | ConvertFrom-Json
        $complPolicy    = Get-Content (Join-Path $policiesPath "policy-compliant.json") | ConvertFrom-Json
        $tierDefs       = @(Get-TierDefinitions -TiersPath $tiersPath)

        $roleResults = @(
            @{
                error = $null
                definition = @{ id = $controlPlaneGlobalAdminId; displayName = "Global Administrator"; isPrivileged = $true }
                slug = "global-administrator"
                policyAssignment = $noncomplPolicy
            },
            @{
                error = $null
                definition = @{ id = $dataWorkloadPlaneComplianceAdminId; displayName = "Compliance Administrator"; isPrivileged = $false }
                slug = "compliance-administrator"
                policyAssignment = $complPolicy
            }
        )
    }

    It "produces violations from noncompliant policy" {
        $v = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)
        @($v).Count | Should -BeGreaterThan 0
    }

    It "severity matches tier definition" {
        $v = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)
        @($v | Where-Object { $_.severity -eq "High" }).Count | Should -BeGreaterThan 0
    }

    It "sets fileType=access-model-compliance for suppression" {
        $v = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)
        if (@($v).Count -gt 0) {
            $v[0].fileType | Should -Be "access-model-compliance"
            $v[0].workload | Should -Be "directory-roles"
            $v[0].entity   | Should -Not -BeNullOrEmpty
        }
    }

    It "skips tiers without expectedConfig" {
        # DataWorkloadPlane (Compliance Admin) has no expectedConfig, so Compliance Admin should generate no compliance violations
        $v = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)
        @($v | Where-Object { $_.context -eq "Compliance Administrator" }).Count | Should -Be 0
    }
}

Describe "Get-CoverageViolations" {
    BeforeEach {
        $complPolicy = Get-Content (Join-Path $policiesPath "policy-compliant.json") | ConvertFrom-Json
        $tierDefs    = @(Get-TierDefinitions -TiersPath $tiersPath)

        # Tier fixtures classify: GlobalAdmin (ControlPlane), DomainName (ManagementPlane), ComplianceAdmin (DataWorkloadPlane)
        $roleResults = @(
            @{ error = $null; definition = @{ id = $controlPlaneGlobalAdminId; displayName = "Global Administrator"; isPrivileged = $true }; slug = "global-administrator"; policy = $complPolicy },
            @{ error = $null; definition = @{ id = "unclass-priv-id"; displayName = "Unclassified Privileged"; isPrivileged = $true }; slug = "unclass-priv"; policy = $complPolicy },
            @{ error = $null; definition = @{ id = "unclass-std-id"; displayName = "Unclassified Standard"; isPrivileged = $false }; slug = "unclass-std"; policy = $complPolicy }
        )
    }

    It "detects unclassified privileged roles with scope=privileged" {
        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Scope "privileged")
        @($v).Count | Should -Be 1
        $v[0].context | Should -Be "Unclassified Privileged"
    }

    It "detects all unclassified roles with scope=all" {
        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Scope "all")
        @($v).Count | Should -Be 2
        @($v.context) | Should -Contain "Unclassified Privileged"
        @($v.context) | Should -Contain "Unclassified Standard"
    }

    It "respects exclusion list" {
        $excl = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $excl.Add("unclass-priv-id") | Out-Null

        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Exclusions $excl -Scope "all")
        @($v).Count | Should -Be 1
        $v[0].context | Should -Be "Unclassified Standard"
    }

    It "uses Medium severity" {
        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Scope "all")
        @($v | Where-Object { $_.severity -eq "Medium" }).Count | Should -Be @($v).Count
    }

    It "uses fileType=access-model-coverage" {
        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Scope "all")
        if (@($v).Count -gt 0) {
            $v[0].fileType | Should -Be "access-model-coverage"
        }
    }
}

Describe "Integration — Group-ChangesBySeverity" {
    It "buckets High-severity compliance violations correctly" {
        $tierDefs    = @(Get-TierDefinitions -TiersPath $tiersPath)
        $noncomplPolicy = Get-Content (Join-Path $policiesPath "policy-noncompliant.json") | ConvertFrom-Json

        $roleResults = @(
            @{ error = $null; definition = @{ id = $controlPlaneGlobalAdminId; displayName = "Global Admin"; isPrivileged = $true }; slug = "global-administrator"; policyAssignment = $noncomplPolicy }
        )

        $v = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)
        $grouped = Group-ChangesBySeverity -Changes $v

        $grouped.High.Count | Should -BeGreaterThan 0
        $grouped.Total | Should -Be @($v).Count
    }

    It "buckets Medium-severity coverage violations correctly" {
        $tierDefs    = @(Get-TierDefinitions -TiersPath $tiersPath)
        $complPolicy = Get-Content (Join-Path $policiesPath "policy-compliant.json") | ConvertFrom-Json

        $roleResults = @(
            @{ error = $null; definition = @{ id = "unclass-id"; displayName = "Unclassified"; isPrivileged = $true }; slug = "unclass"; policyAssignment = $complPolicy }
        )

        $v = @(Get-CoverageViolations -TierDefinitions $tierDefs -RoleResults $roleResults -Scope "all")
        $grouped = Group-ChangesBySeverity -Changes $v

        @($grouped.Coverage).Count | Should -BeGreaterThan 0
    }
}
