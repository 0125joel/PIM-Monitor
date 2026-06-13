---
sidebar_position: 1
description: Suppress known-good changes in PIM Monitor using expected-changes.json. Define time-bound suppressions for planned maintenance windows.
---

# Expected Change Suppression

Suppress known-good changes so PIM Monitor only alerts on the unexpected.

## Problem

When you intentionally modify a PIM policy through the Entra portal or PIM Manager, the next scan detects it as a change and fires a notification. For planned maintenance this is noise: you already know the change is coming.

## Solution

Create an `expected-changes.json` file in the repository root before making your changes. During a scan, any detected change that matches an entry in this file is suppressed from notifications. The inventory file is still updated and committed; only the notification is skipped.

After the scan, PIM Monitor automatically cleans up the file:
- Consumed entries (matched and no longer needed) are removed.
- Expired entries (`expiresUtc` in the past) are removed.
- If no entries remain, the file is deleted.

## Format

```json
{
  "expected": [
    {
      "workload":   "directory-roles",
      "entity":     "global-administrator",
      "fileType":   "policy",
      "ruleId":     "Expiration_EndUser_Assignment",
      "reason":     "Activation duration changed to 4 h per SEC-1234",
      "expiresUtc": "2026-05-01T00:00:00Z"
    }
  ]
}
```

## Field Reference

All fields are optional. Omitting a field makes it a wildcard: matching is AND-based across the fields you do provide.

| Field | Description | Example values |
|---|---|---|
| `workload` | Limits matching to one workload type | `directory-roles`, `pim-groups`, `authentication-contexts`, `administrative-units` |
| `entity` | Limits matching to one entity (kebab-case slug) | `global-administrator`, `tier-0-admins` |
| `fileType` | Limits matching to one file type | `definition`, `policy`, `assignments`, `access-model-compliance`, `access-model-coverage`, `group-compliance`, `group-coverage` |
| `ruleId` | For policy changes: limits to a specific rule ID | `Enablement_EndUser_Assignment`, `Approval_EndUser_Assignment` |
| `reason` | Free-text note for your own reference. Not evaluated by the filter. | `"SEC-1234 approved"` |
| `expiresUtc` | ISO 8601 UTC timestamp. Entries past this time are ignored and removed. | `"2026-05-01T17:00:00Z"` |

> [!NOTE]
> An entry with no fields at all suppresses every detected change for as long as the entry exists. This is almost never what you want. Always include at least `workload` + `entity` + `fileType`.

## Matching Examples

**Suppress one specific policy rule on one role:**
```json
{ "workload": "directory-roles", "entity": "global-administrator", "fileType": "policy", "ruleId": "Enablement_EndUser_Assignment" }
```

**Suppress all policy changes on one role (any rule):**
```json
{ "workload": "directory-roles", "entity": "global-administrator", "fileType": "policy" }
```

**Suppress any assignment change across all roles:**
```json
{ "workload": "directory-roles", "fileType": "assignments" }
```

**Suppress all changes on one PIM group:**
```json
{ "workload": "pim-groups", "entity": "tier-0-admins" }
```

## Finding the Entity Slug

The `entity` field must match the folder name under `inventory/`. Folder names are derived from the `displayName` in lowercase, with spaces replaced by hyphens and special characters stripped.

Examples:

| Display name | Slug |
|---|---|
| `Global Administrator` | `global-administrator` |
| `Exchange Online (Protection) Administrator` | `exchange-online-protection-administrator` |
| `Tier-0 Admins` | `tier-0-admins` |

To look up the exact slug for a role or group, check the folder names under `inventory/directory-roles/` or `inventory/pim-groups/` in the repository.

## Workflow

### Before a planned change

1. Create or update `expected-changes.json` in the repository root.
2. Commit and push the file to the `main` branch.
3. Make your configuration changes in Entra ID (via the portal or PIM Manager).

### During the next scan

