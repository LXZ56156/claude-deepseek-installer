# AGENTS.md

本文件是会话级交接文件。**每次新会话开始必读**。CLAUDE.md 是持久化项目知识，本文是动态上下文。

---

## Active Work

- **Branch**: `fix/v1.3.3-native-path-doctor-ux`
- **Status**: VM acceptance final closure implemented on host: transactional resume registration/cleanup, strict SchemaVersion 3 prefix validation, UTF-8 ConPTY driver, static machine-state guard, transactional final summary, isolated TestSafe release output, redacted release API-key scan diagnostics, scenario/step final failureText scan, evidence-gated resume cleanup, release and Live command-collection StrictMode scalar Count fixes, Release Scenario B isolated mock Claude TestSafe fix, TestSafe API Key browser-open guard, ConPTY responder-count PowerShell 5.1 fix, whole-source parenthesized if/switch assignment gate, Scenario 4 API Key prompt regex fix, all sendSecret prompt anchoring guard, Live ownership optional-property and pre-stage cleanup fix, fallback install restart-dependency closure, and deep-audit closure: diagnostic entrypoints default to `-ShareSafe -SkipApiTest -NoOpenReport`, `Invoke-CommandSafe` has direct plus environment-isolated batch runners, release simulation covers中文/space/`&`/`!`/parentheses extraction paths, and Live setup/scenario gates cover Node PATH refresh, stage timeout overhead, and official-only fallback detection. Source-side check, UX check, VM-acceptance functional, Smoke, Release, and Full validations pass in this session. Current non-dedicated host `vm-final -Mode TestSafe` is blocked before scenarios by active `.claude`/node noise; previous isolated TestSafe interactive scenarios pass. Dedicated VM Live and real reboot remain pending.
- **Next**: 在专用 Win11 VMware 验收机执行 TestSafe final-equivalence、Live（8 场景）和真实重启续跑；在该机复验 vm-final final-equivalence（主机无其他 Claude 会话时不复现噪声）。Do not merge/tag/release until VM Live + real-reboot resume pass.
- **Latest commit**: run `git log -1 --oneline`; this file does not self-reference a commit SHA because that would change the commit itself.

---

## Progress Log

保留最近 ~10 条（完整历史在 `git log`）。旧条目直接删除即可。

| 日期 | 内容 | Commit |
|------|------|--------|
| 2026-06-24 | Deep audit closure — safe diagnostic defaults, Invoke-CommandSafe direct/batch runners, special-path release simulation, Live setup/fallback gates | 本提交 |
| 2026-06-24 | Fallback install restart-dependency closure — Node/npm fixed-path verification, explicit Node failure, Claude fixed-path postchecks, Start-Here continuation, Live failureText gates | 本提交 |
| 2026-06-24 | Live ownership StrictMode/pre-stage cleanup closure — optional props guarded and failure cleanup has scenario ownership | 本提交 |
| 2026-06-24 | sendSecret prompt anchoring closure — TestSafe and Live secret steps require actual Read-Host prompt regex | 本提交 |
| 2026-06-24 | Scenario 4 API Key prompt regex closure — sendSecret waits for actual Read-Host prompt | 本提交 |
| 2026-06-24 | Whole-source PS5.1 statement-expression gate — tracked PowerShell files forbid `= (if` / `= (switch` | 本提交 |
| 2026-06-24 | ConPTY responder-count PS5.1 closure — Scenario 3 runner no longer uses parenthesized if assignment | 本提交 |
| 2026-06-24 | TestSafe API Key browser-open guard — Step 3 no longer starts real URL under ConPTY TestSafe | 本提交 |
| 2026-06-23 | Release Scenario B TestSafe mock Claude closure — WCCR no longer depends on host claude/node/npm | 本提交 |
| 2026-06-23 | Live StrictMode scalar command-count closure — safe 0/1/N helper, same-class scan fixes, 119 functional checks | 本提交 |
| 2026-06-23 | Remote review closure — API Key scan redaction, scenario/step final failureText scan, evidence-gated resume cleanup, release StrictMode scalar Count fix, 113 functional checks | 本提交 |
| 2026-06-23 | VM acceptance closure — transactional lifecycle, strict resume prefix schema, UTF-8 ConPTY driver, winget baseline evidence, static state guard, isolated release output, 112 functional checks, 16 TestSafe interactive scenarios | 本提交 |
| 2026-06-23 | Resume follow-up — fail-closed task cleanup, schema gate, checkpoint lifecycle, control-flow test, complete reboot command | 本提交 |
| 2026-06-23 | Resume skips completed scenario; Live-only independently acknowledged restart; residual process blocker; zero-write PATH functional test; accurate summary counts | 本提交 |
| 2026-06-23 | Sandbox functional test PATH adapter; check functional gate; host functional and TestSafe evidence captured; dedicated VM final-equivalence still pending | 931916e |
| 2026-06-22 | Acceptance hardening — complete file rollback, explicit ownership, single-instance lock, resume merge, restore scenario, timeout evidence | 931916e |
| 2026-06-22 | Single-user VM acceptance — ConPTY prompt state machine, atomic Job containment, baseline rollback, TestSafe/Live orchestration | a9f9f6e |
| 2026-06-21 | Fix doc reference parser — replace greedy regex with structured inline-code + markdown-link extractors | cf3d17e |
| 2026-06-21 | Buyer docs review — 01-04 TXT de-markdown, README buyer structure, security/admin/time language fix | f069b44 |
| 2026-06-21 | validate.ps1 preflight cleanup — git 检查/快照移入 try、cleanup try/catch、TestForcePreflightFailure、防回归检查 | 29a6c9a |
| 2026-06-18 | P0 进度格式化修复 — [Math]::Floor+Double+D2→Format-CcdiElapsedTime[int]/异常降级不中断安装/异常清理子进程 | 23053e7 |
| 2026-06-18 | 超时文案对齐 fallback — TimeoutFollowupMessage 参数化/Native/Winget 不直接让用户诊断/npm 温和 follow-up | 000ec3f |
| 2026-06-18 | 安装进度统一对齐 — 所有安装路径紧凑进度+SlowNotice+300s 超时/winget CC 改用 Captured/删除旧等待句 | 8a3135d |
| 2026-06-17 | 遗留收口 — npm shim 冲突修复/support-feedback 单文件反馈/terminal transcript/ZIP docs 白名单/售后口径统一 | 82e1c20 |
| 2026-06-17 | P0 真机 UX/diagnostic hotfix 第二批 — Node 提示/winget 去英文/API Key 暂停/Claude 启动提示/ps1 误执行 | 1a8d936 |
| 2026-06-16 | v1.3.3 acceptance finalized — 验收通过，最终产物记录 | f44fe4e |
| 2026-06-15 | UX 文案收口 — PATH/ExternalScript 清零 + 双文件 0 容忍扫描 | 23c7249 |
| 2026-06-14 | P0-UX 第二批文案收口 + 技术词收缩 | c4ef24a, f8dc13e |
| 2026-06-13 | P0-UX 第二批补丁覆盖 | e9c234b, 2049420 |
| 2026-06-12 | P0/P1 UX hardening — Native PATH 持久化、fresh shell 验证、doctor CJK crash | 19597a0, 2441aab |
| 2026-06-10 | v1.3.2-rc 验收完成并移交 | 6e01a04 |

