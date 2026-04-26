---
sidebar_position: 2
---

# Graph API Endpoints

Which Microsoft Graph endpoints PIM Monitor uses and why each one uses v1.0 or beta.

## Quick reference

| Workload | Resource | Endpoint | Version | Why beta? |
|---|---|---|---|---|
| Directory Roles | Definition | `/roleManagement/directory/roleDefinitions` | Beta | `isPrivileged`, `allowedPrincipalTypes` fields |
| Directory Roles | Policy | `/policies/roleManagementPolicyAssignments` | v1.0 | Stable |
| Directory Roles | Permanent assignments | `/roleManagement/directory/roleAssignments` | v1.0 | Stable |
| Directory Roles | Eligible schedules | `/roleManagement/directory/roleEligibilitySchedules` | v1.0 | Stable |
| Directory Roles | Active schedules | `/roleManagement/directory/roleAssignmentSchedules` | v1.0 | Stable |
| PIM Groups | Eligible instances | `/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances` | v1.0 | Stable |
| PIM Groups | Active instances | `/identityGovernance/privilegedAccess/group/assignmentScheduleInstances` | v1.0 | Stable |
| PIM Groups | Policy | `/policies/roleManagementPolicyAssignments?$filter=...scopeType eq 'Group'` | Beta | `scopeType eq 'Group'` filter |
| Lookups | Auth contexts | `/identity/conditionalAccess/authenticationContextClassReferences` | v1.0 | Stable |
| Lookups | Admin units | `/directory/administrativeUnits` | v1.0 | Stable |

## Details

### Directory role definitions

**Endpoint:** `https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions`

**Why beta:** The `isPrivileged` and `allowedPrincipalTypes` fields are not available in v1.0.

**Example response:**
```json
{
  "id": "62e90394-...",
  "displayName": "Global Administrator",
  "isBuiltIn": true,
  "isEnabled": true,
  "isPrivileged": true,
  "allowedPrincipalTypes": ["User"],
  "rolePermissions": [...]
}
```

### PIM policies

**Directory Roles (v1.0):**
```
/v1.0/policies/roleManagementPolicyAssignments
  ?$filter=scopeId eq '/' and scopeType eq 'Directory' and roleDefinitionId eq '{roleId}'
  &$expand=policy($expand=rules)
```

**PIM Groups (beta):**
```
/beta/policies/roleManagementPolicyAssignments
  ?$filter=scopeId eq '{groupId}' and scopeType eq 'Group'
  &$expand=policy($expand=rules)
```

**Why beta for groups:** The `scopeType eq 'Group'` filter **only works in beta**. v1.0 does not support group-scoped policy queries.

:::warning Upgrade Path
As of April 2026, the `scopeType eq 'Group'` filter remains beta-only. When/if Microsoft migrates this to v1.0 GA, this line must be updated:
- Change base URL from `$script:GraphBeta` to `$script:GraphV1`
- Update the comment above `Get-GroupPolicyUri` in `src/graphEndpoints.ps1`

Monitor Microsoft Graph [changelog](https://learn.microsoft.com/en-us/graph/changelog) for availability announcement.
:::

### Role assignments

**Permanent (v1.0):**
```
/v1.0/roleManagement/directory/roleAssignments
  ?$filter=roleDefinitionId eq '{roleId}'&$expand=principal
```

Non-PIM direct assignments. Deprecated but still relevant for legacy permanent admin access.

**Eligible (v1.0):**
```
/v1.0/roleManagement/directory/roleEligibilitySchedules
  ?$filter=roleDefinitionId eq '{roleId}'&$expand=principal
```

**Active (v1.0):**
```
/v1.0/roleManagement/directory/roleAssignmentSchedules
  ?$filter=roleDefinitionId eq '{roleId}'&$expand=principal
```

`$expand=principal` returns the user or group inline, avoiding N+1 lookups.

### PIM group assignments

**Eligible instances (v1.0):**
```
/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$expand=principal
```

**Active instances (v1.0):**
```
/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$expand=principal
```

These return all instances across all groups. PIM Monitor discovers which groups are onboarded by grouping results by `groupId`.

Each instance includes `groupId`, `principalId`, `accessId` (`member` or `owner`), `principal` (expanded), and `scheduleInfo.expiration`.

### Lookups

**Authentication contexts (v1.0):**
```
/v1.0/identity/conditionalAccess/authenticationContextClassReferences
```

Maps claim values (e.g. `c1`) to display names (e.g. `Require MFA`).

**Administrative units (v1.0):**
```
/v1.0/directory/administrativeUnits
```

Maps AU IDs to display names for scope resolution in assignments.

## Pagination

All list endpoints support `@odata.nextLink`. PIM Monitor follows it automatically:

```powershell
function Get-AllGraphItems {
    $allItems = @()
    $currentUri = $Uri
    while ($currentUri) {
        $response  = Invoke-RestMethod -Uri $currentUri -Headers $headers
        $pageItems = $response.PSObject.Properties['value']?.Value
        if ($pageItems) { $allItems += $pageItems }
        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
    }
    return $allItems
}
```

Both properties are read via `PSObject.Properties['key']?.Value` rather than direct dot notation. Direct access (`$response.value`, `$response.'@odata.nextLink'`) throws under `Set-StrictMode -Version Latest` when the property is absent (e.g., `@odata.nextLink` is not present on the last page).

## Permissions required

**Read (minimum):**
- `RoleManagement.Read.Directory`
- `RoleAssignmentSchedule.Read.Directory`
- `RoleEligibilitySchedule.Read.Directory`
- `RoleManagementPolicy.Read.Directory`
- `PrivilegedAccess.Read.AzureADGroup`
- `AuditLog.Read.All`
- `Policy.Read.ConditionalAccess`
- `User.Read.All`
- `Group.Read.All`
- `AdministrativeUnit.Read.All`

**Optional:**
- `Mail.Send` (email notifications)

## Performance notes

- Full fetch each run, no delta queries (simpler, no state sync needed)
- Per-role policies fetched in parallel via worker pool
- `$expand=principal` on collection endpoints avoids per-item follow-up calls
- JSON serialization is deterministic, so `git diff` output is minimal
