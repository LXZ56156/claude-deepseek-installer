# ============================================================
# env-check.ps1 - 环境检测模块
# 提供系统环境、网络、命令、文件的检测功能
#
# 依赖: common.ps1, logger.ps1（需要先由调用方 dot-source）
# 注意: 本模块不自行 dot-source 依赖模块，由入口脚本统一管理加载顺序
# ============================================================

# ============================================================
# 系统信息检测
# ============================================================

function Get-CcdiObjectPropertyNamesSafe {
    param(
        [Parameter(Mandatory = $false)]
        $Object
    )

    if ($null -eq $Object) {
        return @()
    }

    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-WindowsVersionInfo {
    <#
    .SYNOPSIS
        获取 Windows 版本信息
    .RETURNS
        包含 Version, Build, ReleaseId, IsWindows10, IsWindows11 的哈希表
    #>
    $info = @{
        Version      = "Unknown"
        Build        = "Unknown"
        IsWindows10  = $false
        IsWindows11  = $false
        IsSupported  = $false
    }

    try {
        if (Test-CommandAvailable -CommandName "Get-CimInstance") {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        else {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        }
        $info.Version = $os.Caption
        $info.Build = $os.Version

        # 判断 Windows 10/11，并检查最低版本要求
        if ($os.Version -match '^10\.0\.(\d+)') {
            $buildNumber = [int]$Matches[1]
            if ($buildNumber -ge 22000) {
                $info.IsWindows11 = $true
                $info.IsSupported = $true
            }
            elseif ($buildNumber -ge 17763) {
                $info.IsWindows10 = $true
                $info.IsSupported = $true
            }
            elseif ($buildNumber -ge 10240) {
                $info.IsWindows10 = $true
                $info.IsSupported = $false
            }
        }
    }
    catch {
        Write-Log "ERROR" "获取 Windows 版本失败: $_"
    }

    return $info
}

function Get-PowerShellVersionInfo {
    <#
    .SYNOPSIS
        获取 PowerShell 版本信息
    .RETURNS
        包含 Version, Edition, IsCore, IsSupported 的哈希表
    #>
    $info = @{
        Version     = $PSVersionTable.PSVersion.ToString()
        Edition     = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { "Desktop" }
        IsCore      = ($PSVersionTable.PSEdition -eq "Core")
        IsSupported = $false
    }

    # PowerShell 5.1+ 或 PowerShell 7+ 都支持
    $major = $PSVersionTable.PSVersion.Major
    if ($major -ge 5) {
        $info.IsSupported = $true
    }

    return $info
}

function Get-SystemArchitectureInfo {
    <#
    .SYNOPSIS
        获取 CPU/OS 架构信息
    .RETURNS
        包含 Architecture, IsSupported 的哈希表
    #>
    $info = @{
        Architecture = "Unknown"
        IsSupported  = $false
    }

    try {
        # 优先使用 RuntimeInformation（PowerShell 5.1+）
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
        $info.Architecture = $arch.ToString()
        switch ($arch) {
            "X64"   { $info.IsSupported = $true }
            "Arm64" { $info.IsSupported = $true }
            default { $info.IsSupported = $false }
        }
    }
    catch {
        # 回退到环境变量
        try {
            $envArch = $env:PROCESSOR_ARCHITECTURE
            if ($envArch) {
                $info.Architecture = $envArch
                switch -Wildcard ($envArch) {
                    "AMD64"  { $info.IsSupported = $true; $info.Architecture = "X64" }
                    "ARM64"  { $info.IsSupported = $true; $info.Architecture = "Arm64" }
                    default  { $info.IsSupported = $false }
                }
            }
        }
        catch {
            Write-Log "ERROR" "无法获取系统架构信息: $_"
        }
    }

    Write-Log "DEBUG" "系统架构: $($info.Architecture), 支持: $($info.IsSupported)"
    return $info
}

function Get-MemoryInfo {
    <#
    .SYNOPSIS
        获取物理内存信息
    .RETURNS
        包含 TotalGB, IsSufficient 的哈希表
    #>
    $info = @{
        TotalGB      = 0
        IsSufficient = $false
    }

    try {
        if (Test-CommandAvailable -CommandName "Get-CimInstance") {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        else {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
        }

        if ($os.TotalVisibleMemorySize) {
            $totalKB = [double]$os.TotalVisibleMemorySize
            $info.TotalGB = [Math]::Round($totalKB / 1048576, 1)
            $info.IsSufficient = ($info.TotalGB -ge 3.8)  # 略低于 4GB 也放行（3.8GB+）
        }
        elseif ($os.TotalVisibleMemorySize -eq 0) {
            Write-Log "WARN" "TotalVisibleMemorySize 为 0，可能为虚拟机或异常环境"
            $info.TotalGB = 0
            $info.IsSufficient = $false
        }
    }
    catch {
        Write-Log "ERROR" "获取内存信息失败: $_"
        $info.IsSufficient = $false
    }

    Write-Log "DEBUG" "物理内存: $($info.TotalGB) GB, 满足最低要求: $($info.IsSufficient)"
    return $info
}

function Get-WslUbuntuVersionInfo {
    <#
    .SYNOPSIS
        检测 WSL Ubuntu 版本（仅 WSL 流程或诊断使用）
    .RETURNS
        包含 Exists, Version, IsUbuntu, IsSupported, ErrorMessage 的哈希表
    #>
    $info = @{
        Exists        = $false
        Version       = ""
        IsUbuntu      = $false
        IsSupported   = $false
        ErrorMessage  = ""
    }

    $ubuntuInfo = Test-UbuntuInWsl
    if (-not $ubuntuInfo.Exists) {
        $info.ErrorMessage = "WSL 中未检测到 Ubuntu 发行版"
        return $info
    }

    $info.Exists = $true

    try {
        # 获取 Ubuntu 版本号
        $distroName = ($ubuntuInfo | Where-Object { $_ -is [string] -and $_ -match "Ubuntu" })
        # 从 WSL 发行版列表中获取 Ubuntu 发行版名称
        $wslInfo = Test-WslInstalled
        $ubuntuDistroName = $null
        foreach ($distro in $wslInfo.Distributions) {
            if ($distro.Name -match "Ubuntu") {
                $ubuntuDistroName = $distro.Name
                break
            }
        }

        if (-not $ubuntuDistroName) {
            $info.ErrorMessage = "无法确定 Ubuntu 发行版名称"
            return $info
        }

        # 使用 wsl 获取 Ubuntu 版本
        $versionResult = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "-d", $ubuntuDistroName, "bash", "-c",
            "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2"
        ) -TimeoutSec 8

        if ($versionResult.Success) {
            $distroId = $versionResult.Output.Trim().ToLower()
            if ($distroId -eq "ubuntu") {
                $info.IsUbuntu = $true
            }
            else {
                $info.ErrorMessage = "检测到的发行版不是 Ubuntu: $distroId"
                return $info
            }
        }

        # 获取版本号
        $verResult = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "-d", $ubuntuDistroName, "bash", "-c",
            "lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2"
        ) -TimeoutSec 8

        if ($verResult.Success) {
            $version = $verResult.Output.Trim()
            $info.Version = $version

            try {
                $verNum = [double]$version
                if ($verNum -ge 20.04) {
                    $info.IsSupported = $true
                }
                else {
                    $info.ErrorMessage = "Ubuntu 版本 $version 低于最低要求 20.04"
                }
            }
            catch {
                $info.ErrorMessage = "无法解析 Ubuntu 版本号: $version"
            }
        }
        else {
            $info.ErrorMessage = "无法获取 Ubuntu 版本信息"
        }
    }
    catch {
        $info.ErrorMessage = "获取 WSL Ubuntu 版本信息失败: $_"
        Write-Log "ERROR" "获取 WSL Ubuntu 版本失败: $_"
    }

    Write-Log "DEBUG" "WSL Ubuntu: Exists=$($info.Exists), Version=$($info.Version), IsSupported=$($info.IsSupported)"
    return $info
}

function Test-MinimumRequirements {
    <#
    .SYNOPSIS
        聚合所有最低系统要求检测
    .RETURNS
        包含 IsSupported, Errors, Warnings, Details 的哈希表
    #>
    $result = @{
        IsSupported = $true
        Errors      = [System.Collections.ArrayList]::new()
        Warnings    = [System.Collections.ArrayList]::new()
        Details     = @{}
    }

    # 1. Windows 版本
    $winInfo = Get-WindowsVersionInfo
    $result.Details["Windows"] = $winInfo
    if (-not $winInfo.IsSupported) {
        $result.IsSupported = $false
        $winBuild = $winInfo.Build
        [void]$result.Errors.Add("Windows 版本不满足最低要求。需要 Windows 10 1809+ (Build >= 17763) 或 Windows 11。当前: $($winInfo.Version) (Build $winBuild)")
    }

    # 2. 系统架构
    $archInfo = Get-SystemArchitectureInfo
    $result.Details["Architecture"] = $archInfo
    if (-not $archInfo.IsSupported) {
        $result.IsSupported = $false
        [void]$result.Errors.Add("系统架构不支持。需要 x64 或 ARM64。当前: $($archInfo.Architecture)")
    }

    # 3. 物理内存
    $memInfo = Get-MemoryInfo
    $result.Details["Memory"] = $memInfo
    if (-not $memInfo.IsSufficient) {
        $result.IsSupported = $false
        [void]$result.Errors.Add("物理内存不足。需要 4GB 以上。当前: $($memInfo.TotalGB) GB")
    }

    # 4. PowerShell 版本
    $psInfo = Get-PowerShellVersionInfo
    $result.Details["PowerShell"] = $psInfo
    if (-not $psInfo.IsSupported) {
        $result.IsSupported = $false
        [void]$result.Errors.Add("PowerShell 版本过低。需要 5.1+。当前: $($psInfo.Version)")
    }

    Write-Log "INFO" "最低要求检测: IsSupported=$($result.IsSupported), Errors=$($result.Errors.Count), Warnings=$($result.Warnings.Count)"
    return $result
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        检测当前是否以管理员权限运行
    #>
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Log "DEBUG" "管理员权限检测跳过: $($_.Exception.Message)"
        return $false
    }
}

