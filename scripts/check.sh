#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[check] bash syntax"
bash -n install_wsl.sh

echo "[check] claude-install.ps1 exists and has required functions"
python3 - <<'PY'
from pathlib import Path

claude_install = Path("lib/claude-install.ps1").read_text(encoding="utf-8")
required_functions_ps = [
    "Test-ClaudeCommandExisting",
    "Test-HttpEndpointReachable",
    "Test-ClaudeOfficialInstallNetwork",
    "Test-NpmMirrorClaudeCodeNetwork",
    "Install-ClaudeCodeNative",
    "Install-ClaudeCodeNpmMirror",
    "Install-ClaudeCodeAuto",
    "Invoke-ClaudeDoctorSafe",
]
for fn in required_functions_ps:
    if ("function " + fn) not in claude_install:
        raise SystemExit(f"claude-install.ps1 missing function: {fn}")

# Check status values used
statuses = [
    "official_native",
    "npm_npmmirror",
    "existing",
    "failed_official_and_mirror",
    "failed_missing_node_or_npm",
    "failed_npmmirror_unreachable",
    "skipped_existing",
]
for s in statuses:
    if s not in claude_install:
        raise SystemExit(f"claude-install.ps1 missing status value: {s}")
PY

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
import unicodedata

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

logger = Path("lib/logger.ps1").read_text(encoding="utf-8")
bad_logger = ["✅", "⚠", "❌", "⏭", "\ufe0f"]
found_logger = [ch for ch in bad_logger if ch in logger]
if found_logger:
    raise SystemExit(f"logger.ps1 contains non-ASCII status icons: {found_logger}")

release_docs = [
    Path("README.md"),
    Path("QUICK_START.md"),
    Path("docs/用户使用教程.md"),
    Path("docs/常见问题FAQ.md"),
    Path("docs/闲鱼商品说明.md"),
    Path("docs/测试清单.md"),
    Path("docs/视频教程脚本.md"),
    Path("examples/report.example.txt"),
]
for path in release_docs:
    content = path.read_text(encoding="utf-8")
    risky = []
    for ch in content:
        code = ord(ch)
        if ch == "\ufe0f" or 0x2500 <= code <= 0x257F or unicodedata.category(ch) == "So":
            risky.append(ch)
    if risky:
        sample = " ".join(risky[:5])
        raise SystemExit(f"{path} contains terminal-risk characters: {sample}")
PY

echo "[check] install_wsl.sh new functions exist"
python3 - <<'PY'
from pathlib import Path

install_wsl = Path("install_wsl.sh").read_text(encoding="utf-8")
required_functions = [
    "command_exists",
    "check_url_reachable",
    "check_official_claude_network",
    "check_npmmirror_network",
    "install_claude_official",
    "install_claude_npmmirror",
    "install_claude_auto",
]
for fn in required_functions:
    if fn not in install_wsl:
        raise SystemExit(f"install_wsl.sh missing function: {fn}")

# Verify install_claude_code calls install_claude_auto
if "install_claude_auto" not in install_wsl:
    raise SystemExit("install_wsl.sh: install_claude_auto not found")
if "install_claude_code()" not in install_wsl:
    raise SystemExit("install_wsl.sh: install_claude_code function missing")

# Check state variables
for var in ["CLAUDE_INSTALL_METHOD", "CLAUDE_WAS_ALREADY_INSTALLED", "CLAUDE_INSTALL_STATUS"]:
    if var not in install_wsl:
        raise SystemExit(f"install_wsl.sh missing state variable: {var}")

# Check npmmirror registry URL
if "registry.npmmirror.com" not in install_wsl:
    raise SystemExit("install_wsl.sh missing npmmirror registry URL")

# Check official install.sh URL
if "claude.ai/install.sh" not in install_wsl:
    raise SystemExit("install_wsl.sh missing official install.sh URL")
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

install_wsl = Path("install_wsl.sh").read_text(encoding="utf-8")
bad_wsl_chars = ["✅", "⚠", "❌", "⏭", "╔", "╚", "║", "═", "━", "┌", "│"]
found_wsl = [ch for ch in bad_wsl_chars if ch in install_wsl]
if found_wsl:
    raise SystemExit(f"install_wsl.sh contains terminal-risk characters: {found_wsl}")

for marker in ("[INFO]", "[OK]", "[WARN]", "[ERROR]"):
    if marker not in install_wsl:
        raise SystemExit(f"install_wsl.sh missing ASCII marker {marker}")

doctor = Path("doctor.ps1").read_text(encoding="utf-8")
if "$script:DoctorState" not in doctor or "$Suggestions +=" in doctor:
    raise SystemExit("doctor state management is not centralized")
PY

echo "[check] OK"
