---
sidebar_position: 6
---

# Contributing

PIM Monitor is open source under the MIT license. Contributions are welcome.

## Ways to contribute

### Add a customization page

The easiest way to contribute. If you have built a useful modification, add a page to the Customize section:

1. Fork the repo
2. Add a `.md` file in `docs-site/docs/customize/`
3. Add it to `docs-site/sidebars.ts` under `customizeSidebar`
4. Open a PR

Keep it short: what it does, what to edit, and a code snippet.

### Add a notification channel

PIM Monitor detects the webhook type from the URL. To add a new channel:

1. Add a payload builder in `src/notifications-webhook.ps1`:
   ```powershell
   function Build-MyChannelPayload {
       param($ChangesBySeverity)
       # return your payload hashtable
   }
   ```
2. Add URL detection in `Get-WebhookType` and a case in `Send-WebhookNotification`
3. Open a PR with a customization page documenting the new channel

### Improve the diff engine

The diff engine lives in `src/diff.ps1`. Useful contributions:
- Better assignment key handling for edge cases
- Support for new PIM entity types
- Performance improvements for large tenants

### Fix a bug

Check [open issues](https://github.com/0125joel/PIM-Monitor/issues) on GitHub. Issues labeled `good first issue` are a good starting point.

### Improve the docs

Docs live in `docs-site/docs/`. Fix typos, add examples, clarify steps. All PRs welcome.

## Commit message conventions

PIM Monitor uses [Conventional Commits](https://www.conventionalcommits.org/). The commit message determines whether a release is created and what version bump applies.

**Format:** `<type>: <description>`

| Type | Purpose | Version bump |
|---|---|---|
| `fix:` | Bug fixes | Patch (0.1.0 → 0.1.1) |
| `feat:` | New features | Minor (0.1.0 → 0.2.0) |
| `feat!:` or `BREAKING CHANGE:` | Breaking changes | Major (0.1.0 → 1.0.0) |
| `docs:`, `chore:`, `test:` | Non-release changes | No release |

**Examples:**
- `fix: handle null assignments in diff` → patch release
- `feat: add activation event detection` → minor release
- `feat!: change inventory JSON schema` → major release
- `docs: add webhook guide` → no release

A release PR is automatically opened when you push a `feat:` or `fix:` commit touching `src/`, `monitor-pipeline.yml`, or `scan.yml`. Documentation-only changes do not trigger releases.

## Before you open a PR

- Keep changes focused. One thing per PR.
- If you are adding a new feature, open an issue first to discuss scope.
- Test your changes locally before submitting.
- Use conventional commit messages so releases are created correctly.

## Local setup

```bash
git clone https://github.com/0125joel/PIM-Monitor.git
cd PIM-Monitor/docs-site
npm install
npm start
```

The docs site runs at `http://localhost:3000`.

## Questions

Open an issue on [GitHub](https://github.com/0125joel/PIM-Monitor/issues) or reach out via [LinkedIn](https://www.linkedin.com/in/jo%C3%ABl-prins-4b4655aa/).
