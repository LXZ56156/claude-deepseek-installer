# ============================================================
# claude-install.ps1 - Claude Code 安装模块 (v1.3.3)
# 集中管理 Claude Code 的检测和安装逻辑。
#
# 安装策略:
#   1. claude 已存在 → 跳过（不覆盖、不重装、不自动更新）
#   2. 官方 Native Install 可用 → 优先使用
#   3. 官方不可用或安装失败 → 尝试 winget install Anthropic.ClaudeCode
#   4. winget 不可用或失败 → 自动切换 npmmirror npm 镜像
#   5. npm 镜像需要 Node.js >= 18 + npm（通过 npm.cmd 执行，禁止 npm.ps1）
#
# 依赖: common.ps1, logger.ps1, env-check.ps1, state.ps1
# 注意: 本模块不自行 dot-source 依赖模块，由 bootstrap.ps1 统一加载
# ============================================================

# ============================================================
# 检测函数
# ============================================================

function Test-ClaudeCommandExisting {
    <#
    .SYNOPSIS
        检测 claude 命令是否存在并可用。
        不能只因为 Get-Command claude 存在就判定可用。
        如果 PATH 中 claude 不可用，会继续检测 %USERPROFILE%\.local\bin\claude.exe
        （Native Install 默认路径），防止 WindowsApps alias / Claude Desktop / 旧 shim
        导致的误判。
    .RETURNS
        包含 Exists, Usable, Version, Error, Path, Source 的哈希表
    #>
    $result = @{
        Exists  = $false
        Usable  = $false
        Version = $null
        Error   = ""
        Path    = $null
        Source  = ""
    }

    # TestSafe / Mock mode: skip real claude --version to avoid process hang
    if ($env:CCDI_TEST_MODE -eq "1") {
        if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1") {
            $mockClaude = if ($env:CCDI_MOCK_CLAUDE) { $env:CCDI_MOCK_CLAUDE } else { "missing" }
            Write-Log "DEBUG" "MOCK: Test-ClaudeCommandExisting -> CCDI_MOCK_CLAUDE=$mockClaude"
            switch ($mockClaude) {
                "ok" { return @{ Exists = $true; Usable = $true; Version = "1.0.0-mock"; Error = ""; Path = $null; Source = "" } }
                "native" {
                    # 测试用：返回 Native Install 固定路径可用，用于 repair-deps PATH 修复功能测试。
                    # 仅在 TestSafe + mock-decision 模式生效，不影响真实检测行为。
                    $nativeMockExe = Get-NativeClaudeExePath
                    return @{ Exists = $true; Usable = $true; Version = "1.0.0-mock"; Error = ""; Path = $nativeMockExe; Source = "native_local_bin" }
                }
                "broken" { return @{ Exists = $true; Usable = $false; Version = $null; Error = "mock: claude command exists but --version fails (corrupt or residual)"; Path = $null; Source = "" } }
                default { return @{ Exists = $false; Usable = $false; Version = $null; Error = "mock: claude not found"; Path = $null; Source = "" } }
            }
        }
        # Non-mock TestSafe: use Get-Command only, skip --version
        $cmd = Get-Command "claude" -ErrorAction SilentlyContinue
        if ($cmd) {
            $cmdPath = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
            $cmdSource = if ($cmd.CommandType) { $cmd.CommandType.ToString() } else { "path" }
            return @{ Exists = $true; Usable = $true; Version = "test-safe"; Error = ""; Path = $cmdPath; Source = $cmdSource }
        }

        $testSafeCandidates = New-Object System.Collections.ArrayList
        [void]$testSafeCandidates.Add([PSCustomObject]@{ Path = (Get-NativeClaudeExePath); Source = "native_local_bin" })
        if ($env:APPDATA) {
            [void]$testSafeCandidates.Add([PSCustomObject]@{ Path = (Join-Path $env:APPDATA "npm\claude.cmd"); Source = "npm_global" })
        }
        foreach ($candidate in $testSafeCandidates) {
            if ($candidate.Path -and (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) {
                [void](Add-CurrentProcessPathEntry -PathToAdd (Split-Path -Parent $candidate.Path))
                return @{ Exists = $true; Usable = $true; Version = "test-safe"; Error = ""; Path = $candidate.Path; Source = $candidate.Source }
            }
        }
        return @{ Exists = $false; Usable = $false; Version = $null; Error = "test-safe: claude not found"; Path = $null; Source = "" }
    }

    # 刷新 PATH 后检测
    Refresh-CurrentProcessPath

    # ============================================================
    # 阶段 1: 检测当前 PATH 中的 claude
    # ============================================================
    $cmdInfo = Get-Command "claude" -ErrorAction SilentlyContinue
    if ($cmdInfo) {
        $result.Exists = $true
        $result.Path = if ($cmdInfo.Source) { $cmdInfo.Source } else { $cmdInfo.Definition }
        $result.Source = if ($cmdInfo.CommandType) { $cmdInfo.CommandType.ToString() } else { "path" }
        Write-Log "DEBUG" "Test-ClaudeCommandExisting: found claude at Path=$($result.Path), Source=$($result.Source)"

        $verResult = Invoke-CommandSafe -Command "claude" -Arguments @("--version") -TimeoutSec 5
        if ($verResult.Success -and -not [string]::IsNullOrWhiteSpace($verResult.Output)) {
            $result.Usable = $true
            $result.Version = $verResult.Output.Trim()
            if ($result.Path) {
                [void](Add-CurrentProcessPathEntry -PathToAdd (Split-Path -Parent $result.Path))
            }
            # PATH 中 claude 可用，直接返回
            return $result
        }

        # PATH 中 claude 存在但不可用，记录原因，继续检测 native_local_bin
        $result.Usable = $false
        $result.Error = "PATH 中 claude 命令存在但 --version 失败（残留或损坏）: $($verResult.Error)"
        Write-Log "WARN" $result.Error
    }

    # ============================================================
    # 阶段 2: 只要当前不是 Usable=true，就继续检测 Native Install 默认路径
    # 覆盖场景: PATH 前面有坏 claude（WindowsApps alias / Claude Desktop / 旧 shim / 残留），
    # 但 %USERPROFILE%\.local\bin\claude.exe 实际可用
    # ============================================================
    $nativeClaudeExe = Join-Path (Join-Path (Get-UserProfilePath) ".local\bin") "claude.exe"

    if (Test-Path $nativeClaudeExe) {
        Write-Log "INFO" "Test-ClaudeCommandExisting: 正在检测 Native Install 默认路径: $nativeClaudeExe"
        $nativeVer = Invoke-CommandSafe -Command $nativeClaudeExe -Arguments @("--version") -TimeoutSec 5

        if ($nativeVer.Success -and -not [string]::IsNullOrWhiteSpace($nativeVer.Output)) {
            # PATH 中有坏 claude，但 native_local_bin 可用 → 以 native 为准
            if ($result.Exists -and -not $result.Usable) {
                Write-Log "WARN" "PATH 中 claude 不可用，但 native_local_bin claude.exe 可用。可能存在 PATH 优先级冲突。BadPath=$($result.Path)"
            }

            $result.Exists = $true
            $result.Usable = $true
            $result.Version = $nativeVer.Output.Trim()
            $result.Path = $nativeClaudeExe
            $result.Source = "native_local_bin"
            [void](Add-CurrentProcessPathEntry -PathToAdd (Split-Path -Parent $nativeClaudeExe))
            return $result
        }
        else {
            # native 路径存在但也不可用
            if (-not $result.Exists) {
                # PATH 也没找到，native 是唯一发现
                $result.Exists = $true
                $result.Path = $nativeClaudeExe
                $result.Source = "native_local_bin"
                $result.Error = "native_local_bin claude.exe 存在但 --version 失败: $($nativeVer.Error)"
            }
            else {
                # PATH 已记录坏 claude 的错误，追加 native 也不可用的信息
                $result.Error = "$($result.Error); native_local_bin 也不可用: $($nativeVer.Error)"
            }
            Write-Log "WARN" $result.Error
        }
    }

    # ============================================================
    # 阶段 3: npm/winget 等固定路径清单兜底
    # 覆盖场景: Get-Command claude 暂未刷新，但 %APPDATA%\npm\claude.cmd
    # 或 npm prefix -g 目录下的 claude.cmd 已经可用。
    # ============================================================
    try {
        $inventory = Get-ClaudeCommandInventory
        $usable = $null
        if ($inventory.Active -and $inventory.Active.Usable) {
            $usable = $inventory.Active
        }
        if (-not $usable) {
            $usableCandidates = @($inventory.Candidates | Where-Object {
                $_.Usable -and $_.Source -in @("native_local_bin", "npm_global", "winget", "path", "unknown")
            })
            if ($usableCandidates.Count -gt 0) {
                $usable = $usableCandidates[0]
            }
        }

        if ($usable) {
            $result.Exists = $true
            $result.Usable = $true
            $result.Version = $usable.Version
            $result.Path = $usable.Path
            $result.Source = $usable.Source
            [void](Add-CurrentProcessPathEntry -PathToAdd (Split-Path -Parent $usable.Path))
            Write-Log "INFO" "Test-ClaudeCommandExisting: 固定路径清单确认 claude 可用: Path=$($usable.Path), Source=$($usable.Source), Version=$($usable.Version)"
            return $result
        }

        $existingCandidates = @($inventory.Candidates | Where-Object { $_.Exists })
        $existingFromInventory = if ($existingCandidates.Count -gt 0) { $existingCandidates[0] } else { $null }
        if ($existingFromInventory -and -not $result.Exists) {
            $result.Exists = $true
            $result.Path = $existingFromInventory.Path
            $result.Source = $existingFromInventory.Source
            $result.Error = "检测到 claude 文件但 --version 未通过: $($existingFromInventory.Error)"
        }
    }
    catch {
        Write-Log "DEBUG" "Test-ClaudeCommandExisting: Get-ClaudeCommandInventory fallback failed: $_"
    }

    return $result
}

function Wait-ClaudeCommandReady {
    <#
    .SYNOPSIS
        等待 Claude Code 命令可用。
        首次安装（尤其是 npm shim）后 claude --version 可能短暂超时。
        本函数在 TotalWaitSec 内轮询，支持 Get-ClaudeCommandInventory 和
        Test-ClaudeCommandInFreshShell 兜底，避免第一次超时就误报失败。
    .PARAMETER TotalWaitSec
        总等待秒数，默认 30。
    .PARAMETER IntervalSec
        轮询间隔秒数，默认 2。
    .PARAMETER RequireFreshShell
        是否要求 fresh shell 验证通过。
    .PARAMETER Context
        描述上下文，用于日志。
    .RETURNS
        包含 Ready, Exists, Usable, Version, Path, Source,
        FreshShellSuccess, FreshShellVersion, InventoryUsable,
        Attempts, LastError, Status 的哈希表
    #>
    param(
        [int]$TotalWaitSec = 30,
        [int]$IntervalSec = 2,
        [switch]$RequireFreshShell,
        [string]$Context = "Claude Code 安装确认"
    )

    $result = @{
        Ready             = $false
        Exists            = $false
        Usable            = $false
        Version           = $null
        Path              = $null
        Source            = $null
        FreshShellSuccess = $false
        FreshShellVersion = $null
        InventoryUsable   = $false
        Attempts          = 0
        LastError         = ""
        Status            = "not_ready"
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TotalWaitSec))
    Write-Log "INFO" "Wait-ClaudeCommandReady: Context=$Context, TotalWaitSec=$TotalWaitSec, IntervalSec=$IntervalSec, RequireFreshShell=$RequireFreshShell"

    while ((Get-Date) -lt $deadline) {
        $result.Attempts++
        Refresh-CurrentProcessPath

        $check = Test-ClaudeCommandExisting
        $result.Exists = [bool]$check.Exists
        $result.Usable = [bool]$check.Usable
        $result.Version = $check.Version
        $result.Path = $check.Path
        $result.Source = $check.Source
        $result.LastError = $check.Error

        if ($check.Usable) {
            if ($RequireFreshShell) {
                $fresh = Test-ClaudeCommandInFreshShell
                $result.FreshShellSuccess = [bool]$fresh.Success
                $result.FreshShellVersion = $fresh.Output
                if ($fresh.Success) {
                    $result.Ready = $true
                    $result.Status = "ready_fresh_shell"
                    return $result
                }
            }
            else {
                $result.Ready = $true
                $result.Status = "ready_current_process"
                return $result
            }
        }

        Write-Log "DEBUG" "Wait-ClaudeCommandReady attempt=$($result.Attempts): Exists=$($check.Exists), Usable=$($check.Usable), Error=$($check.Error)"
        Start-Sleep -Seconds ([Math]::Max(1, $IntervalSec))
    }

    # 兜底：inventory 有时能确认 npm shim 可用，尤其刚安装后第一次 claude --version 可能 5 秒超时
    try {
        $inv = Get-ClaudeCommandInventory
        if ($inv -and $inv.Active -and $inv.Active.Usable) {
            $result.InventoryUsable = $true
            $result.Exists = $true
            $result.Usable = $true
            $result.Version = $inv.Active.Version
            $result.Path = $inv.Active.Path
            $result.Source = $inv.Active.Source

            if ($RequireFreshShell) {
                $fresh2 = Test-ClaudeCommandInFreshShell
                $result.FreshShellSuccess = [bool]$fresh2.Success
                $result.FreshShellVersion = $fresh2.Output
                if ($fresh2.Success) {
                    $result.Ready = $true
                    $result.Status = "ready_inventory_fresh_shell"
                    return $result
                }
            }
            else {
                $result.Ready = $true
                $result.Status = "ready_inventory"
                return $result
            }
        }
    }
    catch {
        Write-Log "DEBUG" "Wait-ClaudeCommandReady inventory fallback failed: $_"
    }

    # 最后再做一次 Fresh PowerShell，避免当前窗口状态误判
    try {
        $freshFinal = Test-ClaudeCommandInFreshShell
        $result.FreshShellSuccess = [bool]$freshFinal.Success
        $result.FreshShellVersion = $freshFinal.Output
        if ($freshFinal.Success) {
            $result.Ready = $true
            $result.Status = "ready_fresh_shell_only"
            return $result
        }
    }
    catch {
        Write-Log "DEBUG" "Wait-ClaudeCommandReady fresh shell fallback failed: $_"
    }

    $result.Status = "not_ready_after_wait"
    return $result
}