function Get-ExecutionPolicyInfo {
    <#
    .SYNOPSIS
        获取当前 PowerShell 执行策略
    #>
    try {
        return Get-ExecutionPolicy -Scope CurrentUser -ErrorAction Stop
    }
    catch {
        try {
            return Get-ExecutionPolicy -Scope Process -ErrorAction Stop
        }
        catch {
            return "Unknown"
        }
    }
}

# ============================================================
# 命令检测
# ============================================================

function Test-GitInstalled {
    <#
    .SYNOPSIS
        检测 Git 是否安装并返回版本
    #>
    $result = Invoke-CommandSafe -Command "git" -Arguments @("--version") -TimeoutSec 5
    if ($result.Success) {
        return $result.Output.Trim()
    }
    return $null
}

function Test-CodeInstalled {
    <#
    .SYNOPSIS
        检测 VS Code (code 命令) 是否可用
    #>
    $result = Invoke-CommandSafe -Command "code" -Arguments @("--version") -TimeoutSec 5
    if ($result.Success) {
        return $result.Output.Trim()
    }
    return $null
}

function Test-VSCodeExtensionInstalled {
    <#
    .SYNOPSIS
        检测 Claude Code VS Code 扩展是否安装
    #>
    $codeResult = Invoke-CommandSafe -Command "code" -Arguments @("--list-extensions") -TimeoutSec 8
    if (-not $codeResult.Success) {
        return $false
    }
    return ($codeResult.Output -match "claude-code")
}

