# Access Model Examples

Starter files mapping all 145 built-in Entra ID directory roles against the Microsoft Enterprise Access Model (EAM). Drop the folders into an `AccessModel/` directory in your repository root and edit the role lists to match your tenant.

## Structure

Files are organized by two independent EAM dimensions:

```
AccessModel/
├── ControlPlane/
│   ├── Privileged.json     (30 roles)
│   ├── Specialized.json    (17 roles)
│   └── Enterprise.json     (16 roles)
├── ManagementPlane/
│   ├── Privileged.json     (14 roles - blast-radius escalation)
│   ├── Specialized.json    (47 roles)
│   └── Enterprise.json     (1 role)
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

The permissions of a role decide its plane and its level, not its name. The full method is on the [EAM Role Catalog](../../docs-site/docs/access-model/eam-role-catalog.mdx) page; in short:

**Plane** follows from the role's `allowedResourceActions`. Identity and security actions outrank workload actions: a role that touches authentication, authorization or the security posture is Control, even when it also touches a workload. Read-only does not lower the plane; it lowers the level.

**Security Level** follows a waterfall:

1. **isPrivileged floor** - If `roleDefinition.isPrivileged = true` in Microsoft Graph: Privileged. This is the only authoritative per-role value Microsoft publishes, and nothing can lower it.
2. **Blast-radius escalation** - Permissions that grant full data-plane control over an entire workload (all mailboxes, all sites, all source code) warrant Privileged even when Microsoft does not flag the role. This is a deliberate hardening: Microsoft's security-levels doc would place these workload admins at Specialized, so PIM Monitor is stricter than the Microsoft baseline here on purpose.
3. **Otherwise the permissions decide** - Actions that administer a bounded service or change identity, security or access configuration: Specialized. Read-only, end-user, default or low-impact support actions: Enterprise.

The per-role result is `docs-site/src/data/eam-role-catalog.json`, the single source. Microsoft publishes no per-role EAM plane, so the assignments are reviewed judgement and each role carries a note where the call is contentious.

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
- The authoritative classification for all 145 built-in roles is the hand-maintained catalog `docs-site/src/data/eam-role-catalog.json`. The role lists in these starter files are generated from it by `docs-site/scripts/Build-EamCatalog.ps1`, and `tests/EamCatalog.Tests.ps1` fails when they disagree. To change a classification, edit the catalog and run the script. Do not edit the generated role lists by hand.
- The same catalog is published for other tools as `https://pimmonitor.com/catalog/v1/eam-catalog.json`, described by [`schemas/eam-catalog-v1.json`](../../schemas/eam-catalog-v1.json).

## PIM Groups

See [`pim-groups/`](pim-groups/) for access model examples covering PIM-enabled Entra groups.
