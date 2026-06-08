#!/bin/bash
# ============================================================
# install_wsl.sh - WSL Ubuntu 内 Claude Code 安装配置脚本
# 版本: 1.3.2
#
# 用法:
#   chmod +x install_wsl.sh
#   ./install_wsl.sh
#
# 功能:
#   在 WSL Ubuntu 内安装 Claude Code 并配置 DeepSeek API
#
# 合规声明:
#   本脚本仅做本地安装和配置。
#   不提供 Claude 账号、API Key、中转服务。
#   用户需自备 DeepSeek API Key。
# ============================================================

# 注意：不使用 set -e，所有错误由显式 return 码处理
# 避免 check_environment 等检测函数的 return 1 导致脚本直接退出
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
BACKUP_DIR="$SCRIPT_DIR/backup"
DEFAULTS_FILE="$SCRIPT_DIR/lib/deepseek-env.defaults.json"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/install_wsl-${TIMESTAMP}.log"
SCRIPT_VERSION="1.3.2"
MODE="menu"
YES=0
NON_INTERACTIVE=0
SKIP_API_TEST=0
INSTALL_DEPS=0
SHARE_SAFE=0

# 损坏 JSON 恢复标记
CONFIG_JSON_DAMAGED=0
CONFIG_REBUILT_FROM_DAMAGED=0

# 状态变量（用于最终摘要）
CLAUDE_OK=0
CONFIG_OK=0
API_TEST_PASSED=0
API_TEST_SKIPPED=0
API_TEST_FAILED=0
API_TEST_FAIL_REASON=""

# Claude Code 安装状态变量
CLAUDE_INSTALL_METHOD=""
CLAUDE_WAS_ALREADY_INSTALLED=0
CLAUDE_INSTALL_STATUS=""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================================
# 工具函数
# ============================================================

init_logging() {
    mkdir -p "$LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] ========== WSL 安装日志开始 ==========" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 日志文件: $LOG_FILE" >> "$LOG_FILE"
}

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
    log "INFO" "$*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "INFO" "[OK] $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN" "$*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
    log "ERROR" "$*"
}

step() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}============================================================${NC}"
    log "INFO" "--- 步骤: $* ---"
}

usage() {
    cat <<EOF
用法:
  ./install_wsl.sh [--mode all|install|configure|doctor|uninstall|restore|test-key] [--yes] [--non-interactive] [--skip-api-test] [--install-deps] [--share-safe]

选项:
  --mode all              安装 Claude Code 并配置 DeepSeek
  --mode install          仅安装 Claude Code
  --mode configure        仅配置 DeepSeek
  --mode doctor           仅运行诊断（不修改系统）
  --mode uninstall        移除 DeepSeek 配置（保留 Claude Code 和其他设置）
  --mode restore          从最近备份恢复配置
  --mode test-key         仅测试 DeepSeek API Key 是否可用（不写配置）
  --yes                   跳过免责声明确认
  --non-interactive       非交互模式，只从 CCDI_API_KEY 或 DEEPSEEK_API_KEY 读取 Key
  --skip-api-test         跳过 DeepSeek API 在线测试
  --install-deps          允许在非交互模式下自动安装系统依赖（Node.js 等）
  --share-safe            诊断报告脱敏处理（替换用户名/路径）
  -h, --help              显示帮助
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                if [ $# -lt 2 ]; then
                    error "--mode 需要值: all|install|configure|doctor|uninstall|restore|test-key"
                    exit 1
                fi
                MODE="$2"
                case "$MODE" in
                    all|install|configure|doctor|uninstall|restore|test-key) ;;
                    *)
                        error "无效 --mode: $MODE"
                        info "支持: all | install | configure | doctor | uninstall | restore | test-key"
                        info "如需卸载配置，也可在 Windows 端运行: uninstall-config.ps1"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --yes)
                YES=1
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                YES=1
                shift
                ;;
            --skip-api-test)
                SKIP_API_TEST=1
                shift
                ;;
            --install-deps)
                INSTALL_DEPS=1
                shift
                ;;
            --share-safe)
                SHARE_SAFE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done
}

mask_api_key() {
    local key="$1"
    local len=${#key}
    if [ "$len" -eq 0 ]; then
        printf '(空)'
    elif [ "$len" -le 8 ]; then
        printf '%s****' "${key:0:2}"
    else
        printf '%s****%s' "${key:0:4}" "${key: -4}"
    fi
}

# ============================================================
# 模式判断辅助函数（用于最终摘要）
# ============================================================

mode_needs_install() {
    [ "$MODE" = "all" ] || [ "$MODE" = "install" ]
}

mode_needs_config() {
    [ "$MODE" = "all" ] || [ "$MODE" = "configure" ]
}

# ============================================================
# 备份与恢复函数
# ============================================================
backup_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log "INFO" "备份: 文件不存在，无需备份: $file"
        return 0
    fi

    mkdir -p "$BACKUP_DIR" || {
        log "ERROR" "无法创建备份目录: $BACKUP_DIR"
        return 1
    }

    local filename
    filename=$(basename "$file")
    local backup_path="$BACKUP_DIR/${filename}.${TIMESTAMP}.bak"
    if cp "$file" "$backup_path"; then
        log "INFO" "已备份: $file -> $backup_path"
        info "已备份: $backup_path"
        return 0
    else
        log "ERROR" "备份失败: $file -> $backup_path"
        return 1
    fi
}

# ============================================================
# JSON 处理（优先使用 Node.js，因为 Claude Code 需要它）
# ============================================================

# 确保有 JSON 处理器可用（node 或 python3）
# 返回 0=可用, 1=不可用
# 注意：绝不会在未授权情况下安装 python3
ensure_json_processor() {
    # 优先使用 node（Claude Code 本身就需要它）
    if command -v node &> /dev/null; then
        return 0
    fi

    # 备选 python3
    if command -v python3 &> /dev/null; then
        return 0
    fi

    # 两者都不可用
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if [ "$INSTALL_DEPS" -eq 1 ]; then
            info "缺少 JSON 处理器，正在安装 python3..."
            log "INFO" "非交互模式 --install-deps: 将安装 python3"
            sudo apt-get update -qq >> "$LOG_FILE" 2>&1
            if sudo apt-get install -y python3 >> "$LOG_FILE" 2>&1; then
                success "python3 安装完成。"
                return 0
            else
                error "python3 安装失败。"
                return 1
            fi
        else
            error "缺少 JSON 处理器（node 或 python3）。"
            info "非交互模式下不会自动安装系统依赖。"
            info "请手动安装: sudo apt-get install python3"
            info "或使用 --install-deps 参数。"
            return 1
        fi
    fi

    # 交互模式：询问用户
    warn "配置需要 node 或 python3 来处理 JSON，但两者都未找到。"
    warn "Node.js 是 Claude Code 的运行时依赖，建议安装 Node.js。"
    read -r -p "是否安装 python3？(需要 sudo) (Y/N): " install_py
    if [ "$install_py" = "Y" ] || [ "$install_py" = "y" ]; then
        log "INFO" "用户授权安装 python3"
        sudo apt-get update -qq >> "$LOG_FILE" 2>&1
        if sudo apt-get install -y python3 >> "$LOG_FILE" 2>&1; then
            success "python3 安装完成。"
            return 0
        else
            error "python3 安装失败。"
            return 1
        fi
    else
        info "已取消。请手动安装 Node.js (推荐) 或 python3 后重试。"
        info "  Node.js: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        info "           sudo apt-get install -y nodejs"
        info "  python3: sudo apt-get install python3"
        return 1
    fi
}

