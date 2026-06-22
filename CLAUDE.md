# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`claude-deepseek-installer` 是一个 AI 编程环境一键配置工具，帮助 Windows/WSL 用户安装 Claude Code 并接入 DeepSeek API。纯脚本 MVP，面向闲鱼等场景的技术小白用户。

**核心原则**：配置写入和诊断报告均在本地完成；除用户主动选择 DeepSeek 官方 API 测试外，不向第三方发送 API Key；不提供账号/中转/破解服务。

## Session Trigger

以下规则在对应条件触发时执行，不需要读完整个文档体系：

| 触发条件 | 执行动作 |
|---------|---------|
| **每次会话开始** | 读 `AGENTS.md`（简短，秒读）——知道当前分支/状态/下一步 |
| **遇到 bug / 异常行为 / 报错** | 打开 `docs/dev/bug-registry.md` → 顶部**速查表**按症状定位 → 读对应条目。先查是不是已知问题，再动手修 |
| **修完一个 bug** | 在 bug-registry.md 对应主题区追加条目（症状→根因→修复→防复发→教训）+ 更新下方检查覆盖索引 |
| **一个阶段完成 / 准备 commit** | 更新 `AGENTS.md` Progress Log（一行：日期+内容+commit） |
| **不确定要不要记？** | 记。信息宁可多不可丢 |
| **完成任务前** | 扫一眼 AGENTS.md 的"完成前检查"（§完成前检查），逐条确认后再声称完成 |

## Running Scripts

没有编译 build 步骤 — 纯脚本项目，直接交付给用户运行。Release ZIP 打包用 `scripts/build-release.ps1`。轻量自检脚本在 `scripts/check.ps1` 和 `scripts/check.sh`。

```powershell
# Windows PowerShell / PowerShell 7 自检（不含网络）
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1

# 含网络检测（可选 -StrictNetwork 将网络不可达视为失败）
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1 -Network

# Bash/Python 自检
bash scripts/check.sh

# 诊断 smoke test（不保存报告，跳过 API 测试）
powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -NoSaveReport -SkipApiTest

# 一键修复依赖（TestSafe 模式：只检测，不安装）
powershell -ExecutionPolicy Bypass -File .\repair-deps.ps1 -TestSafe
```

## Validation Workflow

`scripts/validate.ps1` 是统一验收入口，编排多级验证工具链。日常开发和发布前必须运行：

```powershell
# 快速自检（git diff --check + check.ps1 PS 5.1 + pwsh）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke

# 完整验收（Smoke + AST 解析 + UX 检查 + 安装决策矩阵 + Core sandbox 流程）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full

# 发布验收（Full + package-release + simulate-user-release + sandbox 全模拟 + 场景矩阵）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release -RequireClean

# 极端场景（失败目录 + 硬核场景矩阵 + doctor-repair 矩阵）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Hardcore

# 全部（Full + Release + Hardcore + 真实 settings.json 不变检查）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All
```

验证层级：**Smoke（每次 commit）→ Full（每次 push）→ Release（发布前）→ Hardcore（专项验证）**

VM 验收层（独立于 `validate.ps1`，面向发布前真机/VM 全链路人工交互验收）：`scripts/vm-final-acceptance.ps1` 在专用 Win11 VMware 验收机内编排 Full→Release→Hardcore→ZIP 构建→从解压目录真实 `.cmd` 启动 ConPTY 提示驱动场景（15 TestSafe + 7 Live）。TestSafe 在 host 即可跑；Live 需管理员 + `C:\CCDI-ACCEPTANCE-VM.marker` + `-AcknowledgeRealInstall` + 首装无 claude/node/npm。详见 `docs/验收与交接体系.md` 第 11 章。AGENTS.md 显示 Live 尚未执行，未纳入发布门禁前不阻塞 release。

