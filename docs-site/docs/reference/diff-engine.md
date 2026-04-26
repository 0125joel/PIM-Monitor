---
sidebar_position: 3
---

# Diff Engine

The diff engine compares current PIM state (from Graph API) against the previous state (from `inventory/`) and produces a list of changes with severity labels.

## Overview

```
Fetched data
    |
Compare-InventoryFolder (orchestrator)
    +-- definition changes -> check rolePermissions
    +-- policy changes -> Compare-PolicyRules (rule-by-rule)
    +-- assignment changes -> Compare-Assignments (member-by-member)
    |
Change list with severity labels
    |
Notifications (email, webhooks)
```

Each change object:

```powershell
@{
    severity    = "High" | "Medium" | "Low"
    changeType  = "created" | "updated" | "removed"
    description = "Human-readable change"
    old         = $previousObject
    new         = $currentObject
}
```

## How it works

### 1. Compare-InventoryFolder

Located in `src/diff.ps1`.

**Input:**
- `FolderPath` - path to `inventory/{workload}/{slug}/`
- `NewData` - hashtable: `@{ definition = $obj; policy = $obj; assignments = $obj }`
- `EntityName` - used for logging

**Process:**
1. Read old files from disk (returns `null` if new entity)
2. For each file type (definition, policy, assignments):
   - Quick check with `Test-ObjectEqual` - skip if identical
   - If different, run detailed comparison per type
3. Return array of change objects

### 2. Definition comparison

- If `rolePermissions` changed: **High**
- Otherwise: **Low** (metadata like displayName)

```powershell
$oldPerms = $oldData.PSObject.Properties['rolePermissions']?.Value
$newPerms = $newDataForFile.PSObject.Properties['rolePermissions']?.Value
if ($oldPerms -and $newPerms -and -not (Test-ObjectEqual -Left $oldPerms -Right $newPerms)) {
    $severity = "High"
} else {
    $severity = "Low"
}
```

`PSObject.Properties['key']?.Value` is used instead of direct `.rolePermissions` access because `Set-StrictMode -Version Latest` throws when a property does not exist on a PSCustomObject (e.g., auth contexts and admin units do not have `rolePermissions`).

### 3. Policy comparison - Compare-PolicyRules

**Directory Roles:**
1. Extract `policy.rules` array from old and new
2. Build lookup by `rule.id`
3. Detect added, removed, and modified rules
4. Look up severity for each rule from `$PolicyRuleSeverity`

**PIM Groups:**
1. Detect the `{ member: {...}, owner: {...} }` wrapper structure
2. Recurse into each access type
3. Return sub-changes labeled with `member` or `owner`

```powershell
$isWrapped = (Test-ObjectHasKey -Object $NewPolicy -Key 'member') -or
             (Test-ObjectHasKey -Object $NewPolicy -Key 'owner')
if ($isWrapped) {
    foreach ($accessId in @('member', 'owner')) {
        # Recurse: Compare-PolicyRules -OldPolicy $oldSub -NewPolicy $newSub
    }
}
```

### 4. Assignment comparison - Compare-Assignments

**Process:**
1. Extract `permanent`, `eligible`, and `active` arrays from old and new
2. For each category, build a lookup by `Get-AssignmentKey` (principalId + scope)
3. Detect removed, added, and modified assignments
4. Apply severity per category and duration

**Assignment key (for matching):**

```powershell
# Directory Roles
$key = "$principalId|$directoryScopeId"

# PIM Groups
$key = "$principalId|$groupId|$accessId"
```

**Severity logic:**
- Permanent: **High**
- New with no `endDateTime`: **High**
- New with expiration: **Medium**
- Modified or removed: **Low**

### 5. Removed entities - Get-RemovedEntities

Detects entities present in the last scan but missing from the current fetch.

**Process:**
1. List all folders in the workload directory
2. Check each folder against current slugs (case-insensitive)
3. If a folder has no match: entity was removed
4. Return a High-severity change for each

## Example: detecting an MFA policy change

```powershell
$oldPolicy = @{ policy = @{ rules = @( @{ id='Enablement_EndUser_Assignment'; enabledRules=@() } ) } }
$newPolicy = @{ policy = @{ rules = @( @{ id='Enablement_EndUser_Assignment'; enabledRules=@('MultiFactorAuthentication') } ) } }

$changes = Compare-PolicyRules -OldPolicy $oldPolicy -NewPolicy $newPolicy -Context 'Global Administrator'
```

Result:

```
@{
    severity    = "High"
    ruleId      = "Enablement_EndUser_Assignment"
    changeType  = "updated"
    description = "Policy rule changed: Enablement_EndUser_Assignment (Global Administrator)"
    old         = @{ id='Enablement_EndUser_Assignment'; enabledRules=@() }
    new         = @{ id='Enablement_EndUser_Assignment'; enabledRules=@('MultiFactorAuthentication') }
}
```

## Customizing

**Add a severity rule** - edit `src/diff.ps1:22-40`:

```powershell
$script:PolicyRuleSeverity = [ordered]@{
    "MyCustomRule_"  = "High"
    # ...
}
```

**Change permanent assignment severity** - edit `src/diff.ps1:312-316`:

```powershell
$severity = switch ($category) {
    "permanent" { "Medium" }  # was "High"
    # ...
}
```

**Customize object equality** - edit `src/diff.ps1:54-65`. By default, `Test-ObjectEqual` serializes to JSON and compares strings. You can add field exclusions or property-level comparisons.

## Performance

All comparisons are O(n). No quadratic operations.

**Parallel role fetching** (v2.0+): Role policies and assignments are fetched in parallel using PowerShell 7 `ForEach-Object -Parallel` with a throttle limit of 8 workers. This replaces the sequential per-role loop.

| Step | Time | Notes |
|---|---|---|
| Role definitions fetch | ~5s | Sequential, single call |
| Per-role fetch (8-worker parallel) | ~8-10s | Policies + 3 assignment types per role, network I/O overlapped |
| All diffs | ~100ms | Sequential, CPU-bound |
| Total | ~15-18s | 4-5x speedup vs sequential fetch |

**Tuning:** Adjust `-ThrottleLimit` in `src/Scan-PimState.ps1` line 227 to balance parallelism and Graph API throttling.

## Testing locally

```powershell
. ./src/helpers.ps1
. ./src/diff.ps1

$oldPolicy = @{ ... }
$newPolicy = @{ ... }

$changes = Compare-PolicyRules -OldPolicy $oldPolicy -NewPolicy $newPolicy -Context 'Test'
$changes | ForEach-Object { Write-Host $_.description }
```

See `src/README.md` for end-to-end test examples.
