"""Serial story scheduling and verified integration; no LLM or live-run defaults."""

import argparse
import json
import os
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


def git(project, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(project), *args], check=check, text=True, capture_output=True
    )


def branch_states(project):
    refs = git(project, "for-each-ref", "--format=%(refname:short)", "refs/heads/story/").stdout.splitlines()
    result = {}
    for ref in refs:
        match = re.fullmatch(r"story/story-([0-9]+)", ref)
        if match:
            status = git(project, "merge-base", "--is-ancestor", ref, "main", check=False)
            if status.returncode not in (0, 1):
                raise ValueError(f"Cannot inspect {ref} against main")
            result[int(match[1])] = status.returncode == 0
    return result


def base_story(document):
    sections = re.findall(r"^## Base Story[ \t]*\n(.*?)(?=^## |\Z)", document, re.M | re.S)
    if len(sections) != 1:
        raise ValueError("Story requires exactly one ## Base Story section")
    value = sections[0].strip()
    match = re.fullmatch(r"- (main|story-([0-9]+))", value)
    if not match:
        raise ValueError("Base Story must contain only - main or - story-<row_id>")
    return int(match[2]) if match[2] else None


def plan(rows, columns, branches, read_base):
    """Return one action. A retained unlanded branch takes priority over new work."""
    type_col, status_col, parent_col, title_col = (columns[k] for k in ("Type", "Status", "Parent", "Title"))
    stories = {int(r["row_id"]): r for r in rows if r["row_data"].get(type_col) == "story"}
    children = {rid: [] for rid in stories}
    for row in rows:
        data = row["row_data"]
        if data.get(type_col) not in ("task", "bug"):
            continue
        parent = str(data.get(parent_col, ""))
        if not parent.isdecimal() or int(parent) not in stories:
            if data.get(status_col) == "merged":
                continue  # Historical closed issues are not executable work.
            raise ValueError(f"Issue {row['row_id']} has no readable story parent")
        children[int(parent)].append(row)
    if any(rid not in stories and not landed for rid, landed in branches.items()):
        raise ValueError("Unlanded story branch has no PM story; reconcile it before dispatch")

    def finished(rid):
        # Old merged stories may have had their branches deleted. This runner
        # retains branches, so its own integrations always have Git evidence.
        return (
            stories[rid]["row_data"].get(status_col) == "merged"
            and branches.get(rid) is not False
            and all(r["row_data"].get(status_col) == "merged" for r in children[rid])
        )

    pending = [rid for rid in stories if not finished(rid)]
    if not pending:
        return "ALL_DONE"
    rid = min(pending, key=lambda r: (branches.get(r) is not False, r))
    seen = set()
    while True:
        if rid in seen:
            raise ValueError("Cyclic Base Story dependency")
        seen.add(rid)
        dependency = read_base(rid)
        if dependency is None:
            break
        if dependency not in stories:
            raise ValueError(f"Story {rid} depends on a missing/non-story row {dependency}")
        if finished(dependency):
            break
        rid = dependency
    issues = sorted(children[rid], key=lambda r: int(r["row_id"]))
    if not issues:
        raise ValueError(f"Story {rid} has no issues; cannot declare it complete")
    statuses = {r["row_data"].get(status_col) for r in issues}
    if not statuses <= {"todo", "merged"}:
        raise ValueError(f"Story {rid} has unfinished/blocked issues; refusing another story")
    todo = next((r for r in issues if r["row_data"].get(status_col) == "todo"), None)
    if todo:
        title = " ".join(str(todo["row_data"].get(title_col, "")).split())
        title = title.replace("row_id=", "row-id=").replace("parent=", "parent-id=")
        return f"TASK1: {title} (row_id={todo['row_id']} parent={rid})"
    return f"MERGE: {rid}"


