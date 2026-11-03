# =================================================================
# 内网穿透一键脚本（2 选 1）
#   选项 1：Cloudflare Tunnel（零成本 + 自动 HTTPS）
#   选项 2：cpolar（国内节点 + 速度快）
#
# 所有数据/配置统一存 D:\RetroEmuPouch\
# 本地 FastAPI 已经在 127.0.0.1:8000 跑着了
# =================================================================

param(
    [ValidateSet("cloudflare", "cpolar")]
    [string]$Provider = "cloudflare",
    
    [string]$LocalPort = "8000",
    
    [string]$Subdomain = "api",   # Cloudflare Tunnel 用：api.yourdomain.com
    [string]$Domain = ""           # 你的域名（Cloudflare Tunnel 用）
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot

# ⭐ D 盘根目录（所有数据存这里）
$DataRoot = "D:\RetroEmuPouch"
$BackendDir = "$DataRoot\backend"
$TunnelDir = "$DataRoot\tunnel"
$CfDir = "$TunnelDir\cloudflared"
$CpolarDir = "$TunnelDir\cpolar"

# 确保 D 盘目录存在
$dirs = @($DataRoot, $BackendDir, "$BackendDir\logs", "$BackendDir\backups", "$BackendDir\uploads", $TunnelDir, $CfDir, $CpolarDir)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# =================================================================
# 前置：确保本地后端已启动
# =================================================================
function Ensure-LocalBackend {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/healthz" -UseBasicParsing -TimeoutSec 3
        Write-Host "✅ 本地后端已在 http://127.0.0.1:$LocalPort 运行" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "⚠️  本地后端未启动，尝试启动..." -ForegroundColor Yellow
        
        Set-Location $ProjectDir
        
        # 方式 1：Docker Compose（如果有 Docker）
        $docker = Get-Command docker -ErrorAction SilentlyContinue
        if ($docker) {
            $envFile = "$ProjectDir\.env.local"
            if (-not (Test-Path $envFile)) {
                Copy-Item "$ProjectDir\.env.local.example" $envFile
            }
            Write-Host "   用 Docker Compose 启动..."
            docker compose -f docker-compose.local.yml up -d --build
            Write-Host "   等待服务就绪（约 30 秒）..."
            Start-Sleep -Seconds 30
        } else {
            # 方式 2：uvicorn dev 模式（零依赖，Python 直接跑）
            Write-Host "   Docker 未安装，用 uvicorn dev 模式启动..." -ForegroundColor Yellow
            
            # 确保 SQLite 目录存在
            $sqliteDir = "$BackendDir\sqlite"
            New-Item -ItemType Directory -Force -Path $sqliteDir | Out-Null
            
            # 后台启动，SQLite 存 D 盘
            $env:DATABASE_URL = "sqlite:///$sqliteDir\dev.db"
            $env:APP_ENV = "local"
            $env:LOG_DIR = "$BackendDir\logs"
            Start-Process -FilePath "python" -ArgumentList "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$LocalPort", "--reload" -WorkingDirectory $ProjectDir -WindowStyle Minimized
            
            Write-Host "   等待服务就绪..."
            Start-Sleep -Seconds 10
        }
        
        # 验证
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/healthz" -UseBasicParsing -TimeoutSec 5
            Write-Host "✅ 本地后端启动成功！" -ForegroundColor Green
            
            # dev 模式自动 seed（仅首次）
            try {
                $tok = python -c "from app.security import create_admin_token; print(create_admin_token('root'))" 2>$null
                if ($tok) {
                    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$LocalPort/admin/seed" -Headers @{Authorization="Bearer $($tok.Trim())"} -ErrorAction SilentlyContinue
                    Write-Host "🌱 Seed 初始化完成" -ForegroundColor Green
                }
            } catch { }
            
            return $true
        } catch {
            Write-Host "❌ 本地后端启动失败" -ForegroundColor Red
            Write-Host "   请手动启动："
            Write-Host "   cd $ProjectDir"
            Write-Host "   python -m uvicorn app.main:app --host 127.0.0.1 --port $LocalPort --reload"
            return $false
        }
    }
}

