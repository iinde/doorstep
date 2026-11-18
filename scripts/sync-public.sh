#!/bin/bash
# Publish the current committed tree to the public repo as one new commit.
# The private working history (and its author emails) never leaves this Mac.
#   scripts/sync-public.sh "What changed"
set -euo pipefail
cd "$(dirname "$0")/.."
MSG="${1:?usage: scripts/sync-public.sh \"message\"}"
REPO="${DOORSTEP_SOURCE_REPO:-iinde/doorstep}"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit your changes first."; exit 1; }
WORK=$(mktemp -d)
gh repo clone "$REPO" "$WORK/public" -- -q
( cd "$WORK/public" && git rm -rq . )
git archive HEAD | tar -x -C "$WORK/public"
cd "$WORK/public"
git add -A
if git diff --cached --quiet; then echo "Nothing new to publish."; exit 0; fi
LOGIN=$(gh api user --jq .login); ID=$(gh api user --jq .id)
git -c user.name="$LOGIN" -c user.email="${ID}+${LOGIN}@users.noreply.github.com" commit -q -m "$MSG"
git push -q origin main
echo "▸ Published to https://github.com/$REPO ($(git rev-parse --short HEAD))"
rm -rf "$WORK"
