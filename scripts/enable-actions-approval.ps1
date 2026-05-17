<#
.SYNOPSIS
  Enable "Allow GitHub Actions to create and approve pull requests" on every active repo.

.DESCRIPTION
  GitHub Actions cannot approve PRs unless the repo's workflow-permissions
  setting `can_approve_pull_request_reviews` is true. This setting defaults
  to FALSE on new repos, so the auto-approve bot's review call gets rejected
  silently and the workflow can fail at startup with no readable log.

  This script PATCHes the setting to true on every active repo. Idempotent.

.PARAMETER Owner
  GitHub account whose repos receive the update. Default: aks-builds.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.EXAMPLE
  ./enable-actions-approval.ps1 -DryRun

.EXAMPLE
  ./enable-actions-approval.ps1
#>
param(
  [string]$Owner = 'aks-builds',
  [string[]]$ExcludeRepos = @(),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error 'gh CLI not found.'
  exit 1
}

Write-Host "Listing active repos for $Owner..."
$rawNames = gh repo list $Owner --limit 1000 --json name,isArchived `
  --jq '.[] | select(.isArchived == false) | .name'
$repoNames = @($rawNames) | Where-Object { $_ -and ($ExcludeRepos -notcontains $_) }

if (-not $repoNames -or $repoNames.Count -eq 0) {
  Write-Warning 'No repos found.'
  exit 0
}

Write-Host "Found $($repoNames.Count) active repos. Enabling Actions PR approval on each..."

$updated = 0
$skipped = 0
$failed = 0

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # Read current settings.
  $current = $null
  try {
    $resp = gh api "repos/$full/actions/permissions/workflow" 2>$null
    if ($LASTEXITCODE -eq 0 -and $resp) {
      $current = $resp | ConvertFrom-Json
    }
  } catch { }

  if (-not $current) {
    Write-Host "  [skip]   $full (could not read settings)"
    $skipped++
    continue
  }

  if ($current.can_approve_pull_request_reviews -eq $true -and $current.default_workflow_permissions -eq 'write') {
    Write-Host "  [ok]     $full (already enabled)"
    $skipped++
    continue
  }

  if ($DryRun) {
    Write-Host "  [dry]    would enable on $full (was: approve=$($current.can_approve_pull_request_reviews) perm=$($current.default_workflow_permissions))"
    $updated++
    continue
  }

  $result = ''
  try {
    $result = & gh api -X PUT "repos/$full/actions/permissions/workflow" `
      -F default_workflow_permissions='write' `
      -F can_approve_pull_request_reviews=true 2>&1 | Out-String
  } catch { $result = $_.Exception.Message }

  if ($LASTEXITCODE -eq 0) {
    Write-Host "  [set]    $full"
    $updated++
  } else {
    Write-Host "  [FAIL]   $full -- $($result.Trim())"
    $failed++
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would update=$updated, skip=$skipped."
} else {
  Write-Host "Done: updated=$updated, already-ok=$skipped, failed=$failed."
}
