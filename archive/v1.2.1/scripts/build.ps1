#requires -version 5.1
<#
.SYNOPSIS
    构建 PluginManager（独立 App + 特权助手）的 rootless arm64 .deb

.DESCRIPTION
    流程：编译 → 链接 → ad-hoc 签名 → 组装 layout → 打 ar/deb → 自检。
    工具链全部取自 E:\DataBackup\toolchain（无 WSL、无管理员权限要求）：
      zig cc        （ziglang，做 Apple 目标编译）
      ld.lld        （llvm-mingw 里的 LLD，-flavor darwin 做 Mach-O 链接）
      iPhoneOS16.5.sdk（theos/sdks）
      zsign.exe     （zhlynn/zsign，ad-hoc 签名 + entitlements）

.EXAMPLE
    .\scripts\build.ps1
    .\scripts\build.ps1 -Clean
#>
[CmdletBinding()]
param(
    [string]$ToolchainRoot = "E:\DataBackup\toolchain",
    [string]$ProjectRoot = "",
    [switch]$Clean,
    [switch]$SkipSign,
    [string]$MinIOS = "15.0",
    [string]$SdkVersion = "16.5"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptsDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $scriptsDir }

$layout = Join-Path $ProjectRoot 'layout'
$buildDir = Join-Path $ProjectRoot 'build'
$distDir = Join-Path $ProjectRoot 'build\dist'
$appSrc = Join-Path $ProjectRoot 'src\app'
$helperSrc = Join-Path $ProjectRoot 'src\helper'
$resDir = Join-Path $ProjectRoot 'resources'

function Write-Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Fail($t) { Write-Host ""; Write-Host "[ERROR] $t" -ForegroundColor Red; exit 1 }

# ---------- 0. 工具链 ----------
Write-Step "定位工具链"

$zig = Join-Path $ToolchainRoot 'zigpy\ziglang\zig.exe'
if (-not (Test-Path $zig)) { Fail "未找到 zig: $zig（先运行 scripts\bootstrap-toolchain.ps1）" }
Write-Ok "zig      $zig"

$lld = Get-ChildItem -Path (Join-Path $ToolchainRoot 'mingw') -Filter 'ld.lld.exe' -Recurse -ErrorAction SilentlyContinue |
       Select-Object -First 1 -ExpandProperty FullName
if (-not $lld) { Fail "未找到 ld.lld.exe（来自 llvm-mingw），先运行 bootstrap-toolchain.ps1" }
& $lld --version | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "ld.lld 无法运行：$lld" }
Write-Ok "ld.lld   $lld"

$sdk = Join-Path $ToolchainRoot "sdks\iPhoneOS$SdkVersion.sdk"
if (-not (Test-Path $sdk)) { Fail "未找到 SDK: $sdk" }
Write-Ok "sdk      $sdk"

$zsign = Join-Path $ToolchainRoot 'zsign\zsign.exe'
if (-not $SkipSign -and -not (Test-Path $zsign)) { Fail "未找到 zsign: $zsign" }
if (-not $SkipSign) { Write-Ok "zsign    $zsign" }

$sdkInclude = Join-Path $sdk 'usr\include'
$sdkObjc = Join-Path $sdk 'usr\include\objc'
$sdkLib = Join-Path $sdk 'usr\lib'
$sdkFrameworks = Join-Path $sdk 'System\Library\Frameworks'

# ---------- 1. 清理 ----------
if ($Clean) {
    Write-Step "清理 build/ 与 layout/"
    foreach ($d in @($buildDir, $layout)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
}
$objDir = Join-Path $buildDir 'obj'
foreach ($d in @($objDir, $distDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ---------- 2. 编译 ----------
function Compile-Sources {
    param([string]$SourceDir, [string[]]$ExtraIncludes, [string]$Prefix)
    $compiled = @()
    $sources = Get-ChildItem -Path $SourceDir | Where-Object { $_.Extension -in @('.m', '.c') } | Sort-Object Name
    if ($sources.Count -eq 0) { Fail "$SourceDir 下没有 .m/.c 文件" }
    foreach ($src in $sources) {
        $obj = Join-Path $objDir ($Prefix + $src.BaseName + '.o')
        $argv = @(
            'cc', '-target', "aarch64-ios.$MinIOS", '-O2', '-fobjc-arc',
            '-Wno-everything', '-fvisibility=hidden',
            '-I', $sdkInclude, '-I', $sdkObjc, '-F', $sdkFrameworks
        ) + $ExtraIncludes + @('-c', $src.FullName, '-o', $obj)
        $log = & $zig @argv 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $obj)) {
            $log | Select-Object -First 12 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            Fail "编译失败：$($src.Name)"
        }
        Write-Note "$($src.Name) -> $(Split-Path -Leaf $obj)"
        $compiled += $obj
    }
    return $compiled
}

function Link-Objects {
    param([string[]]$Objects, [string[]]$Frameworks, [string]$Output)
    $argv = @(
        '-flavor', 'darwin',
        '-arch', 'arm64',
        '-platform_version', 'ios', $MinIOS, $SdkVersion,
        '-syslibroot', $sdk,
        '-o', $Output,
        '-L', $sdkLib,
        '-F', $sdkFrameworks
    )
    foreach ($fw in $Frameworks) { $argv += @('-framework', $fw) }
    $argv += @('-lSystem', '-lobjc', '-dead_strip')
    $argv += $Objects
    $log = & $lld @argv 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Output)) {
        $log | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        Fail "链接失败：$Output"
    }
    return (Get-Item $Output).Length
}

