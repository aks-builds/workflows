<#
.SYNOPSIS
  Push the auto-approve caller workflow into every active repo on the GitHub account.

.DESCRIPTION
  The reusable workflow in aks-builds/workflows only takes effect on repos that
  have a tiny caller file at .github/workflows/auto-approve.yml. This script
  PUTs that file into every active repo.

  - If main is unprotected: direct commit.
  - If main is protected (branch rules / rulesets reject direct push): the
    script falls back to creating a `bot/add-auto-approve-caller` branch and
    opening a PR. Disable the fallback with -DirectOnly.

  Idempotent: re-running on a repo that already has the file is a no-op
  (unless -Overwrite). Re-running after a PR was opened but not yet merged
  will detect the existing PR and not open a duplicate.

.PARAMETER Owner
  GitHub account whose repos receive the caller. Default: aks-builds.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.PARAMETER Overwrite
  Replace the caller file even if it already exists. Useful for rolling out
  changes (e.g. adding `with: wait-for-checks: true`).

.PARAMETER DirectOnly
  Skip the PR fallback for branch-protected repos. They will be reported as
  [FAIL] for manual handling.

.EXAMPLE
  ./deploy-caller.ps1 -DryRun

.EXAMPLE
  ./deploy-caller.ps1 -ExcludeRepos some-fork,private-experiment

.NOTES
  Output uses ASCII-only markers (PS 5.1 + Win-1252 source encoding gotcha).
#>
param(
  [string]$Owner = 'aks-builds',
  [string[]]$ExcludeRepos = @(),
  [switch]$DryRun,
  [switch]$Overwrite,
  [switch]$DirectOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error 'gh CLI not found. Install from https://cli.github.com/ and run gh auth login first.'
  exit 1
}

$callerYaml = @'
name: Auto-approve

# Calls the reusable workflow in aks-builds/workflows.
# Approves only PRs opened by aks-builds; silently skips all others.

on:
  pull_request:
    types: [opened, ready_for_review, synchronize, reopened]

# Required: the reusable workflow requests `pull-requests: write` to post the
# approval, and a called workflow can never exceed its caller's token scope.
# Omit this and the run dies at startup with "requesting 'pull-requests: write',
# but is only allowed 'pull-requests: none'".
permissions:
  contents: read
  pull-requests: write

jobs:
  call:
    uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main
    secrets: inherit
'@

$callerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($callerYaml))
$path = '.github/workflows/auto-approve.yml'
$prBranch = 'bot/add-auto-approve-caller'
$prTitle = 'ci: add auto-approve caller workflow'

$prBody = @'
This PR adds the auto-approve caller workflow that invokes the reusable
workflow at aks-builds/workflows/.github/workflows/auto-approve.yml.

Once merged, PRs opened by aks-builds will be auto-approved by
aks-codeowner-bot[bot] -- satisfying the branch-protection rule that
requires an approval from someone other than the PR author, without
spinning up a second human reviewer.

Required repo secrets (already distributed by workflows/scripts/distribute-secrets.ps1):
  - APPROVER_APP_ID
  - APPROVER_APP_PRIVATE_KEY

Filed by aks-builds/workflows/scripts/deploy-caller.ps1.
'@

# Write the PR body to a temp file once -- using WriteAllText with explicit
# no-BOM UTF-8 so gh --body-file doesn't choke on a BOM. Reused for every
# PR opened in this run; cleaned up after the loop.
$prBodyFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'openspecpm-pr-body.md')
[System.IO.File]::WriteAllText($prBodyFile, $prBody, [System.Text.UTF8Encoding]::new($false))

