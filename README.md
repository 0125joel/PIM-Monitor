# PIM Monitor

Continuous monitoring of Microsoft Entra ID Privileged Identity Management (PIM) with a git-based audit trail. Run it as a scheduled Azure DevOps pipeline (or GitHub Actions) and get full change history committed to your repo.

Every scan detects what changed in your PIM policies, assignments, and groups. Every change becomes a commit. Your audit trail is version history.

## What it does

- Scans your Entra ID for all PIM configuration changes
- Detects new/modified/deleted roles, groups, policies, assignments
- Classifies changes by severity (High, Medium, Low, Informational)
- Stores inventory as JSON files in git (one commit per scan)
- Sends notifications via email or webhooks (Teams, Slack, Discord)

## Why use it

**Complete audit trail.** Every change is a commit with timestamp and diff. No logs to archive, no retention limits. Just git history.

**No database.** Inventory lives in your repo. No backend to manage, no API to call. Git is your state store.

**Fast deployment.** Works with Azure DevOps or GitHub Actions. Minimal setup, WIF for keyless auth.

## Quick start

### Option 1: Azure DevOps Pipeline

```bash
# 1. Clone this repo
git clone https://github.com/joel-prins/PIM-Monitor.git

# 2. Set up an Entra ID app registration + WIF service connection
# See: docs-site/docs/getting-started/installation.md

# 3. Create the pipeline in Azure DevOps
# Point it to monitor-pipeline.yml

# 4. Add pipeline variables for notifications (optional)
# NOTIFICATION_EMAIL=admin@contoso.com
# NOTIFICATION_WEBHOOK_URL=https://...
```

### Option 2: GitHub Actions

```bash
# Same setup, but use .github/workflows/scan.yml
# See: docs-site/docs/getting-started/installation-github.md
```

### What happens after

On each scan:
1. Scripts fetch current PIM state from Graph API
2. Compare against inventory files in the repo
3. Detect and classify changes
4. Write updated inventory (deterministic JSON)
5. Commit and push to repo
6. Send notifications (if configured)

That's it. You have an audit trail in git.

## Documentation

Start here depending on what you need:

- **Getting started**: [Prerequisites](./docs-site/docs/getting-started/prerequisites.md) (includes troubleshooting), [Installation for Azure DevOps](./docs-site/docs/getting-started/installation.md), [Installation for GitHub Actions](./docs-site/docs/getting-started/installation-github.md), [Local testing](./docs-site/docs/getting-started/local-testing.md), [FAQ](./docs-site/docs/getting-started/faq.md)
- **Configuration**: [Pipeline YAML](./docs-site/docs/configuration/pipeline-yaml.md), [Notifications](./docs-site/docs/configuration/notifications.md), [Severity rules](./docs-site/docs/configuration/severity-rules.md)
- **Reference**: [Inventory structure](./docs-site/docs/reference/inventory-structure.md), [Graph API endpoints](./docs-site/docs/reference/graph-endpoints.md), [Diff engine](./docs-site/docs/reference/diff-engine.md), [Activation events](./docs-site/docs/reference/activation-events.md)
- **Customization**: [Expected changes](./docs-site/docs/customize/expected-changes.md), [Severity rules](./docs-site/docs/customize/severity-rules.md), [Notifications](./docs-site/docs/customize/notifications.md), [Diff engine](./docs-site/docs/customize/diff-engine.md)

Or read the full architecture: [Architecture & Planning](./docs/architecture.md)

Stuck during setup? Check the [Troubleshooting section in Prerequisites](./docs-site/docs/getting-started/prerequisites.md#troubleshooting) or the [FAQ](./docs-site/docs/getting-started/faq.md).

## Architecture overview

```
Azure DevOps Pipeline (scheduled every 15-30 min)
  ├── Fetch current PIM state from Graph API
  ├── Compare against inventory/ files (previous state)
  ├── Detect and classify changes by severity
  ├── Write updated inventory files (deterministic JSON)
  ├── Commit and push to repo
  └── Send notifications (email, webhook)

Git repo = audit trail. Every commit is one scan result.
```

## Features

Phase 1: Core scanning and notifications
- Parallel role fetching (4-5x faster)
- Directory Roles and PIM Groups monitoring
- Severity classification (High, Medium, Low, Informational)
- Email notifications (Graph sendMail)
- Webhook notifications (Teams Adaptive Card, Slack blocks, Discord embeds)
- Diff links in notifications (jump to exact change in git)

Phase 2: Change detection and management
- Expiring assignment detection (flag assignments expiring within N days)
- Expected change suppression (pre-register changes, auto-cleaned after scan)
- Activation event archive (monthly audit logs from Graph)

Phase 3: Future
- Security alert monitoring
- Digest mode (weekly summary emails)

## Requirements

- **Entra ID** tenant with PIM enabled
- **Azure DevOps** (ADO) or **GitHub** repository
- **App Registration** in Entra ID (for Graph API access)
- **Workload Identity Federation** (WIF) for keyless auth
- PowerShell 7+ (built into ADO ubuntu-latest agents)

No secrets stored in pipeline variables. No client secrets to rotate.

## Contributing

We welcome contributions. See [Contributing](./docs-site/docs/contributing.md) for how to get started.

Ways to help:
- Report bugs or request features via GitHub Issues
- Add documentation or improve clarity
- Contribute new notification channels
- Improve performance or reliability

## License

MIT. See [LICENSE](./LICENSE) for details.

## Questions or feedback

Open an issue on [GitHub](https://github.com/joel-prins/PIM-Monitor/issues) or reach out on [LinkedIn](https://www.linkedin.com/in/jo%C3%ABl-prins-4b4655aa/).

---

**PIM Monitor** keeps your Entra ID governance in check. One scan at a time. 📋
