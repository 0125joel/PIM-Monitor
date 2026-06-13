#requires -Version 7
<#
.SYNOPSIS
    Renders Build-EmailChangeHtml against a synthetic fixture for visual review.

.DESCRIPTION
    Writes the result to tests/output/email-preview.html so reviewers can open it in
    Chrome / Outlook Web / Apple Mail and toggle system dark mode. Also prints the
    subject line that Build-EmailSubject would generate for the same fixture.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Resolve-Path (Join-Path $PSScriptRoot '../../src')
. (Join-Path $src 'helpers.ps1')
. (Join-Path $src 'diff.ps1')
. (Join-Path $src 'notifications-shared.ps1')
. (Join-Path $src 'notifications-email.ps1')

$changes = [ordered]@{
    High          = @(
        @{ severity='High'; changeType='added'; description='Directory Roles > Global Administrator > assignment'; context='Global Administrator'; fileType='git'; old=$null; new=@{ principalId='abc123'; directoryScopeId='/' } }
        @{ severity='High'; changeType='modified'; description='Directory Roles > Privileged Role Administrator > policy (rule change)'; context='Privileged Role Administrator'; fileType='git'; old=@{ requireMfa=$false; maxDuration='PT8H' }; new=@{ requireMfa=$true; maxDuration='PT2H' } }
        @{ severity='High'; changeType='modified'; description='Tier-0 Admins (member) > authContext'; context='Tier-0 Admins'; fileType='access-model-compliance'; old=@{ authContext='none' }; new=@{ authContext='phish-resistant-sif' } }
    )
    Medium        = @(
        @{ severity='Medium'; changeType='modified'; description='Directory Roles > Exchange Administrator > expiration'; context='Exchange Administrator'; fileType='git'; old=@{ maximumDuration='PT8H' }; new=@{ maximumDuration='PT4H' } }
        @{ severity='Medium'; changeType='added'; description='PIM Groups > SOC Tier-1 > eligible member'; context='SOC Tier-1'; fileType='git'; old=$null; new=@{ principalId='def456'; startDateTime='2026-05-21T00:00:00Z' } }
    )
    Low           = @(
        @{ severity='Low'; changeType='modified'; description='Directory Roles > Helpdesk Administrator > description'; context='Helpdesk Administrator'; fileType='git'; old='Old description text'; new='New description text v2' }
    )
    Informational = @()
    Coverage      = @(
        @{ severity='Informational'; context='Attack Payload Author'; entity='9c6df0f2-1b6f-4f5c-9a45-1f4a8d3b2c1a'; fileType='coverage'; description='Role not in any access model' }
    )
    Total         = 7
}

$html = Build-EmailChangeHtml `
    -ChangesBySeverity $changes `
    -MinSeverity 'Low' `
    -CommitUrl 'https://github.com/example/repo/commit/a1b2c3d4e5' `
    -TenantName 'Contoso Demo'

$outPath = Join-Path $PSScriptRoot '../output/email-preview.html'
Set-Content -Path $outPath -Value $html -Encoding UTF8

$relevantCount = ($changes.High.Count + $changes.Medium.Count + $changes.Low.Count + $changes.Informational.Count + $changes.Coverage.Count)
$subject = Build-EmailSubject `
    -ChangesBySeverity $changes `
    -RelevantCount $relevantCount `
    -CoverageCount $changes.Coverage.Count `
    -TenantName 'Contoso Demo'

Write-Host "Preview written: $outPath"
Write-Host "Subject:          $subject"
Write-Host "Body size:        $($html.Length) chars"
