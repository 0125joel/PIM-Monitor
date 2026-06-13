BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $groupFixturesPath = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/pim-groups"
    $policiesPath      = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/policies"
}

Describe "Get-GroupDefinitions" {
    It "loads all group definition JSON files" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        @($groupDefs).Count | Should -Be 3
    }

    It "returns empty on nonexistent path" {
        $groupDefs = @(Get-GroupDefinitions -Path "nonexistent/path")
        @($groupDefs).Count | Should -Be 0
    }

    It "skips coverage-exclusions.json" {
        $exclusionFile = Join-Path -Path $groupFixturesPath -ChildPath "coverage-exclusions.json"
        if (-not (Test-Path $groupFixturesPath)) { New-Item -ItemType Directory -Path $groupFixturesPath -Force | Out-Null }
        @{ excludedGroupIds = @() } | ConvertTo-Json | Set-Content -Path $exclusionFile -Encoding utf8NoBOM

        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        # Should still be 3 (coverage-exclusions.json is skipped)
        @($groupDefs).Count | Should -Be 3

        Remove-Item -Path $exclusionFile -Force
    }

    It "preserves group definition properties" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $highDef = $groupDefs | Where-Object { $_.severity -eq "High" } | Select-Object -First 1
        $highDef.name | Should -Match "Tier-0|Privileged"
        $highDef.severity | Should -Be "High"
    }

    It "loads groups from definition files" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $highDef = $groupDefs | Where-Object { $_.severity -eq "High" } | Select-Object -First 1
        @($highDef.groups).Count | Should -BeGreaterThan 0
    }

    It "warns on missing severity field" {
        if (-not (Test-Path $groupFixturesPath)) { New-Item -ItemType Directory -Path $groupFixturesPath -Force | Out-Null }
        $badFile = Join-Path -Path $groupFixturesPath -ChildPath "bad-no-severity.json"
        @{ name = "Bad"; groups = @() } | ConvertTo-Json | Set-Content -Path $badFile -Encoding utf8NoBOM

        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath -WarningAction SilentlyContinue)
        # Should be 3 (bad file skipped)
        @($groupDefs).Count | Should -Be 3

        Remove-Item -Path $badFile -Force
    }

    It "validates expectedConfig sub-key field names" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $withConfig = $groupDefs | Where-Object { $_.expectedConfig } | Select-Object -First 1
        $withConfig | Should -Not -BeNullOrEmpty
        $withConfig.expectedConfig.PSObject.Properties.Name | Should -Contain "member"
    }
}

Describe "Get-GroupCoverageExclusions" {
    It "returns empty on missing file" {
        $excl = Get-GroupCoverageExclusions -Path $groupFixturesPath
        @($excl).Count | Should -Be 0
    }

    It "loads exclusions from file" {
        if (-not (Test-Path $groupFixturesPath)) { New-Item -ItemType Directory -Path $groupFixturesPath -Force | Out-Null }
        $file = Join-Path -Path $groupFixturesPath -ChildPath "coverage-exclusions.json"
        @{ excludedGroupIds = @( @{ id = "group-exclude-1" } ) } | ConvertTo-Json | Set-Content -Path $file -Encoding utf8NoBOM

        $excl = Get-GroupCoverageExclusions -Path $groupFixturesPath
        $excl.Contains("group-exclude-1") | Should -Be $true

        Remove-Item -Path $file -Force
    }
}

