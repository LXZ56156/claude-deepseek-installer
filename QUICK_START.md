# 快速开始指南 (v1.3)

## 一、解压即用（推荐方式）

### 第 1 步：解压

下载 ZIP 文件，右键解压到任意目录（桌面也可以）。

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

双击 **`一键诊断.cmd`**，把项目目录下生成的 `report.txt` 文件发给技术支持。历史报告保存在 `reports/`。

**注意：诊断报告中不包含完整 API Key，可以放心发送。**

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

| 命令 | 作用 |
|------|------|
| `claude` | 启动 Claude Code |
| `claude --version` | 查看版本 |
| `claude doctor` | Claude Code 官方诊断 |

---

## 六、高级用法

> 以下为 PowerShell 命令行用法，适合高级用户或远程指导场景。

### 直接运行入口脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1
```

### 非交互配置（避免 Key 出现在命令历史）

```powershell
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

### 运行诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

### WSL 用户

```bash
# 在 WSL Ubuntu 终端中
cd /mnt/c/Users/你的用户名/Downloads/claude-deepseek-installer
chmod +x install_wsl.sh
./install_wsl.sh
```
