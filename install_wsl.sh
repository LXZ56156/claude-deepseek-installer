#!/bin/bash
# ============================================================
# install_wsl.sh - WSL Ubuntu 内 Claude Code 安装配置脚本
# 版本: 1.3.0
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
SCRIPT_VERSION="1.3.0"
MODE="menu"
YES=0
NON_INTERACTIVE=0
SKIP_API_TEST=0
INSTALL_DEPS=0

# 状态变量（用于最终摘要）
CLAUDE_OK=0
CONFIG_OK=0
API_TEST_PASSED=0
API_TEST_SKIPPED=0
API_TEST_FAILED=0
API_TEST_FAIL_REASON=""

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
  ./install_wsl.sh [--mode all|install|configure|doctor] [--yes] [--non-interactive] [--skip-api-test] [--install-deps]

选项:
  --mode all              安装 Claude Code 并配置 DeepSeek
  --mode install          仅安装 Claude Code
  --mode configure        仅配置 DeepSeek
  --mode doctor           仅运行诊断（不修改系统）
  --yes                   跳过免责声明确认
  --non-interactive       非交互模式，只从 CCDI_API_KEY 或 DEEPSEEK_API_KEY 读取 Key
  --skip-api-test         跳过 DeepSeek API 在线测试
  --install-deps          允许在非交互模式下自动安装系统依赖（Node.js 等）
  -h, --help              显示帮助
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                if [ $# -lt 2 ]; then
                    error "--mode 需要值: all|install|configure|doctor"
                    exit 1
                fi
                MODE="$2"
                case "$MODE" in
                    all|install|configure|doctor) ;;
                    *)
                        error "无效 --mode: $MODE"
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

# 备份文件（返回 0=成功, 1=失败）
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
        node << 'NODEEOF'
const fs = require('fs');
const path = require('path');
const os = require('os');

const configFile = process.env.CCDI_CONFIG_FILE.replace(/^~/, os.homedir());
const defaultsFile = process.env.CCDI_DEFAULTS_FILE;
const apiKey = process.env.CCDI_INPUT_API_KEY;

// 读取默认 env 模板
const newEnv = JSON.parse(fs.readFileSync(defaultsFile, 'utf-8'));
newEnv.ANTHROPIC_AUTH_TOKEN = apiKey;

// 读取现有配置
let existing = {};
if (fs.existsSync(configFile)) {
    try {
        const content = fs.readFileSync(configFile, 'utf-8').trim();
        if (content) {
            existing = JSON.parse(content);
        }
    } catch (e) {
        // JSON 无效，使用空配置（旧文件已备份）
    }
}

// 合并 env: 保留已有 env 字段，只新增/覆盖本工具管理的字段
let oldEnv = existing.env || {};
if (typeof oldEnv !== 'object' || Array.isArray(oldEnv)) {
    oldEnv = {};
}

// 用新值覆盖本工具管理的字段
Object.assign(oldEnv, newEnv);
existing.env = oldEnv;

// 确保目录存在
const configDir = path.dirname(configFile);
if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true });
}

// 写入
fs.writeFileSync(configFile, JSON.stringify(existing, null, 2), 'utf-8');
console.log('CONFIG_OK');
NODEEOF
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
if os.path.exists(config_file):
    try:
        with open(config_file, 'r') as f:
            content = f.read().strip()
            if content:
                existing = json.loads(content)
    except json.JSONDecodeError:
        pass

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
    local node_ok=1
    if command -v node &> /dev/null; then
        local node_ver
        node_ver=$(node --version)
        local node_major
        node_major=$(echo "$node_ver" | sed 's/v//' | cut -d. -f1)

        if [ "$node_major" -lt 18 ] 2>/dev/null; then
            warn "Node.js 版本过旧 ($node_ver)，Claude Code 需要 Node.js >= 18"
            info "当前版本: $node_ver，需要: v18 或更高版本"
            info "建议升级 Node.js 后重新运行本脚本。"
            node_ok=0
            issues=$((issues + 1))
        else
            success "Node.js: $node_ver"
        fi
    else
        error "Node.js 未安装！Claude Code 需要 Node.js 18 或更高版本。"
        info "请先安装 Node.js LTS 后重新运行本脚本。"
        info "安装方法:"
        info "  方法1: curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -"
        info "          sudo apt-get install -y nodejs"
        info "  方法2: 使用 nvm (https://github.com/nvm-sh/nvm)"
        info "  方法3: 从 https://nodejs.org 下载"
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
# 安装 Claude Code
# ============================================================