# 用可用的 JSON 处理器合并 settings.json
# 使用环境变量传递参数避免注入
merge_settings_json() {
    local config_file="$1"
    local defaults_file="$2"
    local api_key="$3"

    export CCDI_CONFIG_FILE="$config_file"
    export CCDI_DEFAULTS_FILE="$defaults_file"
    export CCDI_INPUT_API_KEY="$api_key"

    if command -v node &> /dev/null; then
        # 使用 Node.js 处理 JSON
        local _ccdi_node_out
        _ccdi_node_out=$(node -e '
var fs=require("fs"),path=require("path"),os=require("os");
var cf=process.env.CCDI_CONFIG_FILE.replace(/^~/,os.homedir());
var df=process.env.CCDI_DEFAULTS_FILE;
var ak=process.env.CCDI_INPUT_API_KEY;
var ne=JSON.parse(fs.readFileSync(df,"utf-8"));
ne.ANTHROPIC_AUTH_TOKEN=ak;
var ex={},jd=false;
if(fs.existsSync(cf)){try{var ct=fs.readFileSync(cf,"utf-8").trim();if(ct)ex=JSON.parse(ct);}catch(e){jd=true;}}
var oe=ex.env||{};
if(typeof oe!=="object"||Array.isArray(oe))oe={};
Object.assign(oe,ne);ex.env=oe;
var cd=path.dirname(cf);
if(!fs.existsSync(cd))fs.mkdirSync(cd,{recursive:true});
fs.writeFileSync(cf,JSON.stringify(ex,null,2),"utf-8");
if(jd)console.log("CONFIG_OK_DAMAGED_JSON");else console.log("CONFIG_OK");
' 2>/dev/null)
        if echo "$_ccdi_node_out" | grep -q "DAMAGED_JSON"; then
            CONFIG_JSON_DAMAGED=1
            CONFIG_REBUILT_FROM_DAMAGED=1
            return 0
        elif echo "$_ccdi_node_out" | grep -q "CONFIG_OK"; then
            return 0
        fi
        return $?
    elif command -v python3 &> /dev/null; then
        # 回退到 python3
        python3 << 'PYEOF'
import json
import os

config_file = os.path.expanduser(os.environ.get("CCDI_CONFIG_FILE", "~/.claude/settings.json"))
defaults_file = os.environ.get("CCDI_DEFAULTS_FILE", "")
api_key = os.environ.get("CCDI_INPUT_API_KEY", "")

with open(defaults_file, 'r', encoding='utf-8') as f:
    new_env = json.load(f)
new_env["ANTHROPIC_AUTH_TOKEN"] = api_key

existing = {}
json_damaged = False
if os.path.exists(config_file):
    try:
        with open(config_file, 'r') as f:
            content = f.read().strip()
            if content:
                existing = json.loads(content)
    except json.JSONDecodeError:
        json_damaged = True

old_env = existing.get("env", {})
if not isinstance(old_env, dict):
    old_env = {}

old_env.update(new_env)
existing["env"] = old_env

os.makedirs(os.path.dirname(config_file), exist_ok=True)
with open(config_file, 'w') as f:
    json.dump(existing, f, indent=2, ensure_ascii=False)

print("CONFIG_OK")
PYEOF
        local _ccdi_py_out
        _ccdi_py_out=$(python3 -c '
import json,os
cf=os.path.expanduser(os.environ.get("CCDI_CONFIG_FILE","~/.claude/settings.json"))
df=os.environ.get("CCDI_DEFAULTS_FILE","")
ak=os.environ.get("CCDI_INPUT_API_KEY","")
with open(df,"r",encoding="utf-8") as f:ne=json.load(f)
ne["ANTHROPIC_AUTH_TOKEN"]=ak
ex={};jd=False
if os.path.exists(cf):
 try:
  with open(cf,"r") as f:
   ct=f.read().strip()
   if ct:ex=json.loads(ct)
 except json.JSONDecodeError:jd=True
oe=ex.get("env",{})
if not isinstance(oe,dict):oe={}
oe.update(ne);ex["env"]=oe
os.makedirs(os.path.dirname(cf),exist_ok=True)
with open(cf,"w") as f:json.dump(ex,f,indent=2,ensure_ascii=False)
if jd:print("CONFIG_OK_DAMAGED_JSON")
else:print("CONFIG_OK")
' 2>/dev/null)
        if echo "$_ccdi_py_out" | grep -q "DAMAGED_JSON"; then
            CONFIG_JSON_DAMAGED=1
            CONFIG_REBUILT_FROM_DAMAGED=1
            return 0
        elif echo "$_ccdi_py_out" | grep -q "CONFIG_OK"; then
            return 0
        fi
        return $?
    else
        error "没有可用的 JSON 处理器。"
        return 1
    fi
}

# 用可用的 JSON 处理器验证 settings.json
validate_settings_json() {
    local config_file="$1"
    if command -v node &> /dev/null; then
        node -e "JSON.parse(require('fs').readFileSync('$config_file','utf-8')); console.log('VALID');" 2>/dev/null
        return $?
    elif command -v python3 &> /dev/null; then
        python3 -c "import json; json.load(open('$config_file')); print('VALID')" 2>/dev/null
        return $?
    else
        return 1
    fi
}

# 用可用的 JSON 处理器从配置读取值
read_config_value() {
    local config_file="$1"
    local key="$2"
    local default="$3"
    if command -v node &> /dev/null; then
        node -e "
const fs = require('fs');
const os = require('os');
const f = '$config_file'.replace(/^~/, os.homedir());
try {
    const c = JSON.parse(fs.readFileSync(f, 'utf-8'));
    console.log((c.env || {})['$key'] || '$default');
} catch(e) { console.log('$default'); }
" 2>/dev/null
    elif command -v python3 &> /dev/null; then
        python3 -c "
import json, os
try:
    with open(os.path.expanduser('$config_file')) as f:
        c = json.load(f)
    print(c.get('env', {}).get('$key', '$default'))
except:
    print('$default')
" 2>/dev/null
    else
        echo "$default"
    fi
}

parse_api_content() {
    if command -v node &> /dev/null; then
        node << 'NODEEOF'
const fs = require('fs');
try {
  const data = JSON.parse(fs.readFileSync(0, 'utf-8'));
  if (Array.isArray(data.content) && data.content.length > 0) {
    console.log(data.content[0].text || '');
  } else if (data.content) {
    console.log(String(data.content));
  } else if (data.choices && data.choices[0] && data.choices[0].message) {
    console.log(data.choices[0].message.content || '');
  } else {
    console.log('UNKNOWN_FORMAT');
  }
} catch (e) {
  console.log('PARSE_ERROR: ' + e.message);
}
NODEEOF
    elif command -v python3 &> /dev/null; then
        python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'content' in data:
        if isinstance(data['content'], list):
            print(data['content'][0].get('text', ''))
        else:
            print(str(data['content']))
    elif 'choices' in data:
        print(data['choices'][0].get('message', {}).get('content', ''))
    else:
        print('UNKNOWN_FORMAT')
except Exception as e:
    print(f'PARSE_ERROR: {e}')
"
    else
        echo "UNKNOWN_FORMAT"
    fi
}

# ============================================================
# 卸载 DeepSeek 配置（保留 Claude Code 和其他设置）
# ============================================================

uninstall_wsl_config() {
    step "移除 DeepSeek 配置"

    local config_file="$HOME/.claude/settings.json"

    if [ ! -f "$config_file" ]; then
        warn "未找到配置文件: $config_file"
        info "无需卸载。"
        return 0
    fi

    # 卸载前必须备份
    if ! backup_file "$config_file"; then
        error "备份失败，已停止卸载，避免破坏现有配置。"
        error "请检查 backup/ 目录权限或磁盘空间。"
        return 1
    fi

    local backup_ok=1

    if command -v node &> /dev/null; then
        node -e "
const fs = require('fs');
const path = '${config_file}';
let config = {};
try {
    config = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch(e) {
    console.error('CONFIG_PARSE_ERROR');
    process.exit(2);
}
if (!config.env || typeof config.env !== 'object' || Array.isArray(config.env)) {
    config.env = {};
}
const keys = [
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL',
    'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_EFFORT_LEVEL',
    'API_TIMEOUT_MS', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
    'DISABLE_TELEMETRY', 'DISABLE_ERROR_REPORTING', 'DISABLE_AUTOUPDATER'
];
for (const k of keys) delete config.env[k];
fs.writeFileSync(path, JSON.stringify(config, null, 2) + '\n', 'utf8');
console.log('UNINSTALL_OK');
" 2>/dev/null
        local rc=$?
        if [ $rc -eq 0 ]; then
            backup_ok=1
        elif [ $rc -eq 2 ]; then
            error "配置文件 JSON 损坏，已备份但无法安全移除 DeepSeek 字段。"
            error "请从备份文件手动恢复，或在 Windows 端运行 uninstall-config.ps1。"
            return 1
        else
            error "配置移除失败。"
            return 1
        fi
    elif command -v python3 &> /dev/null; then
        python3 -c "
import json, os
config_file = os.path.expanduser('${config_file}')
try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except json.JSONDecodeError:
    print('CONFIG_PARSE_ERROR')
    exit(2)
env = config.get('env', {})
if not isinstance(env, dict):
    env = {}
keys = [
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL',
    'ANTHROPIC_SMALL_FAST_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDE_CODE_EFFORT_LEVEL',
    'API_TIMEOUT_MS', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
    'DISABLE_TELEMETRY', 'DISABLE_ERROR_REPORTING', 'DISABLE_AUTOUPDATER'
]
for k in keys:
    env.pop(k, None)
config['env'] = env
with open(config_file, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print('UNINSTALL_OK')
" 2>/dev/null
        local rc=$?
        if [ $rc -eq 0 ]; then
            backup_ok=1
        elif [ $rc -eq 2 ]; then
            error "配置文件 JSON 损坏，已备份但无法安全移除 DeepSeek 字段。"
            error "请从备份文件手动恢复，或在 Windows 端运行 uninstall-config.ps1。"
            return 1
        else
            error "配置移除失败。"
            return 1
        fi
    else
        error "未找到 node 或 python3，无法安全修改 JSON。"
        return 1
    fi

    success "DeepSeek 配置已移除。Claude Code 和其他设置已保留。"
    info "备份文件可在 backup/ 目录找到。"
    return 0
}

# ============================================================
# 从最近备份恢复配置
# ============================================================

restore_wsl_config() {
    step "从备份恢复配置"

    local config_file="$HOME/.claude/settings.json"

    # 列出现有备份
    local backups
    backups=$(ls -1t "$BACKUP_DIR"/settings.json.*.bak 2>/dev/null || true)

    if [ -z "$backups" ]; then
        warn "未在 backup/ 目录找到 settings.json 备份文件。"
        info "请确认之前运行过配置写入（会自动备份）。"
        return 1
    fi

    local latest
    latest=$(echo "$backups" | head -1)
    local count
    count=$(echo "$backups" | wc -l)

    if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$YES" -eq 1 ]; then
        info "非交互模式：自动选择最近备份。"
        info "备份文件: $latest"
        info "备份时间: $(stat -c %y "$latest" 2>/dev/null || echo '未知')"
    else
        info "找到 $count 个备份文件："
        local i=1
        local IFS_OLD="$IFS"
        IFS=$'\n'
        for b in $backups; do
            local bt
            bt=$(stat -c %y "$b" 2>/dev/null || echo '未知时间')
            echo "  [$i] $b ($bt)"
            i=$((i+1))
        done
        IFS="$IFS_OLD"
        echo ""
        read -r -p "选择要恢复的备份编号 (1-$count，默认最近): " choice
        if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null; then
            latest=$(echo "$backups" | sed -n "${choice}p")
        fi
    fi

    # 恢复前备份当前配置
    if [ -f "$config_file" ]; then
        info "正在备份当前配置..."
        backup_file "$config_file" || {
            error "当前配置备份失败，已停止恢复。"
            return 1
        }
    fi

    # 执行恢复
    cp "$latest" "$config_file" || {
        error "恢复失败：无法写入 $config_file"
        return 1
    }

    success "配置已从备份恢复: $latest"

    # 验证
    if validate_settings_json "$config_file"; then
        success "恢复的配置文件 JSON 格式验证通过。"
    else
        warn "恢复的配置文件 JSON 格式可能无效，请检查。"
    fi

    return 0
}

# ============================================================
# 仅测试 API Key 是否可用（不写配置）
# ============================================================

test_key_only() {
    step "测试 DeepSeek API Key"

    local api_key

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if [ -n "${CCDI_API_KEY:-}" ]; then
            api_key="$CCDI_API_KEY"
        elif [ -n "${DEEPSEEK_API_KEY:-}" ]; then
            api_key="$DEEPSEEK_API_KEY"
        else
            error "未检测到环境变量 CCDI_API_KEY 或 DEEPSEEK_API_KEY。"
            info "用法: CCDI_API_KEY=sk-xxxx ./install_wsl.sh --mode test-key"
            return 1
        fi
        info "已从环境变量读取 API Key: $(mask_api_key "$api_key")"
    else
        echo ""
        info "此模式仅测试 Key 是否可用，不会修改任何配置文件。"
        read -r -s -p "请粘贴 DeepSeek API Key: " api_key
        echo ""
    fi

    if [ -z "$api_key" ]; then
        error "API Key 不能为空！"
        return 1
    fi

    info "API Key: $(mask_api_key "$api_key")"
    info "正在使用 fast 模型测试 API 连通性，以降低成本。"
    info "这不代表主模型不可用；主模型将在 Claude Code 实际使用时调用。"
    info "正在测试 Anthropic Format 接口..."

    local test_model="deepseek-v4-flash"
    local messages_endpoint="https://api.deepseek.com/anthropic/messages"
    local request_body="{\"model\":\"$test_model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK only.\"}]}"

    local hf
    hf=$(mktemp)
    printf 'x-api-key: %s\n' "$api_key" > "$hf"
    printf 'Authorization: Bearer %s\n' "$api_key" >> "$hf"
    printf 'Content-Type: application/json\n' >> "$hf"
    printf 'anthropic-version: 2023-06-01\n' >> "$hf"

    local response http_code curl_exit
    _ccdi_errexit_saved=0
    case $- in *e*) _ccdi_errexit_saved=1 ;; esac
    set +e
    response=$(curl -s -w "\n%{http_code}" -H @"$hf" --connect-timeout 15 --max-time 30 -X POST -d "$request_body" "$messages_endpoint" 2>&1)
    curl_exit=$?
    if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi
    rm -f "$hf"

    http_code=$(echo "$response" | tail -1)

    case $http_code in
        200)
            success "API Key 可用！测试通过 (HTTP 200)"
            info "注意: 测试使用 fast 模型 ($test_model)，以节省成本。"
            info "这不代表主模型不可用；主模型将在 Claude Code 实际使用时调用。"
            return 0
            ;;
        401)
            error "API Key 验证失败 (401 Unauthorized)"
            info "请检查 Key 是否正确，到 platform.deepseek.com 重新获取。"
            return 1
            ;;
        402)
            error "账户余额不足或计费异常 (402 Payment Required)"
            info "请到 platform.deepseek.com 检查余额。"
            return 1
            ;;
        403)
            error "API Key 无权限 (403 Forbidden)"
            return 1
            ;;
        404)
            error "接口或模型未找到 (404 Not Found)"
            info "模型名可能已变更，请检查 DeepSeek 官方文档。"
            return 1
            ;;
        429)
            error "请求频率限制 (429 Too Many Requests)"
            info "请稍等几分钟再试。"
            return 1
            ;;
        5*)
            error "DeepSeek 服务端错误 (HTTP $http_code)"
            info "官方服务暂时异常，请稍后重试。"
            return 1
            ;;
        *)
            if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$curl_exit" -ne 0 ]; then
                error "网络连接失败"
                info "请检查网络、DNS、代理设置。"
            else
                error "未知错误 (HTTP $http_code)"
            fi
            return 1
            ;;
    esac
}

