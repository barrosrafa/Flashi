from pathlib import Path
import re
import unittest

from pglast import parse_sql


ROOT = Path(__file__).resolve().parents[1]


class FlashiContractsTest(unittest.TestCase):
    def test_all_migrations_parse(self):
        migrations = sorted(ROOT.glob("00*.sql"))
        self.assertGreaterEqual(len(migrations), 23)
        for migration in migrations:
            with self.subTest(migration=migration.name):
                statements = parse_sql(migration.read_text(encoding="utf-8"))
                self.assertTrue(statements, migration.name)

    def test_hardening_and_feature_contracts_are_present(self):
        migration = (ROOT / "0015_hardening_workers_contracts.sql").read_text(encoding="utf-8")
        security_migration = (ROOT / "0016_security_advisors_hardening.sql").read_text(encoding="utf-8")
        rls_migration = (ROOT / "0017_fix_rls_recursion_and_fk_indexes.sql").read_text(encoding="utf-8")
        feature_migration = (ROOT / "0018_search_optimizer_anki_contracts.sql").read_text(encoding="utf-8")
        scheduler_migration = (ROOT / "0019_fsrs_scheduler.sql").read_text(encoding="utf-8")
        pg_net_migration = (ROOT / "0020_move_pg_net_registration.sql").read_text(encoding="utf-8")
        image_occlusion_grant_migration = (ROOT / "0022_harden_image_occlusion_grant.sql").read_text(encoding="utf-8")
        security_cleanup_migration = (ROOT / "0023_security_definer_cleanup.sql").read_text(encoding="utf-8")
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
        for fragment in ("security_invoker", "assign_sync_usn", "record_sync_grave"):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, security_migration)
        for fragment in ("private.is_deck_owner", "private.is_deck_collaborator", "idx_anki_transfer_jobs_source_deck"):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, rls_migration)
        for fragment in (
            "anki-transfers",
            "claim_fsrs_optimization_job_for_worker",
            "complete_fsrs_optimization_job_for_worker",
            "fail_fsrs_optimization_job_for_worker",
            "create_anki_transfer_job",
            "revoke execute on function public.claim_fsrs_optimization_job_for_worker",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, feature_migration)
        for fragment in (
            "private.configure_fsrs_optimizer_cron",
            "flashi_service_role_jwt",
            "vault.decrypted_secrets",
            "flashi-fsrs-optimize-worker",
            "revoke execute on function private.configure_fsrs_optimizer_cron",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, scheduler_migration)
        for fragment in ("drop extension if exists pg_net", "create extension pg_net with schema extensions"):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, pg_net_migration)
        for fragment in (
            "revoke execute on function public.create_image_occlusion_note(uuid, jsonb) from public, anon",
            "grant execute on function public.create_image_occlusion_note(uuid, jsonb) to authenticated",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, image_occlusion_grant_migration)
        for fragment in (
            "alter function public.get_incremental_sync(bigint, integer)",
            "set search_path = public",
            "alter function public.create_image_occlusion_note(uuid, jsonb)",
            "security invoker",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, security_cleanup_migration)

    def test_edge_functions_use_user_scoped_and_bounded_contracts(self):
        sync = (ROOT / "supabase/functions/sync/index.ts").read_text(encoding="utf-8")
        fsrs = (ROOT / "supabase/functions/fsrs-review/index.ts").read_text(encoding="utf-8")
        embeddings = (ROOT / "supabase/functions/embeddings/index.ts").read_text(encoding="utf-8")
        semantic = (ROOT / "supabase/functions/semantic-search/index.ts").read_text(encoding="utf-8")
        optimizer = (ROOT / "supabase/functions/fsrs-optimize/index.ts").read_text(encoding="utf-8")
        optimizer_worker = (ROOT / "supabase/functions/fsrs-optimize-worker/index.ts").read_text(encoding="utf-8")
        anki = (ROOT / "supabase/functions/anki-transfer/index.ts").read_text(encoding="utf-8")
        deno = (ROOT / "supabase/functions/deno.json").read_text(encoding="utf-8")

        self.assertIn('rpc("get_incremental_sync"', sync)
        self.assertIn("next_usn", sync)
        self.assertIn("has_more", sync)
        self.assertIn('rpc(\n      "record_review_fsrs6_idempotent"', fsrs)
        self.assertIn("client_review_id", fsrs)
        self.assertIn("fsrs(parameters)", fsrs)
        self.assertIn("const DIMENSIONS = 1536", embeddings)
        self.assertIn("sha256Hex(text)", embeddings)
        self.assertIn("embedding.length !== DIMENSIONS", embeddings)
        self.assertIn('rpc("mcp_search_notes"', semantic)
        self.assertIn("OPENAI_API_KEY", semantic)
        self.assertIn("mode must be semantic or lexical", semantic)
        self.assertIn('rpc("enqueue_fsrs_optimization")', optimizer)
        self.assertIn("MAX_REVIEWS", optimizer)
        self.assertIn("parameter_count", optimizer)
        self.assertIn("claim_fsrs_optimization_job_for_worker", optimizer_worker)
        self.assertIn('jwtRole(request) !== "service_role"', optimizer_worker)
        self.assertIn("complete_fsrs_optimization_job_for_worker", optimizer_worker)
        self.assertIn("MAX_PACKAGE_BYTES", anki)
        self.assertIn("parseAnkiPackage", anki)
        self.assertIn("include_media", anki)
        self.assertIn('from("anki-transfers")', anki)
        for dependency in (
            '"@sqlite.org/sqlite-wasm": "npm:@sqlite.org/sqlite-wasm@3.53.0-build1"',
            '"fflate": "npm:fflate@0.8.3"',
            '"fsrs-browser": "npm:fsrs-browser@6.6.0/fsrs_browser.js"',
        ):
            with self.subTest(dependency=dependency):
                self.assertIn(dependency, deno)

    def test_local_feature_tests_are_present(self):
        self.assertTrue((ROOT / "tests/fsrs_smoke.ts").is_file())
        self.assertTrue((ROOT / "tests/anki_roundtrip.ts").is_file())
        self.assertIn("zipSlipRejected", (ROOT / "tests/anki_roundtrip.ts").read_text(encoding="utf-8"))
        self.assertIn('weights.length !== 21', (ROOT / "tests/fsrs_smoke.ts").read_text(encoding="utf-8"))

    def test_missing_features_contracts_are_present(self):
        migration = (ROOT / "0021_ai_ingestion_occlusion_references.sql").read_text(encoding="utf-8")
        ingest = (ROOT / "supabase/functions/ai-ingest/index.ts").read_text(encoding="utf-8")
        worker_contract = (ROOT / "supabase/functions/ai-ingest/WORKER_CONTRACT.md").read_text(encoding="utf-8")
        for fragment in (
            "generation_source_type",
            "job_status_type",
            "ai_ingestion_jobs",
            "note_image_occlusion_boxes",
            "note_references",
            "create_image_occlusion_note",
            "cards(user_id",
            "card_learning_state(user_id, card_id, state)",
            "note_image_occlusion_box",
            "note_reference",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, migration)
        for fragment in ("MAX_PDF_BYTES", "ai_ingestion_jobs", 'status: "queued"', "requireUserId"):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, ingest)
        self.assertIn("15 MiB", worker_contract)
        self.assertIn("migração 0021", worker_contract)

    def test_no_credential_markers_are_tracked(self):
        candidates = list(ROOT.glob("*.sql")) + list(ROOT.glob("*.py"))
        candidates += list(ROOT.glob("supabase/functions/**/*.ts"))
        candidates += list(ROOT.glob("supabase/functions/*.json"))
        for path in candidates:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertIsNone(re.search(r"ghp_[A-Za-z0-9]{20,}", text))
                self.assertIsNone(re.search(r"github_pat_[A-Za-z0-9_]{20,}", text))
                self.assertNotIn("service_" + "role_key=", text)


if __name__ == "__main__":
    unittest.main()