Write-Step "编译 App"
$appObjs = Compile-Sources -SourceDir $appSrc -ExtraIncludes @('-I', $appSrc) -Prefix 'app_'
Write-Ok "$($appObjs.Count) 个目标文件"

$appBin = Join-Path $buildDir 'PluginManager'
$size = Link-Objects -Objects $appObjs -Frameworks @('UIKit','Foundation','CoreGraphics','QuartzCore') -Output $appBin
Write-Ok "PluginManager  $size bytes"

Write-Step "编译特权助手"
$helperObjs = Compile-Sources -SourceDir $helperSrc -ExtraIncludes @('-I', $helperSrc) -Prefix 'h_'
Write-Ok "$($helperObjs.Count) 个目标文件"

$helperBin = Join-Path $buildDir 'pmhelper'
$size = Link-Objects -Objects $helperObjs -Frameworks @('Foundation') -Output $helperBin
Write-Ok "pmhelper       $size bytes"

# ---------- 3. 签名 ----------
if (-not $SkipSign) {
    Write-Step "ad-hoc 签名 + entitlements"
    & $zsign -a -f -e (Join-Path $resDir 'entitlements-helper.plist') $helperBin *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "签名 pmhelper 失败" }
    Write-Ok "pmhelper 已签名"
    & $zsign -a -f -e (Join-Path $resDir 'entitlements-app.plist') $appBin *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "签名 PluginManager 失败" }
    Write-Ok "PluginManager 已签名"
} else {
    Write-Note "已跳过签名"
}

# ---------- 4. layout ----------
Write-Step "组装 layout"
$appBundle = Join-Path $layout 'var\jb\Applications\PluginManager.app'
$helperDest = Join-Path $layout 'var\jb\usr\libexec\pluginmanager'
New-Item -ItemType Directory -Force -Path $appBundle, $helperDest | Out-Null

Copy-Item $appBin (Join-Path $appBundle 'PluginManager') -Force
Copy-Item (Join-Path $resDir 'Info.plist') (Join-Path $appBundle 'Info.plist') -Force
Get-ChildItem (Join-Path $resDir 'icons') -Filter '*.png' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $appBundle $_.Name) -Force
}
Copy-Item $helperBin (Join-Path $helperDest 'pmhelper') -Force
Write-Ok "layout/ 就绪"
Get-ChildItem -Recurse $layout -File | ForEach-Object {
    Write-Note ($_.FullName.Substring($layout.Length + 1))
}

# ---------- 5. 打 deb ----------
Write-Step "打包 .deb"
$version = (Get-Content (Join-Path $ProjectRoot 'VERSION') -Raw).Trim()
$controlSrc = Join-Path $resDir 'control'
foreach ($s in @('postinst','prerm','postrm')) {
    Copy-Item (Join-Path $resDir $s) (Join-Path $buildDir $s) -Force
}

$debName = "com.yg.pluginmanager_" + $version + "_iphoneos-arm64.deb"
$debPath = Join-Path $distDir $debName
python (Join-Path $scriptsDir 'mkdeb.py') $layout $controlSrc $debPath $version
if ($LASTEXITCODE -ne 0) { Fail "mkdeb.py 失败" }
Write-Ok ("产物 " + $debPath + "  (" + [math]::Round((Get-Item $debPath).Length/1KB,1) + " KB)")

