# PIM Groups Access Model Examples

Starter files for classifying PIM-enabled groups against the Microsoft Enterprise Access Model (EAM). Drop the folders into `AccessModel/pim-groups/` in your repository root and replace the placeholder GUIDs with your actual group object IDs.

## Structure

```
AccessModel/pim-groups/
├── ControlPlane/
│   └── Privileged.json     ← groups gating Control Plane access
├── ManagementPlane/
│   ├── Privileged.json     ← groups gating blast-radius workload access
│   └── Specialized.json    ← groups gating scoped workload or app access
└── DataWorkloadPlane/
    └── Enterprise.json     ← groups gating read-only or low-impact data access
```

## Classification principle: Clean Source

Unlike directory roles — which have a stable, intrinsic classification — **groups have no inherent EAM classification.** A group's plane and security level are determined entirely by what access membership grants.

**Rule: classify a group at the plane and security level of the most privileged access it provides.**

This is the Clean Source principle from the EAM: a trusted source (the group) must never be classified lower than its destination (the access it grants). Examples:

| Group provides access to | Plane | Security Level |
|---|---|---|
| Global Administrator or Privileged Role Administrator role | Control | Privileged |
| Break-glass / PAW admin access | Control | Privileged |
| Exchange Administrator, SharePoint Administrator, Intune Administrator (full-service) | Management | Privileged |
| Azure subscription Owner or Contributor | Management | Privileged |
| Scoped SOC tooling, specific app admin role, limited Azure resource access | Management | Specialized |
| Read-only reports, compliance dashboards, no write access | Data/Workload | Enterprise |

If a group provides access at multiple levels (a JIT bundle), classify it at the highest level present.

## Difference from directory roles

Directory roles have stable Microsoft-published GUIDs and known permissions. Groups are tenant-specific: you define what a group gates by assigning it to roles, resources, or applications. This means:

- The `groups[]` array always contains your tenant's own group object IDs (no universal GUIDs).
- You must determine the correct file for each group by examining what the group is assigned to.
- When a group's assignments change (e.g., it gains a new role assignment), its classification may need to change too.

## Role-assignable groups

Groups with `isAssignableToRole: true` can be assigned Microsoft Entra directory roles and receive enhanced protections (only Global Administrator, Privileged Role Administrator, or the group Owner can manage them). Any group assigned to an Entra directory role must be role-assignable. Classify such groups at the same plane and security level as the role they are assigned to.

## PIM for Groups: member vs. owner policies

Each group in PIM has two independent activation policies: one for **member** and one for **owner**. Owners can manage the group itself; members receive the access the group grants. The `expectedConfig` in each file specifies both independently.

In most cases, the owner policy should be at least as strict as the member policy, since a compromised owner can manipulate membership.

## Supported `expectedConfig` fields

All files support the same fields for both `member` and `owner`:

| Field | Type | Description |
|---|---|---|
| `requireMFA` | bool | Require MFA on activation |
| `requireApproval` | bool | Require approval for activation |
| `requireJustification` | bool | Require justification text |
| `maxActivationDuration` | ISO 8601 | Maximum duration of a single activation (e.g. `PT4H`) |
| `allowPermanentEligible` | bool | Whether permanent eligible assignments are allowed |
| `allowPermanentActive` | bool | Whether permanent active assignments are allowed |
| `maxEligibleDuration` | ISO 8601 | Maximum duration of an eligible assignment |
| `maxActiveDuration` | ISO 8601 | Maximum duration of an active assignment |

## Excluding groups from the coverage check

To exclude a group from the unclassified alert, create `AccessModel/pim-groups/coverage-exclusions.json`:

```json
{
  "excludedGroupIds": [
    {
      "id": "YOUR-GROUP-ID",
      "displayName": "Temp-Test-Group",
      "reason": "Temporary test group; not under access-model management."
    }
  ]
}
```

## Related documentation

- [Access Model - Directory Roles](../README.md) — the same Plane/SecurityLevel structure for Entra directory roles
- [PIM for Groups concept - Microsoft Learn](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/concept-pim-for-groups)
- [Enterprise Access Model - Microsoft Learn](https://learn.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model)
- [EntraOps - Thomas Naunheim](https://github.com/Cloud-Architekt/EntraOps) — community EAM classification tool that applies the same Clean Source principle to groups
