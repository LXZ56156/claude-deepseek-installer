# 快速开始指南 (v1.3.3)

## 一、解压即用（推荐方式）

### 第 1 步：解压

下载 ZIP 文件，右键选择「全部解压缩」。

你可以解压到：
- 桌面
- 下载目录
- D:\ClaudeDeepSeek
- 你自己容易找到的文件夹

> **重要**：
> - 请先**完整解压**后再运行，**不要在压缩包预览窗口中直接双击**！
> - 你可以解压到桌面、下载目录、D:\ClaudeDeepSeek 或其他你容易找到的文件夹
> - 如果系统自带解压后中文文件名乱码，请用 **7-Zip** 或 **WinRAR** 解压

### 第 2 步：双击「00-点我开始安装.cmd」

在解压后的文件夹中找到 **`00-点我开始安装.cmd`**，双击运行。

### 第 3 步：按提示操作

脚本会显示菜单：

```
[1] 一键安装（推荐）
    自动检测 → 安装 → 配置 → 测试 → 生成报告
[2] 遇到问题：一键诊断
[3] 缺少依赖：一键修复依赖（Node.js/npm/Claude）
[4] 修改 / 恢复 / 卸载配置
[5] 高级选项
[6] 退出
```

直接按回车（默认选 [1]），开始自动安装流程。

### 第 4 步：获取 API Key

脚本会自动打开 DeepSeek API Key 页面。如果没自动打开，手动访问：
https://platform.deepseek.com/api_keys

1. 注册/登录 DeepSeek 账号
2. 点击「创建 API Key」
3. 复制生成的 Key（通常以 `sk-` 开头）

### 第 5 步：粘贴 API Key

回到安装窗口，粘贴 Key（**粘贴时不显示字符，这是安全保护**），按回车。

### 第 6 步：等待安装

脚本会自动完成：
1. 检查系统环境
2. 安装或检测 Claude Code CLI
3. 修复必要 PATH
4. 写入 DeepSeek 配置
5. 测试 API 连接（如未跳过）
6. 创建测试项目
7. 生成安装报告

安装结果以完成页显示为准：
- 安装流程全部完成：可直接验证使用
- 安装基本完成，但命令启动还需要验证：按提示重开 PowerShell 或运行一键修复依赖
- 安装部分完成，API 测试未通过：运行一键诊断，只发送 report.txt

### 第 7 步：开始使用

安装结束后，在完成页选择：

**[1] 立即验证 Claude Code 是否能正常使用（推荐）**

工具会打开测试项目文件夹。

请在打开的文件夹空白处右键 → 在终端中打开，然后输入：

```
claude
```

进入 Claude Code 后，输入：

```
请用一句话说明当前项目是做什么的。
```

如果 Claude Code 能正常回复，说明安装和配置基本可用。

测试项目只是验证用途，可以删除。
删除后不会影响 Claude Code 安装、DeepSeek 配置或 API Key。

---

## 二、遇到问题？

### 先试「一键修复依赖」

双击 **`一键修复依赖.cmd`** — 检测并修复缺失的 Node.js、npm、Claude Code。

- 不会修改已配置的 DeepSeek API Key
- 不会删除已有 Claude 配置
- 安装系统软件时会先询问用户
- 如果提示 NEEDS_RESTART，关闭窗口后重新双击「00-点我开始安装.cmd」
- 生成的 repair-deps-report 仅用于依赖状态；完整诊断仍用「一键诊断.cmd」的 report.txt

### 还不行？运行诊断

如需售后，请运行「一键诊断.cmd」。

**售后安全提示：**
- 只发送生成的 report.txt。
- 不要发送 backup/、logs/、reports/full-report-*、settings.json。
- 不要发送完整 API Key。
- 如果截图，请先确认截图里没有完整 API Key。

诊断报告中的 API Key 已自动脱敏，可以放心发送。

---

## 三、入口文件速查

| 文件 | 什么时候用 |
|------|-----------|
| `00-点我开始安装.cmd` | 首次安装 / 重新安装 |
| `一键诊断.cmd` | 遇到问题 / 售后支持 |
| `一键修复依赖.cmd` | 缺 Node.js/npm/Claude 时修复（不会修改 Key，不会删除配置） |
| `恢复或卸载配置.cmd` | 换 Key / 恢复备份 / 清除配置 |

