<#
.SYNOPSIS
  Push the codeowner-bot App ID and private key to every active repo on your GitHub account.

.DESCRIPTION
  Runs locally. Loops gh repo list and calls gh secret set per repo for
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

.NOTES
  Output uses ASCII-only markers. Windows PowerShell 5.1 reads .ps1 files as
  Windows-1252 unless a UTF-8 BOM is present; non-ASCII characters in strings
  can be misinterpreted as quote terminators. Keep this file ASCII.
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
  Write-Error 'gh CLI not found. Install from https://cli.github.com/ and run gh auth login first.'
  exit 1
}

if (-not (Test-Path $PrivateKeyPath)) {
  Write-Error "Private key file not found: $PrivateKeyPath"
  exit 1
}

$privateKey = Get-Content $PrivateKeyPath -Raw

Write-Host "Listing active repos for $Owner..."

# Let gh's built-in jq evaluator do the filtering server-side.
# It emits one repo name per line, which PowerShell captures cleanly as a string array
# -- avoiding the multi-line-JSON parsing trap.
$rawNames = gh repo list $Owner --limit 1000 --json name,isArchived `
  --jq '.[] | select(.isArchived == false) | .name'

# Normalize to array (a single result comes back as a bare string).
$repoNames = @($rawNames) | Where-Object { $_ -and ($ExcludeRepos -notcontains $_) }

if (-not $repoNames -or $repoNames.Count -eq 0) {
  Write-Warning 'No repos found. Confirm `gh auth status` shows you are logged in as the right account.'
  Write-Host  '  Run: gh repo list ' $Owner ' --limit 5'
  exit 0
}

Write-Host "Found $($repoNames.Count) active repos (after applying -ExcludeRepos)."

$applied = 0
foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"
  if ($DryRun) {
    Write-Host "  [dry]    would set secrets on $full"
    $applied++
    continue
  }
  Write-Host "  [set]    $full"
  gh secret set APPROVER_APP_ID --body $AppId --repo $full
  $privateKey | gh secret set APPROVER_APP_PRIVATE_KEY --repo $full
  $applied++
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run complete. Would distribute to $applied repos. Re-run without -DryRun to apply."
} else {
  Write-Host "Distributed to $applied repos. Re-run after rotating the app's private key."
}
