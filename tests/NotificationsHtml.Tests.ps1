#requires -Version 7
Set-StrictMode -Version Latest

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-shared.ps1")
    . (Join-Path -Path $srcPath -ChildPath "notifications-html.ps1")
}

Describe "Get-ChangeInventoryPath" {
    It "derives path for directory-role policy change" {
        $change = @{
            context   = 'Global Administrator'
            description = 'Directory Roles > policy update'
            fileType  = 'git'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -Be 'inventory/directory-roles/global-administrator/policy.json'
    }

    It "derives path for directory-role assignment change" {
        $change = @{
            context   = 'Exchange Administrator'
            description = 'eligible member assignment added'
            fileType  = 'git'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -Be 'inventory/directory-roles/exchange-administrator/assignments.json'
    }

    It "derives path for PIM group changes" {
        $change = @{
            context   = 'SOC Tier-1'
            description = 'PIM Groups > member policy'
            fileType  = 'git'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -Be 'inventory/pim-groups/soc-tier-1/policy.json'
    }

    It "returns null for compliance violations" {
        $change = @{
            context   = 'Some Role'
            description = 'compliance violation'
            fileType  = 'access-model-compliance'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -BeNullOrEmpty
    }

    It "returns null for coverage items" {
        $change = @{
            context   = 'Some Role'
            description = 'coverage gap'
            fileType  = 'coverage'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -BeNullOrEmpty
    }

    It "returns null when context is empty" {
        $change = @{
            context   = ''
            description = 'some change'
            fileType  = 'git'
        }
        $path = Get-ChangeInventoryPath -Change $change
        $path | Should -BeNullOrEmpty
    }
}

Describe "Build-HtmlReport" {
    BeforeEach {
        $env:GITHUB_SERVER_URL = $null
        $env:GITHUB_REPOSITORY = $null
    }

    It "includes view-tabs navigation" {
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='x'; context='Role X'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'class="view-tabs"'
        $html | Should -Match 'href="#view-severity"'
        $html | Should -Match 'href="#view-entity"'
    }

    It "includes both severity-view and entity-view sections" {
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='x'; context='Role Y'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'id="view-severity"'
        $html | Should -Match 'id="view-entity"'
        $html | Should -Match 'class="severity-view"'
        $html | Should -Match 'class="entity-view"'
    }

    It "groups changes by entity in entity-view" {
        $changes = @{
            High = @(
                @{ severity='High'; changeType='added'; description='change 1'; context='Global Admin'; fileType='git'; old=$null; new=@{} }
                @{ severity='High'; changeType='modified'; description='change 2'; context='Global Admin'; fileType='git'; old=@{}; new=@{} }
                @{ severity='High'; changeType='added'; description='change 3'; context='Exchange Admin'; fileType='git'; old=$null; new=@{} }
            )
            Medium = @(); Low = @(); Informational = @(); Total = 3
        }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'entity-block'
        # Both entities should appear in entity-view section
        $entityView = $html -replace '.*id="view-entity"' -replace '</section>.*' -replace 's'
        $entityView | Should -Match 'Global Admin'
        $entityView | Should -Match 'Exchange Admin'
    }

    It "renders evidence-links when CI environment is set" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='Directory Roles > policy'; context='Role X'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low' -CommitSha 'a1b2c3d4'
        $html | Should -Match 'ev-block'
        $html | Should -Match 'ev-link'
        $html | Should -Match 'view file'
        $html | Should -Match 'view diff'
    }

    It "omits evidence-links when CI environment is not set" {
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='x'; context='Role X'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Not -Match '<div class="ev-block">'
        $html | Should -Not -Match 'view file'
        $html | Should -Not -Match 'view diff'
    }

    It "omits evidence-links for compliance violations" {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'acme/pim'
        $changes = @{
            High = @(@{ severity='High'; changeType='non-compliant'; description='compliance issue'; context='Role X'; fileType='access-model-compliance'; old=@{}; new=@{} })
            Medium = @(); Low = @(); Informational = @(); Total = 1
        }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low' -CommitSha 'a1b2c3d4'
        $html | Should -Not -Match '<div class="ev-block">'
    }

    It "includes print stylesheet with @media print rules" {
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='x'; context='Role X'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match '@media print'
        $html | Should -Match 'background:#ffffff!important'
        $html | Should -Match 'color:#18181b!important'
        $html | Should -Match 'page-break'
    }

    It "renders meta data section with timestamp" {
        $changes = @{ High = @(); Medium = @(); Low = @(); Informational = @(); Total = 0 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'scan metadata'
        $html | Should -Match 'scan time'
        $html | Should -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'
    }

    It "includes tenant name when supplied" {
        $changes = @{ High = @(); Medium = @(); Low = @(); Informational = @(); Total = 0 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low' -TenantName 'Contoso'
        $html | Should -Match 'Contoso'
    }

    It "renders severity bar with proportional segments" {
        $changes = @{ High = @(@{}, @{}); Medium = @(@{}); Low = @(); Informational = @(); Total = 3 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'sev-bar'
        $html | Should -Match '#ef4444'  # red for High
        $html | Should -Match '#d97706'  # amber for Medium
    }

    It "declares lang=en on html element" {
        $changes = @{ High = @(); Medium = @(); Low = @(); Informational = @(); Total = 0 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match '<html lang="en">'
    }

    It "renders Coverage items under Access Model > Coverage sub-label" {
        $changes = @{
            High = @(); Medium = @(); Low = @(); Informational = @()
            Coverage = @(@{ severity='Informational'; context='Attack Payload Author'; entity='abc'; fileType='coverage'; description='Role not in any access model' })
            Total = 1
        }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        # Parent section header
        $html | Should -Match '<div class="pm-section-hd">Access Model</div>'
        # Sub-label with count
        $html | Should -Match '<div class="pm-sub-lbl">Coverage \(1\)</div>'
        $html | Should -Match 'Attack Payload Author'
    }

    It "renders Changes parent section header when git changes present" {
        $changes = @{ High = @(@{ severity='High'; changeType='added'; description='x'; context='Role X'; fileType='git'; old=$null; new=@{} }); Medium = @(); Low = @(); Informational = @(); Total = 1 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match '<div class="pm-section-hd">Changes</div>'
    }

    It "renders Access Model > Compliance sub-label for compliance items" {
        $changes = @{
            High = @(@{ severity='High'; changeType='non-compliant'; description='x'; context='Role X'; fileType='access-model-compliance'; old=@{}; new=@{} })
            Medium = @(); Low = @(); Informational = @(); Total = 1
        }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match '<div class="pm-section-hd">Access Model</div>'
        $html | Should -Match '<div class="pm-sub-lbl">Compliance</div>'
    }

    It "renders Coverage items in entity-view under their entity context" {
        $changes = @{
            High = @(); Medium = @(); Low = @(); Informational = @()
            Coverage = @(@{ severity='Informational'; context='Unclassified Role X'; fileType='coverage'; description='Role not in any access model' })
            Total = 1
        }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        # Entity-view section should mention the unclassified role
        $entityViewSection = ($html -split 'id="view-entity"')[1]
        $entityViewSection | Should -Match 'Unclassified Role X'
        $entityViewSection | Should -Match 'Coverage: 1'
    }

    It "prints all http link URLs in print stylesheet" {
        $changes = @{ High = @(); Medium = @(); Low = @(); Informational = @(); Total = 0 }
        $html = Build-HtmlReport -ChangesBySeverity $changes -MinSeverity 'Low'
        $html | Should -Match 'a\[href\^="http"\]::after'
        $html | Should -Match 'a\[href\^="#"\]::after\{content:none\}'
    }
}
