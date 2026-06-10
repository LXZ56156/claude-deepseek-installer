# Windows 真实机器验收矩阵

> 面向发布前手工真机/VM 验收。自动化已覆盖的场景标记为 AUTO/MOCK；
> 仍需手工验收的场景标记为 MANUAL。
> WSL 暂缓，本次不改。

## 场景概览

| # | 场景 ID | 场景描述 | 自动化等级 | 手工验收 |
|---|---------|---------|-----------|---------|
| 1 | WIN-REAL-001 | 干净 Windows 10/11，无 Node.js/npm/Claude Code | 部分 MOCK | 必须 |
| 2 | WIN-REAL-002 | Windows 已安装 Claude Code | 部分 MOCK | 建议 |
| 3 | WIN-REAL-003 | Windows settings.json 损坏 | AUTO | 可选 |
| 4 | WIN-REAL-004 | 阻断 claude.ai 但允许 registry.npmmirror.com | MOCK | 必须 |
| 5 | WIN-REAL-005 | Windows 无 winget | MOCK | 建议 |
| 6 | WIN-REAL-006 | Windows npm PATH 未刷新 | MANUAL | 必须 |
| 7 | WIN-REAL-007 | ZIP 未完整解压，直接从压缩包临时目录运行 | AUTO + MANUAL | 建议 |
| 8 | WIN-REAL-008 | 中文用户名 / 中文路径 / 带空格路径 | 部分 AUTO | 必须 |
| 9 | WIN-REAL-009 | 已有自定义 permissions/hooks/mcpServers/env 配置 | AUTO | 可选 |
| 10 | WIN-REAL-010 | 卸载 DeepSeek 配置后恢复 | AUTO | 建议 |

## 详细验收步骤

### WIN-REAL-001：干净 Windows 10/11 全新安装

**前置条件**：
- Windows 10 1809+ 或 Windows 11
- 无 Node.js、npm、Claude Code
- 无 %USERPROFILE%\.claude\settings.json

**操作**：
1. 下载 release ZIP 并完整解压到 D:\ClaudeDeepSeek
2. 双击「开始安装.cmd」
3. 按提示完成 7 步安装流程
4. 观察是否自动检测到 Node.js 缺失并给出指引
5. 手动安装 Node.js 18+ LTS 后重新运行
6. 观察是否走 npm npmmirror 镜像安装
7. 安装后输入 DeepSeek API Key 完成配置
8. 运行「一键诊断.cmd」生成 report.txt

**预期**：
- [ ] 无 ParserError
- [ ] 中文显示正常，无乱码
- [ ] Node.js 缺失时给出明确手动安装指引
- [ ] npm mirror 安装后 claude --version 正常
- [ ] DeepSeek 配置写入 %USERPROFILE%\.claude\settings.json
- [ ] 诊断报告脱敏正确
- [ ] 安装报告记录安装方式和状态

**自动化覆盖**：MOCK (install-decision-matrix.ps1 DEC-006)

---

### WIN-REAL-002：Windows 已安装 Claude Code

**前置条件**：
- Windows 已安装 Claude Code（真实安装）
- %USERPROFILE%\.claude\settings.json 已有自定义配置

**操作**：
1. 双击「开始安装.cmd」
2. 观察是否检测到 claude 已安装
3. 确认跳过安装步骤
4. 检查 settings.json 未被覆盖

**预期**：
- [ ] 显示 "Claude Code 已安装" 并跳过
- [ ] 不触发官方安装或 npm 安装
- [ ] 已有配置未被修改
- [ ] 安装状态 state.json 记录 Method=existing

**自动化覆盖**：MOCK (install-decision-matrix.ps1 DEC-001)

---

### WIN-REAL-003：settings.json 损坏

**前置条件**：
- %USERPROFILE%\.claude\settings.json 存在但内容为无效 JSON
- 例如写入 `{ bad json`

**操作**：
1. 手动破坏 settings.json
2. 运行配置流程或诊断
3. 观察 JSON 解析错误提示

**预期**：
- [ ] 提示 JSON 格式无效
- [ ] 自动备份损坏文件到 backup/
- [ ] 询问是否重建配置
- [ ] 重建后仅覆盖 env 字段，尽量保留其他字段

**自动化覆盖**：AUTO (simulate-user-release.ps1 corrupt JSON flow)

---

### WIN-REAL-004：阻断 claude.ai 但允许 npmmirror

**前置条件**：
- 在 hosts 或防火墙上阻断 claude.ai 和 downloads.claude.ai
- 允许 registry.npmmirror.com

**操作**：
1. 双击「开始安装.cmd」
2. 观察是否检测到官方通道不可用
3. 观察是否自动切换到 npmmirror
4. 观察提示信息是否说明 fallback 原因

**预期**：
- [ ] 检测到官方通道不可用并明确提示
- [ ] 自动切换 npmmirror 国内镜像
- [ ] 日志记录 fallback 原因
- [ ] npm mirror 安装成功

