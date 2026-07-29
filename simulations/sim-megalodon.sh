#!/usr/bin/env bash
# campaign-sim mass CI-workflow backdoor simulation (d-PPE at scale)
#
# Models a mass supply-chain campaign that, with stolen creds, pushes a backdoored
# GitHub Actions workflow straight to the default branch of MANY repos in one short
# window -- forging the commit author so it looks like routine CI automation.
#
# Simulated TTPs:
#   * Direct push to the default branch, no PR (d-PPE).
#   * Adds a file under .github/workflows/ (the backdoor).
#   * Forged commit author: bot name + noreply-style email NOT linked to any account
#     => GitHub resolves no user (author.username absent) => author != pusher.
#   * Same forged author email across MANY repos in a short window (the mass signal).
#   * Workflow grants id-token: write (payload benign here).
set -eu

# ---- parameters -------------------------------------------------------------
ORG="${ORG:-supplychain-labs}"                       # one of the two victim owners (an org)
REPO_PREFIX=sim-campaign        # victim repos are $REPO_PREFIX-1 .. -$COUNT
COUNT="${COUNT:-5}"             # how many repos to hit (>=5 trips the mass detector)
FORGED_NAME="${FORGED_NAME:-campaign-bot}"                 # forged commit author name
FORGED_EMAIL="${FORGED_EMAIL:-campaign-bot@campaign.invalid}"  # unresolvable => author=null
WF_PATH=".github/workflows/pipeline-sim.yml"   # the injected workflow file
COMMIT_MSG="chore: adjust workflow settings (sim)"  # blends in as routine CI maintenance

git config --global user.name  "sim-operator"
git config --global user.email "sim-operator@example.com"
git config --global init.defaultBranch main
git config --global credential.helper '!gh auth git-credential'

PUSHER=$(gh api user -q '.login')
# Spread the victim repos across TWO owners (the org + the operator's own account) so the
# same forged author shows up under unrelated owners -- the cross-owner mass signal. We
# only have one credential, so the pusher is the same ($PUSHER) for every repo.
OWNERS=("$ORG" "$PUSHER")
owner_for() { echo "${OWNERS[$(( ($1 - 1) % ${#OWNERS[@]} ))]}"; }
echo "=== campaign: ${OWNERS[*]} / $REPO_PREFIX-1..$COUNT  author=$FORGED_NAME <$FORGED_EMAIL>  pusher=$PUSHER ==="

# Benign backdoor workflow: keeps the campaign's structural IoCs (workflow file under
# .github/workflows, id-token: write) but the step is harmless.
read -r -d '' WORKFLOW <<'YML' || true
name: pipeline-sim
on: [push, workflow_dispatch]
permissions:
  id-token: write
  actions: read
jobs:
  sim:
    runs-on: ubuntu-latest
    steps:
      - run: echo "campaign-sim: benign payload marker"
YML

# -----------------------------------------------------------------------------
echo "=== [0] clean any prior run ==="
for i in $(seq 1 "$COUNT"); do
  gh repo delete "$(owner_for "$i")/$REPO_PREFIX-$i" --yes 2>/dev/null || true
done
sleep 2

# -----------------------------------------------------------------------------
echo "=== [1] seed $COUNT clean victim repos (legitimate baseline) ==="
for i in $(seq 1 "$COUNT"); do
  gh repo create "$(owner_for "$i")/$REPO_PREFIX-$i" --public --add-readme >/dev/null
  echo "  created $(owner_for "$i")/$REPO_PREFIX-$i"
done
sleep 3

# -----------------------------------------------------------------------------
echo "=== [2] ATTACK: inject the workflow into every repo's default branch (burst) ==="
# One forged identity, many repos, back-to-back => the short-window mass signal.
for i in $(seq 1 "$COUNT"); do
  REPO="$(owner_for "$i")/$REPO_PREFIX-$i"
  TMP=$(mktemp -d); git clone -q "https://github.com/$REPO" "$TMP/r"; cd "$TMP/r"
  DEFBR=$(git rev-parse --abbrev-ref HEAD)
  mkdir -p "$(dirname "$WF_PATH")"
  printf '%s\n' "$WORKFLOW" > "$WF_PATH"
  git add "$WF_PATH"
  # Forge the author identity; committer too. Unsigned. Direct to default branch, no PR.
  GIT_AUTHOR_NAME="$FORGED_NAME"  GIT_AUTHOR_EMAIL="$FORGED_EMAIL" \
  GIT_COMMITTER_NAME="$FORGED_NAME" GIT_COMMITTER_EMAIL="$FORGED_EMAIL" \
    git commit -q -m "$COMMIT_MSG" --no-gpg-sign
  git push -q origin "HEAD:refs/heads/$DEFBR"
  echo "  backdoored $REPO ($DEFBR)"
  cd /; rm -rf "$TMP"
done

echo "=== DONE ==="
echo "  injected '$WF_PATH' into $COUNT repos across owners: ${OWNERS[*]}  as $FORGED_NAME <$FORGED_EMAIL> (pusher=$PUSHER)"