Release ZIP 打包：
```powershell
# 直接打包（build-release.ps1）
powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version "1.3.3"

# 向后兼容入口（package-release.ps1，被 validate.ps1 -Mode Release 调用）
powershell -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

## Entry Points（v1.3.3）

用户第一屏是双击 .cmd 文件，不是 PowerShell 命令：

| 入口 | 用途 |
|------|------|
| `00-点我开始安装.cmd` / `Start-Install.cmd` | 懒人安装（双击） |
| `一键诊断.cmd` / `Run-Diagnostics.cmd` | 诊断报告（双击） |
| `一键修复依赖.cmd` | 修复缺失的 Node.js/npm/Claude（双击） |
| `恢复或卸载配置.cmd` / `Restore-Config.cmd` | 配置管理（双击） |

所有 .cmd 必须纯 ASCII 无 BOM。中文提示在 .ps1 中。

`Start-Here.ps1` 是主入口（6 选项菜单 + 7 步懒人安装流程，Native Install 优先 + npm fallback），`install.ps1` 保留向后兼容。

## Architecture

### Lib Loading Order

库文件依赖链是 **单向** 的。入口脚本只 dot-source `lib/bootstrap.ps1`，由 bootstrap 统一加载公共库并初始化日志。`bootstrap.ps1` 是唯一允许集中 dot-source 其他 lib 的例外：

```
bootstrap.ps1
  ├─ logger.ps1  ← 无依赖，最先加载
  ├─ common.ps1  ← 依赖 logger.ps1（使用 Write-Log）
  ├─ state.ps1   ← 依赖 common.ps1 + logger.ps1
  ├─ env-check.ps1  ← 依赖 common.ps1 + logger.ps1
  ├─ config-writer.ps1  ← 依赖 common.ps1 + logger.ps1
  └─ claude-install.ps1  ← 依赖 common.ps1 + logger.ps1 + env-check.ps1 + state.ps1
