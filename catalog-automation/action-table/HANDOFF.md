# Handoff: EAM role catalog, action table and the road to a reliable weekly review

Written 2026-11-16 for the next agent. Working language with the maintainer (Joël) is Dutch; files in
the repo are English. Read this whole file before you change anything.

## 1. Goal (the maintainer's words, binding)

The whole flow, from "the pipeline fetches all role definitions" to "the EAM catalog is updated when
needed", must be accurate, precise and reliable: "one time right", even if it takes longer.

Requirements set by the maintainer:
- **E1** Export all information in the role definition files, including per-action metadata.
- **E2** Definitions plus Microsoft metadata only. No tenant data.
- **E3** Every change in any field counts: additions, edits, removals, anything.
- **E4** Every change triggers a review.
- **E5** Pin the model of the weekly routine, but only at the very end. **Remind Joël** to do it,
  and to move the routine's commit pin (routine `trig_01N32ibUEbGXzw1PV9bPcXSQ`, settings at
  https://claude.ai/code/routines/trig_01N32ibUEbGXzw1PV9bPcXSQ, model `claude-opus-5-5`).

Working style he asked for:
- Act as an orchestrator. Delegate execution to subagents; design, review and decide with him.
- Stop and check in before you finalize anything big.
- Merges to `main` need his explicit go, per pull request.
- He starts workflow runs himself, because the GitHub App cannot dispatch workflows (403).

## 2. What is live (on main)

