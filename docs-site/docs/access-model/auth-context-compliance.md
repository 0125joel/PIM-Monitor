---
sidebar_position: 6
description: Verify that each authentication context is backed by a correctly configured Conditional Access policy.
keywords:
  - authentication context
  - Conditional Access compliance
  - auth context claim
  - phishing-resistant MFA
  - CA policy verification
---

# Auth Context CA Compliance

This check closes a gap that `expectedConfig` alone cannot. In [Setup & Compliance](./setup-compliance.mdx#expectedconfig-fields), `requireMFA` confirms that *some* MFA or auth-context rule is switched on in the PIM policy. But a PIM activation policy can require an auth context claim (`c2`, `c3`, ...) while the Conditional Access policy that is supposed to enforce that claim is disabled, in report-only mode, or weaker than you think. This check verifies the CA side.

It is part of the access model and only runs when the [`AccessModel/` folder exists](./overview.mdx#turn-it-on-or-off).

## How it works

1. Every scan, PIM Monitor fetches the CA policies that reference auth context claims and stores them in `inventory/conditional-access/`.
2. For each folder in `inventory/authentication-contexts/`, it looks for a `config.json`.
3. Where a `config.json` exists, it finds every CA policy targeting that context's claim and checks that at least one satisfies every requirement in the config.
4. Anything short of that is reported as a High severity violation (`fileType: "auth-context-policy-compliance"`).

## Declaring what you expect

Create a `config.json` next to `definition.json` in each auth context folder you want monitored. The scan never writes or overwrites this file.

```
inventory/authentication-contexts/{slug}/
├── definition.json   ← Graph API response (never edit by hand)
└── config.json       ← your requirements (never touched by the scan)
```

```json
{
  "requireState": "enabled",
  "requireAuthStrengthId": "00000000-0000-0000-0000-000000000003",
  "requireSignInFrequencyEveryTime": true,
  "requireCompliantDevice": false
}
```

| Field | Type | Description |
|---|---|---|
| `requireState` | string | Required CA policy state. Use `"enabled"` to demand it is enforcing, not report-only. |
| `requireAuthStrengthId` | string | Required authentication strength ID. Microsoft's built-in "Phishing-resistant MFA" strength is `00000000-0000-0000-0000-000000000003`. |
| `requireSignInFrequencyEveryTime` | boolean | When `true`, requires `sessionControls.signInFrequency.frequencyInterval = "everyTime"`. Use for privileged contexts that must re-authenticate on every activation. |
| `requireCompliantDevice` | boolean | When `true`, requires `"compliantDevice"` in `grantControls.builtInControls`. |

Omit a field to skip that check.

## Seed configs included

PIM Monitor ships four ready-made `config.json` files in `inventory/authentication-contexts/`. All four require auth strength `00000000-0000-0000-0000-000000000003` (phishing-resistant MFA) and state `"enabled"`:

| Auth context | Sign-in frequency every time | Compliant device |
|---|---|---|
| `phish-resistant-sif` | Yes | No |
| `phish-resistant-no-sif` | No | No |
| `phish-resistant-compliant-device` | No | Yes |
| `phish-resistant-compliant-device-sif` | Yes | Yes |

## Required permission

This check needs the `Policy.Read.All` application permission on the App Registration. Without it, PIM Monitor logs a warning and skips the check rather than failing the scan; every context with a `config.json` then reports "no policy found".

## Advanced: suppressing a violation

Use `expected-changes.json` with `fileType: "auth-context-policy-compliance"`, and optionally a `ruleId` for one specific requirement:

```json
{
  "expected": [
    {
      "fileType": "auth-context-policy-compliance",
      "entity": "phish-resistant-sif",
      "ruleId": "requireSignInFrequencyEveryTime",
      "reason": "SIF policy update scheduled for next sprint",
      "expiresUtc": "2026-06-01T00:00:00Z"
    }
  ]
}
```

As with every suppression, the top-level key must be `expected` and the deadline field is `expiresUtc`.
