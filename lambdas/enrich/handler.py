import logging
from typing import Any

from bootstrap import load_github_token

load_github_token()

from collectors.author_search import collect_author_search
from analyzers.detection_queries import AUTHOR_ENRICHMENT_ANALYZERS as DETECTION_ANALYZERS

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    logger.info("author_enrichment start")

    results: dict[str, Any] = {}

    try:
        hits = collect_author_search()
        results["search_hits"] = hits
        logger.info("author_search ok hits=%s", hits)
    except Exception as exc:
        logger.exception("author_search failed")
        results["search_hits"] = {"error": str(exc)}

    findings = 0
    try:
        for analyzer in DETECTION_ANALYZERS:
            findings += analyzer.run()
        results["findings"] = findings
        logger.info("cross_owner_analyzer ok findings=%s", findings)
    except Exception as exc:
        logger.exception("cross_owner_analyzer failed")
        results["findings"] = {"error": str(exc)}

    return results