function Test-WslInstalled {
    <#
    .SYNOPSIS
        检测 WSL 是否可用
    .RETURNS
        包含 Installed, Version, Distributions 的哈希表
    #>
    $info = @{
        Installed      = $false
        Version        = $null
        Distributions  = @()
    }

    $result = Invoke-CommandSafe -Command "wsl" -Arguments @("--version") -TimeoutSec 8
    if ($result.Success) {
        $info.Installed = $true
        $info.Version = ($result.Output -replace "`0", "").Trim()
    }

    # 获取发行版列表
    $listResult = Invoke-CommandSafe -Command "wsl" -Arguments @("-l", "-v") -TimeoutSec 8
    if ($listResult.Success) {
        $info.Installed = $true
        if (-not $info.Version) {
            $info.Version = "已安装（旧版 WSL 不支持 --version）"
        }

        $cleanOutput = $listResult.Output -replace "`0", ""
        $lines = $cleanOutput -split "`n" | Where-Object { $_ -match '\S' }
        $headerSkipped = $false
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            # 跳过标题行: "NAME      STATE           VERSION" 或 Windows 语言版本
            if (-not $headerSkipped) {
                if ($trimmed -match '^\s*\*?\s*(NAME|名称)\s+') {
                    $headerSkipped = $true
                    continue
                }
                $headerSkipped = $true
            }
            # 跳过空行和纯分隔线
            if ($trimmed -match '^\*?\s*$') {
                continue
            }
            # 匹配发行版名称: "* Ubuntu-22.04    Running    2"
            if ($trimmed -match '^\s*\*?\s*(\S+)\s+(Running|Stopped|正在运行|已停止)\s+(\d+)') {
                $state = $Matches[2]
                $distro = @{
                    Name    = $Matches[1]
                    Running = ($state -eq "Running" -or $state -eq "正在运行")
                    Default = ($trimmed -match '^\s*\*')
                    Version = $Matches[3]
                }
                $info.Distributions += $distro
            }
        }
    }

    return $info
}

