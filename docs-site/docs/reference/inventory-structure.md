---
sidebar_position: 1
description: PIM Monitor inventory structure reference. Learn how directory roles, PIM groups, authentication contexts, administrative units, and activation events are organized in JSON files.
---

# Inventory Structure

The `inventory/` folder contains the current PIM state as JSON files, organized by workload and entity.

## Top-level layout

```
inventory/
├── directory-roles/
├── pim-groups/
├── authentication-contexts/
├── conditional-access/
├── administrative-units/
├── activation-events/
└── archive/
```

Each entity gets its own subfolder using a slugified name. For example: `inventory/directory-roles/global-administrator/`.

## Directory Roles

```
inventory/directory-roles/{slug}/
├── definition.json
├── policy.json
└── assignments.json
```

### definition.json

```json
{
  "id": "62e90394-69f5-4237-9190-012177145e10",
  "displayName": "Global Administrator",
  "description": "...",
  "isBuiltIn": true,
  "isEnabled": true,
  "rolePermissions": [
    {
      "allowedResourceActions": ["*"],
      "condition": null
    }
  ]
}
```

### policy.json

PIM policy assignment with expanded rules:

```json
{
  "id": "policyAssignmentId",
  "scopeId": "/",
  "scopeType": "Directory",
  "roleDefinitionId": "roleId",
  "policy": {
    "id": "policyId",
    "rules": [
      {
        "id": "Enablement_EndUser_Assignment",
        "enabledRules": ["MultiFactorAuthentication"],
        "notificationLevel": "All"
      },
      {
        "id": "Expiration_EndUser_Assignment",
        "maximumDuration": "PT8H"
      }
    ]
  }
}
```

### assignments.json

```json
{
  "permanent": [
    {
      "id": "assignmentId1",
      "principalId": "userId1",
      "principal": {
        "id": "userId1",
        "displayName": "Alice Admin",
        "userPrincipalName": "alice@contoso.com"
      },
      "directoryScopeId": "/",
      "createdDateTime": "2024-01-15T10:00:00Z"
    }
  ],
  "eligible": [
    {
      "id": "eligibleId1",
      "principalId": "userId2",
      "principal": { "id": "userId2", "displayName": "Bob User" },
      "directoryScopeId": "/",
      "scheduleInfo": {
        "expiration": {
          "endDateTime": "2027-04-20T00:00:00Z"
        }
      }
    }
  ],
  "active": [
    {
      "id": "activeId1",
      "principalId": "userId3",
      "scheduleInfo": {
        "expiration": {
          "endDateTime": "2026-04-21T15:30:00Z"
        }
      }
    }
  ]
}
```

## PIM Groups

```
inventory/pim-groups/{slug}/
├── definition.json
├── policy.json
└── assignments.json
```

### definition.json

```json
{
  "id": "groupId",
  "displayName": "Finance Admins",
  "description": "...",
  "groupTypes": [],
  "visibility": "Private"
}
```

### policy.json

Two policy assignments, one per access type:

```json
{
  "member": {
    "id": "policyAssignment_member",
    "scopeId": "groupId",
    "scopeType": "Group",
    "roleDefinitionId": "member",
    "policy": {
      "rules": [
        {
          "id": "Enablement_EndUser_Assignment",
          "enabledRules": ["MultiFactorAuthentication"]
        }
      ]
    }
  },
  "owner": {
    "id": "policyAssignment_owner",
    "scopeId": "groupId",
    "scopeType": "Group",
    "roleDefinitionId": "owner",
    "policy": {
      "rules": [
        {
          "id": "Enablement_EndUser_Assignment",
          "enabledRules": ["MultiFactorAuthentication"]
        }
      ]
    }
  }
}
```

### assignments.json

```json
{
  "eligible": [
    {
      "id": "scheduleId1",
      "principalId": "userId1",
      "groupId": "groupId",
      "accessId": "member",
      "principal": {
        "id": "userId1",
        "displayName": "Alice Admin"
      },
      "scheduleInfo": {
        "expiration": {
          "endDateTime": "2027-04-20T00:00:00Z"
        }
      }
    }
  ],
  "active": []
}
```

