# ============================================================
# claude-install.ps1 - Claude Code 安装模块 (v1.3.2)
# 集中管理 Claude Code 的检测和安装逻辑。
#
# 安装策略:
#   1. claude 已存在 → 跳过（不覆盖、不重装、不自动更新）
#   2. 官方 Native Install 可用 → 优先使用
#   3. 官方不可用或安装失败 → 自动切换 npmmirror npm 镜像
#   4. npm 镜像需要 Node.js >= 18 + npm 可用
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
    .RETURNS
        包含 Exists, Usable, Version, Error 的哈希表
    #>
    $result = @{
        Exists  = $false
        Usable  = $false
        Version = $null
        Error   = ""
    }

    # Mock decision support（仅在 CCDI_MOCK_INSTALL_DECISION=1 且 CCDI_TEST_MODE=1 时生效）
    if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
        $mockClaude = if ($env:CCDI_MOCK_CLAUDE) { $env:CCDI_MOCK_CLAUDE } else { "missing" }
        Write-Log "DEBUG" "MOCK: Test-ClaudeCommandExisting -> CCDI_MOCK_CLAUDE=$mockClaude"
        switch ($mockClaude) {
            "ok" {
                return @{ Exists = $true; Usable = $true; Version = "1.0.0-mock"; Error = "" }
            }
            "broken" {
                return @{ Exists = $true; Usable = $false; Version = $null; Error = "mock: claude command exists but --version fails (corrupt or residual)" }
            }
            default {
                return @{ Exists = $false; Usable = $false; Version = $null; Error = "mock: claude not found" }
            }
        }
    }

    # 刷新 PATH 后检测
    Refresh-CurrentProcessPath

    if (Test-CommandAvailable -CommandName "claude") {
        $result.Exists = $true
        $verResult = Invoke-CommandSafe -Command "claude" -Arguments @("--version") -TimeoutSec 30
        if ($verResult.Success -and -not [string]::IsNullOrWhiteSpace($verResult.Output)) {
            $result.Usable = $true
            $result.Version = $verResult.Output.Trim()
        }
        else {
            $result.Usable = $false
            $result.Error = "claude 命令存在但 --version 失败（残留或损坏）: $($verResult.Error)"
            Write-Log "WARN" $result.Error
        }
    }

    return $result
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
    .RETURNS
        包含 Reachable, NpmAvailable, NodeOk, Error 的哈希表
    #>
    $result = @{
        Reachable    = $false
        NpmAvailable = $false
        NodeOk       = $false
        Error        = ""
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
        }
        else {
            $result.Reachable = $false
            $result.Error = "mock: npmmirror unreachable"
        }

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

    # 3. 检测 npmmirror 上的包
    $npmViewResult = Invoke-CommandSafe -Command "npm" -Arguments @(
        "view", "@anthropic-ai/claude-code", "version",
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

    return $result
}

# ============================================================
# 安装函数
# ============================================================

