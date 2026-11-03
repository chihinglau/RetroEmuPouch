<#
.SYNOPSIS
    Local HTTPS debug launcher for store builds to talk to the real backend.

.DESCRIPTION
    Store builds forbid plaintext HTTP, but HTTPS to any host is allowed
    (see app/lib/data/cloud/security_policy.dart). This script uses mkcert to
    generate a trusted cert and serves uvicorn over TLS, so a store package can
    just point the backend URL at https://127.0.0.1:8000 for local debugging -
    no need to switch to the community channel, and the path matches production.

    Usage:
        Run inside the tools/account_backend directory:
        .\start-https.ps1
    Then on the phone: hdc rport tcp:8000 tcp:8000 (USB forwarding), and in the
    app debug entry set the URL to https://127.0.0.1:8000.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
Push-Location $root

$certs = Join-Path $root 'certs'
New-Item -ItemType Directory -Force -Path $certs | Out-Null

function Ensure-Mkcert {
  if (Get-Command mkcert -ErrorAction SilentlyContinue) { return }
  Write-Host '[start-https] mkcert not found, trying to install...' -ForegroundColor Yellow
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id FiloSottile.mkcert
  } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
    scoop install mkcert
  } else {
    throw 'Please install mkcert first: https://github.com/FiloSottile/mkcert (or: scoop install mkcert / winget install FiloSottile.mkcert)'
  }
  if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw 'mkcert still unavailable after install. Restart the terminal or add it to PATH.'
  }
}
$cert = Join-Path $certs '127.0.0.1.pem'
$key  = Join-Path $certs '127.0.0.1-key.pem'
# If the cert/key already exist, skip mkcert entirely (mkcert may not be installed;
# the OHOS app trusts the self-signed cert for loopback in debug anyway).
if (-not (Test-Path $cert) -or -not (Test-Path $key)) {
  Ensure-Mkcert
  mkcert -install
  mkcert -cert-file $cert -key-file $key 127.0.0.1 localhost
}

Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '  HTTPS local backend: https://127.0.0.1:8000' -ForegroundColor Cyan
Write-Host '  Swagger:        https://127.0.0.1:8000/docs' -ForegroundColor Cyan
Write-Host '  App URL to set:  https://127.0.0.1:8000' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '(First time only: trust the mkcert root CA. On PC run "mkcert -CAROOT"'
Write-Host '  to find rootCA.pem, install it on the device via'
Write-Host '  Settings -> Security -> Install certificate -> CA certificate.)'
Write-Host '(If data is not seeded yet: in another terminal POST /admin/seed.)'

uvicorn app.main:app --host 0.0.0.0 --port 8000 `
  --ssl-keyfile $key --ssl-certfile $cert --reload
