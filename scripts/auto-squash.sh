#!/usr/bin/env sh
# scripts/auto-squash.sh
# Robust autosquash that preserves last commit, and handles merge commits.
# Exit codes: 1 = generic failure, 2 = conflict during intermediate cherry-pick,
# 3 = conflict during last-commit cherry-pick (after trying parent candidates),
# 4 = push failed

set -eu
set -o pipefail 2>/dev/null || true

BASE_BRANCH=${BASE_BRANCH:-dev}
REMOTE=${REMOTE:-origin}

# Resolve branch: prefer GITHUB_HEAD_REF in Actions, else use git
if [ -n "${GITHUB_HEAD_REF:-}" ]; then
  BRANCH="$GITHUB_HEAD_REF"
else
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

printf 'Branch resolved to: %s\n' "$BRANCH"

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

git checkout -b "$TMP_BRANCH" || {
  printf 'Failed to create temporary branch %s\n' "$TMP_BRANCH" >&2
  exit 1
}

git reset --hard "$MERGE_BASE" || {
  printf 'Failed to reset to merge-base %s\n' "$MERGE_BASE" >&2
  git checkout - >/dev/null 2>&1 || true
  exit 1
}

ALL_COMMITS=$(git rev-list --reverse "$MERGE_BASE".."$LAST_COMMIT" || true)
if [ -z "$ALL_COMMITS" ]; then
  printf 'No commits found between merge-base and HEAD (unexpected).\n' >&2
  git checkout - >/dev/null 2>&1 || true
  exit 1
fi
COMMITS_TO_SQUASH=$(printf '%s\n' "$ALL_COMMITS" | sed '$d' || true)

if [ -z "$COMMITS_TO_SQUASH" ]; then
  printf 'No commits to squash after dropping last commit — nothing to do.\n'
  git checkout "$BRANCH" >/dev/null 2>&1 || true
  git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true
  exit 0
fi

printf 'Applying %s commits (no-commit) ...\n' "$(printf '%s\n' "$COMMITS_TO_SQUASH" | wc -l)"
echo "$COMMITS_TO_SQUASH" | while IFS= read -r c; do
  printf 'Applying %s ...\n' "$c"
  if ! git cherry-pick --no-commit "$c"; then
    printf 'Conflict during cherry-pick of %s. See git status for details.\n' "$c" >&2
    git status --porcelain --branch || true
    git checkout - >/dev/null 2>&1 || true
    exit 2
  fi
done

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

# --- NEW: Robust handling for last commit that might be a merge ---
# Determine parent count of last commit
PARENTS_LINE=$(git rev-list --parents -n1 "$LAST_COMMIT" || true)
# example: "<commit> <parent1> <parent2> ...", so count words minus 1
PARENT_COUNT=$(printf '%s\n' "$PARENTS_LINE" | awk '{print NF-1}')

printf 'Last commit parent count: %s\n' "$PARENT_COUNT"

if [ "$PARENT_COUNT" -le 1 ]; then
  # normal single-parent commit
  printf 'Cherry-picking last commit (%s) on top ...\n' "$LAST_COMMIT"
  if ! git cherry-pick --keep-redundant-commits "$LAST_COMMIT"; then
    printf 'Conflict while cherry-picking the last commit %s. See git status for details.\n' "$LAST_COMMIT" >&2
    git status --porcelain --branch || true
    git checkout - >/dev/null 2>&1 || true
    exit 3
  fi
else
  # merge commit: try to cherry-pick by selecting a mainline parent.
  # Try -m 1, then -m 2 (common choices). If both fail, abort and show diagnostics.
  printf 'Last commit is a merge commit with %s parents. Attempting cherry-pick with -m options.\n' "$PARENT_COUNT"

  TRIED=0
  SUCCESS=0
  i=1
  while [ $i -le $PARENT_COUNT ]; do
    printf 'Attempting: git cherry-pick -m %s %s\n' "$i" "$LAST_COMMIT"
    if git cherry-pick -m "$i" --keep-redundant-commits "$LAST_COMMIT"; then
      SUCCESS=1
      printf 'Cherry-pick with -m %s succeeded.\n' "$i"
      break
    else
      printf 'Cherry-pick with -m %s failed. Resetting index and trying next parent if available.\n' "$i"
      # abort the failed cherry-pick and reset working tree
      git cherry-pick --abort >/dev/null 2>&1 || true
    fi
    i=$((i + 1))
  done

  if [ $SUCCESS -ne 1 ]; then
    printf 'ERROR: All attempts to cherry-pick merge commit %s with -m <parent> failed.\n' "$LAST_COMMIT" >&2
    printf 'You will need to resolve this merge manually. Dumping helpful git state:\n'
    git --no-pager log -1 --pretty=fuller "$LAST_COMMIT" || true
    git status --porcelain --branch || true
    git --no-pager log --graph --oneline --decorate --all -n 40 || true
    git checkout - >/dev/null 2>&1 || true
    exit 3
  fi
fi

printf 'Attempting to push rebuilt branch back to origin/%s ...\n' "$BRANCH"
if ! git push "$REMOTE" "HEAD:$BRANCH" --force-with-lease; then
  printf 'Push failed.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  exit 4
fi

git checkout "$BRANCH" >/dev/null 2>&1 || true
git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true

printf '✅ Auto-squash complete. Branch %s updated (squashed except last commit preserved).\n' "$BRANCH"
exit 0
