#requires -version 5.1
<#
.SYNOPSIS
    在局域网里找你的 iPhone（扫 62078 lockdown 端口 + 22 SSH 端口）。

.DESCRIPTION
    iOS 设备的 usbmuxd lockdown 端口 62078 是强特征，且 iPhone 几乎不会关掉它。
    找到后直接打印可用的安装命令。

.EXAMPLE
    .\scripts\find-device.ps1
    .\scripts\find-device.ps1 -Subnet 192.168.1
#>
[CmdletBinding()]
param(
    [string]$Subnet = "",
    [int]$TimeoutMs = 350
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-LocalSubnet {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
           Sort-Object -Property InterfaceMetric |
           Select-Object -First 1).IPAddress
    if (-not $ip) { return "" }
    $parts = $ip.Split(".")
    return ($parts[0] + "." + $parts[1] + "." + $parts[2])
}

if (-not $Subnet) { $Subnet = Get-LocalSubnet }
if (-not $Subnet) { Write-Host "找不到本机网段，请手动指定 -Subnet 192.168.1" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "扫描 $Subnet.1-254 ..." -ForegroundColor Cyan

$targets = 1..254 | ForEach-Object { $Subnet + "." + $_ }
$results = @()

# 并发探测：62078 = iOS lockdown，22 = SSH
$jobs = @()
foreach ($t in $targets) {
    $jobs += [pscustomobject]@{ IP = $t; Client = $null; Task = $null }
}

$tasks = foreach ($t in $targets) {
    $c = New-Object System.Net.Sockets.TcpClient
    [pscustomobject]@{
        IP = $t
        Client = $c
        Task = $c.ConnectAsync($t, 62078)
    }
}
Start-Sleep -Milliseconds 1200
foreach ($t in $tasks) {
    if ($t.Task.IsCompleted -and -not $t.Task.IsFaulted -and $t.Client.Connected) {
        $results += $t.IP
    }
    $t.Client.Dispose()
}

if ($results.Count -eq 0) {
    Write-Host "没扫到 iPhone。" -ForegroundColor Yellow
    Write-Host "可能原因：" -ForegroundColor DarkGray
    Write-Host "  1. 手机没连同一个 WiFi（或连的是 5G 蜂窝网）" -ForegroundColor DarkGray
    Write-Host "  2. 路由开了 AP 隔离，设备间不能互访" -ForegroundColor DarkGray
    Write-Host "  3. 网段不是 $Subnet，用 -Subnet 指定" -ForegroundColor DarkGray
    exit 1
}

foreach ($ip in $results) {
    $ssh = "关"
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $c.Connect($ip, 22)
        if ($c.Connected) { $ssh = "开" }
    } catch { }
    $c.Dispose()

    $name = ""
    try { $name = ([System.Net.Dns]::GetHostEntry($ip)).HostName } catch { }

    Write-Host ""
    Write-Host ("发现设备: " + $ip + "  SSH:" + $ssh + "  " + $name) -ForegroundColor Green
    if ($ssh -eq "开") {
        Write-Host ("  → 安装命令: .\scripts\deploy.ps1 -Device " + $ip + " -Password [ROOT_PW]") -ForegroundColor White
    } else {
        Write-Host "  → 设备没开 SSH：Sileo 里装 OpenSSH 后重跑" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($results.Count -eq 1 -and $results[0]) { $results[0] }
