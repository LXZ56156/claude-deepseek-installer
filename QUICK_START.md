# 快速开始指南

## 一、5 分钟上手

### 1. 打开 PowerShell

**方法 A（推荐）：**
在项目文件夹中，按住 `Shift` 键，右键点击空白处 → **"在此处打开 PowerShell 窗口"**

**方法 B：**
按 `Win + R`，输入 `powershell`，然后 `cd` 到项目目录：
```powershell
cd C:\Users\你的用户名\Downloads\claude-deepseek-installer
```

### 2. 运行安装脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

### 3. 按提示操作

```
[1] 仅安装 Claude Code（不配置 DeepSeek）
[2] 安装 Claude Code 并配置 DeepSeek API（推荐）  ← 选这个
[3] 仅运行环境诊断
[4] 仅配置 DeepSeek API
[5] 退出
```

输入 `2` 并按回车。

### 4. 输入 API Key

当提示输入 API Key 时：
1. 打开浏览器访问 https://platform.deepseek.com
2. 登录后在 API Keys 页面复制您的 Key
3. 回到 PowerShell，按 `Ctrl+V` 粘贴（不会显示任何字符）
4. 按回车确认

### 5. 完成！

看到 `✅ 安装流程完成！` 后，关闭 PowerShell 并重新打开。

测试是否成功：
```powershell
claude --version
```

## 二、遇到问题？

运行诊断脚本：
```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

将生成的 `report.txt` 发给卖家/技术支持。

## 三、常用命令

| 命令 | 作用 |
|------|------|
| `claude` | 启动 Claude Code |
| `claude --version` | 查看版本 |
| `claude doctor` | 官方诊断 |
| `.\doctor.ps1` | 本工具深度诊断 |
| `.\configure-deepseek.ps1` | 修改 API Key |
| `.\uninstall-config.ps1` | 恢复/清除配置 |

非交互配置（避免 Key 出现在命令历史）：

```powershell
$env:CCDI_API_KEY = "sk-你的DeepSeekKey"
powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1 -NonInteractive -SkipApiTest
Remove-Item Env:\CCDI_API_KEY
```

## 四、WSL 用户

如果使用 WSL Ubuntu：

```bash
# 在 WSL Ubuntu 终端中
cd /mnt/c/Users/你的用户名/Downloads/claude-deepseek-installer
chmod +x install_wsl.sh
./install_wsl.sh
```

WSL 非交互配置：

```bash
export CCDI_API_KEY="sk-你的DeepSeekKey"
./install_wsl.sh --mode configure --non-interactive --skip-api-test
unset CCDI_API_KEY
```

## 五、获取 DeepSeek API Key

1. 访问 https://platform.deepseek.com
2. 注册账号（支持手机号）
3. 进入 "API Keys" 页面
4. 点击 "创建 API Key"
5. 复制并保存 Key（只显示一次！）
6. Key 格式：`sk-xxxxxxxxxxxxxxxx`

**注意：DeepSeek API 是付费服务，请关注余额。**
