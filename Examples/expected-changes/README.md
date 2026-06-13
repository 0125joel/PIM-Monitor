# Expected-Changes Examples

Five scenarios showing how to suppress known-good changes. Pick the one closest to your situation, copy its content to `expected-changes.json` in the repository root, adjust the `entity`, `ruleId`, and `expiresUtc` fields to match your change, and commit.

## The five scenarios

| File | Scenario | Use when |
|---|---|---|
| `01-planned-policy-tightening.json` | Single policy rule change on one role | You're tightening a PIM policy (e.g., reducing max activation duration) and want to suppress the notification for a specific deadline. |
| `02-new-role-onboarding.json` | New role definition + assignment + policy | You've just onboarded a new directory role to PIM and want to suppress the three initial change notifications (definition, assignment, policy) until you classify it. |
| `03-temporary-compliance-deviation.json` | Temporary access-model compliance deviation | A role's actual PIM policy temporarily deviates from its expected config (e.g., approval requirement being phased out) — suppress it with a deadline. |
| `04-bulk-assignment-cleanup.json` | Bulk assignment removals across roles | You're doing an org-wide role cleanup (removing contractors, restructuring) and want to suppress the assignment changes across multiple roles for the same deadline. |
| `05-emergency-access-account.json` | Break-glass account (no expiration) | You've created a permanent break-glass emergency access account and want to permanently suppress its assignment change (no `expiresUtc` = never expires). |

## How to use

1. **Pick** the scenario closest to your change.
2. **Copy** its content to `expected-changes.json` in your repository root.
3. **Edit** the `entity` field to match your role's slug (e.g., `global-administrator` — check the folder names under `inventory/directory-roles/`).
4. **Edit** the `ruleId` field (if present) to match your specific change. For policy changes, use the rule ID from the Policy Reference in the docs.
5. **Edit** the `expiresUtc` field to a time a few hours after you plan to make the change (narrow windows are better).
6. **Commit** the file to the main branch.
7. **Make** your change in Entra ID (via portal or PIM Manager).
8. **Next scan** will detect and suppress your change. The file is auto-cleaned afterwards.

## Finding your entity slug

The `entity` field must match the folder name under `inventory/directory-roles/`. Slugs are lowercase role display names with spaces replaced by hyphens:

| Role display name | Slug |
|---|---|
| `Global Administrator` | `global-administrator` |
| `Exchange Administrator` | `exchange-administrator` |
| `Helpdesk Administrator` | `helpdesk-administrator` |

To find the exact slug for your role, check the folder names in `inventory/directory-roles/` after at least one scan.

## Common rule IDs for policy changes

When suppressing policy changes, use the `ruleId` to target a specific rule:

| Rule ID | What it controls |
|---|---|
| `Enablement_EndUser_Assignment` | MFA, justification, ticketing on activation |
| `Approval_EndUser_Assignment` | Approval requirement and approvers |
| `Expiration_EndUser_Assignment` | Maximum activation duration |
| `Expiration_Admin_Eligibility` | Maximum eligible assignment duration |
| `Expiration_Admin_Assignment` | Maximum active assignment duration |

Omit `ruleId` to suppress all policy changes on a role (less precise).

## What's not suppressible

- The inventory file is still updated and committed to git — suppressions only hide the notification.
- Other changes on the same role that don't match your entry are still notified.
- Changes after `expiresUtc` are always notified, even if you intended them.

See [`docs-site/docs/customize/expected-changes.md`](../../docs-site/docs/customize/expected-changes.md) for the complete reference and advanced matching patterns.
