# Claude Code + DeepSeek 一键安装配置助手

> 解压即用，双击安装 | Windows / WSL 环境诊断 | 自备 DeepSeek API Key

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://learn.microsoft.com/powershell/)
[![Version](https://img.shields.io/badge/Version-1.3.3-green)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 普通买家先看这里（v1.3.3 一键版）

如果你只是想安装和使用，请优先看 ZIP 中的：
- `01-先看我-安装说明.txt` — 完整安装说明
- `02-安装完成后怎么开始使用.txt` — 安装后如何开始
- `03-常用提示词模板.txt` — 8 个可复制的提示词
- `04-常见问题和售后.txt` — 常见问题与售后流程

**最短流程：**

1. 完整解压 ZIP。
2. 双击 `00-点我开始安装.cmd`（中文乱码用 `Start-Install.cmd`）。
3. 按提示输入自己的 DeepSeek API Key（输入时不显示是正常的安全保护）。
4. 安装结束后，在完成页选择 **[1] 启动 Claude Code 测试（推荐）**。工具会自动新开一个 PowerShell 终端，进入测试项目并直接运行 claude。如果自动启动失败，可以在文件夹地址栏输入 `powershell` 并按回车，然后输入 `claude`。
5. 遇到问题双击 `一键诊断.cmd`，优先发送 `support-feedback.txt`。

> **注意：**
> - 本工具不提供 Claude 账号。
> - 本工具不提供 DeepSeek API Key。
> - 本工具不提供代理 API。

---

## 买家 ZIP 包含以下文件

```
  00-点我开始安装.cmd              # 一键安装入口（双击）
  Start-Install.cmd                 # 英文备用安装入口
  一键诊断.cmd                       # 一键诊断入口（双击）
  Run-Diagnostics.cmd               # 英文备用诊断入口
  一键修复依赖.cmd                   # 依赖修复入口（双击）
  恢复或卸载配置.cmd                 # 配置管理入口（双击）
  Restore-Config.cmd                # 英文备用配置入口
  01-先看我-安装说明.txt             # 安装说明
  02-安装完成后怎么开始使用.txt       # 使用指南
  03-常用提示词模板.txt              # 提示词索引
  04-常见问题和售后.txt              # 常见问题
  提示词模板/                        # 8 个可直接复制使用的提示词
  README.md                         # 本文件
  LICENSE                           # MIT 许可证
  Start-Here.ps1                    # 主入口脚本
  install.ps1                       # 安装脚本
  configure-deepseek.ps1            # API 配置脚本
  doctor.ps1                        # 诊断脚本
  uninstall-config.ps1              # 配置恢复/卸载脚本
  repair-deps.ps1                   # 依赖修复脚本
  install_wsl.sh                    # WSL 安装脚本
  lib/                              # 公共库（8 个文件）
```

> **以下目录仅存在于源码仓库，不在买家 ZIP 中：**
> - `scripts/` — 开发和自检脚本
> - `docs/` — 开发者文档
> - `examples/` — 示例文件
> - `logs/`、`backup/`、`reports/` — 运行时产物（安装后才会生成）

---

## 项目简介

**Claude Code + DeepSeek API 本地配置服务**

帮你把 Claude Code 和你自己的 DeepSeek API Key 配到本机。能安装、能配置、能查错、能恢复。

本项目是纯脚本工具，供**闲鱼等技术服务场景**使用。买家购买的是**安装配置人工服务**，脚本作为交付品辅助自动化。

---

## 合规声明

| 我们做什么 | 我们不做什么 |
|-----------|-------------|
| [OK] Claude Code 本地安装 | [NO] 出售 Claude 账号 |
| [OK] DeepSeek API 本地配置 | [NO] 出售 API Key |
| [OK] 环境诊断和修复 | [NO] API 中转/代理服务 |
| [OK] 配置文件备份恢复 | [NO] 账号共享 |
| [OK] 纯脚本，可审计 | [NO] 破解/绕过限制 |
| [OK] 代码开源透明 | [NO] 打包 exe 或混淆 |

---

## 最低系统要求

| 项目 | 要求 | 说明 |
|------|------|------|
| 操作系统 | Windows 10 1809+ / Windows 11 | Build >= 17763 |
| 系统架构 | x64 或 ARM64 | 64 位系统 |
| 内存 | 4 GB 以上 | 物理内存 |
| PowerShell | 5.1+ | 预装在 Windows 10/11 |
| WSL (高级) | Ubuntu 20.04+ | 仅高级用户需要 |

不满足最低要求时，脚本会明确提示并停止安装。

---

## 适合人群

- [OK] 想用 Claude Code 但不想折腾环境的开发者
- [OK] 已有 DeepSeek API Key，想接入 Claude Code
- [OK] 在 Windows/WSL 环境下使用 VS Code
- [OK] 遇到安装配置问题需要诊断

## 不适合人群

- [NO] 没有 DeepSeek API Key 的用户（工具不提供 Key）
- [NO] macOS 用户（当前仅支持 Windows/WSL）
- [NO] 期望 Claude 官方原生体验的用户（DeepSeek 兼容层有功能差异）
- [NO] 期望工具提供 API 额度的用户

---

## 一键入口说明

| 文件 | 用途 | 怎么用 |
|------|------|--------|
| `00-点我开始安装.cmd` | 一键安装 | 双击运行 |
| `一键诊断.cmd` | 环境诊断 | 有问题时双击 |
| `一键修复依赖.cmd` | 修复 Node.js/npm/Claude 缺失（不会修改 Key/配置） | 缺依赖时双击 |
| `恢复或卸载配置.cmd` | 配置管理 | 换 Key / 恢复备份时双击 |

---

## 安全说明

1. **API Key 保存在本机** — 写入 `%USERPROFILE%\.claude\settings.json`。
2. **安装工具不泄露 Key** — 不会把完整 Key 写入日志、诊断报告或发送给卖家。
3. **API 请求携带 Key** — 当用户选择 API 测试或实际使用 Claude Code 时，请求会携带 Key 发送到用户配置的 DeepSeek 官方 API 地址（默认 `https://api.deepseek.com`）。
4. **不发送到卖家服务器** — Key 不会发送到卖家服务器、项目作者服务器或非用户配置的代理地址。
5. **自定义 Base URL 风险由用户确认** — 如果用户自行修改 Base URL，Key 会发送到该自定义地址，相关风险由用户自行确认。
6. **输入不显示** — 输入 API Key 时字符不会显示在屏幕上。
7. **自动备份** — 修改配置前自动备份到 `backup/` 目录。
8. **代码可审计** — 所有代码开源，可自行审查每一行。

---

## 管理员权限

- 默认以普通用户身份运行即可。
- 不需要一开始就使用管理员权限。
- 某些系统安装器或 winget 可能弹出 Windows UAC 窗口，只有确认窗口来自可信的 Windows/官方安装流程时才允许。
- 双击没反应不能直接归因于权限问题。先确认已解压、检查任务栏和英文备用入口。
- 仍失败再运行一键诊断.cmd。
- 不把"管理员运行"作为首选通用修复方法。

---

## 售后流程

### 第 0 步：先试「一键修复依赖」

双击 **`一键修复依赖.cmd`** — 检测并修复缺失的 Node.js、npm、Claude Code。
- 不会修改已配置的 DeepSeek API Key
- 不会删除已有 Claude 配置

### 第 1 步：双击「一键诊断.cmd」

这会生成诊断文件：
- `support-feedback.txt` — **优先发送**（汇总反馈文件，已脱敏）
- `report.txt` — **备用**（诊断报告，已脱敏）
- `reports/report-YYYYMMDD-HHMMSS.txt` — 分享版历史记录
- `reports/full-report-YYYYMMDD-HHMMSS.txt` — **完整版**（仅本地保存，不要发送）

### 第 2 步：发送 support-feedback.txt

优先将项目根目录的 `support-feedback.txt` 发送给卖家/技术支持。
如果没有该文件，再发送 `report.txt`。

**售后安全提示：**
- 优先发送 support-feedback.txt。
- 如没有 support-feedback.txt，再发送 report.txt。
- 不要发送 backup/、logs/、reports/full-report-*、settings.json。
- 不要发送完整 API Key。
- 如果截图，请先确认截图里没有完整 API Key。
- 不要只发截图，截图只能作为文字的补充。

---

## 常见问题

### 安装相关

**Q: 双击开始安装没有反应？**
A: 先确认已经完整解压 ZIP。检查任务栏是否有被遮挡的窗口。尝试英文入口 `Start-Install.cmd`。仍无反应则运行一键诊断.cmd。不要一上来就用管理员权限。

**Q: 安装需要多长时间？**
A: 取决于网络和电脑环境。只要窗口持续出现进度提示，就继续等待。不要重复双击安装入口。不要在安装时直接关闭窗口。长时间无新输出时，记录窗口内容后运行一键诊断。

**Q: 输入 API Key 为什么不显示？**
A: 这是安全保护机制，输入和粘贴都不会显示字符。直接粘贴后按回车即可。

### API Key 相关

**Q: API 测试失败是不是安装失败？**
A: 不一定。API 测试可能因为 Key 不对、余额不足、网络问题等失败。Claude Code 本身可能已安装成功。先检查 Key 和余额，运行诊断确认。

**Q: 401 错误？**  — API Key 不正确。请到 [platform.deepseek.com](https://platform.deepseek.com) 重新获取。
**Q: 402 错误？**  — DeepSeek 账户余额不足，请充值。
**Q: 403 错误？**  — 访问被拒绝，Key 可能被限制。
**Q: 404 错误？**  — 接口不存在，检查模型名称和 API 地址配置。
**Q: 429 错误？**  — 请求频率过高，等几秒再试。
**Q: 5xx 错误？**  — DeepSeek 官方服务异常，稍后重试。不是您的配置问题。

### 使用相关

**Q: claude 命令提示不存在？**
A: 关闭 PowerShell 窗口后重新打开，让 PATH 环境变量刷新。

**Q: Windows 和 WSL 有什么区别？**
A: Windows 和 WSL 是**两套独立环境**。Claude Code 的配置不共享。
- Windows PowerShell/CMD 用 `00-点我开始安装.cmd`
- WSL Ubuntu 用 `install_wsl.sh`
- 两边的 `settings.json` 不是同一个文件

**Q: 需要管理员权限吗？**
A: 不需要。本工具以普通用户权限运行即可。

**Q: 没有 VS Code 能不能用？**
A: 可以。Claude Code CLI 在 PowerShell/CMD 中直接使用，VS Code 是可选增强项。

**Q: 如何卸载？**
A: 本工具默认只管理配置，不自动卸载 Claude Code。npm 安装的可运行 `npm uninstall -g @anthropic-ai/claude-code`。Native Install 方式请参考 [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code)。

---

## 网络与安装策略 (v1.3.3)

> 以下为技术细节，普通用户不需要关注。安装脚本会自动选择最佳方式。

本工具采用**后验验证为准**的 Claude Code 安装策略：

```
检测 claude 是否已安装
  -> 已安装: 检查 PATH 可用性 -> 跳过安装，继续配置
  -> 未安装:
       优先官方 Native Install
       -> 失败或验证未通过: 切换 winget
       -> winget 不可用: 切换 npm 镜像（需要 Node.js >= 18 + npm）
```

### 策略要点

| 要点 | 说明 |
|------|------|
| 默认官方安装 | 优先使用 Claude 官方 Native Install |
| 后验验证为准 | 安装包 ExitCode 不直接决定成败，最终以 claude --version 和 fresh shell 验证为准 |
| 自动修 PATH | Native Install 安装到 .local\bin 时，会自动写入 User PATH |
| 备用安装通道 | 官方方式未完成验证时，自动尝试 winget / npm 镜像 |
| 不覆盖已安装 | 已安装 Claude Code 时默认不重装、不自动更新 |
| 官方包来源 | npm 镜像安装使用 Anthropic 官方发布的 @anthropic-ai/claude-code 包 |

### 镜像说明

- **npm 镜像只解决下载问题**：提高在国内网络环境下 Claude Code 的下载成功率。
- **不保证后续服务可用**：镜像安装不影响 Claude 登录、鉴权、模型调用。
- **安装方式差异**：npm 镜像安装与官方 Native Install 的安装链路、更新方式不完全一致。

---

## 高级用法

> 以下为 PowerShell 命令行用法，适合高级用户或远程指导场景。
> 普通用户请直接双击 `.cmd` 文件。

### Windows 命令行安装

```powershell
# 一键安装入口
powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1

# 直接进入某模式
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Mode InstallAndConfigure

# 非交互配置（不把 Key 写进命令历史）
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

### WSL 安装与配置

在 WSL Ubuntu 终端中手动运行：

```bash
# 在 WSL Ubuntu 终端中
cd /mnt/c/Users/你的用户名/路径/claude-deepseek-installer
chmod +x install_wsl.sh

# 一键安装 Claude Code + 配置 DeepSeek
./install_wsl.sh

# 或使用命令行模式
./install_wsl.sh --mode configure          # 仅配置 DeepSeek
./install_wsl.sh --mode doctor             # 仅诊断
./install_wsl.sh --mode test-key           # 仅测试 Key
./install_wsl.sh --mode uninstall          # 移除 DeepSeek 配置
./install_wsl.sh --mode restore            # 从备份恢复配置
```

Windows 端自动调用 WSL 为实验性高级选项，不推荐新手使用。

### 诊断

```powershell
# 生成分享版报告（隐藏用户路径）
powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -ShareSafe
```

```bash
# WSL 终端
./install_wsl.sh --mode doctor --share-safe --yes
```

---

## 免责声明

1. 本工具仅做本地环境安装和配置，不提供任何在线服务。
2. 买家需要自备 DeepSeek API Key，API 调用费用由买家承担。
3. 本工具不包含 Claude 账号、不包含 DeepSeek 账号、不包含 API 余额。
4. 本工具不是破解工具，不绕过 Claude 或 DeepSeek 官方限制。
5. 不保证：
   - 不保证 DeepSeek 官方接口永远不变
   - 不保证 Claude Code 后续版本永远兼容
   - 不保证用户网络环境一定可访问
   - 不保证 API 永不限速
6. API 费用、余额、限流由 DeepSeek 官方管理，与本工具无关。
7. 不保证所有 Claude Code 原生功能在 DeepSeek 兼容层下都能正常工作。
8. 多模态（图片、文档等）能力以 DeepSeek 官方兼容情况为准。
9. Claude Code 安装方式可能随官方更新而变化，如遇到安装问题请参考 [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code)。
10. 本工具遵循 MIT 协议开源，用户使用本工具产生的任何后果由用户自行承担。

---

## License

MIT License — 详见 [LICENSE](LICENSE) 文件。

---

**生成说明**: 本项目由 Claude Code 辅助开发完成。
