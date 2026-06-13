$script:GraphV1   = "https://graph.microsoft.com/v1.0"
$script:GraphBeta = "https://graph.microsoft.com/beta"

$script:GraphEndpoints = @{
    # Beta: required for isPrivileged, allowedPrincipalTypes, version
    RoleDefinitions         = "$script:GraphBeta/roleManagement/directory/roleDefinitions"
    # $select intentional: response is used only for $tenantDisplayName in notifications, never written to inventory.
    # "No $select" principle applies to inventory-bound calls only.
    Organization            = "$script:GraphV1/organization?`$select=displayName,id"
    AuthenticationContexts  = "$script:GraphV1/identity/conditionalAccess/authenticationContextClassReferences"

    # Beta: conditions.applications.includeAuthenticationContextClassReferences is beta-only
    ConditionalAccessPolicies = "$script:GraphBeta/identity/conditionalAccess/policies"
    AdministrativeUnits     = "$script:GraphV1/directory/administrativeUnits"

    # PIM-for-Groups discovery. Iteration-3 (current) namespace; no published deprecation date.
    # NOTE: the Oct 28, 2026 PIM deprecation applies to iteration-2 /beta/privilegedAccess/aadRoles +
    # /azureResources, which this project does not use — not to this identityGovernance/.../group path.
    # This endpoint is beta and not documented as a discovery surface, so treat it as a latent risk:
    # there is no tenant-wide replacement (eligibilityScheduleInstances/assignmentScheduleInstances and
    # roleManagementPolicyAssignments all REQUIRE a groupId/scopeId filter). An empty/changed response
    # is guarded by Test-SafeToArchive in the orchestrator to prevent mass false-archival.
    GroupResources = "$script:GraphBeta/identityGovernance/privilegedAccess/group/resources"
}

function Get-RolePolicyUri {
    <#
    .SYNOPSIS
        Returns the URI for the policy assignment (including expanded rules) for a directory role.

    .PARAMETER RoleId
        The role definition ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    return "$script:GraphV1/policies/roleManagementPolicyAssignments?" +
        "`$filter=scopeId eq '/' and scopeType eq 'Directory' and roleDefinitionId eq '$RoleId'&" +
        "`$expand=policy(`$expand=rules)"
}

function Get-RolePermanentAssignmentsUri {
    <#
    .SYNOPSIS
        Returns the URI for direct (non-PIM) role assignments for a directory role.

    .DESCRIPTION
        v1.0 roleAssignments = direct (non-PIM) assignments; roleAssignmentSchedules = PIM active.

    .PARAMETER RoleId
        The role definition ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    return "$script:GraphV1/roleManagement/directory/roleAssignments?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

function Get-RoleEligibleAssignmentsUri {
    <#
    .SYNOPSIS
        Returns the URI for eligible PIM assignment schedules for a directory role.

    .PARAMETER RoleId
        The role definition ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    return "$script:GraphV1/roleManagement/directory/roleEligibilitySchedules?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

function Get-RoleActiveAssignmentsUri {
    <#
    .SYNOPSIS
        Returns the URI for active PIM assignment schedules for a directory role.

    .PARAMETER RoleId
        The role definition ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RoleId
    )

    return "$script:GraphV1/roleManagement/directory/roleAssignmentSchedules?" +
        "`$filter=roleDefinitionId eq '$RoleId'&" +
        "`$expand=principal"
}

function Get-GroupDefinitionUri {
    <#
    .SYNOPSIS
        Returns the URI for a group's definition from the Groups endpoint.

    .PARAMETER GroupId
        The group object ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    return "$script:GraphV1/groups/$GroupId"
}

function Get-GroupPolicyUri {
    <#
    .SYNOPSIS
        Returns the URI for the PIM policy assignment for a group (member or owner scope).

    .DESCRIPTION
        Uses the beta endpoint — scopeType eq 'Group' filter is not supported in v1.0.

    .PARAMETER GroupId
        The group object ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    # Beta: scopeType eq 'Group' filter not supported in v1.0
    return "$script:GraphBeta/policies/roleManagementPolicyAssignments?" +
        "`$filter=scopeId eq '$GroupId' and scopeType eq 'Group'&" +
        "`$expand=policy(`$expand=rules)"
}

function Get-GroupEligibleAssignmentsUri {
    <#
    .SYNOPSIS
        Returns the URI for eligible PIM assignment schedule instances for a group.

    .PARAMETER GroupId
        The group object ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    return "$script:GraphV1/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?" +
        "`$filter=groupId eq '$GroupId'&" +
        "`$expand=principal"
}

function Get-GroupActiveAssignmentsUri {
    <#
    .SYNOPSIS
        Returns the URI for active PIM assignment schedule instances for a group.

    .PARAMETER GroupId
        The group object ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $GroupId
    )

    return "$script:GraphV1/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?" +
        "`$filter=groupId eq '$GroupId'&" +
        "`$expand=principal"
}

function Get-AuditLogsPimUri {
    <#
    .SYNOPSIS
        Returns the URI for PIM-related directory audit log entries since a given date.

    .PARAMETER Since
        ISO 8601 datetime string used as the lower bound for activityDateTime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Since
    )

    return "$script:GraphV1/auditLogs/directoryAudits?" +
        "`$filter=loggedByService eq 'PIM' and activityDateTime ge $Since&" +
        "`$orderby=activityDateTime desc"
}
