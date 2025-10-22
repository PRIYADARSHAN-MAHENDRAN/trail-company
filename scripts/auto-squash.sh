#!/usr/bin/env sh
# scripts/auto-squash.sh
# Improved auto-squash with better logging and distinct exit codes:
# 1 = generic failure, 2 = conflict during intermediate cherry-pick,
# 3 = conflict during last-commit cherry-pick, 4 = push failed

set -eu
set -o pipefail 2>/dev/null || true

BASE_BRANCH=${BASE_BRANCH:-dev}
REMOTE=${REMOTE:-origin}

BRANCH=$(git rev-parse --abbrev-ref HEAD)
printf 'Current branch: %s\n' "$BRANCH"

if [ "$BRANCH" = "$BASE_BRANCH" ] || [ "$BRANCH" = "prod" ]; then
  printf 'On protected branch (%s) — skipping.\n' "$BRANCH"
  exit 0
fi

printf 'Fetching %s/%s...\n' "$REMOTE" "$BASE_BRANCH"
git fetch "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1 || {
  printf 'Failed to fetch %s/%s\n' "$REMOTE" "$BASE_BRANCH" >&2
  exit 1
}

BASE_REF="$REMOTE/$BASE_BRANCH"

if git merge-base --is-ancestor "$BASE_REF" HEAD; then
  printf '%s is an ancestor of HEAD — proceeding.\n' "$BASE_REF"
else
  printf 'ERROR: %s is NOT an ancestor of HEAD. Please rebase your branch onto %s and try again.\n' "$BASE_REF" "$BASE_BRANCH" >&2
  exit 1
fi

COMMITS_AHEAD=$(git rev-list --count HEAD ^"$BASE_REF" || true)
printf 'Commits ahead of %s: %s\n' "$BASE_REF" "$COMMITS_AHEAD"

if [ "$COMMITS_AHEAD" -le 1 ]; then
  printf 'Nothing to squash (0 or 1 commit ahead). Exiting.\n'
  exit 0
fi

MERGE_BASE=$(git merge-base HEAD "$BASE_REF")
LAST_COMMIT=$(git rev-parse HEAD)
printf 'Merge-base: %s\nLast commit: %s\n' "$MERGE_BASE" "$LAST_COMMIT"

TMP_BRANCH="autosquash-temp-$(date +%s)-$RANDOM"
printf 'Creating temporary branch: %s\n' "$TMP_BRANCH"

# create and checkout the temp branch
git checkout -b "$TMP_BRANCH" || {
  printf 'Failed to create temporary branch %s\n' "$TMP_BRANCH" >&2
  exit 1
}

git reset --hard "$MERGE_BASE" || {
  printf 'Failed to reset to merge-base %s\n' "$MERGE_BASE" >&2
  git checkout - >/dev/null 2>&1 || true
  exit 1
}

# compute commits to squash
COMMITS_TO_SQUASH=$(git rev-list --reverse "$MERGE_BASE".."${LAST_COMMIT}^" || true)

if [ -z "$COMMITS_TO_SQUASH" ]; then
  printf 'No commits found to squash (unexpected).\n' >&2
  git checkout - >/dev/null 2>&1 || true
  exit 1
fi

echo "$COMMITS_TO_SQUASH" | while IFS= read -r c; do
  printf 'Applying commit %s (no-commit)...\n' "$c"
  if ! git cherry-pick --no-commit "$c"; then
    printf 'Conflict during cherry-pick of %s. See git status for details.\n' "$c" >&2
    git status --porcelain --branch || true
    git checkout - >/dev/null 2>&1 || true
    exit 2
  fi
done

# create squashed commit if staged changes exist
if git diff --cached --quiet; then
  printf 'No staged changes after applying commits — nothing to squash.\n'
else
  SQ_MSG="Squashed: all commits except last on branch $BRANCH (base: $BASE_BRANCH)"
  git commit -m "$SQ_MSG" || {
    printf 'Failed to create squashed commit.\n' >&2
    git checkout - >/dev/null 2>&1 || true
    exit 1
  }
  printf 'Created single squashed commit.\n'
fi

printf 'Cherry-picking last commit (%s) on top ...\n' "$LAST_COMMIT"
if ! git cherry-pick --keep-redundant-commits "$LAST_COMMIT"; then
  printf 'Conflict while cherry-picking the last commit %s. See git status for details.\n' "$LAST_COMMIT" >&2
  git status --porcelain --branch || true
  git checkout - >/dev/null 2>&1 || true
  exit 3
fi

printf 'Force-pushing to %s/%s ...\n' "$REMOTE" "$BRANCH"
if ! git push "$REMOTE" "HEAD:$BRANCH" --force-with-lease; then
  printf 'Push failed.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  exit 4
fi

# cleanup
git checkout "$BRANCH" >/dev/null 2>&1 || true
git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true

printf '✅ Auto-squash complete. Branch %s updated (squashed except last commit preserved).\n' "$BRANCH"
exit 0
