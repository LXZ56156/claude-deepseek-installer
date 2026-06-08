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
    .RETURNS
        包含 Exists, Version, Error 的哈希表
    #>
    $result = @{
        Exists  = $false
        Version = $null
        Error   = ""
    }

    # 刷新 PATH 后检测
    Refresh-CurrentProcessPath

    if (Test-CommandAvailable -CommandName "claude") {
        $verResult = Invoke-CommandSafe -Command "claude" -Arguments @("--version") -TimeoutSec 30
        if ($verResult.Success) {
            $result.Exists = $true
            $result.Version = $verResult.Output.Trim()
        }
        else {
            $result.Exists = $true
            $result.Version = "已安装（无法获取版本）"
            $result.Error = $verResult.Error
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
          1. https://claude.ai/install.ps1 — 需要能正常下载（GET 请求）
          2. https://downloads.claude.ai — DNS/TLS/HTTP 有响应即可
    .RETURNS
        包含 Reachable, InstallScriptOk, DownloadsOk, Details 的哈希表
    #>
    $result = @{
        Reachable       = $false
        InstallScriptOk = $false
        DownloadsOk     = $false
        Details         = ""
    }

    Write-Log "DEBUG" "检测 Claude 官方安装通道..."

    # 1. 检测 install.ps1
    $installCheck = Test-HttpEndpointReachable -Url "https://claude.ai/install.ps1" -Method "GET" -TimeoutSec 15
    if ($installCheck.Reachable) {
        $result.InstallScriptOk = $true
        Write-Log "DEBUG" "claude.ai/install.ps1 可达 (HTTP $($installCheck.StatusCode))"
    }
    else {
        Write-Log "WARN" "claude.ai/install.ps1 不可达: $($installCheck.Error)"
        $result.Details += "无法下载 install.ps1 ($($installCheck.Error)); "
    }

    # 2. 检测 downloads.claude.ai
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
    }

    if ($TestSafe) {
        Write-Log "INFO" "TestSafe: 跳过 Native Install 执行"
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
    }

    if ($TestSafe) {
        Write-Log "INFO" "TestSafe: 跳过 npm mirror 安装"
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

function Invoke-ClaudeDoctorSafe {
    <#
    .SYNOPSIS
        安全运行 claude doctor，失败不阻断主流程，只写日志。
    .RETURNS
        包含 Success, Output 的哈希表
    #>
    $result = @{
        Success = $false
        Output  = ""
    }

    Write-Info "运行 claude doctor..."
    $doctorResult = Invoke-CommandSafe -Command "claude" -Arguments @("doctor") -TimeoutSec 180

    if ($doctorResult.Success) {
        Write-Host $doctorResult.Output
        $result.Success = $true
        $result.Output = $doctorResult.Output
    }
    else {
        Write-Log "DEBUG" "claude doctor 输出: $($doctorResult.Error)"
        $result.Output = $doctorResult.Error
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
    if ($TestSafe) {
        Write-Warning "当前为测试安全模式：不会安装、更新或卸载 Claude Code。"
        Write-Info "将只检查 claude 命令是否存在，并继续后续沙盒配置验证。"

        $existingCheck = Test-ClaudeCommandExisting
        if ($existingCheck.Exists) {
            Write-Success "检测到 Claude Code: $($existingCheck.Version)"
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
        Write-Success "Claude Code 已安装: $($existingCheck.Version)"
        Write-Info "已安装时不覆盖、不重装、不自动更新。"

        # 运行 claude doctor（失败不阻断）
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

        Write-Log "INFO" "Claude Code 已存在，跳过安装: $($existingCheck.Version)"
        return $result
    }

    Write-Info "Claude Code 未安装，开始安装流程..."

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
            # 验证安装
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
        $wingetOk = Test-CommandAvailable -CommandName "winget"
        if ($wingetOk -and -not $NonInteractive) {
            Write-Info "检测到 winget，可以自动安装 Node.js LTS。"
            if (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js LTS？（将修改系统环境）") {
                Write-Info "正在使用 winget 安装 Node.js LTS（可能需要几分钟）..."
                $installResult = Invoke-CommandSafe -Command "winget" -Arguments @(
                    "install", "OpenJS.NodeJS.LTS",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--silent"
                ) -TimeoutSec 900 -ProgressMessage "仍在安装 Node.js LTS，请勿关闭窗口。"

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

    # 3c. 验证安装
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
