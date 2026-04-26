---
sidebar_position: 1
---

# PIM Monitor

**Continuous monitoring of Microsoft Entra ID PIM state with a git-based audit trail.**

PIM Monitor is a scheduled Azure DevOps pipeline. It scans your Entra ID Privileged Identity Management configuration, detects changes, and commits inventory JSON files to git. Every change becomes a commit. Your audit trail is version history.

## How it works

Each scheduled run fetches the full PIM state from Microsoft Graph, compares it against JSON inventory files committed in the repository, classifies any differences as High, Medium, or Low severity, writes updated inventory files, commits the changes to git, and sends notifications if changes were detected. No database, no external state — the repository is the source of truth.

## Why git?

- **Audit trail** - every change is a commit with timestamp and diff
- **Version control** - `git log` shows who changed what and when
- **Rollback** - reset a commit to undo a scan result (useful for testing)
- **No backend** - inventory lives in the repo, no database needed

## Key concepts

### Inventory structure

```
inventory/
├── directory-roles/{slug}/
│   ├── definition.json       # role properties
│   ├── policy.json           # activation/approval/notification rules
│   └── assignments.json      # permanent/eligible/active members
├── pim-groups/{slug}/
│   ├── definition.json
│   ├── policy.json           # { member: {...}, owner: {...} }
│   └── assignments.json
├── authentication-contexts/{slug}/
│   └── definition.json       # lookup for conditional access auth contexts
└── administrative-units/{slug}/
    └── definition.json       # lookup for AU scope resolution
```

Each entity gets its own folder so git diffs show exactly which role or group changed.

### Severity classification

Changes are classified by **rule ID prefix matching**, not property inspection:

| Rule | Severity |
|---|---|
| `Enablement_EndUser_Assignment` | **High** - MFA/justification on activation |
| `Approval_EndUser_Assignment` | **High** - Approval requirement |
| `AuthenticationContext_EndUser_Assignment` | **High** - Conditional Access auth context |
| `Expiration_*` | **Medium** - Duration limits |
| `Enablement_Admin_*` | **Medium** - Direct assignment MFA |
| `Notification_*` | **Low** - Notifications |
| Permanent assignment (no expiration) | **High** - Direct permanent role grant |
| New eligible/active with expiration | **Medium** - Scheduled assignments |

Add new rules by editing `src/diff.ps1`. No code changes needed beyond that.

### Notifications (optional)

When changes are detected:
- **Email** - via Graph `sendMail` (requires `Mail.Send` permission)
- **Webhook** - format is auto-detected from the URL:
  - `webhook.office.com` → Teams Adaptive Card
  - `hooks.slack.com` → Slack blocks
  - `discord.com/api/webhooks` → Discord embed
  - Other → generic JSON

Enable by setting environment variables in your Azure DevOps pipeline.

## Next steps

- [Prerequisites](./getting-started/prerequisites.md) - what you need before deploying
- [Local Testing](./getting-started/local-testing.md) - run a scan locally before deploying
- [Deployment](./getting-started/installation.md) - deploy on Azure DevOps or GitHub Actions