# ============================================================
# 免责声明
# ============================================================

show_disclaimer() {
    if [ "$YES" -eq 1 ]; then
        log "INFO" "已按参数跳过免责声明确认"
        return 0
    fi

    clear
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  Claude Code + DeepSeek WSL 安装脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}【重要说明】${NC}"
    echo ""
    echo "  本脚本是一个本地安装配置助手，仅帮助您在 WSL Ubuntu 中:"
    echo "    1. 安装 Claude Code CLI 工具"
    echo "    2. 配置 DeepSeek API 连接"
    echo "    3. 诊断环境问题"
    echo ""
    echo "  本脚本不提供以下内容:"
    echo "    - 不出售 Claude 账号"
    echo "    - 不出售 API Key"
    echo "    - 不做 API 中转/代理服务"
    echo "    - 不做任何破解或绕过限制"
    echo ""
    echo "  您需要自行准备:"
    echo "    - DeepSeek API Key (在 platform.deepseek.com 获取)"
    echo "    - API 调用费用由您自己承担"
    echo ""
    echo "  本脚本不会将您的 API Key 发送给第三方或服务提供者。"
    echo "  如选择 API 测试，Key 会发送到 DeepSeek 官方接口验证。"
    echo "  所有配置仅保存在您的本机。"
    echo ""

    read -r -p "请输入 Y 确认您已阅读并同意以上声明 (输入 N 退出): " agree
    if [ "$agree" != "Y" ] && [ "$agree" != "y" ] && [ "$agree" != "是" ]; then
        echo "已取消安装。"
        log "INFO" "用户拒绝免责声明，脚本退出"
        exit 0
    fi

    log "INFO" "用户已同意免责声明"
}

# ============================================================
# 环境检测（纯检测，不修改系统）
# 返回 0=全部通过, 1=有问题但不致命
# ============================================================

