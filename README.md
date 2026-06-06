# workflows

Reusable GitHub Actions workflows used across all of `aks-builds`'s repositories.

The central piece is **`auto-approve.yml`**, which approves PRs authored by `aks-builds` using a GitHub App (`aks-codeowner-bot`) — satisfying branch-protection's "approval from someone other than the PR author" rule on solo repos without spinning up a second human account.

## What's here

| File | Purpose |
|---|---|
| [`.github/workflows/auto-approve.yml`](.github/workflows/auto-approve.yml) | Reusable workflow. Consumer repos call it via `uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main`. |
| [`.github/workflows/distribute-secrets.yml`](.github/workflows/distribute-secrets.yml) | `workflow_dispatch` job that pushes the bot's secrets to every active repo on the account. Triggered from the Actions tab. |
| [`scripts/distribute-secrets.ps1`](scripts/distribute-secrets.ps1) | PowerShell version of the distributor for local runs (Windows-friendly). |
| [`scripts/distribute-secrets.sh`](scripts/distribute-secrets.sh) | Bash version of the distributor for local runs (macOS/Linux). |
| [`scripts/deploy-caller.ps1`](scripts/deploy-caller.ps1) | PowerShell: PUTs `.github/workflows/auto-approve.yml` into every active repo via the Contents API. |
| [`scripts/deploy-caller.sh`](scripts/deploy-caller.sh) | Bash equivalent. |
| [`scripts/enable-actions-approval.ps1`](scripts/enable-actions-approval.ps1) | PowerShell: flips `can_approve_pull_request_reviews=true` on every active repo. **Required** — without this the bot's `gh pr review --approve` call is silently rejected even with a valid App token. |
| [`.github/workflows/grant-approver-collaborator.yml`](.github/workflows/grant-approver-collaborator.yml) | `workflow_dispatch` job that grants the approver account write access on every caller repo and auto-accepts the invite. Triggered from the Actions tab. |
| [`scripts/grant-approver-collaborator.ps1`](scripts/grant-approver-collaborator.ps1) | PowerShell: invites the approver account (`aks-reviewes`) as a **write** collaborator on every repo that calls auto-approve, then accepts the invite using `APPROVER_PAT`. **Required** — approvals only *count* toward required-review rules when the approver has write access. |
| [`scripts/grant-approver-collaborator.sh`](scripts/grant-approver-collaborator.sh) | Bash equivalent. |

## First-time setup

### 1. Create the GitHub App

