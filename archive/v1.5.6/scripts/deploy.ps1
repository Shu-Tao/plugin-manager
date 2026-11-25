#requires -version 5.1
<#
.SYNOPSIS
    把 dist 里的 .deb 推到越狱设备并安装、校验。

.DESCRIPTION
    依赖 Windows 自带 OpenSSH（ssh.exe / scp.exe）。设备需已开启 OpenSSH 且允许 root 登录。
    流程：scp 上传 -> dpkg -i 安装 -> uicache 刷新图标 -> 回读校验（权限、setuid、助手自检）。

.PARAMETER Device
    设备 IP，例如 192.168.1.50（占位符 [DEVICE_IP]）。

.PARAMETER Password
    root 密码，Dopamine 默认 alpine。留空则用已配置的 SSH 密钥。

.EXAMPLE
    .\scripts\deploy.ps1 -Device [DEVICE_IP] -Password [ROOT_PW]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Device,
    [int]$Port = 22,
    [string]$Password = "",
    [string]$Deb = "",
    [switch]$NoRespring,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Write-Step($t) { Write-Host ""; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    $t" -ForegroundColor Green }
function Write-Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Fail($t) { Write-Host "[ERROR] $t" -ForegroundColor Red; exit 1 }

$scriptsDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 依次在「脚本同目录 → dist/ → build/dist/」找包，兼容归档目录与工程目录两种布局
if (-not $Deb) {
    $searchDirs = @(
        (Join-Path $scriptsDir 'Release'),
        $scriptsDir,
        (Join-Path $scriptsDir 'dist'),
        (Join-Path $scriptsDir 'build\dist')
    )
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $hit = Get-ChildItem $dir -Filter '*.deb' |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { $Deb = $hit.FullName; break }
    }
}
if (-not $Deb -or -not (Test-Path $Deb)) { Fail "找不到 .deb，请先运行 build.ps1 或用 -Deb 指定路径" }
Write-Ok ("包: " + $Deb + "  " + [math]::Round((Get-Item $Deb).Length / 1KB, 1) + " KB")

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
$scp = Get-Command scp -ErrorAction SilentlyContinue
if (-not $ssh -or -not $scp) { Fail "未找到 ssh/scp，请启用 Windows 可选功能 OpenSSH Client" }
Write-Ok ("ssh: " + $ssh.Source)

$scpArgs = @('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',
             '-o','ConnectTimeout=10','-o','LogLevel=ERROR','-P',$Port)
$sshArgs = @('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',
             '-o','ConnectTimeout=10','-o','LogLevel=ERROR','-p',$Port)
$remote = "root@$Device"
# 远程用固定英文名，避免中文文件名在设备端 shell 里出问题
$debName = 'pluginmanager-install.deb'

if ($DryRun) {
    Write-Step "DryRun：将要执行的命令"
    Write-Note ('scp ' + ($scpArgs -join ' ') + ' ' + $Deb + ' ' + $remote + ':/tmp/' + $debName)
    Write-Note ('ssh ' + ($sshArgs -join ' ') + ' ' + $remote + ' "sh /tmp/pm-install.sh"')
    exit 0
}

Write-Step "上传到设备"
& scp @scpArgs $Deb ($remote + ":/tmp/" + $debName)
if ($LASTEXITCODE -ne 0) { Fail "scp 失败（检查 IP / 端口 / 密码 / 是否已开 OpenSSH）" }
Write-Ok ("已上传 /tmp/" + $debName)

$installLines = @(
  'set -e',
  'export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin',
  'if command -v dpkg >/dev/null 2>&1; then DPKG=dpkg; else DPKG=/var/jb/usr/bin/dpkg; fi',
  ('$DPKG -i /tmp/' + $debName),
  'APP=/var/jb/Applications/PluginManager.app',
  'HELPER=/var/jb/usr/libexec/pluginmanager/pmhelper',
  'test -d "$APP" || { echo MISSING_APP; exit 10; }',
  'test -x "$APP/PluginManager" || { echo APP_NOT_EXECUTABLE; exit 11; }',
  'test -f "$HELPER" || { echo MISSING_HELPER; exit 12; }',
  'chmod 4755 "$HELPER"',
  'echo "--- perms ---"',
  'ls -ld "$APP"',
  'ls -l "$APP/PluginManager" "$HELPER"',
  'echo "--- helper version ---"',
  '"$HELPER" version || echo HELPER_FAILED',
  'echo "--- helper list ---"',
  '"$HELPER" list | head -c 800 || echo LIST_FAILED',
  'echo',
  'echo "--- uicache ---"',
  'if command -v uicache >/dev/null 2>&1; then uicache -p "$APP" || true; else /var/jb/usr/bin/uicache -p "$APP" 2>/dev/null || true; fi',
  ('rm -f /tmp/' + $debName),
  'echo INSTALL_OK'
)
$local = Join-Path $env:TEMP 'pm-install.sh'
[System.IO.File]::WriteAllText($local, (($installLines -join [char]10) + [char]10), (New-Object System.Text.UTF8Encoding($false)))

& scp @scpArgs $local ($remote + ":/tmp/pm-install.sh")
if ($LASTEXITCODE -ne 0) { Fail "上传安装脚本失败" }

Write-Step "安装并校验"
& ssh @sshArgs $remote "sh /tmp/pm-install.sh; rm -f /tmp/pm-install.sh"
$code = $LASTEXITCODE
if ($code -ne 0) { Fail ("远程安装失败（exit " + $code + "）") }

if (-not $NoRespring) {
    Write-Step "注销 SpringBoard 让图标出现"
    & ssh @sshArgs $remote 'export PATH=/var/jb/usr/bin:/usr/bin:/bin:$PATH; (sbreload || killall -9 SpringBoard) >/dev/null 2>&1 || true'
    Write-Ok "已触发"
}

Write-Host ""
Write-Host "完成。桌面应出现「插件管理」图标。" -ForegroundColor Green
Write-Host "若打开后提示助手不可用：确认 /var/jb/usr/libexec/pluginmanager/pmhelper 权限为 4755。" -ForegroundColor DarkGray