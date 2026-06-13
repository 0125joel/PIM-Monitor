#requires -Version 7
Set-StrictMode -Version Latest

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-shared.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-teams.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-slack.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-discord.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook.ps1")

    $script:fixture = @{
        High          = @(
            @{ severity='High'; changeType='modified'; description='Tier-0 Admins > authContext'; context='Tier-0 Admins'; fileType='access-model-compliance'; old=@{ authContext='none' }; new=@{ authContext='phish-resistant-sif' } }
            @{ severity='High'; changeType='added'; description='Global Administrator > assignment'; context='Global Administrator'; fileType='git'; roleId='62e90394-69f5-4237-9190-012177145e10'; old=$null; new=@{ principalId='abc'; directoryScopeId='/' } }
        )
        Medium        = @(
            @{ severity='Medium'; changeType='modified'; description='Exchange Administrator > duration'; context='Exchange Administrator'; fileType='git'; old=@{ maximumDuration='PT8H' }; new=@{ maximumDuration='PT4H' } }
        )
        Low           = @()
        Informational = @()
        Coverage      = @(
            @{ severity='Informational'; context='Attack Payload Author'; entity='9c6df0f2'; fileType='coverage'; description='Role not in any access model' }
        )
        Total         = 4
    }
}

Describe "Get-WebhookType" {
    It "maps legacy O365 incoming connector URL to Teams" {
        Get-WebhookType 'https://contoso.webhook.office.com/webhookb2/abc' | Should -Be 'Teams'
    }

    It "maps Power Automate logic.azure.com URL to Teams" {
        Get-WebhookType 'https://prod-23.westeurope.logic.azure.com/workflows/abc/triggers/manual/paths/invoke' | Should -Be 'Teams'
    }

    It "maps Power Automate azure-apim.net URL to Teams" {
        Get-WebhookType 'https://prod-12.westeurope.azure-apim.net/apim/teams/abc' | Should -Be 'Teams'
    }

    It "maps Slack incoming webhook to Slack" {
        Get-WebhookType 'https://hooks.slack.com/services/T00000/B00000/abc' | Should -Be 'Slack'
    }

    It "maps Discord webhook to Discord" {
        Get-WebhookType 'https://discord.com/api/webhooks/123/abc' | Should -Be 'Discord'
    }

    It "falls back to Generic for unknown hosts" {
        Get-WebhookType 'https://hooks.example.com/abc' | Should -Be 'Generic'
    }

    Context "NOTIFICATION_WEBHOOK_TYPE override" {
        AfterEach {
            Remove-Item Env:\NOTIFICATION_WEBHOOK_TYPE -ErrorAction SilentlyContinue
        }

        It "overrides URL detection: Logic App URL forced to Generic" {
            $env:NOTIFICATION_WEBHOOK_TYPE = 'Generic'
            Get-WebhookType 'https://prod-23.westeurope.logic.azure.com/workflows/abc/triggers/manual/paths/invoke' |
                Should -Be 'Generic'
        }

        It "normalizes override casing to the canonical value" {
            $env:NOTIFICATION_WEBHOOK_TYPE = 'teams'
            Get-WebhookType 'https://hooks.example.com/abc' | Should -BeExactly 'Teams'
        }

        It "ignores an unrecognized override and falls back to URL detection" {
            $env:NOTIFICATION_WEBHOOK_TYPE = 'MatterMost'
            Get-WebhookType 'https://hooks.slack.com/services/T00000/B00000/abc' -WarningAction SilentlyContinue |
                Should -Be 'Slack'
        }

        It "ignores an unexpanded ADO macro value" {
            $env:NOTIFICATION_WEBHOOK_TYPE = '$(NOTIFICATION_WEBHOOK_TYPE)'
            Get-WebhookType 'https://discord.com/api/webhooks/123/abc' | Should -Be 'Discord'
        }
    }
}

