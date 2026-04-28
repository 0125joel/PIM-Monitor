---
sidebar_position: 4
---

# Diff engine

For a technical explanation of how the diff engine works internally, see [Reference: Diff Engine](../reference/diff-engine.md).

## Filter fields from diff output

`$script:DiffIgnoreProperties` in `src/diff.ps1` controls which API fields are hidden in the diff preview — in emails, webhooks, and the HTML scan report. Fields in this list are skipped when rendering what changed; they do not affect change detection itself.

Edit the array in `src/diff.ps1`:

```powershell
$script:DiffIgnoreProperties = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '@odata.context', '@odata.type', '@odata.id',
        'id', 'templateId', 'target',
        'createdDateTime', 'modifiedDateTime', 'createdUsing',
        'lastModifiedDateTime', 'lastModifiedBy'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)
```

**Default fields and why they are filtered:**

| Field | Reason |
|---|---|
| `@odata.context`, `@odata.type`, `@odata.id` | OData protocol metadata, never user-controlled |
| `id`, `templateId` | API-assigned identifiers, not configuration |
| `target` | Structural rule scope (`caller`/`level`) — identifies the rule, not its settings |
| `createdDateTime`, `modifiedDateTime`, `createdUsing` | System-managed timestamps |
| `lastModifiedDateTime`, `lastModifiedBy` | Audit trail fields, not configuration |

**To hide an additional field** — add its name to the array:

```powershell
'id', 'templateId', 'target', 'myNoiseField',
```

**To make a field visible again** — remove it from the array. The field will then appear as a red/green diff line in notifications whenever it changes.

:::note
Field matching is case-insensitive. Adding `'displayName'` also silences `DisplayName`.
:::

## Change object equality

By default, `Test-ObjectEqual` serializes both objects to JSON and compares the strings. You can modify this to ignore certain fields or compare property-by-property.

Edit `src/diff.ps1` lines 54-65:

```powershell
function Test-ObjectEqual {
    param($Left, $Right)
    # Default: full JSON comparison
    # To ignore a field, remove it before comparing:
    $l = $Left | Select-Object -ExcludeProperty lastModifiedDateTime
    $r = $Right | Select-Object -ExcludeProperty lastModifiedDateTime
    return (ConvertTo-Json $l -Depth 10 -Compress) -eq (ConvertTo-Json $r -Depth 10 -Compress)
}
```

## Change the assignment key

The assignment key determines how old and new assignments are matched. Edit `Get-AssignmentKey` in `src/diff.ps1`:

```powershell
# Default for Directory Roles:
$key = "$principalId|$directoryScopeId"

# To also include roleDefinitionId (for multi-role scenarios):
$key = "$principalId|$directoryScopeId|$roleDefinitionId"
```

## Change how removed entities are detected

By default, a role or group is considered removed if its folder no longer appears in the current fetch. To change the comparison (for example, match by display name instead of slug):

Edit `Get-RemovedEntities` in `src/diff.ps1`.

## Change removed entity severity

By default, removed entities (roles or groups that disappear from the tenant) are classified as High. To change this:

Edit `Get-RemovedEntities` in `src/diff.ps1`:

```powershell
$severity = "Medium"  # was "High"
```
