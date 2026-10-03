# Handoff: publish the PIM Monitor catalog for PIM Manager

**For:** an agent working in the `0125joel/PIM-Monitor` repository.
**From:** the PIM Manager Configure phase (NextGen phase 4), 2026-10-03.
**Background (Dutch):** `docs/Assets/next-gen/configure/2026-10-nextgen-configure-redesign.md` in the PIM Manager repository (`0125joel/PIM-manager-private`, branch `NextGen` or `claude/app-review-improvements-nxaxdz`), sections 3c and 3.6. This file is kept in both repositories; the copy in PIM Monitor is the one to work from.
**Status:** not started. Nothing in PIM Monitor has been changed apart from adding this file. Joël's answers of 2026-10-03 are worked in; no questions are open.

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
| F2 | There is one source, the hand-maintained catalog `eam-role-catalog.json`, last reconciled by hand in commit `c92918e` ("hand-reconciled classifications and revised derivation rationale"); its `_comment` says so and the docs page `eam-role-catalog.mdx` describes the method. The generator `Generate-EamRoleCatalog.ps1` and its input `eam-role-curated.json` are leftovers: the generator header still calls itself the single source of truth, and `c92918e` did not touch the curated file. | `docs-site/src/data/eam-role-catalog.json` (`_comment`), `docs-site/scripts/Generate-EamRoleCatalog.ps1`, `docs-site/src/data/eam-role-curated.json` |
| F3 | Because of F2 the stale files disagree with the catalog: `eam-role-curated.json` differs on 15 roles (for example People Administrator is Management/Specialized in the catalog and Control/Enterprise in the curated file) and has 144 roles against 145. The starter files in `Examples/access-model/` lag as well: `ControlPlane/Enterprise.json` lists 11 roles the catalog puts at another level, `ControlPlane/Specialized.json` has 9 roles where the catalog has 17, the catalog's one Management/Enterprise role has no file, and the `Examples/access-model/README.md` still describes plane derivation from "role name and description", while the catalog page says the permissions (`allowedResourceActions`) decide. The catalog wins in every case. | `docs-site/src/data/eam-role-curated.json`, `Examples/access-model/**` |
| F4 | `authContext` is resolved by slug of the tenant's authentication context display name (`Get-InventorySlug`: lowercase, keep `a-z0-9`, whitespace and hyphens, collapse). In Joël's tenant this works: the contexts are named "Phish-resistant & SIF", "Phish-resistant & No SIF", "Phish-resistant & Compliant device" and "Phish-resistant & Compliant device & SIF", which slug to exactly the four seed labels (checked 2026-10-03). A tenant that names its contexts differently (for example "Auth Context - Phish-resistant & SIF", which slugs to `auth-context-phish-resistant-sif`) gets the compliance check skipped with only a warning in the log (`Resolve-AuthContextConfig`). | `src/compliance.ps1` (`Resolve-AuthContextConfig`), `src/helpers.ps1` (`Get-InventorySlug`), `Scan-PimState.ps1` |
| F5 | The four seed auth context requirements (`phish-resistant-sif`, `phish-resistant-no-sif`, `phish-resistant-compliant-device`, `phish-resistant-compliant-device-sif`) are documented, but only `phish-resistant-sif` exists as a fixture. | `docs-site/docs/access-model/auth-context-compliance.md`, `tests/fixtures/inventory/authentication-contexts/` |
| F6 | There is no published data file. `pimmonitor.com` serves the Docusaurus site (Cloudflare, `Access-Control-Allow-Origin: *` on `/` checked 2026-10-03); `/eam-role-catalog.json` and `/data/eam-role-catalog.json` answer 404. `docs-site/static/` only holds `img/` and `robots.txt`. | `docs-site/` |

## 3. Packages

Each package is one pull request. Follow the repo's own conventions: Pester tests under `tests/`, `release-please` for versions, `CHANGELOG.md`, the docs in `docs-site/docs`. House style: no EM dashes, no emojis.

### PMC-1. One source, and bring the rest in line

