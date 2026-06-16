# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

> **⚠ 旧验收记录 / stale until next release build**
>
> 以下 ZIP 信息和 SHA256 对应上一轮打包产物（commit `655d7cb`）。
> 当前分支 HEAD 已推进至后续修复提交，代码验证已通过但尚未重新打包。
> **在下次 `build-release.ps1` 或 `package-release.ps1` 重新生成 ZIP 之前，以下信息不代表当前分支最新提交 的交付产物。**

- Branch: `release/v1.3.2-rc`
- Artifact source commit: `655d7cb2c6994b3a5ce21b3c9cbe25358714d6eb` (ZIP artifact source tree — stale)
- Generating code commit: `655d7cb2c6994b3a5ce21b3c9cbe25358714d6eb` (feat(release): rename to 00-点我开始安装.cmd — stale)
- Metadata HEAD (current): `03dbb19` (当前分支 HEAD，代码验证已通过；下一轮打包前修复提交，见 `git log`)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.2.zip` (旧打包产物)
- SHA256: `5a272b54a60d398b3a3620d31cabc3fd5e92ef7c214ce8627fc01201ef55ce29` (旧产物 SHA256)
- Size: 191605 bytes (187.1 KB) (旧产物)
- Entries: 38 (旧产物)
- Validation (on old artifact):
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release -Version "1.3.2"`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Hardcore -Version "1.3.2"`
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All -Version "1.3.2" -RequireClean`

---

**下一步**：重新执行 `build-release.ps1` 打包后，用真实 ZIP 信息替换本条记录。
- Notes:
  - Release ZIP 不包含开发者打包脚本（build-release.ps1、simulate-user-release.ps1、package-release.ps1）。
  - Release ZIP 不包含 logs、backup、reports、release、.git、report.txt、CLAUDE.md、.gitignore。
  - 验收过程中真实 `%USERPROFILE%\.claude\settings.json` 未变化。
  - 敏感串扫描无命中。
