"""Static validation for the six-file schema snapshot.

A live schema diff still requires a PostgreSQL/Supabase project; this validator
covers the repository-side invariants that can run in CI without credentials.
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
]


def main() -> None:
    actual = sorted(p.name for p in MIGRATIONS.glob("*.sql"))
    if actual != EXPECTED:
        raise SystemExit(f"snapshot files mismatch: {actual}")
    archived = sorted(p.name for p in ARCHIVE.glob("*.sql"))
    if len(archived) < 26:
        raise SystemExit(f"expected at least 26 archived migrations, found {len(archived)}")
    extension_sql = (MIGRATIONS / EXPECTED[0]).read_text()
    for extension in ('"uuid-ossp"', '"pgcrypto"', '"vector"', '"pg_net"', '"pg_cron"'):
        if f"create extension if not exists {extension} with schema extensions" not in extension_sql:
            raise SystemExit(f"missing centralized extension: {extension}")
    for path in (MIGRATIONS / name for name in EXPECTED):
        statements = parse_sql(path.read_text())
        if not statements:
            raise SystemExit(f"empty snapshot: {path.name}")
    combined = "\n".join((MIGRATIONS / name).read_text().lower() for name in EXPECTED)
    required = ("create table if not exists public.notes", "create table if not exists public.cards", "note_id", "enable row level security", "search_path")
    for fragment in required:
        if fragment not in combined:
            raise SystemExit(f"missing snapshot contract: {fragment}")
    # Every snapshot is rerunnable by contract; reject bare CREATE TABLE/EXTENSION.
    if re.search(r"create\s+(table|extension)\s+(?!if\s+not\s+exists)", combined):
        raise SystemExit("found non-idempotent CREATE TABLE/EXTENSION")
    print(f"OK snapshot: {len(EXPECTED)} files, {len(archived)} archived migrations")


if __name__ == "__main__":
    main()
