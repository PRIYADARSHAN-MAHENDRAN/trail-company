#!/bin/bash
set -e
set -euxo pipefail

branch=$(git rev-parse --abbrev-ref HEAD)

commit_rebase() {
    echo "No commit matches with the HEAD of the dev branch."
    git add .
    git stash -m "my_stash_name"
    git checkout dev
    git pull origin dev
    git checkout $branch
    git rebase dev --strategy=option=theirs
    git stash pop $(git stash list --pretty=%gd %s | grep 'my_stash_name' | head -1 | awk '{print $1}')
    echo "Rebase completed."
}

if [[ "$branch" == "dev" || "$branch" == "prod" ]]; then
    echo "You are on the dev or prod branch."
    exit 0
else
    git add .
    commit_rebase
fi