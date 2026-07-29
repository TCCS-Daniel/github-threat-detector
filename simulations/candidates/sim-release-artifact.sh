#!/usr/bin/env bash
# release-artifact / post-publish asset swap simulation (minimal)
#
# Models a post-publish release artifact replacement: a release ships signed
# binaries, then ONE binary is deleted + re-uploaded via the Releases API while
# its .sig / SHA256SUMS stay put. GitHub asset digests change; signature
# verification against the left-behind .sig would fail.
#
# Simulated TTPs:
#   * Release published with signed, verifiable assets.
#   * Post-publish DELETE /releases/assets/{id} + uploads.github.com reupload.
#   * Original .sig / SHA256SUMS left in place.
#   * Webhook release/edited carries the new asset digest.
#
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"              # victim owner (org); override via env
REPO=sim-release-artifact        # victim repo (ships signed release assets)
TAG="${TAG:-v1.0.0}"             # release tag that gets the swapped asset
GIT_NAME="${GIT_NAME:-mo5084-beep}"
GIT_EMAIL="${GIT_EMAIL:-mambo5084@gmail.com}"
SKIP_PAUSE="${SKIP_PAUSE:-0}"

git config --global init.defaultBranch main
git config --global credential.helper '!gh auth git-credential'

echo "=== target: $ORG/$REPO  tag=$TAG ==="

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
gh repo delete "$ORG/$REPO" --yes 2>/dev/null || true
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed repo + signed commit/tag (verified on GitHub) ==="
SIGN_DIR="$WORKDIR/git-signing"
mkdir -p "$SIGN_DIR"
ssh-keygen -t ed25519 -f "$SIGN_DIR/signing" -N "" -C "$GIT_EMAIL" >/dev/null
for kid in $(gh api user/ssh_signing_keys --jq '.[] | select(.title|test("^sim-release-artifact")) | .id'); do
  gh api -X DELETE "user/ssh_signing_keys/$kid" >/dev/null || true
done
gh api user/ssh_signing_keys \
  -f title="sim-release-artifact" \
  -f key="$(cat "$SIGN_DIR/signing.pub")" >/dev/null
sleep 2

gh repo create "$ORG/$REPO" --public --add-readme >/dev/null
sleep 3
DEFBR=$(gh api "repos/$ORG/$REPO" -q '.default_branch')
cd /tmp; rm -rf "$REPO"; git clone -q "https://github.com/$ORG/$REPO"; cd "$REPO"
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
git config gpg.format ssh
git config user.signingkey "$SIGN_DIR/signing"
echo "build artifact a" > checksums.txt
git add checksums.txt
git commit -q -S -m "chore: seed for $TAG"
git tag -s "$TAG" -m "$TAG"
git push -q origin "HEAD:$DEFBR"
git push -q origin "$TAG"
COMMIT_SHA=$(git rev-parse HEAD)
echo "  seeded $ORG/$REPO @ $TAG ($DEFBR)  commit+tag SSH-signed as $GIT_NAME"
echo "  commit=$COMMIT_SHA"
COMMIT_VER=$(gh api "repos/$ORG/$REPO/commits/$COMMIT_SHA" \
  -q '"verified=\(.commit.verification.verified) reason=\(.commit.verification.reason)"')
TAG_OBJ=$(gh api "repos/$ORG/$REPO/git/ref/tags/$TAG" -q .object.sha)
TAG_VER=$(gh api "repos/$ORG/$REPO/git/tags/$TAG_OBJ" \
  -q '"verified=\(.verification.verified) reason=\(.verification.reason)"')
echo "  BEFORE asset swap — commit: $COMMIT_VER"
echo "  BEFORE asset swap — tag:    $TAG_VER"

# -----------------------------------------------------------------------------
echo "=== [2] generate signing key + signed artifacts ==="
KEYDIR="$WORKDIR/keys"
mkdir -p "$KEYDIR" "$WORKDIR/dist"
openssl genrsa -out "$KEYDIR/release.key" 2048 2>/dev/null
openssl rsa -in "$KEYDIR/release.key" -pubout -out "$KEYDIR/release.pub" 2>/dev/null

printf 'legit-binary-linux-v1\n' > "$WORKDIR/dist/tool-linux-amd64"
printf 'legit-binary-darwin-v1\n' > "$WORKDIR/dist/tool-darwin-amd64"
openssl dgst -sha256 -sign "$KEYDIR/release.key" -out "$WORKDIR/dist/tool-linux-amd64.sig" \
  "$WORKDIR/dist/tool-linux-amd64"
openssl dgst -sha256 -sign "$KEYDIR/release.key" -out "$WORKDIR/dist/tool-darwin-amd64.sig" \
  "$WORKDIR/dist/tool-darwin-amd64"
(
  cd "$WORKDIR/dist"
  shasum -a 256 tool-linux-amd64 tool-darwin-amd64 \
    tool-linux-amd64.sig tool-darwin-amd64.sig > SHA256SUMS
)
cp "$KEYDIR/release.pub" "$WORKDIR/dist/release.pub"
echo "  signed tool-linux-amd64 + tool-darwin-amd64"

