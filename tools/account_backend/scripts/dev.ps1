# =================================================================
# RetroEmuPouch Account Backend —— 本地开发一键启动
#
#   ./scripts/dev.ps1                  # 自动选库：有 Docker→Postgres（与云端同构），否则 SQLite
#   ./scripts/dev.ps1 -Db postgres     # 强制 Postgres（推荐，需 Docker Desktop）
#   ./scripts/dev.ps1 -Db sqlite       # 强制 SQLite（无 Docker 时的快速调试）
#   ./scripts/dev.ps1 -MigrateOnly     # 只准备数据库 + 跑迁移，不启动服务
#   ./scripts/dev.ps1 -Port 8001       # 换端口
#
# 双轨维护约定（详见 docs/design-account-backend.md 的「本地 / 云端双轨维护」）：
#   1) 本地库与云端库永不互连、不双写；线上数据只在需要复现时拉副本（脱敏）到本地。
#   2) schema 只走 alembic：改模型 → 写 alembic revision → 本地 upgrade 验证 → 部署时远端 upgrade。
#   3) 日常开发尽量用 Postgres（-Db postgres），SQLite 仅是无 Docker 的降级，类型/约束有差异。
# =================================================================
param(
    [ValidateSet("auto", "postgres", "sqlite")]
    [string]$Db = "auto",
    [int]$Port = 8000,
    [string]$BindHost = "0.0.0.0",
    [switch]$MigrateOnly,
    [switch]$NoReload
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectDir

$DataRoot  = "D:\RetroEmuPouch\backend"
$SqliteDb  = "D:/RetroEmuPouch/backend/sqlite/dev.db"
$LocalEnv  = Join-Path $ProjectDir ".env.local"
$ComposeFile = "docker-compose.local.yml"

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  FAIL $m" -ForegroundColor Red; exit 1 }

# 原生程序（python/docker）常把正常信息写到 stderr，脚本里 $ErrorActionPreference=Stop
# 会把它当成终止错误。统一用 Run-Native 调用并合并输出，返回真实退出码。
function Run-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-PgReady {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker compose -f $ComposeFile exec -T db pg_isready -U retroemupouch *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

Info "`n== 0/5 检查运行环境 =="
if (-not (Test-Path (Join-Path $ProjectDir "app\main.py"))) {
    Fail "请在 tools/account_backend 目录下运行（当前: $ProjectDir）"
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Fail "找不到 python，请先安装 Python 3.11+ 并加入 PATH"
}
$depCode = Run-Native "python" @("-c", "import fastapi, uvicorn, alembic, sqlalchemy")
if ($depCode -ne 0) {
    Fail "依赖不全：cd $ProjectDir; pip install -r requirements.txt"
}
Ok "python 与后端依赖可用"

# .env 供 app/config.py 读取（缺失时从模板生成）
$EnvFile = Join-Path $ProjectDir ".env"
if (-not (Test-Path $EnvFile)) {
    Copy-Item (Join-Path $ProjectDir ".env.example") $EnvFile
    Ok "已从 .env.example 生成 .env（本地开发值，勿用于生产）"
}

Info "`n== 1/5 选择数据库 =="
$hasDocker = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker info --format '{{.ServerVersion}}' *> $null
        if ($LASTEXITCODE -eq 0) { $hasDocker = $true }
    } finally {
        $ErrorActionPreference = $prev
    }
}

$mode = $Db
if ($mode -eq "auto") {
    if ($hasDocker) { $mode = "postgres" } else { $mode = "sqlite" }
}
if ($mode -eq "postgres" -and -not $hasDocker) {
    Warn "未检测到可用的 Docker → 自动降级为 SQLite"
    Warn "SQLite 与生产 Postgres 存在类型/约束差异，涉及 schema 的改动请务必在 Postgres 上复测"
    $mode = "sqlite"
}

