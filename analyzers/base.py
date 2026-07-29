from abc import ABC, abstractmethod
from db.queries import insert_finding


class BaseAnalyzer(ABC):
    rule_id: str
    severity: str
    is_candidate: bool = False

    def emit(
        self,
        repo_name: str,
        description: str,
        actor_login: str | None = None,
        event_id: str | None = None,
        evidence: dict | None = None,
    ) -> None:
        insert_finding(
            rule_id=self.rule_id,
            severity=self.severity,
            repo_name=repo_name,
            description=description,
            actor_login=actor_login,
            event_id=event_id,
            evidence=evidence,
            is_candidate=self.is_candidate,
        )

    @abstractmethod
    def run(self, repo_name: str | None = None) -> int:
        ...