---

## 四、获取 DeepSeek API Key

1. 访问 https://platform.deepseek.com
2. 注册账号（支持手机号）
3. 进入 "API Keys" 页面
4. 点击 "创建 API Key"
5. 复制并保存 Key（只显示一次！）
6. Key 通常以 `sk-` 开头，后面是一长串随机字符

**注意：DeepSeek API 是付费服务，请关注余额。**

---

## 五、常用命令

### Windows

| 命令 | 作用 |
|------|------|
| `claude` | 启动 Claude Code |
| `claude --version` | 查看版本 |
| `claude doctor` | Claude Code 官方诊断 |
| `.\doctor.ps1 -ShareSafe` | 生成可分享的诊断报告 |

### WSL Ubuntu

| 命令 | 作用 |
|------|------|
| `./install_wsl.sh` | 交互式安装/配置 |
| `./install_wsl.sh --mode configure` | 仅配置 DeepSeek |
| `./install_wsl.sh --mode doctor` | 仅诊断 |
| `./install_wsl.sh --mode test-key` | 仅测试 Key |
| `./install_wsl.sh --mode uninstall` | 移除 DeepSeek 配置 |
| `./install_wsl.sh --mode restore` | 从备份恢复 |
| `./install_wsl.sh --mode doctor --share-safe --yes` | 生成分享版诊断报告 |

---

## 网络与安装策略 (v1.3.3)

本工具采用**后验验证为准**的 Claude Code 安装策略：

1. **已安装则跳过**：不覆盖、不重装、不自动更新（同时检查 User PATH 和 fresh shell 可用性）
2. **优先官方安装**：检测 `claude.ai` 和 `downloads.claude.ai`，可用时使用官方 Native Install
3. **后验验证为准**：安装包 ExitCode 不直接决定成败，最终以 claude --version 和 fresh shell 验证为准
4. **备用通道**：官方方式未完成验证时，自动尝试 winget → npm 镜像
5. **只用官方包**：npm 镜像安装使用 Anthropic 官方发布的 `@anthropic-ai/claude-code` 包

**注意**：镜像只提高 Claude Code 下载成功率，不保证 Claude 登录、鉴权、模型调用一定可用。

### 常见安装失败

| 原因 | 解决方法 |
|------|----------|
| 无法访问 claude.ai | 检查网络/VPN/代理 |
| 未安装 Node.js/npm | 从 https://nodejs.org 下载 LTS 版 |
| npmmirror 不可访问 | 检查网络，稍后重试 |
| claude 命令不存在 | 关闭终端后重新打开 |

---

## 六、高级用法

> 以下为 PowerShell 命令行用法，适合高级用户或远程指导场景。

### 直接运行入口脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1
```

### 测试安全模式（不安装软件）

```powershell
$env:CCDI_TEST_MODE = "1"
$env:CCDI_TEST_USERPROFILE = "$PWD\.sandbox\windows-userprofile"
$env:CCDI_TEST_DESKTOP = "$PWD\.sandbox\windows-desktop"
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1 -NonInteractive -SkipDisclaimer -TestSafe
Remove-Item Env:\CCDI_API_KEY, Env:\CCDI_TEST_MODE, Env:\CCDI_TEST_USERPROFILE, Env:\CCDI_TEST_DESKTOP -ErrorAction SilentlyContinue
```

`-TestSafe` 会跳过 Claude Code 安装、更新、winget/npm 调用和真实 API 测试，仅用于沙盒验证配置写入和报告生成。

### 非交互配置（避免 Key 出现在命令历史）

```powershell
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

### 非交互移除 DeepSeek 配置

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -RemoveDeepSeekEnv -Yes
```

### 运行诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

### 开发者自检

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
```

如果没有安装 `pwsh.exe`，只运行第一条即可。双击 `.cmd` 入口默认使用 Windows PowerShell 5.1，因此发布前至少要保证第一条通过。

### WSL 用户（推荐在 WSL 终端中手动运行）

```bash
# 在 WSL Ubuntu 终端中（推荐方式）
cd /mnt/c/Users/你的用户名/路径/claude-deepseek-installer
chmod +x install_wsl.sh
./install_wsl.sh
```

Windows 端自动调用 WSL 为实验性高级选项，不推荐新手使用。