function Get-ClaudeCommandInventory {
    <#
    .SYNOPSIS
        收集当前 Windows 电脑上所有可能的 claude 命令来源，逐个执行 --version，
        判断是否可用，并识别冲突。
    .RETURNS
        包含 Candidates, Active, HasConflict, ConflictSummary 的哈希表。
        每个 Candidate 包含 Path, Source, Exists, Usable, Version, Risk, Note, Error。
    #>
    $inventory = @{
        Candidates        = [System.Collections.ArrayList]::new()
        MissingKnownPaths = [System.Collections.ArrayList]::new()
        Active            = $null
        HasConflict       = $false
        ConflictSummary   = ""
    }

    $seen = @{}
    $tempCandidates = [System.Collections.ArrayList]::new()

    # --- 辅助函数：规范化路径用于去重 ---
    function _normalize {
        param([string]$P)
        try { return [System.IO.Path]::GetFullPath($P).TrimEnd('\').ToLowerInvariant() }
        catch { return $P.Trim().ToLowerInvariant() }
    }

    # --- 辅助函数：加入候选并去重 ---
    # -KnownPath: 已知固定路径，不存在时记入 MissingKnownPaths 而非 Candidates
    function _add {
        param([string]$CandidatePath, [string]$SourceHint, [string]$RiskHint, [string]$NoteHint, [switch]$KnownPath)
        if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return }

        $exists = Test-Path $CandidatePath

        # 不存在的路径不进入 Candidates；已知路径记录到 MissingKnownPaths
        if (-not $exists) {
            if ($KnownPath) {
                $n = _normalize $CandidatePath
                if (-not $seen.ContainsKey($n)) {
                    $seen[$n] = $true
                    [void]$inventory.MissingKnownPaths.Add([PSCustomObject]@{
                        Path   = $CandidatePath
                        Source = $SourceHint
                        Note   = "known path not found"
                    })
                }
            }
            return
        }

        # 只有存在才进入 Candidates 去重流
        $n = _normalize $CandidatePath
        if ($seen.ContainsKey($n)) { return }
        $seen[$n] = $true

        [void]$tempCandidates.Add([PSCustomObject]@{
            Path              = $CandidatePath
            Source            = $SourceHint
            Exists            = $true
            Usable            = $false
            Version           = $null
            Risk              = $RiskHint
            Note              = $NoteHint
            Error             = ""
            LogicalInstallKey = ""
            ProbePath         = ""
            IsShimCompanion   = $false
            CompanionOf       = ""
        })
    }

    # ============================================================
    # 1. Get-Command claude -All
    # ============================================================
    $cmds = @(Get-Command "claude" -All -ErrorAction SilentlyContinue)
    $firstCmdPath = $null
    if ($cmds.Count -gt 0) {
        $firstCmdPath = if ($cmds[0].Source) { $cmds[0].Source } else { $cmds[0].Definition }
    }
    foreach ($cmd in $cmds) {
        $p = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
        _add -CandidatePath $p -SourceHint "path" -RiskHint "INFO" -NoteHint ""
    }

    # ============================================================
    # 2. where.exe claude
    # ============================================================
    try {
        $whereResult = & where.exe claude 2>$null
        if ($whereResult) {
            $lines = if ($whereResult -is [array]) { $whereResult } else { @($whereResult) }
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -and (Test-Path $trimmed)) {
                    _add -CandidatePath $trimmed -SourceHint "where" -RiskHint "INFO" -NoteHint ""
                }
            }
        }
    }
    catch { }

    # ============================================================
    # 3. Native Install 默认路径 (%USERPROFILE%\.local\bin\claude.exe)
    # ============================================================
    $nativeClaudeExe = Join-Path (Join-Path (Get-UserProfilePath) ".local\bin") "claude.exe"
    _add -CandidatePath $nativeClaudeExe -SourceHint "native_local_bin" -RiskHint "OK" `
        -NoteHint "Claude 官方 Native Install 默认路径" -KnownPath

    # ============================================================
    # 4. npm 全局 shim 默认路径 (%APPDATA%\npm\claude.cmd)
    # ============================================================
    if ($env:APPDATA) {
        $npmClaudeCmd = Join-Path $env:APPDATA "npm\claude.cmd"
        _add -CandidatePath $npmClaudeCmd -SourceHint "npm_global" -RiskHint "INFO" `
            -NoteHint "npm 全局安装 shim" -KnownPath
        $npmClaudePs1 = Join-Path $env:APPDATA "npm\claude.ps1"
        _add -CandidatePath $npmClaudePs1 -SourceHint "npm_global" -RiskHint "INFO" `
            -NoteHint "npm PowerShell shim，仅作为存在性参考，不直接执行" -KnownPath
    }

    # npm prefix -g 返回的目录也可能不是 %APPDATA%\npm，安装后必须检查。
    try {
        $npmResolved = Resolve-NpmCmdPath
        if ($npmResolved.Found) {
            $prefixResult = Invoke-CommandSafe -Command $npmResolved.Path -Arguments @("prefix", "-g") -TimeoutSec 8 -LogTimeoutAsWarn
            if ($prefixResult.Success -and -not [string]::IsNullOrWhiteSpace($prefixResult.Output)) {
                $npmPrefix = ($prefixResult.Output -split "`r?`n" | Select-Object -First 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($npmPrefix)) {
                    _add -CandidatePath (Join-Path $npmPrefix "claude.cmd") -SourceHint "npm_global" -RiskHint "INFO" `
                        -NoteHint "npm prefix -g 全局安装 shim" -KnownPath
                    _add -CandidatePath (Join-Path $npmPrefix "claude.ps1") -SourceHint "npm_global" -RiskHint "INFO" `
                        -NoteHint "npm prefix -g PowerShell shim，仅作为存在性参考，不直接执行" -KnownPath
                }
            }
            else {
                Write-Log "DEBUG" "Get-ClaudeCommandInventory: npm prefix -g 未返回可用目录: $($prefixResult.Error)"
            }
        }
    }
    catch {
        Write-Log "DEBUG" "Get-ClaudeCommandInventory: npm prefix -g 探测失败: $_"
    }

    # ============================================================
    # 5. WindowsApps alias 路径 (%LOCALAPPDATA%\Microsoft\WindowsApps\claude.exe)
    # ============================================================
    if ($env:LOCALAPPDATA) {
        $windowsAppsClaude = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.exe"
        _add -CandidatePath $windowsAppsClaude -SourceHint "windowsapps" -RiskHint "WARN" `
            -NoteHint "可能是 App Execution Alias / Claude Desktop alias，可能抢占真实 CLI" -KnownPath
    }

    # ============================================================
    # 6. 当前 PATH 中的 claude.exe / claude.cmd / claude.bat
    # ============================================================
    $pathDirs = $env:Path.Split(';')
    foreach ($dir in $pathDirs) {
        $trimmedDir = $dir.Trim()
        if (-not $trimmedDir) { continue }
        try {
            if (-not (Test-Path $trimmedDir -PathType Container)) { continue }
            foreach ($ext in @("exe", "cmd", "bat")) {
                $candidatePath = Join-Path $trimmedDir "claude.$ext"
                if (Test-Path $candidatePath) {
                    _add -CandidatePath $candidatePath -SourceHint "path" -RiskHint "INFO" -NoteHint ""
                }
            }
        }
        catch { }
    }

    # ============================================================
    # 候选分类与可用性检测
    # ============================================================
    foreach ($candidate in $tempCandidates) {
        $pathLower = $candidate.Path.ToLowerInvariant()

        # 路径模式分类（覆盖临时 SourceHint）
        if ($candidate.Source -in @("path", "where", "")) {
            if ($pathLower -match '\\\.local\\bin\\claude\.exe$' -or $pathLower -match '/\.local/bin/claude\.exe$') {
                $candidate.Source = "native_local_bin"
                $candidate.Risk = "OK"
                $candidate.Note = "Claude 官方 Native Install 默认路径"
            }
            elseif ($pathLower -match '\\appdata\\roaming\\npm\\claude\.(cmd|ps1)$' -or $pathLower -match '\\npm\\claude\.(cmd|ps1)$') {
                $candidate.Source = "npm_global"
                $candidate.Risk = "INFO"
                $candidate.Note = "npm 全局安装 shim"
            }
            elseif ($pathLower -match '\\microsoft\\windowsapps\\') {
                $candidate.Source = "windowsapps"
                $candidate.Risk = "WARN"
                $candidate.Note = "可能是 App Execution Alias / Claude Desktop alias，可能抢占真实 CLI"
            }
            elseif (
                $pathLower -match '\\microsoft\\winget\\packages\\anthropic\.claudecode_' -or
                $pathLower -match '\\winget\\packages\\anthropic\.claudecode'
            ) {
                $candidate.Source = "winget"
                $candidate.Risk = "OK"
                $candidate.Note = "winget 安装的 Claude Code CLI"
            }
            else {
                $candidate.Source = "unknown"
                $candidate.Risk = "WARN"
                $candidate.Note = "未知 claude 来源，请确认是否为旧安装或第三方文件"
            }
        }

        # --version 检测
        if ($candidate.Exists) {
            # v1.3.3 P5: 不直接执行 claude.ps1，优先探测同目录 claude.cmd
            $probePath = $candidate.Path
            $probingPs1 = $false
            if ([System.IO.Path]::GetExtension($candidate.Path) -eq '.ps1') {
                $siblingCmd = Join-Path (Split-Path -Parent $candidate.Path) "claude.cmd"
                if (Test-Path $siblingCmd) {
                    $probePath = $siblingCmd
                    Write-Log "DEBUG" "Get-ClaudeCommandInventory: 候选 $($candidate.Path) 是 .ps1，改用同目录 claude.cmd 探测: $siblingCmd"
                }
                else {
                    # 没有同目录 claude.cmd，标记 WARN 但不执行 .ps1
                    $candidate.Usable = $false
                    $candidate.Risk = "WARN"
                    $candidate.Note = "PowerShell shim 未直接探测；缺少同目录 claude.cmd"
                    $candidate.Error = "跳过 claude.ps1 直接执行，防止记事本打开或弹窗"
                    Write-Log "INFO" "Get-ClaudeCommandInventory: 跳过 claude.ps1 探测 (Path=$($candidate.Path))，无同目录 claude.cmd"
                    $probingPs1 = $true
                }
            }

            if (-not $probingPs1) {
                $verResult = Invoke-CommandSafe -Command $probePath -Arguments @("--version") -TimeoutSec 8
                if ($verResult.Success -and -not [string]::IsNullOrWhiteSpace($verResult.Output)) {
                    $candidate.Usable = $true
                    $candidate.Version = $verResult.Output.Trim()
                }
                else {
                    $candidate.Usable = $false
                    $candidate.Error = if ($verResult.Error) { $verResult.Error } else { "--version 返回空" }
                    # 文件存在但无法运行 → 升级为 ERROR（windowsapps 除外）
                    if ($candidate.Source -ne "windowsapps") {
                        $candidate.Risk = "ERROR"
                        $candidate.Note = "文件存在但无法运行，可能是残留 shim、损坏安装或 PATH 冲突"
                    }
                }
            }
        }

        # 只有存在才进入 Candidates（不存在路径已在 _add 中过滤）
        [void]$inventory.Candidates.Add($candidate)
    }

    # ============================================================
    # LogicalInstallKey 归一化 (v1.3.3 fix: npm shim 组合不误报冲突)
    # 同目录、同来源的 claude.ps1 + claude.cmd 归为同一个逻辑来源
    # ============================================================
    foreach ($candidate in $inventory.Candidates) {
        $candidateDir = Split-Path -Parent $candidate.Path
        $candidateDirNorm = try { [System.IO.Path]::GetFullPath($candidateDir).TrimEnd('\').ToLowerInvariant() } catch { $candidateDir.ToLowerInvariant() }
        $ext = [System.IO.Path]::GetExtension($candidate.Path).ToLowerInvariant()

        switch ($candidate.Source) {
            "npm_global" {
                $candidate.LogicalInstallKey = "npm_global:$candidateDirNorm"
                # .ps1 shim 如果有同目录 .cmd，标记为 shim companion
                if ($ext -eq '.ps1') {
                    $siblingCmd = Join-Path $candidateDir "claude.cmd"
                    if (Test-Path $siblingCmd) {
                        $candidate.ProbePath = $siblingCmd
                        $candidate.IsShimCompanion = $true
                        $candidate.CompanionOf = $siblingCmd
                        Write-Log "DEBUG" "Get-ClaudeCommandInventory: npm shim companion $($candidate.Path) -> $siblingCmd"
                    }
                }
            }
            "native_local_bin" {
                $candidate.LogicalInstallKey = "native_local_bin:$candidateDirNorm"
            }
            "winget" {
                $candidate.LogicalInstallKey = "winget:$candidateDirNorm"
            }
            "windowsapps" {
                $candidate.LogicalInstallKey = "windowsapps:$candidateDirNorm"
            }
            default {
                # 未知来源使用路径作为 fallback key
                $candidate.LogicalInstallKey = "unknown:$candidateDirNorm"
            }
        }
    }

    # ============================================================
    # Active 判定
    # ============================================================
    # 1. 首选 Get-Command claude 返回的第一个路径
    if ($firstCmdPath) {
        $firstNorm = _normalize $firstCmdPath
        foreach ($c in $inventory.Candidates) {
            if ((_normalize $c.Path) -eq $firstNorm) {
                $inventory.Active = $c
                break
            }
        }
    }

    # 2. 如果 Get-Command 没有返回，但 native_local_bin 可用
    if (-not $inventory.Active) {
        $nativeUsable = $inventory.Candidates | Where-Object { $_.Source -eq "native_local_bin" -and $_.Usable } | Select-Object -First 1
        if ($nativeUsable) { $inventory.Active = $nativeUsable }
    }

    # 3. 第一个候选兜底
    if (-not $inventory.Active -and $inventory.Candidates.Count -gt 0) {
        $inventory.Active = $inventory.Candidates[0]
    }

    # ============================================================
    # Conflict 判断 (v1.3.3 fix: 使用 LogicalInstallKey 去重)
    # ============================================================
    $hasConflict = $false
    $conflictReasons = [System.Collections.ArrayList]::new()

    # 计算 distinct logical sources（排除 IsShimCompanion 的 .ps1 文件）
    $nonCompanionCandidates = @($inventory.Candidates | Where-Object { -not $_.IsShimCompanion })
    $allLogicalKeys = @($nonCompanionCandidates | Where-Object { $_.LogicalInstallKey } | ForEach-Object { $_.LogicalInstallKey } | Select-Object -Unique)
    $distinctSourceCount = $allLogicalKeys.Count

    # fallback: 如果没有 LogicalInstallKey，用规范化路径
    if ($distinctSourceCount -eq 0) {
        $distinctSourceCount = @($nonCompanionCandidates | ForEach-Object { _normalize $_.Path } | Select-Object -Unique).Count
    }

    Write-Log "DEBUG" "Get-ClaudeCommandInventory: Candidates=$($inventory.Candidates.Count), NonCompanion=$($nonCompanionCandidates.Count), DistinctSources=$distinctSourceCount"

    # 多来源冲突：只有当 distinct logical source > 1 时才可能冲突
    $hasWA = (@($nonCompanionCandidates | Where-Object { $_.Source -eq "windowsapps" })).Count -gt 0
    $hasNativeOrNpm = (@($nonCompanionCandidates | Where-Object { $_.Source -in @("native_local_bin", "npm_global") })).Count -gt 0

    if ($distinctSourceCount -gt 1) {
        if ($hasWA -and $hasNativeOrNpm) {
            $hasConflict = $true
            [void]$conflictReasons.Add("WindowsApps alias 与 Native Install/npm 安装并存，可能冲突。")
        }
        elseif ($hasWA) {
            # WindowsApps + 其他非 native/npm 来源
            $hasConflict = $true
            [void]$conflictReasons.Add("WindowsApps alias 与其他 claude 来源并存，可能抢占真实 CLI。")
        }
        elseif ((@($nonCompanionCandidates | Where-Object { $_.Source -in @("native_local_bin", "npm_global", "winget") } | ForEach-Object { $_.LogicalInstallKey } | Select-Object -Unique)).Count -gt 1) {
            # 多个真正的安装来源 (native + npm, native + winget, npm + winget)
            $hasConflict = $true
            [void]$conflictReasons.Add("检测到多个 claude 安装来源（Native Install / npm / winget 并存），可能存在 PATH 优先级冲突。")
        }
    }

    # Active 不可用但其他 logical source 可用
    if ($inventory.Active -and -not $inventory.Active.Usable) {
        $usableOthers = @($nonCompanionCandidates | Where-Object { $_.Usable -and (_normalize $_.Path) -ne (_normalize $inventory.Active.Path) })
        if ($usableOthers) {
            $hasConflict = $true
            [void]$conflictReasons.Add("当前 PATH 优先命中的 claude 不可用，但其他路径存在可用 claude。")
        }
    }

    # Active 是 WindowsApps alias
    if ($inventory.Active -and $inventory.Active.Source -eq "windowsapps") {
        $hasConflict = $true
        [void]$conflictReasons.Add("WindowsApps alias 可能抢占真实 Claude Code CLI。")
    }

    # ERROR candidate 处理：跳过 claude.ps1 且同目录 claude.cmd 可用时不作为冲突
    $errorCandidates = @($nonCompanionCandidates | Where-Object { $_.Risk -eq "ERROR" })
    if ($errorCandidates.Count -gt 0) {
        $hasConflict = $true
        [void]$conflictReasons.Add("存在 $($errorCandidates.Count) 个无法运行的 claude 候选（残留或损坏）。")
    }

    $inventory.HasConflict = $hasConflict
    $inventory.ConflictSummary = ($conflictReasons -join " ")

    Write-Log "DEBUG" "Get-ClaudeCommandInventory: Candidates=$($inventory.Candidates.Count), MissingKnownPaths=$($inventory.MissingKnownPaths.Count), HasConflict=$hasConflict"
    if ($inventory.Active) {
        Write-Log "DEBUG" "Get-ClaudeCommandInventory: Active.Path=$($inventory.Active.Path), Active.Source=$($inventory.Active.Source), Active.Usable=$($inventory.Active.Usable)"
    }

    return $inventory
}

function Test-HttpEndpointReachable {
    <#
    .SYNOPSIS
        检测 HTTP 端点是否可达。
        对 403/404 不视为网络断开，只要 DNS/TLS/HTTP 有响应即可。
    .PARAMETER Url
        要检测的 URL
    .PARAMETER TimeoutSec
        超时秒数，默认 15
    .PARAMETER Method
        HTTP 方法，默认 HEAD
    .RETURNS
        包含 Reachable, StatusCode, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSec = 15,
        [string]$Method = "HEAD"
    )

    $result = @{
        Reachable  = $false
        StatusCode = 0
        Error      = ""
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -Method $Method `
            -TimeoutSec $TimeoutSec -UseBasicParsing `
            -ErrorAction Stop -MaximumRedirection 2

        $result.Reachable = $true
        $result.StatusCode = [int]$response.StatusCode
    }
    catch {
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                $result.StatusCode = $statusCode
                # 403/404 说明网络通，只是权限或路径问题
                if ($statusCode -eq 403 -or $statusCode -eq 404 -or $statusCode -eq 401) {
                    $result.Reachable = $true
                    Write-Log "DEBUG" "端点 $Url 返回 $statusCode（网络可达）"
                }
                else {
                    $result.Error = "HTTP $statusCode"
                }
            }
            elseif ($webEx.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                $result.Error = "连接超时"
            }
            elseif ($webEx.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
                $result.Error = "DNS 解析失败"
            }
            elseif ($webEx.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
                $result.Error = "无法连接到服务器"
            }
            else {
                $result.Error = "网络错误: $($webEx.Status)"
            }
        }
        else {
            $result.Error = $_.Exception.Message
        }
    }

    return $result
}

function Test-ClaudeOfficialInstallNetwork {
    <#
    .SYNOPSIS
        检测 Claude 官方安装通道是否可达。
        检测两个端点:
          1. https://claude.ai/install.ps1 — 必须 HTTP 200 且 GET 下载成功、内容非空
          2. https://downloads.claude.ai — DNS/TLS/HTTP 有响应即可（401/403/404/405 视为可达）
    .RETURNS
        包含 Reachable, InstallScriptOk, DownloadsOk, Details 的哈希表
    #>
    $result = @{
        Reachable       = $false
        InstallScriptOk = $false
        DownloadsOk     = $false
        Details         = ""
    }

    # Mock decision support（仅在 CCDI_MOCK_INSTALL_DECISION=1 且 CCDI_TEST_MODE=1 时生效）
    if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
        $mockOfficial = if ($env:CCDI_MOCK_OFFICIAL) { $env:CCDI_MOCK_OFFICIAL } else { "unreachable" }
        Write-Log "DEBUG" "MOCK: Test-ClaudeOfficialInstallNetwork -> CCDI_MOCK_OFFICIAL=$mockOfficial"
        if ($mockOfficial -eq "reachable") {
            return @{ Reachable = $true; InstallScriptOk = $true; DownloadsOk = $true; Details = "mock: official channel reachable" }
        }
        else {
            return @{ Reachable = $false; InstallScriptOk = $false; DownloadsOk = $false; Details = "mock: official channel unreachable" }
        }
    }

    Write-Log "DEBUG" "检测 Claude 官方安装通道..."

    # 1. 检测 install.ps1（严格检测：HTTP 200 + 内容下载成功且非空）
    # 不能用 Test-HttpEndpointReachable，它会把 401/403/404 当作 Reachable
    try {
        $response = Invoke-WebRequest -Uri "https://claude.ai/install.ps1" `
            -Method GET -TimeoutSec 15 -UseBasicParsing `
            -ErrorAction Stop -MaximumRedirection 3

        if ($response.StatusCode -eq 200) {
            $content = $response.Content
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $result.InstallScriptOk = $true
                Write-Log "DEBUG" "claude.ai/install.ps1 下载成功 (HTTP 200, $($content.Length) bytes)"
            }
            else {
                Write-Log "WARN" "claude.ai/install.ps1 返回 HTTP 200 但内容为空"
                $result.Details += "install.ps1 内容为空; "
            }
        }
        else {
            Write-Log "WARN" "claude.ai/install.ps1 返回非 200: HTTP $($response.StatusCode)"
            $result.Details += "install.ps1 HTTP $($response.StatusCode); "
        }
    }
    catch {
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                Write-Log "WARN" "claude.ai/install.ps1 返回 HTTP $statusCode（不视为可用）"
                $result.Details += "install.ps1 HTTP $statusCode; "
            }
            else {
                Write-Log "WARN" "claude.ai/install.ps1 不可达: $($webEx.Status)"
                $result.Details += "install.ps1 不可达 ($($webEx.Status)); "
            }
        }
        else {
            Write-Log "WARN" "claude.ai/install.ps1 请求异常: $($_.Exception.Message)"
            $result.Details += "install.ps1 请求异常; "
        }
    }

    # 2. 检测 downloads.claude.ai（宽松检测：有 HTTP 响应即可）
    $downloadsCheck = Test-HttpEndpointReachable -Url "https://downloads.claude.ai" -Method "HEAD" -TimeoutSec 10
    if ($downloadsCheck.Reachable) {
        $result.DownloadsOk = $true
        Write-Log "DEBUG" "downloads.claude.ai 可达 (HTTP $($downloadsCheck.StatusCode))"
    }
    else {
        Write-Log "WARN" "downloads.claude.ai 不可达: $($downloadsCheck.Error)"
        $result.Details += "无法访问 downloads.claude.ai ($($downloadsCheck.Error)); "
    }

    # 两者都可访问才算官方通道可用
    if ($result.InstallScriptOk -and $result.DownloadsOk) {
        $result.Reachable = $true
    }
    else {
        $result.Reachable = $false
        if (-not $result.Details) {
            $result.Details = "官方安装通道不可用"
        }
    }

    Write-Log "INFO" "Claude 官方安装通道: $(
        if ($result.Reachable) { "可用" } else { "不可用 - $($result.Details)" })"

    return $result
}

function Test-NpmMirrorClaudeCodeNetwork {
    <#
    .SYNOPSIS
        检测 npmmirror 的 @anthropic-ai/claude-code 包是否可访问。
        同时检测 Windows 平台二进制包和 npm 安装风险配置。
    .RETURNS
        包含 Reachable, NpmAvailable, NodeOk, Error,
        PlatformPackage, PlatformPackageReachable, PlatformPackageVersion,
        PlatformPackageError, NpmConfigWarnings 的哈希表
    #>
    $result = @{
        Reachable                = $false
        NpmAvailable             = $false
        NodeOk                   = $false
        Error                    = ""
        PlatformPackage          = ""
        PlatformPackageReachable = $false
        PlatformPackageVersion   = ""
        PlatformPackageError     = ""
        NpmConfigWarnings        = @()
    }

    # Mock decision support（仅在 CCDI_MOCK_INSTALL_DECISION=1 且 CCDI_TEST_MODE=1 时生效）
    if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
        $mockNode = if ($env:CCDI_MOCK_NODE) { $env:CCDI_MOCK_NODE } else { "missing" }
        $mockNpm = if ($env:CCDI_MOCK_NPM) { $env:CCDI_MOCK_NPM } else { "missing" }
        $mockMirror = if ($env:CCDI_MOCK_NPMMIRROR) { $env:CCDI_MOCK_NPMMIRROR } else { "unreachable" }
        Write-Log "DEBUG" "MOCK: Test-NpmMirrorClaudeCodeNetwork -> NODE=$mockNode NPM=$mockNpm NPMMIRROR=$mockMirror"

        if ($mockNode -eq "ok") {
            $result.NodeOk = $true
        }
        elseif ($mockNode -eq "old") {
            $result.NodeOk = $false
            $result.Error = "mock: Node.js version too old (needs >= 18)"
            return $result
        }
        else {
            $result.NodeOk = $false
            $result.Error = "mock: Node.js not installed"
            return $result
        }

        if ($mockNpm -eq "ok") {
            $result.NpmAvailable = $true
        }
        else {
            $result.NpmAvailable = $false
            $result.Error = if ($mockNpm -eq "broken") { "mock: npm command exists but fails" } else { "mock: npm not available" }
            return $result
        }

        if ($mockMirror -eq "reachable") {
            $result.Reachable = $true
            $result.PlatformPackageReachable = $true
            $result.PlatformPackageVersion = "1.0.0-mock"
        }
        else {
            $result.Reachable = $false
            $result.Error = "mock: npmmirror unreachable"
            $result.PlatformPackageError = "mock: platform package unreachable"
        }
        $result.NpmConfigWarnings = @()

        return $result
    }

    # 1. 检查 Node.js >= 18
    $nodeInfo = Test-NodeJsInstalled
    if (-not $nodeInfo.Installed -or -not $nodeInfo.IsSupported) {
        $result.Error = if (-not $nodeInfo.Installed) {
            "Node.js 未安装"
        }
        else {
            "Node.js 版本不满足要求: $($nodeInfo.Version)（需要 >= 18）"
        }
        Write-Log "WARN" $result.Error
        return $result
    }
    $result.NodeOk = $true

    # 2. 检查 npm
    $npmInfo = Test-NpmInstalled
    if (-not $npmInfo.Installed) {
        $result.Error = "npm 不可用"
        Write-Log "WARN" $result.Error
        return $result
    }
    $result.NpmAvailable = $true

    # 3. 检测 npmmirror 上的包（通过 npm.cmd + cmd.exe 执行，避免 npm.ps1 问题）
    $npmResolved = Resolve-NpmCmdPath
    if (-not $npmResolved.Found) {
        $result.Error = "npm.cmd 未找到: $($npmResolved.Error)"
        $result.Reachable = $false
        Write-Log "WARN" $result.Error
        return $result
    }

    $npmViewResult = Invoke-CommandSafe -Command $npmResolved.Path -Arguments @(
        "view",
        "@anthropic-ai/claude-code",
        "version",
        "--registry=https://registry.npmmirror.com"
    ) -TimeoutSec 60

    if ($npmViewResult.Success -and -not [string]::IsNullOrWhiteSpace($npmViewResult.Output)) {
        $result.Reachable = $true
        Write-Log "INFO" "npmmirror @anthropic-ai/claude-code 可达，版本: $($npmViewResult.Output.Trim())"
    }
    else {
        $result.Reachable = $false
        $result.Error = "无法从 npmmirror 获取 @anthropic-ai/claude-code 版本信息"
        Write-Log "WARN" "$($result.Error): $($npmViewResult.Error)"
    }

    # 4. 检测 Windows 平台二进制包
    $arch = $null
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    catch {
        $arch = $env:PROCESSOR_ARCHITECTURE
    }

    $platformPackage = ""
    switch -Wildcard ($arch) {
        "*x64*"   { $platformPackage = "@anthropic-ai/claude-code-win32-x64" }
        "*X64*"   { $platformPackage = "@anthropic-ai/claude-code-win32-x64" }
        "*AMD64*" { $platformPackage = "@anthropic-ai/claude-code-win32-x64" }
        "*arm64*" { $platformPackage = "@anthropic-ai/claude-code-win32-arm64" }
        "*Arm64*" { $platformPackage = "@anthropic-ai/claude-code-win32-arm64" }
        "*ARM64*" { $platformPackage = "@anthropic-ai/claude-code-win32-arm64" }
        default {
            $result.PlatformPackageError = "未知架构 ($arch)，跳过平台包检测"
            Write-Log "INFO" $result.PlatformPackageError
        }
    }
    $result.PlatformPackage = $platformPackage

    if ($platformPackage) {
        $platViewResult = Invoke-CommandSafe -Command $npmResolved.Path -Arguments @(
            "view",
            $platformPackage,
            "version",
            "--registry=https://registry.npmmirror.com"
        ) -TimeoutSec 60

        if ($platViewResult.Success -and -not [string]::IsNullOrWhiteSpace($platViewResult.Output)) {
            $result.PlatformPackageReachable = $true
            $result.PlatformPackageVersion = $platViewResult.Output.Trim()
            Write-Log "INFO" "npmmirror 平台包可达: $platformPackage $($result.PlatformPackageVersion)"
        }
        else {
            $result.PlatformPackageReachable = $false
            $result.PlatformPackageError = if ($platViewResult.Error) { $platViewResult.Error } else { "平台包版本查询失败" }
            Write-Log "WARN" "npmmirror 主包可达，但平台包不可达: $platformPackage, Error=$($result.PlatformPackageError)"
        }
    }

    # 5. 检测 npm 安装风险配置
    $npmRisk = Get-NpmInstallRiskConfig
    if ($npmRisk -and $npmRisk.Warnings) {
        $result.NpmConfigWarnings = $npmRisk.Warnings
        foreach ($w in $npmRisk.Warnings) {
            Write-Log "WARN" $w
        }
    }

    return $result
}

