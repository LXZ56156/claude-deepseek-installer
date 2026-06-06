# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`claude-deepseek-installer` 是一个 AI 编程环境一键配置工具，帮助 Windows/WSL 用户安装 Claude Code 并接入 DeepSeek API。纯脚本 MVP，面向闲鱼等场景的技术小白用户。

**核心原则**：配置写入和诊断报告均在本地完成；除用户主动选择 DeepSeek 官方 API 测试外，不向第三方发送 API Key；不提供账号/中转/破解服务。

## Running Scripts

没有 build 步骤 — 这是纯脚本项目，直接交付给用户运行。轻量自检脚本在 `scripts/` 下。

```powershell
# Windows PowerShell / PowerShell 7 自检
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1

# Bash/Python 自检
bash scripts/check.sh

# 诊断 smoke test
powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -NoSaveReport -SkipApiTest
```

## Architecture

### Lib Loading Order

库文件依赖链是 **单向** 的。入口脚本只 dot-source `lib/bootstrap.ps1`，由 bootstrap 统一加载公共库并初始化日志。`bootstrap.ps1` 是唯一允许集中 dot-source 其他 lib 的例外：

```
bootstrap.ps1
  ├─ logger.ps1  ← 无依赖，最先加载
  ├─ common.ps1  ← 依赖 logger.ps1（使用 Write-Log）
  ├─ env-check.ps1  ← 依赖 common.ps1 + logger.ps1
  └─ config-writer.ps1  ← 依赖 common.ps1 + logger.ps1
```

每个入口脚本（install.ps1, doctor.ps1 等）只负责定位自身目录并加载 bootstrap。

### Key Design Patterns

- **`Invoke-CommandSafe`** (common.ps1)：所有外部命令调用的统一封装，使用 `Start-Process` + 临时文件捕获输出，内置超时机制（默认 60s）。不要直接调用外部命令，用此函数包装。
- **`Write-Log` / `Write-Info` / `Write-Success` / `Write-Warning` / `Write-Error-Msg`**：统一的日志+控制台输出。`Write-Log` 写日志文件，其他函数同时写日志+彩色控制台输出。
- **`Write-Result`**：检测结果输出，接受 `OK|WARN|ERROR|SKIP` 状态。
- **`Mask-ApiKey`**：Key 脱敏，显示前 4 位 + 后 4 位。所有输出 API Key 的地方必须经过此函数。
- **`Merge-SettingsJson`**：配置合并，保留已有 env 字段，只覆盖同名 key。
- **`Get-ApiKeyFromEnvironment`**：非交互模式只从 `CCDI_API_KEY` 或 `DEEPSEEK_API_KEY` 读取 Key，不支持命令行明文 Key 参数。
- **`lib/deepseek-env.defaults.json`**：PowerShell 和 WSL 共用的 DeepSeek 默认 env 模板。模型名或默认变量只在这里改。

### Error Handling Strategy

`$ErrorActionPreference = "Continue"` — 所有错误由显式 try/catch 处理（而非依赖 PowerShell 的全局 Stop 模式），确保面向小白的错误信息是中文且友好的。

## Critical Constraints

1. **API Key 绝对不可泄露**：日志、report.txt、控制台输出中 API Key 必须脱敏。输入时用 `Read-SecretInput`（不回显），非交互模式只能用环境变量，所有展示路径经过 `Mask-ApiKey`。
2. **中文优先**：所有面向用户的输出、错误提示、报告内容是中文。技术细节写入日志（英文可接受），但用户看到的必须是中文。
3. **面向小白用户**：不要假设用户懂 PowerShell/npm/WSL。错误提示要给出具体的下一步操作（"按 Win+R 输入 powershell"），而非技术术语（"请检查 DNS 解析"）。
4. **report.txt 用 ASCII 标记**：emoji 在老终端/编辑器会乱码，用户发给卖家时会困惑。控制台用 emoji，报告文件用 `[OK]`/`[WARN]`/`[ERROR]`/`[SKIP]`。
5. **脚本幂等**：已安装不重复安装，有配置先备份再合并。
6. **不要求管理员权限**：除非确有必要（如 `npm install -g` 权限问题），优先提示用户手动操作而非自动 `sudo`。

## File Responsibilities

| 文件 | 职责 |
|------|------|
| `install.ps1` | 主入口：免责声明 → 环境检测 → 菜单或 `-Mode` 直达安装/配置/诊断 |
| `doctor.ps1` | 7 类诊断（系统/命令/文件/网络/API/VS Code/WSL）→ 生成 ASCII report.txt |
| `configure-deepseek.ps1` | 独立的 API Key 输入或环境变量读取 → 配置写入 → API 连接测试 |
| `uninstall-config.ps1` | 配置备份恢复 / API Key 移除 / 配置文件删除 |
| `install_wsl.sh` | WSL Ubuntu 内安装 Claude Code + 配置 DeepSeek，支持 `--mode` / `--non-interactive` |
| `lib/bootstrap.ps1` | 入口脚本统一初始化、库加载、日志初始化 |
| `lib/common.ps1` | 路径/备份/JSON/Key脱敏/命令执行/用户交互 |
| `lib/env-check.ps1` | 系统/命令/文件/网络/DeepSeek API 检测 |
| `lib/config-writer.ps1` | DeepSeek 配置读取/写入/合并/恢复 |
| `lib/logger.ps1` | 日志初始化、彩色输出、日志文件管理 |
| `lib/deepseek-env.defaults.json` | PowerShell/WSL 共用 DeepSeek env 默认模板 |
| `scripts/check.*` | 无外部依赖的轻量语法、安全和模板一致性检查 |

## DeepSeek Configuration Format

写入到 `%USERPROFILE%\.claude\settings.json`：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "<用户输入的Key>",
    "ANTHROPIC_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_SMALL_FAST_MODEL": "deepseek-v4-flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
```

`Merge-SettingsJson` 保证保留已存在的非 env 字段和 env 中未被覆盖的字段。

## Git Ignores

- `logs/` — 运行日志含用户环境信息
- `backup/` — 用户配置备份
- `*.settings.json`（除 `examples/`） — 用户实际配置
- `report*.txt`（除 `examples/`） — 诊断报告

## Common Pitfalls

- **lib 文件不应互相 dot-source**：新增 lib 依赖时，只在 `bootstrap.ps1` 中添加，不在其他 lib 文件内部添加。
- **`Invoke-CommandSafe` 的临时文件**：使用 `$PID` + `Get-Random` 生成唯一文件名。不要硬编码 `cmd_stdout.tmp`。
- **`Write-Result` 的 `$Status` 参数**：值 `OK`/`SKIP` 必须被 `Write-Log` 的 `ValidateSet` 支持（已扩展）。
- **`Read-Host -AsSecureString`**：返回 SecureString，需要用 `Marshal` 转换为明文。已封装在 `Read-SecretInput` 中，直接使用即可。
- **安装 Node.js 后 PATH 不刷新**：提示用户"关闭并重新打开 PowerShell"时，附带原因解释（类比手机装 App 后点图标）。