The classification method is already defined and stays as it is: the plane follows from the role's permissions (identity and security actions outrank workload actions), and the level follows the waterfall on the catalog page (`eam-role-catalog.mdx`): first the `isPrivileged` floor, then blast-radius escalation, otherwise the permissions decide. `eam-role-catalog.json` is the result and the only source.

- Remove `docs-site/scripts/Generate-EamRoleCatalog.ps1` and `docs-site/src/data/eam-role-curated.json`, or move them to an `archive/` folder with a note that they are retired. Make sure nothing in the build or the tests still reads them.
- Regenerate the starter files in `Examples/access-model/` (roles at each plane and level, including the missing Management/Enterprise file) from the catalog, with a script and a Pester test that fails when a starter file and the catalog disagree. Update `Examples/access-model/README.md` to the method of the catalog page (permissions decide, not names) and to the real counts.
- Add a Pester test that fails when a `templateId` appears twice or is not a GUID, and when a role has a plane or level outside the allowed values.
- Acceptance: one source, no stale file that claims otherwise, starter files equal to the catalog, tests green.

### PMC-2. One vocabulary for policy settings

- Use the `expectedConfig` field names everywhere, because the scanner already reads them: `maxActivationDuration`, `requireMFA`, `authContext`, `requireJustification`, `requireTicketing`, `requireApproval`, `allowPermanentEligible`, `maxEligibleDuration`, `allowPermanentActive`, `maxActiveDuration`.
- Rename the catalog's `recommendedConfig` to `expectedConfig` (or keep the key but use these field names inside it). `maxActivationLabel` and `severity` are presentation; keep them outside the policy object (`severity` follows from `securityLevel`, as the access-model README already says).
- `authContext` in the catalog becomes one of the seed slugs, not free text. Map: "Phishing-resistant + sign-in frequency" to `phish-resistant-sif`, "Phishing-resistant" to `phish-resistant-no-sif`, "Standard MFA" to no `authContext` with `requireMFA: true`. This is checked: the starter files already use exactly these values per level (Privileged `phish-resistant-sif`, Specialized `phish-resistant-no-sif`, Enterprise no `authContext` and `requireMFA: true`), and the catalog page's policy table says the same. The two compliant-device seeds are not used by the catalog; they stay available for tenants that want them.
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
- `pimmonitor.com` is deployed with Cloudflare Pages from `docs-site` (confirmed by Joël, 2026-10-03). Add `docs-site/static/_headers` with, for `/catalog/*`: `Access-Control-Allow-Origin: *`, `Content-Type: application/json; charset=utf-8`, `Cache-Control: public, max-age=3600`, `X-Content-Type-Options: nosniff`.
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
- Add the catalog as a second contract to `docs/en/11-pim-manager-integration.md` and `docs/nl/11-pim-manager-integratie.md` (today they describe only the inventory contract for the `/monitor` page), and the schema versioning rule to `docs/en/12-versioning.md` and its Dutch twin: a breaking change to the catalog is a `feat!:` commit and a new `/catalog/vN/` path.

## 4. What PIM Manager will do with the file (for context, not for this repo)

- Fetch it once after sign-in, as the last loading step, without blocking the page. Cache it for the session.
- Ship a copy of the catalog inside PIM Manager as a fallback, and say which date is shown when the live file could not be read (a self-hosted install can block the host in its Content Security Policy).
- Read only the `schemaVersion` majors it knows; a newer major shows "This catalog needs a newer PIM Manager" instead of guessing.
- Treat everything in the file as a proposal: a template lands in the Configure change basket and goes through the same review as a manual change. Nothing is written to a tenant without the admin seeing it, so a broken or tampered file cannot change a tenant on its own.
- Match `authContext` slugs to the tenant's contexts with the same slug rule as PIM Monitor first, then by the `authContexts` requirements, and let the admin choose when it is ambiguous.
- Export what was applied back as `AccessModel/` files, so PIM Monitor can watch for drift.

## 5. Questions for Joël

All answered on 2026-10-03: there is one source (the catalog, F2); the classification method is the waterfall on the catalog page, so the stale files follow the catalog (F3, PMC-1); the auth context mapping is checked (PMC-2); `pimmonitor.com` runs on Cloudflare Pages (PMC-4). Ask Joël only when a starter file or a role note seems to need a different classification than the catalog gives.
