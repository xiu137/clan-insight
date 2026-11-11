from __future__ import annotations
import importlib.util
from pathlib import Path
import unittest
import json

spec = importlib.util.spec_from_file_location("fetch_d1", Path(__file__).resolve().parents[1] / "tools/fetch_d1.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FakeReader:
    def __init__(self, change=False, clan="#CLAN"):
        self.change = change; self.clan = clan; self.meta_count = 0; self.sql = []
    def query(self, sql, params=None):
        self.sql.append(sql)
        if sql == module.META:
            self.meta_count += 1
            return [{"clan_tag": self.clan, "last_success": str(self.meta_count) if self.change else "stable", "high_water": 1, "failed": 0}]
        return [{"row_id": 1, "data": json.dumps({"kind": "player", "confirmedAt": "old"}), "confirmed_at": "2026-11-11T00:00:00Z"}]

class ExportTests(unittest.TestCase):
    def test_separate_confirmed_column_overrides_stored_json(self):
        source = FakeReader()
        archive, status = module.export(source, "#CLAN")
        self.assertEqual(archive["observations"][0]["confirmedAt"], "2026-11-11T00:00:00Z")
        self.assertEqual(status["issues"], [])
        self.assertEqual(source.sql, [module.META, module.PAGE, module.META])
    def test_wrong_clan_stops_before_downloading_rows(self):
        source = FakeReader(clan="#OTHER")
        with self.assertRaises(ValueError): module.export(source, "#CLAN")
        self.assertEqual(source.sql, [module.META])
    def test_source_changes_never_publish_partial_archive(self):
        source = FakeReader(change=True)
        old_sleep = module.time.sleep
        module.time.sleep = lambda _: None
        try:
            with self.assertRaises(RuntimeError): module.export(source, "#CLAN")
        finally: module.time.sleep = old_sleep
        self.assertEqual(source.meta_count, 6)
    def test_query_is_restricted_to_fixed_selects(self):
        reader = module.D1Reader("a" * 32, "a" * 36, "test-not-a-secret")
        with self.assertRaises(ValueError): reader.query("DELETE FROM clan_observations")

if __name__ == "__main__": unittest.main()
