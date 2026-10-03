# Handoff: publish the PIM Monitor catalog for PIM Manager

**For:** an agent working in the `0125joel/PIM-Monitor` repository.
**From:** the PIM Manager Configure phase (NextGen phase 4), 2026-10-03.
**Background (Dutch):** `docs/Assets/next-gen/configure/2026-10-nextgen-configure-redesign.md` in the PIM Manager repository (`0125joel/PIM-manager-private`, branch `NextGen` or `claude/app-review-improvements-nxaxdz`), sections 3c and 3.6. This file is kept in both repositories; the copy in PIM Monitor is the one to work from.
**Status:** not started. Nothing in PIM Monitor has been changed.

## 1. Goal

PIM Monitor becomes the single source of truth for the EAM role catalog and the access-model templates. PIM Manager (a fully client-side SPA, no backend) downloads that catalog after the user signs in and offers it as a template in its Configure page: the admin picks a plane and security level, adjusts the proposed settings and applies them to the tenant. When Microsoft adds a role and it is added to the PIM Monitor catalog, PIM Manager picks it up on the next sign-in without a PIM Manager release.

What PIM Manager needs from PIM Monitor:

1. One published, versioned JSON file at a stable URL on `pimmonitor.com`.
2. A JSON Schema for that file, so both repos can test against the same contract.
3. One vocabulary: the same field names in the catalog and in the `AccessModel/` files.

PIM Manager sends nothing to PIM Monitor. It reads one public file. Tenant data never leaves the browser.

## 2. What was found in the repo (commit `e6222c0`, 2026-10-03)

Fix or decide these first; they block a clean contract.

| # | Finding | Where |
|---|---|---|
| F1 | Two shapes for the same policy. The catalog uses `recommendedConfig` with `maxActivation`, `requireMfa`, `authContext` (free text such as `"Phishing-resistant"`, `"Phishing-resistant + sign-in frequency"`, `"Standard MFA"`), plus `pimRequired`, `severity` and `maxActivationLabel`. The access-model files use `expectedConfig` with `maxActivationDuration`, `requireMFA`, `authContext` as a slug (`phish-resistant-sif`), `requireJustification`, `requireApproval`, `allowPermanentEligible`, `allowPermanentActive`. | `docs-site/src/data/eam-role-catalog.json`, `Examples/access-model/**`, field reference in `docs-site/docs/access-model/setup-compliance.mdx` |
| F2 | Two files claim to be the source. `eam-role-catalog.json` says it is hand-maintained and the generator is retired; `Generate-EamRoleCatalog.ps1` says it is the single source of truth and that the catalog is generated from `eam-role-curated.json`. | `docs-site/src/data/eam-role-catalog.json` (`_comment`), `docs-site/scripts/Generate-EamRoleCatalog.ps1` |
| F3 | The catalog and the curated file disagree on 15 roles (plane or security level). Examples: People Administrator is Management/Specialized in the catalog and Control/Enterprise in the curated file; Device Managers is Management/Specialized against Data/Enterprise; User Experience Success Manager is Data/Enterprise against Control/Enterprise. The catalog has 145 roles, the curated file 144. | same two files |
| F4 | `authContext` is resolved by slug of the tenant's authentication context display name (`Get-InventorySlug`: lowercase, keep `a-z0-9`, whitespace and hyphens, collapse). In Joël's tenant this works: the contexts are named "Phish-resistant & SIF", "Phish-resistant & No SIF", "Phish-resistant & Compliant device" and "Phish-resistant & Compliant device & SIF", which slug to exactly the four seed labels (checked 2026-10-03). A tenant that names its contexts differently (for example "Auth Context - Phish-resistant & SIF", which slugs to `auth-context-phish-resistant-sif`) gets the compliance check skipped with only a warning in the log (`Resolve-AuthContextConfig`). | `src/compliance.ps1` (`Resolve-AuthContextConfig`), `src/helpers.ps1` (`Get-InventorySlug`), `Scan-PimState.ps1` |
| F5 | The four seed auth context requirements (`phish-resistant-sif`, `phish-resistant-no-sif`, `phish-resistant-compliant-device`, `phish-resistant-compliant-device-sif`) are documented, but only `phish-resistant-sif` exists as a fixture. | `docs-site/docs/access-model/auth-context-compliance.md`, `tests/fixtures/inventory/authentication-contexts/` |
| F6 | There is no published data file. `pimmonitor.com` serves the Docusaurus site (Cloudflare, `Access-Control-Allow-Origin: *` on `/` checked 2026-10-03); `/eam-role-catalog.json` and `/data/eam-role-catalog.json` answer 404. `docs-site/static/` only holds `img/` and `robots.txt`. | `docs-site/` |

