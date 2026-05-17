<#
.SYNOPSIS
  Add the codeowner-bot App to bypass_actors on every repository ruleset
  that enforces a pull_request rule.

.DESCRIPTION
  GitHub Apps cannot appear in CODEOWNERS, so an App's approval does not
  satisfy `require_code_owner_review`. Rulesets support "bypass actors":
  identities allowed to bypass rules. Adding the bot's App as a bypass
  actor lets its approval pass the code-owner gate without affecting
  enforcement for human contributors.

.PARAMETER AppId
  The bot's GitHub App ID (numeric).

.PARAMETER Owner
  GitHub account whose repos to update. Default: aks-builds.

.PARAMETER BypassMode
  `pull_request` (default, recommended): bot can bypass only via PR workflows.
  `always`: bot can bypass in any context (including direct push). Less safe.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.EXAMPLE
  ./add-bot-bypass.ps1 -AppId 3742289 -DryRun
#>
param(
  [Parameter(Mandatory = $true)][int]$AppId,
  [string]$Owner = 'aks-builds',
  [ValidateSet('pull_request','always')][string]$BypassMode = 'pull_request',
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

Write-Host "Found $($repoNames.Count) active repos. Adding App $AppId as bypass actor ($BypassMode) on each..."

$updated = 0
$alreadyOk = 0
$noRuleset = 0
$failed = 0

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # List rulesets on this repo.
  $rulesets = @()
  try {
    $resp = gh api "repos/$full/rulesets" 2>$null
    if ($LASTEXITCODE -eq 0 -and $resp) {
      $rulesets = @($resp | ConvertFrom-Json)
    }
  } catch { }

  if (-not $rulesets -or $rulesets.Count -eq 0) {
    Write-Host "  [skip]   $full (no rulesets)"
    $noRuleset++
    continue
  }

  $touched = $false
  foreach ($rs in $rulesets) {
    $rsId = $rs.id

    # Fetch full ruleset (the list endpoint omits rules + bypass_actors).
    $full_rs = $null
    try {
      $rsResp = gh api "repos/$full/rulesets/$rsId" 2>$null
      if ($LASTEXITCODE -eq 0 -and $rsResp) {
        $full_rs = $rsResp | ConvertFrom-Json
      }
    } catch { }
    if (-not $full_rs) { continue }

    $hasPRRule = $false
    foreach ($r in @($full_rs.rules)) { if ($r.type -eq 'pull_request') { $hasPRRule = $true; break } }
    if (-not $hasPRRule) { continue }

    $existingBypass = @($full_rs.bypass_actors)
    $alreadyHas = $false
    foreach ($b in $existingBypass) {
      if ($b.actor_id -eq $AppId -and $b.actor_type -eq 'Integration') { $alreadyHas = $true; break }
    }

    if ($alreadyHas) {
      Write-Host "  [ok]     $full ruleset='$($full_rs.name)' (already has App $AppId)"
      $alreadyOk++
      continue
    }

    $newBypass = $existingBypass + @([pscustomobject]@{
      actor_id = $AppId
      actor_type = 'Integration'
      bypass_mode = $BypassMode
    })

    if ($DryRun) {
      Write-Host "  [dry]    $full ruleset='$($full_rs.name)' (would add App $AppId as $BypassMode)"
      $updated++
      $touched = $true
      continue
    }

    # PATCH the ruleset's bypass_actors. Only that field is updated; others are preserved by GitHub.
    $bypassJson = $newBypass | ConvertTo-Json -Compress -Depth 4
    # If single item, ConvertTo-Json emits an object instead of array; force array.
    if ($newBypass.Count -eq 1) { $bypassJson = "[$bypassJson]" }

    $tmp = New-TemporaryFile
    $payload = "{`"bypass_actors`":$bypassJson}"
    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))

    $patchResult = ''
    try {
      $patchResult = & gh api -X PUT "repos/$full/rulesets/$rsId" --input $tmp 2>&1 | Out-String
    } catch { $patchResult = $_.Exception.Message }
    Remove-Item $tmp -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [add]    $full ruleset='$($full_rs.name)'"
      $updated++
      $touched = $true
    } else {
      Write-Host "  [FAIL]   $full ruleset='$($full_rs.name)' -- $($patchResult.Trim())"
      $failed++
    }
  }

  if (-not $touched -and -not ($DryRun)) {
    # No applicable ruleset on this repo.
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would update=$updated, already-ok=$alreadyOk, no-ruleset=$noRuleset."
} else {
  Write-Host "Done: updated=$updated, already-ok=$alreadyOk, no-ruleset=$noRuleset, failed=$failed."
}