```

每个入口脚本（install.ps1, doctor.ps1, repair-deps.ps1 等）只负责定位自身目录并加载 bootstrap。

### Key Design Patterns

- **`Invoke-CommandSafe`** (common.ps1)：所有外部命令调用的统一封装，使用 `Start-Process` + 临时文件捕获输出，内置超时机制（默认 60s）。超时时使用 `taskkill /T /F` 杀进程树，并读取临时文件中的部分输出后再清理。不要直接调用外部命令，用此函数包装。**但安装类长操作（winget/npm/native install）不要用 Invoke-CommandSafe**，改用 `Invoke-VisibleInstallCommand` 让用户看到实时进度。
- **`Write-Log` / `Write-Info` / `Write-Success` / `Write-Warning` / `Write-Error-Msg`**：统一的日志+控制台输出。`Write-Log` 写日志文件，其他函数同时写日志+彩色控制台输出。
- **`Write-Result`**：检测结果输出，接受 `OK|WARN|ERROR|SKIP` 状态。
- **`Mask-ApiKey`**：Key 脱敏，显示前 4 位 + 后 4 位。所有输出 API Key 的地方必须经过此函数。
- **`Merge-SettingsJson`**：配置合并，保留已有 env 字段，只覆盖同名 key。
- **`Get-ApiKeyFromEnvironment`**：非交互模式只从 `CCDI_API_KEY` 或 `DEEPSEEK_API_KEY` 读取 Key，不支持命令行明文 Key 参数。
- **`Test-UserPathRisk`** (common.ps1)：检测脚本是否从压缩包临时目录运行（WinRAR/7-Zip/Explorer 解压预览），返回 `IsBlocked` + `RiskLevel`（INFO/WARN/BLOCK）。
- **`Invoke-ClaudeDoctorSafe`** (claude-install.ps1)：安全封装 `claude doctor`（快速诊断，最多 30s 超时），失败不阻塞流程，始终返回结构化结果。
- **`Invoke-ClaudeDoctorInteractiveSafe`** (claude-install.ps1)：隔离执行 `claude doctor`（通过 cmd.exe 包装或 ProcessStartInfo），设置 `NO_COLOR=1`/`TERM=dumb` 防止分页器，使用 `System.Diagnostics.Process` + `WaitForExit` 超时 + `taskkill /T /F` 杀进程树。`Invoke-ClaudeDoctorSafe` 内部委托给它。**不要在 install 流程中自动调用 claude doctor** — 这是纯诊断工具，安装后验证用 `claude --version` + fresh shell。
- **`Invoke-VisibleInstallCommand`** (claude-install.ps1)：可见安装命令封装，使用 `Start-Process -NoNewWindow -PassThru` 让用户看到实时输出，超时用 `taskkill /T /F` 杀进程树。用于 winget/npm/native install 等需要向用户展示进度的长操作。**安装类命令不要用 `Invoke-CommandSafe`**（它会隐藏输出，用户不知道发生了什么）。
- **`Invoke-VisibleFileDownload`** (claude-install.ps1)：可见文件下载封装，用 `Invoke-RestMethod` + 进度条展示。Native Install 下载脚本必须用此函数而非 `Invoke-CommandSafe`。默认 TimeoutSec <= 30。
- **`Write-JsonFileSafe`** (common.ps1)：JSON 文件安全写入。处理空 env、特殊字符等边界情况。
- **`Initialize-ConsoleEncodingSafe`** (logger.ps1)：按 PowerShell 版本和终端类型智能初始化控制台编码。**Windows PowerShell 5.1 Desktop + conhost 下不强制 chcp 65001**，避免中文叠字（如"正正在在检检测测"）。入口脚本通过 `bootstrap.ps1` 的 `Initialize-CcdiScript` 自动调用此函数。
- **`Convert-ToSafeReportText`** (common.ps1)：过滤 claude doctor 输出中的内部字段（GrowthBook、OAuth、tengu_ccr_bridge、organization 等），生成可安全外发的 report.txt。
- **`Remove-AnsiEscape`** / **`Test-Mojibake`** / **`Normalize-ExternalCommandOutput`** (common.ps1)：文本清理管道 — ANSI 转义序列清除 → 乱码检测（锟斤拷/鈹/鉁等）→ 外部命令输出规范化。
- **`TestSafe` / `CCDI_TEST_MODE` 模式**：所有安装/网络/外部调用函数支持 `-TestSafe` 开关或环境变量 `$env:CCDI_TEST_MODE=1`，跳过真实操作返回模拟结果。开发/自检时通过 `$env:CCDI_TEST_USERPROFILE` 和 `$env:CCDI_TEST_DESKTOP` 将文件写入重定向到 `.sandbox/` 目录。
- **`lib/deepseek-env.defaults.json`**：PowerShell 和 WSL 共用的 DeepSeek 默认 env 模板。模型名或默认变量只在这里改。

### Error Handling Strategy

`$ErrorActionPreference = "Continue"` — 所有错误由显式 try/catch 处理（而非依赖 PowerShell 的全局 Stop 模式），确保面向小白的错误信息是中文且友好的。

## Critical Constraints

1. **API Key 绝对不可泄露**：日志、report.txt、控制台输出中 API Key 必须脱敏。输入时用 `Read-SecretInput`（不回显），非交互模式只能用环境变量，所有展示路径经过 `Mask-ApiKey`。
2. **中文优先**：所有面向用户的输出、错误提示、报告内容是中文。技术细节写入日志（英文可接受），但用户看到的必须是中文。
3. **面向小白用户**：不要假设用户懂 PowerShell/npm/WSL。错误提示要给出具体的下一步操作（"按 Win+R 输入 powershell"），而非技术术语（"请检查 DNS 解析"）。
4. **全部输出用 ASCII 标记**：emoji（✅❌⚠）和框线字符（╔═║━┌│）在老终端/远程工具/缺字体环境显示为方块。控制台和报告文件统一用 `[OK]`/`[WARN]`/`[ERROR]`/`[SKIP]`/`[INFO]`。`scripts/check.sh` 会扫描所有文件确保不含风险字符。
5. **脚本幂等**：已安装不重复安装，有配置先备份再合并。
6. **不要求管理员权限**：除非确有必要（如 `npm install -g` 权限问题），优先提示用户手动操作而非自动 `sudo`。
7. **自动化验证安全规则**（来自 AGENTS.md，同样适用于开发）：
   - 自动化验证中**绝不使用真实 DeepSeek API Key**。用 `-TestSafe`、`-SkipApiTest` 或本地 mock。
   - 自动化验证中**绝不执行真实 claude install、winget、npm install/update**。
   - **不污染真实 `%USERPROFILE%\.claude\settings.json`** — 涉及配置逻辑的验证前后记录 hash/length。
   - **不要 `git add .`** — 只精确 add 需要提交的源文件/文档。
   - P0/P1 验证失败是 blocker，先报告再修，修复保持最小范围。

## File Responsibilities

| 文件 | 职责 |
|------|------|
| `00-点我开始安装.cmd` / `Start-Install.cmd` | 双击启动懒人安装（纯 ASCII，无 BOM，含文件存在性检查） |
| `一键诊断.cmd` / `Run-Diagnostics.cmd` | 双击启动诊断（同上编码约束） |
| `恢复或卸载配置.cmd` / `Restore-Config.cmd` | 双击启动配置管理（同上编码约束） |
| `一键修复依赖.cmd` | 双击启动依赖修复：检测并修复缺失的 Node.js/npm/Claude（不会修改 Key/配置） |
| `Start-Here.ps1` | 主入口：6 选项菜单 + 7 步懒人安装（Native Install 优先 + npm fallback），支持 `-TestSafe` |
| `install.ps1` | 旧版安装脚本，向后兼容，支持 `-Mode` 直达安装/配置/诊断 |
| `doctor.ps1` | 7 类诊断（系统/命令/文件/网络/API/VS Code/WSL）→ 生成 ASCII report.txt。用 `$script:DoctorState` 集中管理状态，不用 `+=` 追加 |
| `configure-deepseek.ps1` | 独立的 API Key 输入或环境变量读取 → 配置写入 → API 连接测试 |
| `repair-deps.ps1` | 一键修复依赖：检测并修复缺失的 Node.js/npm/Claude Code，支持 `-TestSafe`/`-DryRun`/`-AllowInstall` |
| `uninstall-config.ps1` | 配置备份恢复 / API Key 移除 / 配置文件删除，备份按文件名而非 LastWriteTime 排序（Copy-Item 保留源时间戳） |
| `install_wsl.sh` | WSL Ubuntu 内安装 Claude Code + 配置 DeepSeek，支持 `--mode` / `--non-interactive` |
| `lib/bootstrap.ps1` | 入口脚本统一初始化、库加载、日志初始化。**唯一允许集中 dot-source 其他 lib 的文件** |
| `lib/common.ps1` | 路径/备份/JSON/Key脱敏/命令执行/用户交互/PATH 刷新/路径风险检测 |
| `lib/state.ps1` | CCDI 安装状态管理（`state.json` 读写），保存安装方式/时间/版本等持久状态 |
| `lib/env-check.ps1` | 系统/命令/文件/网络/DeepSeek API 检测 |
| `lib/config-writer.ps1` | DeepSeek 配置读取/写入/合并/恢复 |
| `lib/claude-install.ps1` | Claude Code 安装策略（官方优先 + npm 镜像 fallback），含 claude doctor 安全封装 |
| `lib/logger.ps1` | 日志初始化、ASCII 标记输出、日志文件管理。**不使用 emoji 或框线字符** |
| `lib/deepseek-env.defaults.json` | PowerShell/WSL 共用 DeepSeek env 默认模板。模型名或默认变量只在这里改 |
| `scripts/build-release.ps1` | Release ZIP 打包：allow-list → 源预扫描 → staging → BOM 规范化 → .cmd 校验 → ZIP → SHA256 |
| `scripts/package-release.ps1` | 向后兼容的 Release ZIP 入口（封装调用 `build-release.ps1`），被 `validate.ps1 -Mode Release` 使用 |
| `scripts/validate.ps1` | 统一验收入口（Smoke/Full/Release/Hardcore/All），编排多级验证工具链 |
| `scripts/check.ps1` | PowerShell 语法/库加载/配置合并/状态守卫/.cmd 编码/安装安全/返回结构检查（支持 `-Network`/`-StrictNetwork`） |
| `scripts/check.sh` | Bash 语法/JSON 模板一致性/报告标记/敏感输出守卫/函数存在性/风险字符扫描 |
| `scripts/ux-check.ps1` / `scripts/ux-check.sh` | UX 文案一致性检查（标记、措辞、PATH 0 容忍等） |
| `scripts/simulate-user-release.ps1` | Release ZIP 用户路径模拟验收（解压→双击 .cmd→ShellExecute→完成页） |
| `scripts/vm-final-acceptance.ps1` | VM 内全链路人工交互验收入口（Full→Release→Hardcore→ZIP→ConPTY 场景）。TestSafe host 可跑；Live 需管理员 + `CCDI-ACCEPTANCE-VM.marker` + `-AcknowledgeRealInstall` |
| `scripts/interactive-user-acceptance.ps1` | ConPTY 提示驱动交互运行器：状态机匹配当前提示后逐步发送输入，`[SECRET SENT]` 脱敏，Job Object 原子绑定进程树终止 |
| `scripts/lib/AcceptanceEnvironment.ps1` | 验收环境基线快照 / ownership delta / 原子回滚（PATH+注册表+`settings.json` 原始字节），`_git_cache.json` 等易变路径忽略 |
| `scripts/lib/ConPtyAcceptanceHost.cs` | C# ConPTY 驱动：`CreatePseudoConsole` + `PROC_THREAD_ATTRIBUTE_JOB_LIST` 创建时原子加入 kill-on-close Job |
| `scripts/data/interactive-acceptance-scenarios.json` | 22 个交互场景定义（15 TestSafe + 7 Live），每场景含 entry/timeoutSec/step.expect |
| `scripts/set-acceptance-credential.ps1` | 交互式保存/删除虚拟机专用 Key 到 Windows Credential Manager（`CCDI_ACCEPTANCE_DEEPSEEK_API_KEY`），不经参数/环境变量/日志 |

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
- `reports/` — 安装报告和历史诊断报告
- `release/` — Release 打包产物
- `*.settings.json`（除 `examples/`） — 用户实际配置
- `report*.txt`（除 `examples/`） — 诊断报告
- `install-report*.txt` — 安装完成报告
- `.sandbox/` — 验收/自动化测试沙盒
- `*.tmp` / `*.log` — PowerShell 临时文件

## Encoding Rules（v1.3 关键约束）

- **.ps1 / .psm1**：必须保存为 UTF-8 with BOM（EF BB BF）。PowerShell 5.1 在中文 Windows 上按 ANSI/GBK 读取无 BOM 文件导致乱码。
- **.cmd**：必须保存为纯 ASCII（无 BOM，无 >0x7F 字节）。CMD 在中文 Windows 上按 GBK 解析导致 UTF-8 中文乱码。
- **.sh**：UTF-8（LF 换行），不需要 BOM。
- build-release.ps1 的 Step 3.45 自动为 staging 中 .ps1 补 BOM，验证 .cmd 纯 ASCII。违反则 exit 1。

## Testing & Development（TestSafe 模式）

所有可能产生外部副作用的函数都支持 `-TestSafe` 开关和/或环境变量 `$env:CCDI_TEST_MODE=1`。在此模式下，函数跳过真实的安装、网络请求、API 调用，返回模拟的结构化结果（`Status = "skipped_test_safe"`）。

### 测试环境变量

| 变量 | 作用 |
|------|------|
| `$env:CCDI_TEST_MODE = "1"` | 全局启用 TestSafe（`Get-UserProfilePath`、`Get-DesktopPath` 等读取此变量） |
| `$env:CCDI_TEST_USERPROFILE` | 将 `%USERPROFILE%` 重定向到沙盒目录 |
| `$env:CCDI_TEST_DESKTOP` | 将桌面路径重定向到沙盒目录 |
| `$env:CCDI_API_KEY` | 非交互模式下的 API Key 来源 |
| `$env:CCDI_TEST_API_STATUS` | 模拟 API 测试返回状态（用于特定测试场景） |

### 测试沙盒契约

- 测试写入必须通过 `$env:CCDI_TEST_USERPROFILE` / `$env:CCDI_TEST_DESKTOP` 重定向到 `.sandbox/`（已 gitignore）
- `scripts/check.ps1` 的 finally 块必须恢复/清理环境变量和测试目录
- 新增安装/网络函数：必须支持 `-TestSafe` 参数或 `CCDI_TEST_MODE=1` 自动跳过

### 自检套件

```powershell
# 基础自检（不含网络）
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1