The scan detects your changes, matches them against `expected-changes.json`, and suppresses matching ones from notifications. The inventory is still updated and committed.

### After the scan

`expected-changes.json` is rewritten to remove expired entries. Matched entries are kept until their `expiresUtc`, so they keep suppressing on every scan inside the window (a two-step change or a briefly stale Graph response would otherwise re-alert). When no entries remain, the file is deleted. Check the git history of the file to confirm cleanup happened.

### Example timeline

**Monday 9:00**: commit `expected-changes.json`:
```json
{
  "expected": [
    {
      "workload":   "directory-roles",
      "entity":     "global-administrator",
      "fileType":   "policy",
      "ruleId":     "Enablement_EndUser_Assignment",
      "reason":     "MFA config update per security review",
      "expiresUtc": "2026-04-28T17:00:00Z"
    }
  ]
}
```

**Monday 9:15**: make the policy change in the Entra portal.

**Monday 9:30**: scan runs. MFA policy change detected, matched, suppressed. No notification sent; the updated `policy.json` is still committed. The entry stays in `expected-changes.json` and keeps suppressing until its `expiresUtc`.

**Monday 10:00**: scan runs again. No changes detected. No notification. Business as usual.

**First scan after Monday 17:00**: the entry has expired and is removed. Nothing else remains, so `expected-changes.json` is deleted and the deletion is committed.

## Common Rule IDs

For policy changes, the most commonly suppressed rule IDs:

| Rule ID | What it controls |
|---|---|
| `Enablement_EndUser_Assignment` | MFA, justification, ticketing on activation |
| `Approval_EndUser_Assignment` | Approval requirement and approvers |
| `Expiration_EndUser_Assignment` | Maximum activation duration |
| `Expiration_Admin_Eligibility` | Maximum eligible assignment duration |
| `Expiration_Admin_Assignment` | Maximum active assignment duration |
| `Notification_*` | Any of the 9 notification rules |

For the full list, see [Reference: Diff Engine](/docs/reference/diff-engine).

## Best Practices

- Set `expiresUtc` to a few hours after you plan to make the change, not days. A narrow window limits the suppression surface.
- Include `ruleId` for policy changes. Matching on `fileType: "policy"` alone suppresses all policy changes on the role, including ones you did not plan.
- Commit `expected-changes.json` before making the Entra change, not after. If the scan runs between your change and the commit, a notification fires.
- Review the git history of `expected-changes.json` after the scan to confirm it was cleaned up.

## What Is NOT Suppressed

- The inventory file is still updated. The change is still committed and visible in git history.
- Other changes on the same entity that do not match the entry are still notified.
- Changes detected after `expiresUtc` are always notified, regardless of whether you intended them or not.

## Examples

Five ready-to-use scenarios are available in the `Examples/expected-changes/` directory of the repository. Pick the one closest to your situation, copy its content to `expected-changes.json` in the repository root, customize the fields to match your change, and commit:

| Scenario | File | Use when |
|---|---|---|
| **Single policy rule on one role** | `01-planned-policy-tightening.json` | You're tightening a PIM policy (e.g., reducing max activation duration) and want to suppress the notification for a specific deadline. |
| **New role onboarding** | `02-new-role-onboarding.json` | You've just onboarded a new directory role to PIM and want to suppress the three initial change notifications (definition, assignment, policy). |
| **Temporary access-model deviation** | `03-temporary-compliance-deviation.json` | A role's actual PIM policy temporarily deviates from its expected config in `AccessModel/`; suppress it with a deadline. |
| **Bulk assignment cleanup** | `04-bulk-assignment-cleanup.json` | You're doing an org-wide role cleanup and want to suppress the assignment changes across multiple roles for the same deadline. |
| **Break-glass account** | `05-emergency-access-account.json` | You've created a permanent break-glass emergency access account and want to permanently suppress its assignment change. |

For detailed guidance on each scenario, see the README in `Examples/expected-changes/`.
