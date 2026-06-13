# Changelog

## [0.4.0](https://github.com/0125joel/PIM-Monitor/compare/v0.3.0...v0.4.0) (2026-06-13)


### Features

* add EAM access model with compliance engine, curated role catalog, and per-level severity classification
* add CA policy compliance check for authentication contexts via authContext field on access model files
* add NOTIFICATION_WEBHOOK_TYPE support and split webhook notifications into per-channel modules (Teams, Slack, Discord)
* overhaul notifications with email-style hierarchy shared across all channels
* add HTML scan report dual-view (severity / entity), evidence links, and print stylesheet
* add FAIL_ON_COMPONENT_ERROR option for optional hard-fail on component errors during scan
* switch upstream version check to the GitHub releases API
* add notification payload JSON schema (v1) for webhook consumers
* add Pester test suite covering change-entry contract, module load order, StrictMode safety, and notification channel structure
* add structured data and SEO improvements to the documentation site


### Bug Fixes

* guard against mass false-archival when PIM group discovery returns an empty response
* stamp workload, entity, and fileType on change entries so expected-changes suppression actually matches
* add auth-context-policy-compliance to compliance types for correct alert rendering
* harden StrictMode safety in property access and null handling across diff and notification helpers
* keep Policy.Read.All for Conditional Access policy reads (ConditionalAccess app permission is insufficient)
* update fileType references from tier to access-model across scripts and documentation
* hide the inactive view and highlight the active tab in the HTML report toggle

## [0.3.0](https://github.com/0125joel/PIM-Monitor/compare/v0.2.1...v0.3.0) (2026-05-09)


### Features

* add AuthContextLookup parameter to notification functions for enhanced context mapping ([b0ff2f8](https://github.com/0125joel/PIM-Monitor/commit/b0ff2f8a2922f6936c24eafe7a56caff2aafdcb4))

## [0.2.1](https://github.com/0125joel/PIM-Monitor/compare/v0.2.0...v0.2.1) (2026-05-01)


### Bug Fixes

* adjust throttle limits and retry logic in Invoke-GraphRequest function ([467daae](https://github.com/0125joel/PIM-Monitor/commit/467daae0881d58ecc916624673d65cb5d4966b5a))

## [0.2.0](https://github.com/0125joel/PIM-Monitor/compare/v0.1.0...v0.2.0) (2026-04-30)


### Features

* add docusaurus-search-local dependency for enhanced search functionality ([23bed51](https://github.com/0125joel/PIM-Monitor/commit/23bed516d17be607a4180c7d50fe7c340ffb6aa1))
* enhance documentation with descriptions for configuration files and add robots.txt for SEO ([cd27652](https://github.com/0125joel/PIM-Monitor/commit/cd276524c8544e8185fa9601218711eb04cf5525))
* enhance error handling and notifications in scan process; update documentation and workflow variables ([8ffba72](https://github.com/0125joel/PIM-Monitor/commit/8ffba729ff3b8e9bc3f12f312dcac46c1cd0f55f))
* implement upstream update check and notification; add versioning and release configuration ([19dced1](https://github.com/0125joel/PIM-Monitor/commit/19dced1e9508c43fe60cd43aaeeb4245132c00e2))
* remove outdated documentation on notifications, pipeline YAML, and severity rules; add new guide for reducing alert fatigue ([29336ec](https://github.com/0125joel/PIM-Monitor/commit/29336eccf27964b6af3b4459686fe6f05aab68bc))
* scan error notifications, comprehensive customize docs, comment cleanup ([1636501](https://github.com/0125joel/PIM-Monitor/commit/16365017b5d3383a728c5105a8a2d5aa70aacc7b))