function Test-UbuntuInWsl {
    <#
    .SYNOPSIS
        检测 WSL 中是否存在 Ubuntu 发行版
    .RETURNS
        包含 Exists, Running, Default 的哈希表
    #>
    $wslInfo = Test-WslInstalled
    $result = @{
        Exists  = $false
        Running = $false
        Default = $false
    }

    if (-not $wslInfo.Installed) {
        return $result
    }

    foreach ($distro in $wslInfo.Distributions) {
        if ($distro.Name -match "Ubuntu") {
            $result.Exists = $true
            $result.Running = $distro.Running
            $result.Default = $distro.Default
            break
        }
    }

    return $result
}

function Test-ClaudeInstalled {
    <#
    .SYNOPSIS
        检测 Claude Code CLI 是否安装
    .RETURNS
        版本字符串，未安装返回 $null
    #>
    $result = Invoke-CommandSafe -Command "claude" -Arguments @("--version") -TimeoutSec 5
    if ($result.Success) {
        return $result.Output.Trim()
    }
    return $null
}

# ============================================================
# Node.js 检测
# ============================================================

function Test-NodeJsInstalled {
    <#
    .SYNOPSIS
        检测 Node.js 是否安装且版本 >= 18
    .RETURNS
        包含 Installed, Version, MajorVersion, IsSupported, ErrorMessage 的哈希表
    #>
    $result = @{
        Installed     = $false
        Version       = $null
        MajorVersion  = 0
        IsSupported   = $false
        ErrorMessage  = ""
    }

    # 检测 node 命令
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        $result.ErrorMessage = "未检测到 Node.js。Claude Code 需要 Node.js 18 或更高版本，请先安装 Node.js LTS 后重新运行。"
        return $result
    }

    # 获取版本
    $nodeResult = Invoke-CommandSafe -Command "node" -Arguments @("--version") -TimeoutSec 5
    if (-not $nodeResult.Success) {
        $result.ErrorMessage = "无法获取 Node.js 版本信息。"
        return $result
    }

    $rawVersion = $nodeResult.Output.Trim()
    $result.Version = $rawVersion
    $result.Installed = $true

    # 解析主版本号
    try {
        $cleanVersion = $rawVersion -replace '^v', ''
        $major = [int]($cleanVersion.Split('.')[0])
        $result.MajorVersion = $major
        if ($major -ge 18) {
            $result.IsSupported = $true
        }
        else {
            $result.ErrorMessage = "当前 Node.js 版本为 $rawVersion，Claude Code 需要 v18 或更高版本。请升级 Node.js 后重试。"
        }
    }
    catch {
        $result.ErrorMessage = "无法解析 Node.js 版本: $rawVersion"
    }

    return $result
}

