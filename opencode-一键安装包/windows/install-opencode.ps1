# ==============================================================================
# install-opencode.ps1 — 一键安装 OpenCode 2 (Windows)
# 自动检测 Node.js，安装缺失的 Node.js，并通过镜像源安装 @opencode/cli。
# 用法: .\install-opencode.ps1 [选项]
# ==============================================================================

param(
    [switch]$ForceNodeReinstall,
    [switch]$ForceOpencodeReinstall,
    [switch]$SkipNodeCheck,
    [switch]$DryRun,
    [switch]$VerboseLog,
    [string]$Registry = 'https://registry.npmmirror.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CustomRegistry = $PSBoundParameters.ContainsKey('Registry')
if ($Registry -notmatch '^https?://[^\s]+$') { throw 'Registry 必须是 http(s) URL。' }
$Registry = $Registry.TrimEnd('/')

# ================= 编码设置（避免中文乱码）=================
# 将控制台输入/输出编码统一设为 UTF-8（代码页 65001）
try {
    # 设置控制台代码页为 UTF-8
    & chcp 65001 | Out-Null

    # 设置 PowerShell 输出/输入编码
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8

    # 设置 PowerShell 本身的输出编码（影响管道和文件写入）
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 编码设置失败不阻断主流程，静默忽略
}

# npm registry 候选列表（按优先级，最后一个为官方）
$script:NpmRegistryCandidates = @(
    'https://registry.npmmirror.com'                        # 淘宝镜像（最主流）
    'https://mirrors.huaweicloud.com/repository/npm'        # 华为云
    'https://mirrors.tencent.com/npm'                       # 腾讯云
    'https://registry.npmjs.org'                            # 官方（备用）
)
$script:NpmRegistry = ''

# ================= ASCII 路径安全检测 =================
# 检测字符串是否含非 ASCII 字符（中文、日文等）
function Test-HasNonAscii([string]$Value) {
    return [bool]($Value -match '[^\x00-\x7F]')
}

# 检测关键 Windows 路径是否含非 ASCII（中文用户名等）
function Test-NeedsAsciiSafePath {
    foreach ($val in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace($val) -and (Test-HasNonAscii $val)) {
            return $true
        }
    }
    return $false
}