check_environment() {
    step "环境检测（仅检测，不修改系统）"

    local issues=0

    # Linux 发行版
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "Linux 发行版: $NAME $VERSION"
        log "INFO" "Linux 发行版: $NAME $VERSION"
    else
        warn "无法检测 Linux 发行版"
    fi

    # bash
    if command -v bash &> /dev/null; then
        success "bash: $(bash --version | head -1)"
    else
        error "bash 未找到！（这不应该发生）"
    fi

    # curl
    if command -v curl &> /dev/null; then
        success "curl: $(curl --version | head -1)"
    else
        error "curl 未安装！"
        info "请运行: sudo apt-get update && sudo apt-get install -y curl"
        issues=$((issues + 1))
    fi

    # git
    if command -v git &> /dev/null; then
        success "git: $(git --version)"
    else
        warn "git 未安装（推荐但非必须）"
        info "可通过以下命令安装: sudo apt-get install -y git"
    fi

    # node / npm（仅检测，不安装）
    # 先检测 nvm
    local using_nvm=0
    if command -v nvm &> /dev/null || [ -s "$HOME/.nvm/nvm.sh" ]; then
        using_nvm=1
    fi

    local node_ok=1
    if command -v node &> /dev/null; then
        local node_ver
        node_ver=$(node --version)
        local node_major
        node_major=$(echo "$node_ver" | sed 's/v//' | cut -d. -f1)

        if [ "$node_major" -lt 18 ] 2>/dev/null; then
            warn "Node.js 版本过旧 ($node_ver)，Claude Code 需要 Node.js >= 18"
            info "当前版本: $node_ver，需要: v18 或更高版本"
            if [ "$using_nvm" -eq 1 ]; then
                info "检测到 nvm，建议使用: nvm install --lts && nvm use --lts"
            else
                info "建议升级 Node.js 后重新运行本脚本。"
            fi
            node_ok=0
            issues=$((issues + 1))
        else
            success "Node.js: $node_ver"
        fi
    else
        error "Node.js 未安装！Claude Code 需要 Node.js 18 或更高版本。"
        info "请先安装 Node.js LTS 后重新运行本脚本。"
        if [ "$using_nvm" -eq 1 ]; then
            info "检测到 nvm，建议使用: nvm install --lts && nvm use --lts"
        else
            info "安装方法:"
        info "  方法1: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        info "          sudo apt-get install -y nodejs"
        info "  方法2: 使用 nvm (https://github.com/nvm-sh/nvm)"
            info "  方法3: 从 https://nodejs.org 下载"
        fi
        node_ok=0
        issues=$((issues + 1))
    fi

    if command -v npm &> /dev/null; then
        success "npm: $(npm --version)"
    else
        if [ "$node_ok" -eq 1 ]; then
            error "npm 未安装！（Node.js 存在但 npm 缺失，环境异常）"
            info "请检查 Node.js 安装是否完整。"
            issues=$((issues + 1))
        fi
    fi

    # Claude Code
    if command -v claude &> /dev/null; then
        local claude_ver
        claude_ver=$(claude --version 2>/dev/null || echo "已安装")
        success "Claude Code CLI: $claude_ver"
    else
        info "Claude Code CLI: 未安装"
    fi

    # 返回检测结果（仅报告，调用方决定是否退出）
    if [ "$issues" -gt 0 ]; then
        echo ""
        warn "环境检测发现 $issues 个问题。"
        return 1
    fi

    echo ""
    success "环境检测通过。"
    return 0
}

# ============================================================
# 安装 Node.js（仅在用户明确同意时调用）
# ============================================================

install_nodejs_interactive() {
    echo ""
    warn "============================================================"
    warn "  即将安装 Node.js，这将使用 sudo 和系统包管理器修改系统环境。"
    warn "  将执行以下操作:"
    warn "    1. 添加 NodeSource 官方仓库"
    warn "    2. sudo apt-get install -y nodejs"
    warn "============================================================"
    echo ""

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if [ "$INSTALL_DEPS" -eq 1 ]; then
            info "非交互模式：--install-deps 已指定，将自动安装 Node.js。"
            log "INFO" "非交互模式 --install-deps: 自动安装 Node.js"
        else
            error "非交互模式下不会自动安装系统依赖。"
            info "请先手动安装 Node.js 18+，或使用 --install-deps 参数允许自动安装。"
            info "手动安装: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
            info "           sudo apt-get install -y nodejs"
            return 1
        fi
    else
        read -r -p "是否同意安装 Node.js？这将修改系统环境 (Y/N): " agree
        if [ "$agree" != "Y" ] && [ "$agree" != "y" ]; then
            info "已取消 Node.js 安装。"
            info "请手动安装 Node.js 18+ 后重新运行本脚本。"
            info "下载地址: https://nodejs.org (选择 LTS 版本)"
            return 1
        fi
        log "INFO" "用户授权安装 Node.js"
    fi

    info "正在使用 NodeSource 安装 Node.js LTS..."
    if curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - >> "$LOG_FILE" 2>&1; then
        if sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1; then
            success "Node.js 安装完成！"
            if command -v node &> /dev/null; then
                success "Node.js 版本: $(node --version)"
                success "npm 版本: $(npm --version)"
                return 0
            else
                warn "Node.js 安装完成但命令未生效，请运行 'hash -r' 或重新打开终端。"
                return 1
            fi
        else
            error "Node.js 安装失败（apt-get install 失败）。"
            return 1
        fi
    fi

    # 备选方案：直接使用 apt
    warn "NodeSource 安装失败，尝试使用 apt 安装..."
    sudo apt-get update -qq >> "$LOG_FILE" 2>&1
    if sudo apt-get install -y nodejs npm >> "$LOG_FILE" 2>&1; then
        success "Node.js 安装完成（apt 版本）"
        success "Node.js 版本: $(node --version 2>/dev/null || echo '请运行 hash -r 后重试')"
        return 0
    else
        error "Node.js 安装失败，请手动安装: https://nodejs.org"
        return 1
    fi
}

# ============================================================
# 确保 Node.js 可用（用于安装流程）
# ============================================================

ensure_nodejs_for_install() {
    local node_ok=1

    if ! command -v node &> /dev/null; then
        node_ok=0
    else
        local node_major
        node_major=$(node --version | sed 's/v//' | cut -d. -f1)
        if [ "$node_major" -lt 18 ] 2>/dev/null; then
            node_ok=0
        fi
    fi

    if [ "$node_ok" -eq 1 ]; then
        return 0
    fi

    # Node.js 不满足要求，询问是否安装
    if ! command -v node &> /dev/null; then
        error "未检测到 Node.js。Claude Code 需要 Node.js 18 或更高版本。"
    else
        error "当前 Node.js 版本为 $(node --version)，Claude Code 需要 v18 或更高版本。"
        info "请升级 Node.js 后重试。"
    fi

    if ! install_nodejs_interactive; then
        error "Node.js 环境不满足要求，无法继续安装 Claude Code。"
        info "请安装/升级 Node.js 18+ 后重新运行本脚本。"
        return 1
    fi

    return 0
}

# ============================================================
# Claude Code 网络检测和安装函数 (v1.3.2)
# 安装策略:
#   1. claude 已存在 → 跳过（不覆盖、不重装、不自动更新）
#   2. 官方 install.sh 可用 → 优先使用
#   3. 官方不可用或安装失败 → 自动切换 npmmirror npm 镜像
#   4. npm 镜像需要 Node.js >= 18 + npm
# ============================================================

command_exists() {
    command -v "$1" &> /dev/null
}

check_url_reachable() {
    local url="$1"
    local timeout="${2:-15}"
    local method="${3:-HEAD}"

    local http_code curl_exit
    _ccdi_errexit_saved=0
    case $- in *e*) _ccdi_errexit_saved=1 ;; esac
    set +e
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" --connect-timeout "$timeout" --max-time "$((timeout + 5))" "$url" 2>/dev/null)
    curl_exit=$?
    if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi

    if [ "$curl_exit" -eq 0 ] && [ -n "$http_code" ]; then
        # 403/404/401 表示网络可达（DNS/TLS/HTTP 有响应）
        case "$http_code" in
            403|404|401) return 0 ;;
        esac
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 500 ]; then
            return 0
        fi
    fi
    return 1
}

check_official_claude_network() {
    log "INFO" "检测 Claude 官方安装通道..."
    local ok=1

    # 检测 install.sh
    if curl -s --connect-timeout 15 --max-time 20 -o /dev/null "https://claude.ai/install.sh" 2>/dev/null; then
        log "INFO" "claude.ai/install.sh 可达"
    else
        warn "无法下载 claude.ai/install.sh（网络问题或官方服务异常）"
        log "WARN" "claude.ai/install.sh 不可达"
        ok=0
    fi

    # 检测 downloads.claude.ai（有响应即可，403/404 算可达）
    if check_url_reachable "https://downloads.claude.ai" 10 "HEAD"; then
        log "INFO" "downloads.claude.ai 可达"
    else
        warn "无法访问 downloads.claude.ai"
        log "WARN" "downloads.claude.ai 不可达"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        success "Claude 官方安装通道可用。"
        log "INFO" "Claude 官方安装通道: 可用"
    else
        warn "Claude 官方安装通道不可用，将使用 npm 镜像。"
        log "WARN" "Claude 官方安装通道: 不可用"
    fi

    return "$ok"
}