function Test-NpmInstalled {
    <#
    .SYNOPSIS
        检测 npm 是否可用。
        注意区分以下状态:
          - Node 未安装 / 版本过低
          - npm 未安装（Node 存在但 npm 缺失）
          - npm 可用
    .RETURNS
        包含 Installed, Version, Status, ErrorMessage 的哈希表
        Status: ok | failed_missing_node | failed_node_too_old | failed_missing_npm | failed_npm_broken
    #>
    $result = @{
        Installed    = $false
        Version      = $null
        Status       = ""
        ErrorMessage = ""
    }

    # 先检测 Node.js 是否存在
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        $result.Status = "failed_missing_node"
        $result.ErrorMessage = "Node.js 未安装，npm 是 Node.js 的一部分，需要先安装 Node.js。"
        return $result
    }

    # 检测 Node.js 版本
    $nodeResult = Invoke-CommandSafe -Command "node" -Arguments @("--version") -TimeoutSec 5
    if ($nodeResult.Success) {
        $rawVersion = $nodeResult.Output.Trim()
        try {
            $clean = $rawVersion -replace '^v', ''
            $major = [int]($clean.Split('.')[0])
            if ($major -lt 18) {
                $result.Status = "failed_node_too_old"
                $result.ErrorMessage = "Node.js 版本 $rawVersion 低于 v18，npm 可能也不可用。请升级 Node.js LTS。"
                return $result
            }
        }
        catch {
            # 无法解析版本，继续检测 npm
        }
    }

    # 检测 npm 命令
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd) {
        $result.Status = "failed_missing_npm"
        $result.ErrorMessage = "检测到 Node.js 存在，但 npm 不可用。这通常表示 Node.js 安装不完整，或当前终端 PATH 未刷新。请先关闭此窗口重新打开后再试。如果仍失败，请重新安装 Node.js LTS。"
        return $result
    }

    $npmResult = Invoke-CommandSafe -Command "npm" -Arguments @("--version") -TimeoutSec 5
    if ($npmResult.Success) {
        $result.Version = $npmResult.Output.Trim()
        $result.Installed = $true
        $result.Status = "ok"
    }
    else {
        $result.Status = "failed_npm_broken"
        $result.ErrorMessage = "npm 命令存在但无法执行（执行 --version 失败），环境可能异常。请检查 Node.js 安装是否完整。"
    }

    return $result
}

# ============================================================
# 文件检测
# ============================================================

function Test-ClaudeConfigExists {
    <#
    .SYNOPSIS
        检测 Windows 下 Claude Code 配置文件是否存在
    .RETURNS
        包含 Exists, Path, IsValid 的哈希表
    #>
    $configPath = Get-ClaudeConfigFile
    $result = @{
        Exists   = $false
        Path     = $configPath
        IsValid  = $false
        HasEnv   = $false
        EnvCount = 0
    }

    if (Test-Path $configPath) {
        $result.Exists = $true
        $json = Read-JsonFileSafe -FilePath $configPath
        if ($null -ne $json) {
            $result.IsValid = $true
            if (($json.PSObject.Properties.Name -contains "env") -and $null -ne $json.env) {
                $result.HasEnv = $true
                $result.EnvCount = ($json.env.PSObject.Properties | Measure-Object).Count
            }
        }
    }

    return $result
}

function Test-ClaudeConfigDir {
    <#
    .SYNOPSIS
        检测 Claude Code 配置目录是否存在
    #>
    $dir = Get-ClaudeConfigDir
    return Test-Path $dir
}