Write-Host "Listing active repos for $Owner..."
$rawNames = gh repo list $Owner --limit 1000 --json name,isArchived `
  --jq '.[] | select(.isArchived == false) | .name'
$repoNames = @($rawNames) | Where-Object { $_ -and ($ExcludeRepos -notcontains $_) }

if (-not $repoNames -or $repoNames.Count -eq 0) {
  Write-Warning 'No repos found. Run gh auth status to verify.'
  exit 0
}

Write-Host "Found $($repoNames.Count) active repos. Deploying caller to $path on each..."

$created = 0
$updated = 0
$prOpened = 0
$skipped = 0
$failed = 0
$failureDetails = @()
$prList = @()

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # ------- 1. Probe whether the caller already exists on the default branch -------
  $existing = $null
  $sha = $null
  try {
    $probe = gh api "repos/$full/contents/$path" 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) {
      $existing = $probe | ConvertFrom-Json
      $sha = $existing.sha
    }
  } catch { }

  if ($existing -and -not $Overwrite) {
    Write-Host "  [skip]   $full (already has $path)"
    $skipped++
    continue
  }

  if ($DryRun) {
    if ($existing) { Write-Host "  [dry]    would overwrite $path on $full"; $updated++ }
    else { Write-Host "  [dry]    would create $path on $full"; $created++ }
    continue
  }

  $message = if ($existing) { 'ci: update auto-approve caller workflow' } else { 'ci: add auto-approve caller workflow' }

  # ------- 2. Try direct PUT on the default branch -------
  $apiArgs = @(
    'api',
    '-X', 'PUT',
    "repos/$full/contents/$path",
    '-f', "message=$message",
    '-f', "content=$callerB64"
  )
  if ($sha) { $apiArgs += @('-f', "sha=$sha") }

  $putResult = ''
  try { $putResult = & gh @apiArgs 2>&1 | Out-String } catch { $putResult = $_.Exception.Message }
  $putExit = $LASTEXITCODE

  if ($putExit -eq 0) {
    if ($existing) { Write-Host "  [update] $full"; $updated++ }
    else           { Write-Host "  [create] $full"; $created++ }
    continue
  }

  # ------- 3. Direct PUT failed. Was it branch protection? -------
  $isProtected = (
    $putResult -match 'rule violations' -or
    $putResult -match 'must be made through a pull request' -or
    $putResult -match 'HTTP 409' -or
    $putResult -match 'HTTP 422'
  )

  if (-not $isProtected -or $DirectOnly) {
    Write-Host "  [FAIL]   $full -- $($putResult.Trim())"
    $failed++
    $failureDetails += [pscustomobject]@{ repo = $full; reason = $putResult.Trim() }
    continue
  }

  # ------- 4. PR fallback: branch + commit + PR -------
  Write-Host "  [PR...]  $full (branch protected, opening PR via $prBranch)"

  # Default branch
  $defaultBranch = ''
  try {
    $defaultBranch = (gh api "repos/$full" --jq '.default_branch' 2>$null) | Out-String
    $defaultBranch = $defaultBranch.Trim()
  } catch { }
  if (-not $defaultBranch) {
    Write-Host "  [FAIL]   $full -- couldn't read default branch"
    $failed++; $failureDetails += [pscustomobject]@{ repo = $full; reason = 'no default branch' }
    continue
  }

  # Base SHA
  $baseSha = ''
  try {
    $baseSha = (gh api "repos/$full/git/refs/heads/$defaultBranch" --jq '.object.sha' 2>$null) | Out-String
    $baseSha = $baseSha.Trim()
  } catch { }
  if (-not $baseSha) {
    Write-Host "  [FAIL]   $full -- couldn't read base SHA"
    $failed++; $failureDetails += [pscustomobject]@{ repo = $full; reason = 'no base sha' }
    continue
  }

  # Create branch (ignore 422 -- it means branch already exists)
  try {
    $null = & gh api -X POST "repos/$full/git/refs" `
      -f "ref=refs/heads/$prBranch" `
      -f "sha=$baseSha" 2>&1
  } catch { }

  # SHA of any existing file on the PR branch (likely present from a prior
  # partial run). Use an explicit ?ref= query string -- gh api's -f flag on
  # GET requests doesn't always serialize fields as URL params, especially
  # when the value contains a slash (the branch name has 'bot/...').
  $branchFileSha = $null
  try {
    $encodedRef = [Uri]::EscapeDataString($prBranch)
    $branchProbe = gh api "repos/$full/contents/${path}?ref=$encodedRef" 2>$null
    if ($LASTEXITCODE -eq 0 -and $branchProbe) {
      $branchFileSha = ($branchProbe | ConvertFrom-Json).sha
    }
  } catch { }

  $branchPutArgs = @(
    'api',
    '-X', 'PUT',
    "repos/$full/contents/$path",
    '-f', "message=$message",
    '-f', "content=$callerB64",
    '-f', "branch=$prBranch"
  )
  if ($branchFileSha) { $branchPutArgs += @('-f', "sha=$branchFileSha") }

  $branchPutResult = ''
  try { $branchPutResult = & gh @branchPutArgs 2>&1 | Out-String } catch { $branchPutResult = $_.Exception.Message }
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL]   $full -- put on branch failed: $($branchPutResult.Trim())"
    $failed++; $failureDetails += [pscustomobject]@{ repo = $full; reason = "branch PUT failed" }
    continue
  }

  # Open PR (or report existing one)
  $existingPRNum = ''
  try {
    $existingPRNum = (gh pr list --repo $full --head $prBranch --json number --jq '.[0].number' 2>$null) | Out-String
    $existingPRNum = $existingPRNum.Trim()
  } catch { }

  if ($existingPRNum) {
    $prUrl = "https://github.com/$full/pull/$existingPRNum"
    Write-Host "  [PR]     $full -- existing $prUrl"
    $prOpened++; $prList += $prUrl
    continue
  }

  $createResult = ''
  try {
    $createResult = & gh pr create --repo $full `
      --head $prBranch --base $defaultBranch `
      --title $prTitle --body-file $prBodyFile 2>&1 | Out-String
  } catch { $createResult = $_.Exception.Message }

  if ($LASTEXITCODE -eq 0) {
    $prUrl = $createResult.Trim().Split([Environment]::NewLine) | Select-Object -Last 1
    Write-Host "  [PR]     $full -- $prUrl"
    $prOpened++; $prList += $prUrl
  } else {
    Write-Host "  [FAIL]   $full -- PR create failed: $($createResult.Trim())"
    $failed++; $failureDetails += [pscustomobject]@{ repo = $full; reason = "PR create failed" }
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would create=$created, overwrite=$updated, skip=$skipped."
} else {
  Write-Host "Done: created=$created, updated=$updated, PRs opened=$prOpened, skipped=$skipped, failed=$failed."
}

if ($prList.Count -gt 0) {
  Write-Host ''
  Write-Host 'PRs opened on protected repos -- review and merge each:'
  foreach ($url in $prList) { Write-Host "  $url" }
}

if ($failureDetails.Count -gt 0) {
  Write-Host ''
  Write-Host 'Failures:'
  foreach ($f in $failureDetails) { Write-Host "  $($f.repo) -- $($f.reason)" }
}

# Clean up the temp PR-body file.
Remove-Item $prBodyFile -ErrorAction SilentlyContinue