# -----------------------------------------------------------------------------
echo "=== [3] publish release with signed assets ==="
gh release create "$TAG" \
  --repo "$ORG/$REPO" \
  --title "$TAG" \
  --notes "sim signed release — verify with release.pub + *.sig / SHA256SUMS" \
  "$WORKDIR/dist/tool-linux-amd64" \
  "$WORKDIR/dist/tool-linux-amd64.sig" \
  "$WORKDIR/dist/tool-darwin-amd64" \
  "$WORKDIR/dist/tool-darwin-amd64.sig" \
  "$WORKDIR/dist/SHA256SUMS" \
  "$WORKDIR/dist/release.pub"
SWAP_ASSET="${SWAP_ASSET:-tool-darwin-amd64}"
RELEASE_ID=$(gh api "repos/$ORG/$REPO/releases/tags/$TAG" -q .id)
DIGEST_BEFORE=$(gh api "repos/$ORG/$REPO/releases/tags/$TAG" \
  -q ".assets[] | select(.name==\"$SWAP_ASSET\") | .digest")
ASSET_ID_BEFORE=$(gh api "repos/$ORG/$REPO/releases/tags/$TAG" \
  -q ".assets[] | select(.name==\"$SWAP_ASSET\") | .id")
echo "  published $TAG  $SWAP_ASSET id=$ASSET_ID_BEFORE digest=$DIGEST_BEFORE"
echo "  https://github.com/$ORG/$REPO/releases/tag/$TAG"
echo
PAUSE_FLAG="${PAUSE_FLAG:-/tmp/sim-release-artifact.continue}"
if [[ "$SKIP_PAUSE" != "1" ]]; then
  echo "=== PAUSE: screenshot BEFORE (signed assets, digests intact) ==="
  rm -f "$PAUSE_FLAG"
  if [[ -t 0 ]]; then
    read -r -p "Press Enter to continue with the attack... "
  else
    echo "  touch $PAUSE_FLAG  (or reply in chat) when ready"
    while [[ ! -f "$PAUSE_FLAG" ]]; do sleep 2; done
    rm -f "$PAUSE_FLAG"
  fi
fi

# -----------------------------------------------------------------------------
echo "=== [4] ATTACK: DELETE + upload $SWAP_ASSET via Releases API (leave .sig) ==="
printf 'trojanized-binary-darwin-v1-replaced\n' > "$WORKDIR/dist/$SWAP_ASSET"
echo "  DELETE repos/$ORG/$REPO/releases/assets/$ASSET_ID_BEFORE"
gh api -X DELETE "repos/$ORG/$REPO/releases/assets/$ASSET_ID_BEFORE"
echo "  POST uploads.github.com/repos/$ORG/$REPO/releases/$RELEASE_ID/assets?name=$SWAP_ASSET"
gh api --method POST \
  -H "Content-Type: application/octet-stream" \
  --input "$WORKDIR/dist/$SWAP_ASSET" \
  "https://uploads.github.com/repos/$ORG/$REPO/releases/$RELEASE_ID/assets?name=$SWAP_ASSET" \
  -q '"uploaded id=\(.id) digest=\(.digest // "n/a") name=\(.name)"'
DIGEST_AFTER=$(gh api "repos/$ORG/$REPO/releases/tags/$TAG" \
  -q ".assets[] | select(.name==\"$SWAP_ASSET\") | .digest")
ASSET_ID_AFTER=$(gh api "repos/$ORG/$REPO/releases/tags/$TAG" \
  -q ".assets[] | select(.name==\"$SWAP_ASSET\") | .id")
echo "  replaced $SWAP_ASSET  id: $ASSET_ID_BEFORE -> $ASSET_ID_AFTER"
echo "  digest: $DIGEST_BEFORE -> $DIGEST_AFTER"
echo "  https://github.com/$ORG/$REPO/releases/tag/$TAG"
COMMIT_VER_AFTER=$(gh api "repos/$ORG/$REPO/commits/$COMMIT_SHA" \
  -q '"verified=\(.commit.verification.verified) reason=\(.commit.verification.reason) sha=\(.sha)"')
TAG_OBJ_AFTER=$(gh api "repos/$ORG/$REPO/git/ref/tags/$TAG" -q .object.sha)
TAG_VER_AFTER=$(gh api "repos/$ORG/$REPO/git/tags/$TAG_OBJ_AFTER" \
  -q '"verified=\(.verification.verified) reason=\(.verification.reason) sha=\(.sha) object=\(.object.sha)"')
echo "  AFTER asset swap  — commit: $COMMIT_VER_AFTER"
echo "  AFTER asset swap  — tag:    $TAG_VER_AFTER"
echo "  tag object sha before/after: $TAG_OBJ / $TAG_OBJ_AFTER"
echo "  commit sha unchanged:        $COMMIT_SHA"
echo
if [[ "$SKIP_PAUSE" != "1" ]]; then
  echo "=== PAUSE: screenshot AFTER (binary swapped, .sig / SHA256SUMS left) ==="
  rm -f "$PAUSE_FLAG"
  if [[ -t 0 ]]; then
    read -r -p "Press Enter to finish... "
  else
    echo "  touch $PAUSE_FLAG  (or reply in chat) when ready"
    while [[ ! -f "$PAUSE_FLAG" ]]; do sleep 2; done
    rm -f "$PAUSE_FLAG"
  fi
fi

echo "=== DONE ==="
echo "  asset:  $SWAP_ASSET"
echo "  digest: $DIGEST_BEFORE -> $DIGEST_AFTER"
echo "  repo: https://github.com/$ORG/$REPO/releases/tag/$TAG"
echo "  commit/tag badges: see BEFORE vs AFTER verification lines above"