1. <https://github.com/settings/apps/new>
2. Name: `aks-codeowner-bot` (or whatever's unique)
3. Webhook: **uncheck Active**
4. Repository permissions:
   - **Pull requests:** Read & write
   - **Contents:** Read
   - **Metadata:** Read
5. Installation target: **Only on this account**
6. Create → note the **App ID** (top of settings page) → **Generate a private key** (downloads a `.pem`).
7. Sidebar → **Install App** → install on **All repositories**.

### 2. Distribute the secrets

Pick one path.

#### Option A — local (recommended for first run)

```powershell
# from a clone of this repo
cd C:\NashTech\workflows
./scripts/distribute-secrets.ps1 `
  -AppId 123456 `
  -PrivateKeyPath C:\path\to\aks-codeowner-bot.private-key.pem `
  -DryRun

# When the dry-run output looks right:
./scripts/distribute-secrets.ps1 -AppId 123456 -PrivateKeyPath C:\path\to\bot.pem
```

Or bash:

```bash
./scripts/distribute-secrets.sh \
  --app-id 123456 \
  --private-key ~/keys/aks-codeowner-bot.private-key.pem \
  --dry-run

./scripts/distribute-secrets.sh --app-id 123456 --private-key ~/keys/bot.pem
```

#### Option B — from the Actions tab (zero-laptop run)

One-time bootstrap: this repo needs three of its own secrets so the workflow can push to other repos.

```powershell
cd C:\NashTech\workflows
gh secret set APPROVER_APP_ID --body "123456"
gh secret set APPROVER_APP_PRIVATE_KEY --body "$(Get-Content C:\path\to\bot.pem -Raw)"

# DISTRIBUTOR_PAT = your own classic PAT with `repo` scope.
# Create at https://github.com/settings/tokens (Tokens classic).
# Needed because GITHUB_TOKEN can't write secrets to OTHER repos.
gh secret set DISTRIBUTOR_PAT --body "ghp_xxxxxxxxxxxxxxxx"
```

Then trigger from the GitHub UI: **Actions → Distribute bot secrets to all repos → Run workflow** (start with `dry-run = true`).

### 3. Deploy the caller workflow into every repo

The reusable workflow only fires on repos that have a tiny caller file. Use `deploy-caller`:

```powershell
cd C:\NashTech\workflows
./scripts/deploy-caller.ps1 -DryRun
# review which repos would receive the file, then:
./scripts/deploy-caller.ps1
```

Or bash:

```bash
./scripts/deploy-caller.sh --dry-run
./scripts/deploy-caller.sh
```

The script is **idempotent**: re-running on a repo that already has the file is a no-op. To roll out a change to the caller (e.g. enabling `wait-for-checks`), use `-Overwrite` / `--overwrite`.

The file it deploys is:

```yaml
name: Auto-approve

on:
  pull_request:
    types: [opened, ready_for_review, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write

jobs:
  call:
    uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main
    secrets: inherit
```

`secrets: inherit` forwards `APPROVER_APP_ID` + `APPROVER_APP_PRIVATE_KEY` (placed by `distribute-secrets`) into the reusable workflow.

> **The `permissions:` block is required, not optional.** A called workflow can never be granted more token scope than its caller. The reusable workflow requests `pull-requests: write` to post the approval, so the caller must grant at least that much. If you omit the block, the caller inherits the repo's default token — and on the common read-only default the entire run fails **at startup** (no jobs, no logs) with: `The workflow is requesting 'pull-requests: write', but is only allowed 'pull-requests: none'.` Setting it per-caller keeps the token least-privilege; the alternative (flipping the repo-wide default to read/write) is broader and not recommended.

To wait for required status checks before approving:

```yaml
jobs:
  call:
    uses: aks-builds/workflows/.github/workflows/auto-approve.yml@main
    with:
      wait-for-checks: true
    secrets: inherit
```

### 4. Grant the approver account write access

> **Required — without this, approvals are posted but ignored.** Branch
> rules (and rulesets) only **count** approving reviews from identities with
> **write** access to the repo. The bot/PAT can submit an approval, but if the
> approving account is only a read collaborator (or not a collaborator at all),
> the review shows as "Approved" yet `reviewDecision` stays `REVIEW_REQUIRED`
> and the PR never satisfies `required_approving_review_count`.

Adding a collaborator creates a *pending invitation* the approver must accept,
so the script does both — invites with the owner's admin auth, then accepts
using the approver's own token (`APPROVER_PAT`):

```powershell
cd C:\NashTech\workflows
$env:APPROVER_PAT = 'ghp_xxxxxxxxxxxxxxxx'   # aks-reviewes's token
./scripts/grant-approver-collaborator.ps1 -DryRun
# review, then:
./scripts/grant-approver-collaborator.ps1
```

Or bash:

```bash
export APPROVER_PAT='ghp_xxxxxxxxxxxxxxxx'
./scripts/grant-approver-collaborator.sh --dry-run
./scripts/grant-approver-collaborator.sh
```

Or zero-laptop, from the Actions tab: **Grant approver write access to all
caller repos → Run workflow** (needs `DISTRIBUTOR_PAT` + `APPROVER_PAT` set as
secrets on this repo). By default it targets only repos that have the
auto-approve caller; pass `--all-repos` / the `all-repos` input to cover every
active repo. It's idempotent — repos where the approver already has write are
skipped.

## Why a personal-account "centralized secrets" story needs the distributor

GitHub's secret store for Actions is **per-repo on personal accounts**. Organization-level secrets exist but require an Organization account. The distributor closes the gap: one source of truth (this repo) + one command (`distribute-secrets`) pushes the value into every repo at once.

If you ever convert your account to (or move repos into) a free Organization, you can:

1. Set `APPROVER_APP_ID` + `APPROVER_APP_PRIVATE_KEY` once as **organization secrets** with access scope "all repositories".
2. Drop the distributor entirely — the reusable workflow will pick them up automatically via `secrets: inherit`.

Until then, run the distributor:

- After creating any new repo (or run with `--exclude` for the ones you don't want covered).
- After rotating the GitHub App's private key (re-download the `.pem`, re-run).
- After adding a new account-wide secret variable.

## Rotating the App's private key

1. <https://github.com/settings/apps/aks-codeowner-bot> → **Generate a private key** → download new `.pem`.
2. Re-run the distributor with the new file.
3. Once you've confirmed PRs approve correctly, revoke the old key from the same settings page.

## Pausing the bot

Either:

- **Suspend the installation:** <https://github.com/settings/installations> → suspend `aks-codeowner-bot`. Workflows still trigger but the `app-token` step will fail loudly.
- **Soft pause:** comment out the `call:` job in the consumer repo, or rename the workflow file to `.disabled`.

## License

[MIT](LICENSE)
