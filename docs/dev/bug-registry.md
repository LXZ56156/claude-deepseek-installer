# Bug Registry

## 2026-06-22 ConPTY VM acceptance hardening

| ID | Problem | Root cause | Fix | Regression |
|---|---|---|---|---|
| ACC-001 | Desktop test projects and installer state escaped baseline checks | Tracked roots omitted `ClaudeCode-Test-*`, `.claude-deepseek-installer`, and `.claude.json` | Added exact and timestamp-pattern roots | Functional cleanup test |
| ACC-002 | Modified and removed files were not restored | Cleanup only processed `CreatedPaths` and baseline stored hashes only | Capture baseline bytes per RunId and restore owned Modified/Removed paths | Created/Modified/Removed byte test |
| ACC-003 | Fault injection polluted later PATH resolution | Setup prepended fault-bin to process/user PATH without restoring it | Save and restore process/user/machine PATH and delete fault-bin | Consecutive command-resolution test |
| ACC-004 | Concurrent runs could overwrite baseline and resume data | No exclusive lock and shared baseline directory | Exclusive ControlRoot lock and RunId-specific baseline | Second-instance rejection test |
| ACC-005 | Cleanup treated every new package/service/task as owned | Ownership was inferred only from before/after difference | Require explicit scenario registration; unregistered changes are reported without removal | Unregistered package no-uninstall test |
| ACC-006 | Resume lost parameters and earlier results | State omitted CredentialTarget and result collections | Serialize full resume state and merge prior results | Resume round-trip test |
| ACC-007 | Restore coverage only removed configuration | No scenario invoked the restore menu and checked the restored bytes | Added TestSafe and Live restore scenarios with SHA256 assertion | TestSafe restore interaction |
| ACC-008 | Timeout discarded stdout/stderr evidence | `Invoke-VmStage` threw immediately after `taskkill` | Drain readers and write stdout/stderr/result metadata before throwing | Timeout evidence test |

## 检查覆盖索引

| ID | 修复函数 | test-vm-acceptance.ps1 断言 | check.ps1 防回归 | 需专用 VM Live |
|---|---|---|---|---|
| ACC-001 | `Get-AcceptanceKnownRoots` (AcceptanceEnvironment.ps1) | desktop variants and state roots are tracked and cleaned | 场景数 16 + 功能测试（`-AcceptanceFunctional`） | 否（host 已验证） |
| ACC-002 | `Restore-AcceptanceTrackedPath` / `Reset-AcceptanceEnvironment` + RunId 基线字节 | created/modified/removed rollback succeeds + restores exact file bytes | 功能测试（`-AcceptanceFunctional`）+ synthetic `ProcessPath` 字段 | 否 |
| ACC-003 | `Start/Stop-LiveScenarioSetup` + PATH 适配器（`New-VmPathAdapter`/`New-VmSandboxPathAdapter`/`Get/Set-VmAdapterPath`/`Resolve-VmAdapterNpm`） | fault PATH 全程沙盒 + 真实 PATH 不变 + fault-bin 删除 | 功能测试（`-AcceptanceFunctional`） | 否（沙盒；真实故障注入属 Live） |
| ACC-004 | `Enter-AcceptanceInstanceLock` + `runs/<RunId>/baseline` | single instance rejects second owner | 功能测试（`-AcceptanceFunctional`） | 否 |
| ACC-005 | `Reset-AcceptanceEnvironment` ownership 检查（`UNOWNED_*`） | unregistered package is reported and not uninstalled | 功能测试（`-AcceptanceFunctional`） | 否 |
| ACC-006 | `New-VmResumeState` + `Import-AcceptanceResumeResults` / `Write/Read-AcceptanceResumeState` | resume state and prior results round-trip | 功能测试（`-AcceptanceFunctional`） | 真实重启续跑待 VM（仅 round-trip 已证） |
| ACC-007 | `setupRestoreConfig` 场景 + SHA256 断言 + scenarios.json restore 场景 | TestSafe `restore-config-backup` PASS（host 实跑 6.87s） | 场景数 16/8 + 功能测试 | Live `live-restore-deepseek-config` 未运行（静态核对） |
| ACC-008 | `Invoke-VmStage` finally 写 stdout/stderr/result | timeout preserves stdout stderr and metadata | 功能测试（`-AcceptanceFunctional`） | 否 |

## 状态（截至 2026-06-22）

- TestSafe 功能测试（`scripts/test-vm-acceptance.ps1`）：**24/24 通过**，在 host 实跑。沙盒化后不修改真实 User/Machine/Process PATH、真实 USERPROFILE、真实 settings.json；finally 不再写回真实 User PATH。
- TestSafe `restore-config-backup` 场景：**通过**（host 实跑 6.87s），真实 settings.json 前后 SHA256 一致。
- `check.ps1`：功能测试门控于 `-AcceptanceFunctional`；默认 Smoke 仅静态检查（ConPTY 驱动编译 + 场景定义校验 + synthetic 快照字段），无真实环境副作用。
- `vm-final-acceptance.ps1 -Mode TestSafe`：静态校验阶段调用沙盒化功能测试作为首个 stage。
- `vm-final` final-equivalence（所有场景后的最终基线等价检查）：仍严格检查文件、包、服务、任务和相关进程。主机曾观察到 `.claude.json` 并发变化，但在专用 VM 复验前不预先判定为外部噪声或代码缺陷；必须保留失败证据并继续调查，不得自动忽略。
- Live 场景（8 个）：**未运行**。仅定义 + 静态核对；需专用 Win11 VMware + 管理员 + `C:\CCDI-ACCEPTANCE-VM.marker` + `-AcknowledgeRealInstall`。
- 真实重启续跑：**未运行**。自动重启还必须独立传入 `-AcknowledgeRestart`；TestSafe 永不允许重启。round-trip 已验证保存下一场景索引、`resume-cleanup-pending`、历史结果和任务参数，但真实重启仍须专用 VM 复验。

## 2026-06-23 Resume and safety review fixes

| ID | Problem | Root cause | Fix | Regression |
|---|---|---|---|---|
| ACC-009 | Resume repeated the completed scenario | Locked cleanup saved the current loop index and resume ignored phase | Save `index + 1`; resume phase completes pending cleanup before entering the next scenario | Resume round-trip and source gate |
| ACC-010 | TestSafe could reach forced restart | Locked-path handling had no mode-specific restart authorization | Require Live plus real-install and independent restart acknowledgements; failure cleanup never auto-restarts | Two restart authorization tests |
| ACC-011 | Residual processes could still pass | Unowned processes were reports and final equivalence omitted processes | Make unowned residual processes cleanup errors and compare process snapshots | Residual process behavioral test |
| ACC-012 | Functional cleanup rewrote real User PATH | `finally` always persisted the captured string | Remove the persistent write; sandbox adapter remains the only PATH mutation | Real PATH unchanged assertions |
| ACC-013 | Human summary overstated passed scenarios | Summary used total result count | Count PASS and non-PASS results separately in JSON and text | Static source gate |
| ACC-014 | Successful TestSafe exited after all 16 scenarios | Deleting nonexistent resume tasks emitted native stderr under terminating error policy | Use bounded captured `schtasks.exe` deletion and accept missing tasks | Functional no-task cleanup test |
