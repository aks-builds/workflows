<#
.SYNOPSIS
  Push the codeowner-bot App ID and private key to every active repo on your GitHub account.

.DESCRIPTION
  Runs locally. Loops `gh repo list` and calls `gh secret set` per repo for
  APPROVER_APP_ID and APPROVER_APP_PRIVATE_KEY. Re-run whenever you rotate
  the app's private key.

.PARAMETER AppId
  The GitHub App ID (numeric, from github.com/settings/apps/aks-codeowner-bot).

.PARAMETER PrivateKeyPath
  Path to the .pem private key file downloaded from the app settings.

.PARAMETER Owner
  GitHub account whose repos receive the secrets. Defaults to "aks-builds".

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.EXAMPLE
  ./distribute-secrets.ps1 -AppId 123456 -PrivateKeyPath C:\keys\bot.pem -DryRun

.EXAMPLE
  ./distribute-secrets.ps1 -AppId 123456 -PrivateKeyPath C:\keys\bot.pem -ExcludeRepos experiment-1,archived-thing
#>
param(
  [Parameter(Mandatory = $true)][string]$AppId,
  [Parameter(Mandatory = $true)][string]$PrivateKeyPath,
  [string]$Owner = 'aks-builds',
  [string[]]$ExcludeRepos = @(),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error 'gh CLI not found. Install from https://cli.github.com/ and run `gh auth login` first.'
  exit 1
}

if (-not (Test-Path $PrivateKeyPath)) {
  Write-Error "Private key file not found: $PrivateKeyPath"
  exit 1
}

$privateKey = Get-Content $PrivateKeyPath -Raw

Write-Host "Listing active repos for $Owner..."
$reposJson = gh repo list $Owner --limit 1000 --json name,isArchived
$repos = $reposJson | ConvertFrom-Json | Where-Object {
  -not $_.isArchived -and $ExcludeRepos -notcontains $_.name
}

if (-not $repos -or $repos.Count -eq 0) {
  Write-Warning 'No repos found.'
  exit 0
}

Write-Host "Found $($repos.Count) active repos."

$applied = 0
foreach ($repo in $repos) {
  $full = "$Owner/$($repo.name)"
  if ($DryRun) {
    Write-Host "[dry-run] would set secrets on $full"
    continue
  }
  Write-Host "→ $full"
  gh secret set APPROVER_APP_ID --body $AppId --repo $full
  $privateKey | gh secret set APPROVER_APP_PRIVATE_KEY --repo $full
  $applied++
}

Write-Host ""
if ($DryRun) {
  Write-Host "Dry run complete. Re-run without -DryRun to apply."
} else {
  Write-Host "Distributed to $applied repos. Re-run after rotating the app's private key."
}
