# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

- Branch: `release/v1.3.2-rc`
- Artifact source commit: `655d7cb2c6994b3a5ce21b3c9cbe25358714d6eb` (ZIP artifact source tree)
- Generating code commit: `655d7cb2c6994b3a5ce21b3c9cbe25358714d6eb` (feat(release): rename to 00-点我开始安装.cmd)
- Metadata HEAD: `76c00d9` (release record metadata; current as of v1.3.2 P1.2 diagnostics fix)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.2.zip`
- SHA256: `5a272b54a60d398b3a3620d31cabc3fd5e92ef7c214ce8627fc01201ef55ce29`
- Size: 191605 bytes (187.1 KB)
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