## 3. Packages

Each package is one pull request. Follow the repo's own conventions: Pester tests under `tests/`, `release-please` for versions, `CHANGELOG.md`, the docs in `docs-site/docs`. House style: no EM dashes, no emojis.

### PMC-1. Decide the source and reconcile the catalog (needs Joël)

- Ask Joël which file is the source: the hand-maintained `eam-role-catalog.json` or `eam-role-curated.json` plus the generator. Write the answer at the top of the file that stays, remove or archive the other mechanism, and fix the comments of F2.
- Resolve the 15 differences of F3 role by role with Joël (list them in the PR description with both values). Do not pick a side silently.
- Acceptance: one source file, no contradicting comment, a Pester test that fails when a `templateId` appears twice or is not a GUID, and a test that counts the roles.

### PMC-2. One vocabulary for policy settings

- Use the `expectedConfig` field names everywhere, because the scanner already reads them: `maxActivationDuration`, `requireMFA`, `authContext`, `requireJustification`, `requireTicketing`, `requireApproval`, `allowPermanentEligible`, `maxEligibleDuration`, `allowPermanentActive`, `maxActiveDuration`.
- Rename the catalog's `recommendedConfig` to `expectedConfig` (or keep the key but use these field names inside it). `maxActivationLabel` and `severity` are presentation; keep them outside the policy object (`severity` follows from `securityLevel`, as the access-model README already says).
- `authContext` in the catalog becomes one of the seed slugs, not free text. Map: "Phishing-resistant + sign-in frequency" to `phish-resistant-sif`, "Phishing-resistant" to `phish-resistant-no-sif`, "Standard MFA" to no `authContext` with `requireMFA: true`. Confirm the mapping with Joël.
- Document the rule PIM Manager relies on: `requireMFA: true` means "MFA or an authentication context is on"; when `authContext` is present it is the activation requirement, otherwise MFA. PIM allows only one of the two (Microsoft Graph refuses both, `MfaAndAcrsConflict`).
- Acceptance: the docs component `EamRoleCatalog` and its "Copy AccessModel JSON" button still work; the copied JSON passes the existing compliance tests unchanged.

### PMC-3. The JSON Schema

