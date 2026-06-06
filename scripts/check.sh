#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[check] bash syntax"
bash -n install_wsl.sh

echo "[check] JSON templates"
python3 -m json.tool lib/deepseek-env.defaults.json >/dev/null
python3 -m json.tool examples/settings.deepseek.example.json >/dev/null

echo "[check] shared DeepSeek defaults"
python3 - <<'PY'
import json
from pathlib import Path

defaults = json.loads(Path("lib/deepseek-env.defaults.json").read_text(encoding="utf-8"))
example = json.loads(Path("examples/settings.deepseek.example.json").read_text(encoding="utf-8"))["env"]

required = {
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL",
}
missing = sorted(required - defaults.keys())
if missing:
    raise SystemExit(f"missing defaults: {missing}")

for key, value in defaults.items():
    if key == "ANTHROPIC_AUTH_TOKEN":
        continue
    if example.get(key) != value:
        raise SystemExit(f"example mismatch for {key}: {example.get(key)!r} != {value!r}")
PY

echo "[check] report example uses ASCII status markers"
python3 - <<'PY'
from pathlib import Path

text = Path("examples/report.example.txt").read_text(encoding="utf-8")
bad = ["✅", "⚠", "❌", "⏭"]
found = [ch for ch in bad if ch in text]
if found:
    raise SystemExit(f"report example contains non-ASCII status icons: {found}")

for marker in ("[OK]", "[WARN]", "[ERROR]", "[SKIP]"):
    if marker in text:
        break
else:
    raise SystemExit("report example does not contain ASCII status markers")
PY

echo "[check] sensitive-output guardrails"
python3 - <<'PY'
from pathlib import Path

for path in [Path("doctor.ps1"), Path("install_wsl.sh")]:
    text = path.read_text(encoding="utf-8")
    if "cat ~/.claude/settings.json" in text:
        raise SystemExit(f"{path} reads full WSL settings.json")
    if "sudo npm install -g @anthropic-ai/claude-code" in text:
        raise SystemExit(f"{path} suggests sudo npm install")

doctor = Path("doctor.ps1").read_text(encoding="utf-8")
if "$script:DoctorState" not in doctor or "$Suggestions +=" in doctor:
    raise SystemExit("doctor state management is not centralized")
PY

echo "[check] OK"