function Get-NpmInstallRiskConfig {
    <#
    .SYNOPSIS
        检测 npm 安装风险配置：optional, omit, ignore-scripts, registry。
    .RETURNS
        包含 Optional, Omit, IgnoreScripts, Registry, Warnings 的哈希表
    #>
    $result = @{
        Optional       = ""
        Omit           = ""
        IgnoreScripts  = ""
        Registry       = ""
        Warnings       = [System.Collections.ArrayList]::new()
    }

    $npmResolved = Resolve-NpmCmdPath
    if (-not $npmResolved.Found) {
        [void]$result.Warnings.Add("npm.cmd 未找到，无法检查 npm 安装风险配置。")
        return $result
    }

    $configKeys = @("optional", "omit", "ignore-scripts", "registry")
    $configValues = @{}

    foreach ($key in $configKeys) {
        $configResult = Invoke-CommandSafe -Command $npmResolved.Path -Arguments @(
            "config", "get", $key
        ) -TimeoutSec 8

        $val = ""
        if ($configResult.Success -and $configResult.Output) {
            $val = $configResult.Output.Trim()
        }
        $configValues[$key] = $val
    }

    $result.Optional = $configValues["optional"]
    $result.Omit = $configValues["omit"]
    $result.IgnoreScripts = $configValues["ignore-scripts"]
    $result.Registry = $configValues["registry"]

    # 风险判断
    if ($result.Optional -eq "false") {
        [void]$result.Warnings.Add("npm optional dependency 被禁用，Claude Code 平台二进制包可能不会安装。建议执行 npm config delete optional。")
    }

    if ($result.Omit -and $result.Omit -match "optional") {
        [void]$result.Warnings.Add("npm omit 包含 optional，可能跳过平台二进制包。建议执行 npm config delete omit。")
    }

    if ($result.IgnoreScripts -eq "true") {
        [void]$result.Warnings.Add("npm scripts 被禁用，可能影响安装后 shim 生成。建议执行 npm config set ignore-scripts false。")
    }

    Write-Log "DEBUG" "Get-NpmInstallRiskConfig: optional=$($result.Optional), omit=$($result.Omit), ignore-scripts=$($result.IgnoreScripts), registry=$($result.Registry), warnings=$($result.Warnings.Count)"

    return $result
}

# ============================================================

function Test-IsClaudeNativeFileLockError {
    <#
    .SYNOPSIS
        检测 Native Install 失败输出中是否包含文件占用错误。
    .PARAMETER Text
        错误输出文本（英文或中文）。
    .RETURNS
        是否匹配文件占用错误特征。
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    return (
        $Text -match "used by another process" -or
        $Text -match "being used by another process" -or
        $Text -match "The process cannot access the file" -or
        $Text -match "because it is being used by another process" -or
        $Text -match "Access to the path" -or
        $Text -match "\bis denied\b" -or
        $Text -match "文件正由另一进程使用" -or
        $Text -match "无法访问该文件" -or
        $Text -match "拒绝访问" -or
        $Text -match "另一个程序正在使用此文件" -or
        $Text -match "\.claude\\downloads" -or
        $Text -match "\.claude/downloads"
    )
}

function Write-NativeInstallUserMessage {
    <#
    .SYNOPSIS
        v1.3.3 UX: 统一 Native Install 用户可见文案。
        确保后验验证前不显示"失败"，ExitCode 异常只写日志。
    .PARAMETER Phase
        阶段: Start | Verify | Success | Partial | Fallback
    .PARAMETER Detail
        附加信息（如版本号）
    #>
    param(
        [ValidateSet("Start", "Verify", "Success", "Partial", "Fallback")]
        [string]$Phase,
        [string]$Detail = ""
    )

    switch ($Phase) {
        "Start" {
            Write-Info "正在执行 Claude 官方安装包。"
            Write-Info "此步骤可能持续数分钟，中途没有新文字也正常，请不要关闭窗口。"
            Write-Info "安装完成后，本工具会自动验证结果。"
        }
        "Verify" {
            Write-Info "正在确认安装结果..."
        }
        "Success" {
            Write-Success "Claude Code 已安装并确认可用。"
            Write-Log "INFO" "claude --version 可用，新 PowerShell 验证通过: $Detail"
        }
        "Partial" {
            Write-Warning "Claude Code 已安装，但新打开的 PowerShell 还没有确认可用。"
            Write-Info "本工具会继续完成配置。安装结束后请按完成页提示验证或修复。"
        }
        "Fallback" {
            Write-Warning "当前安装方式未完成，正在自动切换备用方式。"
            Write-Info "这通常是网络或系统环境导致，不代表整个安装失败。"
            Write-Log "INFO" "Native Install not verified; fallback to winget/npm"
        }
    }
}

function Format-CcdiElapsedTime {
    <#
    .SYNOPSIS
        v1.3.3 P0 fix: 安全格式化已用秒数为 MM:SS。
        [Math]::Floor 在 PS5.1 下返回 Double，D2 不接受 Double，
        必须显式转换为 [int] 后再格式化。
    .PARAMETER Seconds
        已用秒数（支持 double）
    .RETURNS
        "MM:SS" 格式字符串
    .NOTES
        所有 D2 参数必须是 [int]，避免 PS5.1 下出现"格式说明符无效"。
    #>
    param([double]$Seconds)

    $elapsedInt = [int][Math]::Max(0, [Math]::Round($Seconds, 0))
    $minutes = [int][Math]::Floor($elapsedInt / 60)
    $secondsPart = [int]($elapsedInt % 60)

    return ("{0:D2}:{1:D2}" -f $minutes, $secondsPart)
}

