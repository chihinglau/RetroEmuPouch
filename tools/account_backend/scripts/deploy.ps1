# =================================================================
# RetroEmuPouch Account Backend — 一键部署到阿里云 ECS
# 用法（PowerShell）：
#   $env:ECS_HOST="你的ECS公网IP"
#   $env:ECS_USER="root"
#   ./scripts/deploy.ps1
# =================================================================

param(
    [string]$EcsHost = $env:ECS_HOST,
    [string]$EcsUser = $env:ECS_USER ?? "root",
    [string]$SshKey  = $env:ECS_SSH_KEY,   # 可选，没配就用密码
    [string]$Domain  = $env:ECS_DOMAIN,   # 域名（可选，没有就先用 IP）
    [string]$Action  = "deploy"           # deploy | setup | seed | logs | stop | update
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot

# ── 检查前置 ──
if (-not $EcsHost) {
    Write-Host "❌ 请先设置 ECS_HOST: `$env:ECS_HOST='你的公网IP'" -ForegroundColor Red
    exit 1
}

$sshCmd  = if ($SshKey) { "ssh -i `"$SshKey`" $EcsUser@$EcsHost" } else { "ssh $EcsUser@$EcsHost" }
$scpCmd  = if ($SshKey) { "scp -i `"$SshKey`"" } else { "scp" }

Write-Host "`n🎯 目标: $EcsUser@$EcsHost" -ForegroundColor Cyan

# =================================================================
# 动作分发
# =================================================================

switch ($Action) {

    # ── 1. 首次部署（在 ECS 上装 Docker + 上传代码 + 启动）──
    "setup" {
        Write-Host "`n📦 Step 1: 初始化 ECS（安装 Docker + Docker Compose）" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"curl -fsSL https://get.docker.com | sh && systemctl enable --now docker && docker plugin install grafana/loki-docker-driver:latest --alias loki --grant-all-permissions || true`""
        Invoke-Expression "$sshCmd `"apt-get update && apt-get install -y git curl`""
        Write-Host "✅ Docker 安装完成" -ForegroundColor Green
        Write-Host "👉 下一步: ./deploy.ps1 -Action deploy" -ForegroundColor Yellow
    }

    # ── 2. 上传 + 启动 ──
    "deploy" {
        # 2a. 本地检查 .env.production
        $envFile = "$ProjectDir\.env.production"
        if (-not (Test-Path $envFile)) {
            Write-Host "⚠️  .env.production 不存在，从 .env.production.example 复制一份" -ForegroundColor Yellow
            Copy-Item "$ProjectDir\.env.production.example" $envFile
            Write-Host "👉 编辑 $envFile 填入真实密码/密钥后再跑一次 deploy" -ForegroundColor Yellow
            Write-Host "👉 生成随机密钥: python -c `"import secrets; print(secrets.token_urlsafe(48))`"" -ForegroundColor Yellow
            exit 0
        }

        # 2b. 检查是否改过 Caddyfile.prod 里的域名
        $caddyContent = Get-Content "$ProjectDir\Caddyfile.prod" -Raw
        if ($caddyContent -match "yourdomain\.com") {
            Write-Host "⚠️  Caddyfile.prod 里还是 yourdomain.com，先用 IP 部署的话需要注释掉 HTTPS 段" -ForegroundColor Yellow
            Write-Host "👉 要么买域名改 Caddyfile.prod，要么先用 HTTP 模式测试" -ForegroundColor Yellow
        }

        # 2c. 在 ECS 上创建目录
        Write-Host "`n📁 Step 2: 创建远程目录" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"mkdir -p /opt/retroemupouch-account/scripts`""

        # 2d. 上传（用 .dockerignore 排除无关文件）
        Write-Host "`n📤 Step 3: 上传代码到 ECS" -ForegroundColor Green
        $files = @(
            "Dockerfile.prod",
            "docker-compose.prod.yml",
            "Caddyfile.prod",
            ".env.production",
            "requirements.txt",
            "alembic.ini",
            "app/",
            "alembic/",
            "scripts/db-init/"
        )
        foreach ($f in $files) {
            Write-Host "   → $f"
            Invoke-Expression "$scpCmd -r `"$ProjectDir\$f`" $EcsUser@${EcsHost}:/opt/retroemupouch-account/" 2>$null
        }
        Write-Host "✅ 上传完成" -ForegroundColor Green

        # 2e. 替换 Caddyfile 里的域名（如果提供了 -Domain 参数）
        if ($Domain) {
            Write-Host "`n🌐 Step 4: 替换域名为 $Domain" -ForegroundColor Green
            Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && sed -i 's/yourdomain.com/$Domain/g' Caddyfile.prod`""
        }

        # 2f. 构建 + 启动
        Write-Host "`n🚀 Step 5: Docker Compose 构建 + 启动" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml up -d --build`""

        # 2g. 等服务就绪 + Alembic 迁移 + seed
        Write-Host "`n⏳ Step 6: 等待服务就绪..." -ForegroundColor Green
        Start-Sleep -Seconds 15
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml ps`""

        # 2h. Alembic 自动迁移
        Write-Host "`n🗄️  Step 7: Alembic 数据库迁移" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml exec app alembic upgrade head`""

        Write-Host "`n✅ 部署完成！" -ForegroundColor Green
        if ($Domain) {
            Write-Host "🌐 访问: https://api.$Domain/docs" -ForegroundColor Cyan
        } else {
            Write-Host "🌐 访问: http://$EcsHost:8000/docs" -ForegroundColor Cyan
        }
        Write-Host "👉 还需要 seed 初始化 CMS: ./deploy.ps1 -Action seed" -ForegroundColor Yellow
    }

    # ── 3. Seed 初始化数据 ──
    "seed" {
        Write-Host "`n🌱 Seed 初始化..." -ForegroundColor Green
        $token = Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml exec -T app python -c `"from app.security import create_admin_token; print(create_admin_token('root'))`"`""
        $token = $token.Trim()
        Write-Host "Admin token: $token"
        Invoke-Expression "$sshCmd `"curl -s -X POST http://localhost:8000/admin/seed -H 'Authorization: Bearer $token' -H 'Content-Type: application/json'`""
        Write-Host "✅ Seed 完成" -ForegroundColor Green
    }

    # ── 4. 查看日志 ──
    "logs" {
        $svc = if ($args.Count -gt 0) { $args[0] } else { "app" }
        Write-Host "`n📜 查看 $svc 日志（Ctrl+C 退出）" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml logs -f $svc`""
    }

    # ── 5. 停止 ──
    "stop" {
        Write-Host "`n🛑 停止服务" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml down`""
    }

    # ── 6. 仅更新代码（快速迭代，跳过 Docker 重装）──
    "update" {
        Write-Host "`n🔄 更新代码 + 重建镜像（数据库不动）" -ForegroundColor Green
        Invoke-Expression "$sshCmd `"mkdir -p /opt/retroemupouch-account/scripts`""
        $files = @("Dockerfile.prod","docker-compose.prod.yml","Caddyfile.prod","requirements.txt","alembic.ini","app/","alembic/")
        foreach ($f in $files) {
            Invoke-Expression "$scpCmd -r `"$ProjectDir\$f`" $EcsUser@${EcsHost}:/opt/retroemupouch-account/" 2>$null
        }
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml up -d --build app`""
        # Alembic 迁移
        Invoke-Expression "$sshCmd `"cd /opt/retroemupouch-account && docker compose -f docker-compose.prod.yml exec app alembic upgrade head`""
        Write-Host "✅ 更新完成" -ForegroundColor Green
    }

    default {
        Write-Host "❌ 未知动作: $Action" -ForegroundColor Red
        Write-Host "可用: setup | deploy | seed | logs | stop | update" -ForegroundColor Yellow
    }
}
