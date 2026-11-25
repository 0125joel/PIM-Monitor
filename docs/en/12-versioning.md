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

Release Please checks conventional commits on public `main`. A `feat:` or `fix:` commit can lead to a release PR; a `docs:` commit alone does not.

The configuration lists `docs/**` and `inventory/**` as excluded paths. A mirror commit can also change its synchronization marker, so review the release PR rather than relying on paths alone.

## Release Process

### 1. Review the change

Review the change and its commit message before it reaches public `main`.

### 2. Release Please Opens a PR

When a release is needed, the Release Please GitHub Action opens or updates a release PR that:
- Bumps the `VERSION` file (patch, minor, or major)
- Generates/updates `CHANGELOG.md` with release notes
- Lists the relevant changes since the last release

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

## Catalog Versioning

The published EAM catalog (`/catalog/v1/eam-catalog.json`) has its own `schemaVersion`, separate from the app version:

- A breaking change to the catalog (a removed or renamed field, a changed meaning) is a `feat!:` commit and a new path, `/catalog/v2/`. v1 stays online until consumers have moved.
- Adding an optional field is a `feat:` commit and a minor bump of `schemaVersion`. A wording change is a patch.
- `catalogVersion` is the version of the content (a date). It changes when roles or policies change and does not touch `schemaVersion`.

`docs-site/src/constants.ts` carries the same `x-release-please-version` marker as `VERSION`, so the app version shown on the front page is updated by Release Please too.

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
