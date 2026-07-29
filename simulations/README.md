# Simulations

Benign, self-contained scripts that reproduce the **structural indicators** of real
supply-chain attacks (forged tags, spoofed authors, OIDC/trusted-publishing abuse,
mass tag force-pushes etc.) so the detection rules in
[`../analyzers/detection_queries/rules`](../analyzers/detection_queries/rules) can be
exercised end-to-end. No malware, no network exfiltration — payloads are inert echoes.

## Prerequisites

- `bash`, `git`, `jq`
- [`gh`](https://cli.github.com/) authenticated (`gh auth login`) as a user with
  **repo create/delete** rights in the target owner (scopes: `repo`, `delete_repo`,
  `workflow`).
- The scripts **create and delete public repos** under the target owner. Run them
  only against a throwaway sandbox org/account you control.

## Running

Each script defaults to the sandbox org `supplychain-labs` but the owner is overridable via the
`ORG` environment variable — no file edits needed:

```bash
# run against your own org / account
ORG=my-sandbox-org ./simulations/sim-trivy.sh

# or use the default (supplychain-labs)
./simulations/sim-trivy.sh
```

The pusher/attacker identity is resolved at runtime from the authenticated `gh` user,
so nothing else is hardcoded to a specific environment.

## Cleanup

The scripts delete and recreate their target repos on each run (`gh repo delete` at
step 0). To remove them afterwards:

```bash
gh repo delete "$ORG/sim-trivy" --yes
```