Each entry has an `accessId` field (`member` or `owner`).

## Lookups

Lookups are read-only catalogs of IDs to display names. They contain only `definition.json` and are never diffed for severity.

### authentication-contexts

```
inventory/authentication-contexts/{slug}/
└── definition.json
```

```json
{
  "id": "c1",
  "displayName": "Require MFA",
  "description": "..."
}
```

Resolves `claimValue` references in policy rules like `AuthenticationContext_EndUser_Assignment`.

The `config.json` file in each auth context folder is operator-defined and never written by the scan pipeline. See [Auth Context CA Compliance](../access-model/auth-context-compliance.md) for the supported fields.

## Conditional Access

CA policies that reference at least one auth context claim are stored here. Only policies with `conditions.applications.includeAuthenticationContextClassReferences` set are stored. All other CA policies are out of scope.

```
inventory/conditional-access/{slug}/
└── definition.json
```

```json
{
  "id": "policyId",
  "displayName": "PIM - Phishing-resistant MFA + SIF",
  "state": "enabled",
  "conditions": {
    "applications": {
      "includeAuthenticationContextClassReferences": ["c2"]
    }
  },
  "grantControls": {
    "authenticationStrength": {
      "id": "00000000-0000-0000-0000-000000000003"
    }
  },
  "sessionControls": {
    "signInFrequency": {
      "isEnabled": true,
      "frequencyInterval": "everyTime"
    }
  }
}
```

**Note:** The `includeAuthenticationContextClassReferences` field is only available on the beta endpoint. PIM Monitor uses `$GraphBeta/identity/conditionalAccess/policies` for this workload.

### administrative-units

```
inventory/administrative-units/{slug}/
└── definition.json
```

```json
{
  "id": "auId",
  "displayName": "Finance Department",
  "description": "..."
}
```

Resolves `directoryScopeId` in assignments scoped to an AU instead of the full tenant.

## Archive

When a role or group disappears from PIM (removed, offboarded, or renamed to a different slug), its inventory folder is not deleted. PIM Monitor moves it to `inventory/archive/{workload}/{slug}_{date}`:

```
inventory/archive/
├── directory-roles/
│   └── old-role-name_2026-04-26/
│       ├── definition.json
│       ├── policy.json
│       └── assignments.json
└── pim-groups/
    └── disbanded-group_2026-03-01/
        ├── definition.json
        ├── policy.json
        └── assignments.json
```

The date suffix is the UTC date of the scan that first detected the removal.

### What is preserved

The full folder contents (definition, policy, and assignments) are moved as-is. This means:

- The last known state of the entity is readable on disk without touching git history.
- The git history of the original folder is preserved. `git log inventory/directory-roles/old-role-name/` still shows all changes the entity went through before it was removed.
- Notifications fire for the removal: it is recorded as a `High` severity change entry and sent via email or webhook if configured.

### Renamed roles

If a role is renamed in Entra ID, its slug changes (slugs are derived from `displayName`). PIM Monitor sees this as a removal of the old slug and a creation of the new one. The old folder is archived; a new folder is created on the same scan run.

### Browsing archived entities

```bash
ls inventory/archive/directory-roles/
git log --oneline inventory/archive/directory-roles/old-role-name_2026-04-26/
git show HEAD:inventory/archive/directory-roles/old-role-name_2026-04-26/assignments.json
```

## Deterministic serialization

All JSON files are serialized the same way every time. Same data always produces identical output. This keeps `git diff` clean and meaningful.

- Objects with an `id` field: sorted by `id`
- Strings: sorted alphabetically
- `@odata.context`, `@odata.type`, and other metadata fields are stripped

## Git history

Every inventory change becomes a commit:

```bash
git log --oneline inventory/
```

Output:
```
a1b2c3d scan: 2026-04-20T15:30:00Z
e5f6g7h scan: 2026-04-20T15:00:00Z
```

To see what changed between two scans:

```bash
git diff a1b2c3d~1 a1b2c3d -- inventory/
```
