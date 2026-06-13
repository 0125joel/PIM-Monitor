#requires -Version 7
Set-StrictMode -Version Latest

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-shared.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-email.ps1")
}

Describe "Get-InventoryFileUrl" {
    BeforeEach {
        $env:BUILD_REPOSITORY_URI = $null
        $env:GITHUB_SERVER_URL    = $null
        $env:GITHUB_REPOSITORY    = $null
    }

    It "returns null when no CI platform env vars are present" {
        Get-InventoryFileUrl -RelativePath 'inventory/x.json' -CommitSha 'abc' | Should -BeNullOrEmpty
    }

    It "returns null when RelativePath is blank" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        Get-InventoryFileUrl -RelativePath '   ' -CommitSha 'abc' | Should -BeNullOrEmpty
    }

    It "builds a GitHub blob URL with commit SHA" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        Get-InventoryFileUrl -RelativePath 'inventory/directory-roles/global-administrator/policy.json' -CommitSha 'a1b2c3' |
            Should -Be 'https://github.com/acme/pim/blob/a1b2c3/inventory/directory-roles/global-administrator/policy.json'
    }

    It "falls back to main when CommitSha omitted on GitHub" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        Get-InventoryFileUrl -RelativePath 'inventory/x.json' | Should -Be 'https://github.com/acme/pim/blob/main/inventory/x.json'
    }

    It "builds an Azure DevOps URL with GCcommit version" {
        $env:BUILD_REPOSITORY_URI = 'https://dev.azure.com/contoso/PIM/_git/pim-monitor'
        $url = Get-InventoryFileUrl -RelativePath 'inventory/x.json' -CommitSha 'a1b2c3'
        $url | Should -BeLike 'https://dev.azure.com/contoso/PIM/_git/pim-monitor?path=/inventory/x.json&version=GCa1b2c3'
    }

    It "strips username@ prefix from Azure DevOps repo URI" {
        $env:BUILD_REPOSITORY_URI = 'https://user@dev.azure.com/contoso/PIM/_git/pim-monitor'
        $url = Get-InventoryFileUrl -RelativePath 'inventory/x.json' -CommitSha 'abc'
        $url | Should -BeLike 'https://dev.azure.com/contoso/*'
    }
}

Describe "Get-FileDiffUrl" {
    BeforeEach {
        $env:BUILD_REPOSITORY_URI = $null
        $env:GITHUB_SERVER_URL    = $null
        $env:GITHUB_REPOSITORY    = $null
    }

    It "returns null when no CI platform env vars are present" {
        Get-FileDiffUrl -CommitSha 'abc' -RelativePath 'inventory/x.json' | Should -BeNullOrEmpty
    }

    It "returns null when RelativePath is blank" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        Get-FileDiffUrl -CommitSha 'abc' -RelativePath '   ' | Should -BeNullOrEmpty
    }

    It "builds a GitHub commit URL with sha256 file anchor" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $url = Get-FileDiffUrl -CommitSha 'a1b2c3' -RelativePath 'inventory/directory-roles/global-administrator/policy.json'
        $url | Should -BeLike 'https://github.com/acme/pim/commit/a1b2c3#diff-*'
        # SHA-256 hex is 64 chars
        $url | Should -Match '#diff-[0-9a-f]{64}$'
    }

    It "produces a deterministic GitHub anchor for the same path" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $u1 = Get-FileDiffUrl -CommitSha 'sha1' -RelativePath 'inventory/x.json'
        $u2 = Get-FileDiffUrl -CommitSha 'sha2' -RelativePath 'inventory/x.json'
        ($u1 -split '#')[1] | Should -Be (($u2 -split '#')[1])
    }

    It "produces different anchors for different paths" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $u1 = Get-FileDiffUrl -CommitSha 'sha' -RelativePath 'inventory/x.json'
        $u2 = Get-FileDiffUrl -CommitSha 'sha' -RelativePath 'inventory/y.json'
        ($u1 -split '#')[1] | Should -Not -Be (($u2 -split '#')[1])
    }

    It "builds an Azure DevOps file-diff URL" {
        $env:BUILD_REPOSITORY_URI = 'https://dev.azure.com/contoso/PIM/_git/pim-monitor'
        $url = Get-FileDiffUrl -CommitSha 'a1b2c3' -RelativePath 'inventory/x.json'
        $url | Should -BeLike 'https://dev.azure.com/contoso/PIM/_git/pim-monitor/commit/a1b2c3*'
        $url | Should -Match 'path=.*inventory.*x\.json'
        $url | Should -Match '_a=compare'
    }

    It "strips username@ prefix from Azure DevOps repo URI in diff URL" {
        $env:BUILD_REPOSITORY_URI = 'https://user@dev.azure.com/contoso/PIM/_git/pim-monitor'
        $url = Get-FileDiffUrl -CommitSha 'abc' -RelativePath 'inventory/x.json'
        $url | Should -BeLike 'https://dev.azure.com/contoso/*'
        $url | Should -Not -Match '@'
    }
}