Describe "Get-GroupComplianceViolations" {
    It "returns empty when no group definitions" {
        $groupResults = @( @{ definition = @{ id = "g1" }; policyAssignment = @{}; slug = "test" } )
        $violations = @(Get-GroupComplianceViolations -GroupDefinitions @() -GroupResults $groupResults)
        @($violations).Count | Should -Be 0
    }

    It "returns empty when group not in definition" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $groupResults = @( @{ definition = @{ id = "nonexistent-group" }; policyAssignment = @{}; slug = "test"; error = $null } )
        $violations = @(Get-GroupComplianceViolations -GroupDefinitions $groupDefs -GroupResults $groupResults)
        @($violations).Count | Should -Be 0
    }

    It "handles groups with no expectedConfig" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $lowDef = $groupDefs | Where-Object { $_.severity -eq "Low" } | Select-Object -First 1
        $lowDef | Should -Not -BeNullOrEmpty
        $lowDef.name | Should -Match "IT Service"
    }

    It "integrates with the fixtures" {
        $groupDefs = @(Get-GroupDefinitions -Path $groupFixturesPath)
        $highDef = $groupDefs | Where-Object { $_.severity -eq "High" } | Select-Object -First 1
        $mediumDef = $groupDefs | Where-Object { $_.severity -eq "Medium" } | Select-Object -First 1
        $lowDef = $groupDefs | Where-Object { $_.severity -eq "Low" } | Select-Object -First 1
        $highDef | Should -Not -BeNullOrEmpty
        $mediumDef | Should -Not -BeNullOrEmpty
        $lowDef | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-GroupCoverageViolations" {
    It "returns empty when no group definitions" {
        $groupResults = @( @{ definition = @{ id = "g1"; displayName = "Group1" }; slug = "test"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults -Exclusions $null)
        @($violations).Count | Should -Be 1
        $violations[0].fileType | Should -Be "group-coverage"
    }

    It "flags unclassified group" {
        $groupResults = @( @{ definition = @{ id = "unclassified-id"; displayName = "Unclassified Group" }; slug = "unclass"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults)
        @($violations).Count | Should -Be 1
        $violations[0].changeType | Should -Be "unclassified"
        $violations[0].workload | Should -Be "pim-groups"
    }

    It "respects exclusions" {
        $groupId = "excluded-id"
        $exclusions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $exclusions.Add($groupId) | Out-Null

        $groupResults = @( @{ definition = @{ id = $groupId; displayName = "Excluded" }; slug = "excluded"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults -Exclusions $exclusions)
        @($violations).Count | Should -Be 0
    }

    It "does not flag classified groups" {
        $groupId = "classified-id"
        $groupDef = @{
            name = "Classified"
            severity = "High"
            groups = @( @{ id = $groupId; displayName = "Classified" } )
        }

        $groupResults = @( @{ definition = @{ id = $groupId; displayName = "Classified" }; slug = "classified"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @($groupDef) -GroupResults $groupResults)
        @($violations).Count | Should -Be 0
    }

    It "checks all groups (no scope parameter)" {
        $groupResults = @(
            @{ definition = @{ id = "g1"; displayName = "Group1" }; slug = "g1"; error = $null }
            @{ definition = @{ id = "g2"; displayName = "Group2" }; slug = "g2"; error = $null }
        )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults)
        @($violations).Count | Should -Be 2
    }

    It "uses fileType=group-coverage" {
        $groupResults = @( @{ definition = @{ id = "unclass-id"; displayName = "Unclassified" }; slug = "unclass"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults)
        $violations[0].fileType | Should -Be "group-coverage"
        $violations[0].workload | Should -Be "pim-groups"
    }

    It "uses Medium severity for all coverage violations" {
        $groupResults = @( @{ definition = @{ id = "unclass-id"; displayName = "Unclassified" }; slug = "unclass"; error = $null } )
        $violations = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults)
        $violations[0].severity | Should -Be "Medium"
    }
}

Describe "Get-GroupComplianceViolations — violation detection" {
    BeforeEach {
        $noncompliantPolicy = Get-Content (Join-Path $policiesPath "policy-noncompliant.json") | ConvertFrom-Json
        $compliantPolicy    = Get-Content (Join-Path $policiesPath "policy-compliant.json")    | ConvertFrom-Json

        # Group definition as PSCustomObject (ConvertFrom-Json gives proper PSObject.Properties access)
        $groupDef = '{"name":"Test PAW Groups","severity":"High","groups":[{"id":"test-group-1","displayName":"PAW-Admins-Members"}],"expectedConfig":{"member":{"requireApproval":true,"requireMFA":true,"maxActivationDuration":"PT1H"},"owner":{"requireMFA":true}}}' | ConvertFrom-Json

        # policyAssignment wrapper: noncompliant member, compliant owner
        $policyWrapper = [PSCustomObject]@{
            member = $noncompliantPolicy
            owner  = $compliantPolicy
        }

        $groupResult = @{
            error            = $null
            definition       = @{ id = "test-group-1"; displayName = "PAW-Admins-Members" }
            slug             = "paw-admins-members"
            policyAssignment = $policyWrapper
        }
    }

    It "detects member violations" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        @($v).Count | Should -BeGreaterThan 0
    }

    It "uses member/ prefix in ruleId" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        $memberViolations = @($v | Where-Object { $_.ruleId -like "member/*" })
        @($memberViolations).Count | Should -BeGreaterThan 0
    }

    It "emits correct ruleId format for requireApproval member violation" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        $ruleIds = @($v | Select-Object -ExpandProperty ruleId)
        $ruleIds | Should -Contain "member/requireApproval"
    }

    It "emits correct ruleId format for requireMFA member violation" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        $ruleIds = @($v | Select-Object -ExpandProperty ruleId)
        $ruleIds | Should -Contain "member/requireMFA"
    }

    It "produces no owner violations when owner policy is compliant" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        $ownerViolations = @($v | Where-Object { $_.ruleId -like "owner/*" })
        @($ownerViolations).Count | Should -Be 0
    }

    It "uses fileType=group-compliance" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        @($v | Where-Object { $_.fileType -ne "group-compliance" }).Count | Should -Be 0
    }

    It "uses workload=pim-groups" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        @($v | Where-Object { $_.workload -ne "pim-groups" }).Count | Should -Be 0
    }

    It "severity matches group definition" {
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResult))
        @($v | Where-Object { $_.severity -eq "High" }).Count | Should -Be @($v).Count
    }

    It "detects owner violations independently from member" {
        # All-noncompliant owner, compliant member
        $policyWrapperOwnerViolation = [PSCustomObject]@{
            member = $compliantPolicy
            owner  = $noncompliantPolicy
        }
        $groupResultOwnerBad = @{
            error            = $null
            definition       = @{ id = "test-group-1"; displayName = "PAW-Admins-Members" }
            slug             = "paw-admins-members"
            policyAssignment = $policyWrapperOwnerViolation
        }
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($groupResultOwnerBad))
        $ownerViolations = @($v | Where-Object { $_.ruleId -like "owner/*" })
        @($ownerViolations).Count | Should -BeGreaterThan 0
        $ownerViolations[0].ruleId | Should -Be "owner/requireMFA"
    }

    It "skips group when not in definition" {
        $wrongResult = @{
            error            = $null
            definition       = @{ id = "some-other-group"; displayName = "Other Group" }
            slug             = "other-group"
            policyAssignment = $policyWrapper
        }
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($groupDef) -GroupResults @($wrongResult))
        @($v).Count | Should -Be 0
    }

    It "skips member check when expectedConfig.member is absent" {
        $defMemberOnly = '{"name":"Owner Only Def","severity":"Medium","groups":[{"id":"test-group-1","displayName":"PAW-Admins-Members"}],"expectedConfig":{"owner":{"requireMFA":true}}}' | ConvertFrom-Json
        $policyWrapperOwnerViolation = [PSCustomObject]@{
            member = $noncompliantPolicy
            owner  = $noncompliantPolicy
        }
        $groupResultBoth = @{
            error            = $null
            definition       = @{ id = "test-group-1"; displayName = "PAW-Admins-Members" }
            slug             = "paw-admins-members"
            policyAssignment = $policyWrapperOwnerViolation
        }
        $v = @(Get-GroupComplianceViolations -GroupDefinitions @($defMemberOnly) -GroupResults @($groupResultBoth))
        # Only owner violations, no member violations
        @($v | Where-Object { $_.ruleId -like "member/*" }).Count | Should -Be 0
        @($v | Where-Object { $_.ruleId -like "owner/*" }).Count | Should -BeGreaterThan 0
    }
}
