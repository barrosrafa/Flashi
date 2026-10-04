"""Static validation for the versioned schema snapshot.

A live schema diff still requires a PostgreSQL/Supabase project; this validator
covers repository-side invariants that can run in CI without credentials.
"""
from pathlib import Path
import re
from pglast import parse_sql

ROOT = Path(__file__).resolve().parent
MIGRATIONS = ROOT / "supabase" / "migrations"
ARCHIVE = ROOT / "supabase" / "migrations_archive"
EXPECTED = [
    "00_extensions.sql",
    "01_types_and_identity.sql",
    "02_core_schema.sql",
    "03_study_state_and_gamification.sql",
    "04_functions_triggers_rls.sql",
    "05_workers_storage_realtime.sql",
    "06_harden_public_materializer.sql",
    "07_import_media_bucket.sql",
    "08_sync_worker_and_contract_hardening.sql",
    "20261003220359_sdd_feature_exposure.sql",
    "20261003220443_leaderboard_rpc_and_indexes.sql",
    "20261004023000_ai_ingestion_worker_cron.sql",
    "20261004120000_sdd_activation_expansion.sql",
    "20261004130000_sdd_mission_hardening.sql",
    "20261005000000_sdd_core_hardening.sql",
    "20261005010000_sdd_user_provisioning.sql",
]


def main() -> None:
    actual = sorted(path.name for path in MIGRATIONS.glob("*.sql"))
    if actual != EXPECTED:
        raise SystemExit(f"snapshot files mismatch: {actual}")
    archived = sorted(path.name for path in ARCHIVE.glob("*.sql"))
    if len(archived) < 26:
        raise SystemExit(f"expected at least 26 archived migrations, found {len(archived)}")
    extension_sql = (MIGRATIONS / EXPECTED[0]).read_text(encoding="utf-8")
    for extension in ('"uuid-ossp"', '"pgcrypto"', '"vector"', '"pg_net"', '"pg_cron"'):
        if f"create extension if not exists {extension} with schema extensions" not in extension_sql:
            raise SystemExit(f"missing centralized extension: {extension}")
    for name in EXPECTED:
        if not parse_sql((MIGRATIONS / name).read_text(encoding="utf-8")):
            raise SystemExit(f"empty snapshot: {name}")
    combined = "\n".join((MIGRATIONS / name).read_text(encoding="utf-8").lower() for name in EXPECTED)
    required = (
        "create table if not exists public.notes",
        "create table if not exists public.cards",
        "note_id",
        "enable row level security",
        "search_path",
        "configure_ai_ingestion_cron",
        "flashi_ingestion_worker_secret",
    )
    for fragment in required:
        if fragment not in combined:
            raise SystemExit(f"missing snapshot contract: {fragment}")
    # Every snapshot is rerunnable by contract; reject bare CREATE TABLE/EXTENSION.
    if re.search(r"create\s+(table|extension)\s+(?!if\s+not\s+exists)", combined):
        raise SystemExit("found non-idempotent CREATE TABLE/EXTENSION")
    print(f"OK snapshot: {len(EXPECTED)} files, {len(archived)} archived migrations")


if __name__ == "__main__":
    main()
