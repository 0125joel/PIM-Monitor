---
sidebar_position: 1
sidebar_label: Overview
description: Complete customization guide for PIM Monitor. Configure schedules, notifications, severity rules, environment variables, reporting, and advanced diff engine behavior.
---

# Customize PIM Monitor

PIM Monitor is designed to be customized. The defaults work out of the box, but nearly every behavior can be changed by editing configuration files or environment variables.

This section covers everything you can customize, from schedules and notification channels to severity rules and diff logic.

## Complete Customization Guide

### Pipeline & Scheduling

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **Schedule** | `monitor-pipeline.yml` / `.github/workflows/scan.yml` | How often scans run (cron pattern) | [Pipeline Configuration](./pipeline) |
| **Upstream update check** | `NOTIFY_UPSTREAM_UPDATE` | Notify when a newer release is published upstream | [Pipeline Configuration](./pipeline) |
| **Manual triggers** | YAML | Allow on-demand scans via UI | [Pipeline Configuration](./pipeline) |
| **Commit message** | YAML git step | Format of git commits | [Pipeline Configuration](./pipeline) |
| **Git author** | `src/git.ps1` | Commit author name/email | [Pipeline Configuration](./pipeline) |
| **Inventory path** | `src/Scan-PimState.ps1` | Where scan data is stored | [Pipeline Configuration](./pipeline) |


### Notifications

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **Email setup** | `NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM` | Enable email notifications | [Email Notifications](./email-notifications) |
| **Email format** | `src/notifications-email.ps1` | HTML layout, colors, sections | [Email Notifications](./email-notifications) |
| **Webhook URL** | `NOTIFICATION_WEBHOOK_URL` | Add Teams, Slack, Discord, or custom webhooks | [Webhook Channels](./webhook-channels) |
| **Webhook payload** | `src/notifications-webhook.ps1` | Customize Teams/Slack/Discord format | [Webhook Channels](./webhook-channels) |
| **Severity threshold** | `NOTIFICATION_MIN_SEVERITY` | Which changes trigger notifications | [Notifications Overview](./notifications) |
| **Error notifications** | New feature | Send notifications when components fail | [Scan Error Notifications](./scan-errors) |

### Reporting & Artifacts

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **HTML report** | `REPORT_ARTIFACT` | Enable/disable scan report generation | [Reporting & Artifacts](./reporting) |
| **Report format** | `src/notifications-html.ps1` | HTML layout, colors, metadata | [Reporting & Artifacts](./reporting) |
| **Report branding** | `Build-HtmlReport` | Custom title, logo, colors | [Reporting & Artifacts](./reporting) |

### Change Classification & Detection

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **Policy severity** | `src/diff.ps1` `$PolicyRuleSeverity` | Which policy rules are High/Medium/Low | [Severity Rules](./severity-rules) |
| **Property severity** | `src/diff.ps1` `$PropertySeverity` | Which definition properties are High/Medium/Low | [Severity Rules](./severity-rules) |
| **Assignment severity** | `src/diff.ps1` `Compare-Assignments` | How permanent/eligible/active assignments are classified | [Severity Rules](./severity-rules) |
| **Filtered fields** | `src/diff.ps1` `$DiffIgnoreProperties` | Hide fields from diff preview | [Diff Engine](./diff-engine) |
| **Object equality** | `src/diff.ps1` `Test-ObjectEqual` | How old/new objects are compared | [Diff Engine](./diff-engine) |
| **Assignment matching** | `src/diff.ps1` `Get-AssignmentKey` | How assignments are matched across scans | [Diff Engine](./diff-engine) |
| **Access-model classification** | `AccessModel/*.json` | Classify roles by severity and EAM plane, enforce desired policy config | [Access Model](../access-model/overview.mdx) |
| **Coverage exclusions** | `AccessModel/coverage-exclusions.json` | Permanently exclude roles from unclassified-role alerts | [Access Model: Coverage](../access-model/coverage-exclusions.md) |

