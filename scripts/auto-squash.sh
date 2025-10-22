#!/usr/bin/env sh
# scripts/auto-squash-single-commit.sh
# Squash all commits since merge-base with dev into ONE commit.
# Use the last non-merge commit message (preferable) or last commit message.
# Exits:
#  0 success
#  1 generic failure
#  2 nothing to do (0/1 commits ahead)
#  3 push failed

set -eu
set -o pipefail 2>/dev/null || true

BASE_BRANCH=${BASE_BRANCH:-dev}
REMOTE=${REMOTE:-origin}
PR_HEAD_SHA=${PR_HEAD_SHA:-}

# Resolve branch: prefer PR_HEAD_REF or GITHUB_HEAD_REF if set, else fallback to git
if [ -n "${GITHUB_HEAD_REF:-}" ]; then
  BRANCH="$GITHUB_HEAD_REF"
elif [ -n "${PR_HEAD_REF:-}" ]; then
  BRANCH="$PR_HEAD_REF"
else
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

printf 'Resolved branch: %s\n' "$BRANCH"

# If a PR_HEAD_SHA was provided, ensure we are on that commit (safety check)
if [ -n "${PR_HEAD_SHA:-}" ]; then
  CURRENT_SHA=$(git rev-parse HEAD)
  printf 'Current HEAD: %s    PR_HEAD_SHA: %s\n' "$CURRENT_SHA" "$PR_HEAD_SHA"
  if [ "$CURRENT_SHA" != "$PR_HEAD_SHA" ]; then
    # Try to checkout the exact SHA (safe because fetch-depth=0)
    printf 'Checking out PR head SHA to ensure correct tip...\n'
    git checkout "$PR_HEAD_SHA" || {
      printf 'Failed to checkout PR head SHA %s\n' "$PR_HEAD_SHA" >&2
      exit 1
    }
  fi
fi

# Skip protected branches
if [ "$BRANCH" = "$BASE_BRANCH" ] || [ "$BRANCH" = "prod" ]; then
  printf 'On protected branch (%s) — skipping.\n' "$BRANCH"
  exit 0
fi

# Ensure base branch fetched
printf 'Fetching %s/%s...\n' "$REMOTE" "$BASE_BRANCH"
git fetch "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1 || {
  printf 'Failed to fetch %s/%s\n' "$REMOTE" "$BASE_BRANCH" >&2
  exit 1
}
BASE_REF="$REMOTE/$BASE_BRANCH"

# Confirm branch is based on base branch
if git merge-base --is-ancestor "$BASE_REF" HEAD; then
  printf '%s is ancestor of HEAD — proceeding.\n' "$BASE_REF"
else
  printf 'ERROR: %s is NOT an ancestor of HEAD. Please rebase your branch onto %s and try again.\n' "$BASE_REF" "$BASE_BRANCH" >&2
  exit 1
fi

COMMITS_AHEAD=$(git rev-list --count HEAD ^"$BASE_REF" || true)
printf 'Commits ahead of %s: %s\n' "$BASE_REF" "$COMMITS_AHEAD"

if [ "$COMMITS_AHEAD" -le 1 ]; then
  printf 'Nothing to squash (0 or 1 commit ahead). Exiting.\n'
  exit 2
fi

MERGE_BASE=$(git merge-base HEAD "$BASE_REF")
LAST_COMMIT_SHA=$(git rev-parse HEAD)
printf 'Merge-base: %s\nHEAD: %s\n' "$MERGE_BASE" "$LAST_COMMIT_SHA"

# Find the last non-merge commit (preferred message)
LAST_NON_MERGE=$(git rev-list --no-merges -n 1 HEAD || true)

if [ -n "$LAST_NON_MERGE" ]; then
  LAST_MSG=$(git --no-pager log -1 --pretty=%B "$LAST_NON_MERGE" || true)
  printf 'Using last non-merge commit %s message for squash.\n' "$LAST_NON_MERGE"
else
  LAST_MSG=$(git --no-pager log -1 --pretty=%B HEAD || true)
  printf 'No non-merge commits found; using HEAD message.\n'
fi

if [ -z "$LAST_MSG" ]; then
  LAST_MSG="Squashed changes from branch $BRANCH"
fi

# Prepare temporary branch to build squashed commit
TMP_BRANCH="autosquash-single-$(date +%s)-$RANDOM"
printf 'Creating temporary branch: %s\n' "$TMP_BRANCH"
git checkout -b "$TMP_BRANCH" || {
  printf 'Failed to create temporary branch %s\n' "$TMP_BRANCH" >&2
  exit 1
}

# Soft-reset to merge-base (stages all changes since merge-base)
git reset --soft "$MERGE_BASE" || {
  printf 'Failed to soft-reset to merge-base %s\n' "$MERGE_BASE" >&2
  git checkout - >/dev/null 2>&1 || true
  exit 1
}

# Safety: ensure there are staged changes
if git diff --cached --quiet; then
  printf 'No staged changes after soft reset — aborting.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

# Commit everything as single commit using LAST_MSG
printf 'Committing single squashed commit with provided message...\n'
git commit -m "$LAST_MSG" || {
  printf 'Failed to create squashed commit.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true
  exit 1
}

# Force-push back to original branch
printf 'Force-pushing single-squash to %s/%s ...\n' "$REMOTE" "$BRANCH"
if ! git push "$REMOTE" "HEAD:$BRANCH" --force-with-lease; then
  printf 'Push failed.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true
  exit 3
fi

# Cleanup
git checkout "$BRANCH" >/dev/null 2>&1 || true
git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true

printf '✅ Single-squash complete. Branch %s now has one commit (message copied from last non-merge commit).\n' "$BRANCH"
exit 0