check_npmmirror_network() {
    log "INFO" "检测 npmmirror 镜像可用性..."

    # 检查 node
    if ! command_exists node; then
        warn "Node.js 未安装。"
        return 1
    fi

    local node_major
    node_major=$(node --version | sed 's/v//' | cut -d. -f1)
    if [ "$node_major" -lt 18 ] 2>/dev/null; then
        warn "Node.js 版本过低 ($(node --version))，需要 >= 18。"
        return 1
    fi

    # 检查 npm
    if ! command_exists npm; then
        warn "npm 不可用。"
        return 1
    fi

    # 检测 npmmirror 上的包
    local npm_out npm_rc
    npm_out=$(npm view @anthropic-ai/claude-code version --registry=https://registry.npmmirror.com 2>&1)
    npm_rc=$?

    if [ "$npm_rc" -eq 0 ] && [ -n "$npm_out" ]; then
        info "npmmirror @anthropic-ai/claude-code 可达，版本: $npm_out"
        log "INFO" "npmmirror 镜像可用: $npm_out"
        return 0
    else
        warn "无法从 npmmirror 获取 @anthropic-ai/claude-code 版本信息。"
        log "WARN" "npmmirror 检测失败: $npm_out"
        return 1
    fi
}

install_claude_official() {
    info "正在使用 Claude 官方方式安装..."
    info "执行: curl -fsSL https://claude.ai/install.sh | bash"
    log "INFO" "执行: curl -fsSL https://claude.ai/install.sh | bash"

    local curl_exit
    _ccdi_errexit_saved=0
    case $- in *e*) _ccdi_errexit_saved=1 ;; esac
    set +e
    curl -fsSL https://claude.ai/install.sh | bash >> "$LOG_FILE" 2>&1
    curl_exit=$?
    if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi

    if [ "$curl_exit" -eq 0 ]; then
        success "Claude 官方安装脚本执行成功。"
        log "INFO" "官方 install.sh 完成"
        return 0
    else
        warn "Claude 官方安装脚本执行未成功完成。"
        log "WARN" "官方 install.sh 执行失败 (exit=$curl_exit)"
        return 1
    fi
}

install_claude_npmmirror() {
    info "正在使用 npm + npmmirror 镜像安装 Claude Code..."
    info "执行: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"
    log "INFO" "执行: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"

    local npm_exit
    _ccdi_errexit_saved=0
    case $- in *e*) _ccdi_errexit_saved=1 ;; esac
    set +e
    npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com >> "$LOG_FILE" 2>&1
    npm_exit=$?
    if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi

    if [ "$npm_exit" -eq 0 ]; then
        success "npm 镜像安装 Claude Code 成功！"
        log "INFO" "npm mirror 安装成功"
        return 0
    else
        error "npm 镜像安装过程中出现错误。"
        log "ERROR" "npm mirror 安装失败 (exit=$npm_exit)"
        warn "如果是权限问题，请参考 Claude Code 官方文档修复 npm 权限。"
        warn "不建议通过 sudo 强行安装 Claude Code。"
        return 1
    fi
}

install_claude_auto() {
    log "INFO" "--- install_claude_auto 开始 ---"

    # Step 1: 检测 claude 是否已存在
    if command_exists claude; then
        local existing_version
        existing_version=$(claude --version 2>/dev/null || echo "已安装")
        success "Claude Code 已安装: $existing_version"
        info "已安装时不覆盖、不重装、不自动更新。"

        info "运行 claude doctor..."
        claude doctor 2>&1 || true

        CLAUDE_OK=1
        CLAUDE_INSTALL_METHOD="existing"
        CLAUDE_WAS_ALREADY_INSTALLED=1
        CLAUDE_INSTALL_STATUS="skipped_existing"
        log "INFO" "Claude Code 已存在，跳过安装: $existing_version"
        return 0
    fi

    info "Claude Code 未安装，开始安装流程..."

    # Step 2: 检测官方安装通道
    info "优先使用 Claude 官方方式安装..."
    info "正在检测官方安装通道..."

    local official_ok=0
    if check_official_claude_network; then
        official_ok=1
        if install_claude_official; then
            # 验证官方安装
            hash -r || true
            if command_exists claude; then
                local new_version
                new_version=$(claude --version 2>/dev/null || echo "安装成功")
                success "Claude Code 安装验证通过 (official): $new_version"
                info "运行 claude doctor..."
                claude doctor 2>&1 || true
                CLAUDE_OK=1
                CLAUDE_INSTALL_METHOD="official_native"
                CLAUDE_INSTALL_STATUS="installed"
                log "INFO" "官方安装成功: $new_version"
                return 0
            else
                warn "官方安装脚本已执行但 claude 命令未找到。"
                warn "将尝试 npmmirror 镜像安装作为备用方案。"
                log "WARN" "官方安装后未检测到 claude 命令"
            fi
        else
            warn "官方安装失败，将自动切换 npmmirror 镜像安装。"
            log "WARN" "官方安装失败"
        fi
    else
        warn "Claude 官方安装通道不可用。"
        info "将自动切换 npmmirror 国内镜像安装..."
    fi

    # Step 3: npm npmmirror 镜像安装
    echo ""
    info "正在使用 npmmirror 国内镜像安装 Claude Code..."
    info "使用 Anthropic 官方发布的 @anthropic-ai/claude-code npm 包。"
    info "镜像只提高 Claude Code 下载成功率，不保证登录、鉴权、模型调用一定可用。"
    echo ""

    # 检查镜像可用性（同时检查 node/npm）
    if ! check_npmmirror_network; then
        error "官方安装通道不可用，镜像安装需要 Node.js 18+ 和 npm。"

        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            if [ "$INSTALL_DEPS" -eq 1 ]; then
                info "非交互模式 --install-deps: 尝试安装 Node.js..."
                if ! install_nodejs_interactive; then
                    CLAUDE_OK=0
                    CLAUDE_INSTALL_STATUS="failed_missing_node_or_npm"
                    log "ERROR" "Node.js 自动安装失败"
                    return 1
                fi
                # 重新检测镜像
                if ! check_npmmirror_network; then
                    CLAUDE_OK=0
                    CLAUDE_INSTALL_STATUS="failed_npmmirror_unreachable"
                    log "ERROR" "npmmirror 镜像不可达"
                    return 1
                fi
            else
                error "非交互模式下不会自动安装系统依赖（Node.js）。"
                info "请手动安装 Node.js 18+ 后重新运行。"
                info "或使用 --install-deps 参数允许自动安装。"
                CLAUDE_OK=0
                CLAUDE_INSTALL_STATUS="failed_missing_node_or_npm"
                return 1
            fi
        else
            # 交互模式：提示安装
            if ! install_nodejs_interactive; then
                CLAUDE_OK=0
                CLAUDE_INSTALL_STATUS="failed_missing_node_or_npm"
                return 1
            fi
            # 重新检测镜像
            if ! check_npmmirror_network; then
                CLAUDE_OK=0
                CLAUDE_INSTALL_STATUS="failed_npmmirror_unreachable"
                return 1
            fi
        fi
    fi

    # 执行 npm mirror 安装
    if ! install_claude_npmmirror; then
        error "官方安装和 npm 镜像安装均失败。"
        info "请运行 ./install_wsl.sh --mode doctor 获取诊断。"
        CLAUDE_OK=0
        CLAUDE_INSTALL_METHOD="none"
        CLAUDE_INSTALL_STATUS="failed_official_and_mirror"
        log "ERROR" "官方安装和镜像安装均失败"
        return 1
    fi

    # 验证安装
    hash -r || true
    if command_exists claude; then
        local new_version
        new_version=$(claude --version 2>/dev/null || echo "安装成功")
        success "Claude Code 安装验证通过 (npm mirror): $new_version"
        info "运行 claude doctor..."
        claude doctor 2>&1 || true
        CLAUDE_OK=1
        CLAUDE_INSTALL_METHOD="npm_npmmirror"
        CLAUDE_INSTALL_STATUS="installed"
        log "INFO" "npm mirror 安装成功: $new_version"
        return 0
    else
        warn "claude 命令未找到。可能是 PATH 问题，请尝试:"
        warn "  1. 运行: hash -r"
        warn "  2. 或关闭终端后重新打开"
        warn "  3. 或检查 npm 全局 bin 路径是否在 PATH 中"
        CLAUDE_OK=0
        CLAUDE_INSTALL_METHOD="npm_npmmirror"
        CLAUDE_INSTALL_STATUS="installed_needs_restart"
        log "WARN" "npm mirror 安装后 PATH 未刷新"
        return 1
    fi
}

# ============================================================
# 安装 Claude Code（复用 install_claude_auto）
# ============================================================

install_claude_code() {
    step "安装 Claude Code"

    info "安装策略: 优先 Claude 官方 Native Install → 不可用时自动切换 npmmirror 镜像"
    info "npm 镜像使用 Anthropic 官方发布的 @anthropic-ai/claude-code 包"
    echo ""

    install_claude_auto
    return $?
}