# =================================================================
# 选项 1：Cloudflare Tunnel
# =================================================================
function Setup-CloudflareTunnel {
    Write-Host "`n🔵 Cloudflare Tunnel 零成本方案" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Step 1: 安装 cloudflared
    $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cloudflared) {
        Write-Host "`n📦 安装 cloudflared..." -ForegroundColor Green
        
        # Windows: winget 或直接下载 exe
        $installed = $false
        try {
            winget install --id Cloudflare.cloudflared -e --accept-package-agreements --accept-source-agreements 2>$null
            $installed = $true
        } catch {
            $installed = $false
        }
        
        if (-not $installed) {
            # 手动下载
            $downloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
            $dest = "$env:USERPROFILE\cloudflared.exe"
            Write-Host "   下载 $downloadUrl ..."
            Invoke-WebRequest -Uri $downloadUrl -OutFile $dest -UseBasicParsing
            $env:PATH += ";$env:USERPROFILE"
            $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
        }
        
        if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
            Write-Host "❌ cloudflared 安装失败，请手动下载：" -ForegroundColor Red
            Write-Host "   https://github.com/cloudflare/cloudflared/releases"
            return
        }
        Write-Host "✅ cloudflared 已安装" -ForegroundColor Green
    }
    
    # Step 2: 登录 Cloudflare
    Write-Host "`n🔐 请在浏览器里登录 Cloudflare 账号..." -ForegroundColor Yellow
    Write-Host "   👉 如果没有 Cloudflare 账号，去 https://dash.cloudflare.com 注册（免费）"
    Write-Host "   👉 如果用自己的域名，把 DNS 托管到 Cloudflare"
    Write-Host "   👉 如果没有域名，Cloudflare Tunnel 会给一个 xxx.trycloudflare.com 的临时域名"
    Write-Host ""
    
    if ($Domain) {
        Write-Host "   你配置的域名: $Subdomain.$Domain"
        Write-Host "   👉 确保域名 DNS 已托管到 Cloudflare"
    } else {
        Write-Host "   未配置域名 → 将使用 trycloudflare.com 临时域名（每次重启变）"
        Write-Host "   👉 长期使用建议买个域名（¥50/年）+ Cloudflare DNS 托管"
    }
    
    # ⭐ 生成 tunnel 配置，存 D 盘
    $tunnelName = "retroemupouch"
    $configDir = $CfDir  # D:\RetroEmuPouch\tunnel\cloudflared
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    
    $configContent = @"
# RetroEmuPouch Account Backend — Cloudflare Tunnel 配置
# 存于 D:\RetroEmuPouch\tunnel\cloudflared\config.yml
tunnel: $tunnelName
credentials-file: $configDir\${tunnelName}.json

ingress:
  - hostname: $Subdomain.$Domain
    service: http://127.0.0.1:$LocalPort
  - service: http_status:404
"@
    
    # 没域名就用临时域名模式（不需要 config.yml）
    if (-not $Domain) {
        $configContent = ""  # 临时域名模式不需要配置文件
    } else {
        $configContent | Out-File -FilePath "$configDir\config.yml" -Encoding utf8
        Write-Host "✅ cloudflared 配置已写入 $configDir\config.yml" -ForegroundColor Green
    }
    
    # Step 3: 启动 tunnel
    Write-Host "`n🚀 启动 Cloudflare Tunnel..." -ForegroundColor Green
    
    if ($Domain) {
        # 有域名模式：需要先创建 tunnel + 登录
        Write-Host "`n📝 首次使用需要登录 Cloudflare：" -ForegroundColor Yellow
        Write-Host "   运行: cloudflared tunnel login"
        Write-Host "   然后: cloudflared tunnel create $tunnelName"
        Write-Host "   然后: cloudflared tunnel route dns $tunnelName $Subdomain.$Domain"
        Write-Host "   最后: cloudflared tunnel --config $configDir\config.yml run $tunnelName"
        Write-Host ""
        Write-Host "👉 或者直接在这个终端按 Enter，脚本帮你跑 cloudflared tunnel --url http://127.0.0.1:$LocalPort"
        Write-Host "   （临时域名模式，零配置）"
        $input = Read-Host "按 Enter 启动临时域名模式，或手动执行上面的域名模式命令"
        if (-not $input) {
            Write-Host "`n🚀 启动 cloudflared（临时域名模式）..." -ForegroundColor Green
            Write-Host "   按 Ctrl+C 停止" -ForegroundColor Yellow
            Write-Host ""
            # 存日志到 D 盘
            cloudflared tunnel --url "http://127.0.0.1:$LocalPort" --loglevel info --logfile "$CfDir\cloudflared.log"
        }
    } else {
        # 临时域名模式（零配置）
        Write-Host "`n🚀 启动 cloudflared（临时域名模式）..." -ForegroundColor Green
        Write-Host "   按 Ctrl+C 停止" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Host "   启动后会显示一个 https://xxxx.trycloudflare.com 地址"
        Write-Host "   把这个地址配到 App 里就能用了！"
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Host ""
        
        # 启动 tunnel（前台运行，按 Ctrl+C 停止）
        cloudflared tunnel --url "http://127.0.0.1:$LocalPort" --loglevel info --logfile "$CfDir\cloudflared.log"
    }
}

