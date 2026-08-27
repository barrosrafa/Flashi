from pathlib import Path
import re
import markdown

root = Path(__file__).parent
readme = (root / "README.md").read_text(encoding="utf-8")

fences = re.findall(r"^```", readme, flags=re.MULTILINE)
if len(fences) % 2:
    raise SystemExit("README has an unbalanced code fence")

required = [f"{n:04d}_" for n in range(1, 24)]
missing = [prefix for prefix in required if prefix not in readme]
if missing:
    raise SystemExit(f"README is missing migration references: {missing}")

for pattern in (
    r"ghp_[A-Za-z0-9]{20,}",
    r"github_pat_[A-Za-z0-9_]{20,}",
    r"(?i)(?:OPENAI_API_KEY|SUPABASE_SERVICE_ROLE_KEY)\s*=\s*[\"'](?!<)[^\"']{20,}[\"']",
):
    if re.search(pattern, readme):
        raise SystemExit(f"README contains a credential-like value matching: {pattern}")

if "https://docs.ankiweb.net/importing.html" in readme:
    raise SystemExit("README contains the obsolete Anki import URL")

html = markdown.markdown(readme, extensions=["tables", "fenced_code"])
if not html or "<h1" not in html:
    raise SystemExit("README did not render as Markdown")

references = re.findall(r"^\[(\d+)\]:\s+\S+", readme, flags=re.MULTILINE)
used = set(re.findall(r"\[(\d+)\]", readme))
if not used.issubset(set(references)):
    raise SystemExit(f"README has undefined references: {sorted(used - set(references))}")

print(f"README OK: {len(readme.splitlines())} lines, {len(html)} rendered chars, {len(references)} references")
