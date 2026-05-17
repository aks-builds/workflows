<#
.SYNOPSIS
  Push the auto-approve caller workflow into every active repo on the GitHub account.

.DESCRIPTION
  The reusable workflow in aks-builds/workflows only takes effect on repos that
  have a tiny caller file at .github/workflows/auto-approve.yml. This script
  PUTs that file into every active repo via the GitHub Contents API. Idempotent:
  re-running on a repo that already has the file is a no-op (unless -Overwrite).

.PARAMETER Owner
  GitHub account whose repos receive the caller. Default: aks-builds.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.PARAMETER Overwrite
  Replace the caller file even if it already exists. Useful for rolling out
  changes (e.g. adding `with: wait-for-checks: true`).

.EXAMPLE
  ./deploy-caller.ps1 -DryRun

.EXAMPLE
  ./deploy-caller.ps1 -ExcludeRepos some-fork,private-experiment

.NOTES
  Output uses ASCII-only markers. Windows PowerShell 5.1 reads .ps1 files as
  Windows-1252 unless a UTF-8 BOM is present; non-ASCII characters in strings
  can be misinterpreted as quote terminators. Keep this file ASCII.
#>
param(
  [string]$Owner = 'aks-builds',
  [string[]]$ExcludeRepos = @(),
  [switch]$DryRun,
  [switch]$Overwrite
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

jobs:
  call:
    uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main
    secrets: inherit
'@

$callerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($callerYaml))
$path = '.github/workflows/auto-approve.yml'

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
$skipped = 0
$updated = 0

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # Check whether the file already exists. gh api exits non-zero on 404, which
  # we expect for any repo that doesn't have the caller yet. Wrap in try/catch
  # so $ErrorActionPreference='Stop' doesn't halt the loop.
  $existing = $null
  $sha = $null
  try {
    $probe = gh api "repos/$full/contents/$path" 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) {
      $existing = $probe | ConvertFrom-Json
      $sha = $existing.sha
    }
  } catch {
    # 404 or other API error -- proceed to create.
  }

  if ($existing -and -not $Overwrite) {
    Write-Host "  [skip]   $full (already has $path)"
    $skipped++
    continue
  }

  if ($DryRun) {
    if ($existing) {
      Write-Host "  [dry]    would overwrite $path on $full"
      $updated++
    } else {
      Write-Host "  [dry]    would create $path on $full"
      $created++
    }
    continue
  }

  if ($existing) {
    $message = 'ci: update auto-approve caller workflow'
  } else {
    $message = 'ci: add auto-approve caller workflow'
  }
  $payload = @{ message = $message; content = $callerB64 }
  if ($sha) { $payload.sha = $sha }

  $tmp = New-TemporaryFile
  $payload | ConvertTo-Json -Compress | Out-File -Encoding utf8 -FilePath $tmp
  $putResult = $null
  $putResult = gh api -X PUT "repos/$full/contents/$path" --input $tmp 2>&1
  $putExit = $LASTEXITCODE
  Remove-Item $tmp -ErrorAction SilentlyContinue

  if ($putExit -eq 0) {
    if ($existing) {
      Write-Host "  [update] $full"
      $updated++
    } else {
      Write-Host "  [create] $full"
      $created++
    }
  } else {
    Write-Host "  [FAIL]   $full -- $putResult"
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would create=$created, overwrite=$updated, skip=$skipped."
} else {
  Write-Host "Done: created=$created, updated=$updated, skipped=$skipped."
}
