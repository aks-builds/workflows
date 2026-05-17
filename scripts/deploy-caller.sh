#!/usr/bin/env bash
# Push the auto-approve caller workflow into every active repo on the account.
# Companion to distribute-secrets.sh: secrets get the bot's credentials in place,
# this script puts the caller workflow that consumes them in place.
#
# Usage:
#   ./deploy-caller.sh [options]
#
# Options:
#   --owner <NAME>       GitHub account (default: aks-builds).
#   --exclude <a,b,c>    Comma-separated repo names to skip.
#   --overwrite          Replace existing caller files.
#   --dry-run            Print what would happen without writing.
#   --help               Show this help and exit.

set -euo pipefail

OWNER="aks-builds"
EXCLUDE=""
DRY_RUN=0
OVERWRITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)      OWNER="$2"; shift 2;;
    --exclude)    EXCLUDE="$2"; shift 2;;
    --overwrite)  OVERWRITE=1; shift;;
    --dry-run)    DRY_RUN=1; shift;;
    --help|-h)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)            echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not installed. https://cli.github.com/" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed." >&2; exit 1; }
command -v base64 >/dev/null || { echo "base64 not installed." >&2; exit 1; }

CALLER_YAML='name: Auto-approve

# Calls the reusable workflow in aks-builds/workflows.
# Approves only PRs opened by aks-builds; silently skips all others.

on:
  pull_request:
    types: [opened, ready_for_review, synchronize, reopened]

jobs:
  call:
    uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main
    secrets: inherit
'

CALLER_B64=$(printf '%s' "$CALLER_YAML" | base64 -w 0 2>/dev/null || printf '%s' "$CALLER_YAML" | base64)
TARGET_PATH='.github/workflows/auto-approve.yml'

IFS=',' read -ra EXCLUDED <<< "$EXCLUDE"

echo "Listing active repos for $OWNER..."
mapfile -t repos < <(gh repo list "$OWNER" --limit 1000 --json name,isArchived \
  | jq -r '.[] | select(.isArchived == false) | .name')

created=0
updated=0
skipped=0

for repo in "${repos[@]}"; do
  skip=0
  for ex in "${EXCLUDED[@]:-}"; do
    if [[ -n "$ex" && "$repo" == "$ex" ]]; then skip=1; break; fi
  done
  if [[ $skip -eq 1 ]]; then
    echo "↷ skip $repo (excluded)"
    skipped=$((skipped + 1))
    continue
  fi

  full="$OWNER/$repo"
  sha=""
  if existing=$(gh api "repos/$full/contents/$TARGET_PATH" 2>/dev/null); then
    sha=$(echo "$existing" | jq -r '.sha')
  fi

  if [[ -n "$sha" && $OVERWRITE -eq 0 ]]; then
    echo "↷ skip $full (already has $TARGET_PATH)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -n "$sha" ]]; then
      echo "[dry-run] would overwrite $TARGET_PATH on $full"
      updated=$((updated + 1))
    else
      echo "[dry-run] would create $TARGET_PATH on $full"
      created=$((created + 1))
    fi
    continue
  fi

  if [[ -n "$sha" ]]; then
    message='ci: update auto-approve caller workflow'
    payload=$(jq -n --arg m "$message" --arg c "$CALLER_B64" --arg s "$sha" '{message:$m, content:$c, sha:$s}')
  else
    message='ci: add auto-approve caller workflow'
    payload=$(jq -n --arg m "$message" --arg c "$CALLER_B64" '{message:$m, content:$c}')
  fi

  if echo "$payload" | gh api -X PUT "repos/$full/contents/$TARGET_PATH" --input - >/dev/null; then
    if [[ -n "$sha" ]]; then
      echo "↻ updated $full"
      updated=$((updated + 1))
    else
      echo "+ created $full"
      created=$((created + 1))
    fi
  else
    echo "✖ failed $full"
  fi
done

echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run: would create=$created, overwrite=$updated, skip=$skipped."
else
  echo "Done: created=$created, updated=$updated, skipped=$skipped."
fi
