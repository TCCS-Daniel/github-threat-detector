#!/usr/bin/env bash
# reviewdog / action-setup supply-chain attack simulation (minimal: tag flip-flop)
#
# that is poisoned and then REVERTED to hide it (clean -> malicious -> clean).
#
# Simulated TTPs (reviewdog STAGE B only):
#   * Single floating tag `v1` force-repointed onto a malicious commit.
#   * Malicious commit is off every branch (pushed to the tag ref only).
#   * Unsigned commit on a tag whose baseline was GitHub-signed (web-flow).
#   * Tag flip-flop cover-up: after a wait, `v1` reverted to the clean commit.
#
# poisoned state while it is live (WAIT_SECONDS, default 360s > 3-min snapshot),
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"                      # victim upstream owner (org)
REPO=sim-reviewdog             # victim repo (a composite GitHub Action)
POISON_TAG=v1                  # the SINGLE floating major tag that gets repointed
SETTLE_SECONDS="${SETTLE_SECONDS:-240}" # clean dwell BEFORE poisoning; >3 min so a snapshot records the clean baseline (=> clean->malicious edge lands in repo_tags_history)
WAIT_SECONDS="${WAIT_SECONDS:-360}"   # poison->revert wait; >~3 min so the snapshot poller fires

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch main
git config --global credential.helper '!gh auth git-credential'

echo "=== target: $ORG/$REPO  tag=$POISON_TAG  settle=${SETTLE_SECONDS}s  wait=${WAIT_SECONDS}s ==="

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
gh repo delete "$ORG/$REPO" --yes 2>/dev/null || true
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed repo + a SIGNED clean v1 (the legitimate baseline) ==="
gh repo create "$ORG/$REPO" --public --add-readme >/dev/null
sleep 3
DEFBR=$(gh api "repos/$ORG/$REPO" -q '.default_branch')

# The whole payload is just one indicative text file: clean vs infected.
CLEAN_CONTENT='clean'
CONTENT_B64=$(printf '%s' "$CLEAN_CONTENT" | base64 | tr -d '\n')

# Contents API -> commit is web-flow signed => verified=true. The clean baseline.
RESP=$(gh api -X PUT "repos/$ORG/$REPO/contents/payload.txt" \
        -f message="release v1.0.0 (#101)" \
        -f content="$CONTENT_B64" -f branch="$DEFBR")
CLEAN_SHA=$(echo "$RESP" | jq -r '.commit.sha')
gh api -X POST "repos/$ORG/$REPO/git/refs" -f ref="refs/tags/$POISON_TAG" -f sha="$CLEAN_SHA" >/dev/null
echo "  $POISON_TAG -> $CLEAN_SHA  (clean, signed)"

# -----------------------------------------------------------------------------
echo "=== [1b] SETTLE on clean (let a snapshot record the clean baseline) ==="
echo "  sleeping ${SETTLE_SECONDS}s ..."
sleep "$SETTLE_SECONDS"

# -----------------------------------------------------------------------------
echo "=== [2] craft a malicious (unsigned, off-branch) commit ==="
cd /tmp; rm -rf "$REPO"; git clone -q "https://github.com/$ORG/$REPO"; cd "$REPO"
echo 'infected' > payload.txt
git add payload.txt
git commit -q -m "Fix: update setup script"   # plain local commit => UNSIGNED
MALICIOUS_SHA=$(git rev-parse HEAD)
echo "  malicious commit = $MALICIOUS_SHA (unsigned)"

# -----------------------------------------------------------------------------
echo "=== [3] ATTACK: force-repoint v1 onto the malicious commit ==="
# Push to the TAG ref only (never a branch) -> commit stays off every branch.
# Single tag => a webhook push fires (before=clean, after=malicious).
git push -q --force origin "$MALICIOUS_SHA:refs/tags/$POISON_TAG"
echo "  $POISON_TAG -> $MALICIOUS_SHA  (POISONED)"

# -----------------------------------------------------------------------------
echo "=== [4] WAIT (let the snapshot poller record the poisoned tag) ==="
echo "  sleeping ${WAIT_SECONDS}s ..."
sleep "$WAIT_SECONDS"

# -----------------------------------------------------------------------------
echo "=== [5] COVER-UP: revert v1 back to the clean commit (the flip-flop) ==="
git push -q --force origin "$CLEAN_SHA:refs/tags/$POISON_TAG"
echo "  $POISON_TAG -> $CLEAN_SHA  (reverted; looks clean again)"

echo "=== DONE ==="
echo "  flip-flop in repo_tags_history:  $CLEAN_SHA -> $MALICIOUS_SHA -> $CLEAN_SHA"
echo "  tags: https://github.com/$ORG/$REPO/tags"
