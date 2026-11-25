#requires -version 5.1
<#
.SYNOPSIS
    发布最新构建到两个 GitHub 仓库。
.DESCRIPTION
    1. plugin-manager 仓库：提交源码与产物
    2. shutao-repo 仓库：收录 deb、重建索引、推送
    每次 build.ps1 之后自动调用；也可手动执行。
#>
[CmdletBinding()]
param(
    [string]$Version = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Version) {
    $Version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
}
if (-not $Version) { Write-Host "[ERROR] VERSION empty" -ForegroundColor Red; exit 1 }

$debName = "com.shutao.pluginmanager_" + $Version + "_iphoneos-arm64.deb"
$debPath = Join-Path $root ("Release\" + $debName)
if (-not (Test-Path $debPath)) {
    Write-Host "[ERROR] deb not found: $debName" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==> Publishing v$Version" -ForegroundColor Cyan

# ---------- 1. plugin-manager ----------
Write-Host "  [1/2] plugin-manager" -ForegroundColor Yellow
Push-Location $root
try {
    & git add -A 2>&1 | Out-Null
    $staged = & git status --porcelain
    if ($staged) {
        & git commit -m "release: v$Version" 2>&1 | Out-Null
    }
    $pushOut = & git push origin main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    push failed" -ForegroundColor Red
        $pushOut | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    } else {
        Write-Host "    OK" -ForegroundColor Green
    }
} catch {
    Write-Host "    error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Pop-Location
}

# ---------- 2. shutao-repo ----------
Write-Host "  [2/2] shutao-repo" -ForegroundColor Yellow
$repoDir = Join-Path (Split-Path -Parent $root) 'shutao-repo'
if (-not (Test-Path $repoDir)) {
    Write-Host "    skip: shutao-repo not found" -ForegroundColor DarkGray
    exit 0
}

$repoDebs = Join-Path $repoDir 'debs'
Copy-Item $debPath $repoDebs -Force

Push-Location $repoDir
try {
    & python (Join-Path $repoDir 'scripts\rebuild.py') 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" }

    & git add -A 2>&1 | Out-Null
    $staged2 = & git status --porcelain
    if ($staged2) {
        & git commit -m "add: v$Version" 2>&1 | Out-Null
    }
    $pushOut2 = & git push origin main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    push failed" -ForegroundColor Red
        $pushOut2 | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    } else {
        Write-Host "    OK  https://shu-tao.github.io/shutao-repo/" -ForegroundColor Green
    }
} catch {
    Write-Host "    error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Published v$Version" -ForegroundColor Green
