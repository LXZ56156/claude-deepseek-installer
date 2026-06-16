# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

- Branch: `release/v1.3.2-rc`
- Artifact source commit: `3fdfafb8b81dad4e5382683c11542df35785de71` (ZIP artifact source tree)
- Generating code commit: `3fdfafb8b81dad4e5382683c11542df35785de71` (release build)
- Metadata HEAD: `b3ea13300730393fe6107b8c714128143492f03f` (docs metadata commit; parent of pointer-fix commit)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.2.zip`
- SHA256: `8ce8167699d32e29c7b73f280704b7ff94ee86461ecd460b3b90d00a1ae3aa00`
- Size: `216792 bytes (211.7 KB)`
- Entries: `38`
- Validation:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All -Version "1.3.2" -RequireClean` → **19/19 PASSED**
  - `scripts\build-release.ps1 -Version "1.3.2"` → 打包成功
  - ZIP forbidden entries check: PASSED (0 forbidden)
  - ZIP required entries check: PASSED (26 required, all present)
  - ZIP sensitive scan: PASSED (0 real credentials; 6 code-comment/test placeholders are `user:pass@` in proxy sanitization docs)
  - Chinese/space path unzip TestSafe run: PASSED (Start-Here, doctor, repair-deps, uninstall-config)
- Notes:
  - Release ZIP 不包含开发者打包脚本（build-release.ps1、simulate-user-release.ps1、package-release.ps1、sandbox-full-user-simulation.ps1）。
  - Release ZIP 不包含 logs、backup、reports、release、.git、.sandbox、report.txt、CLAUDE.md、.gitignore。
  - 验收过程中真实 `%USERPROFILE%\.claude\settings.json` 未变化（SHA256: `7841D70B2BD00BECDEBCE4807B5825F807FC01312BA3B6878C82DDFB4B6CA407`）。
  - 敏感串扫描无命中真实凭据。
  - 旧 ZIP（SHA256: `5a272b5...`）不再作为交付产物使用，以本条 SHA256 为准。
