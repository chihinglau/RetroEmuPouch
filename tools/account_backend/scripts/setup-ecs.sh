#!/bin/bash
# =================================================================
# RetroEmuPouch Account Backend — ECS 初始化脚本
# 在 ECS 上直接跑: curl -sSL https://yourscript.url | bash
# 或: bash scripts/setup-ecs.sh
# =================================================================
set -e

echo "================================================"
echo "  RetroEmuPouch Account Backend — ECS Init"
echo "================================================"

# ── 检测系统 ──
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法检测操作系统"
    exit 1
fi

echo "🖥️  OS: $OS"

# ── 安装 Docker（国内 ECS 直接配置阿里云 Docker CE 镜像源）──
if command -v docker &> /dev/null; then
    echo "✅ Docker 已安装: $(docker --version)"
else
    echo "📦 安装 Docker（配置阿里云 Docker CE apt 源）..."
    # get.docker.com 在大陆 ECS 常被连接重置（curl 35）；--mirror 只改脚本内部 apt 源，
    # 脚本本身仍要从 get.docker.com 下载，因此改为直接配置阿里云镜像站的 Docker CE 仓库。
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL --retry 3 --retry-delay 2 \
        https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    ARCH="$(dpkg --print-architecture)"
    # 镜像站尚未同步当前 codename 时回退到 jammy，避免 apt update 404
    if ! curl -fsSL --max-time 15 \
        "https://mirrors.aliyun.com/docker-ce/linux/ubuntu/dists/${CODENAME}/Release" \
        -o /dev/null; then
        echo "⚠️  镜像站暂无 ${CODENAME} 目录，回退 jammy"
        CODENAME="jammy"
    fi
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    echo "✅ Docker 安装完成"
fi

# ── 校验 Docker Compose V2 ──
if docker compose version &> /dev/null; then
    echo "✅ Docker Compose: $(docker compose version)"
else
    # Ubuntu 24.04+ 受 PEP 668 限制，不能用 pip 全局安装旧的 docker-compose v1 兜底
    echo "❌ docker compose（V2 插件）不可用。请检查上方 docker-compose-plugin 是否装成功："
    echo "   apt-get update && apt-get install -y docker-compose-plugin"
    exit 1
fi

# ── Docker Hub 镜像加速（大陆 ECS 直连 registry-1.docker.io 会 i/o timeout）──
# 没有它，compose 里的 postgres:16-alpine / caddy:2-alpine 以及 Dockerfile.prod 的
# python:3.12-slim 都拉不下来。/v2/ 返回 401 是 registry 可达的正常表现。
if ! grep -q '"registry-mirrors"' /etc/docker/daemon.json 2>/dev/null; then
    echo "🔧 配置 Docker Hub 镜像加速..."
    mkdir -p /etc/docker
    if [ -s /etc/docker/daemon.json ]; then
        python3 -c 'import json; p="/etc/docker/daemon.json"; d=json.load(open(p)); d["registry-mirrors"]=["https://docker.m.daocloud.io","https://docker.1ms.run","https://hub.rat.dev"]; json.dump(d, open(p,"w"), indent=2)'
    else
        printf '%s\n' '{"registry-mirrors":["https://docker.m.daocloud.io","https://docker.1ms.run","https://hub.rat.dev"]}' > /etc/docker/daemon.json
    fi
    systemctl restart docker
    echo "✅ 镜像加速已生效"
else
    echo "✅ 镜像加速已配置（跳过）"
fi

# ── 基础工具 ──
echo "📦 安装基础工具..."
apt-get update -qq && apt-get install -y -qq git curl wget vim unzip htop net-tools

# ── 开放端口 ──
echo "🔓 开放防火墙端口 80/443..."
# 注意：Docker 发布的端口会绕过 ufw 规则，真正的端口隔离依赖阿里云安全组。
# 备案前联调走 Caddyfile.staging（纯 HTTP :80，compose 已映射 80:80），无需额外端口。
# 阿里云安全组也要手动放通！（ECS 控制台 → 安全组 → 添加入方向规则）
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp  || true
    ufw allow 443/tcp || true
    ufw allow 22/tcp  || true
    echo "✅ UFW 端口已开放"
fi

# ── 显示公网 IP ──
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ip.sb 2>/dev/null || echo "unknown")
echo ""
echo "================================================"
echo "  ✅ 初始化完成！"
echo "  📍 公网 IP: $PUBLIC_IP"
echo "  🐳 Docker: $(docker --version)"
echo "  🧩 Compose: $(docker compose version)"
echo ""
echo "  👉 阿里云控制台 → 安全组 → 添加入方向规则："
echo "     - 端口 80  / 协议 TCP / 来源 0.0.0.0/0"
echo "     - 端口 443 / 协议 TCP / 来源 0.0.0.0/0"
echo ""
echo "  👉 回到本地 Windows（在 tools\account_backend 目录下）执行："
printf '     $env:ECS_HOST="%s"\n' "$PUBLIC_IP"
echo '     $env:ECS_USER="root"'
echo '     $env:ECS_SSH_KEY="<本机私钥绝对路径>"'
echo ""
echo "  ⚠️  不要立刻 deploy：先做 D2（2G swap + 时区）与 E 阶段（.env.production），然后执行："
echo "     ./scripts/deploy.ps1 -Action deploy -Staging   # 备案前：Caddyfile.staging，纯 HTTP :80"
echo "     ./scripts/deploy.ps1 -Action deploy -Domain <主域>   # 备案后：自动 HTTPS"
echo "================================================"
