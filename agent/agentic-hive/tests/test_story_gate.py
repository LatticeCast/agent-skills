"""Run in tmux: HIVE_TEST_TMP=$PWD/.tmp python3 -m unittest discover -s <tests>."""

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "example-scripts" / "story_gate.py"
SPEC = importlib.util.spec_from_file_location("story_gate", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
COLS = {name: name.lower() for name in ("Type", "Status", "Parent", "Title")}


def row(rid, kind="story", status="todo", parent=None):
    return {"row_id": rid, "row_data": {"type": kind, "status": status,
                                        "parent": parent, "title": f"row {rid}"}}


class PlanningTests(unittest.TestCase):
    def action(self, rows, branches=None, dependencies=None):
        return gate.plan(rows, COLS, branches or {}, lambda rid: (dependencies or {}).get(rid))

    def test_last_issue_requires_story_merge_not_all_done(self):
        self.assertEqual(self.action([row(1), row(2, "task", "merged", 1)]), "MERGE: 1")

    def test_pm_merged_is_not_git_merged(self):
        self.assertEqual(self.action([row(1, status="merged"), row(2, "task", "merged", 1)],
                                     {1: False}), "MERGE: 1")

    def test_done_requires_pm_and_git(self):
        self.assertEqual(self.action([row(1, status="merged"), row(2, "task", "merged", 1)],
                                     {1: True}), "ALL_DONE")

    def test_one_issue_one_story(self):
        self.assertEqual(self.action([row(1), row(2, "task", parent=1), row(3),
                                      row(4, "task", parent=3)]), "TASK1: row 2 (row_id=2 parent=1)")

    def test_active_unlanded_branch_precedes_new_story(self):
        self.assertEqual(self.action([row(1), row(2, "task", parent=1), row(3),
                                      row(4, "task", "merged", 3)], {3: False}), "MERGE: 3")

    def test_blocked_issue_does_not_skip_to_next_story(self):
        for status in ("debugging", "testing", "review", "in_progress", "unknown", None):
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "blocked"):
                self.action([row(1), row(2, "task", status, 1), row(3), row(4, "task", parent=3)])

    def test_dependencies_land_first(self):
        rows = [row(1), row(2, "task", parent=1), row(3), row(4, "task", "merged", 3)]
        self.assertEqual(self.action(rows, dependencies={1: 3}), "MERGE: 3")
        rows[2]["row_data"]["status"] = "merged"
        self.assertTrue(self.action(rows, {3: True}, {1: 3}).startswith("TASK1:"))

    def test_cycle_missing_dependency_empty_story_orphan_fail_closed(self):
        for rows, deps in (([row(1), row(3)], {1: 3, 3: 1}),
                           ([row(1)], {1: 99}), ([row(1)], {}),
                           ([row(2, "task", parent=99)], {})):
            with self.subTest(rows=rows, deps=deps), self.assertRaises(ValueError):
                self.action(rows, dependencies=deps)

    def test_missing_pm_story_for_unlanded_branch_blocks(self):
        with self.assertRaises(ValueError):
            self.action([], {99: False})

    def test_base_document_validation(self):
        self.assertEqual(gate.base_story("## Base Story\n- story-12\n\n## Other\nx"), 12)
        self.assertIsNone(gate.base_story("## Base Story\n- main\n"))
        for doc in ("", "## Base Story\n- main\n- story-1", "## Base Story\n- main\n## Base Story\n- main"):
            with self.subTest(doc=doc), self.assertRaises(ValueError):
                gate.base_story(doc)