install_claude_code() {
    step "安装 Claude Code"

    # 先确保 Node.js 环境满足要求
    if ! ensure_nodejs_for_install; then
        CLAUDE_OK=0
        return 1
    fi

    if command -v claude &> /dev/null; then
        local version
        version=$(claude --version 2>/dev/null || echo "未知版本")
        success "Claude Code 已安装: $version"

        if [ "$NON_INTERACTIVE" -eq 1 ]; then
            info "非交互模式：跳过更新询问，保持现有版本。"
        else
            echo ""
            info "已安装版本: $version"
            read -r -p "是否更新到最新版本？(Y/N): " update_choice
            if [ "$update_choice" = "Y" ] || [ "$update_choice" = "y" ]; then
                info "正在更新 Claude Code..."
                if npm install -g @anthropic-ai/claude-code@latest >> "$LOG_FILE" 2>&1; then
                    success "Claude Code 已更新到最新版本。"
                else
                    warn "更新失败，将继续使用现有版本。"
                fi
            else
                info "跳过更新。"
            fi
        fi

        info "正在运行 claude doctor..."
        claude doctor 2>&1 || true
        CLAUDE_OK=1
        return 0
    fi

    info "正在使用 npm 安装 Claude Code..."
    info "执行: npm install -g @anthropic-ai/claude-code@latest"

    if npm install -g @anthropic-ai/claude-code@latest >> "$LOG_FILE" 2>&1; then
        success "Claude Code 安装成功！"
    else
        error "Claude Code 安装失败！"
        warn "如果是权限问题，请尝试:"
        warn "  1. 检查 npm 全局目录是否为当前用户可写"
        warn "  2. 参考 Claude Code 官方文档修复 npm 权限"
        warn "  3. 不建议通过 sudo 强行安装 Claude Code"
        warn "日志文件: $LOG_FILE"
        CLAUDE_OK=0
        return 1
    fi

    # 验证
    if command -v claude &> /dev/null; then
        local new_version
        new_version=$(claude --version 2>/dev/null || echo "安装成功")
        success "Claude Code 版本: $new_version"
        info "运行 claude doctor..."
        claude doctor 2>&1 || true
        CLAUDE_OK=1
    else
        warn "claude 命令未找到。"
        warn "可能是 PATH 问题，请尝试:"
        warn "  1. 运行: hash -r"
        warn "  2. 或关闭终端后重新打开"
        warn "  3. 或检查 npm 全局 bin 路径是否在 PATH 中"
        CLAUDE_OK=0
        return 1
    fi

    return 0
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
    info "诊断完成。"
}

# ============================================================
# 最终摘要（根据状态变量显示真实结果）
# ============================================================

print_final_summary() {
    echo ""

    # 根据状态决定摘要标题
    if [ "$CLAUDE_OK" -eq 1 ] && [ "$CONFIG_OK" -eq 1 ] && [ "$API_TEST_PASSED" -eq 1 ]; then
        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN}  安装流程全部完成！${NC}"
        echo -e "${GREEN}============================================================${NC}"
    elif [ "$CLAUDE_OK" -eq 1 ] && [ "$CONFIG_OK" -eq 1 ] && [ "$API_TEST_SKIPPED" -eq 1 ]; then
        echo -e "${YELLOW}============================================================${NC}"
        echo -e "${YELLOW}  安装完成（未验证 API 可用）${NC}"
        echo -e "${YELLOW}============================================================${NC}"
    elif [ "$CLAUDE_OK" -eq 1 ] && [ "$CONFIG_OK" -eq 1 ] && [ "$API_TEST_FAILED" -eq 1 ]; then
        echo -e "${YELLOW}============================================================${NC}"
        echo -e "${YELLOW}  安装部分完成（API 测试未通过）${NC}"
        echo -e "${YELLOW}============================================================${NC}"
    elif [ "$CLAUDE_OK" -eq 1 ]; then
        echo -e "${YELLOW}============================================================${NC}"
        echo -e "${YELLOW}  安装部分完成${NC}"
        echo -e "${YELLOW}============================================================${NC}"
    else
        echo -e "${RED}============================================================${NC}"
        echo -e "${RED}  安装未完成，请检查上述错误${NC}"
        echo -e "${RED}============================================================${NC}"
    fi
    echo ""

    if command -v claude &> /dev/null; then
        success "Claude Code: $(claude --version 2>/dev/null || echo '已安装')"
    else
        warn "Claude Code: 未安装或不可用"
    fi

    # 检查配置状态
    local config_file="$HOME/.claude/settings.json"
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
        info "  4. 运行 doctor 获取详细信息"
    fi

    echo ""
    info "下一步:"
    if [ "$CLAUDE_OK" -eq 1 ]; then
        info "  1. 运行 claude 启动 Claude Code"
    fi
    info "  2. 如有问题，在 Windows 端运行 doctor.ps1"
    info "  3. 日志文件: $LOG_FILE"
    echo ""
}

# ============================================================
# 运行模式
# ============================================================

run_mode() {
    case "$MODE" in
        all)
            # 环境检测仅展示结果，不阻断流程
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
    echo "  [4] 仅运行诊断（不安装任何东西）"
    echo "  [5] 退出"
    echo ""

    read -r -p "请输入选项 (1-5): " choice

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
            info "已退出。"
            exit 0
            ;;
        *)
            error "无效选项。请输入 1-5。"
            main
            return 0
            ;;
    esac

    print_final_summary
}

main "$@"
