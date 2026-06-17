# AGENTS.md

本文件是会话级交接文件。**每次新会话开始必读**。CLAUDE.md 是持久化项目知识，本文是动态上下文。

---

## Active Work

- **Branch**: `fix/v1.3.3-native-path-doctor-ux`
- **Status**: 遗留收口批（feedback/report/package residuals）完成，全部验收通过
- **Next**: 真机验收 → 合并到 main → 打 v1.3.3 release ZIP
- **Latest commit**: (待提交) fix(ux): close feedback/report/package residuals

---

## Progress Log

保留最近 ~10 条（完整历史在 `git log`）。旧条目直接删除即可。

| 日期 | 内容 | Commit |
|------|------|--------|
| 2026-06-17 | 遗留收口 — npm shim 冲突修复/support-feedback 单文件反馈/terminal transcript/ZIP docs 白名单/售后口径统一 | (待提交) |
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