Describe "Get-CommitDiffUrl branch awareness" {
    BeforeEach {
        $script:savedEnv = @{}
        foreach ($name in 'BUILD_REPOSITORY_URI', 'BUILD_SOURCEBRANCHNAME', 'GITHUB_SERVER_URL', 'GITHUB_REPOSITORY', 'GITHUB_REF_NAME') {
            $script:savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
            Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
        }
    }

    AfterEach {
        foreach ($entry in $script:savedEnv.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
    }

    It "uses BUILD_SOURCEBRANCHNAME in the ADO refName instead of hardcoding main" {
        $env:BUILD_REPOSITORY_URI = 'https://dev.azure.com/org/project/_git/repo'
        $env:BUILD_SOURCEBRANCHNAME = 'pim-inventory'
        Get-CommitDiffUrl -CommitSha 'a1b2c3d4' |
            Should -Be 'https://dev.azure.com/org/project/_git/repo/commit/a1b2c3d4?refName=refs%2Fheads%2Fpim-inventory'
    }

    It "falls back to main when no branch env var is set" {
        $env:BUILD_REPOSITORY_URI = 'https://dev.azure.com/org/project/_git/repo'
        Get-CommitDiffUrl -CommitSha 'a1b2c3d4' |
            Should -Be 'https://dev.azure.com/org/project/_git/repo/commit/a1b2c3d4?refName=refs%2Fheads%2Fmain'
    }

    It "uses GITHUB_REF_NAME for the inventory file URL branch fallback on GitHub" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'org/repo'
        $env:GITHUB_REF_NAME = 'inventory'
        Get-InventoryFileUrl -RelativePath 'inventory/directory-roles/global-administrator/policy.json' |
            Should -Be 'https://github.com/org/repo/blob/inventory/inventory/directory-roles/global-administrator/policy.json'
    }
}

Describe "Build-SlackPayload" {
    It "emits a top-level text preview field for push notifications" {
        $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        $p.text | Should -Not -BeNullOrEmpty
        $p.text | Should -BeLike '*High-severity*'
    }

    It "renders header + context + exec summary + counts at the top" {
        $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        $p.blocks[0].type | Should -Be 'header'
        $p.blocks[0].text.text | Should -Be 'PIM Monitor — change detected'
        $p.blocks[1].type | Should -Be 'context'
        ($p.blocks[1].elements | Where-Object { $_.text -like '*Contoso*' }) | Should -Not -BeNullOrEmpty
        $p.blocks[2].type | Should -Be 'section'  # exec summary
        $p.blocks[3].type | Should -Be 'section'  # counts (fields)
        $p.blocks[3].fields.Count | Should -BeGreaterThan 3
    }

    It "splits content under CHANGES and ACCESS MODEL header blocks" {
        $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $headerTexts = @($p.blocks | Where-Object { $_.type -eq 'header' } | ForEach-Object { $_.text.text })
        $headerTexts | Should -Contain 'CHANGES'
        $headerTexts | Should -Contain 'ACCESS MODEL'
    }

    It "renders per-change diff as a triple-backtick codeblock" {
        $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        $json | Should -Match '```'
        $json | Should -Match 'authContext: none .* phish-resistant-sif'
    }

    It "uses actions block with View Diff button when CommitSha + CI URL available" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        try {
            $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -CommitSha 'a1b2c3'
            $actions = @($p.blocks | Where-Object { $_.type -eq 'actions' })
            $actions.Count | Should -Be 1
            $actions[0].elements[0].text.text | Should -Be 'View Diff'
            $actions[0].elements[0].url       | Should -BeLike '*a1b2c3*'
        } finally {
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
        }
    }

    It "adds Open HTML Report button when REPORT_ARTIFACT=true and CI env present" {
        $env:REPORT_ARTIFACT   = 'true'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $env:GITHUB_RUN_ID     = '42'
        try {
            $p = Build-SlackPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
            $actions = @($p.blocks | Where-Object { $_.type -eq 'actions' })
            $actions.Count | Should -Be 1
            $titles = @($actions[0].elements | ForEach-Object { $_.text.text })
            $titles | Should -Contain 'Open HTML Report'
        } finally {
            $env:REPORT_ARTIFACT   = $null
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
            $env:GITHUB_RUN_ID     = $null
        }
    }

    It "stays within the Slack 50-block hard limit even under worst-case input" {
        $huge = [ordered]@{
            High          = @(1..30 | ForEach-Object { @{ severity='High'; changeType='added'; description="git change $_"; fileType='git'; old=$null; new=@{ id="x$_" } } })
            Medium        = @(1..30 | ForEach-Object { @{ severity='Medium'; changeType='modified'; description="compl $_"; fileType='access-model-compliance'; old=@{ a=1 }; new=@{ a=2 } } })
            Low           = @(); Informational = @()
            Coverage      = @(1..30 | ForEach-Object { @{ severity='Informational'; context="role $_"; fileType='coverage'; description='x' } })
            Total         = 90
        }
        $p = Build-SlackPayload -ChangesBySeverity $huge -MinSeverity 'Low'
        $p.blocks.Count | Should -BeLessOrEqual 50
    }

    It "drops the CHANGES header when there are no git-type changes" {
        $compOnly = @{
            High          = @(@{ severity='High'; description='c'; fileType='access-model-compliance'; old=@{}; new=@{} })
            Medium        = @(); Low = @(); Informational = @()
            Coverage      = @(); Total = 1
        }
        $p = Build-SlackPayload -ChangesBySeverity $compOnly -MinSeverity 'Low'
        $headerTexts = @($p.blocks | Where-Object { $_.type -eq 'header' } | ForEach-Object { $_.text.text })
        $headerTexts | Should -Not -Contain 'CHANGES'
        $headerTexts | Should -Contain 'ACCESS MODEL'
    }
}