### Expected Changes & Suppression

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **Suppress changes** | `expected-changes.json` | Silence notifications for planned changes | [Expected Changes](./expected-changes) |
| **Matching rules** | JSON | Wildcard matching on workload/entity/fileType | [Expected Changes](./expected-changes) |

### Expiring Assignments

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **Detection window** | `EXPIRING_WINDOW_DAYS` | Days ahead to flag expiring assignments | [Expiring Assignments](./expiring-assignments) |
| **Severity level** | `src/diff.ps1` | Change expiring from Informational to Low/Medium | [Expiring Assignments](./expiring-assignments) |

### Environment & Platforms

| Topic | File/Variable | What you can change | Page |
|---|---|---|---|
| **All env variables** | Reference | Complete list of all configuration variables | [Environment Variables](./environment-variables) |
| **GitHub Actions** | `.github/workflows/scan.yml` | Full setup for GitHub Actions workflow | [GitHub Actions Setup](../getting-started/installation-github) |
| **Azure DevOps** | `monitor-pipeline.yml` | Full setup for Azure DevOps pipeline | [Pipeline Configuration](./pipeline) |

## Quick Navigation by Task

**"I want to..."**

- **...change how often scans run** → [Pipeline Configuration](./pipeline) - Schedule section
- **...send notifications to Slack/Teams** → [Webhook Channels](./webhook-channels)
- **...set up email notifications** → [Email Notifications](./email-notifications)
- **...suppress a known-good change** → [Expected Changes](./expected-changes)
- **...change what's High/Medium/Low severity** → [Severity Rules](./severity-rules)
- **...generate HTML reports** → [Reporting & Artifacts](./reporting)
- **...get warnings for expiring assignments** → [Expiring Assignments](./expiring-assignments)
- **...hide noise from diffs** → [Diff Engine](./diff-engine)
- **...set up on GitHub Actions** → [GitHub Actions Setup](../getting-started/installation-github)
- **...find all environment variables** → [Environment Variables](./environment-variables)
- **...handle component failures gracefully** → [Scan Error Notifications](./scan-errors)
- **...classify roles using the Enterprise Access Model** → [Access Model and Desired-State Compliance](../access-model/overview.mdx)
- **...stop getting alerts for a role that's intentionally unclassified** → [Access Model: Coverage and Exclusions](../access-model/coverage-exclusions.md)

## Customization Depth Levels

### Basic (variables only)

No code editing: just set environment variables in your pipeline:

- `NOTIFICATION_EMAIL` / `NOTIFICATION_MAIL_FROM`: Email setup
- `NOTIFICATION_WEBHOOK_URL`: Webhook setup
- `NOTIFICATION_MIN_SEVERITY`: Severity threshold
- `EXPIRING_WINDOW_DAYS`: Expiring assignment window
- `REPORT_ARTIFACT`: Enable HTML reports

**Time to customize**: 5 minutes  
**Risk**: None: variables are scoped to your pipeline

### Intermediate (YAML and JSON)

Edit pipeline configuration and expected changes:

- Change scan schedule (cron pattern in YAML)
- Change commit message format
- Create `expected-changes.json` to suppress notifications
- Create `AccessModel/*.json` to classify roles by EAM plane and enforce policy
- Create `AccessModel/coverage-exclusions.json` to opt out specific roles
- Change inventory storage path
- Enable manual triggers

**Time to customize**: 15 to 30 minutes  
**Risk**: Low: changes are in separate files, easy to revert

### Advanced (PowerShell code)

Edit notification payloads, severity rules, and diff logic:

- Customize email/webhook format
- Change severity classification rules
- Add custom notification channels
- Modify diff comparison logic
- Change diff output formatting

**Time to customize**: 1 to 2 hours  
**Risk**: Medium: requires PowerShell/JSON knowledge, test thoroughly

## Contributing

If you've built a useful customization, we'd love to see it! Open a PR and add a page here. Keep it concise:
- What it does (1 paragraph)
- What file to edit
- A code snippet showing the change
- Example output (if applicable)

See [Contributing](../contributing.md) for full details.