# 初始化路径变量（中文路径时切换到 C:\OpenCode）
function Initialize-InstallPaths {
    $script:UseAsciiSafePath = Test-NeedsAsciiSafePath

    if ($script:UseAsciiSafePath) {
        $script:SafeRoot      = 'C:\OpenCode'
        $script:NodeInstallDir = Join-Path $script:SafeRoot 'nodejs'
        $script:NpmPrefix      = Join-Path $script:SafeRoot 'npm'
        $script:NpmCache       = Join-Path $script:SafeRoot 'npm-cache'
        $script:NpmTemp        = Join-Path $script:SafeRoot 'tmp'
        $script:ConfigDir      = Join-Path $env:USERPROFILE '.config\opencode'

        Write-WarnMsg "检测到用户路径含非 ASCII 字符（如中文用户名），已自动切换到 ASCII 安全目录。"
        Write-WarnMsg "安装根目录: $script:SafeRoot"
        Write-WarnMsg "Node.js 和 npm 安装文件将使用此目录；OpenCode 配置仍位于用户目录。"

        # 创建目录
        foreach ($dir in @($script:SafeRoot, $script:NpmPrefix, $script:NpmCache, $script:NpmTemp)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    } else {
        $script:SafeRoot       = $null
        $script:NodeInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
        $script:NpmPrefix      = Join-Path $env:LOCALAPPDATA 'Programs\opencode\npm'
        $script:NpmCache       = Join-Path $env:LOCALAPPDATA 'opencode\npm-cache'
        $script:NpmTemp        = $env:TEMP
        $script:ConfigDir      = Join-Path $env:USERPROFILE '.config\opencode'
    }
}

# ================= 日志函数 =================
function Write-Info([string]$Message)  { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-WarnMsg([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Ok([string]$Message)    { Write-Host "[OK]   $Message" -ForegroundColor Green }
function Write-Err([string]$Message)   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-DebugMsg([string]$Message) {
    if ($VerboseLog) { Write-Host "[DEBUG] $Message" -ForegroundColor DarkCyan }
}

# ================= 工具函数 =================
function Command-Exists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Find-NpmRegistry {
    if ($script:CustomRegistry) {
        $script:NpmRegistry = $Registry
        Write-Info "使用指定的 npm registry: $Registry"
        return
    }
    Write-Info "正在探测可用的 npm 镜像..."
    $timeout = 5  # 秒

    foreach ($registry in $script:NpmRegistryCandidates) {
        $isOfficial = ($registry -eq 'https://registry.npmjs.org')
        Write-Host "  测试: $registry ... " -NoNewline -ForegroundColor Gray

        try {
            $probeUrl = "$registry/@opencode%2fcli"
            $resp = Invoke-WebRequest -Uri $probeUrl -Method Head -TimeoutSec $timeout -UseBasicParsing -ErrorAction Stop
            Write-Host "可用" -ForegroundColor Green
            $script:NpmRegistry = $registry

            if ($isOfficial) {
                Write-WarnMsg "所有国内镜像均不可达，已回退到官方源: $registry"
                Write-WarnMsg "如果下载缓慢或失败，请开启代理（VPN / 系统代理）后重试。"
                Write-WarnMsg "常见代理设置（在 PowerShell 中）:"
                Write-WarnMsg "  `$env:https_proxy = 'http://127.0.0.1:7890'"
                Write-WarnMsg "  `$env:http_proxy  = 'http://127.0.0.1:7890'"
            } else {
                Write-Ok "使用镜像: $registry"
            }
            return
        } catch {
            Write-Host "不可达" -ForegroundColor Yellow
        }
    }

    # 兜底
    $script:NpmRegistry = 'https://registry.npmjs.org'
    Write-WarnMsg "所有镜像均不可达，使用官方源，建议开启代理后重试。"
}

function Get-CommandVersion([string]$Name) {
    try {
        $cmd = Get-Command $Name -ErrorAction Stop
        $path = if ($cmd.Path) { $cmd.Path } else { $cmd.Source }
        if ([string]::IsNullOrWhiteSpace($path)) { return '版本未知' }
        $output = & $path --version 2>$null | Select-Object -First 1
        return "$output".Trim()
    } catch {
        return '版本未知'
    }
}

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ================= 环境预检 =================
function Write-PreflightSummary {
    Write-Info "===== 环境预检 ====="
    Write-Info "  操作系统: Windows $([Environment]::OSVersion.VersionString)"
    Write-Info "  PowerShell: $($PSVersionTable.PSVersion)"
    Write-Info "  用户: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Info "  管理员权限: $(Test-IsAdministrator)"

    if (Command-Exists 'node') {
        Write-Info "  node: $(Get-CommandVersion 'node')"
    } else {
        Write-Info "  node: 未找到"
    }
    if (Command-Exists 'npm') {
        Write-Info "  npm: $(Get-CommandVersion 'npm')"
    } else {
        Write-Info "  npm: 未找到"
    }
    if (Command-Exists 'opencode') {
        Write-Info "  opencode: $(Get-CommandVersion 'opencode')"
    } else {
        Write-Info "  opencode: 未找到"
    }
    Write-Info "  npm registry: $Registry"
    Write-DebugMsg "  DryRun=$DryRun ForceNode=$ForceNodeReinstall ForceOpencode=$ForceOpencodeReinstall SkipNode=$SkipNodeCheck"
}

# ================= Node.js 安装 =================

# 镜像地址
$script:NodeMirrorUrl    = 'https://npmmirror.com/mirrors/node'
$script:NodeOfficialUrl  = 'https://nodejs.org/dist'

function Invoke-DownloadWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$FallbackUrl,
        [string]$OutFile,
        [string]$Label = '文件'
    )

    Write-Info "下载 $Label（优先国内镜像）: $PrimaryUrl"
    try {
        Invoke-WebRequest -Uri $PrimaryUrl -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        Write-Info "国内镜像下载成功。"
        return
    } catch {
        Write-WarnMsg "国内镜像下载失败: $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackUrl)) {
        Write-Info "回退官方地址: $FallbackUrl"
        Invoke-WebRequest -Uri $FallbackUrl -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        Write-Info "官方地址下载成功。"
    } else {
        throw "$Label 下载失败，无可用地址。"
    }
}

function Invoke-RestMethodWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$FallbackUrl,
        [string]$Label = '接口'
    )

    Write-Info "查询 $Label（优先国内镜像）: $PrimaryUrl"
    try {
        $result = Invoke-RestMethod -Uri $PrimaryUrl -ErrorAction Stop
        Write-Info "国内镜像查询成功。"
        return $result
    } catch {
        Write-WarnMsg "国内镜像查询失败: $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackUrl)) {
        Write-Info "回退官方地址: $FallbackUrl"
        $result = Invoke-RestMethod -Uri $FallbackUrl -ErrorAction Stop
        Write-Info "官方地址查询成功。"
        return $result
    } else {
        throw "$Label 查询失败，无可用地址。"
    }
}

