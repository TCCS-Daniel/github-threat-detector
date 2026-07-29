import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from pathlib import Path

from db.client import get_cursor
from analyzers.base import BaseAnalyzer


ZERO_SHA = "0000000000000000000000000000000000000000"

RULES_DIR = Path(__file__).parent / "rules"

_HEADER_KEYS = {
    "id",
    "severity",
    "description",
    "event_id",
    "actor",
    "evidence",
    "repo_column",
    "source",
    "tactic",
    "data_source",
    "candidate",
}
_HEADER_RE = re.compile(r"^--\s*([a-z_]+)\s*:\s*(.*)$")


@dataclass
class SqlRule:
    rule_id: str
    severity: str
    description: str
    sql: str
    event_id: str | None = None
    actor: str | None = None
    repo_column: str = "repo_name"
    evidence_columns: list[str] = field(default_factory=list)
    source: str | None = None
    tactic: str | None = None
    data_source: str | None = None
    is_candidate: bool = False


class _Blank(dict):
    def __missing__(self, key):
        return ""


def _render(template: str, row: dict) -> str:
    values = _Blank({k: ("" if v is None else v) for k, v in row.items()})
    return template.format_map(values)


def _jsonable(value):
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {k: _jsonable(v) for k, v in value.items()}
    if isinstance(value, (datetime, date, time, timedelta, Decimal)):
        return str(value)
    return str(value)


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in ("true", "1", "yes")


def parse_rule(path: Path) -> SqlRule:
    lines = path.read_text().splitlines()
    header: dict[str, str] = {}
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped:
            i += 1
            continue
        match = _HEADER_RE.match(stripped)
        if match and match.group(1) in _HEADER_KEYS:
            header[match.group(1)] = match.group(2).strip()
            i += 1
            continue
        break
    body = "\n".join(lines[i:]).strip()

    for required in ("id", "severity", "description"):
        if not header.get(required):
            raise ValueError(f"{path.name}: missing required header '{required}'")
    if not body:
        raise ValueError(f"{path.name}: missing SQL body")

    evidence = [c.strip() for c in header.get("evidence", "").split(",") if c.strip()]
    is_candidate = _truthy(header.get("candidate")) or path.parent.name == "candidates"
    return SqlRule(
        rule_id=header["id"],
        severity=header["severity"],
        description=header["description"],
        event_id=header.get("event_id") or None,
        actor=header.get("actor") or None,
        repo_column=header.get("repo_column") or "repo_name",
        evidence_columns=evidence,
        source=header.get("source") or None,
        tactic=header.get("tactic") or None,
        data_source=header.get("data_source") or None,
        is_candidate=is_candidate,
        sql=body,
    )


class SqlRuleAnalyzer(BaseAnalyzer):
    def __init__(self, rule: SqlRule):
        self.rule = rule
        self.rule_id = rule.rule_id
        self.severity = rule.severity
        self.is_candidate = rule.is_candidate

    def run(self, repo_name: str | None = None) -> int:
        sql = (
            "SELECT * FROM (\n" + self.rule.sql + "\n) _q\n"
            "WHERE (%(repo)s IS NULL OR _q." + self.rule.repo_column + " = %(repo)s)"
        )
        count = 0
        with get_cursor(dict_cursor=True) as cur:
            cur.execute(sql, {"repo": repo_name, "zero": ZERO_SHA})
            for row in cur.fetchall():
                self.emit(
                    repo_name=row.get(self.rule.repo_column) or row.get("repo_name") or repo_name,
                    description=_render(self.rule.description, row),
                    actor_login=(row.get(self.rule.actor) if self.rule.actor else None),
                    event_id=(_render(self.rule.event_id, row) if self.rule.event_id else None),
                    evidence=self._evidence(row),
                )
                count += 1
        return count

    def _evidence(self, row: dict) -> dict | None:
        if not self.rule.evidence_columns:
            return None
        return {c: _jsonable(row.get(c)) for c in self.rule.evidence_columns}


def load_rules() -> list[SqlRuleAnalyzer]:
    paths = sorted(RULES_DIR.glob("*.sql")) + sorted((RULES_DIR / "candidates").glob("*.sql"))
    return [SqlRuleAnalyzer(parse_rule(path)) for path in paths]


ANALYZERS = load_rules()