function Invoke-InstallCommandCaptured {
    <#
    .SYNOPSIS
        v1.3.3 P1-2: 执行安装命令，捕获 stdout/stderr 写入日志，控制台只显示中文心跳。
        用于减少 Native Install/npm 等安装过程中的英文输出，提升小白用户体验。
    .PARAMETER FilePath
        要执行的可执行文件路径
    .PARAMETER Arguments
        命令行参数数组
    .PARAMETER TimeoutSec
        超时秒数，默认 600
    .PARAMETER HeartbeatSec
        心跳输出间隔秒数，默认 30
    .PARAMETER FriendlyName
        友好名称，用于心跳提示
    .RETURNS
        包含 Success, ExitCode, Output, Error, StdOutPath, StdErrPath 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 600,
        [int]$HeartbeatSec = 30,
        [string]$FriendlyName = "安装命令",
        [string]$StartMessage = "",
        [string]$HeartbeatMessage = "",
        [string]$TimeoutMessage = "",
        [string]$TimeoutFollowupMessage = "详细错误已写入日志，请运行「一键诊断.cmd」排查。",
        # v1.3.3 UX: 紧凑中文进度模式
        [string]$ProgressTitle = "",
        [string]$ProgressHint = "",
        [int]$ProgressIntervalSec = 10,
        # v1.3.3 UX: 慢速提示（避免超过 120s 时用户误以为卡死）
        [int]$SlowNoticeAfterSec = 0,
        [string]$SlowNoticeMessage = ""
    )

    $result = @{
        Success         = $false
        ExitCode        = -1
        Output          = ""
        Error           = ""
        SanitizedOutput = ""
        SanitizedError  = ""
        TimedOut        = $false
        DurationMs      = 0
        StdOutPath      = ""
        StdErrPath      = ""
    }

    $stdout = Join-Path $env:TEMP "ccdi_captured_stdout_${PID}_$(Get-Random).log"
    $stderr = Join-Path $env:TEMP "ccdi_captured_stderr_${PID}_$(Get-Random).log"
    $result.StdOutPath = $stdout
    $result.StdErrPath = $stderr

    # 默认消息 — 使用 PSBoundParameters 区分"未传参数"和"显式传空字符串"
    $hasStartMessage = $PSBoundParameters.ContainsKey("StartMessage")
    $hasHeartbeatMessage = $PSBoundParameters.ContainsKey("HeartbeatMessage")
    $hasTimeoutMessage = $PSBoundParameters.ContainsKey("TimeoutMessage")

    # v1.3.3 UX: 紧凑进度模式（ShowUserProgress）
    # 如果指定了 -ProgressTitle，启用短中文进度条（每 10s 一条），不再使用长句 heartbeat
    $showCompactProgress = $PSBoundParameters.ContainsKey("ProgressTitle") -and -not [string]::IsNullOrWhiteSpace($ProgressTitle)
    if ($showCompactProgress) {
        $effectiveHeartbeatSec = if ($PSBoundParameters.ContainsKey("ProgressIntervalSec")) { $ProgressIntervalSec } else { 10 }
    }
    else {
        $effectiveHeartbeatSec = $HeartbeatSec
    }

    if (-not $hasStartMessage) {
        $StartMessage = "正在执行 $FriendlyName..."
    }
    if (-not $hasHeartbeatMessage) {
        $HeartbeatMessage = "仍在执行 $FriendlyName，请继续等待，不要关闭窗口。"
    }
    if (-not $hasTimeoutMessage) {
        $TimeoutMessage = "$FriendlyName 超时，已停止。请运行一键诊断。"
    }

    if (-not [string]::IsNullOrWhiteSpace($StartMessage)) {
        Write-Info $StartMessage
    }

    $proc = $null

    try {
        # v1.3.3 fix: Start-Process 的 ArgumentList 数组在 PS5.1 下会错误拆分
        # 含空格/中文/元字符的参数。FilePath 与参数保持独立，避免 CMD 再解释参数。
        $startParams = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $stdout
            RedirectStandardError  = $stderr
        }
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
            $startParams.ArgumentList = ConvertTo-CommandLine -Arguments $Arguments
        }

        $proc = Start-Process @startParams
        # Windows PowerShell 5.1 必须在进程退出前访问 Handle，才能可靠读取 ExitCode。
        $null = $proc.Handle

        Write-Log "INFO" "Invoke-InstallCommandCaptured: started PID=$($proc.Id), FriendlyName=$FriendlyName"

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $pollIntervalSec = 1
        $nextHeartbeatAt = [Math]::Max(1, $effectiveHeartbeatSec)
        $slowNoticeShown = $false

        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $pollIntervalSec
            $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 0)

            if ($elapsed -ge $nextHeartbeatAt) {
                if ($showCompactProgress) {
                    $hintPart = if ($ProgressHint) { " | $ProgressHint" } else { "" }
                    try {
                        $elapsedFormatted = Format-CcdiElapsedTime -Seconds $elapsed
                        Write-Info "[进度] $ProgressTitle | 已等待 $elapsedFormatted | 状态：正常$hintPart"
                    }
                    catch {
                        Write-Log "WARN" "进度提示格式化失败，已降级为秒数显示: $($_.Exception.Message)"
                        Write-Info "[进度] $ProgressTitle | 已等待 $elapsed 秒 | 状态：正常$hintPart"
                    }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($HeartbeatMessage)) {
                    Write-Info "$HeartbeatMessage（已等待 $elapsed 秒）"
                }
                $nextHeartbeatAt += [Math]::Max(1, $effectiveHeartbeatSec)
            }

            # v1.3.3 UX: 慢速提示（仅输出一次，避免超过阈值时间时用户误以为卡死）
            if (
                $SlowNoticeAfterSec -gt 0 -and
                -not $slowNoticeShown -and
                $elapsed -ge $SlowNoticeAfterSec -and
                -not [string]::IsNullOrWhiteSpace($SlowNoticeMessage)
            ) {
                Write-Info $SlowNoticeMessage
                $slowNoticeShown = $true
            }

            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                Write-Log "WARN" "Invoke-InstallCommandCaptured: timeout ${TimeoutSec}s, killing PID=$($proc.Id)"
                try {
                    & taskkill.exe /PID $proc.Id /T /F 2>$null
                    $proc.WaitForExit(5000) | Out-Null
                }
                catch { }
                $result.TimedOut = $true
                $result.Error = "timeout: ${TimeoutSec}s"
                $result.DurationMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 0)

                # 超时前尝试读取已写入的部分 stdout/stderr（临时文件由 finally 清理）
                if (Test-Path $stdout) {
                    try {
                        $partialOut = Get-Content $stdout -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($partialOut) {
                            $result.Output = $partialOut
                            $result.SanitizedOutput = Sanitize-SecretLikeText -Text (Remove-AnsiEscape -Text $partialOut)
                            Write-Log "DEBUG" "Timeout partial stdout: $($result.SanitizedOutput)"
                        }
                    } catch { }
                }
                if (Test-Path $stderr) {
                    try {
                        $partialErr = Get-Content $stderr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($partialErr) {
                            $result.Error = $partialErr
                            $result.SanitizedError = Sanitize-SecretLikeText -Text (Remove-AnsiEscape -Text $partialErr)
                            Write-Log "DEBUG" "Timeout partial stderr: $($result.SanitizedError)"
                        }
                    } catch { }
                }

                if (-not [string]::IsNullOrWhiteSpace($TimeoutMessage)) {
                    Write-Warning $TimeoutMessage
                }
                else {
                    Write-Warning "$FriendlyName 超时，已停止。请运行一键诊断。"
                }
                if (-not [string]::IsNullOrWhiteSpace($TimeoutFollowupMessage)) {
                    Write-Info $TimeoutFollowupMessage
                }
                return $result
            }
        }

        $proc.WaitForExit()
        $proc.Refresh()
        try {
            $capturedExitCode = $proc.ExitCode
            if ($null -eq $capturedExitCode) {
                throw "process exit code is unavailable"
            }
            $result.ExitCode = [int]$capturedExitCode
        }
        catch {
            # 某些 .cmd 入口在 Windows PowerShell 5.1 下无法提供退出码。
            # 保持明确的未知值，调用方继续依靠现有安装后验证判断结果。
            $result.ExitCode = -1
        }
        $result.Success = ($result.ExitCode -eq 0)
        $result.DurationMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 0)

        # 读取捕获的输出
        if (Test-Path $stdout) {
            try {
                $result.Output = Get-Content $stdout -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not $result.Output) { $result.Output = "" }
            }
            catch { }
        }
        if (Test-Path $stderr) {
            try {
                $result.Error = Get-Content $stderr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                if (-not $result.Error) { $result.Error = "" }
            }
            catch { }
        }

        # 脱敏和 ANSI 清理后写入日志
        if ($result.Output) {
            $result.SanitizedOutput = Sanitize-SecretLikeText -Text (Remove-AnsiEscape -Text $result.Output)
            Write-Log "INFO" "Invoke-InstallCommandCaptured($FriendlyName): stdout ($($result.Output.Length) chars)"
            Write-Log "DEBUG" "Captured stdout: $($result.SanitizedOutput)"
        }
        if ($result.Error) {
            $result.SanitizedError = Sanitize-SecretLikeText -Text (Remove-AnsiEscape -Text $result.Error)
            Write-Log "INFO" "Invoke-InstallCommandCaptured($FriendlyName): stderr ($($result.Error.Length) chars)"
            Write-Log "DEBUG" "Captured stderr: $($result.SanitizedError)"
        }

        Write-Log "INFO" "Invoke-InstallCommandCaptured($FriendlyName): ExitCode=$($result.ExitCode), DurationMs=$($result.DurationMs)"
    }
    catch {
        $result.Error = "Invoke-InstallCommandCaptured 异常: $($_.Exception.Message)"
        Write-Log "ERROR" $result.Error
        # 内部异常时必须终止已启动的子进程树，避免后台安装器残留继续运行
        if ($null -ne $proc -and -not $proc.HasExited) {
            Write-Log "WARN" "Invoke-InstallCommandCaptured 内部异常，正在终止子进程树 PID=$($proc.Id)，避免后台安装器残留。"
            try {
                & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
                $proc.WaitForExit(5000) | Out-Null
            }
            catch {
                Write-Log "WARN" "内部异常后终止子进程树失败: $($_.Exception.Message)"
            }
        }
    }
    finally {
        # 清理临时文件
        foreach ($tmp in @($stdout, $stderr)) {
            if ($tmp -and (Test-Path $tmp)) {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $result
}

function Install-ClaudeCodeNative {
    <#
    .SYNOPSIS
        使用 Claude 官方 Native Install 安装 Claude Code。
        执行: irm https://claude.ai/install.ps1 | iex
    .PARAMETER TestSafe
        测试安全模式：不执行实际安装。
    .RETURNS
        包含 Success, Error, RawError 的哈希表
    #>
    param(
        [switch]$TestSafe
    )

    $result = @{
        Success   = $false
        Error     = ""
        RawError  = ""
        Status    = ""
    }

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        # Mock decision support（仅在 CCDI_MOCK_INSTALL_DECISION=1 时覆盖 TestSafe 行为）
        if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
            $mockNative = if ($env:CCDI_MOCK_NATIVE_INSTALL) { $env:CCDI_MOCK_NATIVE_INSTALL } else { "fail" }
            Write-Log "DEBUG" "MOCK: Install-ClaudeCodeNative -> CCDI_MOCK_NATIVE_INSTALL=$mockNative"
            if ($mockNative -eq "success") {
                return @{ Success = $true; Error = ""; RawError = ""; Status = "installed_mock" }
            }
            else {
                return @{ Success = $false; Error = "mock: native install failed"; RawError = "mock: native install failed"; Status = "failed_mock" }
            }
        }
        Write-Log "INFO" "TestSafe: 跳过 Native Install 执行"
        $result.Status = "skipped_test_safe"
        $result.Error = "skipped_test_safe"
        return $result
    }

    Write-NativeInstallUserMessage -Phase "Start"
    Write-Log "INFO" "下载 Claude 官方安装脚本: https://claude.ai/install.ps1"

    try {
        $tempInstallScript = Join-Path $env:TEMP "claude_native_install_${PID}_$(Get-Random).ps1"
        $downloadResult = Invoke-VisibleFileDownload -Url "https://claude.ai/install.ps1" `
            -OutputPath $tempInstallScript -TimeoutSec 30 -TestSafe:$TestSafe

        if (-not $downloadResult.Success) {
            # 详细错误仅写入日志，主界面只显示友好提示
            $result.Error = "下载官方安装脚本失败: $($downloadResult.Status)"
            $result.RawError = $downloadResult.Error
            Write-Log "ERROR" "Native Install 下载失败: Url=$($downloadResult.Url), Status=$($downloadResult.Status), Error=$($downloadResult.Error), DurationMs=$($downloadResult.DurationMs)"
            Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue
            return $result
        }

        Write-Info "官方安装脚本已下载，开始安装..."

        # v1.3.3 P1-2: 默认使用捕获模式，英文输出写入日志，控制台只显示中文紧凑进度
        $installResult = Invoke-InstallCommandCaptured -FilePath "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempInstallScript
        ) -TimeoutSec 300 -FriendlyName "Claude 官方安装包" `
            -StartMessage "" `
            -ProgressIntervalSec 10 `
            -ProgressTitle "Claude Code 官方安装中" `
            -ProgressHint "如果网络较慢会自动切换备用方式" `
            -SlowNoticeAfterSec 120 `
            -SlowNoticeMessage "官方安装较慢，工具仍在等待；如果超过约 5 分钟会自动切换备用方式。" `
            -TimeoutMessage "官方安装已等待约 5 分钟，正在确认安装结果；如未成功会自动切换备用方式。" `
            -TimeoutFollowupMessage ""

        # 清理临时脚本
        Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue

        # 安装脚本执行结束，记录 ExitCode 状态到日志（不向用户展示）
        Write-NativeInstallUserMessage -Phase "Verify"

        if ($installResult.Success) {
            Write-Log "INFO" "Native Install 安装脚本 ExitCode=0"
        }
        else {
            # 只记录详细错误到日志，不向用户展示 PowerShell 堆栈或失败提示
            $result.Error = "Native Install 安装脚本 ExitCode 为空或非零"
            $result.RawError = $installResult.Error
            Write-Log "INFO" "Native Install 安装脚本 ExitCode 为空或非零 (ExitCode=$($installResult.ExitCode), DurationMs=$($installResult.DurationMs))，将进行后验验证判断真实结果"
            if ($installResult.Error) {
                Write-Log "DEBUG" "Native Install 详情: Error=$($installResult.Error)"
            }
        }
    }
    catch {
        # 异常也写入日志，由后验验证决定最终结论
        $result.Error = "Native Install 异常: $($_.Exception.Message)"
        $result.RawError = $_.Exception.ToString()
        Write-Log "INFO" "Native Install 安装器异常（将进行后验验证）: $($_.Exception.Message)"

        # 清理可能残留的临时文件
        if ($tempInstallScript -and (Test-Path $tempInstallScript)) {
            Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Install-ClaudeCodeNpmMirror {
    <#
    .SYNOPSIS
        通过 npm + npmmirror 镜像安装 Claude Code。
        执行: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com
    .PARAMETER TestSafe
        测试安全模式：不执行实际安装。
    .RETURNS
        包含 Success, Error 的哈希表
    #>
    param(
        [switch]$TestSafe
    )

    $result = @{
        Success = $false
        Error   = ""
        Status  = ""
    }

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        # Mock decision support（仅在 CCDI_MOCK_INSTALL_DECISION=1 时覆盖 TestSafe 行为）
        if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
            $mockNpmInstall = if ($env:CCDI_MOCK_NPM_INSTALL) { $env:CCDI_MOCK_NPM_INSTALL } else { "fail" }
            Write-Log "DEBUG" "MOCK: Install-ClaudeCodeNpmMirror -> CCDI_MOCK_NPM_INSTALL=$mockNpmInstall"
            if ($mockNpmInstall -eq "success") {
                return @{ Success = $true; Error = ""; Status = "installed_mock" }
            }
            else {
                return @{ Success = $false; Error = "mock: npm mirror install failed"; Status = "failed_mock" }
            }
        }
        Write-Log "INFO" "TestSafe: 跳过 npm mirror 安装"
        $result.Status = "skipped_test_safe"
        $result.Error = "skipped_test_safe"
        return $result
    }

    Write-Log "INFO" "Installing via npm mirror (npmmirror.com/@anthropic-ai/claude-code)"
    Write-Info "正在通过备用下载方式安装 Claude Code。"
    Write-Info "这一步可能需要几分钟，请不要关闭窗口。"

    # 解析 npm.cmd（禁止使用 npm.ps1，会导致 "%1 is not a valid Win32 application"）
    $npmResolved = Resolve-NpmCmdPath
    if (-not $npmResolved.Found) {
        $result.Error = "未找到 npm.cmd: $($npmResolved.Error)"
        $result.Status = "failed_missing_npm_cmd"
        Write-Error-Msg "未找到必要运行环境，无法通过备用方式安装。"
        Write-Info "请关闭窗口重新打开后重试，或重新安装 Node.js LTS。"
        Write-Log "ERROR" "npm.cmd not found, cannot proceed with npm mirror install"
        Write-Log "ERROR" $result.Error
        return $result
    }

    Write-Log "INFO" "执行: $($npmResolved.Path) install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"

    # v1.3.3 UX: 使用捕获模式，英文输出写入日志，控制台只显示中文紧凑进度
    $installResult = Invoke-InstallCommandCaptured -FilePath $npmResolved.Path -Arguments @(
        "install",
        "-g",
        "@anthropic-ai/claude-code",
        "--registry=https://registry.npmmirror.com"
    ) -TimeoutSec 900 -FriendlyName "npm 镜像安装 Claude Code" `
        -StartMessage "" `
        -ProgressIntervalSec 10 `
        -ProgressTitle "Claude Code 备用下载方式安装中" `
        -ProgressHint "正在从备用下载源获取 Claude Code" `
        -SlowNoticeAfterSec 120 `
        -SlowNoticeMessage "备用下载方式较慢，工具仍在等待；如果长时间无结果，请稍后运行一键诊断。" `
        -TimeoutMessage "备用下载方式等待过久，正在确认安装结果。" `
        -TimeoutFollowupMessage "如果后续仍未成功，请运行「一键诊断.cmd」。"

    if ($installResult.Success) {
        Write-Success "Claude Code 备用下载方式安装完成。"
        Write-Log "INFO" "npm mirror 安装成功"
        $result.Success = $true
    }
    else {
        # 不在此处输出失败结论，由调用方后验验证决定最终结果。
        # npm install ExitCode 在 Windows PowerShell 5.1 下可能为空或非标准。
        $result.Error = "npm 镜像安装命令返回异常: $($installResult.Error)"
        Write-Log "INFO" "npm 镜像安装命令返回异常（ExitCode 可能为空或非标准），由调用方后验验证决定最终结果。"
        Write-Log "DEBUG" "npm mirror install details: ExitCode=$($installResult.ExitCode), Error=$($installResult.Error), DurationMs=$($installResult.DurationMs)"
    }

    return $result
}

function Clear-StaleClaudeDoctorProcesses {
    <#
    .SYNOPSIS
        清理残留的 claude doctor 孤儿进程。
        支持两种模式：
          - 未传 -ParentPid：全局保守模式，只清理陈旧的 claude.exe doctor，避免误杀。
          - 传了 -ParentPid：限域清理，通过进程树 descendant 匹配，覆盖
            claude.exe / node.exe / cmd.exe / powershell.exe / pwsh.exe 等 npm 安装场景。
        不杀普通 claude 会话 (--resume / --continue 等)。
    .PARAMETER MinAgeSec
        进程最小存活时间（秒），短于此时间的不杀。默认 60。
    .PARAMETER Force
        强制清理所有 doctor 进程，不检查存活时间。
    .PARAMETER ParentPid
        限制只清理指定父 PID 的进程树后裔。不指定则全局保守清理（仅 claude.exe）。
    .RETURNS
        包含 KilledCount, Errors 的哈希表
    .NOTES
        全局模式不清理 node.exe / cmd.exe / powershell.exe / pwsh.exe，防止误杀。
    #>
    param(
        [int]$MinAgeSec = 60,
        [switch]$Force,
        [int]$ParentPid = 0
    )

    $result = @{
        KilledCount = 0
        Errors      = [System.Collections.ArrayList]::new()
    }

    # --- 进程树后裔检测 ---
    function Test-IsDescendantProcess {
        param(
            [object]$Proc,
            [hashtable]$ProcById,
            [int]$RootPid
        )

        $seen = @{}
        $current = $Proc
        while ($current -and $current.ParentProcessId) {
            $ppid = [int]$current.ParentProcessId
            if ($ppid -eq $RootPid) { return $true }
            if ($seen.ContainsKey($ppid)) { return $false }
            $seen[$ppid] = $true
            if (-not $ProcById.ContainsKey($ppid)) { return $false }
            $current = $ProcById[$ppid]
        }
        return $false
    }

    try {
        $now = Get-Date
        $myPid = $PID
        $isScoped = ($ParentPid -gt 0)

        if ($isScoped) {
            # ====================================================
            # 限域模式：进程树 descendant 匹配，覆盖 npm / cmd 场景
            # ====================================================
            Write-Log "DEBUG" "Clear-StaleClaudeDoctorProcesses: scoped cleanup ParentPid=$ParentPid"

            $allProcs = @()
            try {
                $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
                if (-not $allProcs -or $allProcs.Count -eq 0) {
                    $allProcs = @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue)
                }
            }
            catch {
                Write-Log "DEBUG" "获取所有进程失败: $_"
            }

            if (-not $allProcs -or $allProcs.Count -eq 0) {
                Write-Log "DEBUG" "Clear-StaleClaudeDoctorProcesses: 没有查询到任何进程"
                return $result
            }

            # 构建 ProcessId 映射
            $procById = @{}
            foreach ($p in $allProcs) {
                try {
                    $pidKey = [int]$p.ProcessId
                    if ($pidKey -gt 0 -and -not $procById.ContainsKey($pidKey)) {
                        $procById[$pidKey] = $p
                    }
                }
                catch { }
            }

            # 筛选条件
            $candidates = @($allProcs | Where-Object {
                try {
                    $procId = $_.ProcessId
                    if (-not $procId -or $procId -eq $myPid) { return $false }

                    $name = if ($_.Name) { $_.Name.ToLowerInvariant() } else { "" }
                    $cmd  = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { "" }

                    $isDescendant = Test-IsDescendantProcess -Proc $_ -ProcById $procById -RootPid $ParentPid
                    if (-not $isDescendant) { return $false }

                    $isDoctor = $cmd -match '(^|[\s"''`=])doctor([\s"''`]|$)'
                    if (-not $isDoctor) { return $false }

                    $isClaudeLike =
                        ($name -in @("claude.exe", "node.exe", "cmd.exe", "powershell.exe", "pwsh.exe")) -and
                        (
                            $cmd -match 'claude' -or
                            $cmd -match 'anthropic' -or
                            $cmd -match 'claude-code'
                        )

                    return $isClaudeLike
                }
                catch {
                    return $false
                }
            })

            # ProcessId 去重
            $candidates = @($candidates | Sort-Object -Property ProcessId -Unique)

            foreach ($proc in $candidates) {
                $procId = $proc.ProcessId
                $cmdLine = if ($proc.CommandLine) { $proc.CommandLine } else { "" }
                $procName = if ($proc.Name) { $proc.Name } else { "(unknown)" }

                # 存活时间过滤
                if (-not $Force) {
                    $creationDate = $proc.CreationDate
                    if ($creationDate) {
                        $age = ($now - $creationDate).TotalSeconds
                        if ($age -lt $MinAgeSec) {
                            Write-Log "DEBUG" "scoped: 跳过较新进程 PID=$procId Name=$procName (存活 ${age}s < ${MinAgeSec}s)"
                            continue
                        }
                    }
                }

                Write-Log "INFO" "scoped cleanup: 正在清理残留 doctor 进程 PID=$procId, Name=$procName, CommandLine=$cmdLine"

                $killed = $false
                $killError = ""
                try {
                    $taskkillResult = & taskkill.exe /PID $procId /T /F 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $killed = $true
                        Write-Log "INFO" "已终止进程树 PID=$($procId): $taskkillResult"
                    }
                    else {
                        $killError = "taskkill 返回码 $LASTEXITCODE, 输出: $taskkillResult"
                    }
                }
                catch {
                    $killError = "taskkill 异常: $_"
                }

                if (-not $killed) {
                    try {
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        $killed = $true
                        Write-Log "INFO" "已通过 Stop-Process 终止进程 PID=$procId"
                    }
                    catch {
                        $killError += "; Stop-Process 也失败: $_"
                    }
                }

                if ($killed) {
                    $result.KilledCount++
                }
                else {
                    [void]$result.Errors.Add("scoped: 无法终止 PID=$($procId): $killError")
                    Write-Log "ERROR" "Clear-StaleClaudeDoctorProcesses(scoped): 无法终止 PID=$($procId): $killError"
                }
            }

            Write-Log "INFO" "Clear-StaleClaudeDoctorProcesses(scoped): 清理完成，共终止 $($result.KilledCount) 个残留 doctor 进程"
        }
        else {
            # ====================================================
            # 全局保守模式：只清理陈旧的 claude.exe doctor
            # ====================================================
            Write-Log "DEBUG" "Clear-StaleClaudeDoctorProcesses: global stale claude.exe doctor cleanup"

            $claudeProcs = $null
            try {
                $claudeProcs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop
            }
            catch {
                try {
                    $claudeProcs = Get-WmiObject Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop
                }
                catch {
                    [void]$result.Errors.Add("无法查询 claude 进程: $_")
                    Write-Log "ERROR" "Clear-StaleClaudeDoctorProcesses: 无法查询进程列表: $_"
                    return $result
                }
            }

            if (-not $claudeProcs -or @($claudeProcs).Count -eq 0) {
                Write-Log "DEBUG" "Clear-StaleClaudeDoctorProcesses: 没有找到 claude.exe 进程"
                return $result
            }

            foreach ($proc in $claudeProcs) {
                $procId = $proc.ProcessId
                $cmdLine = if ($proc.CommandLine) { $proc.CommandLine } else { "" }

                # 只杀命令行包含 "doctor" 的进程
                if (-not ($proc.CommandLine -match 'doctor')) {
                    continue
                }

                # 不杀自己
                if ($procId -eq $myPid) {
                    continue
                }

                # 检查存活时间（除非 -Force）
                if (-not $Force) {
                    $creationDate = $proc.CreationDate
                    if ($creationDate) {
                        $age = ($now - $creationDate).TotalSeconds
                        if ($age -lt $MinAgeSec) {
                            Write-Log "DEBUG" "global: 跳过较新的 claude doctor 进程 PID=$procId (存活 ${age}s < ${MinAgeSec}s)"
                            continue
                        }
                    }
                }

                Write-Log "INFO" "global cleanup: 正在清理残留 claude doctor 进程 PID=$procId, CommandLine=$cmdLine"

                $killed = $false
                $killError = ""
                try {
                    $taskkillResult = & taskkill.exe /PID $procId /T /F 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $killed = $true
                        Write-Log "INFO" "已终止 claude doctor 进程树 PID=$($procId): $taskkillResult"
                    }
                    else {
                        $killError = "taskkill 返回码 $LASTEXITCODE, 输出: $taskkillResult"
                    }
                }
                catch {
                    $killError = "taskkill 异常: $_"
                }

                if (-not $killed) {
                    try {
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        $killed = $true
                        Write-Log "INFO" "已通过 Stop-Process 终止 claude doctor 进程 PID=$procId"
                    }
                    catch {
                        $killError += "; Stop-Process 也失败: $_"
                    }
                }

                if ($killed) {
                    $result.KilledCount++
                }
                else {
                    [void]$result.Errors.Add("global: 无法终止 PID=$($procId): $killError")
                    Write-Log "ERROR" "Clear-StaleClaudeDoctorProcesses(global): 无法终止 PID=$($procId): $killError"
                }
            }

            Write-Log "INFO" "Clear-StaleClaudeDoctorProcesses(global): 清理完成，共终止 $($result.KilledCount) 个残留 doctor 进程"
        }
    }
    catch {
        [void]$result.Errors.Add("Clear-StaleClaudeDoctorProcesses 异常: $_")
        Write-Log "ERROR" "Clear-StaleClaudeDoctorProcesses 异常: $_"
    }

    return $result
}

function Invoke-ClaudeDoctorSafe {
    <#
    .SYNOPSIS
        安全运行 claude doctor，失败不阻断主流程，只写日志。
        委托 Invoke-ClaudeDoctorInteractiveSafe 执行（Start-Process + 输出捕获）。
    .PARAMETER TestSafe
        测试安全模式：跳过真实 claude doctor 执行。
    .RETURNS
        包含 Success, Output, Status 的哈希表
    .NOTES
        当前 Claude Code v2.1.177 的 claude doctor 在 stdout pipe / shell redirect /
        PowerShell pipeline 下均不稳定输出。因此 doctor.ps1 主流程不再自动调用本函数。
        本函数仅保留用于 fake claude 捕获机制测试、旧入口兼容，以及未来 Claude Code
        官方修复 stdout 行为后的备用路径。
    #>
    param(
        [switch]$TestSafe
    )

    $result = @{
        Success = $false
        Output  = ""
        Status  = ""
    }

    $doctor = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 45 -TestSafe:$TestSafe

    $result.Success = [bool]$doctor.Success
    $result.Output = if ($doctor.Error) { $doctor.Error } else { "ExitCode=$($doctor.ExitCode); DurationMs=$($doctor.DurationMs)" }

    if ($doctor.Success) {
        $result.Status = "ok"
    }
    elseif ($doctor.TimedOut) {
        Write-Warning "claude doctor 超时，已终止。安装流程会继续。"
        Write-Info "如需进一步排查，安装结束后可运行「一键诊断.cmd」。"
        $result.Status = "timeout"
    }
    elseif ($doctor.Error -eq "skipped_test_safe") {
        $result.Status = "skipped_test_safe"
        $result.Output = "skipped_test_safe"
    }
    elseif ($doctor.Error -eq "watchdog_unavailable_skipped") {
        Write-Log "INFO" "Invoke-ClaudeDoctorSafe: watchdog 不可用，已跳过 claude doctor"
        $result.Status = "skipped_watchdog_unavailable"
        $result.Output = "watchdog_unavailable_skipped"
    }
    else {
        Write-Warning "claude doctor 未完成或返回异常，已跳过。安装流程会继续。"
        Write-Info "如需进一步排查，安装结束后可运行「一键诊断.cmd」。"
        Write-Log "DEBUG" "claude doctor 输出: $($doctor.Error)"
        $result.Status = "failed"
    }

    return $result
}

