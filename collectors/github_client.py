import re
import httpx
from typing import Any, Generator

from config import GITHUB_API_BASE, GITHUB_TOKEN, MAX_PAGES, REQUEST_TIMEOUT


_NEXT_LINK_RE = re.compile(r'<([^>]+)>;\s*rel="next"')


def _headers() -> dict[str, str]:
    h = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if GITHUB_TOKEN:
        h["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return h


def paginate(path: str, params: dict[str, Any] | None = None) -> Generator[list[dict], None, None]:
    url = f"{GITHUB_API_BASE}{path}"
    p = {"per_page": 100, **(params or {})}
    with httpx.Client(headers=_headers(), timeout=REQUEST_TIMEOUT) as client:
        for page in range(1, MAX_PAGES + 1):
            p["page"] = page
            resp = client.get(url, params=p)
            if resp.status_code in (404, 403, 429):
                break
            resp.raise_for_status()
            data = resp.json()
            if not data:
                break
            yield data
            link = resp.headers.get("link", "")
            if 'rel="next"' not in link:
                break


def paginate_link(path: str, params: dict[str, Any] | None = None) -> Generator[list[dict], None, None]:
    url: str | None = f"{GITHUB_API_BASE}{path}"
    p: dict[str, Any] | None = {"per_page": 100, **(params or {})}
    with httpx.Client(headers=_headers(), timeout=REQUEST_TIMEOUT) as client:
        for _ in range(MAX_PAGES):
            if not url:
                break
            resp = client.get(url, params=p)
            if resp.status_code in (404, 403, 429):
                break
            resp.raise_for_status()
            data = resp.json()
            if not data:
                break
            yield data
            match = _NEXT_LINK_RE.search(resp.headers.get("link", ""))
            url = match.group(1) if match else None
            p = None


def get_result(path: str, params: dict[str, Any] | None = None) -> tuple[Any | None, int]:
    url = f"{GITHUB_API_BASE}{path}"
    with httpx.Client(headers=_headers(), timeout=REQUEST_TIMEOUT) as client:
        resp = client.get(url, params=params or {})
        if resp.status_code in (404, 403, 422, 429):
            return None, resp.status_code
        resp.raise_for_status()
        return resp.json(), resp.status_code


def get(path: str, params: dict[str, Any] | None = None) -> Any:
    data, _status = get_result(path, params)
    return data
