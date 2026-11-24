# Changelog

## [0.7.0](https://github.com/0125joel/PIM-Monitor/compare/v0.6.2...v0.7.0) (2026-11-24)


### Features

* export every role property and Microsoft's per-action information ([fd0cd2b](https://github.com/0125joel/PIM-Monitor/commit/fd0cd2ba6b3a24ef765540135b690538f0bd0de6))
* export every role property and Microsoft's per-action information ([9542afe](https://github.com/0125joel/PIM-Monitor/commit/9542afe59a9ded107876c98d066349e9f77742ce))
* measure the routine on the whole pool, twice, with criteria fixed in advance ([7cd85a0](https://github.com/0125joel/PIM-Monitor/commit/7cd85a047f84c985040e8bc38e0d1451577bf231))


### Bug Fixes

* authenticate private sync pushes explicitly ([f8c2e02](https://github.com/0125joel/PIM-Monitor/commit/f8c2e02de6355de4df1b91c52ea8d9ee083b4c96))
* authenticate private sync pushes explicitly ([591bdea](https://github.com/0125joel/PIM-Monitor/commit/591bdea2d60f4b1fd43923aaf10dc606f026579e))
* authenticate private sync pushes explicitly ([368943d](https://github.com/0125joel/PIM-Monitor/commit/368943d21732b3cdfe9968fde950502a4df58e5c))
* describe what B2B Policy Administrator really controls in the role catalog ([d6c65b1](https://github.com/0125joel/PIM-Monitor/commit/d6c65b1c7e34aa2fc0afc844b14ce786dc2437c9))
* do not count the tail of a longer role name as a named role in the backtest ([6ec84e9](https://github.com/0125joel/PIM-Monitor/commit/6ec84e99a00a99b4421a651c30866a31dd029036))
* make the catalog review flow blind, reproducible and measured on the whole pool ([164dd3e](https://github.com/0125joel/PIM-Monitor/commit/164dd3efbba199858409ffd308b4775f6a9e7252))
* make the catalog review flow blind, reproducible and self-checking ([1e0ec9b](https://github.com/0125joel/PIM-Monitor/commit/1e0ec9bde897b208337fd4c343e3cb6b75059741))
* settle the four rubric and catalog conflicts round 5 found (maintainer decisions) ([d6db04a](https://github.com/0125joel/PIM-Monitor/commit/d6db04a0eec782b9448b652d6df9fd5c4d9aedd9))
* settle the two conflicts round 6 found (maintainer decisions) ([3cc32ab](https://github.com/0125joel/PIM-Monitor/commit/3cc32abb4f8319a4432a6ab68179cc157a4440e5))
* the role export failed on its live path (Get-AllGraphItems not found) ([cae0c88](https://github.com/0125joel/PIM-Monitor/commit/cae0c88da696097d86507e7f7e1c8a6c525c8658))

## [0.6.2](https://github.com/0125joel/PIM-Monitor/compare/v0.6.1...v0.6.2) (2026-11-16)


### Bug Fixes

* follow Microsoft's isPrivileged flag for Tenant Governance Administrator; count roles from the catalog in the backtest test ([6983dd5](https://github.com/0125joel/PIM-Monitor/commit/6983dd53d2f9028c722cc1d694f4584dbc300627))
* follow the isPrivileged flag for Tenant Governance Administrator; count roles in the backtest test from the catalog ([14876a6](https://github.com/0125joel/PIM-Monitor/commit/14876a6c5da3c09d323e16f2b5996adca584f779))

## [0.6.1](https://github.com/0125joel/PIM-Monitor/compare/v0.6.0...v0.6.1) (2026-11-02)


### Bug Fixes

* apply the email severity filter to subject, counts and every section, and render scan errors as Outlook-safe tables ([cfb54bc](https://github.com/0125joel/PIM-Monitor/commit/cfb54bc89b8224f8721f9d82b4171cb9dcfda6e1))
* list permanent directory role assignments once, not also under active ([cfb54bc](https://github.com/0125joel/PIM-Monitor/commit/cfb54bc89b8224f8721f9d82b4171cb9dcfda6e1))
* push inventory changes to branches whose name contains a slash ([cfb54bc](https://github.com/0125joel/PIM-Monitor/commit/cfb54bc89b8224f8721f9d82b4171cb9dcfda6e1))

## [0.6.0](https://github.com/0125joel/PIM-Monitor/compare/v0.5.0...v0.6.0) (2026-11-02)


### Features

* bring public main changes back into dev and main ([6921394](https://github.com/0125joel/PIM-Monitor/commit/69213946e86b1427712243d5ea22d14e62310678))
* daily role snapshot and weekly catalog review automation ([b4879ce](https://github.com/0125joel/PIM-Monitor/commit/b4879ce79dee19b7c610e254abab444b5dbb229f))
* daily role snapshot and weekly catalog review automation ([36c5560](https://github.com/0125joel/PIM-Monitor/commit/36c5560084032fdb942a15306d9cfd28940450c7))
* harden the catalog review routine (dry-run, backtest, rubric, silence check) ([079a626](https://github.com/0125joel/PIM-Monitor/commit/079a62671c9c8e2789d0d4c9a6b2e48415fc28e3))
* harden the catalog review routine (dry-run, backtest, rubric, silence check) ([eb2144f](https://github.com/0125joel/PIM-Monitor/commit/eb2144fce6d191d5c505c58e7025533015ca655c))
* leave the rubric's worked examples out of the backtest sample ([5adee86](https://github.com/0125joel/PIM-Monitor/commit/5adee8601a31b63034b3ec259022fbcd12b71135))
* leave the rubric's worked examples out of the backtest sample ([29a1261](https://github.com/0125joel/PIM-Monitor/commit/29a126174b2fe3f1a28855cba13e96da80c09751))
* let the backtest leave named roles out of the sample ([8c05c8a](https://github.com/0125joel/PIM-Monitor/commit/8c05c8a5a32ea0c58ebb07c71679e0f4e7cea919))
* let the backtest leave named roles out of the sample ([2730465](https://github.com/0125joel/PIM-Monitor/commit/2730465e4986e79ba4282a329f9b0d9ba9c1882c))
* setup script for the routine's cloud environment (PowerShell 7 and Pester) ([de9c35c](https://github.com/0125joel/PIM-Monitor/commit/de9c35cf53aa7c29b5753cd5e032beeb20978bc2))
* setup script for the routine's cloud environment (PowerShell 7 and Pester) ([d977e18](https://github.com/0125joel/PIM-Monitor/commit/d977e18442e3d655abb9d101698bf8ce70acb56f))


### Bug Fixes

* catalog and rubric changes from the two backtests ([27e5d4f](https://github.com/0125joel/PIM-Monitor/commit/27e5d4f5b0d7bc187ffff8b0c27fc5f95da92725))
* catalog and rubric changes from the two backtests ([81f92ee](https://github.com/0125joel/PIM-Monitor/commit/81f92ee96ade8100179227a4bc3bcfcb6266eee8))
* close the rubric gaps the first backtest found ([a597c1f](https://github.com/0125joel/PIM-Monitor/commit/a597c1f622fad142de70271c4f9d4e10a5ffd1da))
* close the rubric gaps the first backtest found ([4884722](https://github.com/0125joel/PIM-Monitor/commit/488472214327fddab9c590a4634f93b14aea60fe))
* commit the export report on every run ([733a357](https://github.com/0125joel/PIM-Monitor/commit/733a357362b926d0c033a57962a7c56aef1eee4c))
* commit the export report on every run ([8fe2020](https://github.com/0125joel/PIM-Monitor/commit/8fe2020cc911154e19ee4ac4e157fd1d29cc786c))
* give gh a repository in the role-changes issue step ([2afb4c4](https://github.com/0125joel/PIM-Monitor/commit/2afb4c47c51466e82a7dfc65ec6d62ad05dacc48))
* give gh a repository in the role-changes issue step ([028d45c](https://github.com/0125joel/PIM-Monitor/commit/028d45cecb6bf5abe60dfa636cceb38769334341))
* rubric rules for approval-only and no-action roles, and an auto-eligible score ([62bfd5e](https://github.com/0125joel/PIM-Monitor/commit/62bfd5ee4c340322f29e52ee433cbb03f64d2f35))
* rubric rules for approval-only and no-action roles, and an auto-eligible score ([b2d6d04](https://github.com/0125joel/PIM-Monitor/commit/b2d6d041b98d8db53916dbdafa59dcfc6e7e8f7a))
* use the last snapshot commit as head in report.json ([aebd7d5](https://github.com/0125joel/PIM-Monitor/commit/aebd7d508bcbc38dbadf94ad4b844ccc20b073a5))
* use the last snapshot commit as head in report.json ([8cc3b32](https://github.com/0125joel/PIM-Monitor/commit/8cc3b320a59bdf4b7a2f430e4546f72edcfeea47))

## [0.5.0](https://github.com/0125joel/PIM-Monitor/compare/v0.4.0...v0.5.0) (2026-10-03)


### Features

* publish the EAM catalog for PIM Manager and report unresolved auth contexts ([a797ad1](https://github.com/0125joel/PIM-Monitor/commit/a797ad140ff11cf2231f7f76ee2ef4ac8d5d1136))

## [0.4.0](https://github.com/0125joel/PIM-Monitor/compare/v0.3.0...v0.4.0) (2026-06-13)


### Features

* add EAM access model with compliance engine, curated role catalog, and per-level severity classification ([e5b6c93](https://github.com/0125joel/PIM-Monitor/commit/e5b6c9336fd386a42e58d5275f617a5e7a713cd6))
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
