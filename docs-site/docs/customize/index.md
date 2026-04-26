---
sidebar_position: 1
sidebar_label: Overview
---

# Customize

PIM Monitor is designed to be modified. The defaults work out of the box, but most behavior can be changed by editing a handful of files.

This section covers everything you can customize, from severity rules to pipeline behavior and diff logic. Contributors are welcome to add new pages here for additional customizations.

## What you can change

| Area | File | What |
|---|---|---|
| [Expected Change Suppression](./expected-changes) | `expected-changes.json` | Suppress notifications for planned changes |
| [Severity rules](./severity-rules) | `src/diff.ps1` | Which changes are High, Medium, or Low |
| [Pipeline behavior](./pipeline) | `monitor-pipeline.yml` | Schedule, commit format, inventory path |
| [Diff engine](./diff-engine) | `src/diff.ps1` | Object equality, assignment keys, new entity handling |
| [Notifications](./notifications) | `monitor-pipeline.yml` + `src/notifications.ps1` | Thresholds, payload format, new channels |

## Contributing a customization

If you have built a useful modification, open a PR and add a page here. Keep it short: what it does, what to edit, and a code snippet. See [Contributing](../contributing.md) for the full workflow.
