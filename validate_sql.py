from pathlib import Path
from pglast import parse_sql

files = sorted(Path(__file__).parent.glob("00*.sql"))
errors = []
for path in files:
    sql = path.read_text(encoding="utf-8")
    try:
        statements = parse_sql(sql)
        print(f"OK {path.name}: {len(statements)} statements")
    except Exception as exc:
        errors.append((path.name, str(exc)))
        print(f"ERROR {path.name}: {exc}")

if errors:
    raise SystemExit(1)
