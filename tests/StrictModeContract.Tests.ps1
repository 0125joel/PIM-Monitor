#requires -Version 7
Set-StrictMode -Version Latest

<#
StrictMode canary tests — guards against the recurring PowerShell StrictMode pitfalls
documented in docs/LessonsLearned.md (entries from 2026-05-21).

All scripts in PIM Monitor run under Set-StrictMode -Version Latest. This file:
  1. Verifies every module loads cleanly under StrictMode.
  2. Exercises the edge cases that have bitten us before (see LessonsLearned.md):
       - Single-element array unwrap in if/else assignments
       - ConvertTo-DeterministicJson with single-element arrays
       - Group-ChangesBySeverity with empty and single-element collections
       - Notification payload builders with empty severity buckets

When adding a new StrictMode-sensitive function, add a canary It block here and reference
the LessonsLearned entry (or a new one if it's a new pattern).
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-shared.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-teams.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-slack.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook-discord.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-webhook.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-html.ps1")
    . (Join-Path -Path $srcPath -ChildPath "compliance.ps1")

    $script:emptyFixture = @{
        High          = @()
        Medium        = @()
        Low           = @()
        Informational = @()
        Coverage      = @()
        Total         = 0
    }

    $script:minimalFixture = @{
        High = @(
            @{ severity = 'High'; changeType = 'updated'; description = 'Test change'; context = 'Test Role'; fileType = 'definition'; old = 'before'; new = 'after' }
        )
        Medium        = @()
        Low           = @()
        Informational = @()
        Coverage      = @()
        Total         = 1
    }
}

# ─── 1. Module load under StrictMode ─────────────────────────────────────────

Describe "StrictMode — module load" {
    It "all src modules load without error under Set-StrictMode -Version Latest" {
        # BeforeAll already loaded all modules under StrictMode (file-level).
        # If we reached here, no top-level StrictMode violation fired.
        $true | Should -Be $true
    }
}

# ─── 2. Group-ChangesBySeverity — array-unwrap canary ────────────────────────
#
# LessonsLearned [2026-05-21]: $x = if (...) { @() } else { @() } may produce $null
# under StrictMode; .Count then throws. Group-ChangesBySeverity must handle edge cases.

Describe "StrictMode — Group-ChangesBySeverity with edge-case collections" {
    It "accepts empty array without throwing" {
        { Group-ChangesBySeverity -Changes @() } | Should -Not -Throw
    }

    It "returns correct totals for empty array" {
        $result = Group-ChangesBySeverity -Changes @()
        $result.Total | Should -Be 0
        @($result.High).Count | Should -Be 0
    }

    It "accepts single-element array without throwing (array-unwrap risk)" {
        $entry = @{ severity = 'High'; changeType = 'updated'; description = 'Test'; fileType = 'definition'; old = $null; new = $null }
        { Group-ChangesBySeverity -Changes @($entry) } | Should -Not -Throw
    }

    It "buckets single-element array correctly" {
        $entry = @{ severity = 'High'; changeType = 'updated'; description = 'Test'; fileType = 'definition'; old = $null; new = $null }
        $result = Group-ChangesBySeverity -Changes @($entry)
        $result.Total | Should -Be 1
        @($result.High).Count | Should -Be 1
    }

    It "routes access-model-coverage entry to Coverage bucket regardless of severity" {
        $covEntry = @{ severity = 'Medium'; changeType = 'unclassified'; description = 'Coverage'; fileType = 'access-model-coverage'; old = $null; new = $null }
        $result = Group-ChangesBySeverity -Changes @($covEntry)
        @($result.Coverage).Count | Should -Be 1
        @($result.Medium).Count | Should -Be 0
    }

    It "routes group-coverage entry to Coverage bucket regardless of severity" {
        $covEntry = @{ severity = 'Medium'; changeType = 'unclassified'; description = 'Coverage'; fileType = 'group-coverage'; old = $null; new = $null }
        $result = Group-ChangesBySeverity -Changes @($covEntry)
        @($result.Coverage).Count | Should -Be 1
        @($result.Medium).Count | Should -Be 0
    }
}

# ─── 3. ConvertTo-DeterministicJson — single-element array canary ─────────────
#
# LessonsLearned [2026-05-21]: single-element arrays may be unwrapped by ConvertTo-Json.
# ConvertTo-DeterministicJson uses unary comma to prevent this.

Describe "StrictMode — ConvertTo-DeterministicJson with single-element arrays" {
    It "preserves single-element arrays as JSON arrays, not bare objects" {
        # Verify the JSON output contains a proper array (not an unwrapped object).
        # ConvertFrom-Json unwraps single-element arrays on parse, so we check the JSON
        # string directly — the unary comma trick in Normalize prevents ConvertTo-Json unwrap.
        $input = @{ items = @( @{ id = "abc"; name = "test" } ) }
        $json = ConvertTo-DeterministicJson -InputObject $input
        $json | Should -Match '"items"\s*:\s*\[' -Because "single-element arrays must serialize as JSON arrays, not bare objects"
    }

    It "preserves empty arrays as arrays" {
        $input = @{ items = @() }
        $json = ConvertTo-DeterministicJson -InputObject $input
        # Empty array serializes as "[]" — verify round-trip produces array, not null
        $json | Should -Match '"items"\s*:\s*\[\s*\]'
    }

    It "does not throw on null input" {
        { ConvertTo-DeterministicJson -InputObject $null } | Should -Not -Throw
    }
}

# ─── 4. Notification payload builders — empty severity buckets canary ─────────
#
# LessonsLearned [2026-05-21]: Build-* functions must handle empty High/Medium/Low/Coverage
# buckets without .Count throws or array-unwrap under StrictMode.
# $script:emptyFixture and $script:minimalFixture are defined in the top-level BeforeAll.

Describe "StrictMode — Build-TeamsPayload with empty and minimal input" {
    It "does not throw with all-empty severity buckets" {
        { Build-TeamsPayload -ChangesBySeverity $script:emptyFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }

    It "does not throw with minimal single-entry input" {
        { Build-TeamsPayload -ChangesBySeverity $script:minimalFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }
}

Describe "StrictMode — Build-SlackPayload with empty and minimal input" {
    It "does not throw with all-empty severity buckets" {
        { Build-SlackPayload -ChangesBySeverity $script:emptyFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }

    It "does not throw with minimal single-entry input" {
        { Build-SlackPayload -ChangesBySeverity $script:minimalFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }
}

Describe "StrictMode — Build-DiscordPayload with empty and minimal input" {
    It "does not throw with all-empty severity buckets" {
        { Build-DiscordPayload -ChangesBySeverity $script:emptyFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }

    It "does not throw with minimal single-entry input" {
        { Build-DiscordPayload -ChangesBySeverity $script:minimalFixture -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }
}

Describe "StrictMode — Build-GenericPayload with empty and minimal input" {
    It "does not throw with all-empty severity buckets" {
        { Build-GenericPayload -ChangesBySeverity $script:emptyFixture -RelevantCount 0 -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }

    It "does not throw with minimal single-entry input" {
        { Build-GenericPayload -ChangesBySeverity $script:minimalFixture -RelevantCount 1 -MinSeverity 'Low' -CommitSha 'abc123' -TenantName 'Contoso' } | Should -Not -Throw
    }
}
