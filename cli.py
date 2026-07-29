#!/usr/bin/env python3
import sys
import json
from datetime import datetime, timedelta, timezone

import click
from rich.console import Console
from rich.table import Table
from rich import box

from config import DEFAULT_ORGS, DEFAULT_REPOS, TARGET_REPO_PREFIX
from db.client import apply_schema, reset_db
from db.queries import fetch_findings

console = Console()

SEVERITY_COLOR = {
    "critical": "bold red",
    "high": "red",
    "medium": "yellow",
    "low": "green",
}

ALL_ANALYZERS: list = []


def _load_analyzers() -> list:
    from analyzers.detection_queries import ANALYZERS as a1
    return list(a1)


def _parse_repos(repos_opt: str | None) -> list[str]:
    if repos_opt:
        return [r.strip() for r in repos_opt.split(",") if r.strip()]
    if DEFAULT_REPOS:
        return DEFAULT_REPOS
    return []


def _parse_since(since_str: str | None) -> datetime | None:
    if not since_str:
        return None
    since_str = since_str.strip()
    if since_str.endswith("d"):
        days = int(since_str[:-1])
        return datetime.now(timezone.utc) - timedelta(days=days)
    if since_str.endswith("h"):
        hours = int(since_str[:-1])
        return datetime.now(timezone.utc) - timedelta(hours=hours)
    return datetime.fromisoformat(since_str)


@click.group()
def cli() -> None:
    pass


@cli.command()
@click.option("--repos", default=None, help="Comma-separated list of owner/repo to collect from")
@click.option("--orgs", default=None, help="Comma-separated list of orgs to collect from")
@click.option("--repo-prefix", default=None, help="Discover org repos whose name starts with this prefix (e.g. sim or sim*)")
@click.option("--actions", is_flag=True, default=False, help="Also collect Actions workflow runs")
@click.option("--contributors", is_flag=True, default=False, help="Seed contributor list from Contributors API")
@click.option("--workflow-files", "workflow_files", is_flag=True, default=False, help="Fetch workflow YAML files for AI prompt injection analysis")
@click.option("--commits", is_flag=True, default=False, help="Fetch commit metadata for default-branch pushes (enables tamper detection)")
@click.option("--scan-parents", "scan_parents", is_flag=True, default=False, help="When collecting commits, also fetch each head's parent commit(s) so parent lineage (parent committer dates) is available for commit-tamper analyzers")
@click.option("--git-inspect", "git_inspect", is_flag=True, default=False, help="Clone repos and run git-level integrity checks (replace refs, gitattributes, symlinks, unicode, tag provenance)")
@click.option("--tags", is_flag=True, default=False, help="Collect git tag snapshots and detect tag SHA drift (tag poisoning)")
@click.option("--activities", is_flag=True, default=False, help="Collect repository activities (force-pushes, branch/tag deletions) via Activity API")
@click.option("--snapshots", is_flag=True, default=False, help="Snapshot repo config (hooks, branches, secrets, collaborators, releases, workflows) and emit drift events into events_snapshot")
@click.option("--author-search", "author_search", is_flag=True, default=False, help="Search GitHub for forged commit author/committer emails across owners (cross-owner forged-author enrichment)")
def collect(repos: str | None, orgs: str | None, repo_prefix: str | None, actions: bool, contributors: bool, workflow_files: bool, commits: bool, scan_parents: bool, git_inspect: bool, tags: bool, activities: bool, snapshots: bool, author_search: bool) -> None:
    """Collect GitHub events and store them in Postgres."""
    from collectors.events import collect_for_repo, collect_for_org
    from collectors.actions import collect_workflow_runs
    from collectors.contributors import collect_contributors
    from collectors.workflow_files import collect_workflow_files
    from collectors.commits import collect_push_commits
    from collectors.author_search import collect_author_search
    from collectors.git_repo import clone_and_inspect
    from collectors.tags import collect_repo_tags
    from collectors.activities import collect_repo_activities
    from collectors.snapshots import collect_repo_snapshots, collect_org_members
    from collectors.repos import resolve_target_repos

    apply_schema()

    org_list = [o.strip() for o in orgs.split(",") if o.strip()] if orgs else DEFAULT_ORGS
    prefix = (repo_prefix or TARGET_REPO_PREFIX or "").strip() or None
    repo_list = resolve_target_repos(_parse_repos(repos), org_list, prefix)

    if not repo_list and not org_list:
        console.print("[yellow]No repos or orgs specified. Use --repos, --orgs, or set GITHUB_REPOS/GITHUB_ORGS env vars.[/yellow]")
        sys.exit(1)

    if repo_list:
        console.print(f"[cyan]Target repos ({len(repo_list)}):[/cyan] {', '.join(repo_list)}")

    for full_name in repo_list:
        console.print(f"[cyan]Collecting events for {full_name}...[/cyan]")
        n = collect_for_repo(full_name)
        console.print(f"  [green]→ {n} new events[/green]")
        if actions:
            console.print(f"[cyan]Collecting workflow runs for {full_name}...[/cyan]")
            n = collect_workflow_runs(full_name)
            console.print(f"  [green]→ {n} workflow runs[/green]")
        if contributors:
            console.print(f"[cyan]Seeding contributors for {full_name}...[/cyan]")
            n = collect_contributors(full_name)
            console.print(f"  [green]→ {n} contributors[/green]")
        if workflow_files:
            console.print(f"[cyan]Fetching workflow files for {full_name}...[/cyan]")
            n = collect_workflow_files(full_name)
            console.print(f"  [green]→ {n} workflow files[/green]")
        if commits:
            console.print(f"[cyan]Fetching commit metadata for {full_name}...[/cyan]")
            n = collect_push_commits(full_name, scan_parents=scan_parents)
            console.print(f"  [green]→ {n} commits[/green]")
        if git_inspect:
            console.print(f"[cyan]Running git-level inspection for {full_name}...[/cyan]")
            n = clone_and_inspect(full_name)
            console.print(f"  [green]→ {n} checks completed[/green]")
        if tags:
            console.print(f"[cyan]Collecting tag snapshots for {full_name}...[/cyan]")
            n = collect_repo_tags(full_name)
            console.print(f"  [green]→ {n} tags[/green]")
        if activities:
            console.print(f"[cyan]Collecting activities for {full_name}...[/cyan]")
            n = collect_repo_activities(full_name)
            console.print(f"  [green]→ {n} activities[/green]")
        if snapshots:
            console.print(f"[cyan]Snapshotting config for {full_name}...[/cyan]")
            n = collect_repo_snapshots(full_name)
            console.print(f"  [green]→ {n} drift events[/green]")

    for org in org_list:
        console.print(f"[cyan]Collecting org events for {org}...[/cyan]")
        n = collect_for_org(org)
        console.print(f"  [green]→ {n} new events[/green]")
        if snapshots:
            console.print(f"[cyan]Snapshotting members for {org}...[/cyan]")
            n = collect_org_members(org)
            console.print(f"  [green]→ {n} drift events[/green]")

    if author_search:
        console.print("[cyan]Searching GitHub for forged author emails across owners...[/cyan]")
        n = collect_author_search()
        console.print(f"  [green]→ {n} search hits[/green]")

    console.print("[bold green]Collection complete.[/bold green]")


