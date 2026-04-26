---
sidebar_position: 3
---

# Severity Rules

PIM Monitor classifies changes as **High**, **Medium**, or **Low**. This page explains the rules and how to customize them.

## Policy rule severity

Policy changes are matched by **rule ID prefix**. The first matching prefix determines severity.

| Rule ID prefix | Severity | What it means |
|---|---|---|
| `Enablement_EndUser_Assignment` | **High** | MFA, justification, or ticketing on role activation |
| `Approval_EndUser_Assignment` | **High** | Approval requirement and approver list |
| `AuthenticationContext_EndUser_Assignment` | **High** | Conditional Access authentication context |
| `Expiration_EndUser_Assignment` | **Medium** | Max duration for activated roles |
| `Expiration_Admin_Eligibility` | **Medium** | Max duration for eligible assignments |
| `Expiration_Admin_Assignment` | **Medium** | Max duration for permanent/active assignments |
| `Enablement_Admin_Assignment` | **Medium** | MFA/justification on direct assignment |
| `Enablement_Admin_Eligibility` | **Medium** | Requirements for creating eligible assignments |
| `Notification_*` | **Low** | All 9 notification rule types |

Prefix matching: `Notification_Admin_Admin_Eligibility` matches `Notification_` and is classified as Low.

Unknown rules (no matching prefix) default to **Medium**.

## Assignment severity

| Type | Change | Duration | Severity |
|---|---|---|---|
| Permanent | New | None | **High** |
| Permanent | Removed | - | **Low** |
| Eligible | New | With expiration | **Medium** |
| Eligible | New | No expiration | **High** |
| Eligible | Removed | - | **Low** |
| Eligible | Modified | - | **Medium** |
| Active | New | With expiration | **Medium** |
| Active | New | No expiration | **High** |
| Active | Removed | - | **Low** |
| Active | Modified | - | **Medium** |

## Definition severity

| Change | Severity |
|---|---|
| `rolePermissions` modified | **High** - what the role can do changed |
| `displayName` or `description` modified | **Low** - metadata only |

## Examples

**MFA requirement added**
Rule: `Enablement_EndUser_Assignment` (MFA enabled on role activation)
Severity: **High** - users can no longer activate without MFA

**Expiration shortened**
Rule: `Expiration_EndUser_Assignment` (8h to 4h)
Severity: **Medium** - existing workflows still valid, just shorter

**New permanent admin**
Assignment: permanent role created, no expiration
Severity: **High** - user has standing access with no time limit

**Notification rule changed**
Rule: `Notification_Admin_Admin_Eligibility` (email recipients updated)
Severity: **Low** - no effect on user access

## Tips

- **High** - act on these immediately
- **Medium** - audit and review, may need policy adjustments
- **Low** - track for compliance, lower priority

The notification threshold is configured separately (see [Notifications](./notifications.md#severity-threshold)). You can send Medium+ to Teams while only showing High in dashboards.

To change which rule IDs map to which severity, or adjust assignment severity, see [Customize: Severity Rules](../customize/severity-rules.md).

## Next

[Reducing Alert Fatigue](./alert-fatigue.md) - tuning thresholds and suppressing planned changes.