# ============================================================
# 网络检测
# ============================================================

function Test-NetworkConnectivity {
    <#
    .SYNOPSIS
        检测对指定 URL 的网络连通性
    .PARAMETER Url
        要检测的 URL
    .PARAMETER TimeoutSec
        超时秒数
    .RETURNS
        包含 Reachable, StatusCode, LatencyMs, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSec = 10
    )

    $result = @{
        Reachable  = $false
        StatusCode = 0
        LatencyMs  = 0
        Error      = ""
    }

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing `
            -ErrorAction Stop -MaximumRedirection 3
        $sw.Stop()

        $result.Reachable = $true
        $result.StatusCode = [int]$response.StatusCode
        $result.LatencyMs = $sw.ElapsedMilliseconds
    }
    catch {
        $sw.Stop()
        $result.LatencyMs = $sw.ElapsedMilliseconds

        if ($_.Exception -is [System.Net.WebException]) {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $result.StatusCode = [int]$webEx.Response.StatusCode
                $result.Reachable = $true  # 服务器有响应，即使返回错误
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

function Test-DeepSeekApiAnthropic {
    <#
    .SYNOPSIS
        使用 Anthropic Format 接口测试 DeepSeek API 连接。
        这是真正的 smoke test — 验证 Claude Code 能通过
        DeepSeek Anthropic 兼容层正常工作。
    .PARAMETER ApiKey
        DeepSeek API Key
    .PARAMETER BaseUrl
        Anthropic Base URL，默认 https://api.deepseek.com/anthropic
    .PARAMETER Model
        测试用的模型名，默认 deepseek-v4-flash（快速模型，响应快）
    .RETURNS
        包含 Success, StatusCode, Content, Error, Suggestion 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [string]$BaseUrl = "https://api.deepseek.com/anthropic",
        [string]$Model = "deepseek-v4-flash"
    )

    $result = @{
        Success    = $false
        StatusCode = 0
        Content    = ""
        Error      = ""
        Suggestion = ""
    }

    # 先检测 Key 格式
    if (-not (Is-ApiKeyFormatValid -Key $ApiKey)) {
        $result.Error = "API Key 格式不正确"
        $result.Suggestion = "请确认您的 DeepSeek API Key 格式正确。通常以 sk- 开头。"
        return $result
    }

    if ($env:CCDI_TEST_MODE -eq "1" -and -not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_API_STATUS)) {
        $mockStatus = $env:CCDI_TEST_API_STATUS.Trim().ToLowerInvariant()
        Write-Log "DEBUG" "CCDI_TEST_API_STATUS mock: $mockStatus"

        switch ($mockStatus) {
            "200" {
                $result.Success = $true
                $result.StatusCode = 200
                $result.Content = "OK"
            }
            "401" {
                $result.StatusCode = 401
                $result.Error = "API Key 验证失败 (401 Unauthorized)"
                $result.Suggestion = "DeepSeek API Key 验证失败。请检查是否复制完整、是否有多余空格、是否已删除或无权限。到 platform.deepseek.com 重新获取。"
            }
            "402" {
                $result.StatusCode = 402
                $result.Error = "账户余额或计费异常 (402 Payment Required)"
                $result.Suggestion = "API Key 可识别，但账户余额或计费状态可能异常，请到 DeepSeek 控制台检查余额。"
            }
            "403" {
                $result.StatusCode = 403
                $result.Error = "API Key 无权限 (403 Forbidden)"
                $result.Suggestion = "请检查 API Key 是否有对应接口的访问权限。"
            }
            "404" {
                $result.StatusCode = 404
                $result.Error = "接口或模型未找到 (404 Not Found)"
                $result.Suggestion = "endpoint 或模型名可能错误。请检查 DeepSeek 官方文档确认当前支持的模型名。当前使用: $Model。"
            }
            "429" {
                $result.StatusCode = 429
                $result.Error = "API 请求频率限制 (429 Too Many Requests)"
                $result.Suggestion = "请求过于频繁，请稍等几分钟再试。"
            }
            "500" {
                $result.StatusCode = 500
                $result.Error = "DeepSeek 服务端错误 (500 Internal Server Error)"
                $result.Suggestion = "DeepSeek 官方服务暂时异常，请稍后重试。这不是您的配置问题。"
            }
            "502" {
                $result.StatusCode = 502
                $result.Error = "DeepSeek 网关错误 (502 Bad Gateway)"
                $result.Suggestion = "DeepSeek 官方服务暂时不可用，请稍后重试。这不是您的配置问题。"
            }
            "503" {
                $result.StatusCode = 503
                $result.Error = "DeepSeek 服务暂不可用 (503 Service Unavailable)"
                $result.Suggestion = "DeepSeek 官方正在维护或过载，请稍后重试。这不是您的配置问题。"
            }
            "timeout" {
                $result.Error = "网络连接失败: 连接超时"
                $result.Suggestion = "连接超时。可能是 DNS、代理、网络环境或防火墙问题。"
            }
            "dns" {
                $result.Error = "网络连接失败: DNS 解析失败"
                $result.Suggestion = "DNS 解析失败。请检查网络/DNS 设置。"
            }
            default {
                $result.Error = "未知测试状态: $mockStatus"
                $result.Suggestion = "请检查 CCDI_TEST_API_STATUS 测试环境变量。"
            }
        }

        return $result
    }

    try {
        $messagesEndpoint = "$BaseUrl/messages"

        # 构建 Anthropic Format 请求体
        $requestBody = @{
            model      = $Model
            max_tokens = 64
            messages   = @(
                @{
                    role    = "user"
                    content = "Reply OK only."
                }
            )
        } | ConvertTo-Json -Depth 5

        $headers = @{
            "x-api-key"          = $ApiKey
            "Authorization"      = "Bearer $ApiKey"
            "Content-Type"       = "application/json"
            "anthropic-version"  = "2023-06-01"
        }

        Write-Log "DEBUG" "Anthropic Format API test: POST $messagesEndpoint (model=$Model)"

        $response = Invoke-RestMethod -Uri $messagesEndpoint -Headers $headers `
            -Method Post -Body $requestBody -TimeoutSec 30 -ErrorAction Stop

        $result.StatusCode = 200

        # 解析 Anthropic Format 响应。不能直接访问不存在的属性；
        # StrictMode 下缺失属性会抛异常，导致 API 错误无法正常归类。
        $responseProps = @(Get-CcdiObjectPropertyNamesSafe -Object $response)
        if ($responseProps -contains "content") {
            $contentItems = @($response.content)
            foreach ($item in $contentItems) {
                $itemProps = @(Get-CcdiObjectPropertyNamesSafe -Object $item)
                if ($itemProps -contains "text" -and -not [string]::IsNullOrWhiteSpace($item.text)) {
                    $result.Content = $item.text
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($result.Content) -and $contentItems.Count -gt 0) {
                $result.Content = $contentItems[0].ToString()
            }
        }
        elseif ($responseProps -contains "choices") {
            # OpenAI 兼容格式回退
            $result.Content = $response.choices[0].message.content
        }

        if (-not [string]::IsNullOrWhiteSpace($result.Content)) {
            $result.Success = $true
        }
        else {
            $result.Error = "API 返回成功但无法解析响应内容"
            $result.Suggestion = "接口返回格式异常，可能是模型或接口版本不匹配。"
        }
    }
    catch {
        $exception = $_.Exception
        $exceptionProps = @(Get-CcdiObjectPropertyNamesSafe -Object $exception)
        $exceptionResponse = $null
        if ($exceptionProps -contains "Response") {
            $exceptionResponse = $exception.Response
        }

        if ($null -ne $exceptionResponse) {
            $responseProps = @(Get-CcdiObjectPropertyNamesSafe -Object $exceptionResponse)
            if ($responseProps -contains "StatusCode") {
                $statusCode = [int]$exceptionResponse.StatusCode
            }
            else {
                $statusCode = 0
            }
            $result.StatusCode = $statusCode

            switch ($statusCode) {
                401 {
                    $result.Error = "API Key 验证失败 (401 Unauthorized)"
                    $result.Suggestion = "DeepSeek API Key 验证失败。请检查是否复制完整、是否有多余空格、是否已删除或无权限。到 platform.deepseek.com 重新获取。"
                }
                402 {
                    $result.Error = "账户余额或计费异常 (402 Payment Required)"
                    $result.Suggestion = "API Key 可识别，但账户余额或计费状态可能异常，请到 DeepSeek 控制台检查余额。"
                }
                403 {
                    $result.Error = "API Key 无权限 (403 Forbidden)"
                    $result.Suggestion = "请检查 API Key 是否有对应接口的访问权限。"
                }
                404 {
                    $result.Error = "接口或模型未找到 (404 Not Found)"
                    $result.Suggestion = "endpoint 或模型名可能错误。请检查 DeepSeek 官方文档确认当前支持的模型名。当前使用: $Model。"
                }
                429 {
                    $result.Error = "API 请求频率限制 (429 Too Many Requests)"
                    $result.Suggestion = "请求过于频繁，请稍等几分钟再试。"
                }
                500 {
                    $result.Error = "DeepSeek 服务端错误 (500 Internal Server Error)"
                    $result.Suggestion = "DeepSeek 官方服务暂时异常，请稍后重试。这不是您的配置问题。"
                }
                502 {
                    $result.Error = "DeepSeek 网关错误 (502 Bad Gateway)"
                    $result.Suggestion = "DeepSeek 官方服务暂时不可用，请稍后重试。这不是您的配置问题。"
                }
                503 {
                    $result.Error = "DeepSeek 服务暂不可用 (503 Service Unavailable)"
                    $result.Suggestion = "DeepSeek 官方正在维护或过载，请稍后重试。这不是您的配置问题。"
                }
                default {
                    $result.Error = if ($statusCode -gt 0) { "HTTP $statusCode" } else { "HTTP 请求失败" }
                    $result.Suggestion = "未知错误，请运行 doctor.ps1 获取诊断报告。"
                }
            }
        }
        else {
            $result.Error = "网络连接失败: $($_.Exception.Message)"
            if ($_.Exception.Message -match "timeout|超时") {
                $result.Suggestion = "连接超时。可能是 DNS、代理、网络环境或防火墙问题。"
            }
            elseif ($_.Exception.Message -match "DNS|resolve|解析") {
                $result.Suggestion = "DNS 解析失败。请检查网络/DNS 设置。"
            }
            else {
                $result.Suggestion = "无法连接 api.deepseek.com，可能是 DNS、代理、网络环境或防火墙问题。"
            }
        }
    }

    return $result
}

# ============================================================
# 综合检测
# ============================================================

function Get-FullEnvironmentReport {
    <#
    .SYNOPSIS
        获取完整环境报告（所有检测项的综合结果）
    .RETURNS
        包含所有检测结果的哈希表
    #>
    $report = @{
        Timestamp          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Windows            = Get-WindowsVersionInfo
        Architecture       = Get-SystemArchitectureInfo
        Memory             = Get-MemoryInfo
        PowerShell         = Get-PowerShellVersionInfo
        IsAdmin            = Test-IsAdministrator
        ExecutionPolicy    = Get-ExecutionPolicyInfo
        UserProfile        = Get-UserProfilePath
        Git                = Test-GitInstalled
        VSCode             = Test-CodeInstalled
        WSL                = Test-WslInstalled
        Ubuntu             = Test-UbuntuInWsl
        ClaudeInstalled    = Test-ClaudeInstalled
        ClaudeConfig       = Test-ClaudeConfigExists
        ClaudeConfigDir    = Test-ClaudeConfigDir
        NetworkDeepSeek    = $null  # 延迟检测，需要 URL
    }

    return $report
}
