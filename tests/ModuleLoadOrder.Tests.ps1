#requires -Version 7
Set-StrictMode -Version Latest

<#
Load-order contract test: verifies that Scan-PimState.ps1 dot-sources modules in the
required dependency order.

Rule: helpers.ps1 must be sourced before diff.ps1, because diff.ps1 calls
ConvertTo-DeterministicJson (defined in helpers.ps1) at module level via Test-ObjectEqual.

A runtime guard in diff.ps1 already throws on incorrect load order; this test catches
the violation at development time, before the script reaches production.
#>

BeforeAll {
    $srcPath     = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    $orchestrator = Join-Path $srcPath "Scan-PimState.ps1"

    # Parse the orchestrator and extract the dot-source order.
    # Returns an ordered list of basenames for all dot-sourced files.
    function Get-DotSourceOrder {
        param([Parameter(Mandatory)] [string] $FilePath)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$null)

        # Dot-source statements are CommandAst nodes with InvocationOperator = Dot.
        $dotSources = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
        }, $true)

        $order = [System.Collections.Generic.List[string]]::new()
        foreach ($ds in $dotSources) {
            # Convert the whole CommandAst to string, then extract the .ps1 basename.
            # Example: `. (Join-Path -Path $PSScriptRoot -ChildPath "helpers.ps1")`
            $text = $ds.ToString()
            if ($text -match '"([^/\\]+\.ps1)"') {
                $order.Add($Matches[1])
            }
        }

        return @($order)
    }

    $script:loadOrder = Get-DotSourceOrder -FilePath $orchestrator
}

Describe "Module load order — helpers.ps1 before diff.ps1" {
    It "Scan-PimState.ps1 dot-sources helpers.ps1 before diff.ps1" {
        $helpersIdx = [array]::IndexOf($script:loadOrder, "helpers.ps1")
        $diffIdx    = [array]::IndexOf($script:loadOrder, "diff.ps1")

        $helpersIdx | Should -BeGreaterOrEqual 0 -Because "helpers.ps1 must be dot-sourced"
        $diffIdx    | Should -BeGreaterOrEqual 0 -Because "diff.ps1 must be dot-sourced"
        $helpersIdx | Should -BeLessThan $diffIdx -Because "helpers.ps1 must come before diff.ps1 (diff.ps1 depends on ConvertTo-DeterministicJson)"
    }

    It "notifications-shared.ps1 is sourced before all notifications-webhook-*.ps1 files" {
        $sharedIdx = [array]::IndexOf($script:loadOrder, "notifications-shared.ps1")
        $sharedIdx | Should -BeGreaterOrEqual 0

        $webhookFiles = $script:loadOrder | Where-Object { $_ -match '^notifications-webhook-\w+\.ps1$' }
        foreach ($file in $webhookFiles) {
            $idx = [array]::IndexOf($script:loadOrder, $file)
            $idx | Should -BeGreaterThan $sharedIdx `
                -Because "notifications-shared.ps1 must be sourced before $file"
        }
    }

    It "notifications-webhook-<platform>.ps1 files are sourced before notifications-webhook.ps1 (the dispatcher)" {
        $dispatcherIdx = [array]::IndexOf($script:loadOrder, "notifications-webhook.ps1")
        $dispatcherIdx | Should -BeGreaterOrEqual 0

        $platformFiles = $script:loadOrder | Where-Object { $_ -match '^notifications-webhook-\w+\.ps1$' }
        foreach ($file in $platformFiles) {
            $idx = [array]::IndexOf($script:loadOrder, $file)
            $idx | Should -BeLessThan $dispatcherIdx `
                -Because "$file must be sourced before notifications-webhook.ps1 (dispatcher calls platform builders)"
        }
    }
}

Describe "Module load order — runtime guard fires on wrong order" {
    It "diff.ps1 guard throws when helpers.ps1 is not loaded first" {
        $diffPath = Join-Path (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")) "diff.ps1"

        # Run in a fresh process so we don't pollute the current scope
        $result = pwsh -NoProfile -NonInteractive -Command @"
Set-StrictMode -Version Latest
try {
    . '$($diffPath -replace "'", "''")'
    Write-Output 'no-throw'
} catch {
    Write-Output "threw: `$_"
}
"@

        $result | Should -Match "requires helpers.ps1" `
            -Because "diff.ps1 must throw a clear message when ConvertTo-DeterministicJson is not available"
    }
}
