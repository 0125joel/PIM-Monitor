<#
    .SYNOPSIS
        Commits staged inventory changes and pushes them to the remote branch.

    .DESCRIPTION
        Stages inventory/ and expected-changes.json (if present), commits with a timestamped
        message, and pushes to the current branch. If the push is rejected because another
        pipeline run pushed concurrently, it fetches the remote branch and rebases before
        retrying the push. The commit SHA is re-read after rebase because it changes.

        Reads the target branch from BUILD_SOURCEBRANCHNAME (ADO) or GITHUB_REF_NAME (GHA),
        falling back to 'main'.

    .EXAMPLE
        $result = Publish-InventoryChanges
        if ($result.committed) { Write-Host "Committed: $($result.commitSha)" }
    #>
function Publish-InventoryChanges {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('inventory/', 'Commit and push inventory changes')) { return }

    $timestamp = Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ"

    try {
        git config user.name "PIM Monitor" | Out-Null
        git config user.email "pim-monitor@noreply.github.com" | Out-Null

        git add inventory/ | Out-Null

        $expectedChangesPath = Join-Path -Path (Get-Location) -ChildPath "expected-changes.json"
        if (Test-Path $expectedChangesPath) {
            git add expected-changes.json | Out-Null
        }
        else {
            git rm --cached --ignore-unmatch expected-changes.json | Out-Null
        }

        $statusOutput = git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No inventory changes detected"
            return @{
                committed = $false
                message   = "No changes to commit"
                commitSha = $null
            }
        }

        $commitMessage = "scan: $timestamp"
        Write-Host "Committing: $commitMessage"
        git commit -m $commitMessage | Out-Null

        $commitSha = git rev-parse HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve commit SHA"
        }

        # ADO sets BUILD_SOURCEBRANCHNAME; GHA sets GITHUB_REF_NAME
        $targetBranch = if ($env:BUILD_SOURCEBRANCHNAME) {
            $env:BUILD_SOURCEBRANCHNAME
        } elseif ($env:GITHUB_REF_NAME) {
            $env:GITHUB_REF_NAME
        } else {
            'main'
        }

        # Retry once with rebase if another pipeline run pushed while this one was scanning
        Write-Host "Pushing to origin/$targetBranch"
        git push origin "HEAD:$targetBranch" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Push rejected — fetching origin/$targetBranch and rebasing"
            git fetch origin $targetBranch 2>&1 | Out-Null
            git rebase "origin/$targetBranch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Rebase failed after fetch — manual intervention required"
            }
            git push origin "HEAD:$targetBranch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Push failed after rebase"
            }
        }

        # Re-read SHA: rebase may have changed it
        $commitSha = git rev-parse HEAD

        Write-Host "Changes published successfully"
        return @{
            committed = $true
            message   = $commitMessage
            commitSha = $commitSha.Trim()
        }
    }
    catch {
        Write-Error "Failed to publish inventory changes: $_"
        throw
    }
}
