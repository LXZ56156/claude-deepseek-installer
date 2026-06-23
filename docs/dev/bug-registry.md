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

## 状态（截至 2026-06-23）

- TestSafe 功能测试（`scripts/test-vm-acceptance.ps1`）：**112/112 通过**，在 host 实跑。沙盒化后不修改真实 User/Machine/Process PATH、真实 USERPROFILE、真实 settings.json；包含 `.claude` 精确跟踪、resume pending cleanup、checkpoint 删除、下一场景执行、SchemaVersion 3 完整结构校验、场景前缀顺序校验、任务注册/删除/报告失败、最终 lifecycle 失败路径、bounded command timeout evidence 和锁释放测试。
- 完整 TestSafe 交互验收（16 个场景 + ConPTY driver self-tests）：**通过**，使用隔离 release ZIP（36 entries、8 prompt templates）和带空格的 runroot。
- TestSafe `restore-config-backup` 场景：**通过**（host 实跑 6.87s），真实 settings.json 前后 SHA256 一致。
- `check.ps1`：功能测试门控于 `-AcceptanceFunctional`；默认 Smoke 做静态检查（ConPTY 驱动编译、UTF-8/stateful decoder、场景定义校验、synthetic 快照字段 + release allow-list/functional-gate 源码防回归），无真实环境副作用。
- `vm-final-acceptance.ps1 -Mode TestSafe`：静态校验阶段调用沙盒化功能测试作为首个 stage，TestSafe release ZIP 写入 run 目录下的隔离 output，不覆盖仓库 `release/`。
- `vm-final` final-equivalence（所有场景后的最终基线等价检查）：仍严格检查文件、包、服务、任务和相关进程；`.claude` 下除 `_git_cache.json` 外都纳入基线。主机曾观察到 `.claude.json` 并发变化，但在专用 VM 复验前不预先判定为外部噪声或代码缺陷；必须保留失败证据并继续调查，不得自动忽略。
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
| ACC-015 | Resume task deletion failures were ignored | Every nonzero `schtasks.exe` result was treated as a missing task | Use Task Scheduler COM existence checks; only HRESULT `0x80070002` is missing, while timeout, permission, or delete failure preserves state/report and blocks | Real missing-task probe + injected access-denied deletion test |
| ACC-016 | Old resume schemas could execute new control flow | State reader did not validate `SchemaVersion` | Accept only SchemaVersion 3 with an explicit clean-and-restart message | Legacy schema rejection test |
| ACC-017 | Completed pending cleanup left a stale checkpoint | Resume startup kept state and never removed it after equivalence | Delete the old checkpoint only after cleanup and task verification succeed | Resume control-flow gate |
| ACC-018 | Resume tests did not execute control flow | Tests covered serialization only | Production helper now drives pending cleanup and next-index selection; test executes only scenarios after the saved index | Pending-cleanup control-flow test |

## 2026-06-23 VM final acceptance closure fixes

