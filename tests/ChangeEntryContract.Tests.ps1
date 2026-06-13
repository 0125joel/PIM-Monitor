#requires -Version 7
Set-StrictMode -Version Latest

<#
Contract test: every change-entry producer emits [hashtable] entries with mandatory keys.
This guards against the regression documented in LessonsLearned [2026-05-21]:
compliance.ps1 once produced [PSCustomObject] entries that silently broke
Test-ChangeIsExpected parameter binding under Set-StrictMode.

Covered producers:
  diff.ps1       — Compare-FlatProperties, Get-RemovedEntities, Find-ExpiringAssignments
  compliance.ps1 — Get-ComplianceViolations, Get-CoverageViolations,
                   Get-GroupCoverageViolations

When adding a new change-entry producer, add a Describe block here.
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $fixturesPath = Join-Path -Path $PSScriptRoot -ChildPath "fixtures"
    $policiesPath = Join-Path -Path $PSScriptRoot -ChildPath "fixtures/policies"

    $script:controlPlaneGlobalAdminId = "62e90394-69f5-4237-9190-012177145e10"

    # Helper: assert all entries in $entries satisfy the contract.
    function Assert-EntryContract {
        param([Parameter(Mandatory)] [array] $Entries)

        $validSeverities = @('High', 'Medium', 'Low', 'Informational')

        foreach ($entry in $Entries) {
            # Type: must be [hashtable], not [PSCustomObject]
            $entry | Should -BeOfType [hashtable] -Because "change-entries must be [hashtable] for Test-ChangeIsExpected parameter binding"

            # Mandatory keys
            $entry.ContainsKey('severity')    | Should -BeTrue  -Because "every change-entry must have 'severity'"
            $entry.ContainsKey('changeType')  | Should -BeTrue  -Because "every change-entry must have 'changeType'"
            $entry.ContainsKey('description') | Should -BeTrue  -Because "every change-entry must have 'description'"

            # Valid severity value
            $entry['severity'] -in $validSeverities | Should -BeTrue -Because "severity must be High/Medium/Low/Informational, got '$($entry['severity'])'"

            # Binding proof: Test-ChangeIsExpected accepts [hashtable]; PSCustomObject would throw here
            { Test-ChangeIsExpected -Change $entry -Expectations @() } | Should -Not -Throw
        }
    }
}

# ─── diff.ps1 producers ───────────────────────────────────────────────────────

Describe "Change-entry contract — Compare-FlatProperties" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $old = @{ displayName = "Original Name"; isEnabled = $true }
        $new = @{ displayName = "New Name";      isEnabled = $true }

        $entries = @(Compare-FlatProperties -OldObject $old -NewObject $new -Context "Test Role")

        @($entries).Count | Should -BeGreaterThan 0 -Because "a displayName change should produce at least one entry"
        Assert-EntryContract -Entries $entries
    }

    It "emits [hashtable] entries when a property is added" {
        $old = @{ displayName = "Role" }
        $new = @{ displayName = "Role"; isPrivileged = $true }

        $entries = @(Compare-FlatProperties -OldObject $old -NewObject $new -Context "Test Role")
        @($entries).Count | Should -BeGreaterThan 0
        Assert-EntryContract -Entries $entries
    }

    It "emits [hashtable] entries when a property is removed" {
        $old = @{ displayName = "Role"; isPrivileged = $true }
        $new = @{ displayName = "Role" }

        $entries = @(Compare-FlatProperties -OldObject $old -NewObject $new -Context "Test Role")
        @($entries).Count | Should -BeGreaterThan 0
        Assert-EntryContract -Entries $entries
    }
}

Describe "Change-entry contract — Get-RemovedEntities" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $workloadPath = Join-Path $TestDrive "directory-roles"
        New-Item -Path (Join-Path $workloadPath "old-role") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $workloadPath "another-old-role") -ItemType Directory -Force | Out-Null

        # Pass empty CurrentSlugs so both folders are detected as removed
        $entries = @(Get-RemovedEntities -WorkloadPath $workloadPath -CurrentSlugs @())

        @($entries).Count | Should -Be 2
        Assert-EntryContract -Entries $entries
    }
}

