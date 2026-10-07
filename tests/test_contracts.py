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

    def test_0024_gamification_exam_socratic_contracts(self):
        migration = (ROOT / "0024_gamification_exams_socratic.sql").read_text(encoding="utf-8")
        api_doc = (ROOT / "docs/SUPABASE_API.md").read_text(encoding="utf-8")
        for fragment in (
            "exam_priority_level",
            "user_gamification_profiles",
            "badges_definition",
            "user_badges",
            "add_user_xp",
            "deck_exams",
            "get_due_cards_with_exam_schedule",
            "with recursive",
            "socratic_remediation_sessions",
            "check_card_leech_for_socratic",
            "new.is_suspended := true",
            "resolve_socratic_remediation",
            "graves_entity_type_check",
            "user_gamification_profile",
            "user_badge",
            "deck_exam",
            "socratic_remediation_session",
            "revoke execute on function public.add_user_xp(uuid, integer) from public, anon",
            "grant execute on function public.resolve_socratic_remediation(uuid) to authenticated",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, migration)
        for fragment in (
            "POST /rest/v1/rpc/add_user_xp",
            "POST /rest/v1/rpc/get_due_cards_with_exam_schedule",
            "POST /rest/v1/rpc/resolve_socratic_remediation",
            "POST /rest/v1/rpc/get_incremental_sync",
            "scheduling_factor",
            "auth.uid()",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, api_doc)

    def test_0026_sdd_worker_import_and_session_xp_contracts(self):
        migration = (ROOT / "0026_sdd_ai_worker_gamification_imports.sql").read_text(encoding="utf-8")
        worker = (ROOT / "supabase/functions/ai-ingest-worker/index.ts").read_text(encoding="utf-8")
        importer = (ROOT / "supabase/functions/import-deck/index.ts").read_text(encoding="utf-8")
        import_content = (ROOT / "supabase/functions/_shared/import-content.ts").read_text(encoding="utf-8")
        import_url = (ROOT / "supabase/functions/_shared/import-url.ts").read_text(encoding="utf-8")
        for fragment in (
            "claim_ai_ingestion_job", "for update skip locked", "materialize_ai_ingestion_batch",
            "notes_count integer", "cards_count integer", "sync_session_xp", "gamification_xp_sessions",
            "leaderboard_entries", "deck_import_jobs", "materialize_import_batch",
        ):
            with self.subTest(fragment=fragment): self.assertIn(fragment, migration.lower())
        for fragment in ("service_role", "INGESTION_WORKER_SECRET", "MAX_PDF_BYTES", "pdf-parse", "cheerio", "youtube-transcript", "response_format", "json_schema"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, worker)
        for fragment in ("createSignedUrl", "import-media", "csv", "markdown", "quizlet", "remnote", "materialize_import_batch"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, importer)
        for fragment in ("downloadImportUrl", "MAX_IMPORT_BYTES", "readBoundedResponse", "storage_path or url"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, importer)
        for fragment in ("parseDelimited", "unterminated quoted field", "MAX_NOTES"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, import_content)
        for fragment in ("Deno.resolveDns", "redirect: \"manual\"", "Only the standard HTTPS port"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, import_url)

    def test_v2_snapshot_layout_and_guardrails(self):
        snapshot_dir = ROOT / "supabase/migrations"
        archive_dir = ROOT / "supabase/migrations_archive"
        expected = [
            "00_extensions.sql", "01_types_and_identity.sql", "02_core_schema.sql",
            "03_study_state_and_gamification.sql", "04_functions_triggers_rls.sql",
            "05_workers_storage_realtime.sql", "06_harden_public_materializer.sql",
            "07_import_media_bucket.sql", "08_sync_worker_and_contract_hardening.sql",
            "20261003220359_sdd_feature_exposure.sql",
            "20261003220443_leaderboard_rpc_and_indexes.sql",
            "20261004023000_ai_ingestion_worker_cron.sql",
            "20261004120000_sdd_activation_expansion.sql",
            "20261004130000_sdd_mission_hardening.sql", "20261005000000_sdd_core_hardening.sql",
            "20261005010000_sdd_user_provisioning.sql",
            "20261006140000_f18_f19_f20_f46_occlusion_media.sql",
            '20261006221500_fix_anki_path_regex_and_review_replay.sql',
            '20261006230000_anki_f14_card_ordinals.sql',
            '20261007000000_f27_f42_learning_goals.sql',
            '20261007002000_f25_collaboration_invites.sql',
            '20261007010000_f48_core_confirmation.sql',
            '20261007011000_f15_job_states.sql',
            '20261007012000_f15_f16_job_lifecycle.sql',
            '20261007013000_f39_xp_confirmed_runtime.sql',
            '20261007014000_f38_legacy_unreviewed_states.sql',
            '20261007030000_f20_storage_preflight_limits.sql',
            '20261007031000_f19_occlusion_rpc_resolution.sql',
        ]
        self.assertEqual(sorted(path.name for path in snapshot_dir.glob("*.sql")), expected)
        self.assertGreaterEqual(len(list(archive_dir.glob("*.sql"))), 26)
        extensions = (snapshot_dir / expected[0]).read_text(encoding="utf-8")
        for extension in ('"uuid-ossp"', '"pgcrypto"', '"vector"', '"pg_net"', '"pg_cron"'):
            self.assertIn(f"create extension if not exists {extension} with schema extensions", extensions)
        combined = "\n".join((snapshot_dir / name).read_text(encoding="utf-8").lower() for name in expected)
        for fragment in ("create table if not exists public.notes", "create table if not exists public.cards", "enable row level security", "search_path"):
            self.assertIn(fragment, combined)

    def test_storage_limits_preserve_owner_isolation(self):
        sql = (ROOT / 'supabase/migrations/20261007030000_f20_storage_preflight_limits.sql').read_text()
        self.assertTrue(parse_sql(sql))
        self.assertIn('public=false', sql)
        self.assertIn('file_size_limit=26214400', sql)
        self.assertIn('allowed_mime_types=array[', sql)
        self.assertIn('for insert to authenticated', sql)
        self.assertIn('for update to authenticated', sql)
        self.assertEqual(sql.count('(storage.foldername(name))[1]=(select auth.uid())::text'), 3)
        self.assertNotIn('with check (true)', sql)

    def test_sdd_activation_expansion_contracts(self):
        migration = (ROOT / "supabase/migrations/20261004120000_sdd_activation_expansion.sql").read_text(encoding="utf-8").lower()
        for fragment in (
            "type_answer_validation", "image_occlusion", "share_slug", "card_translations",
            "game_sessions", "webhook_subscriptions", "api_keys", "hmac-sha256",
            "enable row level security", "profiles_theme_check",
        ):
            with self.subTest(fragment=fragment): self.assertIn(fragment, migration)
        tts = (ROOT / "supabase/functions/tts/index.ts").read_text(encoding="utf-8")
        for fragment in ("createUserClient", "X-Cache", "waitUntil", "ELEVENLABS_API_KEY", "PROVIDER_UNAVAILABLE"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, tts)
        crypto = (ROOT / "supabase/functions/_shared/crypto.ts").read_text(encoding="utf-8")
        for fragment in ("signWebhookPayload", "HMAC", "SHA-256", "crypto.subtle.sign"):
                with self.subTest(fragment=fragment): self.assertIn(fragment, crypto)

    def test_sdd_mission_hardening_contracts(self):
        migration = (ROOT / "supabase/migrations/20261004130000_sdd_mission_hardening.sql").read_text(encoding="utf-8").lower()
        for fragment in (
            "activation_status", "activation_flows", "activation_idempotency",
            "process_activation", "idempotency_key_reused", "idempotency_in_progress",
            "user_entitlements", "user_quotas", "consume_user_rate_limit",
            "enable row level security", "revoke execute",
        ):
            with self.subTest(fragment=fragment): self.assertIn(fragment, migration)
        function = (ROOT / "supabase/functions/activation/index.ts").read_text(encoding="utf-8")
        for fragment in ("idempotency-key", "sha256Hex", "BOPLA_REJECTED", "process_activation", "requireUserId"):
            with self.subTest(fragment=fragment): self.assertIn(fragment, function)

    def test_ai_ingestion_scheduler_is_opt_in_and_uses_vault_secrets(self):
        migration = (ROOT / "0027_ai_ingestion_worker_cron.sql").read_text(encoding="utf-8").lower()
        for fragment in (
            "configure_ai_ingestion_cron", "flashi_service_role_jwt",
            "flashi_ingestion_worker_secret", "x-worker-secret",
            "cron.schedule", "cron.unschedule", "from public, anon, authenticated",
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, migration)
        self.assertIn("p_cron text default '*/1 * * * *'", migration)
        self.assertIn("p_cron not in", migration)

    def test_edge_functions_use_user_scoped_and_bounded_contracts(self):
        sync = (ROOT / "supabase/functions/sync/index.ts").read_text(encoding="utf-8")
        fsrs = (ROOT / "supabase/functions/fsrs-review/index.ts").read_text(encoding="utf-8")
        embeddings = (ROOT / "supabase/functions/embeddings/index.ts").read_text(encoding="utf-8")
        semantic = (ROOT / "supabase/functions/semantic-search/index.ts").read_text(encoding="utf-8")
        optimizer = (ROOT / "supabase/functions/fsrs-optimize/index.ts").read_text(encoding="utf-8")
        optimizer_worker = (ROOT / "supabase/functions/fsrs-optimize-worker/index.ts").read_text(encoding="utf-8")
        anki = (ROOT / "supabase/functions/anki-transfer/index.ts").read_text(encoding="utf-8")
        deno = (ROOT / "supabase/functions/deno.json").read_text(encoding="utf-8")
        shared_embeddings = (ROOT / "supabase/functions/_shared/embeddings.ts").read_text(encoding="utf-8")

        self.assertIn('rpc("get_incremental_sync"', sync)
        self.assertIn("next_usn", sync)
        self.assertIn("has_more", sync)
        self.assertIn('rpc(\n      "record_review_fsrs6_idempotent"', fsrs)
        self.assertIn("client_review_id", fsrs)
        self.assertIn("fsrs(parameters)", fsrs)
        self.assertIn("export const DIMENSIONS = 1536", shared_embeddings)
        self.assertIn("sha256Hex(text)", embeddings)
        self.assertIn("embedding.length !== DIMENSIONS", shared_embeddings)
        self.assertIn('rpc("mcp_search_notes"', semantic)
        self.assertIn("OPENAI_API_KEY", shared_embeddings)
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

    def test_sdd_activation_observability_contracts(self):
        migration = (ROOT / "supabase/migrations/20261005000000_sdd_core_hardening.sql").read_text(encoding="utf-8")
        observability = (ROOT / "supabase/functions/_shared/observability.ts").read_text(encoding="utf-8")
        activation = (ROOT / "supabase/functions/activation/index.ts").read_text(encoding="utf-8")
        for fragment in ("learning_plans", "process_activation(text, text, text, text, date, integer)"): self.assertIn(fragment, migration)
        for fragment in ("capturePostHogEvent", "captureException", "request_id", "sendDefaultPii: false"): self.assertIn(fragment, observability + activation)


if __name__ == "__main__":
    unittest.main()