PRs #34, #36, #37, #39 and #40 are merged.
- **`.github/workflows/entra-role-export.yml`** runs daily at 04:00 UTC. It writes
  `role-definitions/`, `resource-actions/` (Microsoft's description and isPrivileged per action),
  `export-status.json` and `report.json` (report v1) to branch `entra-role-export`.
- **`Export-RoleDefinitions.ps1`** includes the #40 hotfix: the closure no longer hides
  `Get-AllGraphItems`, and the tests now cover the live path.
- **`Export-ResourceActions.ps1`** exports one file per namespace plus `index.json`. 708 of 708
  role actions are described.
- **Weekly routine**, Monday 05:00 UTC, in MODE pr. It is still pinned to commit `759e5c8`, so it runs
  the old `ROUTINE.md` and `CLASSIFICATION-RUBRIC.md`.
- **Catalog**: `docs-site/src/data/eam-role-catalog.json`, catalogVersion `2026-11-16.5`. Review
  state is in `eam-review-state.json`, with lastReviewedSnapshot `936d394`.
- **Graph limitation**: `allowedPrincipalTypes` is documented but Graph does not return it, even with
  `$select`. This is recorded in `export-status.json`.

## 3. What this branch adds (`catalog-automation/action-table/`)

| Path | What it is |
|---|---|
| `data/action-table.json` | **The heart.** 708 actions: plane, levelFloor, service, source, Microsoft flag, description. This is the reviewed baseline (the "zero point"). |
| `data/entities.json` | The same table grouped into 189 entities (the review-page format), with the maintainer's decision per reviewed entity. |
| `data/maintainer-decisions.json` | Joël's 16 decisions on the flagged entities. 14 are "akkoord"; 2 are adjusted: `azure.devOps/allEntities/allTasks` gets levelFloor Specialized, and `graph.dataConnect/allEntities/allProperties/allTasks` gets Privileged. |
| `data/entraops-role-overrides.json` | EntraOps role-level overrides with justification: permissions a role has that are not listed as actions. 11 roles. Apply them in the role classifier. |
| `data/entraops-source/` | The EntraOps classification files used: `Classification_AadResources.json`, `..._EntraIdDirectoryRoles.json`, `..._RoleDefinitionOverwrites.json`. |
| `data/v2-assessment-passes/` | Three blind sessions on the 26 actions EntraOps does not list. 26 of 26 unanimous. |
| `method/ACTION-METHOD.md` | **Method v2**, for classifying a new action. Use this one. |
| `method/ENTRAOPS-SERVICES.md` | EntraOps services and their actions, generated from the source file. Method v2 uses it as reference. |
| `method/ACTION-METHOD-v1-planeB.md` | The superseded first method, kept for history. |
| `build_zero.py` | Script that built the zero point (inputs were scratch files; it documents the rules). |
| `patches/0001-0005*.patch` | **Unmerged local work**, see section 6. Do not lose it. |

Attribution: EntraOps is by Thomas Naunheim (github.com/Cloud-Architekt/EntraOps). Check its license
before this lands on `main`, and keep the attribution in the docs.

## 4. The reasoning (how to think about it)

### 4.1 Plane and level are two different things

- **Plane** follows Microsoft's Enterprise Access Model, read as a control hierarchy: "prevent control
  of higher planes from lower planes". The question is: what can someone who holds this action take
  control of? The planes are Control, Management and Data.
- **Level** follows Microsoft's privileged access security levels: Enterprise, Specialized and
  Privileged. Level is separate from plane: a Management role can be Privileged.

### 4.2 The action table is the heart; a role is derived from it

- **Role plane** = the highest plane among the role's core actions.
- **Role level** = the maximum of the floor from Microsoft's role isPrivileged flag and the highest
  levelFloor among the core actions.
- The model only judges **new** actions, never whole roles from scratch.

### 4.3 Peel order for a role (agreed with Joël)

1. **Hygiene.** Check that the definition is complete and parsable.
2. **Floor.** Microsoft's role `isPrivileged: true` means the role is at least Privileged.
3. **Peel off inherited permissions** (`inheritsPermissionsFrom`: Directory Readers for 128 roles,
   Guest User for 1). The inherited role is assessed as a role of its own and does not count for the
   role that inherits it.
4. **Assess conditioned blocks separately.** These are actions held only under `$SubjectIsOwner` or
   `$ResourceIsSelf`. They are not lighter by definition. If a conditioned block would raise the
   role's plane or level, it **always goes to Joël**.
5. **Peel off ubiquitous support noise**: service health, support tickets, the web portal read, and
   similar actions that almost every role has.
6. **Classify the core actions** via the table, then derive the role plane.
7. **Derive the level**, as in 4.2.
8. **Check consistency with neighbouring roles** that do similar work.
9. **Set the confidence.**
10. **Apply the EntraOps role overrides** (`entraops-role-overrides.json`), for example "Directory
    Synchronization Accounts can overwrite synced identities", which is not listed as an action.

### 4.4 Real-data fact about Microsoft's role flag

Microsoft's role-level `isPrivileged` counts only **unconditioned** sensitive actions. All 35
privileged roles have at least one. User, Guest User and Restricted Guest User hold sensitive actions
only under a condition, and are not privileged. `Get-RoleContext.ps1` (in the patches) still has a
`privilegeCheck` that must be changed to count unconditioned actions only; then it is consistent for
148 of 148 roles.

### 4.5 How the zero point was set (Joël's decision)

EntraOps is the **zero point**, adopted once together with its reasoning. There is no live
dependency: the routine does not fetch EntraOps. **From this zero point on, we assess ourselves,
with Joël's reasoning and Thomas's reasoning combined** (method v2).

Per action, the rules were applied in this order:
1. Plane = the EntraOps tier, mapped ControlPlane→Control, ManagementPlane→Management,
   UserAccess→Data. This applies to 677 actions, with source `entraops`.
2. Microsoft's action flag `isPrivileged: true` wins: Control/Privileged. This applies to 5 actions
   where EntraOps differs, with source `microsoft-flag`. One of them is
   `oAuth2PermissionGrants/createAsOwner`, which makes Application Developer Control/Privileged.
3. The 26 actions EntraOps does not list were assessed with method v2, with source `v2-assessment`.
4. levelFloor comes from our own three blind passes, because EntraOps has no levels. Joël then
   reviewed the 11 entities where the passes disagreed on level.

Joël decided the following along the way. All of it is reflected in the table:
- Follow EntraOps also where it contradicted his earlier catalog decisions:
  - Service Support Administrator and Kaizala Administrator become Management.
  - Resource Policy roles: the writes are Control, the reads and evaluate actions are Management.
  - Readers of identity and security configuration become Management.
- Agent ID Developer and User are both Management. `createAsOwner` gives no control over others.
- The 6 plain reads that EntraOps calls Control are part of the zero point: backup,
  bulkJobs.groups, certificateBasedDeviceAuthConfigurations, two under deviceTemplates, and intune.
  This is not because EntraOps said so; it is EntraOps' reasoning that these reads concern the
  service's own security configuration.
- Microsoft's action flag always wins ("we always follow it").

### 4.6 Method v2 for a new action (`method/ACTION-METHOD.md`)

1. **Find the EntraOps service** the action belongs to: the same entity, the same resource type, or
   the same purpose. The action inherits that service's plane.
2. **Joël's rules on top:**
   - An action Microsoft flags is Control.
   - A read that reveals a secret is Control.
   - Conditions are handled at role level.
   - Implicit permissions are handled at role level.
3. **levelFloor:**
   - **Privileged**: flagged by Microsoft, or full access to the content of a whole content
     workload.
   - **Specialized**: a write that shapes identity or access, or that administers a service.
   - **Enterprise**: everything else.
4. **No service fits** ("new"): the model proposes, and the action **always goes to Joël**.

Procedure that worked:
- Run three blind sessions with opus. Each reads only the method, the services file and the input.
- Check that every action appears exactly once.
- Take the majority. Flag any disagreement for Joël.
- Quarantine helper scripts the sessions leave behind, so later passes stay blind.

## 5. What is open (in order)

1. **Role classifier from the table.** Implement 4.3 deterministically, with the table as the source
   of truth. The model is used only for actions missing from the table. Produce plane and level for
   all 148 roles, with the actions that decide each.
2. **Full review of all 148 roles** against the current catalog. A rough preview against the old
   plane-B table gave 50 differences; expect a different set now. This review also covers the
   changes since 2026-10-03 that were never reviewed: AI Admin, Agent ID Admin, User, Global
   Administrator, Security Admin and CA Admin. Show Joël the differences grouped by theme and by the
   action that decides them, then update the catalog after his go.
3. **Fix `Get-RoleContext.ps1` `privilegeCheck`** to count unconditioned actions only (4.4).
4. **Rewrite `ROUTINE.md` and `CLASSIFICATION-RUBRIC.md`** around:
   - report v2;
   - `Get-RoleContext`;
   - the action table plus method v2, with the model used only for new actions;
   - the peel order in 4.3;
   - every change triggers a review (E3, E4).
5. **Fix our own documentation:**
   - `eam-role-catalog.mdx` contradicts itself on plane.
   - The overview FAQ equates plane with level.
   - The Search Editor example is outdated.
6. **New measurement with pre-registered criteria**, as in `ROUTINE.md` rounds 1 to 7: blind folds
   with `Invoke-CatalogBacktest.ps1`, criteria written down **before** measuring.
7. **Land everything together** in one pull request, with Joël's go:
   - the patches;
   - this folder;
   - the new rubric and ROUTINE;
   - the workflow validating report v2.

   Report v2 would break the pinned routine if it landed alone.
8. **Move the routine pin** to the new commit and **remind Joël to pin the model** (E5).

## 6. Unmerged local work: `patches/`

Five commits from local branch `local/resource-actions`, made with `git format-patch` on top of
`fd0cd2b`:
- `0001` and `0002`: Microsoft's per-action export, and report v2. Report v2 is a Compare that works
  field by field: (action, condition) pairs, `changedProperties` for every field, propagation through
  inheritance, `vanishedRoles`, and the schema `schemas/entra-role-export-report-v2.json`. Most of
  0001 is already on main via PR #39.
- `0003`: read `inheritsPermissionsFrom` as Graph returns it, `[{id}]`.
- `0004`: report vanished roles; set the per-action flag to null outside `microsoft.directory`; stop
  the export only when a core property is lost.
- `0005`: `Get-RoleContext.ps1`, one shared join of a role definition with Microsoft's per-action
  information. The backtest uses it too.

They **do not apply cleanly on current main**, because they overlap with the PR #40 hotfix in
`Export-RoleDefinitions.ps1` and with what #39 already merged. Rebase them by hand:
`git am -3` one patch at a time, resolve conflicts, and keep #40's live-path fix and tests. Then run
`tests/RoleSnapshot.Tests.ps1` and `tests/EamCatalog.Tests.ps1`.

## 7. Lessons (do not repeat these mistakes)

- **Test the live code path, not only the injected one.** `GetNewClosure` hid a dot-sourced function
  in production, and the tests had only checked variables.
- **Use the real data shape in tests.** `inheritsPermissionsFrom` is `[{id}]`, not strings.
- **PowerShell variables are case-insensitive.** `$s` overwrote `$S`.
- **Pre-register criteria before you measure. Keep backtests blind.** Mask role names, longest name
  first.
- **The gate script must run with `-SnapshotDir` and the final list of changed files.**
- **Take `publishedAt` from the clock**, never invent it.
- **Review page artifact** (https://claude.ai/artifact/SYMj9wpoQ3CuGBaNEWrmzY): the runtime hands out
  frozen objects. Copy them before you mutate. A previous agent republished it and fixed exactly
  that. Its database collections are `entities` and `decisions`.
- **Auto mode blocks delegating merges to an agent.** The maintainer says go per pull request.
