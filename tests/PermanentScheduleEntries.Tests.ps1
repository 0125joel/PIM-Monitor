#requires -Version 7
Set-StrictMode -Version Latest

<#
Regression: roleAssignmentSchedules also returns permanent direct assignments
(assignmentType 'Assigned', expiration 'noExpiration'). Those were listed twice, once under
permanent and once under active. Test-PermanentScheduleEntry identifies them so the scan can
drop them from active. PIM activations and time-bound assignments must be kept.
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")

    function New-ScheduleEntry {
        param(
            [Parameter(Mandatory)] [string] $AssignmentType,
            [Parameter(Mandatory)] [string] $ExpirationType
        )
        [pscustomobject]@{
            assignmentType = $AssignmentType
            memberType     = 'Direct'
            scheduleInfo   = [pscustomobject]@{ expiration = [pscustomobject]@{ type = $ExpirationType } }
        }
    }
}

Describe 'Test-PermanentScheduleEntry' {
    It 'flags a permanent direct assignment (Assigned, noExpiration)' {
        Test-PermanentScheduleEntry -Entry (New-ScheduleEntry -AssignmentType 'Assigned' -ExpirationType 'noExpiration') | Should -BeTrue
    }

    It 'keeps a PIM activation (Activated)' {
        Test-PermanentScheduleEntry -Entry (New-ScheduleEntry -AssignmentType 'Activated' -ExpirationType 'afterDateTime') | Should -BeFalse
    }

    It 'keeps a time-bound direct assignment (Assigned, afterDateTime)' {
        Test-PermanentScheduleEntry -Entry (New-ScheduleEntry -AssignmentType 'Assigned' -ExpirationType 'afterDateTime') | Should -BeFalse
    }

    It 'works on hashtable entries as well as PSCustomObject entries' {
        $permanent = @{ assignmentType = 'Assigned'; scheduleInfo = @{ expiration = @{ type = 'noExpiration' } } }
        $activated = @{ assignmentType = 'Activated'; scheduleInfo = @{ expiration = @{ type = 'afterDateTime' } } }
        Test-PermanentScheduleEntry -Entry $permanent | Should -BeTrue
        Test-PermanentScheduleEntry -Entry $activated | Should -BeFalse
    }

    It 'returns false for null and for entries without schedule information' {
        Test-PermanentScheduleEntry -Entry $null | Should -BeFalse
        Test-PermanentScheduleEntry -Entry ([pscustomobject]@{ principalId = 'x' }) | Should -BeFalse
    }
}
