#!/usr/bin/env bash
# Push the auto-approve secrets to every active repo on the configured GitHub
# account. Re-run whenever you rotate the app's private key or the approver PAT.
#
# Distributes APPROVER_APP_ID + APPROVER_APP_PRIVATE_KEY, and (when provided)
# APPROVER_PAT. APPROVER_PAT is what makes the approval actually COUNT toward
# branch rules — a GitHub App's review does not satisfy required-review rules, so
# the PAT posts the review as a real write-collaborator account.
#
# Usage:
#   ./distribute-secrets.sh --app-id <ID> --private-key <PATH> [options]
#
# Options:
#   --app-id <ID>           GitHub App ID (numeric).
#   --private-key <PATH>    Path to the .pem private key file.
#   --approver-pat <TOKEN>  Approver account classic PAT (repo scope). Falls back
#                           to $APPROVER_PAT. Strongly recommended — without it,
#                           approvals are posted but do not count.
#   --owner <NAME>          GitHub account (default: aks-builds).
#   --exclude <a,b,c>       Comma-separated repo names to skip.
#   --dry-run               Print what would happen without writing.
#   --help                  Show this help and exit.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

OWNER="aks-builds"
EXCLUDE=""
DRY_RUN=0
APP_ID=""
KEY_PATH=""
APPROVER_PAT="${APPROVER_PAT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)       APP_ID="$2"; shift 2;;
    --private-key)  KEY_PATH="$2"; shift 2;;
    --approver-pat) APPROVER_PAT="$2"; shift 2;;
    --owner)        OWNER="$2"; shift 2;;
    --exclude)      EXCLUDE="$2"; shift 2;;
    --dry-run)      DRY_RUN=1; shift;;
    --help|-h)      usage 0;;
    *)              echo "Unknown arg: $1" >&2; usage 1;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not installed. https://cli.github.com/" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed." >&2; exit 1; }

[[ -z "$APP_ID" || -z "$KEY_PATH" ]] && { echo "--app-id and --private-key are required." >&2; usage 1; }
[[ -f "$KEY_PATH" ]] || { echo "Key file not found: $KEY_PATH" >&2; exit 1; }

KEY_CONTENTS=$(cat "$KEY_PATH")
IFS=',' read -ra EXCLUDED <<< "$EXCLUDE"

if [[ -z "$APPROVER_PAT" ]]; then
  echo "WARN: no --approver-pat / \$APPROVER_PAT given. APPROVER_PAT will NOT be"
  echo "      distributed; consumer auto-approve will post App-only reviews that"
  echo "      do NOT count toward required-review rules."
fi

echo "Listing active repos for $OWNER..."
mapfile -t repos < <(gh repo list "$OWNER" --limit 1000 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

count=0
for repo in "${repos[@]}"; do
  skip=0
  for ex in "${EXCLUDED[@]:-}"; do
    if [[ -n "$ex" && "$repo" == "$ex" ]]; then skip=1; break; fi
  done
  if [[ $skip -eq 1 ]]; then
    echo "↷ skip $repo (excluded)"
    continue
  fi
  full="$OWNER/$repo"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would set secrets on $full"
  else
    echo "→ $full"
    gh secret set APPROVER_APP_ID --body "$APP_ID" --repo "$full"
    printf '%s' "$KEY_CONTENTS" | gh secret set APPROVER_APP_PRIVATE_KEY --repo "$full"
    if [[ -n "$APPROVER_PAT" ]]; then
      printf '%s' "$APPROVER_PAT" | gh secret set APPROVER_PAT --repo "$full"
    fi
  fi
  count=$((count + 1))
done

echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run complete. Would distribute to $count repos. Re-run without --dry-run to apply."
else
  echo "Distributed to $count repos. Re-run after rotating the app's private key."
fi