Describe "Build-EmailSubject" {
    It "leads with HIGH when High changes are present" {
        $changes = @{
            High          = @(@{ severity='High'   }, @{ severity='High' })
            Medium        = @(@{ severity='Medium' })
            Low           = @()
            Informational = @()
        }
        Build-EmailSubject -ChangesBySeverity $changes -RelevantCount 3 -CoverageCount 0 -TenantName 'Contoso' |
            Should -BeLike '*HIGH severity*'
    }

    It "includes tenant name in the subject when supplied" {
        $changes = @{ High=@(@{}); Medium=@(); Low=@(); Informational=@() }
        $subject = Build-EmailSubject -ChangesBySeverity $changes -RelevantCount 1 -CoverageCount 0 -TenantName 'Contoso'
        $subject | Should -BeLike '*Contoso*'
    }

    It "omits tenant name and uses generic prefix when not supplied" {
        $changes = @{ High=@(); Medium=@(@{}); Low=@(); Informational=@() }
        $subject = Build-EmailSubject -ChangesBySeverity $changes -RelevantCount 1 -CoverageCount 0
        $subject.StartsWith('[PIM Monitor] ') | Should -BeTrue
        $subject | Should -Not -BeLike '*Contoso*'
    }

    It "falls back to CLASSIFICATION when only coverage is present" {
        $changes = @{ High=@(); Medium=@(); Low=@(); Informational=@() }
        Build-EmailSubject -ChangesBySeverity $changes -RelevantCount 2 -CoverageCount 2 -TenantName 'Contoso' |
            Should -BeLike '*CLASSIFICATION severity*'
    }

    It "uses singular 'change' for count of 1" {
        $changes = @{ High=@(@{}); Medium=@(); Low=@(); Informational=@() }
        Build-EmailSubject -ChangesBySeverity $changes -RelevantCount 1 -CoverageCount 0 |
            Should -BeLike '*1 change*'
    }
}

Describe "Get-ExecutiveSummaryLine" {
    It "leads with High when High changes are present" {
        $c = @{ High=@(@{},@{},@{}); Medium=@(); Low=@(); Informational=@() }
        Get-ExecutiveSummaryLine -ChangesBySeverity $c -TenantName 'Contoso' |
            Should -BeLike '3 High-severity*Contoso*'
    }

    It "leads with Medium when no High but Medium present" {
        $c = @{ High=@(); Medium=@(@{},@{}); Low=@(); Informational=@() }
        Get-ExecutiveSummaryLine -ChangesBySeverity $c |
            Should -BeLike '2 Medium-severity*'
    }

    It "uses neutral phrasing when only Low / Info / Coverage" {
        $c = @{ High=@(); Medium=@(); Low=@(@{}); Informational=@(); Coverage=@(@{}) }
        Get-ExecutiveSummaryLine -ChangesBySeverity $c -TenantName 'Contoso' |
            Should -BeLike '*none at High severity*'
    }

    It "reports scan complete on zero changes" {
        $c = @{ High=@(); Medium=@(); Low=@(); Informational=@() }
        Get-ExecutiveSummaryLine -ChangesBySeverity $c |
            Should -BeLike '*no qualifying changes*'
    }

    It "omits tenant clause when TenantName not supplied" {
        $c = @{ High=@(@{}); Medium=@(); Low=@(); Informational=@() }
        $line = Get-ExecutiveSummaryLine -ChangesBySeverity $c
        $line | Should -Not -Match 'in tenant'
    }
}

Describe "ConvertTo-ChangePayloadObject" {
    It "maps required fields" {
        $c = @{ severity='High'; changeType='added'; fileType='git'; description='x' }
        $o = ConvertTo-ChangePayloadObject -Change $c
        $o.severity    | Should -Be 'High'
        $o.changeType  | Should -Be 'added'
        $o.fileType    | Should -Be 'git'
        $o.description | Should -Be 'x'
    }
    It "includes context/roleId/groupId only when present" {
        $c1 = @{ severity='High'; changeType='added'; fileType='git'; description='x'; context='Role X'; roleId='abc' }
        $o1 = ConvertTo-ChangePayloadObject -Change $c1
        $o1.Contains('context') | Should -BeTrue
        $o1.Contains('roleId')  | Should -BeTrue
        $o1.Contains('groupId') | Should -BeFalse

        $c2 = @{ severity='Low'; changeType='modified'; fileType='git'; description='y' }
        $o2 = ConvertTo-ChangePayloadObject -Change $c2
        $o2.Contains('context') | Should -BeFalse
        $o2.Contains('roleId')  | Should -BeFalse
        $o2.Contains('groupId') | Should -BeFalse
    }
}

