# 快速开始指南 (v1.3.1)

## 一、解压即用（推荐方式）

### 第 1 步：解压

下载 ZIP 文件，右键解压到任意目录（桌面也可以）。

> 如果系统自带解压后中文文件名乱码，请用 **7-Zip** 或 **WinRAR** 解压。不要在压缩包内直接双击运行！

### 第 2 步：双击「开始安装.cmd」

在解压后的文件夹中找到 **`开始安装.cmd`**，双击运行。

### 第 3 步：按提示操作

脚本会显示菜单：

```
[1] 一键安装（推荐）
    自动检测 → 安装 → 配置 → 测试 → 生成报告
[2] 遇到问题：一键诊断
[3] 修改 / 恢复 / 卸载配置
[4] 高级选项
[5] 退出
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
1. [OK] 检查系统环境
2. [OK] 安装 Claude Code CLI
3. [OK] 写入 DeepSeek 配置
4. [OK] 测试 API 连接
5. [OK] 创建测试项目
6. [OK] 生成安装完成报告

### 第 7 步：开始使用

看到「安装流程全部完成」后，打开终端：

```powershell
cd "%USERPROFILE%\Desktop\ClaudeCode-Test"
claude
```

---

## 二、遇到问题？

双击 **`一键诊断.cmd`**，把项目根目录下生成的 `report.txt`（分享版）文件发给技术支持。历史报告保存在 `reports/`。

**注意：**
- **只发送 `report.txt`**（分享版，已脱敏路径和 Key）
- **不要发送 `reports/full-report-xxx.txt`**（完整版，包含真实路径）
- **不要发送 `backup/` 目录或 `.bak` 文件**（可能包含完整 API Key）
- **不要发送 `logs/` 目录**（可能包含本机路径信息）
- 诊断报告中的 API Key 已自动脱敏，可以放心发送
- 不要截图包含 API Key 的窗口

---

## 三、入口文件速查

| 文件 | 什么时候用 |
|------|-----------|
| `开始安装.cmd` | 首次安装 / 重新安装 |
| `一键诊断.cmd` | 遇到问题 / 售后支持 |
| `恢复或卸载配置.cmd` | 换 Key / 恢复备份 / 清除配置 |

---

## 四、获取 DeepSeek API Key

1. 访问 https://platform.deepseek.com
2. 注册账号（支持手机号）
3. 进入 "API Keys" 页面
4. 点击 "创建 API Key"
5. 复制并保存 Key（只显示一次！）
6. Key 格式示例：`sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

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