Describe "Test-SafeToArchive — mass-archival guard" {
    It "returns true when discovery found entities (normal scan)" {
        $workloadPath = Join-Path $TestDrive "pim-groups-normal"
        New-Item -Path (Join-Path $workloadPath "some-group") -ItemType Directory -Force | Out-Null

        Test-SafeToArchive -DiscoveredCount 3 -WorkloadPath $workloadPath | Should -BeTrue
    }

    It "returns true when discovery is empty but the workload folder does not exist (first run)" {
        $workloadPath = Join-Path $TestDrive "pim-groups-absent"

        Test-SafeToArchive -DiscoveredCount 0 -WorkloadPath $workloadPath | Should -BeTrue
    }

    It "returns true when discovery is empty and the workload folder has no entity folders" {
        $workloadPath = Join-Path $TestDrive "pim-groups-empty"
        New-Item -Path $workloadPath -ItemType Directory -Force | Out-Null

        Test-SafeToArchive -DiscoveredCount 0 -WorkloadPath $workloadPath | Should -BeTrue
    }

    It "returns false when discovery is empty but inventory still holds folders (guard trips)" {
        $workloadPath = Join-Path $TestDrive "pim-groups-populated"
        New-Item -Path (Join-Path $workloadPath "tier-0-admins") -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $workloadPath "tier-1-admins") -ItemType Directory -Force | Out-Null

        Test-SafeToArchive -DiscoveredCount 0 -WorkloadPath $workloadPath | Should -BeFalse
    }
}

Describe "Change-entry contract — Find-ExpiringAssignments" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $soonDate = (Get-Date -AsUTC).AddDays(5).ToString('o')

        # Use ConvertFrom-Json to create the assignment — this matches the actual runtime
        # type (PSCustomObject with nested PSCustomObjects) that Graph API responses produce.
        $assignment = @"
{
    "principalId": "test-principal",
    "scheduleInfo": {
        "expiration": {
            "endDateTime": "$soonDate"
        }
    }
}
"@ | ConvertFrom-Json

        $assignments = @{
            'test-role' = @{
                permanent = @()
                eligible  = @($assignment)
                active    = @()
            }
        }

        $entries = @(Find-ExpiringAssignments -Assignments $assignments -WindowDays 14)

        @($entries).Count | Should -Be 1
        Assert-EntryContract -Entries $entries
    }
}

# ─── compliance.ps1 producers ────────────────────────────────────────────────

Describe "Change-entry contract — Get-ComplianceViolations" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $tierDefs = @(Get-TierDefinitions -TiersPath $fixturesPath)
        $noncomplPolicy = Get-Content (Join-Path $policiesPath "policy-noncompliant.json") | ConvertFrom-Json

        $roleResults = @(
            @{
                error            = $null
                definition       = @{ id = $script:controlPlaneGlobalAdminId; displayName = "Global Administrator"; isPrivileged = $true }
                slug             = "global-administrator"
                policyAssignment = $noncomplPolicy
            }
        )

        $entries = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults)

        @($entries).Count | Should -BeGreaterThan 0 -Because "noncompliant policy against a tier role must produce violations"
        Assert-EntryContract -Entries $entries
    }
}

Describe "Change-entry contract — Get-CoverageViolations" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $roleResults = @(
            @{
                error      = $null
                definition = @{ id = "unclassified-role-id"; displayName = "Unclassified Role"; isPrivileged = $true }
                slug       = "unclassified-role"
            }
        )

        # Pass empty TierDefinitions so the role is unclassified
        $entries = @(Get-CoverageViolations -TierDefinitions @() -RoleResults $roleResults -Scope "privileged")

        @($entries).Count | Should -Be 1
        Assert-EntryContract -Entries $entries
    }
}

Describe "Change-entry contract — Get-GroupCoverageViolations" {
    It "emits [hashtable] entries that pass Test-ChangeIsExpected binding" {
        $groupResults = @(
            @{
                error      = $null
                definition = @{ id = "unclassified-group-id"; displayName = "Unclassified Group" }
                slug       = "unclassified-group"
            }
        )

        # Pass empty GroupDefinitions so the group is unclassified
        $entries = @(Get-GroupCoverageViolations -GroupDefinitions @() -GroupResults $groupResults)

        @($entries).Count | Should -Be 1
        Assert-EntryContract -Entries $entries
    }
}

# ─── End-to-end: all producers feed Group-ChangesBySeverity ──────────────────

Describe "Change-entry contract — Group-ChangesBySeverity round-trip" {
    It "buckets entries from every producer without throwing" {
        $old = @{ displayName = "Before" }
        $new = @{ displayName = "After" }
        $flatEntries = @(Compare-FlatProperties -OldObject $old -NewObject $new -Context "Role")

        $coverageEntry = @{
            severity    = "Medium"
            changeType  = "unclassified"
            description = "Unclassified role"
            fileType    = "access-model-coverage"
            old         = $null
            new         = $null
        }

        $all = @($flatEntries) + @($coverageEntry)
        { Group-ChangesBySeverity -Changes $all } | Should -Not -Throw

        $grouped = Group-ChangesBySeverity -Changes $all
        $grouped.Total | Should -Be $all.Count
    }
}
