#requires -Version 7
Set-StrictMode -Version Latest

<#
Regression: a ForEach-Object -Parallel block runs in its own runspace, where the functions of
src/*.ps1 are not loaded. On 2026-11-02 a call to Test-PermanentScheduleEntry inside such a block
made 14 roles fail with "The term ... is not recognized"; unit tests did not see it because they
call the function directly. This test reads the syntax tree: a project function may only be
called inside a -Parallel block when the block first defines it (${function:Name} = ...).
#>

BeforeAll {
    $script:srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '../src')

    function Get-SourceAst {
        Get-ChildItem -Path $script:srcPath -Filter '*.ps1' | ForEach-Object {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            [pscustomobject]@{ File = $_.Name; Ast = $ast }
        }
    }

    function Get-ParallelBlock {
        # Script blocks passed to -Parallel of ForEach-Object (or its alias foreach).
        param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast)
        $Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('ForEach-Object', 'foreach', '%')
            }, $true) | ForEach-Object {
            $elements = $_.CommandElements
            for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $element.ParameterName -like 'Parallel*' -and
                    $elements[$i + 1] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $elements[$i + 1].ScriptBlock
                }
            }
        }
    }

    $script:sources = @(Get-SourceAst)
    $script:projectFunctions = @($script:sources | ForEach-Object {
            $_.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name }
        } | Sort-Object -Unique)

    $script:violations = @(foreach ($source in $script:sources) {
            foreach ($block in @(Get-ParallelBlock -Ast $source.Ast)) {
                # Functions the block defines itself, as ${function:Name} = [scriptblock]::Create(...).
                $defined = @($block.FindAll({
                            param($n)
                            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $n.Left.VariablePath.DriveName -eq 'function'
                        }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath -replace '^function:', '' })

                $block.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                    Where-Object {
                        $name = $_.GetCommandName()
                        $name -and $name -in $script:projectFunctions -and $name -notin $defined
                    } |
                    ForEach-Object { '{0}:{1} {2}' -f $source.File, $_.Extent.StartLineNumber, $_.GetCommandName() }
            }
        })
}

Describe 'ForEach-Object -Parallel blocks' {
    It 'exist in src, so this test checks something' {
        @($script:sources | ForEach-Object { Get-ParallelBlock -Ast $_.Ast }).Count | Should -BeGreaterThan 0
    }

    It 'call no project function that the block does not define itself' {
        $script:violations | Should -BeNullOrEmpty -Because 'functions from src/*.ps1 are not loaded in a -Parallel runspace; call them after the block, or pass them in with $using: and ${function:Name} = [scriptblock]::Create(...)'
    }
}

Describe 'the check itself' {
    It 'finds a project function called inside a -Parallel block' {
        $code = @'
function Test-Thing { $true }
1..2 | ForEach-Object -Parallel { Test-Thing } -ThrottleLimit 5
'@
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
        $block = @(Get-ParallelBlock -Ast $ast)
        $block.Count | Should -Be 1
        @($block[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() }) | Should -Contain 'Test-Thing'
    }
}
