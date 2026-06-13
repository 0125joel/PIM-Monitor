# 04 — Graph API

## Table of Contents

1. [API Version Policy](#1-api-version-policy)
2. [Endpoint Reference](#2-endpoint-reference)
3. [Collection Endpoints](#3-collection-endpoints)
4. [Per-Item URI Builders](#4-per-item-uri-builders)
5. [Pagination](#5-pagination)
6. [Throttling and Retry](#6-throttling-and-retry)
7. [Deprecated Endpoints](#7-deprecated-endpoints)
8. [Adding a New Endpoint](#8-adding-a-new-endpoint)

---

## 1. API Version Policy

PIM Monitor uses **v1.0 endpoints by default**. Beta is used only when specific properties are unavailable in v1.0. This minimizes exposure to breaking changes in the beta API.

The rule is: use the least privileged, most stable version that provides the required data.

> [!WARNING]
> Beta endpoints can change or be removed without notice. Any use of a beta endpoint should be documented with the reason and a note about when to revisit (e.g., when Microsoft announces v1.0 parity).

---

## 2. Endpoint Reference

| Endpoint | Version | Why |
|---|---|---|
| `GET /roleManagement/directory/roleDefinitions` | **beta** | `isPrivileged`, `allowedPrincipalTypes`, and `version` are beta-only fields |
| `GET /roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{id}'` | v1.0 | Permanent (non-PIM) assignments — fully available |
| `GET /roleManagement/directory/roleEligibilitySchedules?$filter=roleDefinitionId eq '{id}'` | v1.0 | PIM eligible assignment schedules |
| `GET /roleManagement/directory/roleAssignmentSchedules?$filter=roleDefinitionId eq '{id}'` | v1.0 | PIM active/activated assignment schedules |
| `GET /policies/roleManagementPolicyAssignments?$filter=...scopeType eq 'Directory'...` | v1.0 | Directory role policies — all rules available |
| `GET /policies/roleManagementPolicyAssignments?$filter=...scopeType eq 'Group'...` | **beta** | `scopeType eq 'Group'` filter not supported in v1.0 |
| `GET /groups/{id}` | v1.0 | Group properties |
| `GET /identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId eq '{id}'` | v1.0 | PIM Group eligible assignments |
| `GET /identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId eq '{id}'` | v1.0 | PIM Group active/permanent assignments |
| `GET /identityGovernance/privilegedAccess/group/resources` | **beta** | PIM Group discovery — beta, undocumented for discovery, no published deprecation date (guarded) |
| `GET /identity/conditionalAccess/authenticationContextClassReferences` | v1.0 | Authentication context lookup |
| `GET /directory/administrativeUnits` | v1.0 | Administrative unit lookup |
| `GET /auditLogs/directoryAudits?$filter=loggedByService eq 'PIM'...` | v1.0 | PIM activation events |
| `GET /identityGovernance/roleManagementAlerts/alerts` | **beta** | Security alerts — no v1.0 equivalent (Phase 4) |
| `GET /roleManagement/directory/roleEligibilityScheduleRequests` | v1.0 | Pending requests (Phase 4) |
| `GET /roleManagement/directory/roleAssignmentScheduleRequests` | v1.0 | Pending requests (Phase 4) |

---

## 3. Collection Endpoints

Collection endpoints are defined as constants in `$script:GraphEndpoints` in `graphEndpoints.ps1`. These endpoints return a flat list of all items without a per-item filter.

```powershell
$script:GraphEndpoints = @{
    RoleDefinitions         = "$script:GraphBeta/roleManagement/directory/roleDefinitions"
    AuthenticationContexts  = "$script:GraphV1/identity/conditionalAccess/authenticationContextClassReferences"
    AdministrativeUnits     = "$script:GraphV1/directory/administrativeUnits"
    GroupResources          = "$script:GraphBeta/identityGovernance/privilegedAccess/group/resources"
}
```

These are passed directly to `Get-AllGraphItems`, which handles pagination.

---

## 4. Per-Item URI Builders

Per-item endpoints require a role ID or group ID in the filter. These are implemented as functions in `graphEndpoints.ps1` rather than string templates, to keep URI construction in one place and avoid interpolation errors in the orchestrator.

| Function | Endpoint pattern |
|---|---|
| `Get-RolePolicyUri -RoleId` | `/policies/roleManagementPolicyAssignments?$filter=...roleDefinitionId eq '{id}'&$expand=policy($expand=rules)` |
| `Get-RolePermanentAssignmentsUri -RoleId` | `/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-RoleEligibleAssignmentsUri -RoleId` | `/roleManagement/directory/roleEligibilitySchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-RoleActiveAssignmentsUri -RoleId` | `/roleManagement/directory/roleAssignmentSchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-GroupDefinitionUri -GroupId` | `/groups/{id}` |
| `Get-GroupPolicyUri -GroupId` | `/beta/policies/roleManagementPolicyAssignments?$filter=scopeId eq '{id}' and scopeType eq 'Group'&$expand=policy($expand=rules)` |
| `Get-GroupEligibleAssignmentsUri -GroupId` | `/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` |
| `Get-GroupActiveAssignmentsUri -GroupId` | `/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` |
| `Get-AuditLogsPimUri -Since` | `/auditLogs/directoryAudits?$filter=loggedByService eq 'PIM' and activityDateTime ge {since}&$orderby=activityDateTime desc` |

---

## 5. Pagination

All Graph API list endpoints that may return more than 100 items must be paginated. The helper `Get-AllGraphItems` handles this automatically:

```powershell
function Get-AllGraphItems {
    param([string] $Uri, [string] $AccessToken)

    $allItems = @()
    $headers  = @{ Authorization = "Bearer $AccessToken" }

    $currentUri = $Uri
    while ($currentUri) {
        $response = Invoke-RestMethod -Uri $currentUri -Headers $headers -Method Get
        $pageItems = $response.PSObject.Properties['value']?.Value
        if ($pageItems) { $allItems += $pageItems }
        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
    }

    return $allItems
}
```

Key implementation notes:
- `PSObject.Properties['value']?.Value` is used instead of `$response.value` because `Set-StrictMode -Version Latest` throws on missing properties.
- `@odata.nextLink` may not be present on the final page; the null-conditional `?.Value` returns `$null`, ending the loop.
- This function is not available inside `-Parallel` blocks. The Directory Roles parallel section has its own inlined pagination loop.

---

## 6. Throttling and Retry

Microsoft Graph throttles requests when too many are made in a short window. The retry logic inside the Directory Roles `-Parallel` block:

1. Call the endpoint.
2. On success, `Start-Sleep -Milliseconds 500` (courteous pacing).
3. On failure:
   - If the error is `429 Too Many Requests` or a 5xx server error, wait for the `Retry-After` header value (or exponential backoff: 2^attempt seconds) and retry.
   - If the error is a non-retryable 4xx, re-throw immediately.
   - Maximum 5 retry attempts before re-throwing.

```powershell
$attempt = 0
while ($true) {
    try {
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        Start-Sleep -Milliseconds 500
        return $result
    } catch {
        $attempt++
        if ($attempt -ge 6) { throw }
        $isRetryable = ($_ -match '429') -or ($_ -match '5\d\d')
        if (-not $isRetryable) { throw }
        $retryAfter = ...
        $waitSecs = if ($retryAfter -gt 0) { $retryAfter } else { [math]::Pow(2, $attempt + 1) }
        Start-Sleep -Seconds $waitSecs
    }
}
```

`Get-AllGraphItems` (used outside of parallel blocks) does not include its own retry loop. If throttling becomes a problem for non-parallel fetches, add retry logic there as well.

---

## 7. Deprecated Endpoints

### `GET /beta/identityGovernance/privilegedAccess/group/resources`

**Status:** Beta, undocumented as a discovery surface. **No published deprecation date.**

Correction: the widely cited "October 28, 2026" deadline applies to PIM **iteration 2** (`/beta/privilegedAccess/aadRoles` + `/azureResources`), which this project does not use. This `identityGovernance/.../group` path is the current iteration-3 namespace.

This endpoint is used to discover which groups are PIM-onboarded (`$script:GraphEndpoints.GroupResources`). There is **no** tenant-wide replacement:

> [!IMPORTANT]
> `eligibilityScheduleInstances` and `assignmentScheduleInstances` **require** `$filter=groupId` (verbatim in the Microsoft v1.0 docs) and **cannot** be enumerated unfiltered. `roleManagementPolicyAssignments` likewise requires `scopeId` + `scopeType`. There is no "list all PIM groups" API, so discovery cannot be reconstructed from these endpoints.

Because the endpoint is beta and undocumented for discovery, an empty or changed response is possible. `Test-SafeToArchive` (`src/diff.ps1`) guards against that: if discovery returns zero groups while inventory still holds group folders, archival is skipped and a scan error is raised instead of mass false-removal.

### `resourceScopes` on role definitions

**Status:** Deprecated by Microsoft. Documentation states: "DO NOT USE. Will be deprecated soon."

PIM Monitor stores the full role definition response including `resourceScopes`, in keeping with the full-response principle. Do not use this field for logic. Use `directoryScopeId` on assignments instead.

---

## 8. Adding a New Endpoint

To add a new Graph API endpoint to PIM Monitor:

1. **Add the URI** to `graphEndpoints.ps1`:
   - Collection endpoint: add a key to `$script:GraphEndpoints`.
   - Per-item endpoint: add a new URI builder function following the existing naming convention (`Get-{Entity}{DataType}Uri`).

2. **Fetch the data** in `Scan-PimState.ps1` using `Get-AllGraphItems` or `Invoke-RestMethod` as appropriate.

3. **Store the data** via `Save-InventoryFile` to the appropriate inventory folder.

4. **Add diff logic** in `diff.ps1` if the new data type should be diffed (or reuse `Compare-InventoryFolder` if the standard three-file structure applies).

5. **Update severity tables** in `diff.ps1` if the new data type introduces new property names or rule IDs.

6. **Document the endpoint** in the table in Section 2 of this document.

7. **Add the required permission** to the App Registration documentation in [09-authentication.md](09-authentication.md).