Describe "Build-GenericPayload (v1.0.0)" {
    BeforeAll {
        $script:schemaPath = Resolve-Path (Join-Path $PSScriptRoot '../schemas/notification-payload-v1.json')
    }

    It "includes the schema URL and schemaVersion = 1.0.0" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low' -TenantName 'Contoso'
        $p['$schema']       | Should -Match 'notification-payload-v1\.json$'
        $p['schemaVersion'] | Should -Be '1.0.0'
    }

    It "emits a summary.counts block including classification" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low'
        $p.summary.counts.Contains('classification') | Should -BeTrue
        $p.summary.counts.high | Should -Be 2
    }

    It "omits the tenant key when TenantName is empty" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low'
        $p.Contains('tenant') | Should -BeFalse
    }

    It "includes tenant.name when TenantName is supplied" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low' -TenantName 'Contoso'
        $p.tenant.name | Should -Be 'Contoso'
    }

    It "omits the urls key when no commit / report URL inferable" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low'
        $p.Contains('urls') | Should -BeFalse
    }

    It "populates urls.diff when CommitSha + CI env available" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        try {
            $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low' -CommitSha 'a1b2c3'
            $p.urls.diff | Should -BeLike '*a1b2c3*'
        } finally {
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
        }
    }

    It "includes _legacy block with backwards-compat fields" {
        $p = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low'
        $p._legacy.text                                | Should -Match 'PIM Monitor'
        $p._legacy.summary                             | Should -Not -BeNullOrEmpty
        $p._legacy.changesBySeverity.total             | Should -Be 4
        $p._legacy.changesBySeverity.high              | Should -Be 2
    }

    It "truncates changes array > 50 items with _truncated placeholder" {
        $huge = [ordered]@{
            High          = @(1..60 | ForEach-Object { @{ severity='High'; changeType='added'; fileType='git'; description="g $_" } })
            Medium = @(); Low = @(); Informational = @(); Coverage = @(); Total = 60
        }
        $p = Build-GenericPayload -ChangesBySeverity $huge -RelevantCount 60 -MinSeverity 'Low'
        $p.changes.Count | Should -Be 50
        $p.changes[-1]._truncated | Should -BeTrue
        $p.changes[-1].remaining  | Should -Be 11
    }

    It "validates against schemas/notification-payload-v1.json" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        try {
            $p    = Build-GenericPayload -ChangesBySeverity $script:fixture -RelevantCount 4 -MinSeverity 'Low' -CommitSha 'a1b2c3' -TenantName 'Contoso'
            $json = $p | ConvertTo-Json -Depth 20
            { Test-Json -Json $json -SchemaFile $script:schemaPath } | Should -Not -Throw
            (Test-Json -Json $json -SchemaFile $script:schemaPath) | Should -BeTrue
        } finally {
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
        }
    }

    It "minimal payload (no tenant, no urls, no coverage) still validates against schema" {
        $minimal = @{
            High          = @(@{ severity='High'; changeType='added'; fileType='git'; description='only one' })
            Medium = @(); Low = @(); Informational = @(); Total = 1
        }
        $p    = Build-GenericPayload -ChangesBySeverity $minimal -RelevantCount 1 -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
    }

    It "truncated payload still validates against schema" {
        $huge = [ordered]@{
            High          = @(1..60 | ForEach-Object { @{ severity='High'; changeType='added'; fileType='git'; description="g $_" } })
            Medium = @(); Low = @(); Informational = @(); Coverage = @(); Total = 60
        }
        $p    = Build-GenericPayload -ChangesBySeverity $huge -RelevantCount 60 -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
    }
}