**自动化覆盖**：MOCK (install-decision-matrix.ps1 DEC-005)

---

### WIN-REAL-005：Windows 无 winget

**前置条件**：
- Windows 无 winget（如 Windows 10 LTSC 或旧版）

**操作**：
1. 确保 Node.js 未安装
2. 双击「开始安装.cmd」
3. 观察 Node.js 缺失时的处理

**预期**：
- [ ] 不静默安装任何软件
- [ ] 不误报安装成功
- [ ] 提示手动安装 Node.js LTS
- [ ] 给出下载地址 https://nodejs.org

**自动化覆盖**：MOCK (install-decision-matrix.ps1 DEC-010)

---

### WIN-REAL-006：npm PATH 未刷新

**前置条件**：
- 已安装 Node.js 但当前终端 PATH 未包含 npm
- 例如：刚安装 Node.js 未重启终端

**操作**：
1. 模拟 PATH 未刷新状态
2. 双击「开始安装.cmd」
3. 观察 npm 检测结果

**预期**：
- [ ] 检测到 npm 不可用
- [ ] 提示"关闭并重新打开 PowerShell"
- [ ] 不误判为 npm 未安装

**自动化覆盖**：MANUAL（需真实 PATH 环境）

---

### WIN-REAL-007：ZIP 未完整解压

**前置条件**：
- 在压缩包预览窗口中直接双击 .cmd
- 或只解压了部分文件

**操作**：
1. 只复制单个 .cmd 到空目录
2. 双击该 .cmd

**预期**：
- [ ] 提示"请先完整解压 ZIP"
- [ ] 给出具体解压步骤
- [ ] 不闪退

**自动化覆盖**：AUTO (simulate-user-release.ps1 missing file test) + MANUAL（真实压缩包双击）

---

### WIN-REAL-008：中文用户名 / 带空格路径

**前置条件**：
- Windows 用户名为中文
- 或项目路径包含中文、空格

**操作**：
1. 解压到 D:\中文 路径\ClaudeDeepSeek
2. 双击「开始安装.cmd」
3. 观察中文显示和路径处理

**预期**：
- [ ] 路径风险检测不误报中文路径
- [ ] 带空格路径给出 WARN 但允许继续
- [ ] 中文界面显示正常（PowerShell 5.1 + UTF-8 BOM）
- [ ] .cmd 启动器正常（纯 ASCII）

**自动化覆盖**：部分 AUTO (check.ps1 path risk matrix, simulate path test)

---

### WIN-REAL-009：已有自定义配置

**前置条件**：
- %USERPROFILE%\.claude\settings.json 已有自定义 permissions、hooks、mcpServers、自定义 env

**操作**：
1. 运行 DeepSeek 配置写入
2. 检查 settings.json 变化

**预期**：
- [ ] permissions、hooks、mcpServers 保留
- [ ] 自定义 env（非 DeepSeek 字段）保留
- [ ] 仅覆盖 DeepSeek 相关 env 字段
- [ ] 旧配置已备份

**自动化覆盖**：AUTO (simulate-user-release.ps1 custom config flow, ux-check.ps1)

---

### WIN-REAL-010：卸载 DeepSeek 配置后恢复

**前置条件**：
- settings.json 同时有 DeepSeek env 和自定义配置

**操作**：
1. 运行「恢复或卸载配置.cmd」
2. 选择"移除 DeepSeek 配置"
3. 检查 settings.json
4. 选择"从备份恢复最新配置"
5. 检查恢复结果

**预期**：
- [ ] RemoveDeepSeekEnv 后仅移除 DeepSeek 字段
- [ ] 自定义字段完整保留
- [ ] 备份文件在 backup/ 目录
- [ ] RestoreLatest 后完整恢复
- [ ] 多次备份不互相覆盖

**自动化覆盖**：AUTO (simulate-user-release.ps1 uninstall flow)

---

## 环境限制说明

以下情况可记录为环境限制，不影响发布判定：

- 本机无 WSL → Windows 主流程不受影响
- 本机无 pwsh → PowerShell 7 检查自动跳过
- 本机无 VS Code → code CLI 检查自动跳过
- 国内网络 claude.ai 不通 → 预期行为，验证 fallback 是否生效

以下情况不可放过：

- 真实 settings.json 被修改
- 安装流程崩溃或闪退
- .cmd 启动器乱码
- 中文显示异常
- API Key 泄露到日志/报告/控制台
- release ZIP 包含敏感文件

## WSL 声明

本次所有改动仅限 Windows 侧验收体系。WSL 相关：

- install_wsl.sh 未修改
- scripts/check.sh 未修改
- scripts/ux-check.sh 未修改
- WSL 安装逻辑未改动
- WSL 场景标记为「暂缓/后续处理」

## 参考

- `docs/验收与交接体系.md` — 完整验收体系说明
- `docs/发布前验收清单.md` — 发布前验收命令
- `docs/v1.3.2-rc-验收与修复交接.md` — 当前版本验收状态
