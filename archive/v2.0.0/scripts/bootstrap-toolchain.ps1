#requires -version 5.1
<#
.SYNOPSIS
    拉取构建 PluginManager 所需的工具链到 E:\DataBackup\toolchain。

.DESCRIPTION
    全部下载到本地目录，不装系统组件、不需要管理员权限：
      zig          pip 的 ziglang wheel（提供 zig cc）
      llvm-mingw   提供 ld.lld（-flavor darwin 链接 Mach-O）
      iPhoneOS SDK  theos/sdks 的 iPhoneOS16.5.sdk
      zsign        ad-hoc 签名 + entitlements 注入

    可重复执行；已存在的文件会跳过。

.EXAMPLE
    .\scripts\bootstrap-toolchain.ps1
    .\scripts\bootstrap-toolchain.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$ToolchainRoot = "E:\DataBackup\toolchain",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Write-Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Fail($t) { Write-Host "[ERROR] $t" -ForegroundColor Red; exit 1 }

$dl = Join-Path $ToolchainRoot "dl"
foreach ($d in @($ToolchainRoot, $dl)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ---------- 分片下载器（GitHub 直连慢，用多线程 range 并行）----------
$pget = Join-Path $ToolchainRoot "pget.py"
if (-not (Test-Path $pget)) { Fail "缺少分片下载器 $pget" }

function Invoke-Download {
    param([string]$Url, [string]$Dest, [int]$Threads = 8)
    if ((Test-Path $Dest) -and -not $Force) {
        Write-Note ("已存在，跳过: " + (Split-Path -Leaf $Dest));
        return
    }
    Write-Note ("下载 " + $Url);
    python $pget $Url $Dest $Threads
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Dest)) { Fail ("下载失败: " + $Url) }
    Write-Ok ((Split-Path -Leaf $Dest) + "  " + [math]::Round((Get-Item $Dest).Length / 1MB, 1) + " MB")
}

# ---------- 1. zig ----------
Write-Step "zig（Apple 目标编译前端）"
$zigExe = Join-Path $ToolchainRoot "zigpy\ziglang\zig.exe"
if ($Force -or -not (Test-Path $zigExe)) {
    $wheel = Join-Path $dl "zig.whl"
    Invoke-Download -Url "https://files.pythonhosted.org/packages/c8/6c/2013114fa780f0cf490cdc98bdd5bf7dce706a5dbd86e50ec4132cf7d4b1/ziglang-0.17.1-py3-none-win_amd64.whl" -Dest $wheel -Threads 8
    $zigPy = Join-Path $ToolchainRoot "zigpy"
    if (Test-Path $zigPy) { Remove-Item -Recurse -Force $zigPy }
    python -c "import zipfile;zipfile.ZipFile(r'$wheel').extractall(r'$zigPy')"
    if ($LASTEXITCODE -ne 0) { Fail "解压 zig wheel 失败" }
}
if (Test-Path $zigExe) { Write-Ok ("zig " + (& $zigExe version)) } else { Fail "zig 未就绪" }

# ---------- 2. llvm-mingw（ld.lld）----------
Write-Step "ld.lld（Mach-O 链接器）"
$lldFound = Get-ChildItem -Path (Join-Path $ToolchainRoot "mingw") -Filter "ld.lld.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($Force -or -not $lldFound) {
    $zip = Join-Path $dl "llvm-mingw.zip"
    Invoke-Download -Url "https://github.com/mstorsjo/llvm-mingw/releases/download/20261117/llvm-mingw-20261117-ucrt-x86_64.zip" -Dest $zip -Threads 12
    $dest = Join-Path $ToolchainRoot "mingw"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    python -c "import zipfile;zipfile.ZipFile(r'$zip').extractall(r'$dest')"
    if ($LASTEXITCODE -ne 0) { Fail "解压 llvm-mingw 失败" }
    $lldFound = Get-ChildItem -Path $dest -Filter "ld.lld.exe" -Recurse | Select-Object -First 1
}
if (-not $lldFound) { Fail "未找到 ld.lld.exe" }
Write-Ok ("ld.lld " + $lldFound.FullName)

# ---------- 3. iPhoneOS SDK ----------
Write-Step "iPhoneOS16.5.sdk"
$sdkDir = Join-Path $ToolchainRoot "sdks\iPhoneOS16.5.sdk"
if ($Force -or -not (Test-Path $sdkDir)) {
    $sdkXz = Join-Path $dl "iPhoneOS16.5.sdk.tar.xz"
    Invoke-Download -Url "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz" -Dest $sdkXz -Threads 8
    python -c "import tarfile;tarfile.open(r'$sdkXz').extractall(r'" + (Join-Path $ToolchainRoot "sdks") + "')"
    if ($LASTEXITCODE -ne 0) { Fail "解压 SDK 失败" }
}
if (-not (Test-Path (Join-Path $sdkDir "System\Library\Frameworks\UIKit.framework"))) { Fail "SDK 不完整" }
Write-Ok $sdkDir

# ---------- 4. zsign ----------
Write-Step "zsign（ad-hoc 签名）"
$zsignExe = Join-Path $ToolchainRoot "zsign\zsign.exe"
if ($Force -or -not (Test-Path $zsignExe)) {
    $zsignZip = Join-Path $dl "zsign.zip"
    Invoke-Download -Url "https://github.com/zhlynn/zsign/releases/download/v1.1.3/zsign-windows-x64.zip" -Dest $zsignZip -Threads 4
    $zdest = Join-Path $ToolchainRoot "zsign"
    if (Test-Path $zdest) { Remove-Item -Recurse -Force $zdest }
    python -c "import zipfile;zipfile.ZipFile(r'$zsignZip').extractall(r'$zdest')"
    if ($LASTEXITCODE -ne 0) { Fail "解压 zsign 失败" }
}
if (Test-Path $zsignExe) { Write-Ok $zsignExe } else { Fail "zsign 未就绪" }

Write-Host ""
Write-Host "工具链就绪。下一步：powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Clean" -ForegroundColor Green