@cli.command()
@click.option("--repos", default=None, help="Comma-separated list of owner/repo to analyze (default: all)")
@click.option("--rules", default=None, help="Comma-separated rule IDs to run (default: all)")
def analyze(repos: str | None, rules: str | None) -> None:
    """Run heuristic analyzers and write findings to Postgres."""
    apply_schema()
    analyzers = _load_analyzers()
    rule_filter = set(r.strip() for r in rules.split(",")) if rules else None
    if rule_filter:
        analyzers = [a for a in analyzers if a.rule_id in rule_filter]

    repo_list = _parse_repos(repos) or [None]

    total = 0
    for analyzer in analyzers:
        for repo in repo_list:
            label = repo or "all repos"
            console.print(f"[cyan]Running [bold]{analyzer.rule_id}[/bold] on {label}...[/cyan]")
            try:
                n = analyzer.run(repo_name=repo)
                if n:
                    console.print(f"  [red]→ {n} finding(s)[/red]")
                else:
                    console.print(f"  [green]→ clean[/green]")
                total += n
            except Exception as exc:
                console.print(f"  [yellow]→ error: {exc}[/yellow]")

    console.print(f"\n[bold]Analysis complete. Total findings: {total}[/bold]")


@cli.command()
@click.option("--severity", default=None, help="Filter by severity: critical,high,medium,low")
@click.option("--repos", default=None, help="Filter by repo (owner/repo)")
@click.option("--since", default=None, help="Show findings since: 7d, 24h, or ISO timestamp")
@click.option("--format", "fmt", default="table", type=click.Choice(["table", "json"]), help="Output format")
def report(severity: str | None, repos: str | None, since: str | None, fmt: str) -> None:
    """Display findings report."""
    severity_list = [s.strip() for s in severity.split(",")] if severity else None
    repo_filter = repos.strip() if repos else None
    since_dt = _parse_since(since)

    findings = fetch_findings(
        severity=severity_list,
        repo_name=repo_filter,
        since=since_dt,
    )

    if fmt == "json":
        click.echo(json.dumps(findings, indent=2, default=str))
        return

    if not findings:
        console.print("[green]No findings.[/green]")
        return

    table = Table(box=box.ROUNDED, show_lines=True)
    table.add_column("ID", style="dim", width=6)
    table.add_column("Severity", width=10)
    table.add_column("Rule", width=30)
    table.add_column("Repo", width=35)
    table.add_column("Actor", width=22)
    table.add_column("Description")
    table.add_column("When", width=20)

    for f in findings:
        sev = f["severity"]
        color = SEVERITY_COLOR.get(sev, "white")
        table.add_row(
            str(f["id"]),
            f"[{color}]{sev}[/{color}]",
            f["rule_id"],
            f["repo_name"],
            f["actor_login"] or "",
            f["description"],
            str(f["created_at"])[:19] if f["created_at"] else "",
        )

    console.print(table)
    console.print(f"\n[bold]Total: {len(findings)} finding(s)[/bold]")


@cli.command()
def init_db() -> None:
    """Apply database schema (creates workflow_runs and findings tables)."""
    apply_schema()
    console.print("[green]Schema applied.[/green]")


@cli.command("reset-db")
@click.confirmation_option(prompt="Drop all tables/views and re-apply schema.sql?")
def reset_db_cmd() -> None:
    """Wipe all data and recreate schema from db/schema.sql."""
    reset_db()
    apply_schema()
    console.print("[green]Database reset and schema applied.[/green]")


if __name__ == "__main__":
    cli()
