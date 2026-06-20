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
| H | 用户名含空格 | 任意 | Invoke-InstallCommandCaptured 参数不拆分 | **本次新增** | check.ps1: 运行级参数验证（含中文+空格路径） |
| I | TEMP 路径含空格 | 任意 | Invoke-InstallCommandCaptured 参数正确传递 | **本次新增** | check.ps1: 运行级参数验证 |
| J | 中文路径含空格 | 任意 | 参数保持完整（中文原文：中文 参数） | **本次新增** | check.ps1: 逐项精确比较 |
| K | Native Install / npm / winget 调用点参数转义 | official_native / npm_npmmirror / winget | ConvertTo-CommandLine + cmd.exe wrapper 正确转义 | **本次新增** | check.ps1 + ux-check.ps1: 源码级防回归 |
| L | Mock 决策矩阵 Native/npm 语义 | official_native / npm_npmmirror | DEC-002/003/009 修复后 10/10 | **本次新增** | install-decision-matrix.ps1: 10/10 |

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
- **验证层级**：`scripts/check.ps1` 运行级参数验证
- **已验证**：`Invoke-InstallCommandCaptured` 保持 `FilePath` 与参数分离，通过 `ConvertTo-CommandLine` 正确转义路径参数。含空格的测试目录中脚本正常执行。
- **未验证**：未运行真实 Native/winget/npm 安装。

### 场景 I：TEMP 路径含空格
- **前置条件**：`%TEMP%` 路径包含空格或中文
- **验证层级**：`scripts/check.ps1` 运行级参数验证
- **已验证**：测试目录名包含中文、空格、`&`、`!` 和字面量 `%PATH%`，其中脚本执行成功，ExitCode=0。
- **未验证**：未运行真实安装。

### 场景 J：中文路径
- **前置条件**：项目路径或 TEMP 路径包含中文字符
- **验证层级**：`scripts/check.ps1` 运行级逐项精确比较
- **已验证**：含中文参数"中文 参数"在 UTF-8 JSON 输出中保持原文，逐字符匹配通过且无乱码。
- **未验证**：未运行真实安装。

### 场景 K：Native Install / npm / winget 调用点参数转义
- **前置条件**：所有安装路径共用的 `Invoke-InstallCommandCaptured` 函数
- **验证层级**：`scripts/check.ps1` + `scripts/ux-check.ps1` 源码级防回归检查
- **已验证**：
  - 不使用裸 `-ArgumentList $Arguments` 数组
  - 调用 `ConvertTo-CommandLine` 进行参数转义
  - 使用 `Start-Process @startParams`，`FilePath` 不参与命令字符串拼接
  - 仅当 `Arguments.Count > 0` 时传入 `ArgumentList`
  - 不存在 cmd.exe wrapper、`!ERRORLEVEL!`、`$innerCommand`、`/v:on` 或 exitCodeFile
  - `WaitForExit()` + `Refresh()` 后读取 ExitCode，无法读取时返回 `-1`
  - CMD 元字符、百分号、感叹号、中文、引号、尾反斜杠和空字符串逐项保持参数边界
  - `hostname.exe` 使用真正的 `Arguments=@()`；`exit 7` 正确返回失败
  - finally 清理 stdout/stderr，超时保留 `taskkill /T /F`
  - `ConvertTo-CommandLineArgument` 处理尾部反斜杠
- **未验证**：未运行真实 Native/winget/npm 安装。

### 场景 L：Mock 决策矩阵 Native/npm 语义
- **前置条件**：CCDI_TEST_MODE=1 + CCDI_MOCK_INSTALL_DECISION=1
- **验证层级**：`scripts/install-decision-matrix.ps1` Mock 决策矩阵验证
- **已验证**：
  - DEC-002: Native 安装成功后信任 mock（不依赖安装前 broken 状态）→ 10/10
  - DEC-003: 同上
  - DEC-009: npm 安装 mock 失败正确返回 failed_official_and_mirror → 10/10
- **未验证**：未运行真实安装。

### 场景 M：validate 测试产物隔离
- **前置条件**：`CCDI_TEST_MODE=1`，validate 创建唯一 `CCDI_TEST_ARTIFACT_ROOT`
- **验证层级**：`scripts/check.ps1` + `scripts/ux-check.ps1` + `scripts/validate.ps1 -Mode Full`
- **已验证**：
  - child stdout/stderr、settings 备份、Core sandbox、doctor 报告和日志均写入 TEMP RunRoot
  - doctor 实际生成 `report.txt`、`support-feedback.txt`、`reports/report-*.txt`
  - 成功时删除 RunRoot，失败时保留并输出完整路径
  - 仓库既有 report/support-feedback/logs/reports/runs/backup 文件清单及 SHA256 不变
  - reports/runs 中的旧无效脚本不参与源码解析扫描
- **未验证**：未执行真实安装。

## 自动化验收命令

```powershell
# 基础自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
# UX 文案检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ux-check.ps1
# 用户路径模拟（含场景 A-G）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\simulate-user-release.ps1 -Version "1.3.3"
```
