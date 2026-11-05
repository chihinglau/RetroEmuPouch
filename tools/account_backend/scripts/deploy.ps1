# =================================================================
# RetroEmuPouch Account Backend — 一键部署到阿里云 ECS
# 用法（PowerShell，环境变量仅当前会话有效）：
#   $env:ECS_HOST="你的ECS公网IP"
#   $env:ECS_USER="root"
#   $env:ECS_SSH_KEY="C:\Users\<你>\.ssh\id_ecs99"   # 私钥绝对路径
#   $env:ECS_DOMAIN="gamepouch.cn"                    # 只传主域，不要传 api.gamepouch.cn
#   ./scripts/deploy.ps1 -Action setup    # 动作：setup / deploy / seed / logs / stop / update
#   ./scripts/deploy.ps1 -Action logs -Service caddy
#
# -Action update 只替换 app 代码并重建镜像（Caddyfile / compose / 环境变量一律不动），
# 适合日常发版；改动 Caddy 或 compose 必须用 -Action deploy（备案前记得加 -Staging）。
#
# 顺序：setup → deploy → seed
# 备案前（域名未解析，ACME 必然失败）：加 -Staging 走纯 HTTP IP 直连
#   ./scripts/deploy.ps1 -Action deploy -Staging
#   ./scripts/deploy.ps1 -Action seed
#   访问 http://<ECS公网IP>/healthz
# 首次连接自动接受新主机并写入 known_hosts（已变更主机仍会拒绝，比 =no 安全）
# =================================================================

param(
    [string]$EcsHost = $env:ECS_HOST,
    [string]$EcsUser = $env:ECS_USER,
    [string]$SshKey  = $env:ECS_SSH_KEY,
    [string]$Domain  = $env:ECS_DOMAIN,
    [string]$Action  = "deploy",          # setup | deploy | seed | logs | stop | update
    [string]$Service = "app",             # -Action logs -Service caddy 时查看的服务名
    [switch]$Staging                      # 备案前：上传 Caddyfile.staging（纯 HTTP、无域名，不触发 ACME）
)

# 不用 PS7 的 ?? 运算符，保证 Windows PowerShell 5.1 也能运行
if (-not $EcsUser) { $EcsUser = "root" }

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$RemoteDir  = "/opt/retroemupouch-account"
$SshOpts    = @("-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes")

# 备案前用 Caddyfile.staging（:80 纯 HTTP、无域名站点），但远程文件名统一叫
# Caddyfile.prod，compose 的挂载路径不必改；备案通过后去掉 -Staging 即可切回自动 HTTPS。
$CaddyLocal = if ($Staging) { "Caddyfile.staging" } else { "Caddyfile.prod" }

if (-not $EcsHost) {
    Write-Host "❌ 请先设置 ECS_HOST: `$env:ECS_HOST='你的公网IP'" -ForegroundColor Red
    exit 1
}

# 用参数数组调用 ssh/scp，避免 Invoke-Expression 多层引号嵌套与错误被吞
function Invoke-Remote([string]$Command) {
    $target = "$EcsUser@$EcsHost"
    if ($SshKey) {
        & ssh -i $SshKey @SshOpts $target $Command
    } else {
        & ssh @SshOpts $target $Command
    }
    if ($LASTEXITCODE -ne 0) { throw "远程命令失败 (exit=$LASTEXITCODE): $Command" }
}

function Copy-ToRemote([string]$LocalPath, [string]$RemotePath) {
    $target = "$EcsUser@${EcsHost}:$RemotePath"
    if ($SshKey) {
        & scp -r -i $SshKey @SshOpts $LocalPath $target
    } else {
        & scp -r @SshOpts $LocalPath $target
    }
    if ($LASTEXITCODE -ne 0) { throw "上传失败: $LocalPath -> $RemotePath" }
}

Write-Host "`n🎯 目标: $EcsUser@$EcsHost" -ForegroundColor Cyan