function Parse-ClaudeDoctorOutput {
    <#
    .SYNOPSIS
        解析清洗后的 claude doctor 输出，提取结构化信息。
        过滤 GrowthBook、OAuth、feature flag 等不应公开的内部字段。
    .PARAMETER CleanedOutput
        经过 Remove-AnsiEscape + Remove-ControlChars 清洗后的 doctor 输出
    .RETURNS
        包含 ParsedFields, UserSummary, HasCoreFields 的哈希表
    #>
    param(
        [string]$CleanedOutput
    )

    $result = @{
        ParsedFields  = @{}
        UserSummary   = ""
        HasCoreFields = $false
        RawCleaned    = $CleanedOutput
    }

    if ([string]::IsNullOrWhiteSpace($CleanedOutput)) {
        $result.UserSummary = "未获取到 doctor 输出"
        return $result
    }

    $fields = @{}

    # --- 提取当前运行版本 (Currently running) ---
    if ($CleanedOutput -match 'Currently running[:\s]*(\S+)') {
        $fields['RunningVersion'] = $matches[1].Trim()
    }

    # --- 提取 Version ---
    if ($CleanedOutput -match '(?:^|\n)\s*Version[:\s]*([^\r\n]+)') {
        $fields['Version'] = $matches[1].Trim()
    }
    elseif ($CleanedOutput -match '(\d+\.\d+\.\d+[^\s,]*)') {
        if (-not $fields['Version']) {
            $fields['Version'] = $matches[1].Trim()
        }
    }

    # --- 提取 Commit ---
    if ($CleanedOutput -match 'Commit[:\s]*([a-f0-9]+)') {
        $fields['Commit'] = $matches[1].Trim()
    }

    # --- 提取 Platform ---
    if ($CleanedOutput -match 'Platform[:\s]*([^\r\n]+)') {
        $fields['Platform'] = $matches[1].Trim()
    }

    # --- 提取 Path ---
    if ($CleanedOutput -match '(?:^|\n)\s*(?:Install )?Path[:\s]*([^\r\n]+)') {
        $fields['Path'] = $matches[1].Trim()
    }

    # --- 提取 Config install method ---
    if ($CleanedOutput -match '(?:Config )?[Ii]nstall method[:\s]*([^\r\n]+)') {
        $fields['InstallMethod'] = $matches[1].Trim()
    }

    # --- 提取 Search 状态 ---
    if ($CleanedOutput -match 'Search[:\s]*(OK|ok|PASS|pass|FAIL|fail|WARN|warn)') {
        $fields['Search'] = $matches[1].Trim().ToUpper()
    }

    # --- 提取 Auto-updates ---
    if ($CleanedOutput -match 'Auto[-_\s]?updates?[:\s]*([^\r\n]+)') {
        $fields['AutoUpdates'] = $matches[1].Trim()
    }

    # --- 提取 Background server ---
    if ($CleanedOutput -match 'Background server[:\s]*([^\r\n]+)') {
        $fields['BackgroundServer'] = $matches[1].Trim()
    }

    # --- 提取 Remote Control ---
    if ($CleanedOutput -match 'Remote [Cc]ontrol[:\s]*([^\r\n]+)') {
        $fields['RemoteControl'] = $matches[1].Trim()
    }

    # --- 过滤内部字段（从原始文本中移除）---
    $filteredText = $CleanedOutput
    $internalPatterns = @(
        'GrowthBook[:\s][^\r\n]*',
        'feature[_ ]?flag[:\s][^\r\n]*',
        'OAuth[_\s]?token[:\s][^\r\n]*',
        'subscriber[_\s]?auth[:\s][^\r\n]*',
        'tengu_ccr_bridge[:\s][^\r\n]*',
        'organization[_\s]?UUID[:\s][^\r\n]*',
        'telemetryDisabledBy[:\s][^\r\n]*',
        'DISABLE_GROWTHBOOK[:\s][^\r\n]*',
        'authToken[:\s][^\r\n]*',
        'subscriberId[:\s][^\r\n]*',
        'orgId[:\s][^\r\n]*',
        'clientId[:\s][^\r\n]*'
    )
    foreach ($pattern in $internalPatterns) {
        $filteredText = $filteredText -replace $pattern, ''
    }
    $result.RawCleaned = $filteredText

    $result.ParsedFields = $fields

    # 判断是否有核心字段
    $hasVersion = -not [string]::IsNullOrWhiteSpace($fields['Version'])
    $hasPlatform = -not [string]::IsNullOrWhiteSpace($fields['Platform'])
    $hasPath = -not [string]::IsNullOrWhiteSpace($fields['Path'])
    $result.HasCoreFields = ($hasVersion -or $hasPlatform -or $hasPath)

    # --- 构建用户可读摘要 ---
    $summaryParts = [System.Collections.ArrayList]::new()

    if ($fields['Version']) {
        $platformStr = if ($fields['Platform']) { ", $($fields['Platform'])" } else { "" }
        [void]$summaryParts.Add("Claude Code 版本 $($fields['Version'])$platformStr - 安装状态正常")
    }
    elseif ($fields['RunningVersion']) {
        [void]$summaryParts.Add("Claude Code 运行版本 $($fields['RunningVersion'])")
    }

    if ($fields['Path']) {
        [void]$summaryParts.Add("安装路径: $($fields['Path'])")
    }

    if ($fields['Search']) {
        $searchStatus = if ($fields['Search'] -eq 'OK') { "正常" } else { $fields['Search'] }
        [void]$summaryParts.Add("Search: $searchStatus")
    }

    if ($fields['InstallMethod']) {
        [void]$summaryParts.Add("安装方式: $($fields['InstallMethod'])")
    }

    if ($fields['BackgroundServer'] -or $fields['RemoteControl']) {
        [void]$summaryParts.Add("后台服务/Remote Control 状态不影响 DeepSeek API 终端使用")
    }

    if ($summaryParts.Count -eq 0) {
        $result.UserSummary = "doctor 未返回可解析的结构化信息"
    }
    else {
        $result.UserSummary = ($summaryParts -join "; ")
    }

    return $result
}

function Invoke-ClaudeDoctor {
    <#
    .SYNOPSIS
        Claude Code 诊断新入口。运行 claude doctor，清洗输出，解析为结构化摘要。
        用户主界面只显示摘要，不暴露原始 TUI。
        分级处理超时和异常状态。
    .PARAMETER TimeoutSec
        超时秒数，默认 45。
    .PARAMETER TestSafe
        测试安全模式：跳过真实 claude doctor 执行。
    .RETURNS
        包含 Success, Summary, ParsedData, CleanedOutput, HasCoreFields,
        TimedOut, Error, ExitCode, DurationMs, RawOutputForLog 的哈希表
    .NOTES
        当前 Claude Code v2.1.177 的 claude doctor 在 stdout pipe / shell redirect /
        PowerShell pipeline 下均不稳定输出。因此 doctor.ps1 主流程不再自动调用本函数。
        本函数仅保留用于兼容旧入口或后续如果官方修复 stdout 行为时再启用。
    #>
    param(
        [int]$TimeoutSec = 45,
        [switch]$TestSafe
    )

    $result = @{
        Success         = $false
        Severity        = "ERROR"
        Summary         = ""
        ParsedData      = @{}
        CleanedOutput   = ""
        HasCoreFields   = $false
        TimedOut        = $false
        Error           = ""
        ExitCode        = $null
        DurationMs      = 0
        RawOutputForLog = ""
        DoctorAvailable = $true
    }

    # 1. 先确认 claude --version 是否可用
    $claudeVer = Test-ClaudeInstalled
    $claudeAvailable = ($null -ne $claudeVer)

    # 2. 调用 InteractiveSafe 执行 doctor
    $doctor = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec $TimeoutSec -TestSafe:$TestSafe

    $result.ExitCode = $doctor.ExitCode
    $result.DurationMs = $doctor.DurationMs
    $result.TimedOut = [bool]$doctor.TimedOut

    if ($doctor.Error -eq "skipped_test_safe") {
        $result.Severity = "SKIP"
        $result.Summary = "[SKIP] 测试安全模式 - 已跳过 claude doctor"
        $result.Error = "skipped_test_safe"
        return $result
    }

    if ($doctor.Error -eq "watchdog_unavailable_skipped") {
        $result.Severity = "SKIP"
        $result.Summary = "[SKIP] 超时保护不可用 - 已跳过 claude doctor，不影响主诊断"
        $result.Error = "watchdog_unavailable_skipped"
        $result.DoctorAvailable = $false
        return $result
    }

    # 3. 清洗输出
    $rawOutput = if ($doctor.CleanedOutput) { $doctor.CleanedOutput } else { "" }
    $cleanedOutput = Normalize-ExternalCommandOutput -Text $rawOutput -MaxLength 8000
    $result.CleanedOutput = $cleanedOutput
    $result.RawOutputForLog = $rawOutput

    # 4. 解析
    $parsed = Parse-ClaudeDoctorOutput -CleanedOutput $cleanedOutput
    $result.ParsedData = $parsed.ParsedFields
    $result.HasCoreFields = $parsed.HasCoreFields

    # 5. 分级处理（设置 Severity 让调用方直接使用，不必自行推断顺序）
    if ($doctor.Success -and $parsed.HasCoreFields) {
        # 成功且解析到核心字段
        $result.Success = $true
        $result.Severity = "OK"
        $result.Summary = "[OK] Claude Code doctor - $($parsed.UserSummary)"
        Write-Log "INFO" "Invoke-ClaudeDoctor: 成功, $($result.Summary)"
    }
    elseif ($doctor.TimedOut -and $parsed.HasCoreFields) {
        # 超时但已解析到核心字段 → WARN（注意：Success 依然 true 供向后兼容，但 Severity=WARN）
        $result.Success = $true
        $result.Severity = "WARN"
        $result.TimedOut = $true
        $result.Error = "claude doctor 进入交互式流程，已终止；已从部分输出中解析安装状态"
        $result.Summary = "[WARN] claude doctor - 官方 doctor 进入交互式流程，已终止；已从部分输出中解析安装状态"
        if ($parsed.UserSummary -and $parsed.UserSummary -ne 'doctor 未返回可解析的结构化信息') {
            $result.Summary += "`n  解析结果: $($parsed.UserSummary)"
        }
        Write-Log "WARN" "Invoke-ClaudeDoctor: 超时但核心字段可解析"
    }
    elseif ($doctor.TimedOut -and -not $parsed.HasCoreFields -and $claudeAvailable) {
        # 超时，无法解析，但 claude CLI 可用
        $result.Success = $true
        $result.Severity = "WARN"
        $result.TimedOut = $true
        $result.Error = "claude doctor 未返回有效结果；Claude Code CLI 本身可用 ($claudeVer)"
        $result.Summary = "[WARN] claude doctor - 未返回有效结果；Claude Code CLI 本身可用 ($claudeVer)"
        Write-Log "WARN" "Invoke-ClaudeDoctor: 超时无输出，但 CLI 可用 ($claudeVer)"
    }
    elseif (-not $doctor.Success -and $claudeAvailable) {
        # doctor 失败但 CLI 可用
        $result.Success = $true
        $result.Severity = "WARN"
        $result.Error = "claude doctor 返回异常；但 Claude Code CLI 本身可用 ($claudeVer)"
        $result.Summary = "[WARN] claude doctor - 官方 doctor 未完整返回，但 Claude Code CLI 已可用；不影响基础使用"
        Write-Log "WARN" "Invoke-ClaudeDoctor: doctor 异常但 CLI 可用 ($claudeVer)"
    }
    elseif (-not $claudeAvailable) {
        # CLI 也不可用 → 真正的安装问题
        $result.Success = $false
        $result.Severity = "ERROR"
        $result.Error = "Claude Code CLI 不可用，无法运行 doctor 诊断"
        $result.Summary = "[ERROR] Claude Code CLI - 未检测到可运行的 claude 命令"
        Write-Log "ERROR" "Invoke-ClaudeDoctor: CLI 不可用，无法运行 doctor"
    }
    else {
        # 兜底
        $result.Success = $parsed.HasCoreFields
        $result.Severity = "WARN"
        $result.Summary = if ($parsed.HasCoreFields) {
            "[WARN] claude doctor - 部分字段可解析"
        }
        else {
            "[WARN] claude doctor - 未完成"
        }
        Write-Log "WARN" "Invoke-ClaudeDoctor: 兜底分支"
    }

    return $result
}

