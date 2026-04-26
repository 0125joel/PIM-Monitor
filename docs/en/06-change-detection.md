# 06 — Change Detection

## Table of Contents

1. [Overview](#1-overview)
2. [Entry Point: Compare-InventoryFolder](#2-entry-point-compare-inventoryfolder)
3. [Definition Diff: Compare-FlatProperties](#3-definition-diff-compare-flatproperties)
4. [Policy Diff: Compare-PolicyRules](#4-policy-diff-compare-policyrules)
5. [Assignment Diff: Compare-Assignments](#5-assignment-diff-compare-assignments)
6. [Severity Classification](#6-severity-classification)
7. [Noise Suppression: Remove-AssignmentNoise](#7-noise-suppression-remove-assignmentnoise)
8. [Expiring Assignments: Find-ExpiringAssignments](#8-expiring-assignments-find-expiringassignments)
9. [Expected-Change Suppression](#9-expected-change-suppression)
10. [Change Entry Schema](#10-change-entry-schema)
11. [Extending the Diff Engine](#11-extending-the-diff-engine)

---

## 1. Overview

The diff engine in `diff.ps1` follows a **declarative, rule-based design**. Severity is determined by lookup tables, not by if/else branches. Adding or adjusting a severity rule means editing a table entry, not modifying function logic.

The engine operates at three levels of granularity:
- **Folder level** (`Compare-InventoryFolder`): detects new or deleted entities.
- **File level** (dispatched by `Compare-InventoryFolder`): detects which file changed.
- **Sub-object level**: three specialized comparators for each file type.

All three file types are handled uniformly by `Compare-InventoryFolder`. The file type determines which comparator is invoked.

---

## 2. Entry Point: Compare-InventoryFolder

```powershell
Compare-InventoryFolder -FolderPath $folderPath -NewData $newData -EntityName $entityName
```

Parameters:
- `$folderPath`: path to the entity's inventory folder.
- `$newData`: hashtable keyed by file type (`definition`, `policy`, `assignments`), each value being the new data object.
- `$entityName`: display name for log messages and change descriptions.

Logic:

```
For each fileType in $newData:
  │
  ├── $oldData = Read-PreviousInventoryFile(filePath)
  │
  ├── $oldData == null AND $newData != null
  │       → New entity: High severity for "definition", Medium for others
  │
  ├── $oldData != null AND $newData == null
  │       → Entity deleted: High severity
  │
  ├── $oldData == null AND $newData == null
  │       → Skip
  │
  └── Test-ObjectEqual($oldData, $newData)
          → Equal: skip
          → Different: dispatch to file-type comparator
                  "definition"  → Compare-FlatProperties
                  "policy"      → Compare-PolicyRules
                  "assignments" → Compare-Assignments
```

`Test-ObjectEqual` normalizes both objects through `ConvertTo-DeterministicJson` and compares the resulting strings. This makes the equality check robust to property reordering.

---

## 3. Definition Diff: Compare-FlatProperties

Compares the two `definition.json` objects at the **top-level property level**. Produces one change entry per changed, added, or removed property.

Properties listed in `$script:DiffIgnoreProperties` are skipped entirely:

```powershell
$script:DiffIgnoreProperties = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    '@odata.context', '@odata.type', '@odata.id',
    'id', 'templateId',
    'createdDateTime', 'modifiedDateTime', 'createdUsing',
    'lastModifiedDateTime', 'lastModifiedBy'
))
```

These are system-managed fields that change without any user action (timestamps, OData metadata) or are used as keys rather than configuration values.

For each non-ignored property:
- **Present in new but not old** (`new_property`): always `Informational`. New API fields that appeared in the response are captured without raising an alert.
- **Present in old but not new** (`removed_property`): severity from `Get-PropertySeverity`.
- **Present in both but different** (`updated`): severity from `Get-PropertySeverity`.

### Property severity table

```powershell
$script:PropertySeverity = [ordered]@{
    "rolePermissions"        = "High"
    "allowedResourceActions" = "High"
    "isPrivileged"           = "High"
    "isEnabled"              = "High"
    "allowedPrincipalTypes"  = "Medium"
    "displayName"            = "Informational"
    "description"            = "Informational"
    "version"                = "Informational"
}
$script:DefaultPropertySeverity = "Informational"
```

Matching is prefix-based: a property key `"rolePermissions[0]"` would match the `"rolePermissions"` pattern. Unknown properties default to `Informational`, ensuring any new API field is silently captured without noise.

---

## 4. Policy Diff: Compare-PolicyRules

Compares `policy.json` objects at the **individual rule level**. Matches rules by their `id` field.

### PIM Group wrapper detection

If the policy object has `member` or `owner` keys (PIM Group policy), the function detects this and recurses for each sub-policy with context `"EntityName — member"` and `"EntityName — owner"`.

### Rule extraction

Rules are extracted from either `$policy.policy.rules` (expanded form) or `$policy.rules` (flat form). Both shapes are handled.

### Per-rule comparison

```
For each ruleId in oldByRuleId:
    ├── Not in newByRuleId → rule removed
    └── In both → Test-ObjectEqual → rule changed

For each ruleId in newByRuleId:
    └── Not in oldByRuleId → rule added
```

Severity is determined by `Get-PolicyRuleSeverity` using prefix matching on the rule ID:

```powershell
$script:PolicyRuleSeverity = [ordered]@{
    "Enablement_EndUser_Assignment"           = "High"
    "Approval_EndUser_Assignment"             = "High"
    "AuthenticationContext_EndUser_Assignment" = "High"
    "Expiration_EndUser_Assignment"           = "Medium"
    "Expiration_Admin_Eligibility"            = "Medium"
    "Expiration_Admin_Assignment"             = "Medium"
    "Enablement_Admin_Assignment"             = "Medium"
    "Enablement_Admin_Eligibility"            = "Medium"
    "Notification_"                           = "Low"
}
$script:DefaultPolicyRuleSeverity = "Medium"
```

Order matters: first match wins. `"Notification_"` is a prefix match that catches all nine notification rules (`Notification_Admin_Admin_Assignment`, etc.).

---

## 5. Assignment Diff: Compare-Assignments

Compares `assignments.json` objects at the **individual assignment entry level**. Matches entries by a composite key.

### Category detection

Categories are derived dynamically from both the old and new objects, so any new category type that Microsoft adds to the API (beyond `permanent`, `eligible`, `active`) is automatically detected.

### Assignment key

`Get-AssignmentKey` builds a stable composite key for matching old vs new entries:

```
Directory Roles:  principalId + "|" + directoryScopeId
PIM Groups:       principalId + "|" + groupId + "|" + accessId
Fallback:         assignment.id (if no principalId is present)
```

### Change types and severity

| Situation | changeType | Severity |
|---|---|---|
| Key in old but not new | `removed` | Low |
| Key in new but not old, category `permanent` | `added` | High |
| Key in new but not old, category `eligible` | `added` | Medium |
| Key in new but not old, category `active` | `added` | Medium |
| Key in new but not old, `scheduleInfo.expiration.endDateTime == null` (any category) | `added` | High |
| Key in both, but values differ | `updated` | Medium |

The null-expiration check (`endDateTime == null`) upgrades severity to High because an assignment with no expiration is effectively permanent, regardless of the category it was fetched from.

---

## 6. Severity Classification

PIM Monitor uses four severity levels:

| Severity | Meaning | Examples |
|---|---|---|
| High | Immediate security impact | MFA disabled, approval removed, permanent assignment, role removed from PIM |
| Medium | Significant configuration change | Activation duration changed, new eligible/active assignment, expiration policy changed |
| Low | Administrative or cosmetic change | Notification settings changed, display name changed, assignment expired/removed |
| Informational | New API fields, activation events | New property appeared in Graph response, PIM audit log event |

### Configuring severity

All severity rules are defined as lookup tables in `diff.ps1`:

- `$script:PolicyRuleSeverity` — policy rule ID to severity
- `$script:PropertySeverity` — definition property name to severity
- `$script:DefaultPolicyRuleSeverity` — fallback for unknown rule IDs
- `$script:DefaultPropertySeverity` — fallback for unknown property names
- `$script:DefaultCategorySeverity` — fallback for unknown assignment categories

To change a severity, edit the appropriate table. No function logic needs to change.

---

## 7. Noise Suppression: Remove-AssignmentNoise

`Remove-AssignmentNoise` strips fields from assignment objects that change on a fixed schedule without representing actual user or admin action.

The set of fields to strip is configured in:

```powershell
$script:AssignmentNoisePaths = @('scheduleInfo.startDateTime')
```

`scheduleInfo.startDateTime` is updated by Microsoft Graph approximately every 30 minutes as part of internal role provisioning heartbeat. Without stripping it, every scan would commit a change for every active assignment, even when nothing actually changed.

The function performs a deep copy via JSON round-trip (`ConvertTo-Json | ConvertFrom-Json`) before modifying, so the original objects fetched from the API are never mutated.

To add a new noise path, add its dot-notation path to `$script:AssignmentNoisePaths`.

---

## 8. Expiring Assignments: Find-ExpiringAssignments

`Find-ExpiringAssignments` scans all assignment categories for entries where `scheduleInfo.expiration.endDateTime` is set and within the configured window.

```powershell
$daysRemaining = ($expiryTime - $nowUtc).TotalDays
if ($daysRemaining -gt 0 -and $daysRemaining -le $WindowDays) {
    # emit Medium severity change with changeType = "expiring"
}
```

The window is controlled by the `EXPIRING_WINDOW_DAYS` pipeline variable (default 14 days). Change entries have `severity = "Medium"` and `changeType = "expiring"`. They are included in notifications but do not modify any inventory file.

---

## 9. Expected-Change Suppression

`Test-ChangeIsExpected` checks each change against entries in `expected-changes.json`.

Schema of `expected-changes.json`:

```json
{
  "expected": [
    {
      "workload":    "directory-roles",
      "entity":      "global-administrator",
      "fileType":    "policy",
      "ruleId":      "Expiration_Admin_Eligibility",
      "expiresUtc":  "2026-05-01T00:00:00Z",
      "reason":      "Planned policy update during maintenance window"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `workload` | Optional | Match on workload type (`directory-roles`, `pim-groups`, etc.) |
| `entity` | Optional | Match on entity slug (kebab-case) |
| `fileType` | Optional | Match on file type (`definition`, `policy`, `assignments`) |
| `ruleId` | Optional | Match on specific policy rule ID |
| `expiresUtc` | Optional | ISO 8601 UTC; entry is ignored after this time |
| `reason` | Optional | Documentation — not evaluated by the filter |

Matching is AND-based: all specified fields must match. Omitting a field makes it a wildcard for that dimension.

After filtering, the pipeline rewrites the file removing expired entries. If all entries are removed, the file is deleted.

---

## 10. Change Entry Schema

Every change entry emitted by the diff engine is a PowerShell hashtable with these standard fields:

| Field | Type | Always present | Description |
|---|---|---|---|
| `severity` | string | Yes | `High`, `Medium`, `Low`, or `Informational` |
| `changeType` | string | Yes | `created`, `deleted`, `updated`, `added`, `removed`, `new_property`, `removed_property`, `expiring` |
| `description` | string | Yes | Human-readable summary |
| `context` | string | Yes | Entity display name (e.g., `"Global Administrator"`) |
| `old` | any | No | Previous value (null for new entities) |
| `new` | any | No | New value (null for deleted entities) |
| `fileType` | string | Mostly | `definition`, `policy`, or `assignments` |
| `ruleId` | string | Policy changes | Policy rule ID |
| `propertyKey` | string | Definition changes | Property name |
| `category` | string | Assignment changes | `permanent`, `eligible`, or `active` |
| `isAlert` | boolean | Expiring only | Marks expiring-assignment entries |
| `daysRemaining` | int | Expiring only | Days until expiration |
| `folderPath` | string | Deleted entities | Full path to the removed folder |

---

## 11. Extending the Diff Engine

### Add a new severity rule for a policy rule ID

Edit `$script:PolicyRuleSeverity` in `diff.ps1`. Place more specific patterns before less specific ones (first match wins).

### Add a new severity rule for a definition property

Edit `$script:PropertySeverity` in `diff.ps1`.

### Suppress a noisy assignment field

Add its dot-notation path to `$script:AssignmentNoisePaths` in `diff.ps1`.

### Add a new property to the diff-ignore list

Add it to `$script:DiffIgnoreProperties` in `diff.ps1`. This is for system-managed fields that change without user action (timestamps, internal IDs).

### Add a new workload type (new inventory category)

`Compare-InventoryFolder` is workload-agnostic and handles any `@{ definition; policy; assignments }` data structure. To add a new workload:
1. Add the fetch logic in `Scan-PimState.ps1`.
2. Call `Compare-InventoryFolder` with the new data.
3. Call `Save-InventoryFile` for each file type.
4. Call `Get-RemovedEntities` to detect deletions.
5. No changes to `diff.ps1` are needed unless the new workload introduces new rule IDs or property names that need custom severity.
