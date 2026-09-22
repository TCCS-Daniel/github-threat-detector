from collectors.github_client import paginate
import os


def _split_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def _prefix_match(name: str, prefix: str | None) -> bool:
    if not prefix:
        return True
    return name.startswith(prefix.rstrip("*"))


def list_org_repos(org: str, name_prefix: str | None = None) -> list[str]:
    repos: list[str] = []
    for page in paginate(f"/orgs/{org}/repos", {"type": "all", "sort": "updated"}):
        for repo in page:
            name = repo.get("name", "")
            if not name or not _prefix_match(name, name_prefix):
                continue
            # Use GitHub's canonical full_name, not the configured org string:
            # a case difference (e.g. "my-org" vs "My-Org") would otherwise
            # split every repo's data under two spellings.
            repos.append(repo.get("full_name") or f"{org}/{name}")
    return repos


def resolve_target_repos(
    explicit_repos: list[str] | None = None,
    orgs: list[str] | None = None,
    repo_prefix: str | None = None,
) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for full_name in explicit_repos or []:
        if full_name and full_name not in seen:
            seen.add(full_name)
            ordered.append(full_name)
    for org in orgs or []:
        for full_name in list_org_repos(org, repo_prefix):
            if full_name not in seen:
                seen.add(full_name)
                ordered.append(full_name)
    return ordered


def resolve_target_repos_from_env() -> list[str]:
    explicit = _split_csv(os.environ.get("TARGET_REPOS") or os.environ.get("GITHUB_REPOS"))
    orgs = _split_csv(os.environ.get("TARGET_ORGS") or os.environ.get("GITHUB_ORGS"))
    prefix = (os.environ.get("TARGET_REPO_PREFIX") or "").strip() or None
    return resolve_target_repos(explicit, orgs, prefix)
