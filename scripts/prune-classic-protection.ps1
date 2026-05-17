<#
.SYNOPSIS
  Remove classic branch protection on repos that also have a ruleset
  enforcing PR rules. Rulesets supersede classic protection and offer
  bypass-actor support that classic protection lacks.

.DESCRIPTION
  Where both classic branch protection AND a ruleset are present and
  both enforce a "require code owner reviews" style rule, GitHub
  applies the most restrictive of the two -- which means even after
  granting the bot a ruleset bypass, the classic rule continues to
  block. This script deletes the classic protection only where a
  ruleset on the same branch already covers the territory.

  Idempotent. Repos without a classic protection or without a ruleset
  are skipped.

.PARAMETER Owner
  GitHub account. Default: aks-builds.

.PARAMETER Branch
  Branch name to inspect. Default: main.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.EXAMPLE
  ./prune-classic-protection.ps1 -DryRun
#>
param(
  [string]$Owner = 'aks-builds',
  [string]$Branch = 'main',
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

Write-Host "Found $($repoNames.Count) active repos. Checking each for redundant classic protection on '$Branch'..."

$pruned = 0
$keptOnlyClassic = 0
$noClassic = 0
$failed = 0

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # Does this repo have classic branch protection on the branch?
  $hasClassic = $false
  try {
    $resp = gh api "repos/$full/branches/$Branch/protection" 2>$null
    if ($LASTEXITCODE -eq 0 -and $resp) { $hasClassic = $true }
  } catch { }

  if (-not $hasClassic) {
    Write-Host "  [skip]   $full (no classic protection on $Branch)"
    $noClassic++
    continue
  }

  # Does it have a ruleset that targets the default branch with a pull_request rule?
  $rulesets = @()
  try {
    $rsResp = gh api "repos/$full/rulesets" 2>$null
    if ($LASTEXITCODE -eq 0 -and $rsResp) {
      $rulesets = @($rsResp | ConvertFrom-Json)
    }
  } catch { }

  $hasOverlap = $false
  foreach ($rs in $rulesets) {
    try {
      $detail = gh api "repos/$full/rulesets/$($rs.id)" --jq '{rules:.rules, conditions:.conditions, enforcement:.enforcement}' 2>$null | ConvertFrom-Json
      if ($detail.enforcement -ne 'active') { continue }
      $coversDefault = $false
      foreach ($incl in @($detail.conditions.ref_name.include)) {
        if ($incl -eq '~DEFAULT_BRANCH' -or $incl -eq "refs/heads/$Branch") { $coversDefault = $true; break }
      }
      if (-not $coversDefault) { continue }
      foreach ($r in @($detail.rules)) {
        if ($r.type -eq 'pull_request') { $hasOverlap = $true; break }
      }
      if ($hasOverlap) { break }
    } catch { }
  }

  if (-not $hasOverlap) {
    Write-Host "  [keep]   $full (classic protection has no ruleset overlap; not pruning)"
    $keptOnlyClassic++
    continue
  }

  if ($DryRun) {
    Write-Host "  [dry]    would delete classic protection on $full ($Branch); ruleset covers it"
    $pruned++
    continue
  }

  $delResult = ''
  try {
    $delResult = & gh api -X DELETE "repos/$full/branches/$Branch/protection" 2>&1 | Out-String
  } catch { $delResult = $_.Exception.Message }

  if ($LASTEXITCODE -eq 0) {
    Write-Host "  [del]    $full classic protection removed (ruleset still in force)"
    $pruned++
  } else {
    Write-Host "  [FAIL]   $full -- $($delResult.Trim())"
    $failed++
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would prune=$pruned, keep-only-classic=$keptOnlyClassic, no-classic=$noClassic."
} else {
  Write-Host "Done: pruned=$pruned, keep-only-classic=$keptOnlyClassic, no-classic=$noClassic, failed=$failed."
}
