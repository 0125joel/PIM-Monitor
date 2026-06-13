---
sidebar_position: 5
description: Classify PIM-enabled groups by severity and enforce expected member and owner PIM policies.
keywords:
  - PIM groups
  - PIM-enabled groups
  - member and owner policy
  - group PIM policy compliance
  - role-assignable groups
---

# PIM Groups

PIM-enabled groups work the same way as directory roles, with one twist: each group has two policies, one for members and one for owners. You classify and enforce them independently.

Everything from [Setup & Compliance](./setup-compliance.mdx) (compliance vs coverage, severity, sparse `expectedConfig`) applies here too. This page covers only what is different for groups.

## Prerequisites

Before a group can be classified, it has to appear in the inventory at all:

- **Licensing.** Microsoft Entra ID P2 or Microsoft Entra ID Governance is required for each user with an eligible or time-bound assignment in a PIM group. This is what makes the group appear in PIM; it is not a constraint on PIM Monitor's read-only scanning.
- **Group type.** Only cloud-native security groups and Microsoft 365 groups can be PIM-onboarded. Dynamic-membership groups and groups synced from on-premises AD cannot be, and simply never appear in `inventory/pim-groups/`. No special handling needed.

## Deciding a group's severity

Group names carry no reliable signal, but one property does. Check `isAssignableToRole`:

```powershell
Get-MgGroup -GroupId "YOUR-GROUP-ID" -Property isAssignableToRole | Select-Object DisplayName, isAssignableToRole
```

| `isAssignableToRole` | Recommended severity | Why |
|---|---|---|
| `true` | **High** | Can be granted Entra roles. Maximum blast radius, and only Global Admin / Privileged Role Admin / the group owner can manage it. |
| `false`, but grants Azure resource roles or privileged SaaS access | High or Medium | Depends on scope |
| General IT operations (helpdesk, licensing) | Low | Limited blast radius |

Unlike directory roles, the coverage check always covers all PIM-enabled groups regardless of `EAM_COVERAGE_SCOPE`.

## File format

Create files in `AccessModel/pim-groups/`. The shape mirrors directory roles, with `groups` instead of `roles` and a split `member` / `owner` `expectedConfig`:

```json
{
  "name": "Privileged Access Groups",
  "description": "Groups providing access to Entra roles or critical resources.",
  "severity": "High",
  "groups": [
    { "id": "12345678-1234-1234-1234-123456789012", "displayName": "PAW-Tier0-Admins-Members" }
  ],
  "expectedConfig": {
    "member": {
      "requireMFA": true,
      "requireApproval": true,
      "maxActivationDuration": "PT2H",
      "allowPermanentEligible": false,
      "allowPermanentActive": false
    },
    "owner": {
      "requireMFA": true,
      "requireApproval": true,
      "maxActivationDuration": "PT1H",
      "allowPermanentEligible": false,
      "allowPermanentActive": false
    }
  }
}
```

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Display name used in notifications |
| `severity` | Yes | `High`, `Medium`, or `Low` |
| `groups` | Yes | Array of `{ "id": "<groupId>", "displayName": "..." }`. Only `id` is matched. |
| `description` | No | Informational |
| `expectedConfig` | No | Separate `member` and `owner` objects. Each supports the [same fields as directory roles](./setup-compliance.mdx#expectedconfig-fields). Omit to classify by severity only. |

## Coverage and exclusions

Unclassified groups appear in the same Classification section as unclassified roles. Exclude them with `excludedGroupIds`:

```json
{
  "excludedGroupIds": [
    {
      "id": "GROUP-ID",
      "displayName": "Test-Group",
      "reason": "Temporary test group."
    }
  ]
}
```

## Advanced: suppressing group violations

Groups use the same `expected-changes.json` mechanism as directory roles, with group-specific `fileType` values:

| fileType | Suppresses |
|---|---|
| `group-compliance` | A specific `expectedConfig` deviation for a group |
| `group-coverage` | An "unclassified group" alert |

Because member and owner have separate policies, the compliance `ruleId` is prefixed: `member/<field>` or `owner/<field>`. A `member/requireApproval` suppression does not suppress the matching `owner/requireApproval` violation.

```json
{
  "expected": [
    {
      "workload": "pim-groups",
      "entity": "paw-tier0-admins-members",
      "fileType": "group-compliance",
      "ruleId": "member/requireApproval",
      "reason": "Approval requirement being phased in by 2026-08-01",
      "expiresUtc": "2026-08-01T23:59:59Z"
    },
    {
      "workload": "pim-groups",
      "entity": "security-investigations",
      "fileType": "group-coverage",
      "reason": "Under access review, will be classified by 2026-07-01",
      "expiresUtc": "2026-07-01T00:00:00Z"
    }
  ]
}
```

## Examples

Start from the templates in `Examples/access-model/pim-groups/`:

- `PrivilegedAccessGroups.json`: groups with Entra role assignment or critical resource access (High)
- `SecurityOperationsGroups.json`: SOC and incident response groups with moderate policies (Medium)
- `ITServiceGroups.json`: IT service delivery groups, classification only, no enforcement (Low)
