# Release Artifacts

> 交付产物记录。每次正式发布后更新最新版本的 ZIP 文件名和 SHA256。

## v1.3.2 RC

- Branch: `release/v1.3.2-rc`
- Artifact source commit: `9d6e59c` (ZIP artifact source tree)
- Generating code commit: `9d6e59c` (release build)
- Metadata HEAD: `9d6e59c` (current HEAD of fix/v1.3.3-native-path-doctor-ux)
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
## v1.3.3

- Branch: `fix/v1.3.3-native-path-doctor-ux`
- Artifact source commit: `37ea865` (ZIP artifact source tree)
- Generating code commit: `37ea865` (release build)
- Metadata HEAD: `37ea865` (current HEAD of fix/v1.3.3-native-path-doctor-ux)
- ZIP: `ClaudeCode-DeepSeek-本地配置助手-v1.3.3.zip`
- SHA256: `f72bdbce37665579774c8818a51423442c80831d5e9b863c109ea6281e3ef6b9`
- Size: `267729 bytes (261.5 KB)`
- Entries: `38`
- Build command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version "1.3.3"`
- Simulate command: `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\simulate-user-release.ps1 -Version "1.3.3"`
- Validation:
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1` → ALL PASSED (P0-P9, v1.3.3 anti-regression)
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ux-check.ps1` → 555/555 PASSED
  - `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1 -ReleaseCheck` → PASSED
  - All .ps1 syntax parse → PASSED
  - `build-release.ps1` → 打包成功，38 entries
  - `simulate-user-release.ps1` → ALL PASSED (包括 7 ShellExecute 双击模拟、7 API mock 场景、中文空格路径解压、配置完整生命周期)
  - ZIP forbidden entries check: PASSED (无 .git/, logs/, backup/, reports/, settings.json, 开发者脚本)
  - ZIP required entries check: PASSED
  - ZIP sensitive scan: PASSED (DEEPSEEK_API_KEY/api_key 均为变量名引用，无真实 sk- 密钥)
  - A/B/C 验收：B/C 真实验收通过，A 场景标记为模拟/待真实验收（当前机器非干净 Windows）