# 含网络检测
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1 -Network

# 严格网络模式（网络不可达视为测试失败）
powershell -ExecutionPolicy Bypass -File .\scripts\check.ps1 -Network -StrictNetwork

# Bash 自检
bash scripts/check.sh
```

## Common Pitfalls

- **lib 文件不应互相 dot-source**：新增 lib 依赖时，只在 `bootstrap.ps1` 中添加，不在其他 lib 文件内部添加。
- **`Invoke-CommandSafe` 的临时文件**：使用 `$PID` + `Get-Random` 生成唯一文件名。不要硬编码 `cmd_stdout.tmp`。
- **`Invoke-CommandSafe` 安装类调用必须设 TimeoutSec**：下载脚本 180s、执行安装 600s、npm 安装 900s、轻量检测 15-60s。默认 60s 在慢网环境会误判失败。
- **`Write-Result` 的 `$Status` 参数**：值 `OK`/`SKIP` 必须被 `Write-Log` 的 `ValidateSet` 支持（已扩展）。
- **`Read-Host -AsSecureString`**：返回 SecureString，需要用 `Marshal` 转换为明文。已封装在 `Read-SecretInput` 中，直接使用即可。
- **API Key 扫描用 `[List[object]]::new().Add()`**：不要用 `+=` 在函数内追加，PowerShell 函数作用域会创建局部变量导致外层变量不更新。
- **安装后检测 claude 前先调 `Refresh-CurrentProcessPath`**：Native Install/npm 安装后 PATH 可能已写入但当前进程未刷新。
- **Release allow-list**：docs/ examples/ 是文件级白名单，不是整目录。新增/删除 docs 文件必须同步更新 `$AllowedEntries`。**注意：`docs/dev/` 是开发者文档，永远不进入 release allow-list**。
- **安装 Node.js 后 PATH 不刷新**：提示用户"关闭并重新打开 PowerShell"时，附带原因解释（类比手机装 App 后点图标）。
- **TestSafe 模式不执行真实外部操作**：所有安装/网络函数检测到 `-TestSafe` 或 `$env:CCDI_TEST_MODE=1` 立即返回模拟结果，不调用 winget/npm/claude/外网。开发测试时用 `$env:CCDI_TEST_USERPROFILE` 将文件写入重定向到 `.sandbox/`。
- **doctor.ps1 状态用 `$script:DoctorState` 集中管理**：`CheckResults` 和 `Suggestions` 是 `[List[object]]::new()` 脚本级变量，不用 `+=`。`scripts/check.ps1` 会验证此约束。
- **backup 文件排序按文件名**：`Copy-Item` 保留源文件时间戳，所以按 `LastWriteTime` 排序会错序。按文件名（含 yyyyMMdd-HHmmss-fff）排序。文件名精度至少到毫秒，防止同一秒内多次备份互相覆盖。
- **安装类命令不要用 `Invoke-CommandSafe`**：winget/npm install/native install 需要让用户看到实时输出。用 `Invoke-VisibleInstallCommand` 或 `Invoke-InstallCommandCaptured`（使用 `Start-Process -NoNewWindow -PassThru`），超时时用 `taskkill /T /F` 杀进程树。
- **claude doctor 是纯诊断工具，不要在 install 流程中自动调用**：`Install-ClaudeCodeAuto` 不能调用 `Invoke-ClaudeDoctorSafe`/`Invoke-ClaudeDoctorInteractiveSafe`。安装后验证用 `claude --version` + fresh shell 检查。
- **doctor.ps1 不能自动调用 claude doctor**：Check-Commands 只提供手动指导（"手动输入：claude doctor"），警告不要通过脚本/管道/重定向运行，建议截图或复制终端输出。底层通过 `Invoke-ClaudeDoctorInteractiveSafe` 隔离执行（设置 `NO_COLOR=1`/`TERM=dumb`，cmd.exe 包装或 ProcessStartInfo）。
- **`Clear-StaleClaudeDoctorProcesses` 必须按 CommandLine 过滤**：不能简单杀所有 claude.exe 进程（会误杀正常运行的 claude 会话）。支持 `-ParentPid` 参数进行局部清理。
- **`ConvertTo-WindowsCommandLineArgument` 必须处理尾部反斜杠**：路径如 `D:\foo\` 的尾部反斜杠需要双倍转义，否则引号被吞。
- **WSL base64 管道必须用 `printf` 不用 `echo`**：`Test-WslClaudeComprehensive` 中 decoded 变量双引号包裹后通过 `printf '%s'` 管道到 bash，防止分词和转义问题。必须先用 `command -v base64` 检查可用性。
- **Encoding 初始化不要直接调 `chcp 65001`**：用 `Initialize-ConsoleEncodingSafe`（由 `Initialize-CcdiScript` 自动调用）。Windows PowerShell 5.1 Desktop + conhost 下强制 UTF-8 会导致中文叠字。

## Related Files

- **`AGENTS.md`**：会话级状态文件（当前分支、最新 commit、最近修复历史、启动流程）。每次新会话都应该读取 AGENTS.md 了解当前工作上下文。本文件（CLAUDE.md）是持久化的项目文档；AGENTS.md 随迭代更新。
- **`lib/deepseek-env.defaults.json`**：DeepSeek 模型的**唯一权威来源**。任何模型名、默认 env 变量的修改只能在此文件中进行。PowerShell 和 WSL 共用此模板。
