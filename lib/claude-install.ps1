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
                "broken" { return @{ Exists = $true; Usable = $false; Version = $null; Error = "mock: claude command exists but --version fails (corrupt or residual)"; Path = $null; Source = "" } }
                default { return @{ Exists = $false; Usable = $false; Version = $null; Error = "mock: claude not found"; Path = $null; Source = "" } }
            }
        }
        # Non-mock TestSafe: use Get-Command only, skip --version
        $cmd = Get-Command "claude" -ErrorAction SilentlyContinue
        if ($cmd) {
            return @{ Exists = $true; Usable = $true; Version = "test-safe"; Error = ""; Path = $null; Source = "" }
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
            Path    = $CandidatePath
            Source  = $SourceHint
            Exists  = $true
            Usable  = $false
            Version = $null
            Risk    = $RiskHint
            Note    = $NoteHint
            Error   = ""
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
            elseif ($pathLower -match '\\appdata\\roaming\\npm\\claude\.cmd$' -or $pathLower -match '\\npm\\claude\.cmd$') {
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
            $verResult = Invoke-CommandSafe -Command $candidate.Path -Arguments @("--version") -TimeoutSec 8
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

        # 只有存在才进入 Candidates（不存在路径已在 _add 中过滤）
        [void]$inventory.Candidates.Add($candidate)
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
    # Conflict 判断
    # ============================================================
    $hasConflict = $false
    $conflictReasons = [System.Collections.ArrayList]::new()

    if ($inventory.Candidates.Count -gt 1) {
        $hasConflict = $true
        [void]$conflictReasons.Add("检测到多个 claude 命令来源，可能存在 PATH 优先级冲突。")
    }

    if ($inventory.Active -and -not $inventory.Active.Usable) {
        $usableOthers = $inventory.Candidates | Where-Object { $_.Usable -and (_normalize $_.Path) -ne (_normalize $inventory.Active.Path) }
        if ($usableOthers) {
            $hasConflict = $true
            [void]$conflictReasons.Add("当前 PATH 优先命中的 claude 不可用，但其他路径存在可用 claude。")
        }
    }

    if ($inventory.Active -and $inventory.Active.Source -eq "windowsapps") {
        $hasConflict = $true
        [void]$conflictReasons.Add("WindowsApps alias 可能抢占真实 Claude Code CLI。")
    }

    $errorCandidates = $inventory.Candidates | Where-Object { $_.Risk -eq "ERROR" }
    if ($errorCandidates) {
        $hasConflict = $true
        [void]$conflictReasons.Add("存在 $($errorCandidates.Count) 个无法运行的 claude 候选（残留或损坏）。")
    }

    $hasWA = $inventory.Candidates | Where-Object { $_.Source -eq "windowsapps" }
    $hasNativeOrNpm = $inventory.Candidates | Where-Object { $_.Source -in @("native_local_bin", "npm_global") }
    if ($hasWA -and $hasNativeOrNpm) {
        $hasConflict = $true
        [void]$conflictReasons.Add("WindowsApps alias 与 Native Install/npm 安装并存，可能冲突。")
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
        阶段: Start | Heartbeat | Verify | Success | Partial | Fallback
    .PARAMETER Detail
        附加信息（如版本号）
    #>
    param(
        [ValidateSet("Start", "Heartbeat", "Verify", "Success", "Partial", "Fallback")]
        [string]$Phase,
        [string]$Detail = ""
    )

    switch ($Phase) {
        "Start" {
            Write-Info "正在执行 Claude 官方安装包。"
            Write-Info "此步骤可能持续数分钟，中途没有新文字也正常，请不要关闭窗口。"
            Write-Info "安装完成后，本工具会自动验证结果。"
        }
        "Heartbeat" {
            Write-Info "仍在安装 Claude Code，请继续等待，不要关闭窗口。"
        }
        "Verify" {
            Write-Info "官方安装包执行结束，正在验证安装结果..."
        }
        "Success" {
            Write-Success "Claude Code 已安装：$Detail"
            Write-Success "已确认新 PowerShell 可直接运行 claude"
        }
        "Partial" {
            Write-Warning "Claude Code 已安装，但新 PowerShell 验证暂未通过。"
            Write-Info "本工具会继续完成配置。安装结束后请按完成页提示验证或修复。"
        }
        "Fallback" {
            Write-Warning "官方安装方式未完成验证，正在切换备用安装方式。"
            Write-Info "这通常是网络或系统环境导致，不代表整个安装失败。"
            Write-Info "将继续尝试 winget / npm 镜像方式。"
        }
    }
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
        [string]$TimeoutMessage = ""
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

    # 默认消息
    if (-not $StartMessage) { $StartMessage = "正在执行 $FriendlyName..." }
    if (-not $HeartbeatMessage) { $HeartbeatMessage = "仍在执行 $FriendlyName，请继续等待，不要关闭窗口。" }
    if (-not $TimeoutMessage) { $TimeoutMessage = "$FriendlyName 超时，已停止。请运行一键诊断。" }

    if ($StartMessage) { Write-Info $StartMessage }

    try {
        $proc = Start-Process -FilePath $FilePath `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        Write-Log "INFO" "Invoke-InstallCommandCaptured: started PID=$($proc.Id), FriendlyName=$FriendlyName"

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = [Math]::Max(1, $HeartbeatSec)

        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $nextHeartbeat
            if (-not $proc.HasExited) {
                $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 0)
                if ($HeartbeatMessage) { Write-Info "$HeartbeatMessage（已等待 $elapsed 秒）" }
                $nextHeartbeat = $HeartbeatSec
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
                Write-Warning $TimeoutMessage
                Write-Info "详细错误已写入日志，请运行「一键诊断.cmd」排查。"
                return $result
            }
        }

        $result.ExitCode = $proc.ExitCode
        $result.Success = ($proc.ExitCode -eq 0)
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
        Write-NativeInstallUserMessage -Phase "Start"
        Write-Host ""

        # v1.3.3 P1-2: 默认使用捕获模式，英文输出写入日志，控制台只显示中文心跳
        $installResult = Invoke-InstallCommandCaptured -FilePath "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempInstallScript
        ) -TimeoutSec 600 -HeartbeatSec 30 -FriendlyName "Claude 官方安装包" `
            -StartMessage "" -HeartbeatMessage "仍在安装 Claude Code，请继续等待，不要关闭窗口。"

        # 清理临时脚本
        Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue

        # 安装脚本执行结束，记录 ExitCode 状态到日志（不向用户展示）
        Write-NativeInstallUserMessage -Phase "Verify"

        if ($installResult.Success) {
            Write-Log "INFO" "Native Install 安装脚本 ExitCode=0"
        }
        else {
            # 只记录详细错误到日志，不向用户展示 PowerShell 堆栈或失败提示
            $result.Error = "Native Install 安装脚本返回非零退出码或异常"
            $result.RawError = $installResult.Error
            Write-Log "INFO" "Native Install 安装脚本返回非零退出码 (ExitCode=$($installResult.ExitCode), DurationMs=$($installResult.DurationMs))，将进行后验验证判断真实结果"
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

    Write-Info "正在使用 npm 镜像安装 Claude Code。"
    Write-Info "这一步会下载 Anthropic 官方 Claude Code 包，可能需要数分钟。"
    Write-Info "仍在安装 Claude Code，请继续等待，不要关闭窗口。"

    # 解析 npm.cmd（禁止使用 npm.ps1，会导致 "%1 is not a valid Win32 application"）
    $npmResolved = Resolve-NpmCmdPath
    if (-not $npmResolved.Found) {
        $result.Error = "未找到 npm.cmd: $($npmResolved.Error)"
        $result.Status = "failed_missing_npm_cmd"
        Write-Error-Msg "npm.cmd 未找到，无法执行 npm 镜像安装。"
        Write-Info "请关闭窗口重新打开后重试，或重新安装 Node.js LTS。"
        Write-Log "ERROR" $result.Error
        return $result
    }

    Write-Log "INFO" "执行: $($npmResolved.Path) install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"

    # v1.3.3 UX: 使用捕获模式，英文输出写入日志，控制台只显示中文心跳
    $installResult = Invoke-InstallCommandCaptured -FilePath $npmResolved.Path -Arguments @(
        "install",
        "-g",
        "@anthropic-ai/claude-code",
        "--registry=https://registry.npmmirror.com"
    ) -TimeoutSec 900 -HeartbeatSec 30 -FriendlyName "npm 镜像安装 Claude Code" `
        -StartMessage "正在使用 npm 镜像安装 Claude Code。" `
        -HeartbeatMessage "仍在安装 Claude Code，请继续等待，不要关闭窗口。"

    if ($installResult.Success) {
        Write-Success "npm 镜像安装 Claude Code 完成。"
        Write-Log "INFO" "npm mirror 安装成功"
        $result.Success = $true
    }
    else {
        $result.Error = "npm 镜像安装未完成验证: $($installResult.Error)"
        Write-Warning "npm 镜像安装未完成验证。"
        Write-Info "可能原因：Node.js/npm 不完整、镜像网络不可达、npm 全局 PATH 异常。"
        Write-Info "请运行「一键诊断.cmd」生成 report.txt 发给技术支持。"
        Write-Log "ERROR" $result.Error
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
    Write-Info "如果下载超时，将自动切换备用安装通道（winget → npm 镜像）。"
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
        使用 winget 安装 Node.js LTS，保留终端输出让用户看到下载进度。
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

    Write-Info "正在通过 Windows 官方 winget 安装 Node.js LTS。"
    Write-Info "这是备用安装方式所需依赖，下载约几十 MB。"
    Write-Info "安装完成后可能需要关闭窗口重新运行本工具。"
    Write-Host ""

    return Invoke-VisibleInstallCommand -FilePath "winget" -Arguments @(
        "install", "OpenJS.NodeJS.LTS",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    ) -TimeoutSec $TimeoutSec -TestSafe:$TestSafe
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

    Write-Info "正在使用 winget 安装 Claude Code（Windows 官方包管理器方式）..."
    Write-Log "INFO" "执行: winget install Anthropic.ClaudeCode"

    return Invoke-VisibleInstallCommand -FilePath "winget" -Arguments @(
        "install", "Anthropic.ClaudeCode",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    ) -TimeoutSec 600 -TestSafe:$TestSafe
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
                Write-Info "检测到 Claude Code 已通过 Native Install 安装，正在检查 PowerShell 命令可用性..."

                # 检查 User PATH
                $pathCheck = Test-UserPathContains -TargetPath $nativeBin
                if (-not $pathCheck.Contains) {
                    Write-Warning "Claude Code 已安装，但安装目录未加入用户 PATH。"
                    Write-Info "正在自动修复 User PATH..."
                    $pathFix = Ensure-UserPathEntry -PathToAdd $nativeBin
                }
                else {
                    $pathFix = @{ Success = $true; Changed = $false; Error = "" }
                    Write-Info "Claude Code 安装目录已在 User PATH 中。"
                }

                # Fresh shell 验证
                $freshCheck = Test-ClaudeCommandInFreshShell

                if ($freshCheck.Success) {
                    Write-Success "新 PowerShell 可直接运行 claude: $($freshCheck.Output)"
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
                    Write-Warning "PATH 已写入，但 fresh shell 验证仍未通过。"
                    Write-Info "请关闭当前窗口，重新打开 PowerShell 后执行 claude --version 验证。"

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

                Write-Warning "Claude Code 已安装，但 PATH 自动修复失败。"
                Write-Info "请运行「一键修复依赖」或手动将以下路径加入 User PATH：$nativeBin"

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
    # Step 2: 检测官方安装通道 + 尝试 Native Install
    # ============================================================
    Write-Info ""
    Write-Info "优先使用 Claude 官方 Native Install 方式安装..."
    Write-Info "正在检测官方安装通道..."

    $officialNetwork = Test-ClaudeOfficialInstallNetwork

    if ($officialNetwork.Reachable) {
        Write-Success "Claude 官方安装通道可用。"
        Write-Info "开始 Native Install..."

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
                Write-Success "Claude Code 安装完成 (mock Native Install)"
                return $result
            }

            Write-Success "Claude Code 已安装: $($verifyResult.Version)"

            # --- PATH 持久化 (v1.3.3) ---
            $nativeBinPath = Get-NativeClaudeBinPath
            $pathResult = Ensure-UserPathEntry -PathToAdd $nativeBinPath

            if ($pathResult.Success) {
                if ($pathResult.Changed) {
                    Write-Success "已将 Claude Code 安装目录加入用户 PATH"
                    Write-Info "新打开的 PowerShell 将可以直接运行 claude"
                }
                else {
                    Write-Info "Claude Code 安装目录已在用户 PATH 中"
                }
            }
            else {
                Write-Warning "Claude Code 已安装，但 PATH 自动写入失败"
                Write-Warning "请手动将以下路径加入用户 PATH:"
                Write-Warning "  $nativeBinPath"
            }

            # --- Fresh Shell 验证 (v1.3.3) ---
            $freshCheck = Test-ClaudeCommandInFreshShell
            Write-Log "INFO" "Native Install fresh shell check: Success=$($freshCheck.Success), Version=$($freshCheck.Version), Error=$($freshCheck.Error)"

            if ($freshCheck.Success) {
                Write-Success "新 PowerShell 可直接运行 claude: $($freshCheck.Output)"
            }
            else {
                Write-Warning "claude --version 在当前进程可用，但新 PowerShell 中可能无法识别"
                if ($pathResult.Success -and $pathResult.Changed) {
                    Write-Info "PATH 已写入注册表，关闭当前窗口后重开 PowerShell 通常即可解决。"
                }
                else {
                    Write-Info "请运行「一键修复依赖」或重新运行安装工具修复 PATH。"
                }
            }

            # --- v1.3.3 P0-2: 最终成功条件必须以 fresh shell 为准 ---
            # 状态 1: fresh shell 通过 → 完整成功
            if ($verifyResult.Usable -and $freshCheck.Success) {
                Write-NativeInstallUserMessage -Phase "Success" -Detail $verifyResult.Version

                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed"
                $result.Version = $verifyResult.Version

                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = "installed"
                    claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                } | Out-Null
                return $result
            }

            # 状态 2: claude 可用 + PATH 已写入 + fresh shell 失败 → 部分成功
            if ($verifyResult.Usable -and $pathResult.Success -and -not $freshCheck.Success) {
                Write-NativeInstallUserMessage -Phase "Partial"
                Write-Info "请关闭当前窗口，重新打开 PowerShell 后执行 claude --version"
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
                Write-Warning "Claude Code 已安装，但 PATH 自动写入失败"
                Write-Info "请运行「一键修复依赖」或手动将以下路径加入 User PATH："
                Write-Info "  $nativeBinPath"

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
            Write-Warning "Claude Code 已安装，但 claude 命令暂时无法直接运行"
            Write-Info "请运行「一键修复依赖」或重新运行安装工具修复 PATH"

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
        Write-Info "下一步将优先尝试 winget；如果 winget 不可用或验证失败，再切换 npmmirror 镜像。"
        Write-Log "INFO" "Native Install 后验验证未通过，进入备用安装通道"
    }
    else {
        Write-Warning "Claude 官方安装通道不可用: $($officialNetwork.Details)"
        Write-Info "将自动切换备用安装通道（winget → npmmirror 镜像）。"
    }

    # ============================================================
    # Step 2.5: 尝试 winget 安装 Claude Code（Native Install 失败后的中速通道）
    # ============================================================
    $wingetOk = if ($isMockDecision) {
        ($env:CCDI_MOCK_WINGET -eq "ok")
    }
    else {
        Test-CommandAvailable -CommandName "winget"
    }
    if ($wingetOk) {
        Write-Info ""
        Write-Info "正在尝试通过 winget 安装 Claude Code（备用通道）..."
        Write-Info "这是 Windows 官方包管理器方式，下载可能需要数分钟。"
        $wingetClaudeResult = Install-ClaudeCodeViaWinget

        # winget 在 Windows PowerShell 5.1 下 Start-Process 的 ExitCode 可能为空，
        # 因此不依赖 $wingetClaudeResult.Success 判断，始终做后验验证。
        # 只要 claude --version 可用，就判定 winget 安装成功。
        Refresh-CurrentProcessPath
        $verifyWingetClaude = Test-ClaudeCommandExisting
        Write-Log "INFO" "winget Claude Code 后验验证: Usable=$($verifyWingetClaude.Usable), Version=$($verifyWingetClaude.Version), Path=$($verifyWingetClaude.Path)"

        if ($verifyWingetClaude.Usable) {
            Write-Success "winget 安装验证通过: $($verifyWingetClaude.Version)"
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
            Write-Warning "检测到 claude 命令存在但无法运行，可能是旧安装、残留 shim 或 WindowsApps alias。"
            Write-Log "WARN" "winget: claude exists but unusable: $($verifyWingetClaude.Error)"
            Write-Info "继续尝试 npm 镜像安装..."
            try {
                $inv = Get-ClaudeCommandInventory
                if ($inv.ConflictSummary) {
                    Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
                }
            } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
        }
        else {
            Write-Log "INFO" "winget 安装后 claude 命令未找到: ExitCode=$($wingetClaudeResult.ExitCode), Error=$($wingetClaudeResult.Error)"
            Write-Info "winget 安装后暂未检测到 claude，继续尝试 npm 镜像安装..."
        }
    }

    # ============================================================
    # Step 3: npm npmmirror 镜像安装
    # ============================================================
    Write-Info ""
    Write-Info "正在使用 npm 镜像安装 Claude Code。"
    Write-Info "这会下载 Anthropic 官方发布的 @anthropic-ai/claude-code 包。"
    Write-Host ""

    # 3a. 检测 Node.js 和 npm
    $mirrorCheck = Test-NpmMirrorClaudeCodeNetwork

    if (-not $mirrorCheck.NodeOk) {
        # Node.js 不存在或版本过低
        Write-Error-Msg "官方安装通道不可用，镜像安装需要 Node.js 18+ 和 npm。"

        # 尝试 winget 安装 Node.js（仅交互模式）
        $wingetOk = if ($isMockDecision) {
            ($env:CCDI_MOCK_WINGET -eq "ok")
        }
        else {
            Test-CommandAvailable -CommandName "winget"
        }
        if ($wingetOk -and -not $NonInteractive) {
            Write-Info "检测到 winget，可以自动安装 Node.js LTS。"
            if ($isMockDecision -or (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js LTS？这会修改系统环境。" -Default "No")) {
                if ($isMockDecision) {
                    Write-Log "DEBUG" "MOCK: auto-confirming winget Node.js install prompt"
                }
                $installResult = if ($isMockDecision) {
                    $mockNodeInstall = if ($env:CCDI_MOCK_NODE_INSTALL) { $env:CCDI_MOCK_NODE_INSTALL } else { "fail" }
                    Write-Log "DEBUG" "MOCK: winget install Node.js -> CCDI_MOCK_NODE_INSTALL=$mockNodeInstall"
                    @{ Success = ($mockNodeInstall -eq "success"); Error = if ($mockNodeInstall -eq "success") { "" } else { "mock: winget install failed" } }
                }
                else {
                    Install-NodeJsViaWinget -TimeoutSec 900
                }

                Write-Log "INFO" "winget Node.js 安装返回: Success=$($installResult.Success), ExitCode=$($installResult.ExitCode), Error=$($installResult.Error)"
                Write-Info "正在二次验证 Node.js/npm 是否已经可用..."
                Refresh-CurrentProcessPath

                $nodeRecheck = Test-NodeJsInstalled
                $npmRecheck = Test-NpmInstalled
                if ($nodeRecheck.Installed -and $nodeRecheck.IsSupported -and $npmRecheck.Installed) {
                    Write-Success "Node.js/npm 已验证可用 (Node $($nodeRecheck.Version), npm $($npmRecheck.Version))。"

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
                        Write-Error-Msg "npm 镜像仓库不可达: $($mirrorRecheck.Error)"
                        Write-Info "官方安装通道和 npm 镜像仓库均不可用。"
                        Write-Info "请确认网络是否正常，稍后重新运行。"
                        $result.Method = "none"
                        $result.Status = "failed_npmmirror_unreachable"
                        Update-CcdiState -Updates @{
                            claudeInstallMethod = "none"
                            claudeInstallStatus = "failed_npmmirror_unreachable"
                        } | Out-Null
                        return $result
                    }
                    Write-Info "npmmirror: 可访问，开始安装 Claude Code..."
                    Write-Host ""
                    $mirrorResult = Install-ClaudeCodeNpmMirror
                    if (-not $mirrorResult.Success) {
                        Write-Error-Msg "官方 Native Install、winget 和 npm 镜像安装均未通过验证。"
                        Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
                        $result.Method = "none"
                        $result.Status = "failed_official_and_mirror"
                        Update-CcdiState -Updates @{
                            claudeInstallMethod = "none"
                            claudeInstallStatus = "failed_official_and_mirror"
                        } | Out-Null
                        return $result
                    }
                    # 验证安装
                    if ($isMockDecision) {
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
                    Refresh-CurrentProcessPath
                    $verifyResult = Test-ClaudeCommandExisting
                    if ($verifyResult.Usable) {
                        Write-Success "Claude Code 安装验证通过: $($verifyResult.Version)"
                        $result.Success = $true
                        $result.Method = "npm_npmmirror"
                        $result.Status = "installed"
                        $result.Version = $verifyResult.Version
                        Update-CcdiState -Updates @{
                            claudeWasAlreadyInstalled = $false
                            claudeInstallMethod       = "npm_npmmirror"
                            claudeInstallStatus       = "installed"
                            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        } | Out-Null
                        return $result
                    }
                    elseif ($verifyResult.Exists) {
                        Write-Warning "检测到 claude 命令存在但无法运行: $($verifyResult.Error)"
                        Write-Warning "可能是旧安装、残留 shim、WindowsApps alias 或 PATH 冲突。"
                        Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
                        Write-Log "WARN" "npm mirror: claude exists but unusable: $($verifyResult.Error)"
                        try {
                            $inv = Get-ClaudeCommandInventory
                            if ($inv.ConflictSummary) {
                                Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
                            }
                        } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
                        $result.Method = "npm_npmmirror"
                        $result.Status = "failed_claude_unusable"
                        Update-CcdiState -Updates @{
                            claudeInstallMethod = "npm_npmmirror"
                            claudeInstallStatus = "failed_claude_unusable"
                        } | Out-Null
                        return $result
                    }
                    else {
                        Write-Warning "claude 命令未找到，正在刷新 PATH 并重新检测..."
                        Refresh-CurrentProcessPath
                        $verifyResult2 = Test-ClaudeCommandExisting
                        if ($verifyResult2.Usable) {
                            Write-Success "Claude Code 安装验证通过: $($verifyResult2.Version)"
                            $result.Success = $true
                            $result.Method = "npm_npmmirror"
                            $result.Status = "installed"
                            $result.Version = $verifyResult2.Version
                            Update-CcdiState -Updates @{
                                claudeWasAlreadyInstalled = $false
                                claudeInstallMethod       = "npm_npmmirror"
                                claudeInstallStatus       = "installed"
                                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                            } | Out-Null
                            return $result
                        }
                        elseif ($verifyResult2.Exists) {
                            Write-Warning "检测到 claude 命令存在但无法运行（PATH 刷新后）: $($verifyResult2.Error)"
                            Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
                            Write-Log "WARN" "npm mirror PATH retry: claude exists but unusable: $($verifyResult2.Error)"
                            try {
                                $inv = Get-ClaudeCommandInventory
                                if ($inv.ConflictSummary) {
                                    Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
                                }
                            } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
                            $result.Method = "npm_npmmirror"
                            $result.Status = "failed_claude_unusable"
                            Update-CcdiState -Updates @{
                                claudeInstallMethod = "npm_npmmirror"
                                claudeInstallStatus = "failed_claude_unusable"
                            } | Out-Null
                            return $result
                        }
                        Write-Warning "Claude Code 可能已安装，但当前终端还没有刷新 PATH。"
                        Write-Info "请关闭此窗口后重新双击 [00-点我开始安装.cmd]。"
                        Write-Info "如果仍不行，请运行 [一键诊断.cmd] 获取诊断报告。"
                        $npmResolvedForPrefix = Resolve-NpmCmdPath
                        $npmPrefixResult = if ($npmResolvedForPrefix.Found) {
                            Invoke-CommandSafe -Command $npmResolvedForPrefix.Path -Arguments @("prefix", "-g") -TimeoutSec 8
                        } else {
                            @{ Success = $false; Output = ""; Error = "npm.cmd not resolved for prefix check" }
                        }
                        if ($npmPrefixResult.Success) {
                            Write-Info "npm 全局安装路径: $($npmPrefixResult.Output.Trim())"
                        }
                        $result.Method = "npm_npmmirror"
                        $result.Status = "installed_needs_restart"
                        Update-CcdiState -Updates @{
                            claudeInstallMethod = "npm_npmmirror"
                            claudeInstallStatus = "installed_needs_restart"
                            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        } | Out-Null
                        return $result
                    }
                }
                else {
                    # Node 安装后二次验证未完全通过，给出具体诊断
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

                    Write-Warning "Node.js/npm 安装后验证未完全通过:"
                    foreach ($line in $diagLines) {
                        Write-Info "  $line"
                    }
                    Write-Info "请关闭此窗口后重新双击 [00-点我开始安装.cmd]。"
                    $result.Method = "node-via-winget"
                    $result.Status = "node_installed_needs_restart"
                    Update-CcdiState -Updates @{
                        claudeInstallMethod = "node-via-winget"
                        claudeInstallStatus = "node_installed_needs_restart"
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
            Write-Info "未检测到 winget，请手动安装 Node.js:"
            Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
            Write-Info "安装完成后，关闭并重新打开终端，然后重新运行本脚本。"
            $result.Status = "failed_missing_node_or_npm"
            Update-CcdiState -Updates @{
                claudeInstallStatus = "failed_missing_node_or_npm"
            } | Out-Null
        }

        return $result
    }

    if (-not $mirrorCheck.NpmAvailable) {
        # npm 不可用（Node.js 存在但 npm 缺失或损坏）
        Write-Error-Msg "npm 不可用: $($mirrorCheck.Error)"
        Write-Info "官方安装通道不可用，镜像安装需要 npm。"
        Write-Info "请确认 Node.js 安装是否完整，然后重新打开终端重试。"
        $result.Status = "failed_missing_node_or_npm"
        Update-CcdiState -Updates @{
            claudeInstallStatus = "failed_missing_node_or_npm"
        } | Out-Null
        return $result
    }

    if (-not $mirrorCheck.Reachable) {
        # npmmirror 不可达
        Write-Error-Msg "npm 镜像仓库不可达: $($mirrorCheck.Error)"
        Write-Info "官方安装通道和 npm 镜像仓库均不可用。"
        Write-Info "请确认:"
        Write-Info "  1. 网络是否正常连接"
        Write-Info "  2. 是否需要配置代理/VPN"
        Write-Info "  3. 是否暂时屏蔽了 registry.npmmirror.com"
        Write-Info "  4. 稍等片刻后重新运行"
        $result.Method = "none"
        $result.Status = "failed_npmmirror_unreachable"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "none"
            claudeInstallStatus = "failed_npmmirror_unreachable"
        } | Out-Null
        return $result
    }

    # 3b. 执行 npm mirror 安装
    Write-Info "Node.js: $($mirrorCheck.NodeOk) (可用)"
    Write-Info "npm: 可用"
    Write-Info "npmmirror: 可访问"
    Write-Host ""

    $mirrorResult = Install-ClaudeCodeNpmMirror

    if (-not $mirrorResult.Success) {
        Write-Error-Msg "官方 Native Install、winget 和 npm 镜像安装均未通过验证。"
        Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
        $result.Method = "none"
        $result.Status = "failed_official_and_mirror"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "none"
            claudeInstallStatus = "failed_official_and_mirror"
        } | Out-Null
        return $result
    }

    # 3c. 验证安装（mock 模式下自动信任安装结果）
    if ($isMockDecision) {
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
    Refresh-CurrentProcessPath
    $verifyResult = Test-ClaudeCommandExisting
    if ($verifyResult.Usable) {
        Write-Success "Claude Code 安装验证通过: $($verifyResult.Version)"
        # claude doctor is diagnostic-only; not called during install

        $result.Success = $true
        $result.Method = "npm_npmmirror"
        $result.Status = "installed"
        $result.Version = $verifyResult.Version
        Update-CcdiState -Updates @{
            claudeWasAlreadyInstalled = $false
            claudeInstallMethod       = "npm_npmmirror"
            claudeInstallStatus       = "installed"
            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | Out-Null
        return $result
    }
    elseif ($verifyResult.Exists) {
        Write-Warning "检测到 claude 命令存在但无法运行: $($verifyResult.Error)"
        Write-Warning "可能是旧安装、残留 shim、WindowsApps alias 或 PATH 冲突。"
        Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
        Write-Log "WARN" "npm mirror: claude exists but unusable: $($verifyResult.Error)"
        try {
            $inv = Get-ClaudeCommandInventory
            if ($inv.ConflictSummary) {
                Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
            }
        } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
        $result.Method = "npm_npmmirror"
        $result.Status = "failed_claude_unusable"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "npm_npmmirror"
            claudeInstallStatus = "failed_claude_unusable"
        } | Out-Null
        return $result
    }
    else {
        Write-Warning "claude 命令未找到，正在刷新 PATH 并重新检测..."
        Refresh-CurrentProcessPath
        $verifyResult2 = Test-ClaudeCommandExisting
        if ($verifyResult2.Usable) {
            Write-Success "Claude Code 安装验证通过: $($verifyResult2.Version)"
            $result.Success = $true
            $result.Method = "npm_npmmirror"
            $result.Status = "installed"
            $result.Version = $verifyResult2.Version
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "npm_npmmirror"
                claudeInstallStatus       = "installed"
                claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            } | Out-Null
            return $result
        }
        elseif ($verifyResult2.Exists) {
            Write-Warning "检测到 claude 命令存在但无法运行（PATH 刷新后）: $($verifyResult2.Error)"
            Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
            Write-Log "WARN" "npm mirror PATH retry: claude exists but unusable: $($verifyResult2.Error)"
            try {
                $inv = Get-ClaudeCommandInventory
                if ($inv.ConflictSummary) {
                    Write-Log "WARN" "Claude command inventory: $($inv.ConflictSummary)"
                }
            } catch { Write-Log "DEBUG" "Get-ClaudeCommandInventory failed (non-blocking): $_" }
            $result.Method = "npm_npmmirror"
            $result.Status = "failed_claude_unusable"
            Update-CcdiState -Updates @{
                claudeInstallMethod = "npm_npmmirror"
                claudeInstallStatus = "failed_claude_unusable"
            } | Out-Null
            return $result
        }

        Write-Warning "Claude Code 可能已安装，但当前终端还没有刷新 PATH。"
        Write-Info "请关闭此窗口后重新双击 [00-点我开始安装.cmd]。"
        Write-Info "如果仍不行，请运行 [一键诊断.cmd] 获取诊断报告。"

        $npmResolvedForPrefix = Resolve-NpmCmdPath
        $npmPrefix = if ($npmResolvedForPrefix.Found) {
            Invoke-CommandSafe -Command $npmResolvedForPrefix.Path -Arguments @("prefix", "-g") -TimeoutSec 8
        } else {
            @{ Success = $false; Output = ""; Error = "npm.cmd not resolved" }
        }
        if ($npmPrefix.Success) {
            Write-Info "npm 全局安装路径: $($npmPrefix.Output.Trim())"
        }

        $result.Method = "npm_npmmirror"
        $result.Status = "installed_needs_restart"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "npm_npmmirror"
            claudeInstallStatus = "installed_needs_restart"
            claudeInstallCompletedAt  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | Out-Null
        return $result
    }
}
