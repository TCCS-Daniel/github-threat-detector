import os
from dotenv import load_dotenv

load_dotenv()

GITHUB_TOKEN: str = os.environ.get("GITHUB_TOKEN", "")
DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres@localhost:5432/threat_detector",
)

DEFAULT_REPOS: list[str] = [
    repo.strip()
    for repo in os.environ.get("GITHUB_REPOS", "").split(",")
    if repo.strip()
]

DEFAULT_ORGS: list[str] = [
    org.strip()
    for org in os.environ.get("GITHUB_ORGS", os.environ.get("TARGET_ORGS", "")).split(",")
    if org.strip()
]

TARGET_REPO_PREFIX: str = os.environ.get("TARGET_REPO_PREFIX", "").strip()

# Orgs still collected and analyzed, but hidden from the investigation UI's
# default views (org/repo dropdowns and the unfiltered findings list).
# Explicitly filtering on a hidden org (?org=...) still shows its data.
HIDDEN_ORGS: list[str] = [
    org.strip().lower()
    for org in os.environ.get("HIDDEN_ORGS", "").split(",")
    if org.strip()
]

GITHUB_API_BASE = "https://api.github.com"
REQUEST_TIMEOUT = 30
MAX_PAGES = 10
GIT_CLONE_TIMEOUT = 120
