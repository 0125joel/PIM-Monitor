# 05 — Inventory Format

## Table of Contents

1. [Design Principle: Full API Response](#1-design-principle-full-api-response)
2. [Deterministic JSON](#2-deterministic-json)
3. [Directory Roles](#3-directory-roles)
4. [PIM Groups](#4-pim-groups)
5. [Lookup Inventories](#5-lookup-inventories)
6. [Activation Events](#6-activation-events)
7. [Folder and Slug Naming](#7-folder-and-slug-naming)
8. [Reading Inventory Files](#8-reading-inventory-files)

---

## 1. Design Principle: Full API Response

Every inventory file stores the **complete Graph API response** for that resource, stripped only of OData navigation metadata (`@odata.type`, `@odata.context`, `@odata.id`, `@odata.count`).

No `$select` filtering. No hardcoded property lists. No transformation.

Consequences:
- **New API properties appear automatically.** When Microsoft adds fields to a Graph endpoint, they show up in inventory on the next scan without any code change.
- **Git diff shows everything.** Including properties that were not considered when the project was built.
- **No schema maintenance.** The inventory format evolves with the API.
- **Consumer responsibility.** Presenting data in a human-friendly way (e.g., resolving rule IDs to descriptions) is the responsibility of consumers (PIM Manager, scripts, dashboards), not the pipeline.

> [!WARNING]
> Do not add `$select` to Graph API calls or post-process the response before passing it to `Save-InventoryFile`. Doing so breaks the full-response guarantee and may cause consumers to fail on missing fields.

---

## 2. Deterministic JSON

### Why it matters

The Graph API does not guarantee property order. PowerShell's `ConvertTo-Json` preserves insertion order. Without normalization, two calls to the same endpoint returning identical data in different property order would produce different JSON bytes — and git would report a change on every scan, even when nothing in PIM actually changed.

### The normalization algorithm

`ConvertTo-DeterministicJson` in `helpers.ps1` applies the `Normalize` function recursively:

1. **Null:** passes through as `$null`.
2. **Arrays:** normalize each element; sort by `id` if elements are objects with an `id` field, sort by value if elements are strings, preserve order otherwise.
3. **Dictionaries (hashtables):** strip `@odata.*` keys; sort remaining keys alphabetically; recurse into values.
4. **PSCustomObject:** same as dictionaries — checks `$obj.PSObject.Properties` instead of `.GetEnumerator()`.
5. **Primitives (string, bool, int, datetime):** pass through unchanged.

> [!IMPORTANT]
> `string` and `System.ValueType` (bool, int, etc.) are excluded from the PSObject branch even though PowerShell technically wraps all objects in `[psobject]`. The type check uses explicit exclusion: `($obj -is [psobject]) -and -not ($obj -is [string]) -and -not ($obj -is [System.ValueType])`. Do not use `.PSObject.Properties.Count` to distinguish objects from primitives — it fails under `Set-StrictMode -Version Latest`.

### Output format

- 2-space indentation.
- UTF-8 without BOM (`-Encoding utf8NoBOM`).
- No trailing newline from `ConvertTo-Json`; `Set-Content` adds one.

---

## 3. Directory Roles

### Folder path

```
inventory/directory-roles/{role-slug}/
```

Where `{role-slug}` is derived from `displayName` via `Get-InventorySlug`.

---

### definition.json

**Source:** `GET /beta/roleManagement/directory/roleDefinitions` (beta — required for `isPrivileged`, `allowedPrincipalTypes`, `version`)

**Content:** Full `unifiedRoleDefinition` object.

Notable fields:

| Field | Type | Notes |
|---|---|---|
| `id` | string (GUID) | Role definition ID |
| `displayName` | string | Human-readable role name |
| `description` | string | Role description |
| `isBuiltIn` | boolean | Built-in (Microsoft) vs custom role |
| `isEnabled` | boolean | Whether the role is enabled in the directory |
| `isPrivileged` | boolean | **Beta only.** Whether Microsoft considers this role privileged |
| `allowedPrincipalTypes` | string | **Beta only.** `"User"`, `"Group"`, or combined |
| `version` | string | **Beta only.** Schema version |
| `templateId` | string (GUID) | Role template ID (stable across tenants for built-in roles) |
| `rolePermissions` | array | Permissions granted by this role |
| `resourceScopes` | array | **Deprecated.** Do not use. |

---

### policy.json

**Source:** `GET /policies/roleManagementPolicyAssignments?$filter=scopeId eq '/' and scopeType eq 'Directory' and roleDefinitionId eq '{id}'&$expand=policy($expand=rules)` (v1.0)

**Content:** Full `unifiedRoleManagementPolicyAssignment` object with expanded policy and rules.

The outer object has:
- `id`, `policyId`, `roleDefinitionId`, `scopeId`, `scopeType`
- `policy`: the `unifiedRoleManagementPolicy` object
  - `lastModifiedBy`, `lastModifiedDateTime`: who last modified the policy and when
  - `rules[]`: array of ~16 rule objects (see below)

#### Policy rules

Each rule has:
- `id`: unique rule identifier (e.g., `"Enablement_EndUser_Assignment"`)
- `ruleType`: discriminator (e.g., `"unifiedRoleManagementPolicyEnablementRule"`)
- `target.caller`: `"Admin"` or `"EndUser"`
- `target.level`: `"Eligibility"` or `"Assignment"`
- Rule-specific fields depending on `ruleType`

Common rule IDs and what they control:

| Rule ID | Type | Controls |
|---|---|---|
| `Enablement_EndUser_Assignment` | EnablementRule | MFA, justification, ticketing on activation |
| `Approval_EndUser_Assignment` | ApprovalRule | Approval requirement and approver list |
| `AuthenticationContext_EndUser_Assignment` | AuthenticationContextRule | Conditional Access auth context on activation |
| `Expiration_EndUser_Assignment` | ExpirationRule | Maximum activation duration |
| `Expiration_Admin_Eligibility` | ExpirationRule | Maximum eligible assignment duration |
| `Expiration_Admin_Assignment` | ExpirationRule | Maximum active assignment duration |
| `Enablement_Admin_Assignment` | EnablementRule | Requirements for creating active assignments |
| `Enablement_Admin_Eligibility` | EnablementRule | Requirements for creating eligible assignments |
| `Notification_*` (9 rules) | NotificationRule | 3 notification categories × 3 recipient types |

---

### assignments.json

**Source:** Three separate Graph API calls.

**Content:**

```json
{
  "permanent": [ /* full unifiedRoleAssignment responses */ ],
  "eligible":  [ /* full unifiedRoleEligibilitySchedule responses */ ],
  "active":    [ /* full unifiedRoleAssignmentSchedule responses */ ]
}
```

Sources per category:

| Category | Endpoint | API Version |
|---|---|---|
| `permanent` | `GET /roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{id}'&$expand=principal` | v1.0 |
| `eligible` | `GET /roleManagement/directory/roleEligibilitySchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` | v1.0 |
| `active` | `GET /roleManagement/directory/roleAssignmentSchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` | v1.0 |

Key fields for diff interpretation:

| Field | Notes |
|---|---|
| `principalId` | The user, group, or service principal being assigned |
| `roleDefinitionId` | The role being assigned to |
| `directoryScopeId` | `"/"` for tenant-wide; `/administrativeUnits/{id}` for AU-scoped |
| `memberType` | `"Direct"` or `"Group"` (inherited via group membership) |
| `assignmentType` | `"Assigned"` or `"Activated"` (active assignments only) |
| `scheduleInfo.expiration.endDateTime` | `null` means no expiration (permanent); ISO 8601 otherwise |
| `status` | `"Provisioned"`, `"PendingApproval"`, etc. |

> [!NOTE]
> `scheduleInfo.startDateTime` is stripped by `Remove-AssignmentNoise` before both diffing and writing. Microsoft Graph re-provisions this heartbeat timestamp approximately every 30 minutes without any user action. Including it would cause a spurious commit on almost every scan.

---

## 4. PIM Groups

### Folder path

```
inventory/pim-groups/{group-slug}/
```

Same three files (`definition.json`, `policy.json`, `assignments.json`), with PIM-Group-specific schemas.

---

### definition.json

**Source:** `GET /groups/{id}` (v1.0)

**Content:** Full `group` object. Notable fields: `id`, `displayName`, `description`, `mail`, `mailEnabled`, `securityEnabled`, `groupTypes`, `isAssignableToRole`.

---

### policy.json

**Content:** A wrapper object with two sub-policies:

```json
{
  "member": { /* full policyAssignment response with expanded policy + rules */ },
  "owner":  { /* full policyAssignment response with expanded policy + rules */ }
}
```

Each sub-policy has the same structure as a Directory Role `policy.json`. The wrapper exists because PIM Groups have two independent policies: one for `member` access, one for `owner` access.

**Source:** `GET /beta/policies/roleManagementPolicyAssignments?$filter=scopeId eq '{groupId}' and scopeType eq 'Group'&$expand=policy($expand=rules)` (beta — `scopeType eq 'Group'` filter not available in v1.0)

The API returns two objects distinguished by `roleDefinitionId`: `"member"` and `"owner"`.

---

### assignments.json

**Content:**

```json
{
  "member": {
    "permanent": [ /* assignmentScheduleInstance responses where endDateTime is null */ ],
    "eligible":  [ /* eligibilityScheduleInstance responses */ ],
    "active":    [ /* assignmentScheduleInstance responses where endDateTime is set */ ]
  },
  "owner": {
    "permanent": [],
    "eligible":  [],
    "active":    []
  }
}
```

Sources:
- **Eligible:** `GET /identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` (v1.0)
- **Active/Permanent:** `GET /identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` (v1.0)

The `accessId` field on each instance (`"member"` or `"owner"`) determines which section the entry goes into. Permanent entries (no `endDateTime`) are split into `permanent`; the rest go into `active`.

---

## 5. Lookup Inventories

### authentication-contexts/ and administrative-units/

These store entities that are **referenced by** policies and assignments. They allow consumers to resolve IDs to display names without making additional Graph API calls.

Folder structure:
```
inventory/authentication-contexts/{slug}/definition.json
inventory/administrative-units/{slug}/definition.json
```

Only `definition.json` — no `policy.json` or `assignments.json`.

**Authentication context source:** `GET /identity/conditionalAccess/authenticationContextClassReferences` (v1.0). Fields include `id`, `displayName`, `description`, `isAvailable`, `claimValue`.

**Administrative unit source:** `GET /directory/administrativeUnits` (v1.0). Fields include `id`, `displayName`, `description`, `visibility`.

---

## 6. Activation Events

### Path

```
inventory/activation-events/YYYY-MM.json
```

One file per calendar month. The file is a JSON array of audit log event objects, sorted by `activityDateTime` ascending.

**Source:** `GET /auditLogs/directoryAudits?$filter=loggedByService eq 'PIM' and activityDateTime ge {since}&$orderby=activityDateTime desc` (v1.0)

Notable fields per event: `id`, `activityDateTime`, `activityDisplayName`, `initiatedBy` (user or app), `targetResources`, `result`, `category`, `operationType`.

The file grows incrementally as new events are appended. It is never trimmed. Files from past months are immutable once the month rolls over.

---

## 7. Folder and Slug Naming

Folder names are derived from `displayName` by `Get-InventorySlug`:

```powershell
$Name.ToLower() `
    -replace '[^\w\s-]', '' `
    -replace '\s+', '-' `
    -replace '-+', '-' `
    -replace '^-|-$', ''
```

Examples:

| displayName | slug |
|---|---|
| `Global Administrator` | `global-administrator` |
| `Exchange Online (Protection) Administrator` | `exchange-online-protection-administrator` |
| `Tier-0 Admins` | `tier-0-admins` |
| `EU - Finance Approvers` | `eu---finance-approvers` (triple hyphen preserved) |

> [!CAUTION]
> If two entities produce the same slug from different display names, the second will overwrite the first. This is extremely unlikely for built-in roles but possible for custom roles or groups with similar names. If this occurs, one of the entities must be renamed.

---

## 8. Reading Inventory Files

To read an inventory file in PowerShell:

```powershell
$path = "inventory/directory-roles/global-administrator/assignments.json"
$data = Get-Content -Path $path -Raw -Encoding utf8 | ConvertFrom-Json
```

When comparing a property that may not exist (because it was added by a newer API version):

```powershell
# Safe under Set-StrictMode -Version Latest
$isPrivileged = $data.PSObject.Properties['isPrivileged']?.Value
```

To check whether an assignments file has any permanent assignments:

```powershell
$permanent = $data.PSObject.Properties['permanent']?.Value
if ($permanent -and $permanent.Count -gt 0) {
    # process permanent assignments
}
```

> [!NOTE]
> `ConvertFrom-Json` returns `PSCustomObject` by default. Use `PSObject.Properties['key']?.Value` for safe property access. Use `ConvertFrom-Json -AsHashtable` when you need dictionary-style iteration.
