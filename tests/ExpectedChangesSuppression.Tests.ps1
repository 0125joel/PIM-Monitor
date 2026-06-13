#requires -Version 7
Set-StrictMode -Version Latest

<#
End-to-end expected-changes suppression tests.

Guards against the regression where diff.ps1 producers emitted change entries without
workload/entity/fileType keys, so every documented expectation (the docs instruct users
to always include workload + entity + fileType) silently failed to match inventory diffs.

Fixture discipline:
- Previous inventory state is written to disk and read back through Compare-InventoryFolder,
  exactly like production (ConvertFrom-Json output, PSCustomObject).
- New data uses a ConvertTo-Json/ConvertFrom-Json round-trip where production delivers
  Graph API responses (PSCustomObject), never bare hashtable entries: PSObject.Properties
  behaves differently on hashtables (LessonsLearned 2026-06-11) and a hashtable fixture
  would not exercise the production code path.
- Expectations are built via ConvertFrom-Json to mirror expected-changes.json parsing.

The expectation shapes mirror Examples/expected-changes/01 (policy + ruleId) and
04 (assignments), with a far-future expiresUtc so the entries are not expired.
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")

    function New-InventoryTestFolder {
        param(
            [Parameter(Mandatory)] [string] $Workload,
            [Parameter(Mandatory)] [string] $Slug,
            [Parameter(Mandatory)] [hashtable] $Files
        )
        $folder = Join-Path -Path $TestDrive -ChildPath "inventory/$Workload/$Slug"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        foreach ($fileType in $Files.Keys) {
            $json = ConvertTo-DeterministicJson -InputObject $Files[$fileType]
            Set-Content -Path (Join-Path $folder "$fileType.json") -Value $json -Encoding utf8NoBOM
        }
        return $folder
    }

    function ConvertTo-GraphShape {
        # JSON round-trip: hashtable fixture -> PSCustomObject, the shape Graph API data has in production.
        param([Parameter(Mandatory)] $InputObject)
        return $InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    }

    function ConvertTo-Expectations {
        param([Parameter(Mandatory)] [string] $Json)
        return @(($Json | ConvertFrom-Json).expected)
    }
}

