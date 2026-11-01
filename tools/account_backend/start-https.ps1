<#
.SYNOPSIS
    本地 HTTPS 调试启动脚本（供 store 构建联调真实后台）。

.DESCRIPTION
    store 构建禁止明文 HTTP，但 HTTPS 任何主机都放行（见 app/lib/data/cloud/security_policy.dart）。
    本脚本用 mkcert 生成受信证书并给 uvicorn 挂 TLS，使 store 包把后端地址填为
    https://127.0.0.1:8000 即可联调真实后台——无需切到 community 渠道、且路径与生产一致。

    用法：
        在 tools/account_backend 目录执行
        .\start-https.ps1
    然后手机：adb reverse tcp:8000 tcp:8000（USB 转发），App 调试入口填 https://127.0.0.1:8000。
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $root

$certs = Join-Path $root 'certs'
New-Item -ItemType Directory -Force -Path $certs | Out-Null

function Ensure-Mkcert {
  if (Get-Command mkcert -ErrorAction SilentlyContinue) { return }
  Write-Host '[start-https] 未找到 mkcert，尝试安装...' -ForegroundColor Yellow
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id FiloSottile.mkcert
  } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
    scoop install mkcert
  } else {
    throw '请先安装 mkcert：https://github.com/FiloSottile/mkcert （或 scoop install mkcert / winget install FiloSottile.mkcert）'
  }
  if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw 'mkcert 安装后仍不可用，请重启终端或将其加入 PATH。'
  }
}
Ensure-Mkcert

# 安装本地根 CA 并签发 127.0.0.1 + localhost 证书
mkcert -install
$cert = Join-Path $certs '127.0.0.1.pem'
$key  = Join-Path $certs '127.0.0.1-key.pem'
if (-not (Test-Path $cert) -or -not (Test-Path $key)) {
  mkcert -cert-file $cert -key-file $key 127.0.0.1 localhost
}

Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  HTTPS 本地后台: https://127.0.0.1:8000' -ForegroundColor Cyan
Write-Host '  Swagger:        https://127.0.0.1:8000/docs' -ForegroundColor Cyan
Write-Host '  App 端填:       https://127.0.0.1:8000' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '（首次需在设备信任 mkcert 根 CA：PC 执行 "mkcert -CAROOT" 找到 rootCA.pem，'
Write-Host '  通过 设置→安全→安装证书→CA 证书 装入；模拟器可用 adb push 到系统信任区。）'
Write-Host '（如尚未初始化数据：另开终端 POST /admin/seed 生成 CMS/配置默认数据。）'

uvicorn app.main:app --host 0.0.0.0 --port 8000 `
  --ssl-keyfile $key --ssl-certfile $cert --reload