---

## Safety Rules

- 不使用真实 DeepSeek API Key，除非用户明确要求真机 API 测试
- 自动化验证中不执行真实 claude install、winget、npm install/update
- 不污染真实 `%USERPROFILE%\.claude\settings.json`；涉及配置的验证前后记录 hash/length
- 不把运行产物加入 Git：`.sandbox/`, `logs/`, `backup/`, `reports/`, `release/`, `report.txt`, `*-report*.txt`
- 不要 `git add .` —— 只精确 add 需要的源文件/文档
- P0/P1 验证失败是 blocker，先报告再修，修复保持最小范围

---

## Validation Commands

```powershell
# 日常自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke

# 完整验收（push 前）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full

# 发布验收
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release -Version "1.3.3" -RequireClean

# Release ZIP
powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version "1.3.3"

# TestSafe 核心流程
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-Here.ps1 -NonInteractive -SkipDisclaimer -TestSafe
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair-deps.ps1 -TestSafe
powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -ShareSafe -SkipApiTest -NoOpenReport
```

---

## Bug Registry

所有有意义的 bug 记录在 `docs/dev/bug-registry.md`。修 bug 后必须：
1. 在 bug-registry.md 添加条目（按模板）
2. 在 check.ps1 中补充防回归检查
3. 在本文件 Progress Log 加一行记录

---

## 完成前检查（以下每一项，没做就补，做完再声称完成）

- 修了 bug → `docs/dev/bug-registry.md` 追加条目
- 新增关键逻辑 → `scripts/check.ps1` 补防回归检查
- 阶段结束 → 上面 Progress Log 加行
- 自检通过 → `validate.ps1 -Mode Smoke` 不报错
- 只 add 需要的文件 → 没有 `git add .`

## Recent Fix History

→ 详见 `docs/dev/bug-registry.md` 的完整记录。以下列出最近 5 条：

- `1a8d936` P0 真机 UX/diagnostic hotfix 第二批 — Node 提示/winget 去英文/API Key 暂停/Claude 启动提示/ps1 误执行
- `37ea865` ux-check.ps1 Section 32 黑名单改用 $allVisJoined + PATH 0 容忍统一
- `23c7249` P0-UX 第二批文案收口三次修正 — PATH/ExternalScript 清零 + 双文件 0 容忍扫描
- `9d6e59c` narrow compressed regex to TEMP-only
- `53c632b` allow desktop and common extract paths
