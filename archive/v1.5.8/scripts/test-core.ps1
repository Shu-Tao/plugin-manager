#requires -version 5.1
<#
.SYNOPSIS
    在宿主机（Windows 或 Linux）上跑 PMFsOps 的单元测试，不依赖 iOS 工具链。

.EXAMPLE
    .\scripts\test-core.ps1
#>
[CmdletBinding()]
param(
    [string]$ToolchainRoot = "E:\DataBackup\toolchain"
)

$ErrorActionPreference = 'Stop'
$scriptsDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptsDir
$buildDir = Join-Path $projectRoot "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$hostClang = Get-ChildItem -Path (Join-Path $ToolchainRoot "mingw") -Filter "x86_64-w64-mingw32-clang.exe" -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
if (-not $hostClang) {
    $cmd = Get-Command clang -ErrorAction SilentlyContinue
    if ($cmd) { $hostClang = $cmd.Source }
}
if (-not $hostClang) { Write-Host "[ERROR] 没有可用的宿主机 clang" -ForegroundColor Red; exit 1 }

$exe = Join-Path $buildDir "pmfsops_test.exe"
$args = @("-std=c11","-Wall","-O1",
          "-I", (Join-Path $projectRoot "src\helper"),
          "-I", (Join-Path $projectRoot "tests"),
          "-include", (Join-Path $projectRoot "tests\win_compat.h"),
          (Join-Path $projectRoot "tests\pmfsops_test.c"),
          (Join-Path $projectRoot "src\helper\PMFsOps.c"),
          "-o", $exe)
& $hostClang @args
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] 编译失败" -ForegroundColor Red; exit 1 }

$fixture = Join-Path $buildDir "fixture"
New-Item -ItemType Directory -Force -Path $fixture | Out-Null
$env:PM_TEST_ROOT = $fixture
& $exe
$code = $LASTEXITCODE
$env:PM_TEST_ROOT = ""
exit $code
