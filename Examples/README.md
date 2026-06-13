# Examples

Copy-pasteable starter files. Pick what you need, drop it into your repo, edit to fit.

## What's here

| Folder | Purpose |
|---|---|
| [`access-model/`](./access-model/) | Four ready-to-use `AccessModel/*.json` files aligned with the Microsoft Enterprise Access Model (EAM): Control Plane, Specialized, Management Plane, Data/Workload Plane. |
| [`expected-changes/`](./expected-changes/) | Five `expected-changes.json` scenarios showing how to suppress planned changes, onboard new roles, and handle break-glass accounts. |

## How to use

**Access model files** — copy the four `access-model/*.json` files to a new `AccessModel/` directory in your repository root, then edit the role lists to match what you actually have in your tenant. The `expectedConfig` values in the examples reflect EAM RAMP guidance; tighten or loosen as your maturity allows.

**Expected-changes files** — pick the scenario closest to what you need, copy its content to `expected-changes.json` in your repository root, and adjust the `entity`, `ruleId`, and `expiresUtc` fields. PIM Monitor consumes and cleans up the file automatically after each scan.

## Background

- Conceptual reference: [`docs/EAM.md`](../docs/EAM.md) (Dutch, internal)
- User-facing docs: [Access model & compliance](../docs-site/docs/customize/access-model.md) and [Expected change suppression](../docs-site/docs/customize/expected-changes.md)
- Microsoft EAM source: [Securing privileged access — Enterprise access model](https://learn.microsoft.com/en-us/security/privileged-access-workstations/privileged-access-access-model)
