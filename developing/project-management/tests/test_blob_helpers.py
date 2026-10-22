"""Isolated schema and Bash API helper tests; no live service requests."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


PM_DIR = Path(__file__).resolve().parents[1]
SKILLS = PM_DIR.parents[1]
GATE = SKILLS / "agent/agentic-hive/example-scripts/story_gate.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resolver = load("pm_doc_column", PM_DIR / "pm_doc_column.py")
gate = load("story_gate", GATE)


def column(cid="doc-id", name="Doc", kind="text", column_type="blob"):
    return {"name": name, "column_id": cid, "type": column_type, "options": {"kind": kind}}


class BlobHelperTests(unittest.TestCase):
    def setUp(self):
        scratch = os.environ.get("HIVE_TEST_TMP")
        if not scratch:
            self.fail("Set HIVE_TEST_TMP to the project's .tmp directory")
        self.temp = tempfile.TemporaryDirectory(prefix="pm-blob-test-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, PROJECT_DIR=str(self.root), SKILLS_DIR=str(SKILLS),
                        LC_API="http://unused.invalid/api/v1", TABLE_ID="pm",
                        LC_AUTH_HEADER="Authorization: Bearer fixture-jwt", PM_ENV_FILE="/dev/null")
        self.schema = {"columns": [column("legacy", kind="doc"),
                                   column("notes", "Notes"), column()]}

    def bash(self, commands, schema=None, rc=0):
        # Mock only the HTTP boundary; execute the real shell helpers.
        script = '''
set -euo pipefail
source "$SKILLS_DIR/developing/project-management/pm_tool.sh"
lc_table_get() { printf '%s' "$SCHEMA_JSON"; }
curl() { printf '%s\\0' "$@"; return "$MOCK_RC"; }
''' + commands
        return subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                              env=dict(self.env, SCHEMA_JSON=json.dumps(schema or self.schema), MOCK_RC=str(rc)))

    def test_named_doc_wins_independent_of_schema_order(self):
        self.assertEqual(resolver.resolve(self.schema), "doc-id")
        self.assertEqual(resolver.resolve({"columns": list(reversed(self.schema["columns"]))}), "doc-id")

    def test_single_renamed_text_blob_is_supported(self):
        self.assertEqual(resolver.resolve({"columns": [column(name="Details")]}), "doc-id")

    def test_legacy_missing_and_ambiguous_columns_are_rejected(self):
        for columns in ([], [column(kind="doc")], [column(column_type="text")],
                        [column(name="Notes"), column("other", "Other")]):
            with self.subTest(columns=columns), self.assertRaises(ValueError):
                resolver.resolve({"columns": columns})

    def test_pm_helper_and_story_gate_select_same_current_doc(self):
        result = self.bash("pm_doc_col")
        self.assertEqual(result.returncode, 0, result.stderr)
        with patch.dict(os.environ, self.env), patch.object(gate.PM, "request", return_value=self.schema):
            self.assertEqual(gate.PM("http://unused.invalid", "pm").doc, result.stdout.strip())

    def test_stale_cache_is_ignored_without_deleting_it(self):
        cache = self.root / ".tmp/agentic-hive/_doc_col"
        cache.parent.mkdir(parents=True)
        cache.write_text("legacy\n")
        result = self.bash("pm_doc_col")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "doc-id")
        self.assertEqual(cache.read_text(), "legacy\n")

    def test_pm_helper_legacy_only_fails(self):
        result = self.bash("pm_doc_col", {"columns": [column(kind="doc")]})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_document_operations_do_not_send_requests_when_resolution_fails(self):
        for operation in ("pm_read_doc 42", "pm_read_ticket_doc 42", "pm_write_doc 42 body",
                          "pm_append_doc 42 log"):
            result = self.bash("set +e\n" + operation, {"columns": [column(kind="doc")]})
            with self.subTest(operation=operation):
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_document_operations_login_in_parent_shell(self):
        for operation in ("pm_read_doc 42", "pm_read_ticket_doc 42", "pm_write_doc 42 body",
                          "pm_append_doc 42 log"):
            result = self.bash('''
unset LC_AUTH_HEADER
lc_login_password() { printf fixture-jwt; }
lc_blob_doc_read() { _lc_check_env; printf existing; }
lc_blob_doc_write() { _lc_check_env; cat >/dev/null; printf saved; }
''' + operation)
            with self.subTest(operation=operation):
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_append_resolves_once_for_both_read_and_write(self):
        result = self.bash('''
pm_doc_col() { printf x >> "$PROJECT_DIR/resolutions"; printf doc-id; }
lc_blob_doc_read() { printf '# Existing'; }
lc_blob_doc_write() { printf '%s\\n' "$3"; cat; }
pm_append_doc 42 log
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "resolutions").read_text(), "x")
        self.assertTrue(result.stdout.startswith("doc-id\n# Existing\n- "))

    def test_queen_uses_same_resolver_at_dispatch(self):
        # Source only queen's actual function; do not run startup or real bees.
        queen = (GATE.parent / "queen.sh").read_text()
        start = queen.index("doc_col() {")
        end = queen.index("\n}", start) + 2
        result = self.bash('PM_URL=http://unused.invalid; AUTH="$LC_AUTH_HEADER"\n'
                           'curl() { printf "%s" "$SCHEMA_JSON"; }\n' + queen[start:end] + "\ndoc_col")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "doc-id")

    def test_upload_without_mime_retains_original_request(self):
        result = self.bash("lc_blob_upload pm 42 doc-id '/fixture/file name.bin'")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = result.stdout.rstrip("\0").split("\0")
        self.assertEqual(args[args.index("-F") + 1], "file=@/fixture/file name.bin")
        self.assertIn("http://unused.invalid/api/v1/tables/pm/rows/42/blob/doc-id", args)

    def test_upload_explicit_mime(self):
        result = self.bash("lc_blob_upload pm 42 doc-id /fixture/file.md text/markdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("file=@/fixture/file.md;type=text/markdown\0", result.stdout)

    def test_markdown_file_delegates_and_preserves_caller_file(self):
        document = self.root / "caller.md"
        document.write_text("# Keep\n")
        result = self.bash('lc_blob_doc_write pm 42 doc-id -f "$PROJECT_DIR/caller.md"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"file=@{document};type=text/markdown\0", result.stdout)
        self.assertEqual(document.read_text(), "# Keep\n")

    def test_stdin_markdown_temp_is_local_and_cleaned_up(self):
        result = self.bash("printf '# Body' | lc_blob_doc_write pm 42 doc-id")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"file=@{self.root}/.tmp/blob-doc.", result.stdout)
        self.assertFalse(list((self.root / ".tmp").glob("blob-doc.*")))

    def test_upload_failure_is_preserved_and_stdin_temp_is_cleaned_up(self):
        result = self.bash("printf '# Body' | lc_blob_doc_write pm 42 doc-id", rc=22)
        self.assertEqual(result.returncode, 22)
        self.assertFalse(list((self.root / ".tmp").glob("blob-doc.*")))


if __name__ == "__main__":
    unittest.main()