# ============================================================
# 配置 DeepSeek（合并 env，不覆盖）
# ============================================================

configure_deepseek() {
    step "配置 DeepSeek API"

    local api_key
    local key_source=""

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if [ -n "${CCDI_API_KEY:-}" ]; then
            api_key="$CCDI_API_KEY"
            key_source="CCDI_API_KEY"
        elif [ -n "${DEEPSEEK_API_KEY:-}" ]; then
            api_key="$DEEPSEEK_API_KEY"
            key_source="DEEPSEEK_API_KEY"
        else
            error "未检测到环境变量 CCDI_API_KEY 或 DEEPSEEK_API_KEY。非交互模式不会读取明文命令行参数。"
            CONFIG_OK=0
            return 1
        fi
        info "已从环境变量 $key_source 读取 API Key: $(mask_api_key "$api_key")"
    else
        echo ""
        info "现在需要配置您的 DeepSeek API Key。"
        info "获取地址: https://platform.deepseek.com → API Keys"
        echo ""
        warn "输入时不会显示字符（安全保护）。"
        warn "如选择 API 测试，Key 会发送到 DeepSeek 官方接口验证，不会发送给第三方。"
        echo ""

        read -r -s -p "请粘贴您的 DeepSeek API Key: " api_key
        echo ""
    fi

    if [ -z "$api_key" ]; then
        error "API Key 不能为空！配置已取消。"
        CONFIG_OK=0
        return 1
    fi

    # 简单格式检查
    if [[ ! "$api_key" =~ ^sk- ]] || [ ${#api_key} -lt 20 ]; then
        warn "API Key 格式看起来不典型（通常以 sk- 开头，长度 > 20）"
        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            error "非交互模式下拒绝使用格式异常的 API Key。"
            CONFIG_OK=0
            return 1
        fi
        read -r -p "是否继续使用此 Key？(Y/N): " continue_anyway
        if [ "$continue_anyway" != "Y" ] && [ "$continue_anyway" != "y" ]; then
            info "配置已取消。"
            CONFIG_OK=0
            return 1
        fi
    fi

    # 创建配置目录
    local config_dir="$HOME/.claude"
    local config_file="$config_dir/settings.json"

    mkdir -p "$config_dir"

    # 备份旧配置（配置前必须备份，备份失败则阻止写入）
    if [ -f "$config_file" ]; then
        info "检测到已有配置文件，正在备份..."
        if ! backup_file "$config_file"; then
            error "已有配置文件备份失败，已停止写入，避免破坏用户配置。"
            error "请检查 backup/ 目录权限或磁盘空间。"
            CONFIG_OK=0
            return 1
        fi
    fi

    # 确保 JSON 处理器可用
    if ! ensure_json_processor; then
        error "无法处理 JSON 配置，缺少 node 或 python3。"
        CONFIG_OK=0
        return 1
    fi

    # 验证模板文件
    if [ ! -f "$DEFAULTS_FILE" ]; then
        error "找不到默认配置模板: $DEFAULTS_FILE"
        CONFIG_OK=0
        return 1
    fi

    # 构建新配置 JSON（合并 env，不覆盖）
    info "正在写入配置（合并已有 env，不覆盖其他字段）..."

    if merge_settings_json "$config_file" "$DEFAULTS_FILE" "$api_key"; then
        success "DeepSeek 配置已写入！"

        # 如果旧 JSON 损坏，明确提示用户
        if [ "${CONFIG_REBUILT_FROM_DAMAGED:-0}" -eq 1 ]; then
            warn ""
            warn "注意：旧配置文件 JSON 损坏，已备份并重建。"
            warn "旧配置中的非 env 字段（如 permissions）可能无法自动保留。"
            warn "如需恢复，请从 backup/ 目录手动合并。"
            warn ""
        fi

        # 脱敏显示
        info "API Key: $(mask_api_key "$api_key")"
        info "配置文件: $config_file"

        # 验证 JSON
        if validate_settings_json "$config_file"; then
            success "配置文件 JSON 格式验证通过。"
            CONFIG_OK=1
        else
            error "配置文件 JSON 格式验证失败！"
            CONFIG_OK=0
            return 1
        fi
    else
        error "配置写入失败！"
        CONFIG_OK=0
        return 1
    fi

    return 0
}

# ============================================================
# API 测试（Anthropic Format smoke test）
# 返回 0=通过, 1=失败或跳过
# ============================================================

test_api() {
    step "测试 DeepSeek API 连接（Anthropic Format）"

    if [ "$SKIP_API_TEST" -eq 1 ]; then
        info "已按参数跳过 DeepSeek API 在线测试。"
        info "注意: 未验证 API 是否可用。"
        API_TEST_SKIPPED=1
        return 1
    fi

    local config_file="$HOME/.claude/settings.json"
    local api_key
    api_key=$(read_config_value "$config_file" "ANTHROPIC_AUTH_TOKEN" "")

    if [ -z "$api_key" ]; then
        warn "无法从配置文件读取 API Key，跳过 API 测试。"
        API_TEST_SKIPPED=1
        API_TEST_FAIL_REASON="未读取到 API Key"
        return 1
    fi

    local base_url
    base_url=$(read_config_value "$config_file" "ANTHROPIC_BASE_URL" "https://api.deepseek.com/anthropic")
    local main_model
    main_model=$(read_config_value "$config_file" "ANTHROPIC_MODEL" "deepseek-v4-pro[1m]")
    local small_model
    small_model=$(read_config_value "$config_file" "ANTHROPIC_SMALL_FAST_MODEL" "deepseek-v4-flash")

    info "API Key: $(mask_api_key "$api_key")"
    info "Base URL: $base_url"
    info "主模型: $main_model"
    info "快速模型: $small_model"
    info "正在测试 Anthropic Format 接口..."

    local messages_endpoint="${base_url}/messages"
    local request_body
    request_body=$(cat <<EOF
{
  "model": "$small_model",
  "max_tokens": 16,
  "messages": [{"role": "user", "content": "Reply OK only."}]
}
EOF
)

    local response
    local http_code
    local header_file
    header_file=$(mktemp)
    # 使用 x-api-key 作为主要鉴权方式，同时保留 Authorization: Bearer 作为备选
    printf 'x-api-key: %s\n' "$api_key" > "$header_file"
    printf 'Authorization: Bearer %s\n' "$api_key" >> "$header_file"
    printf 'Content-Type: application/json\n' >> "$header_file"
    printf 'anthropic-version: 2023-06-01\n' >> "$header_file"

    # 保存当前 errexit 状态并临时关闭（脚本默认不使用 set -e，
    # 但需要兼容用户通过 bash -e 调用的场景，且绝不能在此时开启 errexit）
    _ccdi_errexit_saved=0
    case $- in *e*) _ccdi_errexit_saved=1 ;; esac
    set +e
    response=$(curl -s -w "\n%{http_code}" \
        -H @"$header_file" \
        --connect-timeout 15 \
        --max-time 30 \
        -X POST \
        -d "$request_body" \
        "$messages_endpoint" 2>&1)
    local curl_exit=$?
    if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi
    rm -f "$header_file"

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    case $http_code in
        200)
            local content
            content=$(echo "$body" | parse_api_content 2>/dev/null)
            if [ -n "$content" ] && [ "$content" != "UNKNOWN_FORMAT" ] && [[ ! "$content" =~ ^PARSE_ERROR ]]; then
                success "Anthropic Format smoke test 通过！(HTTP 200)"
                info "模型返回内容: $content"
                API_TEST_PASSED=1
                return 0
            else
                success "Anthropic Format 接口可访问 (HTTP 200)"
                warn "返回内容解析异常: $content"
                API_TEST_PASSED=1
                return 0
            fi
            ;;
        401)
            error "API Key 验证失败 (401 Unauthorized)"
            info "请检查 API Key 是否正确，到 platform.deepseek.com 重新获取。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="API Key 错误 (401)"
            return 1
            ;;
        402)
            error "账户余额不足或计费异常 (402 Payment Required)"
            info "请到 platform.deepseek.com 检查余额。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="余额/计费异常 (402)"
            return 1
            ;;
        403)
            error "API Key 无权限 (403 Forbidden)"
            info "请检查 API Key 是否有对应接口的访问权限。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="API Key 无权限 (403)"
            return 1
            ;;
        404)
            error "接口或模型未找到 (404 Not Found)"
            info "可能原因: endpoint 或模型名错误。"
            info "当前使用: endpoint=$messages_endpoint, model=$small_model"
            info "请检查 DeepSeek 官方文档确认当前支持的模型名。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="endpoint/模型错误 (404)"
            return 1
            ;;
        429)
            error "请求频率限制 (429 Too Many Requests)"
            info "请稍等几分钟再试。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="频率限制 (429)"
            return 1
            ;;
        5*)
            error "DeepSeek 服务端错误 (HTTP $http_code)"
            info "官方服务暂时异常，请稍后重试。不是您的配置问题。"
            API_TEST_FAILED=1
            API_TEST_FAIL_REASON="服务端错误 (HTTP $http_code)"
            return 1
            ;;
        *)
            if [ -z "$http_code" ] || [ "$http_code" = "000" ] || [ "$curl_exit" -ne 0 ]; then
                error "网络连接失败"
                info "请检查:"
                info "  1. 网络是否正常"
                info "  2. 能否访问 api.deepseek.com"
                info "  3. 是否需要代理"
                API_TEST_FAILED=1
                API_TEST_FAIL_REASON="网络连接失败"
                return 1
            else
                warn "API 返回 HTTP $http_code"
                API_TEST_FAILED=1
                API_TEST_FAIL_REASON="HTTP $http_code"
                return 1
            fi
            ;;
    esac
}