function Invoke-ClaudeDoctorInteractiveSafe {
    <#
    .SYNOPSIS
        通过 cmd.exe 包装执行 claude doctor，stdout/stderr 写入临时文件后读取。
        设置 CI=1, TERM=dumb, NO_COLOR=1 环境变量防止 TUI 输出。
        通过独立 watchdog job 实现超时保护，超时后杀进程树并读取已写入的临时文件。
        Legacy / fake-test / compatibility only。doctor.ps1 主流程不再自动调用。
    .PARAMETER TimeoutSec
        超时秒数，默认 45。
    .PARAMETER TestSafe
        测试安全模式：跳过真实 claude doctor 执行。
    .RETURNS
        包含 Success, TimedOut, ExitCode, Error, Command, DurationMs,
        CleanedOutput, ParsedData, HasCoreFields 的哈希表
    .NOTES
        当前 Claude Code v2.1.177 的 claude doctor 在 stdout pipe / shell redirect /
        PowerShell pipeline 下均不稳定输出。因此 doctor.ps1 主流程不再自动调用本函数。
        本函数仅保留用于 fake claude 捕获机制测试、旧入口兼容，以及未来 Claude Code
        官方修复 stdout 行为后的备用路径。
    #>
    param(
        [int]$TimeoutSec = 45,
        [switch]$TestSafe
    )

    $result = @{
        Success       = $false
        TimedOut      = $false
        ExitCode      = $null
        Error         = ""
        Command       = ""
        DurationMs    = 0
        CleanedOutput = ""
    }

    # TestSafe 模式：跳过真实执行
    $isTestSafe = $TestSafe -or ($env:CCDI_TEST_MODE -eq "1")
    if ($isTestSafe) {
        Write-Log "INFO" "TestSafe: 跳过 claude doctor (Invoke-ClaudeDoctorInteractiveSafe)"
        $result.Error = "skipped_test_safe"
        $result.Command = "(test-safe skipped)"
        return $result
    }

    # --- 解析 claude 路径 ---
    $claudePath = $null
    try {
        $claudeCandidates = @(Get-Command claude -All -ErrorAction SilentlyContinue)
        if ($claudeCandidates.Count -gt 0) {
            $claudeInfo = $claudeCandidates |
                Where-Object {
                    $_.CommandType -eq "Application" -and
                    $_.Source -and
                    ([System.IO.Path]::GetExtension($_.Source).ToLowerInvariant() -in @(".exe", ".com", ".cmd", ".bat"))
                } |
                Select-Object -First 1
            if (-not $claudeInfo) {
                $claudeInfo = $claudeCandidates | Select-Object -First 1
            }
            $claudePath = if ($claudeInfo.Source) { $claudeInfo.Source } else { $claudeInfo.Definition }
        }
    }
    catch {
        Write-Log "WARN" "Get-Command claude 解析失败: $_"
    }

    if (-not $claudePath -or -not (Test-Path $claudePath)) {
        $result.Error = "claude 命令未找到或路径无效: $claudePath"
        Write-Log "ERROR" "Invoke-ClaudeDoctorInteractiveSafe: $($result.Error)"
        return $result
    }

    # 记录环境信息到日志
    $cwd = (Get-Location).Path
    $psVersion = $PSVersionTable.PSVersion.ToString()
    Write-Log "INFO" "Invoke-ClaudeDoctorInteractiveSafe: claudePath=$claudePath, cwd=$cwd, PSVersion=$psVersion, parentPid=$PID, TimeoutSec=$TimeoutSec"
    $result.Command = $claudePath

    # 尝试记录 where.exe 结果
    try {
        $whereResult = & where.exe claude 2>&1
        Write-Log "DEBUG" "where.exe claude: $whereResult"
    }
    catch {
        Write-Log "DEBUG" "where.exe claude 失败: $_"
    }

    # --- 执行前清理残留 doctor 进程 ---
    try {
        $preClean = Clear-StaleClaudeDoctorProcesses -MinAgeSec 60
        Write-Log "INFO" "执行前清理残留 doctor 进程: 清理了 $($preClean.KilledCount) 个"
    }
    catch {
        Write-Log "WARN" "执行前清理残留进程失败（不阻塞）: $_"
    }

    # --- 启动 Watchdog Job ---
    $parentPid = $PID
    $killLogPath = Join-Path ([System.IO.Path]::GetTempPath()) "ccdi_watchdog_${parentPid}_$(Get-Random).log"
    $watchdogJob = $null
    $watchdogAvailable = $false

    try {
        $watchdogJob = Start-Job -Name "ccdi_claude_doctor_watchdog_$parentPid" -ScriptBlock {
            param($ParentPid, $WaitSec, $LogPath)

            Start-Sleep -Seconds $WaitSec

            # --- 收集所有进程 ---
            $allProcs = @()
            try {
                $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
                if (-not $allProcs -or $allProcs.Count -eq 0) {
                    $allProcs = @(Get-WmiObject Win32_Process -ErrorAction SilentlyContinue)
                }
            }
            catch {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 查询所有进程失败: $_" | Out-File $LogPath -Append -Encoding UTF8
                return
            }

            if (-not $allProcs -or $allProcs.Count -eq 0) {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 未查询到任何进程" | Out-File $LogPath -Append -Encoding UTF8
                return
            }

            # --- 构建 ProcessId → Process 映射 ---
            $procById = @{}
            foreach ($p in $allProcs) {
                try {
                    $pidKey = [int]$p.ProcessId
                    if ($pidKey -gt 0 -and -not $procById.ContainsKey($pidKey)) {
                        $procById[$pidKey] = $p
                    }
                }
                catch { }
            }

            # --- 进程树后裔检测 ---
            function Test-IsDescendantProcess {
                param(
                    [object]$Proc,
                    [hashtable]$ProcById,
                    [int]$RootPid
                )

                $seen = @{}
                $current = $Proc
                while ($current -and $current.ParentProcessId) {
                    $ppid = [int]$current.ParentProcessId
                    if ($ppid -eq $RootPid) { return $true }
                    if ($seen.ContainsKey($ppid)) { return $false }
                    $seen[$ppid] = $true
                    if (-not $ProcById.ContainsKey($ppid)) { return $false }
                    $current = $ProcById[$ppid]
                }
                return $false
            }

            # --- 筛选目标进程：当前 PowerShell 后裔 + doctor + claude 相关 ---
            $targets = @($allProcs | Where-Object {
                try {
                    $name = if ($_.Name) { $_.Name.ToLowerInvariant() } else { "" }
                    $cmd  = if ($_.CommandLine) { $_.CommandLine.ToLowerInvariant() } else { "" }

                    $isDescendant = Test-IsDescendantProcess -Proc $_ -ProcById $procById -RootPid $ParentPid
                    $isDoctor = $cmd -match '(^|[\s"''`=])doctor([\s"''`]|$)'
                    $isClaudeLike =
                        ($name -in @("claude.exe", "node.exe", "cmd.exe", "powershell.exe", "pwsh.exe")) -and
                        (
                            $cmd -match 'claude' -or
                            $cmd -match 'anthropic' -or
                            $cmd -match 'claude-code'
                        )

                    return ($isDescendant -and $isDoctor -and $isClaudeLike)
                }
                catch {
                    return $false
                }
            })

            # 按 ProcessId 去重
            $targets = @($targets | Sort-Object -Property ProcessId -Unique)

            if ($targets.Count -eq 0) {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 未找到当前进程树内的 claude doctor 相关子进程（可能已正常退出）" | Out-File $LogPath -Append -Encoding UTF8
                return
            }

            "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 找到 $($targets.Count) 个 claude doctor 相关子进程" | Out-File $LogPath -Append -Encoding UTF8

            foreach ($t in $targets) {
                $pidToKill = $t.ProcessId
                $procName  = if ($t.Name) { $t.Name } else { "(unknown)" }
                $ppid      = if ($t.ParentProcessId) { $t.ParentProcessId } else { "?" }
                $cmdLine   = if ($t.CommandLine) { $t.CommandLine } else { "(unknown)" }
                if ($cmdLine.Length -gt 500) {
                    $cmdLine = $cmdLine.Substring(0, 500) + "...[截断]"
                }
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: PID=$pidToKill, Name=$procName, ParentProcessId=$ppid, CommandLine=$cmdLine" | Out-File $LogPath -Append -Encoding UTF8

                try {
                    $killOutput = & taskkill.exe /PID $pidToKill /T /F 2>&1
                    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: taskkill 结果 PID=${pidToKill}: $killOutput" | Out-File $LogPath -Append -Encoding UTF8
                }
                catch {
                    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: taskkill 异常 PID=${pidToKill}: $_" | Out-File $LogPath -Append -Encoding UTF8
                    try {
                        Stop-Process -Id $pidToKill -Force -ErrorAction Stop
                        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: Stop-Process fallback 成功 PID=$pidToKill" | Out-File $LogPath -Append -Encoding UTF8
                    }
                    catch {
                        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: Stop-Process 也失败 PID=${pidToKill}: $_" | Out-File $LogPath -Append -Encoding UTF8
                    }
                }
            }
        } -ArgumentList $parentPid, $TimeoutSec, $killLogPath

        if ($watchdogJob) {
            $watchdogAvailable = $true
            Write-Log "DEBUG" "Invoke-ClaudeDoctorInteractiveSafe: watchdog job started, id=$($watchdogJob.Id), name=$($watchdogJob.Name)"
        }
    }
    catch {
        Write-Log "WARN" "Start-Job 创建 watchdog 失败（可能被安全策略禁用）: $_。已跳过 claude doctor，避免诊断流程卡死。"
        Write-Warning "watchdog 不可用，已跳过 claude doctor，不影响后续诊断。"
        $watchdogAvailable = $false
    }

    if (-not $watchdogAvailable) {
        $result.Error = "watchdog_unavailable_skipped"
        $result.ExitCode = $null
        Write-Log "INFO" "因 watchdog 不可用（Start-Job 被禁用），已跳过 claude doctor"
        return $result
    }

    # --- 执行 claude doctor（cmd.exe 包装 + 临时文件捕获输出）---
    # 部分 Claude Code 版本在 stdout 为 pipe 时不输出内容（即使 CI=1）。
    # 改用 cmd.exe /c + shell 重定向写入临时文件，提供更接近真实终端的执行环境。
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1

    try {
        $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $tmpOut = Join-Path $tempDir "ccdi_doctor_stdout_${PID}_$(Get-Random).tmp"
        $tmpErr = Join-Path $tempDir "ccdi_doctor_stderr_${PID}_$(Get-Random).tmp"
        $tmpExit = Join-Path $tempDir "ccdi_doctor_exit_${PID}_$(Get-Random).tmp"

        $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
        # 通过 cmd.exe 内联 set 设置 CI/TERM/NO_COLOR 环境变量，
        # stdout/stderr 用 shell 重定向写入临时文件（增量写入，无 pipe 死锁风险）
        $innerCmd = "set CI=1&& set TERM=dumb&& set NO_COLOR=1&& set FORCE_COLOR=0&& set CLAUDE_CODE_TTY=0&& set NODE_OPTIONS=--no-warnings&& `"$claudePath`" doctor > `"$tmpOut`" 2> `"$tmpErr`" & echo !ERRORLEVEL! > `"$tmpExit`""

        Write-Log "INFO" "Invoke-ClaudeDoctorInteractiveSafe: 启动 claude doctor (cmd.exe + shell 重定向到临时文件)"
        Write-Log "DEBUG" "Invoke-ClaudeDoctorInteractiveSafe: tmpOut=$tmpOut, tmpErr=$tmpErr"

        $proc = Start-Process -FilePath $cmdExe -ArgumentList "/d /v:on /s /c `"$innerCmd`"" -NoNewWindow -PassThru
        Write-Log "DEBUG" "Invoke-ClaudeDoctorInteractiveSafe: cmd.exe PID=$($proc.Id)"

        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        $stdOut = ""
        $stdErr = ""

        if ($finished) {
            Write-Log "INFO" "claude doctor 完成, DurationMs=$($sw.ElapsedMilliseconds)"
        }
        else {
            Write-Log "WARN" "claude doctor 超时 (${TimeoutSec}s)，正在终止进程树 PID=$($proc.Id)"
            try {
                if (-not $proc.HasExited) {
                    $tkResult = & taskkill.exe /PID $proc.Id /T /F 2>&1
                    Write-Log "INFO" "claude doctor timeout taskkill result PID=$($proc.Id): $tkResult"
                    $proc.WaitForExit(5000) | Out-Null
                }
            }
            catch {
                Write-Log "WARN" "taskkill 终止 claude doctor 失败，尝试 proc.Kill(): $_"
                try {
                    if (-not $proc.HasExited) {
                        $proc.Kill()
                        $proc.WaitForExit(3000) | Out-Null
                    }
                }
                catch {
                    Write-Log "ERROR" "无法终止 claude doctor 进程: $_"
                }
            }
            Write-Log "DEBUG" "claude doctor timeout kill completed"
        }

        # 读取临时文件中的输出（shell 重定向是增量写入的，超时时也能获取已写入内容）
        if (Test-Path $tmpOut) {
            try {
                $stdOut = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "DEBUG" "读取 doctor stdout 临时文件异常: $_"
            }
            if (-not $stdOut) { $stdOut = "" }
        }
        if (Test-Path $tmpErr) {
            try {
                $stdErr = Get-Content $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            catch {
                Write-Log "DEBUG" "读取 doctor stderr 临时文件异常: $_"
            }
            if (-not $stdErr) { $stdErr = "" }
        }
        if (Test-Path $tmpExit) {
            try {
                $exitCodeText = (Get-Content $tmpExit -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim()
                if ($exitCodeText -match '^-?\d+') {
                    $exitCode = [int]$exitCodeText
                }
            }
            catch {
                Write-Log "DEBUG" "读取 doctor exit code 临时文件异常: $_"
            }
        }

        Write-Log "INFO" "claude doctor output captured: stdout=$($stdOut.Length) bytes, stderr=$($stdErr.Length) bytes, exitCode=$exitCode"

        # 清理临时文件
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpExit -Force -ErrorAction SilentlyContinue

        $sw.Stop()

        # 保存原始输出（始终拼接，供后续清洗使用）
        $combinedOutput = "$stdOut`n$stdErr"

        # DEBUG 日志：仅当 CCDI_DEBUG_RAW_DOCTOR=1 时才记录完整 raw output
        if ($env:CCDI_DEBUG_RAW_DOCTOR -eq "1") {
            # API Key 脱敏 + 路径脱敏后写入 DEBUG 日志
            $safeOutput = Sanitize-SecretLikeText -Text $combinedOutput
            $safeOutput = Sanitize-PathForReport -Text $safeOutput
            if ($safeOutput.Length -gt 12000) {
                $safeOutput = $safeOutput.Substring(0, 12000) + "`n...[doctor 输出截断]"
            }
            Write-Log "DEBUG" "Invoke-ClaudeDoctorInteractiveSafe raw output ($($combinedOutput.Length) bytes): $safeOutput"
        }
        # 始终记录简洁状态到 INFO
        Write-Log "INFO" "Invoke-ClaudeDoctorInteractiveSafe: output $($combinedOutput.Length) bytes, exitCode=$exitCode, finished=$finished"

        # 清洗输出
        $rawOutput = $combinedOutput
        $result.CleanedOutput = Normalize-ExternalCommandOutput -Text $rawOutput -MaxLength 8000
        $result.ExitCode = if ($finished) { $exitCode } else { -1 }
        $result.DurationMs = $sw.ElapsedMilliseconds
    }
    catch {
        $sw.Stop()
        $result.DurationMs = $sw.ElapsedMilliseconds
        $result.Error = "claude doctor 执行异常: $_"
        Write-Log "ERROR" "Invoke-ClaudeDoctorInteractiveSafe: cmd.exe 执行异常: $_"
    }

    # --- 检查 Watchdog 状态 ---
    # 不能仅凭 JobState 判 fired：watchdog 可能醒来后发现目标已退出也结束。
    # 必须根据日志里是否实际终止了进程来判断。
    $watchdogFired = $false
    $watchdogLogText = ""

    try {
        $jobState = $watchdogJob.State
        Write-Log "DEBUG" "Watchdog job 状态: State=$jobState"

        if ($jobState -eq 'Running') {
            Stop-Job $watchdogJob -ErrorAction SilentlyContinue
            Write-Log "DEBUG" "Watchdog 未触发，claude doctor 在超时前完成"
        }
        else {
            $received = Receive-Job $watchdogJob -ErrorAction SilentlyContinue
            if ($received) {
                $watchdogLogText += ($received | Out-String)
            }

            if (Test-Path $killLogPath) {
                try {
                    $fileLog = Get-Content $killLogPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($fileLog) {
                        $watchdogLogText += "`n$fileLog"
                    }
                }
                catch {
                    Write-Log "DEBUG" "读取 watchdog killLog 异常: $_"
                }
            }

            if ($watchdogLogText) {
                Write-Log "INFO" "Watchdog 已结束：$watchdogLogText"
            }

            # 只有日志确认实际终止了进程时才算 fired
            $watchdogFired = (
                $watchdogLogText -match 'WATCHDOG:\s*找到\s+\d+\s+个 claude doctor 相关子进程' -or
                $watchdogLogText -match 'WATCHDOG:\s*taskkill 结果' -or
                $watchdogLogText -match 'WATCHDOG:\s*Stop-Process fallback 成功' -or
                $watchdogLogText -match 'WATCHDOG:\s*超时，正在终止'
            )

            if (-not $watchdogFired) {
                Write-Log "DEBUG" "Watchdog 已结束但未实际终止进程，不标记为 fired"
            }
        }
    }
    catch {
        Write-Log "WARN" "检查 watchdog 状态异常: $_"
    }
    finally {
        Remove-Job $watchdogJob -Force -ErrorAction SilentlyContinue
        if (Test-Path $killLogPath) {
            Remove-Item $killLogPath -Force -ErrorAction SilentlyContinue
        }
    }

    # --- 处理结果 ---
    if ($watchdogFired) {
        $result.TimedOut = $true
        $result.Success = $false
        $result.Error = "claude doctor 超时（${TimeoutSec}秒），watchdog 已终止进程树"
        Write-Log "WARN" "Invoke-ClaudeDoctorInteractiveSafe: $($result.Error)"

        try {
            $postClean = Clear-StaleClaudeDoctorProcesses -ParentPid $parentPid -Force
            Write-Log "INFO" "超时后清理本进程 doctor 子进程: 清理了 $($postClean.KilledCount) 个"
        }
        catch {
            Write-Log "WARN" "超时后清理残留失败: $_"
        }
    }
    elseif ($finished -and $exitCode -eq 0) {
        $result.Success = $true
        Write-Log "INFO" "claude doctor 成功完成 (ExitCode=0, DurationMs=$($result.DurationMs))"
    }
    elseif ($finished) {
        # doctor 执行完成但退出码非零
        $result.Success = $false
        $result.Error = "claude doctor 返回非零退出码: $exitCode"
        Write-Log "WARN" "Invoke-ClaudeDoctorInteractiveSafe: $($result.Error), DurationMs=$($result.DurationMs)"
        # 即使退出码非零，如果捕获到输出也算部分成功
        if (-not [string]::IsNullOrWhiteSpace($result.CleanedOutput)) {
            Write-Log "INFO" "虽然退出码非零，但已捕获 $($result.CleanedOutput.Length) bytes 输出用于解析"
        }
    }
    else {
        # 超时
        $result.TimedOut = $true
        $result.Success = $false
        $result.Error = "claude doctor 超时（${TimeoutSec}秒）"
        if (-not [string]::IsNullOrWhiteSpace($result.CleanedOutput)) {
            Write-Log "INFO" "超时但已捕获 $($result.CleanedOutput.Length) bytes 部分输出"
        }
    }

    return $result
}


function Invoke-VisibleInstallCommand {
    <#
    .SYNOPSIS
        执行外部安装命令，输出直连用户终端（不重定向）。
        用于 winget / npm install / powershell -File 等长时间命令，
        让用户看到真实进度而非心跳提示。
    .PARAMETER FilePath
        可执行文件路径。
    .PARAMETER Arguments
        参数数组。
    .PARAMETER TimeoutSec
        超时秒数，默认 600。
    .PARAMETER TestSafe
        测试安全模式：跳过真实执行。
    .PARAMETER Cwd
        工作目录，默认当前目录。
    .RETURNS
        包含 Success, ExitCode, Error, DurationMs, Command, Pid 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 600,
        [switch]$TestSafe,
        [string]$Cwd = ""
    )

    $result = @{
        Success    = $false
        ExitCode   = -1
        Error      = ""
        DurationMs = 0
        Command    = "$FilePath $($Arguments -join ' ')"
        Pid        = 0
    }

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过可见安装命令: $($result.Command)"
        $result.Error = "skipped_test_safe"
        return $result
    }

    Write-Log "INFO" "Invoke-VisibleInstallCommand: $($result.Command), TimeoutSec=$TimeoutSec, cwd=$(if ($Cwd) { $Cwd } else { (Get-Location).Path })"

    try {
        # 解析 FilePath：如果是 .cmd / .bat，通过 cmd.exe 包装执行。
        # Invoke-CommandSafe 内部已经有完整的 cmd.exe 包装，这里对可见安装命令
        # 统一处理 Extension Awareness。
        $resolvedPath = $FilePath
        $resolvedArgs = $Arguments
        $ext = if ($FilePath) { [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant() } else { "" }
        if ($ext -in @(".cmd", ".bat")) {
            # .cmd/.bat 必须通过 cmd.exe /c 执行，且内部把整个命令行传给 /c
            $quoted = @($resolvedPath) + $resolvedArgs
            $inner = ($quoted | ForEach-Object { ConvertTo-CommandLineArgument -Argument $_ }) -join " "
            $resolvedPath = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
            $resolvedArgs = @("/d", "/s", "/c", $inner)
            Write-Log "DEBUG" "Invoke-VisibleInstallCommand: wrapping .cmd via cmd.exe: $resolvedPath /d /s /c $inner"
        }

        $startParams = @{
            FilePath     = $resolvedPath
            ArgumentList = $resolvedArgs
            NoNewWindow  = $true
            PassThru     = $true
            ErrorAction  = 'Stop'
        }
        if ($Cwd) {
            $startParams.WorkingDirectory = $Cwd
        }

        $proc = Start-Process @startParams
        $result.Pid = $proc.Id
        Write-Log "INFO" "进程已启动 PID=$($proc.Id)"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        $sw.Stop()
        $result.DurationMs = $sw.ElapsedMilliseconds

        if ($finished) {
            # Windows PowerShell 5.1 下 Start-Process -PassThru 的 ExitCode 可能为 $null
            # 即使进程实际返回了 0。此时记录为 -1 并标记 Success=$false，
            # 由调用方通过后验验证（如 Test-ClaudeCommandExisting）决定最终结果。
            if ($null -eq $proc.ExitCode -or $proc.ExitCode -isnot [int]) {
                $result.ExitCode = -1
                $result.Success = $false
                $result.Error = "$FilePath 未返回有效退出码（PS 5.1 已知限制），请调用方做后验验证"
                Write-Log "WARN" "Invoke-VisibleInstallCommand: ExitCode 为空或无效，DurationMs=$($result.DurationMs)"
            }
            else {
                $result.ExitCode = [int]$proc.ExitCode
                $result.Success = ($result.ExitCode -eq 0)
                if (-not $result.Success) {
                    $result.Error = "$FilePath 返回非零退出码: $($result.ExitCode)"
                }
                Write-Log "INFO" "Invoke-VisibleInstallCommand 完成: ExitCode=$($result.ExitCode), DurationMs=$($result.DurationMs)"
            }
        }
        else {
            # 超时：杀进程树
            Write-Log "WARN" "Invoke-VisibleInstallCommand 超时 (${TimeoutSec}s)，正在终止进程树 PID=$($proc.Id)"
            try {
                if (-not $proc.HasExited) {
                    $tkResult = & taskkill.exe /PID $proc.Id /T /F 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "INFO" "taskkill /T /F 成功 PID=$($proc.Id): $tkResult"
                    }
                    else {
                        Write-Log "WARN" "taskkill 失败 (exit=$LASTEXITCODE): $tkResult，尝试 Stop-Process"
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Log "INFO" "Stop-Process fallback 成功 PID=$($proc.Id)"
                    }
                }
            }
            catch {
                Write-Log "ERROR" "终止进程树失败 PID=$($proc.Id): $_"
                try {
                    if (-not $proc.HasExited) { $proc.Kill() }
                }
                catch {
                    Write-Log "ERROR" "Kill 也失败: $_"
                }
            }
            $result.Error = "命令超时 (${TimeoutSec}秒): $FilePath"
        }
    }
    catch {
        $result.Error = "执行异常: $_"
        Write-Log "ERROR" "Invoke-VisibleInstallCommand 异常: $_"
    }

    return $result
}

function New-CcdiTimeoutWebClient {
    <#
    .SYNOPSIS
        创建带超时控制的 WebClient 子类。
        解决默认 WebClient.DownloadFile 不设 Timeout 导致半连通/TLS 阻塞时
        长期卡死的隐患。
    .PARAMETER TimeoutSec
        超时秒数，默认 30。同时设置 request.Timeout 和 ReadWriteTimeout。
    #>
    param(
        [int]$TimeoutSec = 30
    )

    if (-not ("CcdiTimeoutWebClient" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Net;

public class CcdiTimeoutWebClient : WebClient {
    public int Timeout { get; set; }

    protected override WebRequest GetWebRequest(Uri address) {
        WebRequest request = base.GetWebRequest(address);
        request.Timeout = Timeout;
        if (request is HttpWebRequest) {
            ((HttpWebRequest)request).ReadWriteTimeout = Timeout;
            ((HttpWebRequest)request).AllowAutoRedirect = true;
            ((HttpWebRequest)request).MaximumAutomaticRedirections = 3;
        }
        return request;
    }
}
"@ -ErrorAction Stop
    }

    $client = New-Object CcdiTimeoutWebClient
    $client.Timeout = [Math]::Max(1, $TimeoutSec) * 1000
    $client.Headers.Add("User-Agent", "Mozilla/5.0 CCDI")
    return $client
}

function Invoke-VisibleFileDownload {
    <#
    .SYNOPSIS
        下载文件，显示明确阶段提示，不隐藏进度。
        不使用 Invoke-CommandSafe / cmd.exe / 子进程包装。
    .PARAMETER Url
        下载地址。
    .PARAMETER OutputPath
        输出文件路径。
    .PARAMETER TimeoutSec
        超时秒数，默认 30。
    .PARAMETER TestSafe
        测试安全模式：跳过真实下载。
    .RETURNS
        包含 Success, Error, Status, DurationMs, Url, OutputPath 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [int]$TimeoutSec = 30,
        [switch]$TestSafe
    )

    $result = @{
        Success    = $false
        Error      = ""
        Status     = ""
        DurationMs = 0
        Url        = $Url
        OutputPath = $OutputPath
    }

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过下载 $Url"
        $result.Error = "skipped_test_safe"
        $result.Status = "skipped_test_safe"
        return $result
    }

    Write-Info "正在下载 Claude 官方安装脚本..."
    Write-Info "下载地址: $Url"
    Write-Info "如果下载超时，将自动切换到备用安装方式。"
    Write-Log "INFO" "Invoke-VisibleFileDownload: Url=$Url, OutputPath=$OutputPath, TimeoutSec=$TimeoutSec"
    Write-Host ""

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null

    try {
        # 确保目标目录存在
        $outDir = Split-Path -Parent $OutputPath
        if (-not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }

        # 使用 WebClient.DownloadFile 进行二进制安全下载。
        # 不能用 Invoke-WebRequest 把 response.Content 当 string 再 [IO.File]::WriteAllText，
        # 某些 Windows 环境下会导致文件内容变成十进制字节串（如 "112 97 114 97 109 40 ..."）。
        $client = New-CcdiTimeoutWebClient -TimeoutSec $TimeoutSec
        $client.DownloadFile($Url, $OutputPath)

        $sw.Stop()
        $result.DurationMs = $sw.ElapsedMilliseconds

        if (-not (Test-Path $OutputPath)) {
            $result.Error = "下载完成但目标文件不存在"
            $result.Status = "failed_download_empty"
            Write-Log "ERROR" "Invoke-VisibleFileDownload: 下载完成但文件不存在, Url=$Url"
            return $result
        }

        $bytes = [IO.File]::ReadAllBytes($OutputPath)
        $resultSize = $bytes.Length

        if ($bytes.Length -lt 100) {
            $result.Error = "下载文件过小 ($($bytes.Length) bytes)，可能不是安装脚本"
            $result.Status = "failed_download_too_small"
            Write-Log "ERROR" "Invoke-VisibleFileDownload: 文件过小 ($($bytes.Length) bytes), Url=$Url"
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            return $result
        }

        # 校验：检查前 512 字节是否像合法的 PowerShell 安装脚本
        $headLen = [Math]::Min($bytes.Length, 512)
        $head = [Text.Encoding]::UTF8.GetString($bytes, 0, $headLen)

        # 拒绝十进制字节串（如 "112 97 114 97 109 40 ..."）
        if ($head -match '^\s*\d+\s+\d+\s+\d+\s+\d+') {
            $result.Error = "下载文件内容像十进制字节串，不是合法 PowerShell 脚本"
            $result.Status = "failed_download_decimal_bytes"
            Write-Log "ERROR" "Invoke-VisibleFileDownload: 内容为十进制字节串, Url=$Url, head=$($head.Substring(0, [Math]::Min(80, $head.Length)))"
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            return $result
        }

        # 至少包含一个 PowerShell 脚本特征
        if ($head -notmatch '(?i)param\s*\(|function|powershell|claude') {
            $result.Error = "下载内容不像 Claude 官方 PowerShell 安装脚本"
            $result.Status = "failed_download_not_ps1"
            Write-Log "ERROR" "Invoke-VisibleFileDownload: 内容不像安装脚本, Url=$Url"
            Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            return $result
        }

        $result.Success = $true
        $result.Status = "ok"
        Write-Success "官方安装脚本下载完成 ($($result.DurationMs)ms, $resultSize bytes)"
        Write-Log "INFO" "Invoke-VisibleFileDownload 成功: Url=$Url, size=$resultSize, DurationMs=$($result.DurationMs)"
    }
    catch {
        $sw.Stop()
        $result.DurationMs = $sw.ElapsedMilliseconds
        $result.Error = "下载异常: $($_.Exception.Message)"
        $result.Status = "failed_download"

        # 清理可能的部分下载文件
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue

        # 分析错误类型写入日志
        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            if ($webEx.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
                $result.Error = "下载超时 (${TimeoutSec}秒): $Url"
                $result.Status = "failed_download_timeout"
                Write-Log "ERROR" "Invoke-VisibleFileDownload 超时: Url=$Url, TimeoutSec=$TimeoutSec"
            }
            elseif ($webEx.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
                Write-Log "ERROR" "Invoke-VisibleFileDownload DNS 解析失败: Url=$Url"
            }
            elseif ($webEx.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure) {
                Write-Log "ERROR" "Invoke-VisibleFileDownload 连接失败: Url=$Url"
            }
            else {
                Write-Log "ERROR" "Invoke-VisibleFileDownload 网络错误: Status=$($webEx.Status), Url=$Url"
            }
        }
        else {
            Write-Log "ERROR" "Invoke-VisibleFileDownload 异常: $_"
        }
    }
    finally {
        if ($null -ne $client) {
            try { $client.Dispose() } catch { }
        }
    }

    return $result
}

function Install-NodeJsViaWinget {
    <#
    .SYNOPSIS
        使用 winget 安装 Node.js LTS，捕获英文输出到日志，控制台只显示中文心跳。
    .PARAMETER TimeoutSec
        超时秒数，默认 900（15分钟）。
    .PARAMETER TestSafe
        测试安全模式：跳过真实安装。
    .RETURNS
        包含 Success, ExitCode, Error 的哈希表
    #>
    param(
        [int]$TimeoutSec = 900,
        [switch]$TestSafe
    )

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过 winget install Node.js"
        return @{ Success = $false; ExitCode = -1; Error = "skipped_test_safe" }
    }

    Write-Log "INFO" "Installing Node.js LTS via winget"
    Write-Info "正在安装 Node.js LTS，请不要关闭窗口。"
    Write-Info "这一步通常需要 1-5 分钟，取决于网络和电脑速度。"
    Write-Info '如果弹出权限确认窗口，请选择“是”；如果没看到，请看任务栏是否闪烁。'
    Write-Host ""

    return Invoke-InstallCommandCaptured -FilePath "winget" -Arguments @(
        "install", "--id", "OpenJS.NodeJS.LTS", "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    ) -TimeoutSec $TimeoutSec -ProgressIntervalSec 10 -FriendlyName "Node.js LTS 安装" `
        -ProgressTitle "Node.js LTS 安装中" `
        -ProgressHint '如有权限弹窗请选择“是”' `
        -SlowNoticeAfterSec 120 `
        -SlowNoticeMessage "Node.js 安装耗时较长，工具仍在正常等待。首次安装通常需要几分钟，请不要关闭窗口。" `
        -StartMessage ""
}

