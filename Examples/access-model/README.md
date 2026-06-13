# Access Model Examples

Starter files mapping all 144 built-in Entra ID directory roles against the Microsoft Enterprise Access Model (EAM). Drop the folders into an `AccessModel/` directory in your repository root and edit the role lists to match your tenant.

## Structure

Files are organized by two independent EAM dimensions:

```
AccessModel/
├── ControlPlane/
│   ├── Privileged.json     (29 roles)
│   ├── Specialized.json    (9 roles)
│   └── Enterprise.json     (27 roles)
├── ManagementPlane/
│   ├── Privileged.json     (14 roles - blast-radius escape clause)
│   └── Specialized.json    (45 roles)
└── DataWorkloadPlane/
    ├── Privileged.json     (1 role  - AI Reader, isPrivileged = true)
    └── Enterprise.json     (19 roles)
```

## The two dimensions

| Dimension | Values | What it means |
|---|---|---|
| **Plane** | Control, Management, Data/Workload | Where the resource lives in the stack |
| **Security Level** | Privileged, Specialized, Enterprise | How much protection the role requires |

These are independent: a Management Plane role can be Privileged (Exchange Admin) or Specialized (License Admin), depending on its blast radius.

Since PIM covers only the Privileged access path, the User Access and App Access pathways are not represented here. All roles in PIM are on the Privileged access path by definition.

## Classification logic

Classification follows the single source of truth in [`docs/eam-pim-classification.md`](../../docs/eam-pim-classification.md):

**Security Level is determined by three rules in order:**

1. **MS Privileged flag** - If `roleDefinition.isPrivileged = true` in Microsoft Graph: Privileged. This is the only authoritative per-role value Microsoft publishes.

2. **Blast-radius escape clause** - Full service control over a Microsoft 365 workload with direct data impact (all mailboxes, all sites, all source code, etc.) warrants Privileged regardless of the isPrivileged flag. Applies to: Exchange, SharePoint, Teams, Yammer, Power Platform, Dynamics 365, Fabric, Azure DevOps, Windows 365, Knowledge. This is a deliberate hardening: Microsoft's security-levels doc would place these workload admins at Specialized, so PIM Monitor is stricter than the Microsoft baseline here on purpose.

3. **Plane mapping** - Management plane: Specialized. Control plane non-reader/non-governance: Specialized. Control plane reader/governance/default: Enterprise. Data plane: Enterprise.

**Plane** is derived from role name and description against EAM definitions. Microsoft does not publish an official per-role EAM plane mapping; the assignments here are heuristic and always reviewable.

## EAM planes

| Plane | What lives here | Example roles |
|---|---|---|
| **Control** | Identity, authentication, and authorization infrastructure | Global Administrator, Conditional Access Administrator, Helpdesk Administrator |
| **Management** | Workload, device, and service configuration | Exchange Administrator, Intune Administrator, Compliance Administrator |
| **Data/Workload** | End-user data and business processes | Reports Reader, Message Center Reader, Search Editor |

## Security levels and PIM defaults

| Security Level | `expectedConfig` defaults | Rationale |
|---|---|---|
| **Privileged** | 1h activation, MFA + Approval + Justification, no permanent assignments | Identity infrastructure or full-service workload control; breach = major incident |
| **Specialized** | 4h activation, MFA + Approval + Justification, no permanent active | Elevated business impact; breach = significant but bounded |
| **Enterprise** | 8h activation, MFA + Justification, no approval | Audit trail via PIM; approval overhead not warranted for low blast radius |

The scanner derives the notification severity from the security level: Privileged = High, Specialized = Medium, Enterprise = Low. These files carry `securityLevel`, not a literal `severity` field.

## Legacy tier mapping

| Legacy term | EAM equivalent |
|---|---|
| Tier 0 | Control Plane / Privileged |
| Tier 1 (identity admin) | Control Plane / Specialized |
| Tier 1 (workload admin) | Management Plane / Privileged or Specialized |
| Tier 2 | Data/Workload Plane / Enterprise |

## Customizing

- The `roles[]` array uses Microsoft's well-known directory role template IDs. Add or remove roles; `displayName` is informational and not used for matching.
- Tighten or loosen `expectedConfig` per your organization's maturity.
- The complete `expectedConfig` field reference is in [`docs-site/docs/access-model/setup-compliance.mdx`](../../docs-site/docs/access-model/setup-compliance.mdx).
- The authoritative classification reference for all 144 built-in roles is the single source of truth [`docs/eam-pim-classification.md`](../../docs/eam-pim-classification.md) (the rules) plus the generated catalog `docs-site/src/data/eam-role-catalog.json` (per-role). The older `docs/PIM-EAM-Mapping-v2.xlsx` is legacy and may be stale.

## PIM Groups

See [`pim-groups/`](pim-groups/) for access model examples covering PIM-enabled Entra groups.