function Install-ClaudeCodeNative {
    <#
    .SYNOPSIS
        使用 Claude 官方 Native Install 安装 Claude Code。
        执行: irm https://claude.ai/install.ps1 | iex
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
            $mockNative = if ($env:CCDI_MOCK_NATIVE_INSTALL) { $env:CCDI_MOCK_NATIVE_INSTALL } else { "fail" }
            Write-Log "DEBUG" "MOCK: Install-ClaudeCodeNative -> CCDI_MOCK_NATIVE_INSTALL=$mockNative"
            if ($mockNative -eq "success") {
                return @{ Success = $true; Error = ""; Status = "installed_mock" }
            }
            else {
                return @{ Success = $false; Error = "mock: native install failed"; Status = "failed_mock" }
            }
        }
        Write-Log "INFO" "TestSafe: 跳过 Native Install 执行"
        $result.Status = "skipped_test_safe"
        $result.Error = "skipped_test_safe"
        return $result
    }

    Write-Info "正在使用 Claude 官方 Native Install 方式安装..."
    Write-Log "INFO" "执行: irm https://claude.ai/install.ps1 | iex"

    try {
        $tempInstallScript = Join-Path $env:TEMP "claude_native_install_${PID}_$(Get-Random).ps1"
        $downloadResult = Invoke-CommandSafe -Command "powershell" -Arguments @(
            "-NoProfile", "-Command",
            "Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -OutFile '$tempInstallScript'"
        ) -TimeoutSec 180 -ProgressMessage "仍在下载 Claude 官方安装脚本，请勿关闭窗口。"

        if (-not $downloadResult.Success -or -not (Test-Path $tempInstallScript)) {
            $result.Error = "下载官方安装脚本失败: $($downloadResult.Error)"
            Write-Warning $result.Error
            Write-Log "ERROR" $result.Error
            return $result
        }

        Write-Info "正在执行官方安装脚本（可能需要几分钟）..."
        $installResult = Invoke-CommandSafe -Command "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempInstallScript
        ) -TimeoutSec 600 -ProgressMessage "仍在安装 Claude Code，请勿关闭窗口。"

        # 清理临时脚本
        Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue

        if ($installResult.Success) {
            Write-Success "Native Install 安装脚本执行成功。"
            Write-Log "INFO" "Native Install 完成"
            $result.Success = $true
        }
        else {
            $result.Error = "Native Install 安装脚本执行未成功完成: $($installResult.Error)"
            Write-Warning $result.Error
            Write-Log "WARN" $result.Error
        }
    }
    catch {
        $result.Error = "Native Install 异常: $($_.Exception.Message)"
        Write-Warning $result.Error
        Write-Log "ERROR" $result.Error

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

    Write-Info "正在使用 npm + npmmirror 镜像安装 Claude Code..."
    Write-Info "执行: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"
    Write-Log "INFO" "执行: npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com"

    $installResult = Invoke-CommandSafe -Command "npm" -Arguments @(
        "install", "-g", "@anthropic-ai/claude-code",
        "--registry=https://registry.npmmirror.com"
    ) -TimeoutSec 900 -ProgressMessage "仍在通过 npm 镜像安装 Claude Code，请勿关闭窗口。"

    if ($installResult.Success) {
        Write-Success "npm 镜像安装 Claude Code 成功！"
        Write-Log "INFO" "npm mirror 安装成功"
        $result.Success = $true
    }
    else {
        $result.Error = "npm 镜像安装失败: $($installResult.Error)"
        Write-Error-Msg "npm 镜像安装过程中出现错误:"
        Write-Host $installResult.Error -ForegroundColor Red

        if ($installResult.Error -match "EACCES|permission|权限") {
            Write-Warning "可能是 npm 全局安装权限问题。"
            Write-Warning "建议使用 nvm 管理 Node.js，或使用官方 Native Install 方式。"
        }
        Write-Log "ERROR" $result.Error
    }

    return $result
}

