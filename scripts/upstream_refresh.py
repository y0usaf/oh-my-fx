#!/usr/bin/env python3
"""Refresh attached OMIFX worktrees onto one pinned upstream revision."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


class RefreshError(RuntimeError):
    pass


def git(cwd: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    if check and result.returncode:
        raise RefreshError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def common_git_dir(root: Path) -> Path:
    value = git(root, "rev-parse", "--git-common-dir")
    return (root / value).resolve() if not Path(value).is_absolute() else Path(value).resolve()


def state_root(root: Path) -> Path:
    path = common_git_dir(root) / "omifx-upstream-refresh"
    path.mkdir(exist_ok=True)
    return path


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def acquire_lock(path: Path) -> None:
    try:
        path.mkdir()
    except FileExistsError as exc:
        raise RefreshError(f"another refresh is active: {path}") from exc
    (path / "pid").write_text(f"{os.getpid()}\n")


def worktrees(root: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in git(root, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            current = {"path": line.removeprefix("worktree ")}
        elif line.startswith("branch "):
            current["branch"] = line.removeprefix("branch refs/heads/")
        elif not line and current:
            if "branch" in current:
                result.append(current)
            current = {}
    return result


def in_progress(path: Path) -> bool:
    git_dir = Path(git(path, "rev-parse", "--git-dir")).resolve()
    markers = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE")
    return any((git_dir / marker).exists() for marker in markers) or any(
        (git_dir / marker).exists() for marker in ("rebase-merge", "rebase-apply")
    )


def entry(root: Path, source: str, base: str, item: dict[str, str], excluded: set[str]) -> dict[str, Any]:
    path = Path(item["path"])
    branch = item["branch"]
    data: dict[str, Any] = {"branch": branch, "worktree": str(path), "old": git(path, "rev-parse", branch)}
    if branch in excluded:
        data["status"] = "excluded"
    elif not path.exists():
        data["status"] = "missing-worktree"
    elif git(path, "status", "--porcelain"):
        data["status"] = "skipped-dirty"
    elif in_progress(path):
        data["status"] = "skipped-operation-in-progress"
    else:
        fork = git(root, "merge-base", branch, base)
        data["fork"] = fork
        probe = subprocess.run(["git", "merge-base", "--is-ancestor", source, branch], cwd=root)
        data["status"] = "noop" if probe.returncode == 0 else "planned"
    return data


def command_plan(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    states = state_root(root)
    lock_path = states / "lock"
    acquire_lock(lock_path)
    integration_worktree: Path | None = None
    try:
        if not args.no_fetch:
            git(root, "fetch", "--prune", args.remote, args.upstream_branch)
            if subprocess.run(["git", "rev-parse", "origin/main"], cwd=root, capture_output=True).returncode == 0:
                git(root, "fetch", "--prune", "origin", "main")
        source = git(root, "rev-parse", f"{args.remote}/{args.upstream_branch}")
        base_ref = "origin/main" if subprocess.run(["git", "rev-parse", "origin/main"], cwd=root, capture_output=True).returncode == 0 else "main"
        base = git(root, "rev-parse", base_ref)
        integration_worktree = states / f"integration-{source[:12]}"
        if integration_worktree.exists():
            run_result = subprocess.run(["git", "worktree", "remove", "--force", str(integration_worktree)], cwd=root, text=True, capture_output=True)
            if run_result.returncode:
                raise RefreshError(run_result.stderr.strip())
        git(root, "worktree", "add", "--detach", str(integration_worktree), base)
        merge = subprocess.run(["git", "merge", "--no-ff", "--no-edit", source], cwd=integration_worktree, text=True, capture_output=True)
        if merge.returncode:
            raise RefreshError(merge.stderr.strip() or "upstream integration merge conflicted")
        integration = git(integration_worktree, "rev-parse", "HEAD")
        session = f"{time.time_ns()}-{source[:12]}"
        excluded = set(args.exclude)
        entries = [entry(root, integration, base, item, excluded) for item in worktrees(root)]
        payload = {
            "version": 2, "session": session, "root": str(root), "remote": args.remote,
            "upstream_branch": args.upstream_branch, "source": source, "base": base,
            "integration": integration, "entries": entries,
        }
        path = states / f"{session}.json"
        write_json(path, payload)
        print(f"plan: {path}")
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    finally:
        if integration_worktree and integration_worktree.exists():
            subprocess.run(["git", "worktree", "remove", "--force", str(integration_worktree)], cwd=root, check=False)
        (lock_path / "pid").unlink()
        lock_path.rmdir()
def command_apply(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    plan_path = Path(args.plan).resolve()
    payload = json.loads(plan_path.read_text())
    lock_path = state_root(root) / "lock"
    acquire_lock(lock_path)
    try:
        target = str(payload["integration"])
        backup_prefix = f"refs/backup/omifx-upstream-refresh/{payload['session']}"
        for data in payload["entries"]:
            if data["status"] != "planned":
                continue
            branch = str(data["branch"])
            old = str(data["old"])
            backup = f"{backup_prefix}/{branch.replace('/', '__')}"
            git(root, "update-ref", backup, old)
            path = Path(str(data["worktree"]))
            result = subprocess.run(
                ["git", "rebase", "--rebase-merges", "--onto", target, str(data["fork"]), branch],
                cwd=path, text=True, capture_output=True,
            )
            data["backup"] = backup
            if result.returncode:
                data["status"] = "conflict"
                data["error"] = result.stderr.strip()
                write_json(plan_path, payload)
                print(json.dumps(payload, indent=2, sort_keys=True))
                return 2
            data["status"] = "updated"
            data["new"] = git(path, "rev-parse", branch)
        write_json(plan_path, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    finally:
        (lock_path / "pid").unlink()
        lock_path.rmdir()
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--root", default=".")
    plan.add_argument("--remote", default="upstream")
    plan.add_argument("--upstream-branch", default="main")
    plan.add_argument("--exclude", action="append", default=[])
    plan.add_argument("--no-fetch", action="store_true")
    apply = sub.add_parser("apply")
    apply.add_argument("--root", default=".")
    apply.add_argument("--plan", required=True)
    args = parser.parse_args()
    return command_plan(args) if args.command == "plan" else command_apply(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RefreshError, json.JSONDecodeError) as exc:
        print(f"upstream-refresh: {exc}", file=sys.stderr)
        raise SystemExit(3)