# ---------- 6. 逻辑单测（宿主机原生运行 PMFsOps）----------
Write-Step "核心逻辑单测"
$testC = Join-Path $ProjectRoot 'tests\pmfsops_test.c'
$compatH = Join-Path $ProjectRoot 'tests\win_compat.h'
$opsC = Join-Path $ProjectRoot 'src\helper\PMFsOps.c'
if ((Test-Path $testC) -and (Test-Path $compatH)) {
    $hostClang = Get-ChildItem -Path (Join-Path $ToolchainRoot 'mingw') -Filter 'x86_64-w64-mingw32-clang.exe' -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1 -ExpandProperty FullName
    if ($hostClang) {
        $exe = Join-Path $buildDir 'pmfsops_test.exe'
        $hostArgs = @('-std=c11','-Wall','-O1',
                      '-I', (Join-Path $ProjectRoot 'src\helper'),
                      '-I', (Join-Path $ProjectRoot 'tests'),
                      '-include', $compatH,
                      $testC, $opsC, '-o', $exe)
        & $hostClang @hostArgs 2>&1 | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Fail "单测编译失败" }
        $fixture = Join-Path $buildDir 'fixture'
        New-Item -ItemType Directory -Force -Path $fixture | Out-Null
        $env:PM_TEST_ROOT = $fixture
        $testOut = & $exe 2>&1
        $testCode = $LASTEXITCODE
        $env:PM_TEST_ROOT = ''
        $testOut | Where-Object { $_ -match 'FAIL|passed' } | ForEach-Object { Write-Note $_ }
        if ($testCode -ne 0) { Fail "核心逻辑单测未通过" }
        Write-Ok "核心逻辑单测通过"

        # 进程操作单测（注销路径的正确性）
        $procTest = Join-Path $ProjectRoot 'tests\pmprocops_test.c'
        $procSrc = Join-Path $ProjectRoot 'src\helper\PMProcOps.c'
        if ((Test-Path $procTest) -and (Test-Path $procSrc)) {
            $procExe = Join-Path $buildDir 'pmprocops_test.exe'
            $procArgs = @('-std=c11','-Wall','-O1',
                          '-I', (Join-Path $ProjectRoot 'src\helper'),
                          '-I', (Join-Path $ProjectRoot 'tests'),
                          '-include', $compatH,
                          $procTest, $procSrc, '-o', $procExe)
            & $hostClang @procArgs 2>&1 | Select-Object -First 8 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $procExe)) { Fail "进程操作单测编译失败" }
            $procOut = & $procExe 2>&1
            $procCode = $LASTEXITCODE
            $procOut | Where-Object { $_ -match 'FAIL|passed' } | ForEach-Object { Write-Note $_ }
            if ($procCode -ne 0) { Fail "进程操作单测未通过" }
            Write-Ok "进程操作单测通过"
        }

        # 归档操作单测（文件管理功能的路径安全与参数校验）
        $arTest = Join-Path $ProjectRoot 'tests\pmarachiveops_test.c'
        $arSrc = Join-Path $ProjectRoot 'src\helper\PMArchiveOps.c'
        if ((Test-Path $arTest) -and (Test-Path $arSrc)) {
            $arExe = Join-Path $buildDir 'pmarachiveops_test.exe'
            $arArgs = @('-std=c11','-O1','-Wno-everything',
                        '-I', (Join-Path $ProjectRoot 'src\helper'),
                        '-I', (Join-Path $ProjectRoot 'tests'),
                        '-include', $compatH,
                        $arTest, $arSrc, '-o', $arExe)
            $arLog = & $hostClang @arArgs 2>&1
            $arLog | Where-Object { $_ -match 'error:' } | Select-Object -First 8 |
                ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
            if ($LASTEXITCODE -eq 0 -and (Test-Path $arExe)) {
                $arOut = & $arExe 2>&1
                $arCode = $LASTEXITCODE
                $arOut | Where-Object { $_ -match 'FAIL|passed' } | ForEach-Object { Write-Note $_ }
                if ($arCode -ne 0) { Fail "归档操作单测未通过" }
                Write-Ok "归档操作单测通过"
            } else {
                Write-Note "归档单测编译跳过"
            }
        }
    } else {
        Write-Note "未找到宿主机 clang，跳过单测"
    }
} else {
    Write-Note "未找到 tests/pmfsops_test.c，跳过单测"
}

# ---------- 7. 自检 ----------
Write-Step "自检"
python (Join-Path $scriptsDir 'verify-deb.py') $debPath
if ($LASTEXITCODE -ne 0) { Fail "自检未通过" }

Write-Host ""
Write-Host "构建完成: $debPath" -ForegroundColor Green