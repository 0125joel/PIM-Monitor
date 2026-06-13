---
sidebar_position: 10
description: Reduce PIM Monitor notification volume by raising the minimum severity, suppressing expected changes, and excluding low-risk roles.
---

# Reducing Alert Fatigue

PIM Monitor is designed to catch every change. Without tuning, it may notify on changes you do not care about, which trains you to ignore notifications, including the ones that matter.

This page explains the three controls available and when to use each.

---

## Control 1: Minimum Severity Threshold

The `NOTIFICATION_MIN_SEVERITY` pipeline variable controls which severity levels trigger a notification.

| Value | What is notified |
|---|---|
| `High` | Only high-severity changes (MFA disabled, permanent assignment created, etc.) |
| `Medium` | High + Medium (default) |
| `Low` | High + Medium + Low |
| `Informational` | Everything, including new API fields and activation events |

**Default:** `Medium`

Set this in the Azure DevOps pipeline variable panel or GitHub Actions variables. Changes take effect on the next scan.

> [!TIP]
> Start with the default (`Medium`) and only lower the threshold if you regularly miss changes you want to know about. Raising it to `High`-only is a useful starting point for high-noise environments.

All changes are still committed to the inventory regardless of the threshold. The threshold only controls what is included in email and webhook notifications.

---

## Control 2: Expected Change Suppression

For planned maintenance (policy updates, assignment changes during an access review, onboarding a new role), register the change in advance so PIM Monitor skips the notification for that specific event.

Create `expected-changes.json` in the repository root before making the Entra change:

```json
{
  "expected": [
    {
      "workload":   "directory-roles",
      "entity":     "global-administrator",
      "fileType":   "policy",
      "ruleId":     "Expiration_EndUser_Assignment",
      "reason":     "Activation duration extended per SEC-1234",
      "expiresUtc": "2026-05-01T17:00:00Z"
    }
  ]
}
```

The file is cleaned up automatically after each scan: consumed entries are removed, expired entries are removed, and the file is deleted when empty.

For the full field reference, matching examples, and workflow, see [Expected Change Suppression](./expected-changes.md).

---

## Control 3: Notification Channel

Sometimes the problem is not the number of alerts but how they are delivered. A full inbox of individual emails for every scan may feel like noise even when the individual changes are worth knowing about.

Options:

**Raise the minimum severity** (Control 1) so only High + Medium changes generate email, and rely on the pipeline artifact for a full Low-inclusive report.

**Use a webhook to a shared channel** instead of email. A Teams or Slack channel dedicated to security notifications is easier to batch-review than an individual mailbox. Colleagues can also see and react to alerts.

**Use both channels for different thresholds.** PIM Monitor sends to all configured channels with the same threshold. If you need email for High-only and Slack for everything, the current version does not support different thresholds per channel. Set the threshold to the level you need for email and rely on the Slack channel for the broader view.

**Enable the HTML report artifact** (`REPORT_ARTIFACT=true`) for a structured digest view of each scan run without sending individual notifications.

---

## Control 4: Coverage Exclusions

If the access model is enabled, unclassified roles appear in a dedicated Classification section on every scan notification until each role is assigned to a model file or explicitly excluded. A single scan can surface tens of roles at once, especially on first setup when no access-model files exist yet.

Two ways to silence a specific role without classifying it:

**Permanent exclusion**: add to `AccessModel/coverage-exclusions.json`:

```json
{
  "excludedRoleIds": [
    {
      "id": "fe930be7-5e62-47db-91af-98c3a49a38b1",
      "displayName": "User Administrator",
      "reason": "Intentionally outside access-model management."
    }
  ]
}
```

`displayName` and `reason` are informational. Matching is by `id` only.

**Temporary suppression**: add to `expected-changes.json` with a deadline:

```json
{
  "expected": [
    {
      "workload":   "directory-roles",
      "entity":     "user-administrator",
      "fileType":   "access-model-coverage",
      "reason":     "Under access review, will be classified by Q3",
      "expiresUtc": "2026-09-01T00:00:00Z"
    }
  ]
}
```

PIM Monitor removes expired entries automatically after each scan.

> [!TIP]
> Use `coverage-exclusions.json` for roles that are permanently outside your access model. Use `expected-changes.json` when you expect to classify the role by a specific date.

See [Access Model: Coverage and Exclusions](../access-model/coverage-exclusions.md) for full setup.

---

## Summary

| Problem | Solution |
|---|---|
| Too many notifications for minor changes | Raise `NOTIFICATION_MIN_SEVERITY` to `High` or `Medium` |
| Notification fired for a planned change | Add an entry to `expected-changes.json` before making the change |
| Individual emails are hard to track | Switch to a webhook → Teams or Slack channel |
| Want a digest without per-scan notifications | Enable `REPORT_ARTIFACT=true`; review the HTML artifact |
| Same unclassified roles appear every scan | Add to `AccessModel/coverage-exclusions.json` (permanent) or `expected-changes.json` with `expiresUtc` (temporary) |