switch ($Action) {

    # ── 1. 首次部署：上传并执行 ECS 初始化脚本 ──
    "setup" {
        Write-Host "`n📦 Step 1: 初始化 ECS（上传 scripts/setup-ecs.sh）" -ForegroundColor Green
        Invoke-Remote "mkdir -p $RemoteDir/scripts"
        Copy-ToRemote "$ProjectDir\scripts\setup-ecs.sh" "/tmp/setup-ecs.sh"
        Invoke-Remote "chmod +x /tmp/setup-ecs.sh && bash /tmp/setup-ecs.sh"

        # D3 + J1：部署目录收紧到 700、建备份目录、装每日 pg_dump 定时任务
        Write-Host "`n🔐 Step 2: 目录权限 + 每日备份定时任务" -ForegroundColor Green
        Copy-ToRemote "$ProjectDir\scripts\backup-db.sh" "/tmp/backup-db.sh"
        Invoke-Remote "install -m 755 /tmp/backup-db.sh $RemoteDir/scripts/backup-db.sh && mkdir -p /opt/backups && chmod 700 $RemoteDir /opt/backups"
        # 幂等：先剔除旧的 backup-db.sh 行再追加（crontab 里 % 需转义，本文件不含 %）
        Invoke-Remote "crontab -l 2>/dev/null | grep -v backup-db.sh > /tmp/gp_cron || true; echo '15 3 * * * $RemoteDir/scripts/backup-db.sh >> /var/log/gp-backup.log 2>&1' >> /tmp/gp_cron; crontab /tmp/gp_cron && rm -f /tmp/gp_cron"
        Invoke-Remote "crontab -l | grep backup-db.sh"

        # H2 冒烟脚本：装到远端，随时 `scripts/smoke.sh http://127.0.0.1` 回归
        Copy-ToRemote "$ProjectDir\scripts\smoke.sh" "/tmp/smoke.sh"
        Invoke-Remote "install -m 755 /tmp/smoke.sh $RemoteDir/scripts/smoke.sh"

        # J2 探活 + 磁盘清理：healthcheck 每 10 分钟（失败才写日志），每周日清一次悬空镜像
        Copy-ToRemote "$ProjectDir\scripts\healthcheck.sh" "/tmp/healthcheck.sh"
        Invoke-Remote "install -m 755 /tmp/healthcheck.sh $RemoteDir/scripts/healthcheck.sh && touch /var/log/gp-health.log && chmod 644 /var/log/gp-health.log"
        Invoke-Remote "crontab -l 2>/dev/null | grep -v -e healthcheck.sh -e 'docker system prune' > /tmp/gp_cron || true; echo '*/10 * * * * $RemoteDir/scripts/healthcheck.sh >/dev/null 2>&1' >> /tmp/gp_cron; echo '30 4 * * 0 docker system prune -af --filter until=168h >> /var/log/gp-docker-prune.log 2>&1' >> /tmp/gp_cron; crontab /tmp/gp_cron && rm -f /tmp/gp_cron"
        Invoke-Remote "crontab -l | grep -e healthcheck.sh -e prune"
        Write-Host "✅ ECS 初始化完成" -ForegroundColor Green
        Write-Host "👉 下一步（备案前）: ./deploy.ps1 -Action deploy -Staging" -ForegroundColor Yellow
        Write-Host "👉 下一步（备案后）: ./deploy.ps1 -Action deploy -Domain <主域>" -ForegroundColor Yellow
    }

    # ── 2. 上传 + 启动 ──
    "deploy" {
        # 2a. 本地检查 .env.production
        $envFile = "$ProjectDir\.env.production"
        if (-not (Test-Path $envFile)) {
            Write-Host "⚠️  .env.production 不存在，从模板复制一份" -ForegroundColor Yellow
            Copy-Item "$ProjectDir\.env.production.example" $envFile
            Write-Host "👉 编辑 $envFile 填入真实密码/密钥（含 ADMIN_WEB_PASSWORD）后再跑一次 deploy" -ForegroundColor Yellow
            Write-Host "👉 生成随机密钥: python -c `"import secrets; print(secrets.token_urlsafe(48))`"" -ForegroundColor Yellow
            exit 0
        }
        if ((Get-Content $envFile -Raw) -match "CHANGE_ME") {
            Write-Host "❌ .env.production 里仍有 CHANGE_ME 占位值，请先填完真实 secrets" -ForegroundColor Red
            exit 1
        }

        # 2b. 域名参数校验：-Domain 只接受主域
        if ($Domain -and $Domain -match "^api\.") {
            Write-Host "❌ -Domain 只传主域（如 gamepouch.cn），传 api.gamepouch.cn 会拼成 api.api.*" -ForegroundColor Red
            exit 1
        }

        # 2c. 远程目录（scripts/ 必须存在，compose 挂载 ./scripts/db-init）
        Write-Host "`n📁 Step 2: 创建远程目录" -ForegroundColor Green
        Invoke-Remote "mkdir -p $RemoteDir/scripts"

        # 2d. 上传根目录文件（Caddyfile 按 -Staging 选择源文件，远程仍叫 Caddyfile.prod）
        Write-Host "`n📤 Step 3: 上传代码到 ECS" -ForegroundColor Green
        if ($Staging) {
            Write-Host "   🅿️  Staging 模式：使用 $CaddyLocal（纯 HTTP :80，不触发 ACME）" -ForegroundColor Yellow
        }
        $files = @(
            "Dockerfile.prod",
            "docker-compose.prod.yml",
            ".env.production",
            "requirements.txt",
            "alembic.ini",
            "app/",
            "alembic/"
        )
        foreach ($f in $files) {
            Write-Host "   → $f"
            Copy-ToRemote "$ProjectDir\$f" "$RemoteDir/"
        }
        Write-Host "   → $CaddyLocal (as Caddyfile.prod)"
        Copy-ToRemote "$ProjectDir\$CaddyLocal" "$RemoteDir/Caddyfile.prod"
        # db-init 必须落到 scripts/ 下，否则 compose 的 ./scripts/db-init 挂载为空，pgcrypto 扩展不会创建
        Write-Host "   → scripts/db-init/"
        Copy-ToRemote "$ProjectDir\scripts\db-init" "$RemoteDir/scripts/"
        Invoke-Remote "chmod 600 $RemoteDir/.env.production"
        # Compose 的 ${DB_PASSWORD} 插值只认 shell 环境 / ./.env，不读 env_file 指定的
        # .env.production；从上传好的文件里抽一行生成 .env（密钥不出远端、不回显）。
        Invoke-Remote "cd $RemoteDir && grep '^DB_PASSWORD=' .env.production > .env && chmod 600 .env"
        Write-Host "✅ 上传完成" -ForegroundColor Green

        # 2e. 替换域名：Caddyfile 与 .env.production 的 APP_CORS_ORIGINS 都要改
        if ($Staging) {
            Write-Host "`n🌐 Step 4: Staging 模式，跳过域名替换（Caddy 只监听 :80，无域名站点）" -ForegroundColor Yellow
            Write-Host "   .env.production 中的 APP_CORS_ORIGINS 仍按备案后域名保留，客户端用 IP 直连时可临时放宽" -ForegroundColor DarkGray
        }
        elseif ($Domain) {
            Write-Host "`n🌐 Step 4: 替换域名为 $Domain" -ForegroundColor Green
            Invoke-Remote "cd $RemoteDir && sed -i 's/yourdomain.com/$Domain/g' Caddyfile.prod .env.production"
        } else {
            Write-Host "⚠️  未提供 -Domain，Caddyfile.prod 仍是 yourdomain.com；备案前请加 -Staging 用 HTTP 临时站点联调" -ForegroundColor Yellow
        }

        # 2f. 构建 + 启动
        Write-Host "`n🚀 Step 5: Docker Compose 构建 + 启动" -ForegroundColor Green
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml up -d --build"

        # 先校验 Caddyfile，避免配置写错导致 caddy 容器反复重启（日志里只有 exit 1，很难定位）
        try {
            Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile"
        } catch {
            Write-Host "❌ Caddyfile 校验失败（见上方输出），已中止部署；修复 $CaddyLocal 后重试" -ForegroundColor Red
            Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml logs --tail 40 caddy"
            exit 1
        }

        # Caddyfile 是挂载文件，compose 不会因文件内容变化自动重建容器 → 显式重启 caddy 让新配置生效
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml restart caddy"

        # 2g. 等待服务就绪
        Write-Host "`n⏳ Step 6: 等待服务就绪..." -ForegroundColor Green
        Start-Sleep -Seconds 15
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml ps"

        # 2h. Alembic 迁移（非交互 SSH 必须加 -T）
        Write-Host "`n🗄️  Step 7: Alembic 数据库迁移" -ForegroundColor Green
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml exec -T app alembic upgrade head"

        # 2i. Staging 下做一次真实 HTTP 联通性自检（失败只告警，不中断部署）
        if ($Staging) {
            Write-Host "`n🔎 Step 8: 健康检查 http://127.0.0.1/healthz" -ForegroundColor Green
            try {
                Invoke-Remote "curl -fsS --max-time 10 http://127.0.0.1/healthz"
            } catch {
                Write-Host "⚠️  本机 HTTP 自检失败：检查 caddy 日志 ./deploy.ps1 -Action logs -Service caddy" -ForegroundColor Yellow
            }
        }

        Write-Host "`n✅ 部署完成！" -ForegroundColor Green
        Write-Host "👉 还需要 seed 初始化 CMS/AppConfig: ./deploy.ps1 -Action seed" -ForegroundColor Yellow
        if ($Staging) {
            Write-Host "🌐 备案前访问: http://$EcsHost/healthz （IP 直连，请确认安全组已放行 80 端口）" -ForegroundColor Cyan
            Write-Host "🌐 备案通过后带 -Domain 且去掉 -Staging 重新 deploy，即可切回 api.<域名> 自动证书" -ForegroundColor DarkGray
        }
        elseif ($Domain) {
            Write-Host "🌐 访问: https://api.$Domain/healthz" -ForegroundColor Cyan
        }
        else {
            Write-Host "🌐 访问: 在 ECS 上 curl http://127.0.0.1/healthz （Caddy 监听 80/443）" -ForegroundColor Cyan
        }
    }

    # ── 3. Seed：走 app/cli_seed.py 直接调 seed 服务 ──
    # 不用 python -c "..."：PowerShell → ssh → bash 会吞掉内层双引号，远程必报 syntax error
    "seed" {
        Write-Host "`n🌱 Seed 初始化（容器内执行）..." -ForegroundColor Green
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml exec -T app python -m app.cli_seed"
        Write-Host "✅ Seed 完成" -ForegroundColor Green
    }

    # ── 4. 查看日志 ──
    "logs" {
        $svc = $Service
        Write-Host "`n📜 查看 $svc 日志（Ctrl+C 退出）" -ForegroundColor Cyan
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml logs -f $svc"
    }

    # ── 5. 停止 ──
    "stop" {
        Write-Host "`n🛑 停止服务" -ForegroundColor Yellow
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml down"
    }

    # ── 6. 仅更新代码（数据库 / Caddy / compose 一律不动）──
    "update" {
        Write-Host "`n🔄 更新代码 + 重建镜像（数据库与 Caddy 配置不动）" -ForegroundColor Green
        Invoke-Remote "mkdir -p $RemoteDir/scripts"
        $files = @("Dockerfile.prod","requirements.txt","alembic.ini","app/","alembic/")
        foreach ($f in $files) {
            Copy-ToRemote "$ProjectDir\$f" "$RemoteDir/"
        }
        # 故意不覆盖 Caddyfile.prod：备案前远端跑的是 Caddyfile.staging（纯 HTTP :80）。
        # 若这里无条件上传 Caddyfile.prod（HTTPS 站点 + 自动 ACME），Caddy 会整站 308 跳
        # https://<未解析域名>，线上直接不可用（2026-11-05 踩过）。
        # Caddy / compose / 环境变量的改动一律走 -Action deploy，并显式带 -Staging 或 -Domain。
        Write-Host "   （跳过 Caddyfile.prod / docker-compose.prod.yml —— 如需改动请用 -Action deploy）" -ForegroundColor DarkGray
        # 保证 ${DB_PASSWORD} 插值所需的 ./.env 存在（首次 update / 换过密钥都适用）
        Invoke-Remote "cd $RemoteDir && grep '^DB_PASSWORD=' .env.production > .env && chmod 600 .env"
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml up -d --build app"
        Invoke-Remote "cd $RemoteDir && docker compose -f docker-compose.prod.yml exec -T app alembic upgrade head"
        Write-Host "✅ 更新完成" -ForegroundColor Green
    }

    default {
        Write-Host "❌ 未知动作: $Action" -ForegroundColor Red
        Write-Host "可用: setup | deploy | seed | logs | stop | update" -ForegroundColor Yellow
    }
}
