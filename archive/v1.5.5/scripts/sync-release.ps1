#requires -version 5.1
<#
.SYNOPSIS
    把当前版本的源码归档到 archive\v<版本>\，并同步根目录安装脚本与文档版本号。

.DESCRIPTION
    每次构建后自动调用；也可手动执行。
    幂等：同一版本重复执行不会产生重复目录。

.EXAMPLE
    .\scripts\sync-release.ps1
    .\scripts\sync-release.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptsDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $scriptsDir }

function Write-Step2($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok2($t)   { Write-Host "    $t" -ForegroundColor Green }
function Write-Note2($t) { Write-Host "    $t" -ForegroundColor DarkGray }

$version = (Get-Content (Join-Path $ProjectRoot "VERSION") -Raw).Trim()
if (-not $version) { Write-Host "[ERROR] VERSION 为空" -ForegroundColor Red; exit 1 }
Write-Ok2 ("当前版本: " + $version)

# ---------- 1. 源码归档 ----------
Write-Step2 "源码归档"
$archiveRoot = Join-Path $ProjectRoot "archive"
$verDir = Join-Path $archiveRoot ("v" + $version)

if ((Test-Path $verDir) -and -not $Force) {
    Write-Note2 ("archive\v" + $version + " 已存在，跳过（-Force 可覆盖）")
} else {
    if (Test-Path $verDir) { Remove-Item $verDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $verDir | Out-Null

    foreach ($item in @("src", "resources", "tests", "scripts")) {
        $s = Join-Path $ProjectRoot $item
        if (Test-Path $s) {
            Copy-Item $s (Join-Path $verDir $item) -Recurse -Force
        }
    }
    foreach ($f in @("README.md", "VERSION")) {
        $s = Join-Path $ProjectRoot $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $verDir $f) -Force }
    }

    # 附一份该版本的 deb
    $relDir = Join-Path $ProjectRoot "Release"
    if (Test-Path $relDir) {
        $pattern = "*" + $version.Replace(".", ".") + "*.deb"
        Get-ChildItem $relDir -Filter "*.deb" | Where-Object { $_.Name -like ("*_" + $version + "_*") } |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $verDir $_.Name) -Force }
    }

    $cnt = (Get-ChildItem $verDir -Recurse -File | Measure-Object).Count
    Write-Ok2 ("archive\v" + $version + "\ 已生成，共 " + $cnt + " 个文件")
}

# ---------- 2. 根目录脚本同步 ----------
Write-Step2 "同步根目录安装脚本"
$rootScripts = @("deploy.ps1", "find-device.ps1", "serve-sileo.ps1", "一键安装到手机.ps1")
foreach ($name in $rootScripts) {
    $srcPath = Join-Path (Join-Path $ProjectRoot "scripts") $name
    $dstPath = Join-Path $ProjectRoot $name
    if (-not (Test-Path $srcPath)) {
        # scripts 里没有就反向同步（把根目录的推到 scripts）
        if (Test-Path $dstPath) {
            Copy-Item $dstPath $srcPath -Force
            Write-Note2 ($name + " ← 从根目录回填到 scripts\")
        }
        continue
    }
    $same = $false
    if (Test-Path $dstPath) {
        $same = (Get-FileHash $srcPath -Algorithm SHA256).Hash -eq (Get-FileHash $dstPath -Algorithm SHA256).Hash
    }
    if (-not $same) {
        Copy-Item $srcPath $dstPath -Force
        Write-Ok2 ($name + " 已同步")
    } else {
        Write-Note2 ($name + " 已一致")
    }
}

# ---------- 3. 文档版本号替换 ----------
Write-Step2 "刷新文档版本号"
foreach ($doc in @("安装说明.txt", "README.md")) {
    $p = Join-Path $ProjectRoot $doc
    if (-not (Test-Path $p)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch "__VERSION__") {
        Write-Note2 ($doc + " 不含占位符，跳过")
        continue
    }
    $replaced = $text.Replace("__VERSION__", $version)
    [System.IO.File]::WriteAllText($p, $replaced, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok2 ($doc + " → " + $version)
}

# ---------- 4. 汇总 ----------
Write-Host ""
if (Test-Path $archiveRoot) {
    $vers = Get-ChildItem $archiveRoot -Directory | Sort-Object Name
    Write-Host ("已归档版本: " + (($vers | ForEach-Object { $_.Name }) -join ", ")) -ForegroundColor Green
}
