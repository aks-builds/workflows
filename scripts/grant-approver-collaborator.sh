#!/usr/bin/env bash
# Grant the secondary approver account write (push) access to every repo that
# calls the auto-approve reusable workflow, and auto-accept the invitation.
#
# Why: required-review rules only COUNT approvals from identities with write
# access. The auto-approve bot/PAT can post an approval, but unless the
# approving account is a write collaborator the approval is ignored and the PR
# still shows "review required". Adding the account as a collaborator only
# creates a *pending invitation* -- so this script also accepts it using the
# approver's own token (APPROVER_PAT).
#
# Companion to deploy-caller.sh / enable-actions-approval.* in the onboarding
# flow: deploy-caller puts the workflow in place, enable-actions-approval lets
# Actions approve at all, and this grants the approver the access that makes
# the approval count.
#
# Auth:
#   - Sending the invite needs ADMIN on each repo. Uses your ambient `gh` auth
#     (run as the repo owner) -- or set GH_TOKEN to a PAT with `repo` scope.
#   - Accepting the invite must be done BY the approver account, so it needs
#     the approver's own token via --approver-pat or $APPROVER_PAT. Without it
#     the invite is sent but left pending (accept it manually).
#
# Usage:
#   ./grant-approver-collaborator.sh [options]
#
# Options:
#   --owner <NAME>        GitHub account that owns the repos (default: aks-builds).
#   --approver <LOGIN>    Account to grant write + accept as (default: aks-reviewes).
#   --permission <LEVEL>  pull|triage|push|maintain|admin (default: push = write).
#   --approver-pat <TOK>  Approver account token used to accept the invite
#                         (falls back to $APPROVER_PAT).
#   --all-repos           Target every active repo, not just ones that have the
#                         auto-approve caller workflow.
#   --exclude <a,b,c>     Comma-separated repo names to skip.
#   --dry-run             Print what would happen without writing.
#   --help                Show this help and exit.

set -euo pipefail

OWNER="aks-builds"
APPROVER="aks-reviewes"
PERMISSION="push"
APPROVER_PAT="${APPROVER_PAT:-}"
ALL_REPOS=0
EXCLUDE=""
DRY_RUN=0
CALLER_PATH=".github/workflows/auto-approve.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)        OWNER="$2"; shift 2;;
    --approver)     APPROVER="$2"; shift 2;;
    --permission)   PERMISSION="$2"; shift 2;;
    --approver-pat) APPROVER_PAT="$2"; shift 2;;
    --all-repos)    ALL_REPOS=1; shift;;
    --exclude)      EXCLUDE="$2"; shift 2;;
    --dry-run)      DRY_RUN=1; shift;;
    --help|-h)      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)              echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not installed. https://cli.github.com/" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed." >&2; exit 1; }

if [[ -z "$APPROVER_PAT" ]]; then
  echo "WARN: no --approver-pat / \$APPROVER_PAT set. Invites will be SENT but left"
  echo "      pending -- $APPROVER must accept them manually for approvals to count."
fi

IFS=',' read -ra EXCLUDED <<< "$EXCLUDE"

echo "Listing active repos for $OWNER..."
mapfile -t repos < <(gh repo list "$OWNER" --limit 1000 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

invited=0
accepted=0
skipped=0
failed=0

for repo in "${repos[@]}"; do
  skip=0
  for ex in "${EXCLUDED[@]:-}"; do
    if [[ -n "$ex" && "$repo" == "$ex" ]]; then skip=1; break; fi
  done
  if [[ $skip -eq 1 ]]; then
    echo "  [skip]   $repo (excluded)"
    skipped=$((skipped + 1))
    continue
  fi

  full="$OWNER/$repo"

  # Only target repos that actually call the auto-approve workflow, unless --all-repos.
  if [[ $ALL_REPOS -eq 0 ]]; then
    if ! gh api "repos/$full/contents/$CALLER_PATH" >/dev/null 2>&1; then
      echo "  [skip]   $full (no auto-approve caller)"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  # Already a write+ collaborator? On public repos the permission endpoint
  # returns 'read' for non-collaborators, so 'write'/'admin' reliably means an
  # accepted collaborator with the access we need.
  perm=$(gh api "repos/$full/collaborators/$APPROVER/permission" --jq '.permission' 2>/dev/null || echo "")
  if [[ "$perm" == "write" || "$perm" == "admin" || "$perm" == "maintain" ]]; then
    echo "  [ok]     $full ($APPROVER already has $perm)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry]    would invite $APPROVER to $full as $PERMISSION and accept"
    invited=$((invited + 1))
    continue
  fi

  # ---- 1. Send / update the invite (needs admin; uses ambient gh auth) ----
  if ! gh api -X PUT "repos/$full/collaborators/$APPROVER" -f "permission=$PERMISSION" >/dev/null 2>&1; then
    echo "  [FAIL]   $full (could not invite $APPROVER -- need admin on the repo)"
    failed=$((failed + 1))
    continue
  fi
  echo "  [invite] $full -> $APPROVER ($PERMISSION)"
  invited=$((invited + 1))

  # ---- 2. Accept the invite AS the approver account ----
  if [[ -z "$APPROVER_PAT" ]]; then
    continue
  fi
  inv_id=$(GH_TOKEN="$APPROVER_PAT" gh api /user/repository_invitations --paginate \
    --jq ".[] | select(.repository.full_name==\"$full\") | .id" 2>/dev/null | head -n1)
  if [[ -z "$inv_id" ]]; then
    # No pending invite usually means it was already accepted between the PUT
    # and now, or the PAT belongs to the wrong account.
    echo "  [note]   $full (no pending invite to accept -- may already be active)"
    continue
  fi
  if GH_TOKEN="$APPROVER_PAT" gh api -X PATCH "/user/repository_invitations/$inv_id" >/dev/null 2>&1; then
    echo "  [accept] $full ($APPROVER accepted)"
    accepted=$((accepted + 1))
  else
    echo "  [FAIL]   $full (invite sent but accept failed -- accept manually as $APPROVER)"
    failed=$((failed + 1))
  fi
done

echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run: would invite=$invited, skip=$skipped."
else
  echo "Done: invited=$invited, accepted=$accepted, skipped=$skipped, failed=$failed."
fi
