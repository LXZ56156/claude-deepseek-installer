# Claude Code + DeepSeek 本地配置助手

Windows 10/11 上的 Claude Code 安装、DeepSeek API 本地配置、诊断、依赖修复和配置恢复工具。当前版本：v1.3.3。

![Version-1.3.3](https://img.shields.io/badge/Version-1.3.3-green)

## 普通买家先看这里：v1.3.3 一键版

- `01-先看我-安装说明.txt`：从完整解压到安装和基础验证。
- `02-安装完成后怎么开始使用.txt`：第一次启动并在自己的项目中工作。
- `03-常用提示词模板.txt`：按任务选择 8 个提示词模板。
- `04-常见问题和售后.txt`：按症状排查和联系售后。
- 遇到问题时运行 `一键诊断.cmd`，优先把生成的 `support-feedback.txt` 发给售后；没有该文件时再发 `report.txt`。

本工具不提供 Claude 账号、DeepSeek API Key、代理 API、VPN 或网络加速。

安装完成页的主路径是选择 `[1] 启动 Claude Code 测试（推荐）`，工具会自动打开终端并在测试项目中运行 `claude`。自动打开失败时，可在项目文件夹地址栏输入 `powershell`，按回车后手动输入 `claude`；详细步骤见 02 文档。

## 功能范围

本工具可以：

- 安装或检测 Claude Code 所需环境。
- 把用户自己的 DeepSeek API Key 写入本机 Claude Code 配置。
- 诊断 Windows、命令、网络、API、VS Code 和 WSL 环境。
- 在明确缺少 Node.js、npm 或 Claude Code 时修复依赖。
- 备份、恢复或移除本工具写入的配置。

本工具不会出售账号、Key 或 API 额度，不提供中转服务，不破解或绕过平台限制，也不保证外部网络、账户、额度或第三方服务永久可用。

## 适合与不适合

适合：使用 Windows 10/11、已有自己的 DeepSeek API Key，并希望在本机使用 Claude Code 的用户。

不适合：macOS 用户、没有 DeepSeek API Key 的用户、需要代理或 VPN 的用户，以及期望获得 Claude 官方原生模型体验或 API 额度的用户。

## 最低系统要求

- Windows 10 1809 或更高版本，或 Windows 11。
- x64 或 ARM64 系统。
- PowerShell 5.1 或更高版本。
- 物理内存 4 GB 以上。
- 可用网络连接。
- 用户自己的 DeepSeek API Key。
- WSL 功能仅供需要 Ubuntu 20.04 或更高版本环境的高级用户使用。

## 买家 ZIP 结构

以下是买家 ZIP 的实际内容。`support-feedback.txt`、`report.txt`、`logs/`、`backup/` 和 `reports/` 是运行后才可能生成的产物，不在初始 ZIP 中。

```text
00-点我开始安装.cmd
Start-Install.cmd
一键诊断.cmd
Run-Diagnostics.cmd
一键修复依赖.cmd
恢复或卸载配置.cmd
Restore-Config.cmd
01-先看我-安装说明.txt
02-安装完成后怎么开始使用.txt
03-常用提示词模板.txt
04-常见问题和售后.txt
README.md
LICENSE
Start-Here.ps1
install.ps1
configure-deepseek.ps1
doctor.ps1
uninstall-config.ps1
repair-deps.ps1
install_wsl.sh
提示词模板/
  00-先用这个-检查环境和项目.txt
  01-接手已有代码项目.txt
  02-补装开发环境和依赖.txt
  03-微信小程序开发.txt
  04-网页前端项目.txt
  05-Python脚本开发.txt
  06-安全修改代码.txt
  07-生成README和使用说明.txt
lib/
  bootstrap.ps1
  claude-install.ps1
  common.ps1
  config-writer.ps1
  deepseek-env.defaults.json
  env-check.ps1
  logger.ps1
  state.ps1
```

源码仓库还包含开发和验收内容；它们不属于买家 ZIP。不要根据源码仓库目录推断买家会收到额外文件。

## 安全与数据流

1. 本工具只负责在本机安装 Claude Code 和写入配置，不是本地大模型；“本地配置”不等于模型推理在本机运行。
2. API Key 由用户在本机输入，输入时不回显。配置写入 `%USERPROFILE%\.claude\settings.json`，修改前会在工具的运行目录中创建脱敏安全备份。
3. 使用 Claude Code 时，用户输入的提示词，以及 Claude Code 为完成任务选择、读取或提供给模型的相关代码、项目内容、命令输出、错误信息和工具结果，可能作为模型请求的一部分发送到配置的 API 地址。这不表示整个项目一定会上传。
4. 默认 API 地址是本工具当前配置的 DeepSeek 官方 API 地址。如果用户设置自定义 Base URL，相关请求内容和 API Key 都会发送到该自定义地址；用户必须自行确认其可信性和数据政策。
5. 安装工具不会把 API Key、项目代码或诊断材料上传到卖家服务器或项目作者服务器，但卖家和作者不能控制 DeepSeek 或其他模型提供者如何处理请求。请求的存储和处理以模型提供者的隐私政策和服务条款为准。
6. 不要让 AI 读取或处理不必要的密钥、凭据、隐私数据和生产数据。不要发送完整 API Key，也不要发送 `settings.json`。
7. 默认以普通用户身份运行。只有 Windows 对某个系统安装器明确弹出 UAC 时，用户才应核对文件和操作后决定是否允许；管理员权限不是通用修复方案。

## Windows 与 WSL

Windows 和 WSL 是两套独立环境，软件、命令路径和配置不会自动共享。Windows 入口负责 Windows 流程；`install_wsl.sh` 用于 WSL Ubuntu 环境。请在实际运行项目的环境中分别安装和验证。

## 网络与安装策略 v1.3.3

安装结果以后验验证为准，安装包 ExitCode 不直接决定成败。工具会结合命令可用性和 fresh shell（新开 PowerShell）验证判断结果；网络或备用安装方式的内部细节不需要普通买家手动处理。

售后只发送本工具解压目录中的必要脱敏文件，也就是与 `一键诊断.cmd` 同一个文件夹：优先发送 `support-feedback.txt`；如果没有，再发送同一文件夹中的 `report.txt`。不要发送 `backup/`、`logs/`、`reports/` 目录中的任何文件、`settings.json`、完整 API Key、私钥、密码、Cookie 或其他敏感文件。如果截图，请先确认截图里没有完整 API Key。

## 高级命令行用法

普通买家优先使用 `.cmd` 入口。需要明确控制时，可在本工具解压目录，也就是与 `一键诊断.cmd` 同一个文件夹运行：

```powershell
# 主菜单
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Here.ps1

# 仅配置 DeepSeek API Key
powershell -NoProfile -ExecutionPolicy Bypass -File .\configure-deepseek.ps1

# 安全诊断，不执行 API 测试，不自动打开报告
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -ShareSafe -SkipApiTest -NoOpenReport

# 检查依赖状态，不允许自动安装
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair-deps.ps1 -DryRun

# 配置恢复或卸载
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-config.ps1
```

WSL 中可运行：

```bash
bash ./install_wsl.sh
```

## 免责声明

本项目按现状提供。用户应自行保管账号、API Key 和项目数据，并对 API 费用、账户状态、网络环境、自定义地址及执行第三方命令的风险负责。Claude、Claude Code 和 DeepSeek 的服务能力、价格、限制与可用性以各自官方信息为准。

## License

本项目采用 [MIT License](LICENSE)。

## 官方链接

- [Claude Code 官方文档](https://code.claude.com/docs/en/overview)
- [DeepSeek API 官方文档](https://api-docs.deepseek.com/)
- [PowerShell 官方文档](https://learn.microsoft.com/powershell/)
- [WSL 官方文档](https://learn.microsoft.com/windows/wsl/)
