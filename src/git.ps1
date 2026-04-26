<#
.SYNOPSIS
    Git operations for PIM Monitor — commit and push inventory changes.

.DESCRIPTION
    Stages inventory/ folder, commits changes with timestamp, and pushes to origin.
    Only commits if files have actually changed.
#>

<#
.SYNOPSIS
    Commits and pushes inventory changes to the repository.

.DESCRIPTION
    Stages inventory/ folder and expected-changes.json (if modified/deleted),
    checks for changes, commits with timestamp message, and pushes to the current branch.

    Returns: @{ committed = $true/false; message = "..."; commitSha = "..." }

.EXAMPLE
    $result = Publish-InventoryChanges
    if ($result.committed) { Write-Host "Pushed $($result.commitSha)" }
#>
function Publish-InventoryChanges {
    [CmdletBinding()]
    param()

    $timestamp = Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ"

    try {
        # Configure git (required for commits in pipelines)
        Write-Host "Configuring git user"
        git config user.name "PIM Monitor" | Out-Null
        git config user.email "pim-monitor@pipeline" | Out-Null

        # Stage inventory changes
        Write-Host "Staging inventory/ folder"
        git add inventory/ | Out-Null

        # Stage expected-changes.json cleanup (modified or deleted by the scan)
        $expectedChangesPath = Join-Path -Path (Get-Location) -ChildPath "expected-changes.json"
        if (Test-Path $expectedChangesPath) {
            git add expected-changes.json | Out-Null
        }
        else {
            git rm --cached --ignore-unmatch expected-changes.json | Out-Null
        }

        # Check if there are changes to commit
        $statusOutput = git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            # No changes
            Write-Host "No inventory changes detected"
            return @{
                committed = $false
                message   = "No changes to commit"
                commitSha = $null
            }
        }

        # Commit changes
        $commitMessage = "scan: $timestamp"
        Write-Host "Committing: $commitMessage"
        git commit -m $commitMessage | Out-Null

        # Get commit SHA
        $commitSha = git rev-parse HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve commit SHA"
        }

        # Push to origin — retry once with rebase if remote has moved forward
        Write-Host "Pushing to origin"
        git push origin HEAD:main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Push rejected — fetching origin/main and rebasing"
            git fetch origin main 2>&1 | Out-Null
            git rebase origin/main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Rebase failed after fetch — manual intervention required"
            }
            git push origin HEAD:main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Push failed after rebase"
            }
        }

        # Re-read SHA after potential rebase
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
