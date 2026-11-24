#requires -version 5.1
<#
.SYNOPSIS
    起一个局域网 HTTP 服务，把本地 deb 源喂给手机上的 Sileo。不需要 SSH、不需要管理员权限。

.EXAMPLE
    .\scripts\serve-sileo.ps1
    .\scripts\serve-sileo.ps1 -Port 8900
#>
[CmdletBinding()]
param(
    [int]$Port = 8899,
    [string]$BindAddress = "0.0.0.0"
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 依次在「脚本同目录/repo → 上级/repo → 上级/build/repo」找索引
$repo = $null
foreach ($cand in @(
    (Join-Path $here 'repo'),
    (Join-Path (Split-Path -Parent $here) 'repo'),
    (Join-Path (Split-Path -Parent $here) 'build\repo')
)) {
    if (Test-Path (Join-Path $cand 'Packages')) { $repo = $cand; break }
}

if (-not $repo) {
    Write-Host "找不到 repo/Packages 索引" -ForegroundColor Red
    exit 1
}

function Get-LanAddress {
    $candidates = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -notlike "172.1[6-9].*" -and
            $_.IPAddress -notlike "172.2*" -and
            $_.IPAddress -notlike "172.3[01].*"
        } |
        Where-Object {
            $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
            $ad -and $ad.Status -eq "Up" -and $ad.Virtual -eq $false
        } |
        Sort-Object -Property InterfaceMetric

    if ($candidates) {
        $wifi = $candidates | Where-Object { $_.IPAddress -like "192.168.*" } | Select-Object -First 1
        if ($wifi) { return $wifi.IPAddress }
        return $candidates[0].IPAddress
    }

    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($route) {
        $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($addr) { return $addr.IPAddress }
    }
    return ""
}

$ip = Get-LanAddress
if (-not $ip) { Write-Host "拿不到局域网 IP，检查网络或用 -BindAddress" -ForegroundColor Red; exit 1 }

$baseUrl = "http://" + $ip + ":" + $Port + "/"

Write-Host ""
Write-Host "  本地 deb 源" -ForegroundColor Green
Write-Host ""
Write-Host "  源地址      $baseUrl" -ForegroundColor Cyan
Write-Host "  Sileo 一键  sileo://source/$baseUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  手机上：" -ForegroundColor White
Write-Host "    1. 与电脑连同一个 WiFi"
Write-Host "    2. Sileo -> 软件源 -> 右上角 + -> 粘贴源地址 -> 添加"
Write-Host "    3. 源里找到「插件管理」-> 安装"
Write-Host ""
Write-Host "  Ctrl+C 停止" -ForegroundColor DarkGray
Write-Host ""

$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($BindAddress), $Port)
    $listener.Start()
} catch {
    Write-Host ("端口 " + $Port + " 起不来：" + $_.Exception.Message) -ForegroundColor Red
    Write-Host "换个端口：-Port 8900" -ForegroundColor DarkGray
    exit 1
}

$mime = @{
    ".deb" = "application/vnd.debian.binary-package"
    ".gz"  = "application/gzip"
    ".bz2" = "application/x-bzip2"
    ".xz"  = "application/x-xz"
    ".txt" = "text/plain; charset=utf-8"
}

function Send-Response {
    param($Stream, [int]$Status, [string]$StatusText, [byte[]]$Body, [string]$ContentType)
    $head = "HTTP/1.1 " + $Status + " " + $StatusText + "`r`n" +
            "Server: YG-Local-Repo`r`n" +
            "Content-Type: " + $ContentType + "`r`n" +
            "Content-Length: " + $Body.Length + "`r`n" +
            "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if (-not $requestLine) { continue }
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line -eq "") { break }
            }

            $parts = $requestLine.Split(" ")
            $rawPath = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
            $rel = [Uri]::UnescapeDataString($rawPath).Split("?")[0].TrimStart("/")
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "Packages" }

            if ($rel -match "\.\.") {
                $b = [System.Text.Encoding]::UTF8.GetBytes("bad request")
                Send-Response -Stream $stream -Status 400 -StatusText "Bad Request" -Body $b -ContentType "text/plain"
                Write-Host ("  400 " + $rel) -ForegroundColor Yellow
            } else {
                $path = Join-Path $repo ($rel -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                if (Test-Path $path -PathType Leaf) {
                    $bytes = [System.IO.File]::ReadAllBytes($path)
                    $ext = [System.IO.Path]::GetExtension($path).ToLower()
                    $ct = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
                    Send-Response -Stream $stream -Status 200 -StatusText "OK" -Body $bytes -ContentType $ct
                    Write-Host ("  200 " + $rel + "  " + $bytes.Length + " B") -ForegroundColor DarkGray
                } else {
                    $b = [System.Text.Encoding]::UTF8.GetBytes("not found")
                    Send-Response -Stream $stream -Status 404 -StatusText "Not Found" -Body $b -ContentType "text/plain"
                    Write-Host ("  404 " + $rel) -ForegroundColor Yellow
                }
            }
            $stream.Close()
        } catch { } finally { $client.Close() }
    }
} finally {
    if ($listener) { $listener.Stop() }
    Write-Host ""
    Write-Host "  服务已停止" -ForegroundColor DarkGray
}
