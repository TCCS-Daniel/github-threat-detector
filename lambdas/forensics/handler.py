import logging
from typing import Any

from bootstrap import load_github_token

load_github_token()

from collectors.git_repo import clone_and_inspect
from collectors.repos import resolve_target_repos_from_env
from analyzers.detection_queries import FORENSICS_ANALYZERS as DETECTION_ANALYZERS

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    repos = resolve_target_repos_from_env()
    logger.info("forensics_collector start repos=%s", repos)

    results: dict[str, Any] = {"repos": {}}

    for repo in repos:
        try:
            n = clone_and_inspect(repo)
            results["repos"][repo] = n
            logger.info("forensics_repo repo=%s checks=%d", repo, n)
        except Exception as exc:
            logger.exception("forensics_repo failed repo=%s", repo)
            results["repos"][repo] = {"error": str(exc)}

    results["findings"] = {}
    for analyzer in DETECTION_ANALYZERS:
        try:
            n = analyzer.run()
            results["findings"][analyzer.rule_id] = n
            logger.info("analyzer ok rule=%s findings=%s", analyzer.rule_id, n)
        except Exception as exc:
            logger.exception("analyzer failed rule=%s", analyzer.rule_id)
            results["findings"][analyzer.rule_id] = {"error": str(exc)}

    return results