function Clear-StaleClaudeDoctorProcesses {
    <#
    .SYNOPSIS
        清理残留的 claude doctor 孤儿进程。
        只杀命令行包含 "claude" 和 "doctor" 的进程，
        不杀普通 claude 会话 (--resume / --continue 等)。
        默认只清理启动超过 60 秒的陈旧进程。
    .PARAMETER MinAgeSec
        进程最小存活时间（秒），短于此时间的不杀。默认 60。
    .PARAMETER Force
        强制清理所有 doctor 进程，不检查存活时间。
    .PARAMETER ParentPid
        限制只清理指定父进程 ID 下的子进程。不指定则清理全局。
    .RETURNS
        包含 KilledCount, Errors 的哈希表
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

    try {
        # 获取所有 claude.exe 进程
        $claudeProcs = $null
        try {
            $claudeProcs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop
        }
        catch {
            Write-Log "DEBUG" "Get-CimInstance 获取 claude 进程失败，尝试 Get-WmiObject: $_"
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

        $now = Get-Date
        $myPid = $PID

        foreach ($proc in $claudeProcs) {
            $procId = $proc.ProcessId
            $cmdLine = if ($proc.CommandLine) { $proc.CommandLine } else { "" }

            # 只杀命令行包含 "doctor" 的进程
            if ($cmdLine -notmatch 'doctor') {
                continue
            }

            # 不杀自己
            if ($procId -eq $myPid) {
                continue
            }

            # 如果指定了 ParentPid，只清理属于该父进程的子进程
            if ($ParentPid -gt 0 -and $proc.ParentProcessId -ne $ParentPid) {
                Write-Log "DEBUG" "跳过非目标父进程 PID=$($proc.ParentProcessId) 的 claude doctor 进程 PID=$procId"
                continue
            }

            # 检查存活时间（除非 -Force）
            if (-not $Force) {
                $creationDate = $proc.CreationDate
                if ($creationDate) {
                    $age = ($now - $creationDate).TotalSeconds
                    if ($age -lt $MinAgeSec) {
                        Write-Log "DEBUG" "跳过较新的 claude doctor 进程 PID=$procId (存活 ${age}s < ${MinAgeSec}s)"
                        continue
                    }
                }
            }

            Write-Log "INFO" "正在清理残留 claude doctor 进程 PID=$procId, CommandLine=$cmdLine"

            # 优先使用 taskkill /T /F 杀进程树
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

            # fallback: Stop-Process
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
                [void]$result.Errors.Add("无法终止 PID=$($procId): $killError")
                Write-Log "ERROR" "Clear-StaleClaudeDoctorProcesses: 无法终止 PID=$($procId): $killError"
            }
        }

        Write-Log "INFO" "Clear-StaleClaudeDoctorProcesses: 清理完成，共终止 $($result.KilledCount) 个残留 doctor 进程"
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
        委托 Invoke-ClaudeDoctorInteractiveSafe 内联执行，继承 TTY。
    .PARAMETER TestSafe
        测试安全模式：跳过真实 claude doctor 执行。
    .RETURNS
        包含 Success, Output, Status 的哈希表
    #>
    param(
        [switch]$TestSafe
    )

    $result = @{
        Success = $false
        Output  = ""
        Status  = ""
    }

    $doctor = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 30 -TestSafe:$TestSafe

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
    else {
        Write-Warning "claude doctor 未完成或返回异常，已跳过。安装流程会继续。"
        Write-Info "如需进一步排查，安装结束后可运行「一键诊断.cmd」。"
        Write-Log "DEBUG" "claude doctor 输出: $($doctor.Error)"
        $result.Status = "failed"
    }

    return $result
}

function Invoke-ClaudeDoctorInteractiveSafe {
    <#
    .SYNOPSIS
        在当前 PowerShell 终端内联执行 claude doctor，继承真实 TTY 环境。
        不使用 Invoke-CommandSafe / Start-Process / cmd.exe / stdout 重定向。
        通过独立 watchdog job 实现超时保护，超时后递归杀进程树。
    .PARAMETER TimeoutSec
        超时秒数，默认 30。
    .PARAMETER TestSafe
        测试安全模式：跳过真实 claude doctor 执行。
    .RETURNS
        包含 Success, TimedOut, ExitCode, Error, Command, DurationMs 的哈希表
    #>
    param(
        [int]$TimeoutSec = 30,
        [switch]$TestSafe
    )

    $result = @{
        Success    = $false
        TimedOut   = $false
        ExitCode   = $null
        Error      = ""
        Command    = ""
        DurationMs = 0
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

            # 查找属于当前 PowerShell 的 claude doctor 子进程
            $targets = @()
            try {
                $allClaude = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue
                if (-not $allClaude) {
                    $allClaude = Get-WmiObject Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue
                }
                if ($allClaude) {
                    $targets = @($allClaude | Where-Object {
                        $_.ParentProcessId -eq $ParentPid -and
                        ($_.CommandLine -match 'doctor')
                    })
                }
            }
            catch {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 查询进程失败: $_" | Out-File $LogPath -Append -Encoding UTF8
                return
            }

            if ($targets.Count -eq 0) {
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 未找到 claude doctor 子进程（可能已正常退出）" | Out-File $LogPath -Append -Encoding UTF8
                return
            }

            foreach ($t in $targets) {
                $pidToKill = $t.ProcessId
                $cmdLine = if ($t.CommandLine) { $t.CommandLine } else { "(unknown)" }
                "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: 超时，正在终止 PID=$pidToKill, CommandLine=$cmdLine" | Out-File $LogPath -Append -Encoding UTF8

                # taskkill /T /F 杀进程树
                try {
                    $killOutput = & taskkill.exe /PID $pidToKill /T /F 2>&1
                    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: taskkill 结果: $killOutput" | Out-File $LogPath -Append -Encoding UTF8
                }
                catch {
                    "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: taskkill 异常: $_" | Out-File $LogPath -Append -Encoding UTF8
                    try {
                        Stop-Process -Id $pidToKill -Force -ErrorAction Stop
                        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: Stop-Process fallback 成功 PID=$pidToKill" | Out-File $LogPath -Append -Encoding UTF8
                    }
                    catch {
                        "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] WATCHDOG: Stop-Process 也失败: $_" | Out-File $LogPath -Append -Encoding UTF8
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
        Write-Log "WARN" "Start-Job 创建 watchdog 失败（可能被安全策略禁用）: $_。claude doctor 将无超时保护运行。"
        Write-Info "watchdog 不可用，claude doctor 将在无超时保护下运行（最多等待 120 秒）。"
        $watchdogAvailable = $false
    }

    # --- 内联执行 claude doctor（继承当前终端 TTY 环境）---
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1

    try {
        & $claudePath doctor
        $exitCode = $LASTEXITCODE
    }
    catch {
        $result.Error = "claude doctor 执行异常: $_"
        Write-Log "ERROR" "Invoke-ClaudeDoctorInteractiveSafe: 内联执行异常: $_"
        $exitCode = -1
    }

    $sw.Stop()
    $result.DurationMs = $sw.ElapsedMilliseconds
    $result.ExitCode = $exitCode

    # --- 检查 Watchdog 状态 ---
    $watchdogFired = $false
    if ($watchdogAvailable) {
        try {
            $jobState = $watchdogJob.State
            Write-Log "DEBUG" "Watchdog job 状态: State=$jobState"

            if ($jobState -eq 'Running') {
                # 正常完成，watchdog 没触发
                Stop-Job $watchdogJob -ErrorAction SilentlyContinue
                $watchdogFired = $false
                Write-Log "DEBUG" "Watchdog 未触发，claude doctor 在超时前完成"
            }
            else {
                # Watchdog 已结束 → 它触发了
                $watchdogFired = $true
                $watchdogLog = Receive-Job $watchdogJob -ErrorAction SilentlyContinue
                Write-Log "INFO" "Watchdog 已触发：$watchdogLog"
            }
        }
        catch {
            Write-Log "WARN" "检查 watchdog 状态异常: $_"
        }
        finally {
            Remove-Job $watchdogJob -Force -ErrorAction SilentlyContinue
            # 清理 watchdog 日志
            if (Test-Path $killLogPath) {
                try {
                    $watchdogContent = Get-Content $killLogPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($watchdogContent) {
                        Write-Log "DEBUG" "Watchdog 日志: $watchdogContent"
                    }
                    Remove-Item $killLogPath -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "DEBUG" "清理 watchdog 日志失败: $_"
                }
            }
        }
    }

    # --- 处理结果 ---
    if ($watchdogFired) {
        $result.TimedOut = $true
        $result.Success = $false
        $result.Error = "claude doctor 超时（${TimeoutSec}秒），watchdog 已终止进程树"
        Write-Log "WARN" "Invoke-ClaudeDoctorInteractiveSafe: $($result.Error)"

        # 超时后再次清理残留：仅清理属于本次父进程的子进程
        try {
            $postClean = Clear-StaleClaudeDoctorProcesses -ParentPid $parentPid
            Write-Log "INFO" "超时后清理本进程 doctor 子进程: 清理了 $($postClean.KilledCount) 个"
        }
        catch {
            Write-Log "WARN" "超时后清理残留失败: $_"
        }
    }
    elseif ($exitCode -eq 0) {
        $result.Success = $true
        Write-Log "INFO" "claude doctor 成功完成 (ExitCode=0, DurationMs=$($result.DurationMs))"
    }
    else {
        $result.Success = $false
        $result.Error = "claude doctor 返回非零退出码: $exitCode"
        Write-Log "WARN" "Invoke-ClaudeDoctorInteractiveSafe: $($result.Error), DurationMs=$($result.DurationMs)"
    }

    return $result
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
          3. 官方不可用或安装失败 → 自动切换 npmmirror npm 镜像
          4. npm 镜像需要 Node.js >= 18 + npm
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
            # claude 存在且可用 → 跳过
            Write-Success "Claude Code 已安装: $($existingCheck.Version)"
            Write-Info "已安装时不覆盖、不重装、不自动更新。"

            [void](Invoke-ClaudeDoctorSafe)

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
            Write-Info "将尝试通过安装流程修复（不覆盖已有配置）。"
            Write-Log "WARN" "Claude Code 存在但不可用 (existing_broken)，进入修复路径"
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

        if ($nativeResult.Success) {
            # 验证安装（mock 模式下自动信任安装结果）
            if ($isMockDecision) {
                Write-Log "DEBUG" "MOCK: trusting native install success"
                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed"
                $result.Version = "1.0.0-mock"
                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = "installed"
                } | Out-Null
                Write-Success "Claude Code 安装完成 (mock Native Install)"
                return $result
            }
            Refresh-CurrentProcessPath
            $verifyResult = Test-ClaudeCommandExisting
            if ($verifyResult.Exists) {
                Write-Success "Claude Code 安装验证通过 (Native Install): $($verifyResult.Version)"
                [void](Invoke-ClaudeDoctorSafe)

                $result.Success = $true
                $result.Method = "official_native"
                $result.Status = "installed"
                $result.Version = $verifyResult.Version
                Update-CcdiState -Updates @{
                    claudeWasAlreadyInstalled = $false
                    claudeInstallMethod       = "official_native"
                    claudeInstallStatus       = "installed"
                } | Out-Null
                return $result
            }
            else {
                Write-Warning "安装脚本已执行但 claude 命令未找到，正在刷新 PATH 重试..."
                Refresh-CurrentProcessPath
                $verifyResult2 = Test-ClaudeCommandExisting
                if ($verifyResult2.Exists) {
                    Write-Success "Claude Code 安装验证通过（PATH 刷新后）: $($verifyResult2.Version)"
                    [void](Invoke-ClaudeDoctorSafe)

                    $result.Success = $true
                    $result.Method = "official_native"
                    $result.Status = "installed"
                    $result.Version = $verifyResult2.Version
                    Update-CcdiState -Updates @{
                        claudeWasAlreadyInstalled = $false
                        claudeInstallMethod       = "official_native"
                        claudeInstallStatus       = "installed"
                    } | Out-Null
                    return $result
                }
                Write-Warning "Native Install 安装脚本已执行但未检测到 claude 命令。"
                Write-Warning "将尝试 npmmirror 镜像安装作为备用方案。"
            }
        }
        else {
            Write-Warning "Native Install 失败: $($nativeResult.Error)"
            Write-Info "将自动切换 npmmirror 镜像安装..."
        }
    }
    else {
        Write-Warning "Claude 官方安装通道不可用: $($officialNetwork.Details)"
        Write-Info "将自动切换 npmmirror 国内镜像安装..."
    }

    # ============================================================
    # Step 3: npm npmmirror 镜像安装
    # ============================================================
    Write-Info ""
    Write-Info "正在使用 npmmirror 国内镜像安装 Claude Code..."
    Write-Info "这种安装方式使用 Anthropic 官方发布的 @anthropic-ai/claude-code npm 包。"
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
            if ($isMockDecision -or (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js LTS？（将修改系统环境）")) {
                if ($isMockDecision) {
                    Write-Log "DEBUG" "MOCK: auto-confirming winget Node.js install prompt"
                }
                Write-Info "正在使用 winget 安装 Node.js LTS（可能需要几分钟）..."
                $installResult = if ($isMockDecision) {
                    $mockNodeInstall = if ($env:CCDI_MOCK_NODE_INSTALL) { $env:CCDI_MOCK_NODE_INSTALL } else { "fail" }
                    Write-Log "DEBUG" "MOCK: winget install Node.js -> CCDI_MOCK_NODE_INSTALL=$mockNodeInstall"
                    @{ Success = ($mockNodeInstall -eq "success"); Error = if ($mockNodeInstall -eq "success") { "" } else { "mock: winget install failed" } }
                }
                else {
                    Invoke-CommandSafe -Command "winget" -Arguments @(
                        "install", "OpenJS.NodeJS.LTS",
                        "--accept-package-agreements",
                        "--accept-source-agreements",
                        "--silent"
                    ) -TimeoutSec 900 -ProgressMessage "仍在安装 Node.js LTS，请勿关闭窗口。"
                }

                if ($installResult.Success) {
                    Write-Success "Node.js 安装完成！"
                    Write-Warning "请关闭并重新打开 PowerShell/命令提示符，然后重新运行本脚本。"
                    Write-Warning "这样 Node.js 和 npm 命令才能被正确识别。"
                    $result.Method = "node-via-winget"
                    $result.Status = "node_installed_needs_restart"
                    Update-CcdiState -Updates @{
                        claudeInstallMethod = "node-via-winget"
                        claudeInstallStatus = "node_installed_needs_restart"
                    } | Out-Null
                }
                else {
                    Write-Error-Msg "Node.js 自动安装失败。"
                    Write-Info "请手动下载安装: https://nodejs.org (选择 LTS 版本)"
                    Write-Info "安装完成后重新运行本脚本。"
                    $result.Status = "failed_missing_node_or_npm"
                    Update-CcdiState -Updates @{
                        claudeInstallMethod = ""
                        claudeInstallStatus = "failed_missing_node_or_npm"
                    } | Out-Null
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
        Write-Error-Msg "官方 Native Install 和 npm 镜像安装均失败。"
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
        } | Out-Null
        Write-Success "Claude Code 安装完成 (mock npm mirror)"
        return $result
    }
    Refresh-CurrentProcessPath
    $verifyResult = Test-ClaudeCommandExisting
    if ($verifyResult.Exists) {
        Write-Success "Claude Code 安装验证通过 (npm mirror): $($verifyResult.Version)"
        [void](Invoke-ClaudeDoctorSafe)

        $result.Success = $true
        $result.Method = "npm_npmmirror"
        $result.Status = "installed"
        $result.Version = $verifyResult.Version
        Update-CcdiState -Updates @{
            claudeWasAlreadyInstalled = $false
            claudeInstallMethod       = "npm_npmmirror"
            claudeInstallStatus       = "installed"
        } | Out-Null
        return $result
    }
    else {
        Write-Warning "claude 命令未找到，正在刷新 PATH 并重新检测..."
        Refresh-CurrentProcessPath
        $verifyResult2 = Test-ClaudeCommandExisting
        if ($verifyResult2.Exists) {
            Write-Success "Claude Code 检测成功（PATH 刷新后）: $($verifyResult2.Version)"
            $result.Success = $true
            $result.Method = "npm_npmmirror"
            $result.Status = "installed"
            $result.Version = $verifyResult2.Version
            Update-CcdiState -Updates @{
                claudeWasAlreadyInstalled = $false
                claudeInstallMethod       = "npm_npmmirror"
                claudeInstallStatus       = "installed"
            } | Out-Null
            return $result
        }

        Write-Warning "Claude Code 可能已安装，但当前终端还没有刷新 PATH。"
        Write-Info "请关闭此窗口后重新双击 [开始安装.cmd]。"
        Write-Info "如果仍不行，请运行 [一键诊断.cmd] 获取诊断报告。"

        $npmPrefix = Invoke-CommandSafe -Command "npm" -Arguments @("prefix", "-g")
        if ($npmPrefix.Success) {
            Write-Info "npm 全局安装路径: $($npmPrefix.Output.Trim())"
        }

        $result.Method = "npm_npmmirror"
        $result.Status = "installed_needs_restart"
        Update-CcdiState -Updates @{
            claudeInstallMethod = "npm_npmmirror"
            claudeInstallStatus = "installed_needs_restart"
        } | Out-Null
        return $result
    }
}