function Get-NodeLtsInfo {
    Write-Info "正在查询 Node.js 最新 LTS 版本..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $index = Invoke-RestMethodWithFallback `
        -PrimaryUrl  "$script:NodeMirrorUrl/index.json" `
        -FallbackUrl "$script:NodeOfficialUrl/index.json" `
        -Label 'Node.js 版本列表'

    $nodeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64-zip' } else { 'win-x64-zip' }
    $lts = $index | Where-Object { $_.lts -and ($_.files -contains $nodeArch) } | Select-Object -First 1
    if (-not $lts) {
        throw "无法获取 Node.js LTS 版本信息。"
    }
    return $lts
}

function Assert-Sha256 {
    param(
        [string]$FilePath,
        [string]$Version,
        [string]$FileName
    )

    $shaMirror   = "$script:NodeMirrorUrl/$Version/SHASUMS256.txt"
    $shaOfficial = "$script:NodeOfficialUrl/$Version/SHASUMS256.txt"

    Write-Info "下载 SHA256 校验文件..."
    $tmpSha = Join-Path $env:TEMP ("opencode-sha256-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        Invoke-DownloadWithFallback -PrimaryUrl $shaMirror -FallbackUrl $shaOfficial -OutFile $tmpSha -Label 'SHA256 校验文件'
        $manifest = Get-Content -LiteralPath $tmpSha -Raw
    } finally {
        Remove-Item -LiteralPath $tmpSha -Force -ErrorAction SilentlyContinue
    }

    $expected = $null
    foreach ($line in ($manifest -split "`r?`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$' -and $Matches[2] -eq $FileName) {
            $expected = $Matches[1].ToLowerInvariant()
            break
        }
    }
    if (-not $expected) {
        throw "在校验文件中未找到 $FileName 的 SHA256。"
    }

    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA256 校验失败: 期望 $expected，实际 $actual"
    }
    Write-Ok "SHA256 校验通过: $actual"
}

