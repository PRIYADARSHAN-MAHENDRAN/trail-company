#!/bin/bash
set -euxo pipefail

# Determine current branch (the checked-out ref in Actions)
branch=$(git rev-parse --abbrev-ref HEAD)

commit_rebase() {
    echo "Starting rebase for branch: $branch"

    # Stash current uncommitted changes (if any)
    stash_name="auto_rebase_stash_$(date +%s)"
    git stash push -u -m "$stash_name" || true

    # Ensure latest dev branch from origin
    git fetch --prune origin dev
    git checkout dev
    git pull origin dev

    # Return to original branch and rebase onto origin/dev using 'theirs' merge strategy option
    git checkout "$branch"

    # Rebase and prefer origin/dev changes on conflicts (use -X theirs to favor the upstream branch)
    if git rebase origin/dev -X theirs; then
        echo "Rebase completed successfully."
    else
        echo "Rebase conflict detected. Aborting rebase..."
        git rebase --abort || true
        git checkout "$branch"
        # Restore stash if present
        if git stash list | grep -q "$stash_name"; then
            git stash pop "$(git stash list --pretty=%gd | head -1)" || true
        fi
        return 1
    fi

    # Restore stashed changes (if any)
    if git stash list | grep -q "$stash_name"; then
        git stash pop "$(git stash list --pretty=%gd | head -1)" || true
        echo "Restored stashed changes."
    else
        echo "No stash to restore."
    fi

    return 0
}

if [[ "$branch" == "dev" || "$branch" == "prod" ]]; then
    echo "You are on the dev or prod branch. Skipping rebase."
    exit 0
else
    commit_rebase
fi
