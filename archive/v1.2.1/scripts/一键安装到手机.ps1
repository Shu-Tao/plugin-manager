#requires -version 5.1
<#
.SYNOPSIS
    一条命令把 deb 装到 iPhone（自动找设备 / 手动填 IP）。

.EXAMPLE
    .\一键安装到手机.ps1
    .\一键安装到手机.ps1 -Device 192.168.1.50 -Password alpine
#>
[CmdletBinding()]
param(
    [string]$Device = "",
    [int]$Port = 22,
    [string]$Password = ""
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $here
$deb = Get-ChildItem (Join-Path $root "dist") -Filter "*.deb" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $deb) { Write-Host "找不到 deb，先运行 scripts\build.ps1" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "  插件管理 —— 安装到 iPhone" -ForegroundColor Cyan
Write-Host ("  " + $deb.Name) -ForegroundColor DarkGray
Write-Host ""

if (-not $Device) {
    Write-Host "正在局域网里找设备..." -ForegroundColor Yellow
    $found = & (Join-Path $here "find-device.ps1")
    $candidate = ($found | Select-Object -Last 1)
    if ($candidate -and $candidate -match "^\d+\.\d+\.\d+\.\d+$") {
        Write-Host ("找到设备: " + $candidate) -ForegroundColor Green
        $ans = Read-Host "用它吗？(Y/n)"
        if ($ans -eq "" -or $ans -match "^[Yy]") { $Device = $candidate }
    }
}

if (-not $Device) {
    Write-Host ""
    $Device = Read-Host "请输入手机 IP（设置 - WiFi - 点当前网络 - IP 地址）"
}
if (-not $Device) { Write-Host "没有 IP，退出。" -ForegroundColor Red; exit 1 }

if (-not $Password) {
    Write-Host ""
    Write-Host "root 密码（Dopamine 默认 alpine，没改过就直接回车）" -ForegroundColor DarkGray
    $Password = Read-Host "密码"
    if (-not $Password) { $Password = "alpine" }
}

Write-Host ""
& (Join-Path $here "deploy.ps1") -Device $Device -Port $Port -Password $Password
