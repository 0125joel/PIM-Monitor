---
sidebar_position: 3
title: "Catalog for PIM Manager"
sidebar_label: Catalog for PIM Manager
description: The EAM role catalog as one public, versioned JSON file with a JSON Schema, for tools such as PIM Manager.
keywords:
  - EAM catalog JSON
  - PIM Manager template
  - JSON Schema
  - Entra role catalog
  - catalog versioning
---

# Catalog for PIM Manager

The [EAM Role Catalog](./eam-role-catalog.mdx) is also published as one JSON file, so other tools can use it as a template source. [PIM Manager](https://pimmanager.com) reads it after sign-in and offers it in its Configure page: the admin picks a plane and a security level, adjusts the proposed settings and applies them to the tenant. When a role is added to the catalog, PIM Manager picks it up on the next sign-in without a release of its own.

The file is public. It contains Microsoft's built-in role properties and PIM Monitor's classification of them, and **no tenant data**. PIM Manager sends nothing to PIM Monitor; it reads one file.

## Where it lives

| What | Where |
|---|---|
| Catalog | `https://pimmonitor.com/catalog/v1/eam-catalog.json` |
| JSON Schema | [`schemas/eam-catalog-v1.json`](https://github.com/joel-prins/PIM-Monitor/blob/main/schemas/eam-catalog-v1.json) |
| Maintained source | `docs-site/src/data/eam-role-catalog.json` and `eam-catalog-defaults.json` |

The server answers with `Access-Control-Allow-Origin: *`, `Content-Type: application/json`, a one hour cache and `nosniff`, so a browser app on any origin can fetch it.

## What is in it

| Field | Content |
|---|---|
| `schemaVersion` | Version of the contract, semver, starts at `1.0.0` |
| `catalogVersion` | Version of the content, shown on this site next to the catalog |
| `publishedAt` | ISO 8601 UTC timestamp of the content |
| `source` | Repository and path of the maintained source |
| `roles[]` | Every built-in role: `templateId`, `displayName`, `plane`, `securityLevel`, `isPrivileged`, a sparse `expectedConfig`, `note`, `reviewNeeded` |
| `levels[]` | The default `expectedConfig` per plane and security level |
| `groups[]` | The default `expectedConfig` for PIM for Groups per plane and level, split into `member` and `owner`. No group ids |
| `authContexts[]` | Per seed slug the requirements of its Conditional Access policy, so a slug can be matched to a context in a tenant |

Policy settings use the same field names as the `expectedConfig` in your [`AccessModel/` files](./setup-compliance.mdx#expectedconfig-fields). `requireMFA: true` means "MFA or an authentication context is on"; when `authContext` is present it is the activation requirement, otherwise MFA. PIM allows only one of the two.

## Versioning

`schemaVersion` is semver, and the rule is fixed:

- A **major** bump changes the URL (`/catalog/v2/`) and may remove or rename fields.
- A **minor** bump only adds optional fields.
- A **patch** changes wording only.
- A field is never removed or renamed within v1.

A consumer reads only the majors it knows. `catalogVersion` changes whenever roles or policies change, without any change to the schema.

## What PIM Manager does with it

- Fetches the file once after sign-in, without blocking the page, and caches it for the session.
- Ships a copy as a fallback and says which date it shows when the live file cannot be read.
- Shows "This catalog needs a newer PIM Manager" for a major it does not know, instead of guessing.
- Treats everything as a proposal. A template lands in the change basket and goes through the same review as a manual change, so a broken or tampered file cannot change a tenant on its own.
- Matches `authContext` slugs to the tenant's contexts the way PIM Monitor does (see [Auth Context CA Compliance](./auth-context-compliance.md#how-a-label-finds-its-context)), then by the `authContexts` requirements, and lets the admin choose when it is ambiguous.
- Exports what was applied as `AccessModel/` files, so PIM Monitor can watch for drift.

## Maintaining it

The published file and the starter files in `Examples/access-model/` are generated from the catalog by `docs-site/scripts/Build-EamCatalog.ps1` and committed. A test fails when they are out of date. After you change a role or a default, run the script, bump `catalogVersion` and `publishedAt` in `eam-catalog-defaults.json` when consumers should notice, and commit the result.
