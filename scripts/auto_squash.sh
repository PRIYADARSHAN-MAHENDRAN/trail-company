#!/usr/bin/env sh
# auto-squash.sh
# Squash all commits since merge-base with dev, but preserve the last commit on top.
# Exits non-zero on conflicts or unexpected situations.

set -eu
# optional: make piping failures visible
set -o pipefail 2>/dev/null || true

# config: base branch and remote
BASE_BRANCH=${BASE_BRANCH:-dev}
REMOTE=${REMOTE:-origin}

# record current branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
printf 'Current branch: %s\n' "$BRANCH"

# skip protected branches
if [ "$BRANCH" = "$BASE_BRANCH" ] || [ "$BRANCH" = "prod" ]; then
  printf 'On protected branch (%s) — skipping.\n' "$BRANCH"
  exit 0
fi

# fetch base branch to ensure we have up-to-date merge-base
printf 'Fetching %s/%s...\n' "$REMOTE" "$BASE_BRANCH"
git fetch "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1

BASE_REF="$REMOTE/$BASE_BRANCH"

# check if base commit is ancestor of HEAD (i.e. branch is based on updated dev)
if git merge-base --is-ancestor "$BASE_REF" HEAD; then
  printf '%s is an ancestor of HEAD — proceeding.\n' "$BASE_REF"
else
  printf 'ERROR: %s is NOT an ancestor of HEAD. Please rebase your branch onto %s and try again.\n' "$BASE_REF" "$BASE_BRANCH" >&2
  exit 1
fi

# count commits ahead of base
COMMITS_AHEAD=$(git rev-list --count HEAD ^"$BASE_REF" || true)
printf 'Commits ahead of %s: %s\n' "$BASE_REF" "$COMMITS_AHEAD"

# nothing to do if 0 or 1 commits ahead (1 means only last commit exists; nothing to squash)
if [ "$COMMITS_AHEAD" -le 1 ]; then
  printf 'Nothing to squash (0 or 1 commit ahead). Exiting.\n'
  exit 0
fi

# compute merge-base and last commit
MERGE_BASE=$(git merge-base HEAD "$BASE_REF")
LAST_COMMIT=$(git rev-parse HEAD)
printf 'Merge-base: %s\nLast commit: %s\n' "$MERGE_BASE" "$LAST_COMMIT"

# prepare temp branch name
TMP_BRANCH="autosquash-temp-$(date +%s)-$RANDOM"
printf 'Creating temporary branch: %s\n' "$TMP_BRANCH"

# create temp branch from HEAD so we can go back easily if needed
git branch "$TMP_BRANCH" >/dev/null 2>&1 || true

# checkout the temp branch
git checkout -b "$TMP_BRANCH"

# reset hard to merge-base (clean slate)
git reset --hard "$MERGE_BASE"

# build the list of commits to squash: all commits after merge-base up to HEAD^ (everything except last)
# get them in chronological order:
COMMITS_TO_SQUASH=$(git rev-list --reverse "$MERGE_BASE".."${LAST_COMMIT}^" || true)

if [ -z "$COMMITS_TO_SQUASH" ]; then
  printf 'No commits found to squash (unexpected). Exiting.\n' >&2
  exit 1
fi

# cherry-pick each commit without committing (stages their changes)
printf 'Cherry-picking %s commits (no-commit) ...\n' "$(echo "$COMMITS_TO_SQUASH" | wc -l)"
# iterate commits
echo "$COMMITS_TO_SQUASH" | while IFS= read -r c; do
  printf 'Applying %s ...\n' "$c"
  # stop on conflict: let git report and exit non-zero
  git cherry-pick --no-commit "$c" || {
    printf 'Conflict during cherry-pick of %s. Resolve locally and re-run, or abort.\n' "$c" >&2
    # checkout original branch back for safety
    git checkout - >/dev/null 2>&1 || true
    exit 2
  }
done

# create a single squashed commit (if there are staged changes)
if git diff --cached --quiet; then
  printf 'No staged changes after applying commits — nothing to squash.\n'
else
  SQ_MSG="Squashed: all commits except last on branch $BRANCH (base: $BASE_BRANCH)"
  git commit -m "$SQ_MSG"
  printf 'Created single squashed commit.\n'
fi

# cherry-pick last commit on top to preserve it exactly
printf 'Cherry-picking last commit (%s) on top ...\n' "$LAST_COMMIT"
git cherry-pick --keep-redundant-commits "$LAST_COMMIT" || {
  printf 'Conflict while cherry-picking the last commit %s. Resolve locally and re-run.\n' "$LAST_COMMIT" >&2
  git checkout - >/dev/null 2>&1 || true
  exit 3
}

# push result back to the original branch (force-with-lease)
printf 'Force-pushing to %s/%s ...\n' "$REMOTE" "$BRANCH"
git push "$REMOTE" "HEAD:$BRANCH" --force-with-lease || {
  printf 'Push failed. Aborting and cleaning up.\n' >&2
  git checkout - >/dev/null 2>&1 || true
  exit 4
}

# cleanup: checkout original branch and delete temp branch
git checkout "$BRANCH" >/dev/null 2>&1 || true
git branch -D "$TMP_BRANCH" >/dev/null 2>&1 || true

printf '✅ Auto-squash complete. Branch %s updated (squashed except last commit preserved).\n' "$BRANCH"
exit 0
