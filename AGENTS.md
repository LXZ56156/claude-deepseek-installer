# AGENTS.md

This repository uses this file as the handoff guide for coding agents working on `claude-deepseek-installer`.

## Current Release Context

- Active release branch: `release/v1.3.2-rc`
- Do not switch to `main`, merge `main`, or return to previous fix branches unless explicitly instructed.
- Current latest known pushed commit on the release branch: `6e01a04` (`fix(doctor): bound claude doctor diagnostics`).
- The latest full Windows release validation must be rerun from `6e01a04` or a later commit before final publication, because fixes after the last full ZIP pass touched API/doctor behavior.

## Safety Rules

- Do not use a real DeepSeek API Key unless the user explicitly asks for a real API test.
- Do not request the real DeepSeek API during automated validation. Use `-TestSafe`, `-SkipApiTest`, or local mock endpoints.
- Do not execute real Claude install, real `winget`, or real `npm install/update` during automated validation.
- Do not pollute the real `%USERPROFILE%\.claude\settings.json`; record hash/length before and after any validation that touches config logic.
- Do not add runtime artifacts to Git:
  - `.sandbox/`
  - `logs/`
  - `backup/`
  - `reports/`
  - `release/`
  - `report.txt`
  - `report-share-safe.txt`
  - `full-report*`
  - `repair-deps-report*`
  - `install-report*`
- Do not use `git add .`. Add only the exact source/documentation files required.
- Treat P0/P1 validation failures as blockers. Report first; keep fixes minimal and scoped.

## Normal Start Procedure

Run from a Windows native local disk path such as `D:\projects\claude-deepseek-installer`, not from `\\wsl.localhost` or `\\wsl$`.

```powershell
git fetch origin --prune
git checkout release/v1.3.2-rc
git pull --ff-only origin release/v1.3.2-rc
git status --short
git log --oneline --decorate -8
```

Stop and report if there are unexpected source changes in the worktree.

## Validation Commands

Core Windows checks:

```powershell
git diff --check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\check.ps1
```

PowerShell parse check:

```powershell
powershell.exe -NoProfile -Command "Get-ChildItem . -Filter *.ps1 -Recurse | Where-Object { `$_.FullName -notmatch '\\.git|\\.sandbox|\\backup|\\logs|\\reports|\\release|\\node_modules' } | ForEach-Object { `$tokens = `$null; `$errors = `$null; [System.Management.Automation.Language.Parser]::ParseFile(`$_.FullName, [ref]`$tokens, [ref]`$errors) | Out-Null; if (`$errors.Count -gt 0) { throw ('PowerShell parse failed: ' + `$_.FullName + ' - ' + `$errors[0].Message) } }"
```

Core TestSafe checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Here.ps1 -NonInteractive -SkipDisclaimer -TestSafe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\repair-deps.ps1 -TestSafe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Here.ps1 -FixDeps -TestSafe
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1 -ShareSafe -SkipApiTest -NoOpenReport
```

Release ZIP:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-release.ps1
```

If Windows/WSL CRLF behavior makes source-worktree `bash -n install_wsl.sh` fail, record it as a Windows environment limitation. The release ZIP copy must still normalize `install_wsl.sh` to LF, and ZIP-internal `bash -n install_wsl.sh` must pass when Bash is available.

## Recent Fix History

- `bb5d159` `fix(path): block archive temp extraction paths`
  - Fixed archive temp path detection for `Rar$...`, `7z...`, and TEMP `.zip` paths.
- `4433b64` `fix(config): handle empty env under strict mode`
  - Fixed empty `env = {}` StrictMode failures during uninstall/restore.
- `369a9cf` `fix(ux): bound claude doctor quick check`
  - Bounded install-flow `claude doctor` to 30 seconds.
- `e708863` `fix(api): handle response-less smoke test errors`
  - Fixed DeepSeek API smoke-test crashes when exceptions lack a `Response` property.
- `6e01a04` `fix(doctor): bound claude doctor diagnostics`
  - Bounded `doctor.ps1` `claude doctor` diagnostic call to 30 seconds with progress output.

See `docs/v1.3.2-rc-验收与修复交接.md` for the detailed handoff log.
