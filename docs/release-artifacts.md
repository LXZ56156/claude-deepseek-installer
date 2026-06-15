# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

- Branch: `release/v1.3.2-rc`
- Commit: `<see-below>` (fix(validation): enforce final artifact and shellexecute failure checks)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.2.zip`
- SHA256: `de65f8610ae2a12c6bb724a5fa7dc2e5d0dfb80dab0312ef845fac71222d3d69`
- Size: 190671 bytes (186.2 KB)
- Entries: 38
- Validation:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release -Version "1.3.2"`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Hardcore -Version "1.3.2"`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All -Version "1.3.2" -RequireClean`
- Notes:
  - Release ZIP 不包含开发者打包脚本（build-release.ps1、simulate-user-release.ps1、package-release.ps1）。
  - Release ZIP 不包含 logs、backup、reports、release、.git、report.txt、CLAUDE.md、.gitignore。
  - 验收过程中真实 `%USERPROFILE%\.claude\settings.json` 未变化。
  - 敏感串扫描无命中。