# ============================================================
# WSL 诊断（仅检测，不修改系统）
# ============================================================

run_doctor() {
    step "WSL 环境诊断"

    echo ""
    info "========== 系统信息 =========="
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "操作系统: $NAME $VERSION"
    fi
    info "bash 版本: $(bash --version | head -1)"
    info "是否 WSL: $(if grep -qi microsoft /proc/version 2>/dev/null; then echo '是'; else echo '否/不确定'; fi)"
    echo ""

    info "========== 命令检测 =========="
    if command -v node &> /dev/null; then
        local nv
        nv=$(node --version)
        local nm
        nm=$(echo "$nv" | sed 's/v//' | cut -d. -f1)
        if [ "$nm" -ge 18 ] 2>/dev/null; then
            success "Node.js: $nv"
        else
            error "Node.js: $nv (需要 >= 18)"
        fi
    else
        error "Node.js: 未安装 (需要 >= 18)"
    fi

    if command -v npm &> /dev/null; then
        success "npm: $(npm --version)"
    else
        error "npm: 未安装"
    fi

    if command -v claude &> /dev/null; then
        success "Claude Code: $(claude --version 2>/dev/null || echo '已安装')"
    else
        warn "Claude Code: 未安装"
    fi
    echo ""

    info "========== 配置文件 =========="
    local config_file="$HOME/.claude/settings.json"
    if [ -f "$config_file" ]; then
        success "settings.json: 存在 ($config_file)"
        if validate_settings_json "$config_file"; then
            success "JSON 格式: 有效"

            # 用 node 或 python3 读取配置摘要
            if command -v node &> /dev/null; then
                node -e "
const fs = require('fs'), os = require('os');
const f = '$config_file'.replace(/^~/, os.homedir());
const c = JSON.parse(fs.readFileSync(f, 'utf-8'));
const e = c.env || {};
const t = e.ANTHROPIC_AUTH_TOKEN || '';
const masked = t ? (t.slice(0,4)+'****'+t.slice(-4)) : '(未设置)';
console.log('API Key: ' + masked);
console.log('Base URL: ' + (e.ANTHROPIC_BASE_URL || '(未设置)'));
console.log('主模型: ' + (e.ANTHROPIC_MODEL || '(未设置)'));
console.log('快速模型: ' + (e.ANTHROPIC_SMALL_FAST_MODEL || '(未设置)'));
const managed = new Set(['ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_EFFORT_LEVEL']);
const other = Object.keys(e).filter(k => !managed.has(k));
if (other.length) console.log('其他 env 字段: ' + other.join(', '));
const otherTop = Object.keys(c).filter(k => k !== 'env');
if (otherTop.length) console.log('其他配置项: ' + otherTop.join(', '));
" 2>/dev/null
            elif command -v python3 &> /dev/null; then
                python3 -c "
import json
c = json.load(open('$config_file'))
e = c.get('env', {})
t = e.get('ANTHROPIC_AUTH_TOKEN', '')
m = t[:4]+'****'+t[-4:] if len(t)>8 else ('(已设置)' if t else '(未设置)')
print(f'API Key: {m}')
print(f'Base URL: {e.get(\"ANTHROPIC_BASE_URL\", \"(未设置)\")}')
print(f'主模型: {e.get(\"ANTHROPIC_MODEL\", \"(未设置)\")}')
print(f'快速模型: {e.get(\"ANTHROPIC_SMALL_FAST_MODEL\", \"(未设置)\")}')
" 2>/dev/null
            fi
        else
            error "JSON 格式: 无效"
        fi
    else
        warn "settings.json: 不存在"
    fi
    echo ""

    info "========== 网络检测 =========="
    if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://api.deepseek.com" 2>/dev/null | grep -q "200\|401\|402\|404\|405"; then
        success "api.deepseek.com: 可访问"
    else
        error "api.deepseek.com: 无法访问"
        info "请检查网络连接、DNS、代理或防火墙设置。"
    fi
    echo ""

    info "========== Anthropic Format Smoke Test =========="
    local api_key
    api_key=$(read_config_value "$config_file" "ANTHROPIC_AUTH_TOKEN" "")

    if [ -n "$api_key" ] && [ "$SKIP_API_TEST" -ne 1 ]; then
        local base_url
        base_url=$(read_config_value "$config_file" "ANTHROPIC_BASE_URL" "https://api.deepseek.com/anthropic")
        local test_model
        test_model=$(read_config_value "$config_file" "ANTHROPIC_SMALL_FAST_MODEL" "deepseek-v4-flash")

        info "测试 Anthropic Format: ${base_url}/messages"
        info "使用模型: $test_model"

        local test_body="{\"model\":\"$test_model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK only.\"}]}"
        local hf
        hf=$(mktemp)
        printf 'x-api-key: %s\n' "$api_key" > "$hf"
        printf 'Authorization: Bearer %s\n' "$api_key" >> "$hf"
        printf 'Content-Type: application/json\n' >> "$hf"
        printf 'anthropic-version: 2023-06-01\n' >> "$hf"

        local test_resp test_code
        # 保存当前 errexit 状态并临时关闭（脚本默认不使用 set -e，
        # 但需要兼容用户通过 bash -e 调用的场景，且绝不能在此时开启 errexit）
        _ccdi_errexit_saved=0
        case $- in *e*) _ccdi_errexit_saved=1 ;; esac
        set +e
        test_resp=$(curl -s -w "\n%{http_code}" -H @"$hf" --connect-timeout 15 --max-time 30 -X POST -d "$test_body" "${base_url}/messages" 2>&1)
        test_code=$(echo "$test_resp" | tail -1)
        if [ "$_ccdi_errexit_saved" -eq 1 ]; then set -e; fi
        rm -f "$hf"

        if [ "$test_code" = "200" ]; then
            success "Anthropic Format smoke test: 通过 (HTTP 200)"
        else
            error "Anthropic Format smoke test: 失败 (HTTP $test_code)"
            case $test_code in
                401) info "→ API Key 错误或无权限";;
                402) info "→ 余额不足或计费异常";;
                404) info "→ endpoint 或模型名错误";;
                429) info "→ 频率限制";;
                5*) info "→ DeepSeek 服务端异常";;
                *)   info "→ 网络或未知错误";;
            esac
        fi
    elif [ "$SKIP_API_TEST" -eq 1 ]; then
        info "Anthropic Format smoke test: 已跳过"
        info "注意: 未验证 API 是否可用。"
    else
        warn "Anthropic Format smoke test: 跳过（无 API Key）"
    fi

    echo ""

    # 分享版脱敏处理
    if [ "$SHARE_SAFE" -eq 1 ]; then
        info "========== 生成分享版诊断报告 =========="
        local share_report="$SCRIPT_DIR/report-share-safe.txt"
        {
            echo "============================================================"
            echo "  Claude DeepSeek 诊断报告（分享版 - 已脱敏）"
            echo "  生成时间: $(date)"
            echo "============================================================"
            echo ""
            echo "系统信息:"
            if [ -f /etc/os-release ]; then
                . /etc/os-release 2>/dev/null
                echo "  OS: ${NAME:-未知} ${VERSION:-}"
            fi
            echo "  WSL: $(if grep -qi microsoft /proc/version 2>/dev/null; then echo 是; else echo 否/不确定; fi)"
            echo ""
            echo "命令状态:"
            echo "  Node.js: $(node --version 2>/dev/null || echo 未安装)"
            echo "  npm: $(npm --version 2>/dev/null || echo 未安装)"
            echo "  Claude Code: $(claude --version 2>/dev/null || echo 未安装)"
            echo ""
            echo "配置文件:"
            if [ -f "$config_file" ]; then
                echo "  settings.json: 存在"
                if validate_settings_json "$config_file" 2>/dev/null; then
                    echo "  JSON 格式: 有效"
                    local st
                    st=$(read_config_value "$config_file" "ANTHROPIC_AUTH_TOKEN" "" 2>/dev/null || echo "")
                    echo "  API Key: $(mask_api_key "$st")"
                    echo "  Base URL: $(read_config_value "$config_file" "ANTHROPIC_BASE_URL" "(未设置)" 2>/dev/null || echo "(未设置)")"
                    echo "  主模型: $(read_config_value "$config_file" "ANTHROPIC_MODEL" "(未设置)" 2>/dev/null || echo "(未设置)")"
                else
                    echo "  JSON 格式: 无效"
                fi
            else
                echo "  settings.json: 不存在"
            fi
            echo ""
            echo "网络:"
            if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://api.deepseek.com" 2>/dev/null | grep -q "200\|401\|402\|404\|405"; then
                echo "  api.deepseek.com: 可访问"
            else
                echo "  api.deepseek.com: 无法访问"
            fi
            echo ""
            echo "============================================================"
            echo "注意: 本报告已自动脱敏（隐藏用户名和路径）。"
        } > "$share_report"
        success "分享版报告已生成: $share_report"
        info "你可以将此文件发给卖家/技术支持，不会泄露个人路径信息。"
    fi

    echo ""
    info "诊断完成。"
}

