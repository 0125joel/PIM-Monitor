# 12 — Versioning & Releases

## Overview

PIM Monitor uses [Conventional Commits](https://www.conventionalcommits.org/) with automated releases via [Release Please](https://github.com/googleapis/release-please). This ensures consistent version bumping and release notes based on commit messages.

## Commit Message Format

All commits should use the format:

```
<type>: <description>
```

### Commit Types

| Type | Meaning | Version Bump | Example |
|---|---|---|---|
| `fix:` | Bug fix | Patch (0.1.0 → 0.1.1) | `fix: handle null assignments in diff` |
| `feat:` | New feature | Minor (0.1.0 → 0.2.0) | `feat: add activation event detection` |
| `feat!:` | Breaking change | Major (0.1.0 → 1.0.0) | `feat!: change inventory JSON schema` |
| `docs:` | Documentation | No release | `docs: update webhook guide` |
| `chore:` | Maintenance | No release | `chore: update dependencies` |
| `test:` | Tests | No release | `test: add diff engine tests` |
| `refactor:` | Code refactoring | No release | `refactor: simplify git operations` |

### What Triggers a Release

A release is triggered **only** when a `feat:` or `fix:` commit touches:
- `src/**` (PowerShell scripts)
- `monitor-pipeline.yml` (Azure DevOps pipeline)
- `scan.yml` (GitHub Actions workflow)

Changes to documentation, inventory files, README, or `.github/` configuration do **not** trigger releases.

## Release Process

### 1. Commit & Push

Push a `feat:` or `fix:` commit touching core files:

```bash
git add src/
git commit -m "feat: add new notification channel"
git push origin main
```

### 2. Release Please Opens a PR

Release Please GitHub Action automatically opens a Release PR that:
- Bumps the `VERSION` file (patch, minor, or major)
- Generates/updates `CHANGELOG.md` with release notes
- Lists all commits since the last release

### 3. Review & Merge

Review the Release PR to ensure:
- Version bump is correct
- CHANGELOG.md looks good
- No unwanted commits are included

Then merge the PR.

### 4. GitHub Release Created

When the Release PR is merged, Release Please automatically creates a GitHub Release with:
- Semantic version tag (e.g., `v0.2.0`)
- Release notes from CHANGELOG.md
- Link to the release page

## VERSION File

The `VERSION` file contains the current version and serves as the single source of truth:

```
0.1.0 # x-release-please-version
```

The comment marker `# x-release-please-version` tells Release Please where to update the version number.

The pipeline reads this file to know what version the user is running, and compares it against the latest GitHub Release to detect updates.

## User Update Notifications

When a user deploys PIM Monitor (either Azure DevOps or GitHub Actions), the pipeline:

1. Reads their `VERSION` file (current running version)
2. Calls GitHub API to fetch the latest release
3. Compares versions using semantic versioning
4. If a newer version exists, sends a notification (email/webhook) with:
   - Current version
   - Latest available version
   - Release notes
   - Link to release page on GitHub

This means users are automatically notified of updates without needing to check GitHub manually.

## Best Practices

- **One thing per commit**: Each commit should represent a single logical change (bug fix or feature)
- **Clear messages**: Commit messages should be clear and descriptive
- **Squash if needed**: Before pushing, squash unrelated work-in-progress commits
- **Feature branches**: Work on feature branches, create PRs for review
- **No manual version bumps**: Let Release Please handle versioning automatically
