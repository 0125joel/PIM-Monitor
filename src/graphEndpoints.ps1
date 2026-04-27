<#
.SYNOPSIS
    Centralized Graph API endpoint configuration for PIM Monitor.

.DESCRIPTION
    All Graph API URIs in one place. Separates v1.0 from beta, documents why
    beta is needed, and provides URI-builder functions for per-item endpoints.

    Import: . (Join-Path $PSScriptRoot "graphEndpoints.ps1")
    Usage:  $uri = Get-RolePolicyUri -RoleId $roleId
#>

# Base URLs

$script:GraphV1 = "https://graph.microsoft.com/v1.0"
$script:GraphBeta = "https://graph.microsoft.com/beta"

# Collection Endpoints (fetch all items, no per-item filter)

$script:GraphEndpoints = @{

    # --- Directory Roles ---

    # Beta: required for isPrivileged, allowedPrincipalTypes, version
    RoleDefinitions = "$script:GraphBeta/roleManagement/directory/roleDefinitions"

    # --- Lookups ---

    # v1.0: tenant display name and verified domains
    Organization = "$script:GraphV1/organization?`$select=displayName,id"

    # v1.0: authentication context class references (resolve claimValue → displayName)
    AuthenticationContexts = "$script:GraphV1/identity/conditionalAccess/authenticationContextClassReferences"

    # v1.0: administrative units (resolve directoryScopeId → displayName)
    AdministrativeUnits = "$script:GraphV1/directory/administrativeUnits"

    # --- PIM Groups (Phase 2) ---

    # Beta: discover which groups are PIM-onboarded. Deprecated Oct 2026 —
    # when removed, Graph will need an alternative discovery path.
    # The unfiltered eligibilityScheduleInstances/assignmentScheduleInstances
    # collection endpoints REQUIRE $filter=groupId eq '...' and cannot be used
    # for discovery; per-group URI builders below are used for assignment fetches.
    GroupResources = "$script:GraphBeta/identityGovernance/privilegedAccess/group/resources"
}

# Per-Item URI Builders

<#
.SYNOPSIS
    Builds the policy assignment URI for a specific Directory Role.
.PARAMETER RoleId
    The role definition ID.
#>
function Get-RolePolicyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    # v1.0: policy rules fully available for Directory scope
    return "$script:GraphV1/policies/roleManagementPolicyAssignments?" +
        "`$filter=scopeId eq '/' and scopeType eq 'Directory' and roleDefinitionId eq '$RoleId'&" +
        "`$expand=policy(`$expand=rules)"
}

<#
.SYNOPSIS
    Builds the permanent role assignments URI for a specific role.
.PARAMETER RoleId
    The role definition ID.
#>
function Get-RolePermanentAssignmentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    # v1.0: direct role assignments (non-PIM)
    return "$script:GraphV1/roleManagement/directory/roleAssignments?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

<#
.SYNOPSIS
    Builds the eligible assignments URI for a specific role.
.PARAMETER RoleId
    The role definition ID.
#>
function Get-RoleEligibleAssignmentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    # v1.0: PIM eligible schedules
    return "$script:GraphV1/roleManagement/directory/roleEligibilitySchedules?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

<#
.SYNOPSIS
    Builds the active assignments URI for a specific role.
.PARAMETER RoleId
    The role definition ID.
#>
function Get-RoleActiveAssignmentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    # v1.0: PIM active/activated schedules
    return "$script:GraphV1/roleManagement/directory/roleAssignmentSchedules?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

<#
.SYNOPSIS
    Builds the group definition URI.
.PARAMETER GroupId
    The group object ID.
#>
function Get-GroupDefinitionUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    # v1.0: group properties
    return "$script:GraphV1/groups/$GroupId"
}

<#
.SYNOPSIS
    Builds the PIM Group policy URI.
.PARAMETER GroupId
    The group object ID.
#>
function Get-GroupPolicyUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    # Beta: scopeType eq 'Group' filter only works in beta
    return "$script:GraphBeta/policies/roleManagementPolicyAssignments?" +
        "`$filter=scopeId eq '$GroupId' and scopeType eq 'Group'&" +
        "`$expand=policy(`$expand=rules)"
}

<#
.SYNOPSIS
    Builds the PIM Group eligible assignments URI.
.PARAMETER GroupId
    The group object ID.
#>
function Get-GroupEligibleAssignmentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    # v1.0: PIM Group eligible schedule instances
    return "$script:GraphV1/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?" +
        "`$filter=groupId eq '$GroupId'&" +
        "`$expand=principal"
}

<#
.SYNOPSIS
    Builds the PIM Group active assignments URI.
.PARAMETER GroupId
    The group object ID.
#>
function Get-GroupActiveAssignmentsUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    # v1.0: PIM Group assignment schedule instances
    return "$script:GraphV1/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?" +
        "`$filter=groupId eq '$GroupId'&" +
        "`$expand=principal"
}

<#
.SYNOPSIS
    Builds the audit log URI to fetch PIM-related events since a given time.

.PARAMETER Since
    ISO 8601 UTC datetime to fetch events after (e.g., "2026-04-01T00:00:00Z").
#>
function Get-AuditLogsPimUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Since
    )

    # v1.0: audit logs filtered by PIM service and after a specific datetime
    return "$script:GraphV1/auditLogs/directoryAudits?" +
        "`$filter=loggedByService eq 'PIM' and activityDateTime ge $Since&" +
        "`$orderby=activityDateTime desc"
}