Describe "Get-ScanMetadata" {
    It "always includes timestamp and minSeverity" {
        $m = Get-ScanMetadata -MinSeverity 'Low'
        $m.timestamp   | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $m.minSeverity | Should -Be 'Low'
        $m.Contains('commitSha') | Should -BeFalse
    }
    It "includes commitSha when supplied" {
        $m = Get-ScanMetadata -CommitSha 'a1b2c3' -MinSeverity 'Medium'
        $m.commitSha | Should -Be 'a1b2c3'
    }
}

Describe "Get-SeverityColorInt" {
    It "returns red for High" {
        Get-SeverityColorInt -Severity 'High' | Should -Be 15684676
    }
    It "returns amber for Medium" {
        Get-SeverityColorInt -Severity 'Medium' | Should -Be 14251270
    }
    It "returns green for Low" {
        Get-SeverityColorInt -Severity 'Low' | Should -Be 2278750
    }
    It "returns zinc-light for Informational" {
        Get-SeverityColorInt -Severity 'Informational' | Should -Be 7566195
    }
    It "returns zinc-mid for Coverage" {
        Get-SeverityColorInt -Severity 'Coverage' | Should -Be 5395026
    }
    It "returns amber for AccessModel parent" {
        Get-SeverityColorInt -Severity 'AccessModel' | Should -Be 14251270
    }
    It "falls back to zinc-light for unknown labels" {
        Get-SeverityColorInt -Severity 'Bogus' | Should -Be 7566195
    }
}

Describe "Get-ArtifactReportUrl" {
    BeforeEach {
        $env:REPORT_ARTIFACT                       = $null
        $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI    = $null
        $env:SYSTEM_TEAMPROJECT                    = $null
        $env:BUILD_BUILDID                         = $null
        $env:GITHUB_SERVER_URL                     = $null
        $env:GITHUB_REPOSITORY                     = $null
        $env:GITHUB_RUN_ID                         = $null
    }

    It "returns null when REPORT_ARTIFACT is not 'true'" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $env:GITHUB_RUN_ID     = '99'
        Get-ArtifactReportUrl | Should -BeNullOrEmpty
    }

    It "returns null when REPORT_ARTIFACT enabled but no CI env present" {
        $env:REPORT_ARTIFACT = 'true'
        Get-ArtifactReportUrl | Should -BeNullOrEmpty
    }

    It "builds Azure DevOps build-results URL" {
        $env:REPORT_ARTIFACT                    = 'true'
        $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI = 'https://dev.azure.com/contoso/'
        $env:SYSTEM_TEAMPROJECT                 = 'PIM'
        $env:BUILD_BUILDID                      = '12345'
        $url = Get-ArtifactReportUrl
        $url | Should -Match 'dev\.azure\.com/contoso/PIM/_build/results\?buildId=12345'
        $url | Should -Match 'publishedArtifacts'
    }

    It "builds GitHub Actions run-page URL" {
        $env:REPORT_ARTIFACT   = 'true'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $env:GITHUB_RUN_ID     = '789'
        Get-ArtifactReportUrl | Should -Be 'https://github.com/acme/pim/actions/runs/789'
    }
}

Describe "Build-EmailChangeHtml" {
    BeforeAll {
        $script:fixture = @{
            High          = @(@{ severity='High'; changeType='added'; description='Role X assignment'; context='Role X'; fileType='git'; old=$null; new=@{ id='abc' } })
            Medium        = @()
            Low           = @()
            Informational = @()
            Coverage      = @()
            Total         = 1
        }
    }

    It "includes a hidden preheader span" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low' -TenantName 'Contoso'
        $html | Should -Match 'display:none!important'
        $html | Should -Match 'detected in Contoso'
    }

    It "renders dark-mode media query and Outlook.com selector" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Match '@media \(prefers-color-scheme: dark\)'
        $html | Should -Match '\[data-ogsc\]'
    }

    It "renders bulletproof button with VML when CommitUrl supplied" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low' -CommitUrl 'https://example.com/commit/abc'
        $html | Should -Match 'v:roundrect'
        $html | Should -Match 'mso\]'
        $html | Should -Match 'href="https://example\.com/commit/abc"'
    }

    It "omits the button block entirely when CommitUrl is null" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Not -Match 'v:roundrect'
    }

    It "does not emit <details> elements (Outlook-unfriendly)" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Not -Match '<details'
        $html | Should -Not -Match '<summary'
    }

    It "declares lang=en on <html>" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Match '<html lang="en">'
    }

    It "marks layout tables with role=presentation" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Match 'role="presentation"'
    }

    It "renders an executive summary line that mentions the High count" {
        $html = Build-EmailChangeHtml -ChangesBySeverity $script:fixture -MinSeverity 'Low'
        $html | Should -Match '1 High-severity'
    }
}