class PaginationTests(unittest.TestCase):
    def test_all_pages_are_read(self):
        pm = object.__new__(gate.PM)
        pm.table = "/tables/pm"
        pages = [[row(n, "epic") for n in range(500)], [row(999)]]
        with patch.object(pm, "request", side_effect=pages) as request:
            self.assertEqual(len(pm.rows()), 501)
            self.assertIn("offset=500", request.call_args.args[0])

    def test_duplicate_page_and_api_failure_are_not_empty_queue(self):
        pm = object.__new__(gate.PM)
        pm.table = "/tables/pm"
        page = [row(n, "epic") for n in range(500)]
        with patch.object(pm, "request", side_effect=[page, page]), self.assertRaises(ValueError):
            pm.rows()
        with patch.object(pm, "request", side_effect=OSError("offline")), self.assertRaises(OSError):
            pm.rows()


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        if not os.environ.get("TMUX"):
            self.fail("Run Git integration tests inside tmux")
        scratch = os.environ.get("HIVE_TEST_TMP")
        if not scratch:
            self.fail("Set HIVE_TEST_TMP to the project's .tmp directory")
        self.temp = tempfile.TemporaryDirectory(prefix="hive-gate-test-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.g("init", "-b", "main")
        self.g("config", "user.name", "Hive Test")
        self.g("config", "user.email", "hive-test@example.invalid")
        self.commit(self.root, ".gitignore", ".tmp/\n_git.lock/\n")
        self.commit(self.root, "shared", "base\n")
        (self.root / ".tmp").mkdir()
        self.story = self.root / ".tmp/story_1"
        self.g("worktree", "add", "-b", "story/story-1", str(self.story))
        self.commit(self.story, "feature", "story\n")
        self.commit(self.root, "main-only", "main\n")
        self.before = self.g("rev-parse", "HEAD")
        self.tip = self.g("rev-parse", "story/story-1")

    def g(self, *args):
        return gate.git(self.root, *args).stdout.strip()

    def commit(self, tree, name, value):
        (tree / name).write_text(value)
        gate.git(tree, "add", name)
        gate.git(tree, "commit", "-m", f"fixture {name}")

    def land(self, verify="test -f feature && test -f main-only", ready=lambda: True):
        return gate.integrate(self.root, 1, verify, ready)

    def assert_unmoved(self):
        self.assertEqual(self.g("rev-parse", "main"), self.before)
        self.assertEqual(self.g("rev-parse", "story/story-1"), self.tip)
        self.assertFalse((self.root / "_git.lock").exists())

    def test_success_tests_combined_tree_and_lands_before_next_story(self):
        landed = self.land('test -f feature && test -f main-only && test "$PWD" = "$PROJECT_DIR" && '
                           'test "$PROJECT_DIR" = "$HIVE_INTEGRATION_DIR" && test "$HIVE_STORY_ID" = 1')
        self.assertEqual(self.g("rev-parse", "main"), landed)
        self.assertNotEqual(landed, self.before)
        self.assertEqual(gate.branch_states(self.root), {1: True})
        self.assertTrue(self.story.is_dir())
        self.assertFalse(list((self.root / ".tmp").glob("story-merge-*")))
        self.assertEqual(self.g("status", "--porcelain"), "")

    def test_red_verification_retains_candidate_without_moving_main(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.land("exit 7")
        self.assert_unmoved()
        self.assertEqual(len(list((self.root / ".tmp").glob("story-merge-*"))), 1)

    def test_conflict_retains_candidate_without_moving_main(self):
        self.commit(self.story, "shared", "story edit\n")
        self.commit(self.root, "shared", "main edit\n")
        self.before = self.g("rev-parse", "HEAD")
        self.tip = self.g("rev-parse", "story/story-1")
        with self.assertRaises(subprocess.CalledProcessError):
            self.land()
        self.assert_unmoved()
        candidate = next((self.root / ".tmp").glob("story-merge-*"))
        self.assertIn("UU shared", gate.git(candidate, "status", "--porcelain").stdout)

    def test_dirty_root_is_not_discarded(self):
        (self.root / "uncommitted").write_text("keep")
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.land()
        self.assert_unmoved()
        self.assertEqual((self.root / "uncommitted").read_text(), "keep")

    def test_dirty_story_is_not_discarded(self):
        (self.story / "feature").write_text("partial work")
        with self.assertRaisesRegex(ValueError, "dirty"):
            self.land()
        self.assert_unmoved()
        self.assertEqual((self.story / "feature").read_text(), "partial work")

    def test_existing_lock_is_never_removed(self):
        lock = self.root / "_git.lock"
        lock.mkdir()
        with self.assertRaises(FileExistsError):
            self.land()
        self.assertTrue(lock.is_dir())
        self.assertEqual(self.g("rev-parse", "main"), self.before)

    def test_no_verification_or_tmux_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "VERIFY_CMD"):
            self.land("")
        with patch.dict(os.environ, {"TMUX": ""}), self.assertRaisesRegex(ValueError, "tmux"):
            self.land()
        self.assert_unmoved()

    def test_verification_must_leave_candidate_clean(self):
        with self.assertRaisesRegex(ValueError, "changes"):
            self.land("printf changed > feature")
        self.assert_unmoved()

    def test_verification_cannot_replace_candidate_commit(self):
        with self.assertRaisesRegex(ValueError, "changed the candidate commit"):
            self.land("git checkout --detach main")
        self.assert_unmoved()

    def test_changed_pm_state_blocks_landing(self):
        with self.assertRaisesRegex(ValueError, "PM story state changed"):
            self.land(ready=lambda: False)
        self.assert_unmoved()

    def test_changed_root_during_verification_blocks_landing(self):
        with self.assertRaisesRegex(ValueError, "changed during verification"):
            self.land('printf keep > "$HIVE_REPO_ROOT/uncommitted"')
        self.assert_unmoved()

    @contextlib.contextmanager
    def pm_server(self, fail_final=False):
        test = self
        rows = [row(1), row(2, "task", "merged", 1), row(3), row(4, "task", parent=3)]
        writes = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                path = urlsplit(self.path)
                if path.path.endswith("/rows"):
                    query = parse_qs(path.query)
                    offset = int(query.get("offset", ["0"])[0])
                    filters = json.loads(query.get("filter_json", ["{}"])[0])
                    data = [r for r in rows if all(r["row_data"].get(k) == v for k, v in filters.items())]
                    data = data[offset:offset + 500]
                elif "/blob/" in path.path:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"## Base Story\n- main\n")
                    return
                else:
                    data = {"columns": [{"name": k, "column_id": v} for k, v in COLS.items()] +
                                       [{"name": "Doc", "column_id": "doc", "type": "blob",
                                         "options": {"kind": "text"}}]}
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())

            def do_PATCH(self):
                data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                status = data["row_data"]["status"]
                writes.append((status, test.g("rev-parse", "main")))
                if fail_final and status == "merged":
                    self.send_error(503)
                    return
                rows[0]["row_data"]["status"] = status
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/api/v1", writes
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def cli(self, action, api, verify="test -f feature && test -f main-only"):
        env = dict(os.environ, LC_AUTH_HEADER="Authorization: Bearer fixture-jwt",
                   HIVE_STORY_VERIFY_CMD=verify)
        return subprocess.run(["python3", str(SCRIPT), action, str(self.root), "--api", api,
                               "--table", "pm", "--story", "1"], env=env, capture_output=True, text=True)

    def test_real_cli_pm_status_order_and_next_story_gate(self):
        with self.pm_server() as (api, writes):
            self.assertEqual(self.cli("plan", api).stdout.strip(), "MERGE: 1")
            result = self.cli("land", api)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(writes[0], ("review", self.before))
            self.assertEqual(writes[1], ("merged", self.g("rev-parse", "main")))
            self.assertNotEqual(writes[1][1], self.before)
            self.assertEqual(self.cli("plan", api).stdout.strip(), "TASK1: row 4 (row_id=4 parent=3)")

    def test_real_cli_red_gate_stops_before_next_story(self):
        with self.pm_server() as (api, writes):
            result = self.cli("land", api, "exit 8")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual([s for s, _ in writes], ["review", "debugging"])
            self.assertEqual(self.cli("plan", api).stdout.strip(), "MERGE: 1")
        self.assert_unmoved()

    def test_final_pm_write_failure_returns_nonzero_even_after_landing(self):
        with self.pm_server(fail_final=True) as (api, writes):
            self.assertNotEqual(self.cli("land", api).returncode, 0)
            self.assertEqual([s for s, _ in writes], ["review", "merged", "debugging"])
            self.assertEqual(self.cli("plan", api).stdout.strip(), "MERGE: 1")
        self.assertNotEqual(self.g("rev-parse", "main"), self.before)

    def queen(self, api, verify):
        env = dict(os.environ, LC_API=api, TABLE_ID="pm",
                   LC_AUTH_HEADER="Authorization: Bearer fixture-jwt",
                   HIVE_STORY_VERIFY_CMD=verify, HIVE_VERIFY_CMD="")
        return subprocess.run(["bash", str(SCRIPT.parent / "queen.sh"), str(self.root), "1", "7"],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_actual_queen_integrates_before_next_dispatch(self):
        with self.pm_server() as (api, writes):
            result = self.queen(api, "test -f feature && test -f main-only")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ignoring num_workers=7", result.stdout)
            self.assertNotIn("Spawn W", result.stdout)
            self.assertEqual([s for s, _ in writes], ["review", "merged"])
            self.assertEqual(gate.branch_states(self.root), {1: True})

    def test_actual_queen_stops_on_red_story_gate(self):
        with self.pm_server() as (api, writes):
            result = self.queen(api, "exit 9")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stopping with worktrees preserved", result.stdout)
            self.assertNotIn("Spawn W", result.stdout)
            self.assertEqual([s for s, _ in writes], ["review", "debugging"])
        self.assert_unmoved()

    def test_actual_queen_requires_verification_at_startup(self):
        with self.pm_server() as (api, writes):
            result = self.queen(api, "")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("VERIFY_CMD", result.stdout)
            self.assertEqual(writes, [])
        self.assert_unmoved()


if __name__ == "__main__":
    unittest.main()
