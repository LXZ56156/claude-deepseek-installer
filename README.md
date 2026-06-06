# Claude Code + DeepSeek 一键安装配置助手

> VS Code AI 编程环境本地配置 | Claude Code 安装 | DeepSeek API 接入

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-blue)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://learn.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## 📋 项目简介

这是一个**AI 编程环境本地配置工具**，帮助用户在 Windows / WSL 环境下：
1. **一键安装** Claude Code CLI 工具
2. **一键配置** DeepSeek API 接入
3. **一键诊断** 环境问题

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

## 🚀 快速开始

### 1. 准备环境

- **Windows 10/11** 操作系统
- **Node.js 18+**（[nodejs.org](https://nodejs.org) 下载 LTS 版，Claude Code 运行必需）
- **npm**（随 Node.js 一起安装）
- **PowerShell 5.1+** （Win 10/11 自带）
- **VS Code**（推荐，可选；Claude Code CLI 是核心交付，VS Code 扩展是可选增强项）
- **DeepSeek API Key**（[platform.deepseek.com](https://platform.deepseek.com) 获取）

### 2. 下载项目

下载 ZIP 解压，或通过 git clone（如有 git）。

### 3. Windows 安装

在项目目录中右键 → **"在终端中打开"**，然后运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

按照屏幕提示选择：
- `[1]` 安装 Claude Code 并配置 DeepSeek（推荐）
- 然后粘贴您的 DeepSeek API Key（输入时不显示，这是安全保护）

### 4. WSL 安装

如果需要在 WSL Ubuntu 中安装，在 WSL 终端中运行：

```bash
chmod +x install_wsl.sh
./install_wsl.sh
```

支持 `--mode all|install|configure|doctor` 指定运行模式。

### 5. 验证安装

```powershell
# 在 PowerShell 中
claude --version
claude doctor

# 如需诊断
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

非交互配置（适合售后自动化，不把 Key 写进命令历史）：

```powershell
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

### 6. 诊断和售后

如遇问题，运行诊断脚本生成报告：

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

将生成的 `report.txt` 发给技术支持（报告中的 API Key 已自动脱敏）。详见下方 [🩺 售后流程](#-售后流程) 和 [❓ 常见问题](#-常见问题)。

---

## 📁 文件结构

```
claude-deepseek-installer/
├── README.md                    # 项目说明（本文件）
├── QUICK_START.md               # 快速开始指南
├── install.ps1                  # 主安装脚本（Windows）
├── configure-deepseek.ps1       # DeepSeek API 独立配置脚本
├── doctor.ps1                   # 环境诊断脚本
├── uninstall-config.ps1         # 配置恢复/卸载脚本
├── install_wsl.sh               # WSL Ubuntu 安装脚本
├── .gitignore                   # Git 忽略规则
├── lib/                         # 公共库
│   ├── common.ps1               # 通用工具函数
│   ├── env-check.ps1            # 环境检测函数
│   ├── config-writer.ps1        # 配置读写函数
│   ├── logger.ps1               # 日志和输出
│   ├── bootstrap.ps1            # 入口初始化和库加载
│   └── deepseek-env.defaults.json # DeepSeek 默认 env 模板
├── scripts/                     # 轻量自检脚本
│   ├── check.sh
│   └── check.ps1
├── docs/                        # 文档
│   ├── 闲鱼商品说明.md           # 闲鱼商品详情文案
│   ├── 用户使用教程.md           # 用户使用教程
│   ├── 常见问题FAQ.md            # 常见问题解答
│   ├── 售后排查话术.md           # 售后话术参考
│   └── 测试清单.md               # 手动测试清单
├── examples/                    # 示例文件
│   ├── settings.deepseek.example.json
│   └── report.example.txt
├── logs/                        # 运行日志（不提交 Git）
└── backup/                      # 配置备份（不提交 Git）
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

如果遇到问题，请按以下步骤操作：

### 第 1 步：运行诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

这会生成一份 `report.txt` 诊断报告。

### 第 2 步：发送报告

将 `report.txt` 文件发送给卖家/技术支持。

### 第 3 步：不要发送 API Key

**报告中的 API Key 已自动脱敏处理。**
请**不要**单独发送您的 API Key 给任何人！

---

## ❓ 常见问题

### Q: 需要管理员权限吗？
A: **不需要。** 本工具以普通用户权限运行即可。如果 npm 安装遇到权限问题，脚本会提示解决方案。

### Q: claude 命令提示不存在？
A: 关闭 PowerShell 窗口后重新打开，让 PATH 环境变量刷新。

### Q: 401 错误？
A: API Key 不正确。请到 [platform.deepseek.com](https://platform.deepseek.com) 重新获取。

### Q: 402 错误？
A: DeepSeek 账户余额不足，请充值。

### Q: 429 错误？
A: 请求过于频繁，请稍等几分钟再试。

### Q: 5xx 错误？
A: DeepSeek 官方服务异常，稍后重试。不是您的配置问题。

### Q: 能用 Claude 官方模型吗？
A: 本工具配置的是 DeepSeek 兼容层接入方式。如需使用 Claude 官方模型，需要 Anthropic 官方 API Key，并自行配置 Anthropic 的 API 地址。

### Q: 支持多模态（图片/文档）吗？
A: 取决于 DeepSeek 官方对该兼容接口的支持情况。请查阅 [DeepSeek 官方文档](https://platform.deepseek.com/docs)。

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