function Install-NodeJs {
    Write-Info "正在安装 Node.js LTS (Windows, 用户目录，无需管理员)..."

    $lts = Get-NodeLtsInfo
    $version = $lts.version
    $nodeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
    $zipName = "node-$version-$nodeArch.zip"
    $zipMirror   = "$script:NodeMirrorUrl/$version/$zipName"
    $zipOfficial = "$script:NodeOfficialUrl/$version/$zipName"

    $tempDir = Join-Path $script:NpmTemp ("opencode-node-install-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $targetRoot = $script:NodeInstallDir

    try {
        $zipPath = Join-Path $tempDir $zipName
        Invoke-DownloadWithFallback -PrimaryUrl $zipMirror -FallbackUrl $zipOfficial -OutFile $zipPath -Label "Node.js ${version}"

        Assert-Sha256 -FilePath $zipPath -Version $version -FileName $zipName

        Write-Info "解压 Node.js..."
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

        $extractRoot = Join-Path $tempDir "node-$version-$nodeArch"
        if (-not (Test-Path -LiteralPath $extractRoot)) {
            throw "解压后未找到 Node.js 目录: $extractRoot"
        }

        # 移动到目标目录
        $parentDir = Split-Path -Parent $targetRoot
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null

        if (Test-Path -LiteralPath $targetRoot) {
            $backupPath = "$targetRoot.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Info "已有 Node.js 目录备份至: $backupPath"
            Move-Item -LiteralPath $targetRoot -Destination $backupPath -Force
        }

        Move-Item -LiteralPath $extractRoot -Destination $targetRoot -Force

        if (-not (Test-Path (Join-Path $targetRoot 'node.exe'))) {
            throw "node.exe 未在目标目录找到: $targetRoot"
        }
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 将 Node.js 目录添加到用户 PATH
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $parts = $userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $normalizedTarget = $targetRoot.Trim().TrimEnd('\')
    $alreadyIn = $parts | Where-Object { $_.Trim().TrimEnd('\') -ieq $normalizedTarget }
    if (-not $alreadyIn) {
        $newPath = ($parts + $normalizedTarget) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Info "已将 Node.js 添加到用户 PATH: $normalizedTarget"
    }

    # 更新当前进程 PATH
    $env:Path = "$targetRoot;$env:Path"

    # 添加 npm 全局 bin 目录
    $npmBin = $script:NpmPrefix
    New-Item -ItemType Directory -Path $npmBin -Force | Out-Null
    $userPath2 = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts2 = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath2)) {
        $parts2 = $userPath2 -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
    $alreadyIn2 = $parts2 | Where-Object { $_.Trim().TrimEnd('\') -ieq $npmBin.Trim().TrimEnd('\') }
    if (-not $alreadyIn2) {
        $newPath2 = ($parts2 + $npmBin) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath2, 'User')
        Write-Info "已将 npm 全局目录添加到用户 PATH: $npmBin"
    }
    $env:Path = "$env:Path;$npmBin"

    Write-Ok "Node.js $version 安装完成。"
    Write-Ok "Node.js: $(& (Join-Path $targetRoot 'node.exe') --version)"
}

function Ensure-NodeNpm {
    if ($SkipNodeCheck) {
        Write-Info "--SkipNodeCheck: 跳过 Node.js 检测。"
        return
    }

    if ((Command-Exists 'node') -and (Command-Exists 'npm')) {
        $nodeVer = Get-CommandVersion 'node'
        $npmVer  = Get-CommandVersion 'npm'
        Write-Ok "检测到 Node.js 已安装，当前版本: $nodeVer  (npm $npmVer)"

        if ($ForceNodeReinstall) {
            Write-Info "已指定强制重装，继续安装..."
        } else {
            Write-Host ""
            Write-Host "  是否重新安装 Node.js？" -ForegroundColor White
            Write-Host "  [1] 不重装，保留当前版本（推荐）" -ForegroundColor White
            Write-Host "  [2] 重新安装（覆盖当前版本）" -ForegroundColor White
            Write-Host ""

            $choice = ''
            while ($true) {
                $choice = (Read-Host "  请输入选项 [1/2]，然后按回车").Trim()
                if ($choice -eq '' -or $choice -eq '1') {
                    Write-Info "保留当前 Node.js 版本，跳过安装。"
                    return
                } elseif ($choice -eq '2') {
                    Write-Info "用户选择重新安装 Node.js..."
                    break
                } else {
                    Write-Host "  请输入 1 或 2" -ForegroundColor Yellow
                }
            }
        }
    }

    Install-NodeJs

    # 验证安装
    $nodePath = Join-Path $script:NodeInstallDir 'node.exe'
    if (-not (Test-Path $nodePath)) {
        throw "Node.js 安装后未找到 node.exe，请检查安装过程。"
    }
    Write-Ok "Node.js 安装验证成功。"
}

# ================= opencode 安装 =================

function Ensure-Opencode {
    # 检查是否已安装
    if (Command-Exists 'opencode') {
        $ver = Get-CommandVersion 'opencode'
        Write-Ok "检测到 opencode 已安装，当前版本: $ver"

        if ($ForceOpencodeReinstall) {
            Write-Info "已指定强制重装，继续安装..."
        } elseif ($ver -match '^1\.') {
            Write-Info "检测到 OpenCode 1，升级到 OpenCode 2..."
        } else {
            # 交互询问用户
            Write-Host ""
            Write-Host "  是否重新安装 opencode？" -ForegroundColor White
            Write-Host "  [1] 不重装，保留当前版本（推荐）" -ForegroundColor White
            Write-Host "  [2] 重新安装（覆盖当前版本）" -ForegroundColor White
            Write-Host ""

            $choice = ''
            while ($true) {
                $choice = (Read-Host "  请输入选项 [1/2]，然后按回车").Trim()
                if ($choice -eq '' -or $choice -eq '1') {
                    Write-Info "保留当前 opencode 版本，跳过安装。"
                    return
                } elseif ($choice -eq '2') {
                    Write-Info "用户选择重新安装 opencode..."
                    break
                } else {
                    Write-Host "  请输入 1 或 2" -ForegroundColor Yellow
                }
            }
        }
    }

    # 查找 npm
    $npmCmd = $null
    foreach ($name in @('npm.cmd', 'npm')) {
        $found = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $npmCmd = if ($found.Path) { $found.Path } else { $found.Source }
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($npmCmd)) {
        Write-Err "npm 未找到，无法安装 @opencode/cli。"
        Write-Err "请先确保 Node.js/npm 已安装，并重新打开 PowerShell 窗口后重试。"
        throw "npm 未找到"
    }

    Write-Info "正在安装 @opencode/cli..."
    # 优先使用探测到的镜像，否则使用参数传入的 registry
    $activeRegistry = if (-not [string]::IsNullOrWhiteSpace($script:NpmRegistry)) { $script:NpmRegistry } else { $Registry }
    Write-Info "registry: $activeRegistry; prefix: $script:NpmPrefix"

    $savedEA = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $npmCmd install -g --prefix $script:NpmPrefix --cache $script:NpmCache @opencode/cli --registry $activeRegistry
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEA
    }

    if ($exitCode -ne 0) {
        Write-Err "@opencode/cli 安装失败 (exit code: $exitCode)。"
        throw "npm install 失败，退出码: $exitCode"
    }

    # 优先使用本次安装的 npm 全局 bin
    $npmBin = $script:NpmPrefix
    $env:Path = "$npmBin;$env:Path"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $otherPaths = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim().TrimEnd('\') -ine $npmBin.TrimEnd('\')
    })
    [Environment]::SetEnvironmentVariable('Path', (@($npmBin) + $otherPaths) -join ';', 'User')

    $opencodePath = Join-Path $npmBin 'opencode.cmd'
    if (-not (Test-Path -LiteralPath $opencodePath)) {
        throw "安装完成但未找到 opencode.cmd；请检查 npm prefix: $npmBin"
    }
    $ver = (& $opencodePath --version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $ver) { throw 'opencode --version 验证失败。' }
    Write-Ok "opencode 安装成功: $ver"
}

# ================= opencode 配置文件 =================

function New-OpencodeConfig {
    $configDir  = $script:ConfigDir
    $configFile = Join-Path $configDir 'opencode.json'

    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath (Join-Path $configDir 'opencode.jsonc')) {
        Write-Info "保留现有 opencode.jsonc 配置。"
    } elseif (Test-Path -LiteralPath $configFile) {
        Write-Info "配置文件已存在: $configFile"
    } else {
        [System.IO.File]::WriteAllText($configFile, '{"$schema":"https://opencode.ai/config.json"}', (New-Object System.Text.UTF8Encoding $false))
        Write-Ok "配置文件已创建: $configFile"
    }
    Write-Info "可在 OpenCode 中使用 /connect 配置提供商。"
}

# ================= 主流程 =================

function Main {
    Write-Info "===== OpenCode 2 一键安装脚本 (Windows) ====="
    Write-PreflightSummary

    if ($DryRun) {
        Write-Ok "Dry run 完成，未做任何修改。"
        return
    }

    Initialize-InstallPaths
    Find-NpmRegistry
    Ensure-NodeNpm
    Ensure-Opencode
    New-OpencodeConfig

    $configFile = Join-Path $script:ConfigDir 'opencode.json'
    $jsoncFile = Join-Path $script:ConfigDir 'opencode.jsonc'
    if (Test-Path -LiteralPath $jsoncFile) { $configFile = $jsoncFile }
    Write-Host ""
    Write-Ok "===== 安装完成 ====="
    Write-Info "配置文件位置: $configFile"
    Write-Info "如果 opencode 命令不可用，请关闭并重新打开 PowerShell 窗口。"
    Write-Info "验证安装: opencode --version"
    Write-Info "启动 opencode: opencode"
}

Main
