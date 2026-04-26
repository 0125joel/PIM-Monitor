---
sidebar_position: 2
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

## Change definition severity

Edit the definition comparison block in `src/diff.ps1`:

```powershell
if (-not (Test-ObjectEqual -Left $oldData.rolePermissions -Right $newDataForFile.rolePermissions)) {
    $severity = "High"
} else {
    $severity = "Low"  # change to "Medium" if you want metadata changes to stand out
}
```

## Reference

See [Severity rules](../configuration/severity-rules) in Configuration for the full default table and examples.