function Get-InstallResultField {
    param(
        [AllowNull()][object]$InstallResult,
        [string]$Name
    )

    if ($null -eq $InstallResult) { return $null }
    if ($InstallResult -is [System.Collections.IDictionary]) {
        if ($InstallResult.Contains($Name)) { return $InstallResult[$Name] }
        if ($InstallResult.ContainsKey($Name)) { return $InstallResult[$Name] }
        return $null
    }

    $prop = $InstallResult.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-WingetNodeInstallAccepted {
    <#
    .SYNOPSIS
        判断 winget Node.js 安装命令本身是否可被接受。
        最终是否可继续仍以固定路径 node.exe/npm.cmd 后验验证为准。
    #>
    param(
        [AllowNull()][object]$InstallResult
    )

    $success = Get-InstallResultField -InstallResult $InstallResult -Name "Success"
    if ($success -eq $true) { return $true }

    $exitCode = Get-InstallResultField -InstallResult $InstallResult -Name "ExitCode"
    if ($null -ne $exitCode) {
        try {
            if ([int]$exitCode -eq 0) { return $true }
        }
        catch { }
    }

    $textParts = @()
    foreach ($field in @("Output", "Error", "RawError", "Status")) {
        $value = Get-InstallResultField -InstallResult $InstallResult -Name $field
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $textParts += [string]$value
        }
    }
    $text = $textParts -join "`n"
    if ($text -match '(?i)already\s+installed|no\s+applicable\s+update|no\s+available\s+upgrade|package\s+is\s+already\s+installed|已安装|无需更新|没有可用升级') {
        return $true
    }

    return $false
}

function Install-ClaudeCodeViaWinget {
    <#
    .SYNOPSIS
        使用 winget 安装 Claude Code（Anthropic.ClaudeCode）。
        Native Install 和 npm 镜像之间的中速通道。
    .PARAMETER TestSafe
        测试安全模式：跳过真实安装。
    .RETURNS
        包含 Success, ExitCode, Error 的哈希表
    #>
    param(
        [switch]$TestSafe
    )

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过 winget install Claude Code"
        return @{ Success = $false; ExitCode = -1; Error = "skipped_test_safe" }
    }

    Write-Log "INFO" "执行: winget install Anthropic.ClaudeCode"
    Write-Info "正在通过系统安装工具安装 Claude Code。"
    Write-Info "这一步可能需要几分钟，请不要关闭窗口。"
    Write-Info '如果弹出权限确认窗口，请选择“是”；如果没看到，请看任务栏是否闪烁。'

    return Invoke-InstallCommandCaptured -FilePath "winget" -Arguments @(
        "install", "Anthropic.ClaudeCode",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    ) -TimeoutSec 600 -FriendlyName "winget 安装 Claude Code" `
        -StartMessage "" `
        -ProgressIntervalSec 10 `
        -ProgressTitle "Claude Code 系统安装中" `
        -ProgressHint '如有权限弹窗请选择“是”' `
        -SlowNoticeAfterSec 120 `
        -SlowNoticeMessage "系统安装方式较慢，工具仍在等待；如果后续未确认成功，会自动切换备用下载方式。" `
        -TimeoutMessage "系统安装方式等待过久，正在确认安装结果；如未成功会自动切换备用下载方式。" `
        -TimeoutFollowupMessage ""
}

# ============================================================
# 统一安装入口
# ============================================================