Describe "Build-DiscordPayload" {
    It "emits a summary embed plus per-severity / Access Model embeds (≤ 10 total)" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        $p.embeds.Count | Should -BeGreaterOrEqual 2
        $p.embeds.Count | Should -BeLessOrEqual 10
    }

    It "places tenant name in the summary embed author" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        $p.embeds[0].author.name | Should -Be 'Tenant: Contoso'
    }

    It "omits author when TenantName not supplied" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $p.embeds[0].ContainsKey('author') | Should -BeFalse
    }

    It "uses severity-mapped color int per embed" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $highEmbed = $p.embeds | Where-Object { $_.title -like 'CHANGES — High*' }
        $highEmbed.color | Should -Be 15684676  # red
    }

    It "renders per-change diff as a triple-backtick codeblock" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        $json | Should -Match '```'
        $json | Should -Match 'authContext: none -> phish-resistant-sif'
    }

    It "splits compliance findings into a separate ACCESS MODEL embed" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        ($p.embeds | Where-Object { $_.title -like 'ACCESS MODEL — Compliance*' }) | Should -Not -BeNullOrEmpty
    }

    It "renders a separate ACCESS MODEL — Coverage embed when coverage items exist" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        ($p.embeds | Where-Object { $_.title -like 'ACCESS MODEL — Coverage*' }) | Should -Not -BeNullOrEmpty
    }

    It "appends a Reports field with Diff + HTML report links to the last embed" {
        $env:REPORT_ARTIFACT   = 'true'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $env:GITHUB_RUN_ID     = '42'
        try {
            $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -CommitSha 'a1b2c3'
            $last = $p.embeds[-1]
            $reports = $last.fields | Where-Object { $_.name -eq '📄 Reports' }
            $reports | Should -Not -BeNullOrEmpty
            $reports.value | Should -Match '\[Diff\]'
            $reports.value | Should -Match '\[HTML report\]'
        } finally {
            $env:REPORT_ARTIFACT   = $null
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
            $env:GITHUB_RUN_ID     = $null
        }
    }

    It "omits the Reports field when neither commit nor report URL inferable" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $allFields = $p.embeds | ForEach-Object { if ($_.ContainsKey('fields')) { $_.fields } }
        ($allFields | Where-Object { $_.name -eq '📄 Reports' }) | Should -BeNullOrEmpty
    }

    It "sets allowed_mentions.parse to an empty array to suppress mass-pings" {
        $p = Build-DiscordPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $p.allowed_mentions.parse.Count | Should -Be 0
    }

    It "stays within the 10-embed limit even under worst-case input" {
        $huge = [ordered]@{
            High          = @(1..30 | ForEach-Object { @{ severity='High'; changeType='added'; description="git $_"; fileType='git'; old=$null; new=@{ id="x$_" } } })
            Medium        = @(1..30 | ForEach-Object { @{ severity='Medium'; changeType='modified'; description="compl $_"; fileType='access-model-compliance'; old=@{ a=1 }; new=@{ a=2 } } })
            Low           = @(1..30 | ForEach-Object { @{ severity='Low'; changeType='modified'; description="low $_"; fileType='git'; old=@{ a=1 }; new=@{ a=2 } } })
            Informational = @()
            Coverage      = @(1..30 | ForEach-Object { @{ severity='Informational'; context="role $_"; fileType='coverage'; description='x' } })
            Total         = 120
        }
        $p = Build-DiscordPayload -ChangesBySeverity $huge -MinSeverity 'Low'
        $p.embeds.Count | Should -BeLessOrEqual 10
    }

    It "respects 25-field-per-embed and 1024-char-per-value limits" {
        $huge = [ordered]@{
            High          = @(1..30 | ForEach-Object { @{ severity='High'; changeType='added'; description="git $_"; fileType='git'; old=$null; new=@{ id="x$_" } } })
            Medium        = @(); Low = @(); Informational = @(); Coverage = @(); Total = 30
        }
        $p = Build-DiscordPayload -ChangesBySeverity $huge -MinSeverity 'Low'
        foreach ($embed in $p.embeds) {
            if ($embed.ContainsKey('fields')) {
                $embed.fields.Count | Should -BeLessOrEqual 25
                foreach ($f in $embed.fields) {
                    $f.value.Length | Should -BeLessOrEqual 1024
                }
            }
        }
    }
}

