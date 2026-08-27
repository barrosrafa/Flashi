from pathlib import Path
import re
import unittest

from pglast import parse_sql


ROOT = Path(__file__).resolve().parents[1]


class FlashiContractsTest(unittest.TestCase):
    def test_all_migrations_parse(self):
        migrations = sorted(ROOT.glob("00*.sql"))
        self.assertGreaterEqual(len(migrations), 15)
        for migration in migrations:
            with self.subTest(migration=migration.name):
                statements = parse_sql(migration.read_text(encoding="utf-8"))
                self.assertTrue(statements, migration.name)

    def test_hardening_contracts_are_present(self):
        migration = (ROOT / "0015_hardening_workers_contracts.sql").read_text(encoding="utf-8")
        required_fragments = (
            "review_logs_user_client_review_id",
            "record_review_fsrs6_idempotent",
            "card_media_sha256_hash_check",
            "list_orphaned_card_media",
            "p_expected_usn bigint default null",
            "CARD_STATE_CHANGED",
            "client_review_id is already associated with another card",
            "where d.user_id = auth.uid()",
            "where g.user_id = auth.uid()",
        )
        for fragment in required_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, migration)

    def test_edge_functions_use_user_scoped_and_bounded_contracts(self):
        sync = (ROOT / "supabase/functions/sync/index.ts").read_text(encoding="utf-8")
        fsrs = (ROOT / "supabase/functions/fsrs-review/index.ts").read_text(encoding="utf-8")
        embeddings = (ROOT / "supabase/functions/embeddings/index.ts").read_text(encoding="utf-8")

        self.assertIn('rpc("get_incremental_sync"', sync)
        self.assertIn("next_usn", sync)
        self.assertIn("has_more", sync)
        self.assertIn('rpc(\n      "record_review_fsrs6_idempotent"', fsrs)
        self.assertIn("client_review_id", fsrs)
        self.assertIn("fsrs(parameters)", fsrs)
        self.assertIn("const DIMENSIONS = 1536", embeddings)
        self.assertIn("sha256Hex(text)", embeddings)
        self.assertIn("embedding.length !== DIMENSIONS", embeddings)

    def test_no_credential_markers_are_tracked(self):
        candidates = list(ROOT.glob("*.sql")) + list(ROOT.glob("*.py"))
        candidates += list(ROOT.glob("supabase/functions/**/*.ts"))
        for path in candidates:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertIsNone(re.search(r"ghp_[A-Za-z0-9]{20,}", text))
                self.assertIsNone(re.search(r"github_pat_[A-Za-z0-9_]{20,}", text))
                self.assertNotIn("service_" + "role_key=", text)


if __name__ == "__main__":
    unittest.main()