function Install-ClaudeCodeAuto {
    <#
    .SYNOPSIS
        Claude Code 自动安装函数。
        策略：
          1. claude 已存在 → 跳过（不覆盖、不重装、不自动更新）
          2. 官方 Native Install 可用 → 优先使用
          3. 官方不可用或安装失败 → 尝试 winget install Anthropic.ClaudeCode
          4. winget 不可用或失败 → 自动切换 npmmirror npm 镜像
          5. npm 镜像需要 Node.js >= 18 + npm
    .PARAMETER TestSafe
        测试安全模式：不执行 irm/curl/npm install/winget，只检测 claude 命令是否存在。
    .PARAMETER NonInteractive
        非交互模式：不向用户提问，不自动安装 winget/Node.js 等系统软件。
    .RETURNS
        包含 Success, Method, Status, Version, WasAlreadyInstalled 的哈希表
    #>
    param(
        [switch]$TestSafe,
        [switch]$NonInteractive
    )

    $result = @{
        Success             = $false
        Method              = ""
        Status              = ""
        Version             = $null
        WasAlreadyInstalled = $false
        UserMessage         = ""
    }

    # ============================================================
    # TestSafe 模式
    # ============================================================
    # Mock decision support: 当 CCDI_MOCK_INSTALL_DECISION=1 时，不要提前返回，
    # 而是继续走完整决策树，由子函数的 mock 逻辑返回模拟结果。
    $isTestSafe = $TestSafe -or ($env:CCDI_TEST_MODE -eq "1")
    $isMockDecision = ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1")
    if ($isTestSafe -and -not $isMockDecision) {
        Write-Warning "当前为测试安全模式：不会安装、更新或卸载 Claude Code。"
        Write-Info "将只检查 claude 命令是否存在，并继续后续沙盒配置验证。"

        $existingCheck = Test-ClaudeCommandExisting
        if ($existingCheck.Exists) {
            if ($existingCheck.Usable) {
                Write-Success "检测到 Claude Code: $($existingCheck.Version)"
                $result.Success = $true
                $result.Method = "existing"
                $result.Status = "skipped_test_safe_existing"
                $result.Version = $existingCheck.Version
                $result.WasAlreadyInstalled = $true
                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $true
                    claudeInstallMethod       = "existing"
                    claudeInstallStatus       = "skipped_test_safe_existing"
                } | Out-Null
            }
            else {
                Write-Warning "检测到 Claude Code 残留或损坏: $($existingCheck.Error)"
                Write-Warning "测试安全模式下不会尝试修复安装。"
                $result.Method = "none"
                $result.Status = "skipped_test_safe_broken"
                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "none"
                    claudeInstallStatus       = "skipped_test_safe_broken"
                } | Out-Null
            }
        }
        else {
            Write-Warning "未检测到 Claude Code。测试安全模式下不会尝试安装。"
            $result.Method = "none"
            $result.Status = "skipped_test_safe_missing"
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "none"
                claudeInstallStatus       = "skipped_test_safe_missing"
            } | Out-Null
        }

        return $result
    }

    # ============================================================
    # Step 1: 检测 claude 是否已存在
    # ============================================================
    $existingCheck = Test-ClaudeCommandExisting
    if ($existingCheck.Exists) {
        if ($existingCheck.Usable) {
            # claude 存在且可用
            Write-Success "Claude Code 已安装: $($existingCheck.Version)"
            Write-Info "已安装时不覆盖、不重装、不自动更新。"

            # --- v1.3.3 P0-1: 已有 Native Install 也必须检查 User PATH 和 fresh shell ---
            $nativeExe = Get-NativeClaudeExePath
            $nativeBin = Get-NativeClaudeBinPath

            # 判断是否为 Native Install 来源
            $isNativeInstall = $false
            if ($existingCheck.Source -eq "native_local_bin") {
                $isNativeInstall = $true
            }
            elseif ($existingCheck.Path) {
                try {
                    $existingPathNorm = [IO.Path]::GetFullPath($existingCheck.Path).TrimEnd('\').ToLowerInvariant()
                    $nativeExeNorm = [IO.Path]::GetFullPath($nativeExe).TrimEnd('\').ToLowerInvariant()
                    if ($existingPathNorm -eq $nativeExeNorm) {
                        $isNativeInstall = $true
                    }
                }
                catch { }
            }
            if (-not $isNativeInstall -and (Test-Path $nativeExe)) {
                # Native exe 存在，即使 Source 没有标准化，也要检查 PATH
                $isNativeInstall = $true
            }

            if ($isNativeInstall) {
                Write-Log "INFO" "Native Install (existing): checking claude command availability..."
                Write-Info "Claude Code 已安装，正在检查命令是否可以直接运行..."

                # 检查 User PATH
                $pathCheck = Test-UserPathContains -TargetPath $nativeBin
                if (-not $pathCheck.Contains) {
                    Write-Warning "Claude Code 已安装，但命令路径还未配置。"
                    Write-Info "正在自动配置命令路径..."
                    Write-Log "INFO" "Auto-fixing User PATH: adding $nativeBin"
                    $pathFix = Ensure-UserPathEntry -PathToAdd $nativeBin
                }
                else {
                    $pathFix = @{ Success = $true; Changed = $false; Error = "" }
                    Write-Log "INFO" "Claude Code install dir already in User PATH"
                }

                # Fresh shell 验证
                $freshCheck = Test-ClaudeCommandInFreshShell

                if ($freshCheck.Success) {
                    Write-Log "INFO" "Native Install (existing) fresh shell 可用: $($freshCheck.Output)"
                    $result.Success = $true
                    $result.Method = "existing_native"
                    $result.Status = "skipped_existing"
                    $result.Version = $existingCheck.Version
                    $result.WasAlreadyInstalled = $true

                    Update-CcdiState -Updates @{
                        claudeWasAlreadyInstalled = $true
                        claudeInstallMethod       = "existing_native"
                        claudeInstallStatus       = "skipped_existing"
                    } | Out-Null

                    Write-Log "INFO" "Claude Code 已存在(Native)，PATH 和 fresh shell 均通过，跳过安装: $($existingCheck.Version)"
                    return $result
                }

                if ($pathFix.Success) {
                    Write-Warning "命令路径已配置，但新打开的 PowerShell 暂未确认可用。"
                    Write-Info "请关闭当前窗口，重新打开 PowerShell 后测试 Claude Code 命令。"

                    $result.Success = $true
                    $result.Method = "existing_native"
                    $result.Status = "installed_needs_restart_or_path_fix"
                    $result.Version = $existingCheck.Version
                    $result.WasAlreadyInstalled = $true

                    Update-CcdiState -Updates @{
                        claudeWasAlreadyInstalled = $true
                        claudeInstallMethod       = "existing_native"
                        claudeInstallStatus       = "installed_needs_restart_or_path_fix"
                    } | Out-Null

                    Write-Log "INFO" "Claude Code 已存在(Native)，PATH 已写入但 fresh shell 未通过"
                    return $result
                }

                Write-Warning "Claude Code 已安装，但命令路径自动配置失败。"
                Write-Info "请运行「一键修复依赖」自动修复，或手动配置命令路径。"

                $result.Success = $true
                $result.Method = "existing_native"
                $result.Status = "installed_needs_path_fix"
                $result.Version = $existingCheck.Version
                $result.WasAlreadyInstalled = $true

                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $true
                    claudeInstallMethod       = "existing_native"
                    claudeInstallStatus       = "installed_needs_path_fix"
                } | Out-Null

                Write-Log "INFO" "Claude Code 已存在(Native)，PATH 修复失败"
                return $result
            }

            # 非 Native Install (npm/winget/其他路径)，走原有 existing 逻辑
            # claude doctor is diagnostic-only; not called during install

            $result.Success = $true
            $result.Method = "existing"
            $result.Status = "skipped_existing"
            $result.Version = $existingCheck.Version
            $result.WasAlreadyInstalled = $true
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $true
                claudeInstallMethod       = "existing"
                claudeInstallStatus       = "skipped_existing"
            } | Out-Null

            Write-Log "INFO" "Claude Code 已存在且可用，跳过安装: $($existingCheck.Version)"
            return $result
        }
        else {
            # claude 命令存在但不可用 → 残留/损坏，进入修复路径
            Write-Warning "检测到 Claude Code 残留或损坏: $($existingCheck.Error)"
            Write-Warning "检测到 claude 命令来源异常，可能是旧安装、WindowsApps alias、Claude Desktop alias 或残留 shim。"
            Write-Info "请运行「一键诊断.cmd」查看 Claude 命令来源。"
            Write-Info "将尝试通过安装流程修复（不覆盖已有配置）。"
            Write-Log "WARN" "Claude Code 存在但不可用 (existing_broken)，进入修复路径"
            try {
                $inv = Get-ClaudeCommandInventory
                if ($inv.ConflictSummary) {
                    Write-Log "WARN" "Claude command inventory conflict: $($inv.ConflictSummary)"
                }
            } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
        }
    }
    else {
        Write-Info "Claude Code 未安装，开始安装流程..."
    }

    # ============================================================
    # Step 2: 检测官方安装通道 + 尝试安装
    # ============================================================
    Write-Info ""
    Write-Log "INFO" "Install strategy: official_native -> winget -> npm_npmmirror"
    Write-Info "正在检测最快的安装方式..."
    Write-Log "INFO" "Checking official download channel..."

    $officialNetwork = Test-ClaudeOfficialInstallNetwork

    if ($officialNetwork.Reachable) {
        Write-Log "INFO" "Official download channel reachable, starting install..."
        Write-Info "正在通过官方方式安装 Claude Code。"
        Write-Info "这一步可能需要几分钟，请不要关闭窗口。"

        $nativeResult = Install-ClaudeCodeNative

        # 无论安装器 ExitCode 如何，始终先做后验验证
        # Native Install 失败或返回异常 ExitCode 时不向用户展示失败信息，
        # 由后验验证决定最终结论（避免"失败→成功"的矛盾提示）。
        Write-Host ""
        Refresh-CurrentProcessPath
        $verifyResult = Test-ClaudeCommandExisting
        Write-Log "INFO" "Native Install 后验验证: Exists=$($verifyResult.Exists), Usable=$($verifyResult.Usable), Version=$($verifyResult.Version), Path=$($verifyResult.Path)"

        # 记录安装器 ExitCode 异常到日志（不向用户展示）
        if (-not $nativeResult.Success) {
            Write-Log "INFO" "Native Install returned non-zero/unknown exit code, but post-install verification will decide outcome."
        }

        # Mock 决策模式：如果 Native 安装 mock 返回成功，信任 mock 结果，
        # 不要依赖 Test-ClaudeCommandExisting 的后验验证（它仍返回安装前的 broken/missing 状态）
        if ($isMockDecision -and $nativeResult.Success) {
            Write-Log "DEBUG" "MOCK: native install returned success; trusting mock result (post-verify skipped)"
            $result.Success = $true
            $result.Method = "official_native"
            $result.Status = "installed"
            $result.Version = "1.0.0-mock"
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled  = $false
                claudeInstallMethod        = "official_native"
                claudeInstallStatus        = "installed"
                claudeInstallCompletedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | Out-Null
            Write-Success "Claude Code 安装完成 (mock native)"
            return $result
        }

        if ($verifyResult.Usable) {
            # 后验验证通过：claude.exe 存在且可用

            if ($isMockDecision) {
                Write-Log "DEBUG" "MOCK: trusting native install success"
                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed"
                $result.Version = "1.0.0-mock"
                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled  = $false
                    claudeInstallMethod        = "official_native"
                    claudeInstallStatus        = "installed"
                    claudeInstallCompletedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | Out-Null
                Write-Success "Claude Code 安装完成 (mock)"
                return $result
            }

            Write-Log "INFO" "Native Install 后验验证可用: $($verifyResult.Version)"

            # --- PATH 持久化 (v1.3.3) ---
            $nativeBinPath = Get-NativeClaudeBinPath
            $pathResult = Ensure-UserPathEntry -PathToAdd $nativeBinPath

            if ($pathResult.Success) {
                if ($pathResult.Changed) {
                    Write-Log "INFO" "User PATH updated with Claude bin: $nativeBinPath"
                    Write-Info "命令路径已配置，新打开的 PowerShell 将可以直接使用 Claude Code。"
                }
                else {
                    Write-Log "INFO" "Claude install dir already in User PATH"
}
            }
            else {
                Write-Warning "Claude Code 已安装，但命令路径自动配置失败"
                Write-Log "WARN" "PATH auto-fix failed for $nativeBinPath"

            }

            # --- Fresh Shell 验证 (v1.3.3) ---
            $freshCheck = Test-ClaudeCommandInFreshShell
            Write-Log "INFO" "Native Install fresh shell check: Success=$($freshCheck.Success), Version=$($freshCheck.Version), Error=$($freshCheck.Error)"

            if ($freshCheck.Success) {
                Write-Log "INFO" "Native Install fresh shell 可用: $($freshCheck.Output)"
            }
            else {
                Write-Warning "当前窗口可以识别 Claude Code，但新打开的 PowerShell 可能无法识别"
                if ($pathResult.Success -and $pathResult.Changed) {
                    Write-Info "命令路径已配置，关闭当前窗口后重新打开 PowerShell 通常即可解决。"
                }
                else {
                    Write-Info "请运行「一键修复依赖」自动修复命令路径，或重新运行安装助手。"
                }
            }

            # --- v1.3.3 P0-2: 最终成功条件必须以 fresh shell 为准 ---
            # 状态 1: fresh shell 通过 → 完整成功
            if ($verifyResult.Usable -and $freshCheck.Success) {
                Write-NativeInstallUserMessage -Phase "Success" -Detail $verifyResult.Version

                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = if ($nativeResult.Success) { "installed" } else { "installed_postcheck_usable" }
                $result.Version = $verifyResult.Version

                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = $result.Status
                    claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | Out-Null
                return $result
            }

            # 状态 2: claude 可用 + PATH 已写入 + fresh shell 失败 → 部分成功
            if ($verifyResult.Usable -and $pathResult.Success -and -not $freshCheck.Success) {
                Write-NativeInstallUserMessage -Phase "Partial"
                Write-Info "请关闭当前窗口，重新打开 PowerShell 后测试 Claude Code 命令。"
                Write-Info "如仍失败，请运行「一键修复依赖」"

                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed_needs_restart_or_path_fix"
                $result.Version = $verifyResult.Version

                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = "installed_needs_restart_or_path_fix"
                    claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | Out-Null
                return $result
            }

            # 状态 3: claude 可用 + PATH 写入失败 + fresh shell 失败 → 需要修复
            if ($verifyResult.Usable -and -not $pathResult.Success -and -not $freshCheck.Success) {
                Write-Warning "Claude Code 已安装，但命令路径自动配置失败。"
                Write-Info "请优先运行「一键修复依赖」自动修复命令路径。"
                Write-Log "INFO" "Manual PATH add needed: $nativeBinPath"

                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed_needs_path_fix"
                $result.Version = $verifyResult.Version

                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = "installed_needs_path_fix"
                    claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | Out-Null
                return $result
            }

            # 状态 4: claude 可用但逻辑未覆盖的兜底
            Write-Warning "Claude Code 已安装，但暂时无法直接运行 Claude Code 命令"
            Write-Info "请运行「一键修复依赖」自动修复命令路径，或重新运行安装助手。"

            $result.Success = $true
            $result.Method = "official_native"
            $result.Status = "installed_needs_path_fix"
            $result.Version = $verifyResult.Version

            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "official_native"
                claudeInstallStatus       = "installed_needs_path_fix"
                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | Out-Null
            return $result
        }

        # --- 后验验证未通过：claude.exe 不存在或不可用 ---
        if (-not $verifyResult.Exists) {
            Write-Log "INFO" "Native Install 后验验证: claude.exe 未找到"
        }
        elseif (-not $verifyResult.Usable) {
            Write-Log "INFO" "Native Install 后验验证: claude.exe 存在但不可用 - $($verifyResult.Error)"
        }

        # 后验验证失败 → 检查是否是文件占用
        $nativeRawForLockCheck = @(
            $nativeResult.Error
            $nativeResult.RawError
            $nativeResult.Status
        ) -join "`n"
        Write-Log "DEBUG" "Native Install lock check: HasRawError=$([bool]$nativeResult.RawError), TextLength=$($nativeRawForLockCheck.Length)"

        if (Test-IsClaudeNativeFileLockError -Text $nativeRawForLockCheck) {
            Write-Warning "Claude 官方安装器提示文件被占用。"
            Write-Info "请关闭所有 claude / node / PowerShell / Windows Terminal 窗口。"
            Write-Info "然后删除 %USERPROFILE%\.claude\downloads 后重新运行安装。"
            Write-Info "不要删除 %USERPROFILE%\.claude\settings.json。"
        }

        # 后验验证失败时才显示备用通道切换信息
        Write-NativeInstallUserMessage -Phase "Fallback"
        Write-Log "INFO" "Native Install 后验验证未通过，进入备用安装通道 (winget -> npm)"
    }
    else {
        Write-Warning "官方安装方式目前不可用。"
        Write-Info "正在自动切换到备用安装方式..."
        Write-Log "INFO" "Official channel unreachable: $($officialNetwork.Details)"
    }

    # ============================================================
    # Step 2.5: 判断是否应尝试 winget 安装 Claude Code
    # 即使 winget 可用，如果 downloads.claude.ai 不可达，也不应尝试 winget Claude Code，
    # 因为 winget 也会从 downloads.claude.ai 下载，会导致长时间卡住后失败。
    # 但这不影响 winget 安装 Node.js LTS（Node.js 来源是 nodejs.org）。
    # ============================================================
    $downloadsOk = $false
    if ($officialNetwork.ContainsKey("DownloadsOk")) {
        $downloadsOk = [bool]$officialNetwork.DownloadsOk
    }
    $shouldTryWingetClaude = $downloadsOk

    if (-not $shouldTryWingetClaude) {
        Write-Info "当前安装方式连接较慢，已自动切换备用方式。"
        Write-Log "INFO" "downloads.claude.ai unreachable; skip winget Claude; fallback to npm mirror."
    }

    # ============================================================
    # Step 2.6: 尝试 winget 安装 Claude Code（Native Install 失败后的中速通道）
    # ============================================================
    $wingetOk = if ($isMockDecision) {
        ($env:CCDI_MOCK_WINGET -eq "ok")
    }
    else {
        Test-CommandAvailable -CommandName "winget"
    }
    if ($wingetOk -and $shouldTryWingetClaude) {
        Write-Info ""
        Write-Info "正在尝试备用安装方式。"
        Write-Info "这一步可能需要几分钟，请不要关闭窗口。"
        Write-Log "INFO" "Trying winget install Anthropic.ClaudeCode"
        $wingetClaudeResult = Install-ClaudeCodeViaWinget

        # winget 在 Windows PowerShell 5.1 下 Start-Process 的 ExitCode 可能为空，
        # 因此不依赖 $wingetClaudeResult.Success 判断，始终做后验验证。
        # 只要 claude --version 可用，就判定 winget 安装成功。
        Refresh-CurrentProcessPath
        $verifyWingetClaude = Test-ClaudeCommandExisting
        Write-Log "INFO" "winget post verification: Usable=$($verifyWingetClaude.Usable), Version=$($verifyWingetClaude.Version), Path=$($verifyWingetClaude.Path)"

        if ($verifyWingetClaude.Usable) {
            Write-Success "Claude Code 已安装并确认可用。"
            Write-Log "INFO" "winget install verified: version=$($verifyWingetClaude.Version)"
            $result.Success = $true
            $result.Method = "winget"
            $result.Status = "installed"
            $result.Version = $verifyWingetClaude.Version
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "winget"
                claudeInstallStatus       = "installed"
                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | Out-Null
            return $result
        }

        if ($verifyWingetClaude.Exists) {
            Write-Warning "检测到 Claude Code 存在但无法运行，可能是旧安装残留。"
            Write-Log "WARN" "winget: claude exists but unusable: $($verifyWingetClaude.Error)"
            Write-Info "正在自动切换到备用下载方式..."
            try {
                $inv = Get-ClaudeCommandInventory
                if ($inv.ConflictSummary) {
                    Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
                }
            } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
        }
        else {
            Write-Log "INFO" "winget did not produce usable claude: Exists=false; fallback to npm mirror"
            Write-Info "当前方式未确认成功，正在切换到备用下载方式..."
        }
    }
    elseif ($wingetOk -and -not $shouldTryWingetClaude) {
        # 已在 Step 2.5 中提示跳过原因
        Write-Log "INFO" "已跳过 winget Claude Code（shouldTryWingetClaude=$shouldTryWingetClaude），继续 npm 镜像通道。"
    }

    # ============================================================
    # Step 3: npm npmmirror 镜像安装
    # ============================================================
    Write-Info ""
    Write-Log "INFO" "Installing via npm mirror: @anthropic-ai/claude-code"
    Write-Info "备用下载方式可用，开始安装 Claude Code。"
    Write-Info "这一步可能需要几分钟，请不要关闭窗口。"
    Write-Host ""

    # 3a. 检测 Node.js 和 npm
    $mirrorCheck = Test-NpmMirrorClaudeCodeNetwork

    if (-not $mirrorCheck.NodeOk) {
        # Node.js 不存在或版本过低
        Write-Warning "当前需要先安装 Node.js LTS，这是 Claude Code 备用安装所需运行环境。"

        # 尝试 winget 安装 Node.js（仅交互模式）
        $wingetOk = if ($isMockDecision) {
            ($env:CCDI_MOCK_WINGET -eq "ok")
        }
        else {
            Test-CommandAvailable -CommandName "winget"
        }
        if ($wingetOk -and -not $NonInteractive) {
            Write-Info "检测到可用的系统安装工具，可以自动安装 Node.js LTS。"
            Write-Log "INFO" "winget available; offering Node.js LTS install"
            if ($isMockDecision -or (Confirm-UserChoice -Message "是否现在安装 Node.js LTS？Windows 可能弹出权限确认窗口，请选择'是'继续。" -Default "No")) {
                if ($isMockDecision) {
                    Write-Log "DEBUG" "MOCK: auto-confirming winget Node.js install prompt"
                }
                $installResult = if ($isMockDecision) {
                    $mockNodeInstall = if ($env:CCDI_MOCK_NODE_INSTALL) { $env:CCDI_MOCK_NODE_INSTALL } else { "fail" }
                    Write-Log "DEBUG" "MOCK: winget install Node.js -> CCDI_MOCK_NODE_INSTALL=$mockNodeInstall"
                    if ($mockNodeInstall -eq "success") {
                        $env:CCDI_MOCK_NODE = "ok"
                        $env:CCDI_MOCK_NPM = "ok"
                        $env:CCDI_MOCK_NODE_VERSION = "v20.11.1"
                        $env:CCDI_MOCK_NPM_VERSION = "10.2.4"
                        @{ Success = $true; ExitCode = 0; Output = "mock: OpenJS.NodeJS.LTS installed"; Error = ""; Status = "installed_mock" }
                    }
                    else {
                        @{ Success = $false; ExitCode = -2147012744; Output = ""; Error = "mock: winget install failed"; Status = "failed_mock" }
                    }
                }
                else {
                    Install-NodeJsViaWinget -TimeoutSec 900
                }

                Write-Log "INFO" "winget Node.js 安装返回: Success=$($installResult.Success), ExitCode=$($installResult.ExitCode), Error=$($installResult.Error)"
                Write-Info "正在二次验证 Node.js/npm 是否已经可用..."
                Refresh-CurrentProcessPath

                $nodeInstallCommandAccepted = Test-WingetNodeInstallAccepted -InstallResult $installResult
                $nodeRecheck = Test-NodeJsInstalled
                $npmRecheck = Test-NpmInstalled
                if ($nodeRecheck.Installed -and $nodeRecheck.IsSupported -and $npmRecheck.Installed) {
                    Write-Success "Node.js 已安装并确认可用，继续安装 Claude Code。"
                    Write-Log "INFO" "Node install classification: node_ready_after_install; CommandAccepted=$nodeInstallCommandAccepted; Node=$($nodeRecheck.Version); NodePath=$($nodeRecheck.Path); npm=$($npmRecheck.Version); NpmPath=$($npmRecheck.Path)"

                    # Node 安装后先检测 Claude 是否已由 winget 装好。
                    # 如果 Claude 已可用，直接返回成功，不必继续 npm。
                    Refresh-CurrentProcessPath
                    $postNodeClaude = Test-ClaudeCommandExisting
                    if ($postNodeClaude.Usable) {
                        Write-Success "Claude Code 已可用 (Node 安装后重新检测): $($postNodeClaude.Version)"
                        $result.Success = $true
                        $result.Method = "winget"
                        $result.Status = "installed"
                        $result.Version = $postNodeClaude.Version
                        Update-CcdiState -Updates @{
                            claudeWasAlreadyInstalled = $false
                            claudeInstallMethod       = "winget"
                            claudeInstallStatus       = "installed"
                            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        } | Out-Null
                        return $result
                    }

                    Write-Info "继续安装 Claude Code..."
                    Write-Log "INFO" "Node.js/npm 二次验证通过: Node=$($nodeRecheck.Version), npm=$($npmRecheck.Version)"
                    # 重新检测 npmmirror 可达性（之前因 Node 不可用已提前返回）
                    $mirrorRecheck = Test-NpmMirrorClaudeCodeNetwork
                    if (-not $mirrorRecheck.Reachable) {
                        Write-Error-Msg "备用下载方式不可达。"
                        Write-Log "ERROR" "npmmirror unreachable: $($mirrorRecheck.Error)"
                        Write-Info "官方安装方式和备用下载方式均不可用。"
                        Write-Info "请确认网络是否正常，稍后重新运行。"
                        $result.Method = "none"
                        $result.Status = "failed_npmmirror_unreachable"
                        Update-CcdiState -Updates @{
                            claudeInstallMethod = "none"
                            claudeInstallStatus = "failed_npmmirror_unreachable"
                        } | Out-Null
                        return $result
                    }
                    Write-Info "备用下载方式可用，开始安装 Claude Code。"
                    Write-Log "INFO" "npmmirror reachable; starting npm install"
                    Write-Host ""
                    $mirrorResult = Install-ClaudeCodeNpmMirror
                    if (-not $mirrorResult.Success) {
                        # 不在此处输出失败结论，由后验验证决定最终结果。
                        # npm install ExitCode 在 Windows PowerShell 5.1 下可能为空或非标准。
                        Write-Log "INFO" "npm 镜像安装命令返回异常状态，将进行后验验证确认真实结果。"
                        Write-Log "DEBUG" "npm mirror install details: Error=$($mirrorResult.Error), Status=$($mirrorResult.Status)"
                    }
                    # 验证安装（mock 模式下必须尊重 $mirrorResult.Success）
                    if ($isMockDecision) {
                        if ($mirrorResult.Success) {
                            Write-Log "DEBUG" "MOCK: trusting npm mirror install success"
                            $result.Success = $true
                            $result.Method = "npm_npmmirror"
                            $result.Status = "installed"
                            $result.Version = "1.0.0-mock"
                            Update-CcdiState -Updates @{
                                claudeWasAlreadyInstalled = $false
                                claudeInstallMethod       = "npm_npmmirror"
                                claudeInstallStatus       = "installed"
                                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                            } | Out-Null
                            Write-Success "Claude Code 安装完成 (mock npm mirror)"
                            return $result
                        }
                        else {
                            Write-Log "DEBUG" "MOCK: npm mirror install returned failure; returning failed_official_and_mirror"
                            $result.Method = "npm_npmmirror"
                            $result.Status = "failed_official_and_mirror"
                            $result.Success = $false
                            Update-CcdiState -Updates @{
                                claudeInstallMethod = "npm_npmmirror"
                                claudeInstallStatus = "failed_official_and_mirror"
                            } | Out-Null
                            return $result
                        }
                    }
                    Refresh-CurrentProcessPath
                    Write-Info "正在确认 Claude Code 是否已经可用..."
                    $ready = Wait-ClaudeCommandReady -TotalWaitSec 30 -IntervalSec 2 -Context "npm 镜像安装后确认"

                    if ($ready.Ready) {
                        if (-not $mirrorResult.Success) {
                            Write-Log "INFO" "npm 镜像安装命令返回异常但固定路径后验验证通过，以 claude --version 为准。"
                        }
                        Write-Success "Claude Code 已安装并确认可用。"
                        Write-Log "INFO" "npm mirror verification ready: Status=$($ready.Status), Version=$($ready.Version), Path=$($ready.Path), Source=$($ready.Source)"
                        $result.Success = $true
                        $result.Method = "npm_npmmirror"
                        $result.Status = if ($mirrorResult.Success) { "installed" } else { "installed_postcheck_usable" }
                        $result.Version = if ($ready.Version) { $ready.Version } else { "2.1.179 (Claude Code)" }
                        Update-CcdiState -Updates @{
                            claudeWasAlreadyInstalled = $false
                            claudeInstallMethod       = "npm_npmmirror"
                            claudeInstallStatus       = $result.Status
                            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        } | Out-Null
                        return $result
                    }

                    Write-Warning "备用下载方式暂未完成确认。"
                    Write-Info "工具已等待并重新检测，但仍未确认 Claude Code 可用。"
                    Write-Info "安装未完成，请稍后重试；如果仍失败，再运行「一键诊断.cmd」获取详细诊断报告。"
                    Write-Log "WARN" "npm mirror Wait-ClaudeCommandReady not ready: Status=$($ready.Status), Attempts=$($ready.Attempts), LastError=$($ready.LastError)"

                    $result.Method = "npm_npmmirror"
                    $result.Status = "claude_install_failed"
                    $result.Success = $false
                    $result.UserMessage = "Claude Code 安装未完成，请稍后重试或运行一键诊断。"
                    $stateUpdate = @{
                        claudeInstallMethod = "npm_npmmirror"
                        claudeInstallStatus = $result.Status
                    }
                    Update-CcdiState -Updates $stateUpdate | Out-Null
                    return $result
                }
                else {
                    # Node 安装后二次验证未通过，明确按安装失败处理，不再要求用户重开终端继续。
                    $diagLines = @()
                    if ($nodeRecheck.Installed -and $nodeRecheck.IsSupported) {
                        $diagLines += "Node.js: $($nodeRecheck.Version) (可用)"
                    }
                    elseif ($nodeRecheck.Installed) {
                        $diagLines += "Node.js: $($nodeRecheck.Version) (版本不满足要求，需要 >= 18)"
                    }
                    else {
                        $diagLines += "Node.js: 未检测到"
                    }
                    if ($npmRecheck.Installed) {
                        $diagLines += "npm: $($npmRecheck.Version) (可用)"
                    }
                    else {
                        $diagLines += "npm: 未检测到"
                    }

                    Write-Error-Msg "Node.js 自动安装失败，通常是网络或系统安装源暂时不可用。"
                    Write-Info "请稍后重试，或手动安装 Node.js LTS 后再运行本工具。"
                    Write-Log "ERROR" "Node install classification: node_install_failed; CommandAccepted=$nodeInstallCommandAccepted; ExitCode=$($installResult.ExitCode); Error=$($installResult.Error); Diagnostics=$($diagLines -join '; ')"
                    $result.Method = "node-via-winget"
                    $result.Status = "node_install_failed"
                    $result.Success = $false
                    $result.UserMessage = "Node.js 安装失败，请检查网络或稍后重试/手动安装 Node.js LTS。"
                    Update-CcdiState -Updates @{
                        claudeInstallMethod = "node-via-winget"
                        claudeInstallStatus = "node_install_failed"
                    } | Out-Null
                    return $result
                }
            }
            else {
                Write-Info "请手动安装 Node.js 后重新运行本脚本。"
                Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
                $result.Status = "failed_missing_node_or_npm"
                Update-CcdiState -Updates @{
                    claudeInstallStatus = "failed_missing_node_or_npm"
                } | Out-Null
            }
        }
        elseif ($NonInteractive) {
            Write-Error-Msg "非交互模式下不会自动安装系统软件（Node.js）。"
            Write-Info "请先手动安装 Node.js 18+ 后重新运行本脚本。"
            $result.Status = "failed_missing_node_or_npm"
            Update-CcdiState -Updates @{
                claudeInstallStatus = "failed_missing_node_or_npm"
            } | Out-Null
        }
        else {
            Write-Info "未检测到系统安装工具，请手动安装必要运行环境。"
            Write-Log "INFO" "winget not detected; prompting manual Node.js install"
            Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
            Write-Info "安装完成后重新运行本脚本。"
            $result.Status = "failed_missing_node_or_npm"
            Update-CcdiState -Updates @{
                claudeInstallStatus = "failed_missing_node_or_npm"
            } | Out-Null
        }

        return $result
    }

    if (-not $mirrorCheck.NpmAvailable) {
        # npm 不可用（Node.js 存在但 npm 缺失或损坏）
        Write-Error-Msg "npm fallback 需要 npm。"
        Write-Log "ERROR" "npm unavailable: $($mirrorCheck.Error)"
        Write-Info "如果你只使用已安装的 Claude Code，则无需处理。"
        Write-Info "当前 Claude Code 不可用，且官方安装方式不可用；请修复 Node.js/npm 后重新运行本工具。"
        $result.Status = "failed_missing_node_or_npm"
        Update-CcdiState -Updates @{
            claudeInstallStatus = "failed_missing_node_or_npm"
        } | Out-Null
        return $result
    }

    if (-not $mirrorCheck.Reachable) {
        # npmmirror 不可达
        Write-Error-Msg "备用下载方式不可达。"
        Write-Log "ERROR" "npmmirror unreachable: $($mirrorCheck.Error)"
        Write-Info "官方安装方式和备用下载方式均不可用。"
        Write-Info "请确认:"
        Write-Info "  1. 网络是否正常连接"
        Write-Info "  2. 是否需要配置代理/VPN"
        Write-Info "  3. 稍等片刻后重新运行"
        $result.Method = "none"
        $result.Status = "failed_npmmirror_unreachable"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "none"
            claudeInstallStatus = "failed_npmmirror_unreachable"
        } | Out-Null
        return $result
    }

    # 3b. 执行 npm mirror 安装
    Write-Log "INFO" "Node.js: $($mirrorCheck.NodeOk) (ok), npm: ok, npmmirror: reachable"
    Write-Info "必要运行环境检查通过，正在安装 Claude Code..."
    Write-Host ""

    $mirrorResult = Install-ClaudeCodeNpmMirror

    if (-not $mirrorResult.Success) {
        # 不在此处输出失败结论，由后验验证决定最终结果。
        # npm install ExitCode 在 Windows PowerShell 5.1 下可能为空或非标准。
        Write-Log "INFO" "npm 镜像安装命令返回异常状态，将进行后验验证确认真实结果。"
        Write-Log "DEBUG" "npm mirror install details: Error=$($mirrorResult.Error), Status=$($mirrorResult.Status)"
    }

    # 3c. 验证安装（mock 模式下必须尊重 $mirrorResult.Success）
    if ($isMockDecision) {
        if ($mirrorResult.Success) {
            Write-Log "DEBUG" "MOCK: trusting npm mirror install success"
            $result.Success = $true
            $result.Method = "npm_npmmirror"
            $result.Status = "installed"
            $result.Version = "1.0.0-mock"
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "npm_npmmirror"
                claudeInstallStatus       = "installed"
                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | Out-Null
            Write-Success "Claude Code 安装完成 (mock npm mirror)"
            return $result
        }
        else {
            Write-Log "DEBUG" "MOCK: npm mirror install returned failure; returning failed_official_and_mirror"
            $result.Method = "npm_npmmirror"
            $result.Status = "failed_official_and_mirror"
            $result.Success = $false
            Update-CcdiState -Updates @{
                claudeInstallMethod = "npm_npmmirror"
                claudeInstallStatus = "failed_official_and_mirror"
            } | Out-Null
            return $result
        }
    }
    Refresh-CurrentProcessPath
    Write-Info "正在确认 Claude Code 是否已经可用..."
    $ready = Wait-ClaudeCommandReady -TotalWaitSec 30 -IntervalSec 2 -Context "npm 镜像安装后确认"

    if ($ready.Ready) {
        if (-not $mirrorResult.Success) {
            Write-Log "INFO" "npm 镜像安装命令返回异常但固定路径后验验证通过，以 claude --version 为准。"
        }
        Write-Success "Claude Code 已安装并确认可用。"
        Write-Log "INFO" "npm mirror verification ready: Status=$($ready.Status), Version=$($ready.Version), Path=$($ready.Path), Source=$($ready.Source)"
        $result.Success = $true
        $result.Method = "npm_npmmirror"
        $result.Status = if ($mirrorResult.Success) { "installed" } else { "installed_postcheck_usable" }
        $result.Version = if ($ready.Version) { $ready.Version } else { "2.1.179 (Claude Code)" }
        Update-CcdiState -Updates @{
            claudeWasAlreadyInstalled = $false
            claudeInstallMethod       = "npm_npmmirror"
            claudeInstallStatus       = $result.Status
            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | Out-Null
        return $result
    }

    # 只有这里才输出"未完成确认"
    Write-Warning "备用下载方式暂未完成确认。"
    Write-Info "工具已等待并重新检测，但仍未确认 Claude Code 可用。"
    Write-Info "安装未完成，请稍后重试；如果仍失败，再运行「一键诊断.cmd」获取详细诊断报告。"
    Write-Log "WARN" "npm mirror Wait-ClaudeCommandReady not ready: Status=$($ready.Status), Attempts=$($ready.Attempts), LastError=$($ready.LastError)"

    $result.Method = "npm_npmmirror"
    $result.Status = "claude_install_failed"
    $result.Success = $false
    $result.UserMessage = "Claude Code 安装未完成，请稍后重试或运行一键诊断。"
    $stateUpdate = @{
        claudeInstallMethod = "npm_npmmirror"
        claudeInstallStatus = $result.Status
    }
    Update-CcdiState -Updates $stateUpdate | Out-Null
    return $result
}