class PM:
    def __init__(self, api, table):
        self.api = api.rstrip("/")
        self.table = "/tables/" + urllib.parse.quote(table, safe="")
        self.auth = os.environ["LC_AUTH_HEADER"].removeprefix("Authorization: ")
        schema = self.request(self.table)
        self.columns = {c["name"]: c["column_id"] for c in schema["columns"]}
        skills = Path(os.environ.get("SKILLS_DIR", Path(__file__).resolve().parents[3]))
        resolver = skills / "developing/project-management/pm_doc_column.py"
        self.doc = subprocess.run(
            ["python3", str(resolver)], input=json.dumps(schema), text=True,
            capture_output=True, check=True,
        ).stdout.strip()

    def request(self, path, data=None, raw=False):
        request = urllib.request.Request(
            self.api + path,
            data=json.dumps(data).encode() if data is not None else None,
            headers={"Authorization": self.auth, "Content-Type": "application/json"},
            method="PATCH" if data is not None else "GET",
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read().decode()
        return body if raw else json.loads(body)

    def rows(self):
        rows, seen, offset = [], set(), 0
        while True:
            page = self.request(f"{self.table}/rows?limit=500&sort=asc&offset={offset}")
            if not isinstance(page, list):
                raise ValueError("PM returned an invalid row page")
            for row in page:
                rid = int(row["row_id"])
                if rid in seen:
                    raise ValueError("PM pagination repeated a row; refusing incomplete state")
                seen.add(rid)
            rows.extend(page)
            if len(page) < 500:
                return rows
            offset += len(page)

    def base(self, rid):
        return base_story(self.request(f"{self.table}/rows/{rid}/blob/{self.doc}", raw=True))

    def status(self, rid, value):
        self.request(f"{self.table}/rows/{rid}", {"row_data": {self.columns["Status"]: value}})

    def plan(self, project):
        return plan(self.rows(), self.columns, branch_states(project), self.base)


def integrate(project, rid, verify, ready):
    """Verify the combined tree before fast-forwarding main. Retain failures."""
    if not verify.strip():
        raise ValueError("Set HIVE_STORY_VERIFY_CMD (or HIVE_VERIFY_CMD); story merge requires verification")
    if not os.environ.get("TMUX"):
        raise ValueError("Story integration must run inside tmux")
    if not str(rid).isdecimal():
        raise ValueError("Story ID must be numeric")
    project = Path(project).resolve()
    lock = project / "_git.lock"
    lock.mkdir()  # Never remove or take over a lock owned by another process.
    try:
        if git(project, "branch", "--show-current").stdout.strip() != "main":
            raise ValueError("Project checkout must stay on main")
        if git(project, "status", "--porcelain").stdout:
            raise ValueError("Main checkout is dirty; refusing integration")
        branch = f"story/story-{rid}"
        tip = git(project, "rev-parse", "--verify", f"refs/heads/{branch}").stdout.strip()
        story_tree = project / ".tmp" / f"story_{rid}"
        if (git(story_tree, "branch", "--show-current").stdout.strip() != branch
                or git(story_tree, "status", "--porcelain").stdout):
            raise ValueError("Story worktree is missing, dirty, or on the wrong branch")
        base = git(project, "rev-parse", "HEAD").stdout.strip()
        (project / ".tmp").mkdir(exist_ok=True)
        candidate = Path(tempfile.mkdtemp(prefix=f"story-merge-{rid}-", dir=project / ".tmp"))
        print(f"Integration candidate retained on failure: {candidate}", flush=True)
        git(project, "worktree", "add", "--detach", str(candidate), base)
        git(candidate, "merge", "--no-ff", "--no-edit", tip)
        verified = git(candidate, "rev-parse", "HEAD").stdout.strip()
        env = dict(os.environ, PROJECT_DIR=str(candidate), HIVE_REPO_ROOT=str(project),
                   HIVE_INTEGRATION_DIR=str(candidate), HIVE_STORY_ID=str(rid))
        subprocess.run(verify, shell=True, executable="/bin/bash", cwd=candidate, env=env, check=True)
        if git(candidate, "status", "--porcelain").stdout:
            raise ValueError("Story verification left tracked/untracked changes")
        if git(candidate, "rev-parse", "HEAD").stdout.strip() != verified:
            raise ValueError("Verification changed the candidate commit; refusing integration")
        if (git(project, "branch", "--show-current").stdout.strip() != "main"
                or git(project, "rev-parse", "HEAD").stdout.strip() != base
                or git(project, "status", "--porcelain").stdout
                or git(project, "rev-parse", branch).stdout.strip() != tip
                or git(story_tree, "branch", "--show-current").stdout.strip() != branch
                or git(story_tree, "status", "--porcelain").stdout):
            raise ValueError("Main/story changed during verification; verify again before landing")
        if not ready():
            raise ValueError("PM story state changed during verification; refusing integration")
        git(candidate, "merge-base", "--is-ancestor", tip, verified)
        git(project, "merge", "--ff-only", verified)
        git(project, "merge-base", "--is-ancestor", tip, "main")
        # No force: unexpected worktree changes must never be discarded.
        git(project, "worktree", "remove", str(candidate))
        return verified
    finally:
        lock.rmdir()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("plan", "land"))
    parser.add_argument("project", type=Path)
    parser.add_argument("--api", required=True)
    parser.add_argument("--table", required=True)
    parser.add_argument("--story", type=int)
    args = parser.parse_args()
    pm = None
    claimed = False
    try:
        pm = PM(args.api, args.table)
        if args.action == "plan":
            print(pm.plan(args.project))
            return 0
        if args.story is None or pm.plan(args.project) != f"MERGE: {args.story}":
            raise ValueError("Story is not ready to merge")
        pm.status(args.story, "review")
        claimed = True
        verify = os.environ.get("HIVE_STORY_VERIFY_CMD") or os.environ.get("HIVE_VERIFY_CMD", "")
        commit = integrate(args.project, args.story, verify,
                           lambda: pm.plan(args.project) == f"MERGE: {args.story}")
        pm.status(args.story, "merged")  # Only after main contains the verified tree.
        print(f"Story {args.story} merged into main at {commit}")
        return 0
    except Exception as exc:
        if claimed:
            try:
                pm.status(args.story, "debugging")
            except Exception:
                pass  # Still fail closed; never dispatch another story.
        detail = exc.stderr if isinstance(exc, subprocess.CalledProcessError) else ""
        print(f"BLOCKED: {exc}\n{detail or ''}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
