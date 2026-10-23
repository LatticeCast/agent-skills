"""E2E context: Playwright page + psycopg2 connection + paired asserts.

Copy into project's browser/ dir.
"""
import os

import psycopg2
from playwright.sync_api import sync_playwright


class E2E:
    def __init__(
        self,
        url: str = "http://lattice-cast:13491",
        dsn: str | None = None,
    ):
        self.url = url.rstrip("/")
        self._pw = sync_playwright().start()
        self.browser = self._pw.chromium.launch(headless=True)
        self.context = self.browser.new_context()
        self.page = self.context.new_page()
        self.db = psycopg2.connect(dsn or os.environ["DATABASE_URL"])
        self.db.autocommit = True

    def close(self):
        self.db.close()
        self.context.close()
        self.browser.close()
        self._pw.stop()

    # ── DB ────────────────────────────────────────────────────────────────

    def assert_db(self, sql, params=None, msg=""):
        with self.db.cursor() as cur:
            cur.execute(sql, params or ())
            row = cur.fetchone()
        assert row is not None, f"DB assert failed: {msg or sql}"
        return row

    def db_count(self, table, **where) -> int:
        sql = f"SELECT count(*) FROM {table}"
        params = ()
        if where:
            sql += " WHERE " + " AND ".join(f"{k} = %s" for k in where)
            params = tuple(where.values())
        with self.db.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchone()[0]

    def db_get(self, table, **where):
        sql = f"SELECT * FROM {table}"
        params = ()
        if where:
            sql += " WHERE " + " AND ".join(f"{k} = %s" for k in where)
            params = tuple(where.values())
        with self.db.cursor() as cur:
            cur.execute(sql, params)
            row = cur.fetchone()
            if row is None:
                return None
            cols = [d[0] for d in cur.description]
            return dict(zip(cols, row))

    # ── UI ────────────────────────────────────────────────────────────────

    def assert_visible(self, selector, text=None, timeout=5000):
        loc = self.page.locator(selector)
        if text is not None:
            loc = loc.filter(has_text=text)
        loc.first.wait_for(state="visible", timeout=timeout)

    def assert_table_in_sidebar(self, table_name):
        # The sidebar renders the display name; the route id is a number.
        self.assert_visible(".sidebar", text=table_name)

    def assert_table_in_main_grid(self, table_name):
        self.assert_visible(".main-grid, .table-header", text=table_name)

    def assert_kanban_grouped_by(self, column_label):
        self.assert_visible(".kanban-column-header", text=column_label)