if ($mode -eq "postgres") {
    Ok "数据库：Postgres（与云端同构）"

    Info "`n== 2/5 启动本地 Postgres 容器 =="
    if (-not (Test-Path $LocalEnv)) {
        Copy-Item (Join-Path $ProjectDir ".env.local.example") $LocalEnv
        Warn "已生成 .env.local —— 请把 DB_PASSWORD=CHANGE_ME... 改成随机强口令"
    }
    $dbPassword = ""
    foreach ($line in [System.IO.File]::ReadAllLines($LocalEnv, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*DB_PASSWORD\s*=\s*(.*)$') { $dbPassword = $matches[1].Trim() }
    }
    if (-not $dbPassword -or $dbPassword -like "CHANGE_ME*") {
        Fail "请先在 $LocalEnv 里设置 DB_PASSWORD（随机 32 位以上）"
    }
    $env:DB_PASSWORD = $dbPassword

    $code = Run-Native "docker" @("compose", "-f", $ComposeFile, "up", "-d", "db")
    if ($code -ne 0) { Fail "docker compose up -d db 失败" }

    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-PgReady) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { Fail "Postgres 60 秒内未就绪：docker compose -f $ComposeFile logs db" }
    Ok "Postgres 就绪（127.0.0.1:5432）"

    $env:DATABASE_URL = "postgresql+psycopg://retroemupouch:$dbPassword@127.0.0.1:5432/retroemupouch"
} else {
    Ok "数据库：SQLite（$SqliteDb）"
    Warn "SQLite 仅用于快速改接口；Boolean/时区/唯一约束行为与 Postgres 不同"
    $sqliteDir = Split-Path -Parent ($SqliteDb.Replace("/", "\"))
    $null = New-Item -ItemType Directory -Force -Path $sqliteDir
    $env:DATABASE_URL = "sqlite:///$SqliteDb"
}

$env:APP_ENV = "local"
$env:LOG_DIR = "$DataRoot\logs"
$env:BACKUP_DIR = "$DataRoot\backups"
$null = New-Item -ItemType Directory -Force -Path $env:LOG_DIR

Info "`n== 3/5 数据库 schema =="
if ($mode -eq "postgres") {
    $code = Run-Native "python" @("-m", "alembic", "upgrade", "head")
    if ($code -ne 0) { Fail "alembic upgrade head 失败" }
    Ok "alembic upgrade head 完成（与云端同一套迁移脚本）"
} else {
    # SQLite 由 app/main.py 的 create_all 兜底；这里预跑一次以便尽早暴露模型错误
    $code = Run-Native "python" @("-c", "import app.main")
    if ($code -ne 0) { Warn "create_all 预检失败（服务启动时会再试一次）" }
    Ok "SQLite 表结构由 create_all 保证（无需 alembic）"
    Warn "发布前请在 Postgres 上再跑一次 alembic upgrade head 验证迁移脚本"
}

if ($MigrateOnly) {
    Info "`n仅准备数据库模式：数据库已就绪，退出。`n"
    exit 0
}

Info "`n== 4/5 客户端联调地址 =="
$lanIps = @()
try {
    $lanIps = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object {
            $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            -not [System.Net.IPAddress]::IsLoopback($_) -and
            -not $_.ToString().StartsWith("169.254.")
        } |
        ForEach-Object { $_.ToString() }
} catch { }

Write-Host "  本机监听 : http://127.0.0.1:$Port" -ForegroundColor White
foreach ($ip in $lanIps) {
    Write-Host "  真机可用 : http://${ip}:$Port" -ForegroundColor White
}
Write-Host "  App 里填 : 「我的账号 → 后端地址」= 上面任一地址" -ForegroundColor DarkGray
Write-Host "  注意     : 明文 HTTP 仅 debug / community 渠道放行（RFC1918 私网）；" -ForegroundColor DarkGray
Write-Host "             store 渠道 release 包只接受 HTTPS，需走 tunnel.ps1 或云端域名" -ForegroundColor DarkGray

Info "`n== 5/5 启动 uvicorn =="
if ($NoReload) {
    Ok "uvicorn app.main:app --host $BindHost --port $Port（无热重载）"
    $code = Run-Native "python" @("-m", "uvicorn", "app.main:app", "--host", $BindHost, "--port", "$Port")
} else {
    Ok "uvicorn app.main:app --host $BindHost --port $Port --reload（Ctrl+C 停止）"
    $code = Run-Native "python" @("-m", "uvicorn", "app.main:app", "--host", $BindHost, "--port", "$Port", "--reload")
}
exit $code