Describe "Expected-changes suppression: policy rule change (Example 01 shape)" {
    BeforeAll {
        $oldPolicy = @{
            policy = @{
                rules = @(
                    @{ id = 'Expiration_EndUser_Assignment'; maximumDuration = 'PT8H' },
                    @{ id = 'Enablement_EndUser_Assignment'; enabledRules = @('MultiFactorAuthentication') }
                )
            }
        }
        $newPolicy = @{
            policy = @{
                rules = @(
                    @{ id = 'Expiration_EndUser_Assignment'; maximumDuration = 'PT1H' },
                    @{ id = 'Enablement_EndUser_Assignment'; enabledRules = @('MultiFactorAuthentication') }
                )
            }
        }
        $folder = New-InventoryTestFolder -Workload 'directory-roles' -Slug 'global-administrator' -Files @{ policy = $oldPolicy }
        $script:policyChanges = @(Compare-InventoryFolder `
            -FolderPath $folder `
            -NewData @{ policy = (ConvertTo-GraphShape $newPolicy) } `
            -EntityName 'Global Administrator')
    }

    It "emits exactly one change with workload, entity, fileType and ruleId" {
        $script:policyChanges.Count | Should -Be 1
        $change = $script:policyChanges[0]
        $change['workload'] | Should -Be 'directory-roles'
        $change['entity']   | Should -Be 'global-administrator'
        $change['fileType'] | Should -Be 'policy'
        $change['ruleId']   | Should -Be 'Expiration_EndUser_Assignment'
    }

    It "is suppressed by an Example-01-shaped expectation" {
        $expectations = ConvertTo-Expectations '{
            "expected": [
                {
                    "workload": "directory-roles",
                    "entity": "global-administrator",
                    "fileType": "policy",
                    "ruleId": "Expiration_EndUser_Assignment",
                    "reason": "planned policy tightening",
                    "expiresUtc": "2099-01-01T00:00:00Z"
                }
            ]
        }'
        Test-ChangeIsExpected -Change $script:policyChanges[0] -Expectations $expectations | Should -BeTrue
    }

    It "is not suppressed when the expectation targets another entity" {
        $expectations = ConvertTo-Expectations '{
            "expected": [
                { "workload": "directory-roles", "entity": "exchange-administrator", "fileType": "policy" }
            ]
        }'
        Test-ChangeIsExpected -Change $script:policyChanges[0] -Expectations $expectations | Should -BeFalse
    }

    It "is not suppressed when the expectation targets another ruleId" {
        $expectations = ConvertTo-Expectations '{
            "expected": [
                { "workload": "directory-roles", "entity": "global-administrator", "fileType": "policy", "ruleId": "Approval_EndUser_Assignment" }
            ]
        }'
        Test-ChangeIsExpected -Change $script:policyChanges[0] -Expectations $expectations | Should -BeFalse
    }

    It "is not suppressed when the expectation has expired" {
        $expectations = ConvertTo-Expectations '{
            "expected": [
                { "workload": "directory-roles", "entity": "global-administrator", "fileType": "policy", "expiresUtc": "2020-01-01T00:00:00Z" }
            ]
        }'
        Test-ChangeIsExpected -Change $script:policyChanges[0] -Expectations $expectations | Should -BeFalse
    }
}

Describe "Expected-changes suppression: assignment change (Example 04 shape)" {
    BeforeAll {
        $oldAssignments = @{
            permanent = @()
            eligible  = @(@{ principalId = '00000000-0000-0000-0000-000000000001'; directoryScopeId = '/' })
            active    = @()
        }
        $newAssignments = @{
            permanent = @()
            eligible  = @(
                @{ principalId = '00000000-0000-0000-0000-000000000001'; directoryScopeId = '/' },
                @{ principalId = '00000000-0000-0000-0000-000000000002'; directoryScopeId = '/' }
            )
            active    = @()
        }
        $folder = New-InventoryTestFolder -Workload 'directory-roles' -Slug 'helpdesk-administrator' -Files @{ assignments = $oldAssignments }
        $script:assignmentChanges = @(Compare-InventoryFolder `
            -FolderPath $folder `
            -NewData @{ assignments = (ConvertTo-GraphShape $newAssignments) } `
            -EntityName 'Helpdesk Administrator')
    }

    It "stamps workload, entity and fileType on assignment entries" {
        $script:assignmentChanges.Count | Should -Be 1
        $script:assignmentChanges[0]['workload'] | Should -Be 'directory-roles'
        $script:assignmentChanges[0]['entity']   | Should -Be 'helpdesk-administrator'
        $script:assignmentChanges[0]['fileType'] | Should -Be 'assignments'
    }

    It "is suppressed by a workload + entity + fileType expectation" {
        $expectations = ConvertTo-Expectations '{
            "expected": [
                {
                    "workload": "directory-roles",
                    "entity": "helpdesk-administrator",
                    "fileType": "assignments",
                    "reason": "bulk assignment cleanup",
                    "expiresUtc": "2099-01-01T00:00:00Z"
                }
            ]
        }'
        Test-ChangeIsExpected -Change $script:assignmentChanges[0] -Expectations $expectations | Should -BeTrue
    }
}

Describe "Expected-changes suppression: removed entities and expiring assignments" {
    It "Get-RemovedEntities stamps workload and entity" {
        $workloadPath = Join-Path $TestDrive 'inventory-removed/pim-groups'
        New-Item -ItemType Directory -Path (Join-Path $workloadPath 'tier-0-admins') -Force | Out-Null

        $entries = @(Get-RemovedEntities -WorkloadPath $workloadPath -CurrentSlugs @())
        $entries.Count | Should -Be 1
        $entries[0]['workload'] | Should -Be 'pim-groups'
        $entries[0]['entity']   | Should -Be 'tier-0-admins'
        $entries[0]['fileType'] | Should -Be 'definition'
    }

    It "Find-ExpiringAssignments stamps workload, entity and fileType" {
        $end = (Get-Date -AsUTC).AddDays(3).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $assignment = ConvertTo-GraphShape @{
            principalId  = '00000000-0000-0000-0000-000000000001'
            principal    = @{ displayName = 'Test User' }
            scheduleInfo = @{ expiration = @{ endDateTime = $end } }
        }
        $assignments = @{ 'global-administrator' = @{ eligible = @($assignment) } }

        $entries = @(Find-ExpiringAssignments -Assignments $assignments -WindowDays 14 -Workload 'directory-roles')
        $entries.Count | Should -Be 1
        $entries[0]['workload'] | Should -Be 'directory-roles'
        $entries[0]['entity']   | Should -Be 'global-administrator'
        $entries[0]['fileType'] | Should -Be 'assignments'
    }
}
