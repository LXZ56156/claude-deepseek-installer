# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

- Branch: `release/v1.3.2-rc`
- Artifact source commit: `4dd908f` (ZIP artifact source tree)
- Generating code commit: `4dd908f` (release build)
- Metadata HEAD: `4dd908f` (current HEAD of release/v1.3.2-rc)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.2.zip`
- SHA256: `6944152F9AA4FE531B276E1947F1A2F1769CC09AD8DC86E4B8E20A0F105722F3`
- Size: `223948 bytes (218.7 KB)`
- Entries: `38`
- Validation:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All -Version "1.3.2" -RequireClean` → PASSED
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1` → P1-P9 ALL OK
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ux-check.ps1` → 244/244 PASSED
  - `build-release.ps1` → 打包成功
  - ZIP forbidden entries check: PASSED (0 forbidden)
  - ZIP required entries check: PASSED
  - ZIP sensitive scan: PASSED (0 real credentials)
  - Chinese/space path unzip TestSafe run: PASSED (Start-Here, doctor, repair-deps, uninstall-config)
- Notes:
  - Release ZIP 不包含开发者打包脚本（build-release.ps1、simulate-user-release.ps1、package-release.ps1、sandbox-full-user-simulation.ps1）。
  - Release ZIP 不包含 logs、backup、reports、release、.git、.sandbox、report.txt、CLAUDE.md、.gitignore。
  - 敏感串扫描无命中真实凭据。
  - 旧 ZIP（SHA256: `8ce8167...`）不再作为交付产物使用，以本条 SHA256 为准。
