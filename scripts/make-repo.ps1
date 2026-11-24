#requires -version 5.1
<#
.SYNOPSIS
    重建本地 deb 源索引（repo/Packages + Release）。

.DESCRIPTION
    每次 build.ps1 出新包后跑一次，Sileo 才能看到新版本。
    也可以 .\scripts\build.ps1 之后直接 .\scripts\make-repo.ps1。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $here

$py = Join-Path $root 'scripts\mk-repo.py'
if (-not (Test-Path $py)) { Write-Host "缺少 scripts\mk-repo.py" -ForegroundColor Red; exit 1 }
python $py
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "repo/ 索引已更新" -ForegroundColor Green
