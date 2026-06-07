# Claude Code + DeepSeek 一键安装配置助手

> 解压即用，双击安装 | Windows / WSL 环境诊断 | 自备 DeepSeek API Key

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://learn.microsoft.com/powershell/)
[![Version](https://img.shields.io/badge/Version-1.3.0-green)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 📦 三步开始（v1.3 懒人版）

### 1. 解压 ZIP

下载后右键解压到任意目录。

### 2. 双击「开始安装.cmd」

双击项目目录中的 **`开始安装.cmd`**，按提示操作。

### 3. 粘贴 DeepSeek API Key

脚本会自动打开 DeepSeek API Key 页面。登录、复制 Key，回到窗口粘贴（不显示是正常的）。

之后脚本会自动完成：检测 → 安装 → 配置 → 测试 → 生成报告。

看到 **「安装流程全部完成」** 后，即可运行 `claude` 开始使用。

---

> **遇到问题？** 双击「一键诊断.cmd」→ 把 report.txt 发给技术支持。
>
> **想修改配置？** 双击「恢复或卸载配置.cmd」。

---

## 📋 项目简介

**Claude Code + DeepSeek API 本地配置服务**

帮你把 Claude Code 和你自己的 DeepSeek API Key 配到本机。
能安装、能配置、能查错、能恢复。

本项目是纯脚本工具，供**闲鱼等技术服务场景**使用。买家购买的是**安装配置人工服务**，脚本作为交付品辅助自动化。

---

## ⚖️ 合规声明

| 我们做什么 | 我们不做什么 |
|-----------|-------------|
| ✅ Claude Code 本地安装 | ❌ 出售 Claude 账号 |
| ✅ DeepSeek API 本地配置 | ❌ 出售 API Key |
| ✅ 环境诊断和修复 | ❌ API 中转/代理服务 |
| ✅ 配置文件备份恢复 | ❌ 账号共享 |
| ✅ 纯脚本，可审计 | ❌ 破解/绕过限制 |
| ✅ 代码开源透明 | ❌ 打包 exe 或混淆 |

---

## 👤 适合人群

- ✅ 想用 Claude Code 但不想折腾环境的开发者
- ✅ 已有 DeepSeek API Key，想接入 Claude Code
- ✅ 在 Windows/WSL 环境下使用 VS Code
- ✅ 遇到安装配置问题需要诊断

## ❌ 不适合人群

- ❌ 没有 DeepSeek API Key 的用户（工具不提供 Key）
- ❌ macOS 用户（当前仅支持 Windows/WSL）
- ❌ 期望 Claude 官方原生体验的用户（DeepSeek 兼容层有功能差异）
- ❌ 期望工具提供 API 额度的用户

---

## 🚀 一键入口说明

| 文件 | 用途 | 怎么用 |
|------|------|--------|
| `开始安装.cmd` | 懒人一键安装 | 双击运行 |
| `一键诊断.cmd` | 环境诊断 | 有问题时双击 |
| `恢复或卸载配置.cmd` | 配置管理 | 换 Key / 恢复备份时双击 |

---

## 📁 文件结构

```
claude-deepseek-installer/
├── 开始安装.cmd                  # 懒人一键安装入口（双击）
├── 一键诊断.cmd                  # 一键诊断入口（双击）
├── 恢复或卸载配置.cmd            # 配置管理入口（双击）
├── Start-Here.ps1                # v1.3 主入口脚本
├── README.md                     # 项目说明（本文件）
├── QUICK_START.md                # 快速开始指南
├── install.ps1                   # 安装脚本（高级用法）
├── configure-deepseek.ps1        # DeepSeek API 独立配置脚本
├── doctor.ps1                    # 环境诊断脚本
├── uninstall-config.ps1          # 配置恢复/卸载脚本
├── install_wsl.sh                # WSL Ubuntu 安装脚本
├── .gitignore                    # Git 忽略规则
├── lib/                          # 公共库
│   ├── common.ps1                # 通用工具函数
│   ├── env-check.ps1             # 环境检测函数
│   ├── config-writer.ps1         # 配置读写函数
│   ├── logger.ps1                # 日志和输出
│   ├── bootstrap.ps1             # 入口初始化和库加载
│   └── deepseek-env.defaults.json # DeepSeek 默认 env 模板
├── scripts/                      # 轻量自检脚本
│   ├── check.sh
│   ├── check.ps1
│   └── build-release.ps1         # Release 打包脚本
├── docs/                         # 文档
│   ├── 闲鱼商品说明.md
│   ├── 用户使用教程.md
│   ├── 常见问题FAQ.md
│   ├── 售后排查话术.md
│   ├── 视频教程脚本.md
│   └── 测试清单.md
├── examples/                     # 示例文件
│   ├── settings.deepseek.example.json
│   └── report.example.txt
├── logs/                         # 运行日志（不提交 Git）
├── backup/                       # 配置备份（不提交 Git）
└── reports/                      # 安装报告（不提交 Git）
```

---

## 🔧 高级用法

> 以下为 PowerShell 命令行用法，适合高级用户或远程指导场景。
> 普通用户请直接双击 `.cmd` 文件。

### Windows 命令行安装

```powershell
# 懒人一键安装入口
powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1

# 直接进入某模式
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Mode InstallAndConfigure

# 非交互配置（不把 Key 写进命令历史）
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

### WSL 安装

```bash
# 在 WSL Ubuntu 终端中
chmod +x install_wsl.sh
./install_wsl.sh
```

### 诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

---

## 🔒 安全说明

**您的 API Key 安全是我们的首要考虑：**

1. **API Key 只保存在本机** — 写入 `%USERPROFILE%\.claude\settings.json`
2. **日志不记录 Key** — 所有日志文件中 API Key 自动脱敏
3. **输入不显示** — 输入 API Key 时字符不会显示在屏幕上
4. **自动备份** — 修改配置前自动备份到 `backup/` 目录
5. **不发给第三方** — 脚本不会把 Key 发送给服务提供者或其他第三方
6. **官方 API 测试** — 如选择连接测试，Key 会发送到 DeepSeek 官方接口验证
7. **代码可审计** — 所有代码开源，可自行审查每一行

---

## 🩺 售后流程

### 第 1 步：双击「一键诊断.cmd」

这会生成一份 `report-YYYYMMDD-HHMMSS.txt` 诊断报告。

### 第 2 步：发送报告

将生成的 report 文件发送给卖家/技术支持。

### 第 3 步：不要发送 API Key

**报告中的 API Key 已自动脱敏处理。**
请**不要**单独发送您的 API Key 给任何人！

---

## ❓ 常见问题

### Q: 双击开始安装没有反应？
A: 右键「开始安装.cmd」→「以管理员身份运行」试试。如果还不行，请截图窗口内容发给技术支持。

### Q: 输入 API Key 为什么不显示？
A: 这是安全保护机制，输入和粘贴都不会显示字符。直接粘贴后按回车即可。

### Q: API 测试失败是不是安装失败？
A: 不一定。API 测试可能因为 Key 不对、余额不足、网络问题等失败。Claude Code 本身可能已安装成功，配置也已写入。先检查 Key 和余额，运行诊断确认。

### Q: 没有 VS Code 能不能用？
A: 可以。Claude Code CLI 是核心交付，可以在 PowerShell/CMD 中直接使用。VS Code 是可选增强项。

### Q: Windows 和 WSL 有什么区别？
A: Windows 原生是默认推荐方式。WSL 是 Linux 子系统，适合需要 Linux 环境的开发者。本工具默认配置 Windows 环境，WSL 是高级选项。

### Q: 我可以不给卖家 API Key 吗？
A: 可以。您自己输入 API Key，脚本只写入本机配置。请不要把 Key 发给任何人。

### Q: 如何生成诊断报告？
A: 双击「一键诊断.cmd」即可。

### Q: 如何恢复旧配置？
A: 双击「恢复或卸载配置.cmd」→ 选择恢复备份。

### Q: 需要管理员权限吗？
A: **不需要。** 本工具以普通用户权限运行即可。

### Q: claude 命令提示不存在？
A: 关闭 PowerShell 窗口后重新打开，让 PATH 环境变量刷新。

### Q: 401 错误？
A: API Key 不正确。请到 [platform.deepseek.com](https://platform.deepseek.com) 重新获取。

### Q: 402 错误？
A: DeepSeek 账户余额不足，请充值。

### Q: 5xx 错误？
A: DeepSeek 官方服务异常，稍后重试。不是您的配置问题。

---

## ⚠️ 免责声明

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

## 📄 License

MIT License — 详见 [LICENSE](LICENSE) 文件。

---

**🤖 生成说明**: 本项目由 Claude Code 辅助开发完成。
