import re
import shutil
import subprocess
import tempfile

from config import GITHUB_TOKEN, GIT_CLONE_TIMEOUT
from db.queries import upsert_git_repo_check


def _clone_url(full_name: str) -> str:
    if GITHUB_TOKEN:
        return f"https://x-access-token:{GITHUB_TOKEN}@github.com/{full_name}.git"
    return f"https://github.com/{full_name}.git"


def _run_git(args: list[str], cwd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=GIT_CLONE_TIMEOUT,
    )


def _check_replace_refs(repo_dir: str) -> dict:
    result = _run_git(["for-each-ref", "--format=%(objectname) %(refname)", "refs/replace/"], repo_dir)
    refs = []
    for line in result.stdout.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            replacement_sha, refname = parts
            original_sha = refname.rsplit("/", 1)[-1]
            refs.append({"original": original_sha, "replacement": replacement_sha})
    return {"refs": refs}


def _check_gitattributes(repo_dir: str) -> dict:
    result = _run_git(["show", "HEAD:.gitattributes"], repo_dir)
    if result.returncode != 0:
        return {"exists": False}
    content = result.stdout
    filter_re = re.compile(r"\b(filter|smudge|clean)\s*=\s*(\S+)")
    directives = []
    for i, line in enumerate(content.splitlines(), 1):
        for m in filter_re.finditer(line):
            directives.append({"line": i, "type": m.group(1), "command": m.group(2), "raw": line.strip()})
    return {"exists": True, "content": content, "directives": directives}


INVISIBLE_UNICODE_RANGES = [
    (0x200B, 0x200F),
    (0x2028, 0x202F),
    (0x2060, 0x2064),
    (0x2066, 0x2069),
    (0xFE00, 0xFE0F),
    (0xFEFF, 0xFEFF),
    (0xE0100, 0xE01EF),
]


def _is_invisible(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in INVISIBLE_UNICODE_RANGES)


def _check_symlinks(repo_dir: str) -> dict:
    result = _run_git(["ls-tree", "-r", "HEAD"], repo_dir)
    if result.returncode != 0:
        return {"symlinks": []}
    symlinks = []
    for line in result.stdout.strip().splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        mode, obj_type, blob_sha, path = parts
        if mode != "120000":
            continue
        target_result = _run_git(["cat-file", "-p", blob_sha], repo_dir)
        target = target_result.stdout.strip() if target_result.returncode == 0 else ""
        symlinks.append({"path": path, "target": target, "blob_sha": blob_sha})
    return {"symlinks": symlinks}


def _check_unicode_artifacts(repo_dir: str) -> dict:
    result = _run_git(["log", "-30", "--format=%H", "HEAD"], repo_dir)
    if result.returncode != 0:
        return {"commits": []}
    shas = [s.strip() for s in result.stdout.strip().splitlines() if s.strip()]
    flagged_commits = []
    for sha in shas:
        diff_result = _run_git(["diff-tree", "--no-commit-id", "-r", "-p", sha], repo_dir)
        if diff_result.returncode != 0:
            continue
        current_file = None
        file_chars: dict[str, list[str]] = {}
        for line in diff_result.stdout.splitlines():
            if line.startswith("+++ b/"):
                current_file = line[6:]
            elif line.startswith("+") and not line.startswith("+++") and current_file:
                for ch in line:
                    if _is_invisible(ch):
                        file_chars.setdefault(current_file, []).append(f"U+{ord(ch):04X}")
        if file_chars:
            files = [{"path": p, "chars": list(set(cs))[:5]} for p, cs in file_chars.items()]
            flagged_commits.append({"sha": sha, "files": files})
    return {"commits": flagged_commits}


def _check_tag_provenance(repo_dir: str) -> dict:
    """Find tags whose commit is not reachable from any local branch.

    Used by tag-from-nonexisting-branch (tj-actions style off-branch tags).

    1. Count local branches; if none, return empty (avoid false positives on
       empty/failed clones).
    2. List every tag and the commit it resolves to (peeled for annotated tags).
    3. For each tag, run ``git branch --contains <sha>``. If no branch contains
       the commit, record it as unreachable.

    Returns:
        ``{"tags": [{"tag_name", "commit_sha"}, ...], "branches_found": int}``
        where ``tags`` is only the unreachable set.
    """
    branches_result = _run_git(
        ["branch", "--list", "--format=%(refname)"],
        repo_dir,
    )
    branches_found = sum(
        1 for b in branches_result.stdout.strip().splitlines() if b.strip()
    )
    if branches_found == 0:
        return {"tags": [], "branches_found": 0}

    tags_result = _run_git(
        [
            "for-each-ref",
            "--format=%(refname:strip=2) %(*objectname) %(objectname)",
            "refs/tags/",
        ],
        repo_dir,
    )
    if tags_result.returncode != 0:
        return {"tags": [], "branches_found": branches_found}

    unreachable = []
    for line in tags_result.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        tag_name, commit_sha = parts[0], parts[1] or parts[-1]
        if not commit_sha or len(commit_sha) < 40:
            continue
        contains = _run_git(
            ["branch", "--contains", commit_sha, "--format=%(refname)"],
            repo_dir,
        )
        if contains.returncode != 0 or not contains.stdout.strip():
            unreachable.append({
                "tag_name": tag_name,
                "commit_sha": commit_sha,
            })
    return {
        "tags": unreachable,
        "branches_found": branches_found,
    }


def clone_and_inspect(full_name: str) -> int:
    tmp_dir = tempfile.mkdtemp(prefix="gtd_")
    repo_dir = f"{tmp_dir}/repo.git"
    try:
        proc = _run_git(["clone", "--bare", "--quiet", _clone_url(full_name), repo_dir], tmp_dir)
        if proc.returncode != 0:
            return 0

        checks = {
            "replace_refs": _check_replace_refs,
            "gitattributes": _check_gitattributes,
            "symlinks": _check_symlinks,
            "unicode_artifacts": _check_unicode_artifacts,
            "tag_provenance": _check_tag_provenance,
        }

        count = 0
        for check_type, fn in checks.items():
            try:
                result = fn(repo_dir)
                upsert_git_repo_check(full_name, check_type, result)
                count += 1
            except subprocess.TimeoutExpired:
                upsert_git_repo_check(full_name, check_type, {"error": "timeout"})
                count += 1

        return count
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