Describe "Build-TeamsPayload" {
    It "uses Adaptive Card schema 1.6" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $p.attachments[0].content.version | Should -Be '1.6'
    }

    It "includes the tenant name as a subtitle when supplied" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        ($p.attachments[0].content.body | Where-Object { $_.text -like '*Tenant: Contoso*' }) | Should -Not -BeNullOrEmpty
    }

    It "renders an executive summary line referencing High severity" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        ($p.attachments[0].content.body | Where-Object { $_.text -like '*High-severity*' }) | Should -Not -BeNullOrEmpty
    }

    It "emits msteams.entities only when High changes AND MentionUpns are present" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -MentionUpns @('oncall@contoso.com')
        $p.attachments[0].content.msteams.entities.Count | Should -Be 1
        $p.attachments[0].content.msteams.entities[0].mentioned.id | Should -Be 'oncall@contoso.com'
    }

    It "does NOT emit msteams.entities when MentionUpns is empty" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $p.attachments[0].content.ContainsKey('msteams') | Should -BeFalse
    }

    It "does NOT emit msteams.entities when no High changes" {
        $lowOnly = @{
            High = @(); Medium = @(); Low = @(@{ severity='Low'; description='x'; fileType='git'; old=$null; new=@{} }); Informational = @(); Coverage = @(); Total = 1
        }
        $p = Build-TeamsPayload -ChangesBySeverity $lowOnly -MinSeverity 'Low' -MentionUpns @('oncall@contoso.com')
        $p.attachments[0].content.ContainsKey('msteams') | Should -BeFalse
    }

    It "renders a ColumnSet header (Property / actual / expected) for compliance diffs" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        $json | Should -Match '"text":\s*"Property"'
        $json | Should -Match '"text":\s*"actual"'
        $json | Should -Match '"text":\s*"expected"'
    }

    It "renders a ColumnSet header (Property / was / changed to) for git diffs" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $json = $p | ConvertTo-Json -Depth 20
        $json | Should -Match '"text":\s*"was"'
        $json | Should -Match '"text":\s*"changed to"'
    }

    It "groups sections under CHANGES and ACCESS MODEL parent headers" {
        $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $texts = @($p.attachments[0].content.body | Where-Object { $_.type -eq 'TextBlock' } | ForEach-Object { $_.text })
        $texts | Should -Contain 'CHANGES'
        $texts | Should -Contain 'ACCESS MODEL'
    }

    It "includes a View Diff action when CommitSha is supplied and CI URL inferable" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        try {
            $p = Build-TeamsPayload -ChangesBySeverity $script:fixture -MinSeverity 'Low' -CommitSha 'a1b2c3'
            $p.attachments[0].content.actions[0].title | Should -Be 'View Diff'
            $p.attachments[0].content.actions[0].url   | Should -BeLike '*a1b2c3*'
        } finally {
            $env:GITHUB_SERVER_URL = $null
            $env:GITHUB_REPOSITORY = $null
        }
    }
}
