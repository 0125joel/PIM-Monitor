# EAM classification rubric

How a built-in Entra directory role gets its EAM plane and security level. The weekly review routine
applies it to new and changed roles, and `Invoke-CatalogBacktest.ps1` scores the routine against the
hand-reconciled catalog. The method in short is also on the
[EAM Role Catalog](../docs-site/docs/access-model/eam-role-catalog.mdx) page; this file is the detail
the routine works from.

The permissions of a role decide, not its name. Read `rolePermissions[].allowedResourceActions`. The
name and description are context. When the name and the action namespace disagree, the namespace wins.

## What is mechanical and what is judgement

| Step | Who |
|---|---|
| `isPrivileged = true` means Privileged. This is a floor, nothing lowers it | Code. `Test-CatalogChangeIsAutoSafe.ps1` rejects a role that breaks it |
| Plane from the action namespaces | Judgement, rubric below |
| Level from the depth and breadth of the actions | Judgement, rubric below |
| PIM policy (activation time, MFA, approval, auth context) and severity | Fixed per level in `eam-catalog-defaults.json`. The routine copies it and never invents values |

## Plane: the function

**Control: the actions govern identity and access control itself.** Signals (`microsoft.directory/...`
and related):

- authentication and credentials: `users/authenticationMethods/*`, `users/password/update`,
  `.../credentials`, `policies/authenticationMethodsPolicy/*`, `authenticationContextClassReferences/*`
- authorization and role management: `roleAssignments/*`, `roleDefinitions/*`,
  `roleManagementPolicies/*`, `conditionalAccessPolicies/*`, `crossTenantAccessPolicy/*`
- identity objects that gate access: `users/*` (write), `groups/*` (write), `applications/*`,
  `servicePrincipals/*`, `agentIdentityBlueprints/*`, `domains/*` and federation,
  `identityProviders/*`, `b2cUserFlows/*`, `b2cUserAttribute/*`, `externalUserProfiles/*`,
  `onPremisesSynchronization/*`
- access-shaping configuration: `customSecurityAttributeDefinitions/*`, `microsoft.permissionsManagement/*`,
  `microsoft.agentRegistry/*`, `microsoft.commerce.tenantRelationships/customerDelegatedAdminPrivileges/*`

Test: a compromise changes who can access what across the tenant, or reveals the security
architecture. Readers of identity and security configuration stay Control (Global Reader, Security
Reader). Default and pathway roles (User, Guest User, Guest Inviter, Directory Readers) are Control by
function and Enterprise by level.

**Management: the actions administer one workload or the hosting infrastructure, bounded to a
service.** Signals: `microsoft.office365.exchange/*`, `microsoft.office365.sharepoint/*`,
`microsoft.teams/*`, `microsoft.intune/*`, `microsoft.directory/devices/*` (writing devices is device
management), `microsoft.dynamics365/*`, `microsoft.powerApps/*`, `microsoft.office365.organizationalMessages/*`,
`microsoft.peopleAdmin/*`, `microsoft.people/*`, Defender and Purview workload actions, and IT
management functions (billing, licences, network, printers). Test: control is bounded to a service,
and the actions are configuration, not full business data. A workload namespace makes a role
Management even when its name sounds tenant-wide.

**Data: the actions mostly read or serve business data, telemetry or end-user support.** Signals:
`microsoft.office365.usageReports/*`, `microsoft.office365.messageCenter/*`, support actions,
`.../standard/read`, printer technician and device-user actions (read and join, not write), backup
readers. A role whose actions are only reads of reports or the message center is Data even when its
name is managerial.

## Level: the depth

After the isPrivileged floor:

- **Privileged**: tenant-wide identity or security control, or full data-plane access to a whole
  workload (all mailbox content, all site and OneDrive content, all source code, all CRM or ERP data).
  This is the blast-radius escalation. It is derived from the permissions, not from a list.
- **Specialized**: bounded service administration or an elevated-impact function, without tenant
  identity control and without full workload data access. Writing or managing access-shaping
  configuration is Specialized, not Enterprise.
- **Enterprise**: read-only, end-user, default, or low-impact actions. Enterprise is not the default
  for an admin role: a role that writes something that shapes identity or access is at least
  Specialized.

## Tie-breakers

1. Identity and security actions outrank workload actions. A role that writes `conditionalAccessPolicies`
   or `crossTenantAccessPolicy` is Control, even when named for a network product.
2. Scope matters: tenant-wide identity control is Control, service-bounded administration is
   Management, data read or support is Data.
3. Read-only does not lower the plane. It lowers the level, unless the floor forces Privileged.
4. Trust the namespace over the name.

## Worked examples

| Role | Plane | Level | Why |
|---|---|---|---|
| Global Administrator | Control | Privileged | isPrivileged; controls all identity and access |
| Groups Administrator | Control | Specialized | Control writer, not isPrivileged; narrower scope |
| Global Reader | Control | Privileged | Read-only but isPrivileged; the floor beats read-only |
| Directory Readers | Control | Enterprise | Control by function, default low-impact role |
| Exchange Administrator | Management | Privileged | Workload admin; full mailbox access escalates |
| Exchange Recipient Administrator | Management | Specialized | Same workload, scoped sub-admin, no full content |
| Billing Administrator | Management | Specialized | Bounded IT management function |
| Reports Reader | Data | Enterprise | Reads usage data, no service control |
| AI Reader | Data | Privileged | Read-only, but isPrivileged forces Privileged |
| Global Secure Access Administrator | Control | Specialized | Name says network, but it writes `conditionalAccessPolicies` and `crossTenantAccessPolicy` |
| Device Managers | Management | Specialized | Writes `directory/devices`; device management, not Data |
| People Administrator | Management | Specialized | `peopleAdmin` and `people` are a workload, not directory identity |
| User Experience Success Manager | Data | Enterprise | Only reads `usageReports` and `messageCenter` |
| Attribute Definition Administrator | Control | Specialized | Writes `customSecurityAttributeDefinitions`; access-shaping write is Specialized |

## Output per role

The routine records one verdict per role, in the pull request description:

```json
{
  "templateId": "<guid>",
  "plane": "Control | Management | Data",
  "securityLevel": "Privileged | Specialized | Enterprise",
  "note": "one line, at most 240 characters, names the deciding actions",
  "confidence": "high | medium | low",
  "signal": "the action namespace that decided it"
}
```

A role with `confidence: low` is written to the pull request description as a question and keeps
`reviewNeeded: true`. Auto-merge never applies to it (see ROUTINE.md).
