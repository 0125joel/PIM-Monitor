---
sidebar_position: 1
---

# Inventory Structure

The `inventory/` folder contains the current PIM state as JSON files, organized by workload and entity.

## Top-level layout

```
inventory/
├── directory-roles/
├── pim-groups/
├── authentication-contexts/
└── administrative-units/
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