- Add `schemas/eam-catalog-v1.json` (JSON Schema 2020-12, same style as `notification-payload-v1.json`).
- Top level: `schemaVersion` (semver string, starts at `1.0.0`), `catalogVersion` (date or semver of the content), `publishedAt` (ISO 8601 UTC), `source` (repo URL and commit), `roles`, `levels`, `authContexts`.
- `roles[]`: `templateId` (GUID, required), `displayName`, `plane` (`Control`, `Management`, `Data`), `securityLevel` (`Privileged`, `Specialized`, `Enterprise`), `isPrivileged` (Microsoft's flag), `expectedConfig` (sparse, the PMC-2 fields), `note`, `reviewNeeded`.
- `levels[]`: the default `expectedConfig` per plane and security level, as in the `Examples/access-model/*/*.json` files, so PIM Manager can offer "apply the Control / Privileged template" without listing every role.
- `groups`: the default `expectedConfig` per plane and level for PIM for Groups, split into `member` and `owner`, as in `Examples/access-model/pim-groups/`. No group ids (those are tenant specific).
- `authContexts[]`: per seed slug the requirements of its Conditional Access policy (`requireState`, `requireAuthStrengthId`, `requireSignInFrequencyEveryTime`, `requireCompliantDevice`) and a short `description`. PIM Manager uses these to match a slug to a context in the tenant.
- `additionalProperties: false` on every object, so a typo fails validation.
- Versioning rule (write it in the schema description and the docs): a major bump changes the URL (`/catalog/v2/`) and may remove or rename fields; a minor bump only adds optional fields; a patch changes wording only. Never remove or rename a field within v1.
- Acceptance: a Pester test validates the published file against the schema (`Test-Json -SchemaFile`), and fails on an unknown field.

### PMC-4. Publish the file on pimmonitor.com

- Generate `docs-site/static/catalog/v1/eam-catalog.json` from the source during the docs build (or commit it from a script with a test that it is up to date; pick one and document it). Docusaurus serves `static/` at the site root, so the file lands at `https://pimmonitor.com/catalog/v1/eam-catalog.json`.
- First check how `pimmonitor.com` is deployed (the response header says Cloudflare; Cloudflare Pages is likely but not confirmed). For Cloudflare Pages add `docs-site/static/_headers` with, for `/catalog/*`: `Access-Control-Allow-Origin: *`, `Content-Type: application/json; charset=utf-8`, `Cache-Control: public, max-age=3600`, `X-Content-Type-Options: nosniff`.
- Do not serve it from a GitHub branch (`raw.githubusercontent.com` answers `text/plain` and ties the contract to a branch name).
- Acceptance: after a deploy, `curl -sI -H "Origin: https://pimmanager.com" https://pimmonitor.com/catalog/v1/eam-catalog.json` returns 200, `application/json` and `Access-Control-Allow-Origin: *`, and the body validates against the schema.

### PMC-5. Auth context matching (F4, F5)

- F4 is fine for Joël's tenant. For other tenants, where context names do not slug to the labels, add one of:
  - an explicit mapping file in `AccessModel/` (`authContexts.json`: label to claim value or display name), which the scanner prefers over the slug rule;
  - matching on the requirements of the Conditional Access policy (the `config.json` checks already exist), when exactly one context qualifies.
- Make the warning visible: a skipped authContext check should appear in the report, not only in the log.
- Add fixtures for the three missing seed contexts (F5).
- Acceptance: Pester tests for a context found by slug, by explicit mapping, and not found (reported, not silent).

### PMC-6. Docs page "Catalog for PIM Manager"

- One page under `docs-site/docs/access-model/` (or `reference/`): the URL, the schema, the versioning rule, what PIM Manager does with it (section 4 below, in short), and that the file is public and contains no tenant data.
- Link it from the EAM Role Catalog page.

## 4. What PIM Manager will do with the file (for context, not for this repo)

- Fetch it once after sign-in, as the last loading step, without blocking the page. Cache it for the session.
- Ship a copy of the catalog inside PIM Manager as a fallback, and say which date is shown when the live file could not be read (a self-hosted install can block the host in its Content Security Policy).
- Read only the `schemaVersion` majors it knows; a newer major shows "This catalog needs a newer PIM Manager" instead of guessing.
- Treat everything in the file as a proposal: a template lands in the Configure change basket and goes through the same review as a manual change. Nothing is written to a tenant without the admin seeing it, so a broken or tampered file cannot change a tenant on its own.
- Match `authContext` slugs to the tenant's contexts with the same slug rule as PIM Monitor first, then by the `authContexts` requirements, and let the admin choose when it is ambiguous.
- Export what was applied back as `AccessModel/` files, so PIM Monitor can watch for drift.

## 5. Questions for Joël before starting

1. Which catalog file is the source (PMC-1)?
2. How should each of the 15 disagreeing roles be classified (PMC-1)?
3. Is the mapping of the free-text `authContext` values to the seed slugs right (PMC-2)?
4. Is `pimmonitor.com` deployed with Cloudflare Pages from `docs-site` (PMC-4)?