# =================================================================
# 选项 2：cpolar（国内节点）
# =================================================================
function Setup-Cpolar {
    Write-Host "`n🟢 cpolar 国内穿透方案（国内节点 + 速度快）" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Step 1: 检查/安装 cpolar
    $cpolar = Get-Command cpolar -ErrorAction SilentlyContinue
    if (-not $cpolar) {
        Write-Host "`n📦 安装 cpolar..." -ForegroundColor Green
        
        # 下载 Windows 版 cpolar
        $cpolarUrl = "https://www.cpolar.com/static/downloads/install-release-cpolar.exe"
        $installer = "$env:TEMP\install-cpolar.exe"
        
        try {
            Write-Host "   下载 $cpolarUrl ..."
            Invoke-WebRequest -Uri $cpolarUrl -OutFile $installer -UseBasicParsing
            Write-Host "   运行安装程序..."
            Start-Process -FilePath $installer -ArgumentList "/S" -Wait
            
            # 刷新 PATH
            $env:PATH = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            
            $cpolar = Get-Command cpolar -ErrorAction SilentlyContinue
            if (-not $cpolar) {
                # 手动添加路径
                $cpolarDir = "C:\Program Files\cpolar"
                if (Test-Path $cpolarDir) {
                    $env:PATH += ";$cpolarDir"
                }
            }
        } catch {
            Write-Host "❌ cpolar 安装失败: $_" -ForegroundColor Red
            Write-Host "   手动下载: https://www.cpolar.com/download"
            return
        }
    }
    
    if (-not (Get-Command cpolar -ErrorAction SilentlyContinue)) {
        Write-Host "❌ cpolar 未找到，请手动安装" -ForegroundColor Red
        return
    }
    Write-Host "✅ cpolar 已安装: $(& cpolar version)" -ForegroundColor Green
    
    # Step 2: 注册 + 获取 authtoken
    Write-Host "`n🔐 请先注册 cpolar 账号（免费）：" -ForegroundColor Yellow
    Write-Host "   👉 https://www.cpolar.com/user/signup"
    Write-Host "   👉 注册后登录 → 仪表盘 → 验证邮箱"
    Write-Host "   👉 左侧菜单「认证」→ 复制你的 authtoken"
    Write-Host ""
    
    $token = Read-Host "粘贴你的 cpolar authtoken（留空跳过，临时模式）"
    
    if ($token) {
        Write-Host "   配置 authtoken..."
        cpolar authtoken $token
        Write-Host "✅ authtoken 已配置" -ForegroundColor Green
    }
    
    # Step 3: 启动 HTTP 隧道
    Write-Host "`n🚀 启动 cpolar HTTP 隧道..." -ForegroundColor Green
    Write-Host "   转发: 公网 → http://127.0.0.1:$LocalPort"
    Write-Host "   按 Ctrl+C 停止" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host "   启动后会显示一个 https://xxxx.cpolar.top 地址"
    Write-Host "   把这个地址配到 App 里就能用了！"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host ""
    
    # 启动 cpolar（前台运行）
    cpolar http -region cn_vip $LocalPort
}

# =================================================================
# 入口
# =================================================================

Write-Host @"

╔══════════════════════════════════════════════════════════╗
║  RetroEmuPouch Account Backend —— 内网穿透一键脚本        ║
║  本地 Docker + Cloudflare Tunnel / cpolar                 ║
╚══════════════════════════════════════════════════════════╝

"@

# 1. 确保本地后端在跑
if (-not (Ensure-LocalBackend)) {
    Write-Host "`n❌ 本地后端未就绪，退出。" -ForegroundColor Red
    exit 1
}

# 2. 选穿透工具
if ($Provider -eq "cloudflare") {
    Setup-CloudflareTunnel
} elseif ($Provider -eq "cpolar") {
    Setup-Cpolar
}
