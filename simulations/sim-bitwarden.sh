#!/usr/bin/env bash
# bitwarden / trusted-publishing supply-chain attack simulation (minimal)
#
# Models the Bitwarden CLI npm-hijack pattern: a compromised maintainer account
# REWRITES an existing publish workflow so it mints a GitHub Actions OIDC token,
# exchanges it for a registry auth token, and publishes -- triggered from a
# NON-default ref (a tag) rather than the protected release branch.
#
# Simulated TTPs:
#   * Existing publish workflow MODIFIED (not added) on a side branch.
#   * In-workflow branch guard removed; trigger downgraded to `on: push: tags`.
#   * Workflow granted `id-token: write` + a manual OIDC->registry token exchange.
#   * Stolen token echoed to the run log (base64) -- secret exfil marker.
#   * Unsigned commit on the publish workflow.
#   * Workflow RUN fires from a non-default ref (the tag).
#   * Run + logs deleted afterwards (anti-forensics) when COVER_TRACKS=1.
#
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"                        # victim owner (org)
REPO=sim-release                 # victim repo (ships a package via a publish workflow)
WF_PATH=".github/workflows/publish-pkg.yml"   # the existing publish workflow
ATTACK_BRANCH=release-fix        # NON-default side branch the rewrite lands on
TAG=pkg-v1.0.1                   # tag pushed to trigger the rewritten workflow
WAIT_SECONDS="${WAIT_SECONDS:-45}"  # let the run register in telemetry

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch main
git config --global credential.helper '!gh auth git-credential'

echo "=== target: $ORG/$REPO  workflow=$WF_PATH  branch=$ATTACK_BRANCH  tag=$TAG ==="

# Legit baseline publish workflow: dispatch-only, branch-guarded, NO id-token.
read -r -d '' LEGIT_WF <<'YML' || true
name: publish-pkg
run-name: Publish package
on:
  workflow_dispatch:
    inputs:
      version:
        description: version to publish
        required: true
permissions:
  contents: read
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - name: Branch check
        run: |
          if [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
            echo "can only publish from main"; exit 1
          fi
      - name: Build and publish
        run: echo "build + publish package (legitimate)"
YML

# Malicious rewrite: id-token, tag trigger, guard removed, OIDC-exchange markers.
# All steps are inert echoes; the token is a placeholder, no network calls.
read -r -d '' EVIL_WF <<'YML' || true
name: publish-pkg
run-name: Publish package
on:
  push:
    tags:
permissions:
  id-token: write
  contents: read
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - name: Mint and exchange token
        run: |
          echo "request OIDC token via ACTIONS_ID_TOKEN_REQUEST_URL (simulated)"
          echo "POST registry endpoint /oidc/token/exchange (simulated)"
          REGISTRY_TOKEN="sim-placeholder-not-a-real-token"
          echo "$REGISTRY_TOKEN" | base64   # exfil marker (simulated)
          echo "config set //registry/:_authToken (simulated)"
      - name: Publish
        run: echo "publish ./dist/pkg-sim.tgz (simulated, benign)"
YML

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
gh repo delete "$ORG/$REPO" --yes 2>/dev/null || true
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed repo + the LEGIT publish workflow (baseline) ==="
gh repo create "$ORG/$REPO" --public --add-readme >/dev/null
sleep 3
DEFBR=$(gh api "repos/$ORG/$REPO" -q '.default_branch')

# Contents API -> web-flow signed commit => the legitimate, verified baseline.
WF_B64=$(printf '%s' "$LEGIT_WF" | base64 | tr -d '\n')
gh api -X PUT "repos/$ORG/$REPO/contents/$WF_PATH" \
  -f message="ci: add package publish workflow" \
  -f content="$WF_B64" -f branch="$DEFBR" >/dev/null
echo "  seeded legit $WF_PATH on $DEFBR (signed)"

# -----------------------------------------------------------------------------
echo "=== [2] ATTACK: rewrite the publish workflow on a side branch (unsigned) ==="
cd /tmp; rm -rf "$REPO"; git clone -q "https://github.com/$ORG/$REPO"; cd "$REPO"
git checkout -q -b "$ATTACK_BRANCH"
printf '%s\n' "$EVIL_WF" > "$WF_PATH"
git add "$WF_PATH"
git commit -q -m "chore: tweak publish workflow"   # plain local commit => UNSIGNED
EVIL_SHA=$(git rev-parse HEAD)
git push -q origin "$ATTACK_BRANCH"
echo "  rewrote $WF_PATH on $ATTACK_BRANCH @ $EVIL_SHA (unsigned)"

# -----------------------------------------------------------------------------
echo "=== [3] TRIGGER: push a tag at the malicious commit (non-default ref) ==="
# Tag push fires `on: push: tags` -> the run executes from the tag, not main.
git push -q origin "$EVIL_SHA:refs/tags/$TAG"
echo "  $TAG -> $EVIL_SHA  (workflow runs from a non-default ref)"

# -----------------------------------------------------------------------------
echo "=== [4] WAIT (let the run register in telemetry) ==="
echo "  sleeping ${WAIT_SECONDS}s ..."
sleep "$WAIT_SECONDS"

# -----------------------------------------------------------------------------
echo "=== [5] COVER TRACKS: delete the publish run + logs ==="
RID=$(gh run list -R "$ORG/$REPO" --json databaseId,headBranch \
        -q "[.[]|select(.headBranch==\"$TAG\")][0].databaseId")
[ -z "$RID" ] && RID=$(gh run list -R "$ORG/$REPO" --json databaseId -q '.[0].databaseId')
if [ -n "$RID" ]; then
  gh run delete "$RID" -R "$ORG/$REPO" && echo "  deleted run $RID (logs gone)"
else
  echo "  no run found to delete"
fi

echo "=== DONE ==="
echo "  publish workflow rewritten + run triggered from tag $TAG (head_branch != $DEFBR)"
echo "  repo: https://github.com/$ORG/$REPO"
