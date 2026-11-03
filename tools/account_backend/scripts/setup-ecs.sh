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

# ── 安装 Docker ──
if command -v docker &> /dev/null; then
    echo "✅ Docker 已安装: $(docker --version)"
else
    echo "📦 安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "✅ Docker 安装完成"
fi

# ── 安装 Docker Compose V2 ──
if docker compose version &> /dev/null; then
    echo "✅ Docker Compose: $(docker compose version)"
else
    echo "📦 安装 Docker Compose..."
    apt-get install -y docker-compose-plugin 2>/dev/null || \
        pip install docker-compose
    echo "✅ Docker Compose 安装完成"
fi

# ── 基础工具 ──
echo "📦 安装基础工具..."
apt-get update -qq && apt-get install -y -qq git curl wget vim unzip htop net-tools

# ── 开放端口 ──
echo "🔓 开放防火墙端口 80/443..."
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
echo "  👉 回到本地 Windows 执行:"
echo '     $env:ECS_HOST="' + $PUBLIC_IP + '"'
echo "     ./scripts/deploy.ps1 -Action deploy"
echo "================================================"