# ============================================================
# 最终摘要（根据状态变量显示真实结果）
# ============================================================

print_final_summary() {
    echo ""

    # doctor 模式不需要摘要
    if [ "$MODE" = "doctor" ]; then
        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN}  诊断完成${NC}"
        echo -e "${GREEN}============================================================${NC}"
        echo ""
        info "请查看上方诊断结果。"
        echo ""
        return 0
    fi

    # test-key 模式只需要 API 测试结果
    if [ "$MODE" = "test-key" ]; then
        echo ""
        info "API Key 测试完成。未修改任何配置文件。"
        echo ""
        return 0
    fi

    # 根据本次任务目标判断成功/失败
    local task_failed=0

    if mode_needs_install && [ "${CLAUDE_OK:-0}" -ne 1 ]; then
        task_failed=1
    fi

    if mode_needs_config && [ "${CONFIG_OK:-0}" -ne 1 ]; then
        task_failed=1
    fi

    if [ "$MODE" = "uninstall" ] || [ "$MODE" = "restore" ]; then
        # uninstall/restore 的结果由各自函数输出，这里只做状态展示
        echo "============================================================"
        if [ -f "$HOME/.claude/settings.json" ]; then
            local token
            token=$(read_config_value "$HOME/.claude/settings.json" "ANTHROPIC_AUTH_TOKEN" "")
            if [ -n "$token" ]; then
                success "DeepSeek 配置: 已配置 (Key: $(mask_api_key "$token"))"
            else
                success "DeepSeek 配置: 已移除"
            fi
        fi
        echo "============================================================"
        return 0
    fi

    if [ "$task_failed" -eq 0 ]; then
        case "$MODE" in
            configure)
                echo -e "${GREEN}============================================================${NC}"
                echo -e "${GREEN}  配置完成${NC}"
                echo -e "${GREEN}============================================================${NC}"
                if [ "${CONFIG_REBUILT_FROM_DAMAGED:-0}" -eq 1 ]; then
                    warn "配置已从损坏 JSON 重建。非 env 字段可能未保留，请检查。"
                fi
                ;;
            install)
                echo -e "${GREEN}============================================================${NC}"
                echo -e "${GREEN}  安装完成${NC}"
                echo -e "${GREEN}============================================================${NC}"
                ;;
            all)
                echo -e "${GREEN}============================================================${NC}"
                echo -e "${GREEN}  安装和配置完成${NC}"
                echo -e "${GREEN}============================================================${NC}"
                if [ "${API_TEST_SKIPPED:-0}" -eq 1 ]; then
                    warn "API 测试已跳过，未验证 Key 是否可用。"
                fi
                ;;
        esac
    else
        echo -e "${RED}============================================================${NC}"
        echo -e "${RED}  本次操作未完成，请检查上方错误${NC}"
        echo -e "${RED}============================================================${NC}"
    fi
    echo ""

    if command -v claude &> /dev/null; then
        success "Claude Code: $(claude --version 2>/dev/null || echo '已安装')"
        if [ -n "${CLAUDE_INSTALL_METHOD:-}" ]; then
            info "安装方式: ${CLAUDE_INSTALL_METHOD}"
        fi
    else
        if mode_needs_install; then
            warn "Claude Code: 未安装或不可用"
        else
            info "Claude Code: $(claude --version 2>/dev/null || echo '已安装（本次未涉及安装）')"
        fi
    fi

    # 检查配置状态
    local config_file="$HOME/.claude/settings.json"
    if mode_needs_config || [ "$MODE" = "all" ]; then
        if [ -f "$config_file" ]; then
            local token
            token=$(read_config_value "$config_file" "ANTHROPIC_AUTH_TOKEN" "")
            if [ -n "$token" ]; then
                local masked
                masked=$(mask_api_key "$token")
                success "DeepSeek 配置: 已配置 (Key: $masked)"
            else
                warn "DeepSeek 配置: API Key 未设置"
            fi
        else
            warn "DeepSeek 配置: 未配置"
        fi
    fi

    if [ "$API_TEST_PASSED" -eq 1 ]; then
        success "API 测试: 通过"
    elif [ "$API_TEST_SKIPPED" -eq 1 ]; then
        warn "API 测试: 已跳过（未验证 API 可用）"
    elif [ "$API_TEST_FAILED" -eq 1 ]; then
        error "API 测试: 失败 - $API_TEST_FAIL_REASON"
        info "配置已写入但 API 未通过验证。请确认:"
        info "  1. API Key 是否正确"
        info "  2. 账户余额是否充足"
        info "  3. 网络是否正常"
        info "  4. 运行 ./install_wsl.sh --mode doctor 获取详细信息"
    fi

    echo ""
    info "下一步:"
    if mode_needs_install && [ "${CLAUDE_OK:-0}" -eq 1 ]; then
        info "  1. 在当前终端运行: claude"
    fi
    info "  2. 如需诊断: ./install_wsl.sh --mode doctor"
    info "  3. 如在 Windows 侧使用 Claude Code: 运行一键诊断.cmd"
    info "  4. 日志文件: $LOG_FILE"
    echo ""
}
# ============================================================
# 运行模式
# ============================================================

run_mode() {
    case "$MODE" in
        all)
            check_environment || true
            if ! install_claude_code; then
                error "Claude Code 安装失败，跳过配置步骤。"
                print_final_summary
                return 1
            fi
            configure_deepseek
            test_api || true
            ;;
        install)
            check_environment || true
            install_claude_code || true
            ;;
        configure)
            configure_deepseek
            test_api || true
            ;;
        doctor)
            run_doctor
            return 0
            ;;
        uninstall)
            uninstall_wsl_config
            return $?
            ;;
        restore)
            restore_wsl_config
            return $?
            ;;
        test-key)
            test_key_only
            return $?
            ;;
    esac
}

# ============================================================
# 主流程
# ============================================================

main() {
    init_logging
    parse_args "$@"

    show_disclaimer

    if [ "$MODE" != "menu" ]; then
        run_mode
        print_final_summary
        return 0
    fi

    # 菜单模式：显示检测结果但不退出
    check_environment || true

    echo ""
    echo -e "${CYAN}请选择操作:${NC}"
    echo "  [1] 安装 Claude Code 并配置 DeepSeek（推荐）"
    echo "  [2] 仅安装 Claude Code"
    echo "  [3] 仅配置 DeepSeek API（Claude Code 已安装）"
    echo "  [4] 仅运行诊断（不安装、不修改配置）"
    echo "  [5] 测试 DeepSeek API Key 是否可用（不写配置）"
    echo "  [6] 移除 DeepSeek 配置（保留 Claude Code）"
    echo "  [7] 从备份恢复配置"
    echo "  [0] 退出"
    echo ""

    read -r -p "请输入选项 (0-7): " choice

    case $choice in
        1)
            if ! install_claude_code; then
                error "Claude Code 安装失败，跳过配置步骤。"
                print_final_summary
                return 1
            fi
            configure_deepseek
            test_api || true
            ;;
        2)
            install_claude_code || true
            ;;
        3)
            configure_deepseek
            test_api || true
            ;;
        4)
            run_doctor
            return 0
            ;;
        5)
            test_key_only || true
            return 0
            ;;
        6)
            uninstall_wsl_config || true
            return 0
            ;;
        7)
            restore_wsl_config || true
            return 0
            ;;
        0)
            info "已退出。"
            exit 0
            ;;
        *)
            error "无效选项。请输入 0-7。"
            main
            return 0
            ;;
    esac

    print_final_summary
}

main "$@"