| ID | Problem | Root cause | Fix | Regression |
|---|---|---|---|---|
| ACC-019 | Resume registration could leave partial tasks or overwrite an unrelated checkpoint | State write, user task, bootstrap, system task and verification were not treated as one transaction | Added injected transactional registration, preexisting task/state rejection, persisted-state re-read, exact task verification and rollback evidence | Registration state/user/bootstrap/system/verify/report fault matrix |
| ACC-020 | Resume cleanup could delete evidence or report success after task deletion failures | Task query/delete/report operations were not fail-closed and report write failure could strand an unverified state | Added strict task existence/delete probes, bootstrap/state post-delete verification, state-byte restore on report failure and idempotent evidence | Cleanup query/timeout/nonzero/still-exists/state/bootstrap/report/KeepState tests |
| ACC-021 | Resume state schema accepted incomplete or reordered history | Only SchemaVersion was checked, so scenario arrays could be truncated, out of order, wrong mode or structurally incomplete | Added full SchemaVersion 3 object validation, array shape preservation, scenario prefix/order validation and TestSafe/Live mode separation | Schema invalid-field matrix + scenario prefix order tests |
| ACC-022 | Final acceptance could leave stale resume state or zero exit after evidence/summary failure | Evidence write, final resume cleanup and summary publication were independent best-effort operations | Added `Complete-VmAcceptanceLifecycle` and transactional summary writes; PASS requires evidence, cleanup and PASS summary success | Final evidence/cleanup/summary/PriorError/lock tests |
| ACC-023 | Static validation could pollute the Live clean-install baseline | Full/Release/Hardcore/build ran before the scenario baseline without guarding PATH, settings or command availability | Added static guard snapshot/restore and Live post-static clean `claude/node/npm` recheck | Static source gate + real PATH/settings unchanged functional assertions |
| ACC-024 | ConPTY driver could miss fatal text, hang on large output, or fail Chinese prompts on localized hosts | Scan loop only read cumulative output, final output was not checked against failure patterns, pseudo-console bytes were decoded with the system ANSI codepage, and final scan could read before the output thread drained | Added incremental output reads, bounded scan buffer, final fatal scan, stateful UTF-8 ConPTY decoding with legacy fallback, pseudo-console close/read-drain before final scan, large-output/split-prompt self-test and safe relative scenario entry validation | Driver self-tests + TestSafe scenario smoke + static UTF-8/drain gate |
| ACC-025 | Release build gates could pass with missing files, stale ZIPs or unsafe failure cleanup | Output directory could be recursively deleted on failure, allow-list copied directories, scans could skip errors, and SHA failure was non-fatal | Build now removes only target artifacts/temp staging, requires exact leaf allow-list, fails closed on scan/SHA errors, checks 36 entries and 8 prompt templates | `build-release.ps1` isolated output probe + static no-OutputDir-delete check |
| ACC-026 | Validation could appear green without functional VM acceptance coverage | Full did not run `test-vm-acceptance.ps1`, Release reused project `release/`, and matrix simulation could be assumed without the prior step passing | Full now runs the functional acceptance test; Release uses isolated output and only passes matrix assumption after simulation success | `validate.ps1` source gate + Full validation |
| ACC-027 | Windows scenario matrix command execution was vulnerable to quoting and wrapper artifacts | It used a `cmd.exe /c` wrapper with redirected temp files | Replaced wrapper with direct `powershell.exe` `ProcessStartInfo`, native argument quoting, async stdout/stderr and bounded process-tree kill | AST parse + matrix smoke |
| ACC-028 | Baseline cleanup missed `.claude` state and could kill a reused PID | `.claude` tracking only included `settings.json`, and process cleanup trusted PID alone | Track all `.claude` files except `_git_cache.json`; verify Name/ExecutablePath/CommandLine/CreationDate before stopping owned PIDs | `.claude` cleanup test + residual process test |
| ACC-029 | `vm-final` could fail baseline collection on busy hosts without useful timeout evidence | `winget export` was bounded at 60s and the generic captured-command timeout path discarded partial stdout/stderr | Increased the winget inventory bound to 180s and preserved timeout stdout/stderr before returning failure | Captured-command timeout evidence test + static timeout gate |

## 2026-06-23 覆盖索引增量

| ID | 修复函数/脚本 | test-vm-acceptance.ps1 断言 | check.ps1 防回归 | 需专用 VM Live |
|---|---|---|---|---|
| ACC-019..021 | `Register-AcceptanceResume` / `Read-AcceptanceResumeState` / `Import-AcceptanceResumeResults` | registration fault matrix; Schema 3 invalid-field matrix; scenario prefix order | resume schema + registration helper source gate; `-AcceptanceFunctional` | 真实重启任务执行待 VM |
| ACC-020 | `Remove-AcceptanceResume` | cleanup query/timeout/nonzero/still-exists/state/bootstrap/report/KeepState | cleanup evidence/static strings + `-AcceptanceFunctional` | 真实 Task Scheduler 权限异常待 VM |
| ACC-022 | `Complete-VmAcceptanceLifecycle` / `Write-VmSummaryArtifactsTransactional` | final evidence/cleanup/summary/PriorError/lock assertions | lifecycle source gate | 否 |
| ACC-023 | `Get/Compare/Restore-VmStaticGuardSnapshot` / `validate.ps1` isolated release output | real User/Machine/Process PATH and settings unchanged | static guard + functional stage source gate | Live clean baseline recheck待 VM |
| ACC-024 | `interactive-user-acceptance.ps1` / `ConPtyAcceptanceHost.cs` | driver self-test and TestSafe scenario smoke | ConPTY static compile + UTF-8/stateful decoder + final output drain + prompt driver source gate | 否 |
| ACC-025..027 | `build-release.ps1` / `simulate-user-release.ps1` / `sandbox-full-user-simulation.ps1` / `windows-scenario-matrix.ps1` | not in functional test; covered by release probes | exact 36 ZIP entries, 8 prompts, isolated output, direct process invocation gates | 否 |
| ACC-028 | `Get-AcceptanceFileState` / `Reset-AcceptanceEnvironment` | `.claude` state cleanup and residual process identity tests | functional gate | 否 |
| ACC-029 | `Invoke-AcceptanceCapturedCommand` / `Get-AcceptanceWingetPackages` | captured command timeout preserves stdout/stderr evidence | stdout/stderr timeout wait + winget 180s source gate | 否 |
