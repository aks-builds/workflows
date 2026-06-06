<#
.SYNOPSIS
  Grant the secondary approver account write access to every repo that calls
  the auto-approve workflow, and auto-accept the invitation.

.DESCRIPTION
  Required-review rules only COUNT approvals from identities with write access.
  The auto-approve bot/PAT can post an approval, but unless the approving
  account is a write collaborator the approval is ignored and the PR still
  shows "review required". Adding the account creates only a *pending
  invitation*, so this script also accepts it using the approver's own token.

  Companion to deploy-caller.ps1 / enable-actions-approval.ps1 in the onboarding
  flow: deploy-caller puts the workflow in place, enable-actions-approval lets
  Actions approve at all, and this grants the approver the access that makes the
  approval count.

  Auth:
    - Sending the invite needs ADMIN on each repo -> uses your ambient `gh` auth
      (run as the repo owner).
    - Accepting the invite must be done BY the approver account -> needs the
      approver's own token via -ApproverPat or $env:APPROVER_PAT. Without it the
      invite is sent but left pending (accept it manually).

.PARAMETER Owner
  GitHub account that owns the repos. Default: aks-builds.

.PARAMETER Approver
  Account to grant write + accept as. Default: aks-reviewes.

.PARAMETER Permission
  pull | triage | push | maintain | admin. Default: push (= write).

.PARAMETER ApproverPat
  Approver account token used to accept the invite. Falls back to
  $env:APPROVER_PAT.

.PARAMETER AllRepos
  Target every active repo, not just ones that have the auto-approve caller.

.PARAMETER ExcludeRepos
  Repo names (without owner prefix) to skip.

.PARAMETER DryRun
  Print what would happen without writing.

.EXAMPLE
  ./grant-approver-collaborator.ps1 -DryRun

.EXAMPLE
  $env:APPROVER_PAT = 'ghp_xxx'; ./grant-approver-collaborator.ps1

.NOTES
  Output uses ASCII-only markers (PS 5.1 + Win-1252 source encoding gotcha).
#>
param(
  [string]$Owner = 'aks-builds',
  [string]$Approver = 'aks-reviewes',
  [ValidateSet('pull', 'triage', 'push', 'maintain', 'admin')]
  [string]$Permission = 'push',
  [string]$ApproverPat = $env:APPROVER_PAT,
  [switch]$AllRepos,
  [string[]]$ExcludeRepos = @(),
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$callerPath = '.github/workflows/auto-approve.yml'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Error 'gh CLI not found. Install from https://cli.github.com/ and run gh auth login first.'
  exit 1
}

if (-not $ApproverPat) {
  Write-Warning "No -ApproverPat / `$env:APPROVER_PAT set. Invites will be SENT but left pending -- $Approver must accept them manually for approvals to count."
}

# Accept a pending invitation as the approver account, via the REST API with
# the approver's own token (kept separate from the ambient admin `gh` auth used
# to send the invite).
function Accept-Invite {
  param([string]$FullName, [string]$Pat)
  $headers = @{ Authorization = "token $Pat"; Accept = 'application/vnd.github+json' }
  $invites = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/user/repository_invitations' -Headers $headers
  $inv = $invites | Where-Object { $_.repository.full_name -eq $FullName } | Select-Object -First 1
  if (-not $inv) { return $null }
  Invoke-RestMethod -Method Patch -Uri "https://api.github.com/user/repository_invitations/$($inv.id)" -Headers $headers | Out-Null
  return $inv.id
}

Write-Host "Listing active repos for $Owner..."
$rawNames = gh repo list $Owner --limit 1000 --json name,isArchived `
  --jq '.[] | select(.isArchived == false) | .name'
$repoNames = @($rawNames) | Where-Object { $_ -and ($ExcludeRepos -notcontains $_) }

if (-not $repoNames -or $repoNames.Count -eq 0) {
  Write-Warning 'No repos found. Run gh auth status to verify.'
  exit 0
}

$invited = 0
$accepted = 0
$skipped = 0
$failed = 0

foreach ($repo in $repoNames) {
  $full = "$Owner/$repo"

  # Only target repos that actually call the auto-approve workflow, unless -AllRepos.
  if (-not $AllRepos) {
    gh api "repos/$full/contents/$callerPath" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  [skip]   $full (no auto-approve caller)"
      $skipped++
      continue
    }
  }

  # Already a write+ collaborator? On public repos the permission endpoint
  # returns 'read' for non-collaborators, so 'write'/'admin'/'maintain'
  # reliably means an accepted collaborator with the access we need.
  $perm = ''
  try {
    $perm = (gh api "repos/$full/collaborators/$Approver/permission" --jq '.permission' 2>$null) | Out-String
    $perm = $perm.Trim()
  } catch { }
  if ($perm -in @('write', 'admin', 'maintain')) {
    Write-Host "  [ok]     $full ($Approver already has $perm)"
    $skipped++
    continue
  }

  if ($DryRun) {
    Write-Host "  [dry]    would invite $Approver to $full as $Permission and accept"
    $invited++
    continue
  }

  # ---- 1. Send / update the invite (needs admin; ambient gh auth) ----
  gh api -X PUT "repos/$full/collaborators/$Approver" -f "permission=$Permission" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL]   $full (could not invite $Approver -- need admin on the repo)"
    $failed++
    continue
  }
  Write-Host "  [invite] $full -> $Approver ($Permission)"
  $invited++

  # ---- 2. Accept the invite AS the approver account ----
  if (-not $ApproverPat) { continue }
  try {
    $id = Accept-Invite -FullName $full -Pat $ApproverPat
    if ($id) {
      Write-Host "  [accept] $full ($Approver accepted)"
      $accepted++
    } else {
      Write-Host "  [note]   $full (no pending invite to accept -- may already be active)"
    }
  } catch {
    Write-Host "  [FAIL]   $full (invite sent but accept failed -- accept manually as $Approver)"
    $failed++
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "Dry run: would invite=$invited, skip=$skipped."
} else {
  Write-Host "Done: invited=$invited, accepted=$accepted, skipped=$skipped, failed=$failed."
}
