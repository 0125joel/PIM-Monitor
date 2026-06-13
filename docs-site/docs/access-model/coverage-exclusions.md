---
sidebar_position: 4
description: Detect inventory roles that appear in no access-model file, and opt specific roles out of unclassified-role alerts.
keywords:
  - coverage check
  - unclassified roles
  - EAM_COVERAGE_SCOPE
  - role exclusions
  - access-model coverage
---

# Coverage and Exclusions

The coverage check answers one question: *are there privileged roles you have not classified yet?* Any role in the inventory that appears in no access-model file is reported as unclassified in the dedicated Classification section of every notification, until you either classify it or exclude it.

By default only roles with `isPrivileged=true` are checked. Set [`EAM_COVERAGE_SCOPE=all`](./overview.mdx#one-optional-setting) to check every inventory role.

## When a role shows up as unclassified

You have two choices:

| You want to... | Do this |
|---|---|
| **Classify it** | Add the role to an access-model file. See [Setup & Compliance](./setup-compliance.mdx). |
| **Leave it unclassified on purpose** | Exclude it (below), so it stops appearing. |

## Excluding a role permanently

Create `AccessModel/coverage-exclusions.json`:

```json
{
  "excludedRoleIds": [
    {
      "id": "fe930be7-5e62-47db-91af-98c3a49a38b1",
      "displayName": "User Administrator",
      "reason": "Intentionally not under access-model management."
    }
  ]
}
```

Matching is by `id`. `displayName` and `reason` are for your own records.

## Advanced: suppressing temporarily instead

If a role is only *temporarily* unclassified (under review, will be assigned to a plane soon), suppress it with a deadline instead of a permanent exclusion. Add an entry to `expected-changes.json`:

```json
{
  "expected": [
    {
      "workload": "directory-roles",
      "entity": "user-administrator",
      "fileType": "access-model-coverage",
      "reason": "Under access review, will be assigned to a plane by 2026-06-01",
      "expiresUtc": "2026-06-01T00:00:00Z"
    }
  ]
}
```

Use `fileType: "access-model-coverage"` for directory-role coverage alerts. When `expiresUtc` passes, the alert returns until you classify or exclude the role.

| Approach | Use when |
|---|---|
| `coverage-exclusions.json` | Permanent: the role is known and intentionally outside the access model |
| `expected-changes.json` with `access-model-coverage` | Temporary: the role will be classified by a deadline |
