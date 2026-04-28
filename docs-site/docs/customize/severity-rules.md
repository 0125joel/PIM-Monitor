---
sidebar_position: 2
description: Configure severity rules for PIM Monitor. Customize how policy changes are classified as High, Medium, Low, or Informational based on rule IDs and assignment types.
---

# Severity rules

By default, severity is determined by rule ID prefix matching. You can change which rules map to which severity, adjust the fallback, and modify how assignments are classified.

## Change a policy rule's severity

Edit `src/diff.ps1` lines 22-40:

```powershell
$script:PolicyRuleSeverity = [ordered]@{
    "Enablement_EndUser_Assignment"              = "High"
    "Approval_EndUser_Assignment"                = "High"
    "AuthenticationContext_EndUser_Assignment"    = "High"

    # Add your own rule here:
    "MyCustomRule_"                              = "High"

    "Expiration_EndUser_Assignment"              = "Medium"
    "Expiration_Admin_Eligibility"               = "Medium"
    "Expiration_Admin_Assignment"                = "Medium"
    "Enablement_Admin_Assignment"                = "Medium"
    "Enablement_Admin_Eligibility"               = "Medium"

    "Notification_"                              = "Low"
}
```

No other code changes needed.

## Change the default for unknown rules

Edit `src/diff.ps1` line 40:

```powershell
$script:DefaultPolicyRuleSeverity = "Low"  # was "Medium"
```

## Change assignment severity

Edit the `Compare-Assignments` function in `src/diff.ps1` (lines 261-350):

```powershell
$severity = switch ($category) {
    "permanent" { "High" }
    "eligible"  { "Medium" }  # change to "High" to treat all eligible as High
    "active"    { "Medium" }
}
```

## Change definition property severity

Definition properties are classified via `$script:PropertySeverity` in `src/diff.ps1`. Each entry maps a property name (prefix-matched) to a severity. Properties not in the map fall back to `$script:DefaultPropertySeverity`.

```powershell
$script:PropertySeverity = [ordered]@{
    # High — security-critical
    "rolePermissions"        = "High"
    "isPrivileged"           = "High"
    "isEnabled"              = "High"
    "isAssignableToRole"     = "High"   # PIM groups
    "securityEnabled"        = "High"   # PIM groups
    "membershipRule"         = "High"   # PIM groups: dynamic membership
    "isAvailable"            = "High"   # auth contexts

    # Medium — worth reviewing
    "allowedPrincipalTypes"      = "Medium"
    "inheritsPermissionsFrom"    = "Medium"
    "assignmentMode"             = "Medium"
    "membershipRuleProcessingState" = "Medium"
    "visibility"                 = "Medium"
    "expirationDateTime"         = "Medium"
    "groupTypes"                 = "Medium"

    # Informational — metadata, no action required
    "displayName"            = "Informational"
    "description"            = "Informational"
    "version"                = "Informational"
    "richDescription"        = "Informational"
    "resourceScopes"         = "Informational"
    # ... see src/diff.ps1 for full list
}
```

To add a property, insert a line in the appropriate section. Prefix matching means `"onPremises" = "Informational"` covers `onPremisesSyncEnabled`, `onPremisesDomainName`, and all other `onPremises*` fields.

To change the fallback for properties not in the map:

```powershell
$script:DefaultPropertySeverity = "Low"  # was "Medium"
```

## Reference

For how the diff engine uses these rules internally, see [Reference: Diff Engine](../reference/diff-engine.md).
