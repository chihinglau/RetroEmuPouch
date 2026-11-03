<#
  dev-connect.ps1 - one-click device integration (store build)
  1. Check if 127.0.0.1:8000 is listening; if not, start the HTTPS backend (generate cert if missing)
  2. Re-establish adb reverse tcp:8000 tcp:8000
  3. Push the dev CA cert to the device (install as user CA via Settings)
  Usage: run .\dev-connect.ps1 from the tools/account_backend directory
#>
param(
  [string]$DeviceSerial = "66B0219C18003002",
  [string]$AndroidHome  = "D:/ai/prj/trae/HuaWei/RetroEmuPouch/.tools/android-sdk",
  [int]$Port = 8000
)

$root = $PSScriptRoot
Set-Location $root

function Banner($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

Banner "1/3 backend HTTPS (127.0.0.1:$Port)"
$listening = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' -and $_.LocalAddress -eq '127.0.0.1' }
if ($listening) {
  Write-Host "Already listening (PID $($listening[0].OwningProcess)), skip start." -ForegroundColor Green
} else {
  if (-not (Test-Path localhost.pem)) {
    Write-Host "localhost.pem not found, generating self-signed dev CA..." -ForegroundColor Yellow
    python gen_cert.py
  }
  Write-Host "Starting uvicorn (HTTPS)..." -ForegroundColor Yellow
  Start-Process -FilePath python -ArgumentList "-m","uvicorn","app.main:app","--port","$Port","--ssl-keyfile","localhost-key.pem","--ssl-certfile","localhost.pem","--log-level","info" -RedirectStandardOutput https.log -RedirectStandardError https.err -NoNewWindow
  Start-Sleep -Seconds 6
  $again = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' -and $_.LocalAddress -eq '127.0.0.1' }
  if (-not $again) {
    Write-Host "Start failed, see https.err:" -ForegroundColor Red
    Get-Content https.err -Tail 15
    exit 1
  }
  Write-Host "Backend started (PID $($again[0].OwningProcess))." -ForegroundColor Green
}

Banner "2/3 adb reverse tcp:$Port tcp:$Port"
$adb = Join-Path $AndroidHome "platform-tools/adb.exe"
if (-not (Test-Path $adb)) { Write-Host "adb not found: $adb" -ForegroundColor Red; exit 1 }
& $adb -s $DeviceSerial reverse "tcp:$Port" "tcp:$Port" 2>&1 | Out-Null
$rv = & $adb -s $DeviceSerial reverse --list 2>&1
if ($rv -match "tcp:$Port") { Write-Host "reverse active: $rv" -ForegroundColor Green } else { Write-Host "reverse failed: $rv" -ForegroundColor Red; exit 1 }

Banner "3/3 push dev CA cert to device"
if (-not (Test-Path localhost.pem)) { Write-Host "localhost.pem missing, cannot push." -ForegroundColor Red; exit 1 }
& $adb -s $DeviceSerial push localhost.pem /sdcard/Download/retroemupouch-dev-ca.pem 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host "cert pushed to /sdcard/Download/retroemupouch-dev-ca.pem" -ForegroundColor Green } else { Write-Host "push failed (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }

Write-Host "`nDone. On the phone: Settings -> Security -> Install certificate -> CA certificate -> pick /sdcard/Download/retroemupouch-dev-ca.pem (skip if already installed); then in the App Network page debug entry set https://127.0.0.1:$Port and enable Use real backend, retry." -ForegroundColor Green
