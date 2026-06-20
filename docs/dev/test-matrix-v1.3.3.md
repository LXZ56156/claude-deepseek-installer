# v1.3.3 安装场景测试矩阵

> **注意**：此文件仅供开发参考，不进入 release ZIP allow-list。

## 场景总览

| 场景 | 环境 | 预期安装方式 | 预期结果 | 真机状态 | 自动化覆盖 |
|------|------|-------------|---------|---------|-----------|
| A | 干净 Windows + 官方可直连 + 无 Node | official_native | 完整成功 | 已通过 | simulate: TestSafe existing flow |
| B | 官方不可用 + 无 Node/npm | npm_npmmirror | 完整成功 | 已通过（已修 UX） | simulate: Scenario B |
| C | 官方不可用 + 已有 Node/npm | npm_npmmirror | 完整成功 | 待真机 | simulate: Scenario C |
| D | 已有 Claude + 无配置 | existing | 只配置 DeepSeek | 待真机 | simulate: Scenario D |
| E | Native 已安装但 PATH 缺失 | existing_native | 自动修 PATH | 待真机 | simulate: static check |
| F | API Key 错误/余额不足 | 任意 | 安装成功 / API 失败提示清楚 | 已通过（mock） | simulate: Scenario F |
| G | npm 未知 ExitCode + 后续可用 | npm_npmmirror | Success=true | 已通过（已修 WCCR） | simulate: Scenario G |
| H | 用户名含空格 | 任意 | 正常安装 | **本次新增** | check.ps1 + ux-check.ps1 运行级测试 |
| I | TEMP 路径含空格 | 任意 | Invoke-InstallCommandCaptured 参数不拆分 | **本次新增** | check.ps1 + ux-check.ps1 运行级测试 |
| J | 中文路径 | 任意 | 参数正确传递 | **本次新增** | check.ps1 + ux-check.ps1 运行级测试 |
| K | Native Install 临时脚本路径含空格 | official_native | ConvertTo-CommandLine 正确转义 | **本次新增** | check.ps1 源码级检查 |
| L | npm.cmd / winget 参数不回归 | npm_npmmirror / winget | 参数数组通过 ConvertTo-CommandLine 转为安全命令行 | **本次新增** | check.ps1 源码级检查 |

## 场景详情

### 场景 A：官方 Native Install 完整成功
- **前置条件**：Windows 干净安装，无 Node.js/npm，Claude Code 官方服务器可达
- **预期流程**：Native Install 下载并执行脚本 → 自动配置 DeepSeek → API 测试通过
- **关键断言**：
  - `result.Method = "official_native"`
  - `result.Success = $true`
  - Node.js/npm 缺失不导致失败（安装方式无需）
  - Report overall = 完整成功

### 场景 B：官方不可用 + 无 Node → npm 镜像
- **前置条件**：官方服务器不可达，无 Node.js/npm
- **预期流程**：winget 安装 Node.js → npm 镜像安装 Claude Code → 验证通过
- **关键断言**：
  - `result.Method = "npm_npmmirror"`
  - 不出现"先诊断再成功"的终端顺序
  - Report method = "备用下载方式（npm 镜像）"

### 场景 C：官方不可用 + 已有 Node/npm → npm 镜像
- **前置条件**：官方不可达，Node.js/npm 已安装
- **预期流程**：跳过 Node.js 安装 → 直接 npm 镜像安装 Claude Code
- **关键断言**：
  - 不安装 Node（无需 winget）
  - `result.Method = "npm_npmmirror"`

### 场景 D：已有 Claude + 无配置
- **前置条件**：Claude Code 已安装，settings.json 不存在
- **预期流程**：跳过 Claude 安装 → 配置 DeepSeek → API 测试
- **关键断言**：
  - 不重装 Claude
  - `Method = "existing"` 或 `"existing_native"`
  - ConfigWritten = true

### 场景 E：Native exe 存在但 PATH 缺失
- **前置条件**：`%USERPROFILE%\.local\bin\claude.exe` 存在但不在 User PATH
- **预期流程**：检测到方法为 existing_native → 调用 Ensure-UserPathEntry
- **关键断言**：
  - `Ensure-UserPathEntry` 被调用
  - Fresh PowerShell 成功后完整成功

### 场景 F：API Key 无效
- **前置条件**：Claude 安装成功，DeepSeek API Key 错误/余额不足/网络不通
- **预期流程**：Claude 安装成功 → 配置写入 → API 测试失败 → 提示清晰
- **关键断言**：
  - 不误报 Claude 安装失败
  - ConfigWritten = true
  - ApiTestFailed = true
  - 下一步建议指向 Key/余额/网络

### 场景 G：npm 安装返回未知 ExitCode 但后续可用
- **前置条件**：npm 镜像安装返回非零 ExitCode（或空 ExitCode）
- **预期流程**：npm 安装 → Wait-ClaudeCommandReady 等待 → 确认可用
- **关键断言**：
  - Success = true
  - Method = npm_npmmirror
  - 不前台输出"请运行一键诊断"后又成功

### 场景 H：用户名含空格
- **前置条件**：Windows 用户名包含空格（如 `C:\Users\Test User\`）
- **预期流程**：所有安装路径（Native/npm/winget）正常执行
- **关键断言**：
  - Invoke-InstallCommandCaptured 使用 ConvertTo-CommandLine 转义参数
  - 含空格的路径不会被 Start-Process 拆分为多个参数
  - 所有参数数量和内容完全一致

### 场景 I：TEMP 路径含空格
- **前置条件**：`%TEMP%` 路径包含空格或中文
- **预期流程**：临时脚本路径正确传递给子进程
- **关键断言**：
  - ConvertTo-CommandLineArgument 正确处理含空格路径
  - 子进程可找到并执行临时脚本
  - ExitCode = 0

### 场景 J：中文路径
- **前置条件**：项目路径或 TEMP 路径包含中文字符
- **预期流程**：所有命令参数正确传递
- **关键断言**：
  - 含中文的参数在子进程中保持完整
  - PowerShell 5.1 下中文不乱码
  - stdout/stderr 捕获正常

### 场景 K：Native Install 临时脚本路径含空格
- **前置条件**：`$env:TEMP\claude_native_install_*.ps1` 路径含空格
- **预期流程**：Native Install 调用 `Invoke-InstallCommandCaptured -FilePath powershell -Arguments @("-NoProfile", ..., "-File", $tempInstallScript)`
- **关键断言**：
  - ConvertTo-CommandLine 正确转义 `-File "C:\Users\Test User\..."` 参数
  - 不再使用裸 `-ArgumentList $Arguments` 数组
  - 使用 `Start-Process @startParams` 条件传入 ArgumentList

### 场景 L：npm.cmd / winget 参数不回归
- **前置条件**：现有 npm 和 winget 安装路径已有正确的参数数组
- **预期流程**：ConvertTo-CommandLine 对所有参数数组生效
- **关键断言**：
  - npm 参数（`install`, `-g`, `@anthropic-ai/claude-code`, `--registry=...`）正确转义
  - winget 参数（`install`, `--id`, ...）正确转义
  - 不含空格/特殊字符的普通参数行为不变
  - 空数组时不传 ArgumentList

## 自动化验收命令

```powershell
# 基础自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
# UX 文案检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ux-check.ps1
# 用户路径模拟（含场景 A-G）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\simulate-user-release.ps1 -Version "1.3.3"
```
