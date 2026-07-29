from analyzers.detection_queries.runner import (
    ANALYZERS,
    SqlRule,
    SqlRuleAnalyzer,
    load_rules,
    parse_rule,
)

FORENSICS_DATA_SOURCE = "git_forensics"
AUTHOR_ENRICHMENT_DATA_SOURCE = "author_enrichment"

FORENSICS_ANALYZERS = [a for a in ANALYZERS if a.rule.data_source == FORENSICS_DATA_SOURCE]
AUTHOR_ENRICHMENT_ANALYZERS = [
    a for a in ANALYZERS if a.rule.data_source == AUTHOR_ENRICHMENT_DATA_SOURCE
]
SNAPSHOT_ANALYZERS = [
    a for a in ANALYZERS
    if a.rule.data_source not in (FORENSICS_DATA_SOURCE, AUTHOR_ENRICHMENT_DATA_SOURCE)
]

__all__ = [
    "ANALYZERS",
    "FORENSICS_ANALYZERS",
    "AUTHOR_ENRICHMENT_ANALYZERS",
    "SNAPSHOT_ANALYZERS",
    "SqlRule",
    "SqlRuleAnalyzer",
    "load_rules",
    "parse_rule",
]
