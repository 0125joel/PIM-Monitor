#requires -Version 7
<#
.SYNOPSIS
    Renders Build-HtmlReport with a synthetic fixture for visual review.

.DESCRIPTION
    Writes the HTML report to tests/output/scan-report.html. Includes various change types:
    git changes, compliance violations, coverage gaps. The report is opened in dark mode
    by default; use Ctrl+P in a browser to test print stylesheet and light-mode rendering.
    The view-tabs toggle between severity and entity views via anchor navigation.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Resolve-Path (Join-Path $PSScriptRoot '../../src')
. (Join-Path $src 'helpers.ps1')
. (Join-Path $src 'diff.ps1')
. (Join-Path $src 'notifications-shared.ps1')
. (Join-Path $src 'notifications-html.ps1')

# Synthetic fixture mimicking a realistic scan
$changes = [ordered]@{
    High          = @(
        @{
            severity    = 'High'
            changeType  = 'added'
            description = 'Directory Roles > Global Administrator > assignment'
            context     = 'Global Administrator'
            fileType    = 'git'
            roleId      = '62e90394-69f5-4237-9190-012177145e10'
            old         = $null
            new         = @{ principalId = 'abc123'; directoryScopeId = '/' }
        }
        @{
            severity    = 'High'
            changeType  = 'modified'
            description = 'Directory Roles > Privileged Role Administrator > policy'
            context     = 'Privileged Role Administrator'
            fileType    = 'git'
            old         = @{ requireMfa = $false; maxDuration = 'PT8H' }
            new         = @{ requireMfa = $true; maxDuration = 'PT2H' }
        }
        @{
            severity    = 'High'
            changeType  = 'modified'
            description = 'Tier-0 Admins (member) > authContext'
            context     = 'Tier-0 Admins'
            fileType    = 'access-model-compliance'
            old         = @{ authContext = 'none' }
            new         = @{ authContext = 'phish-resistant-sif' }
        }
    )
    Medium        = @(
        @{
            severity    = 'Medium'
            changeType  = 'modified'
            description = 'Directory Roles > Exchange Administrator > expiration'
            context     = 'Exchange Administrator'
            fileType    = 'git'
            old         = @{ maximumDuration = 'PT8H' }
            new         = @{ maximumDuration = 'PT4H' }
        }
        @{
            severity    = 'Medium'
            changeType  = 'added'
            description = 'PIM Groups > SOC Tier-1 > eligible member'
            context     = 'SOC Tier-1'
            fileType    = 'git'
            groupId     = '1f4a8d3b-2c1a-4f5c-9a45-1b6f9c6df0f2'
            old         = $null
            new         = @{ principalId = 'def456' }
        }
    )
    Low           = @()
    Informational = @()
    Coverage      = @()
    Total         = 5
}

# Set CI environment for evidence-links
$env:GITHUB_SERVER_URL = 'https://github.com'
$env:GITHUB_REPOSITORY = 'contoso/pim-monitor'
$env:REPORT_ARTIFACT   = 'true'
$env:GITHUB_RUN_ID     = '98765'

try {
    $html = Build-HtmlReport `
        -ChangesBySeverity $changes `
        -MinSeverity 'Low' `
        -CommitSha 'a1b2c3d4e5f6g7h8' `
        -CommitUrl 'https://github.com/contoso/pim-monitor/commit/a1b2c3d4e5f6g7h8' `
        -TenantId 'f5a5a5f5-a5f5-a5a5-a5f5-a5a5a5a5a5a5' `
        -TenantName 'Contoso Production'

    $outPath = Join-Path $PSScriptRoot '../output/scan-report.html'
    Set-Content -Path $outPath -Value $html -Encoding UTF8

    Write-Host "Preview written:     $outPath"
    Write-Host "Report size:         $($html.Length) chars"
    Write-Host "View-tabs enabled:   true (click 'By entity' to test toggle)"
    Write-Host "Evidence-links:      present for git changes"
    Write-Host ""
    Write-Host "Test in browser:"
    Write-Host "  1. Open the HTML file in Chrome/Firefox/Safari"
    Write-Host "  2. Default: severity-view visible, entity-view hidden"
    Write-Host "  3. Click 'By entity' tab → URL changes to #view-entity"
    Write-Host "  4. Entity view shows changes grouped by role/group name"
    Write-Host "  5. Click 'By severity' to toggle back"
    Write-Host "  6. Ctrl+P to test print stylesheet (light background, expanded details)"

} finally {
    $env:GITHUB_SERVER_URL = $null
    $env:GITHUB_REPOSITORY = $null
    $env:REPORT_ARTIFACT   = $null
    $env:GITHUB_RUN_ID     = $null
}
