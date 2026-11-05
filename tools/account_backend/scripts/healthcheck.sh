#!/bin/bash
# =================================================================
# 轻量探活（cron 每 10 分钟跑一次）
#   * 成功：仅整点记一条 "ok"，避免日志膨胀；
#   * 失败：记一条 FAIL + 状态码；
#   * 不自动重启服务（restart: always 已由 docker 负责），避免掩盖真实故障。
# 查看：tail -f /var/log/gp-health.log
# =================================================================
set -uo pipefail

LOG=/var/log/gp-health.log
URL=${1:-http://127.0.0.1/healthz}
TS=$(date '+%F %T')

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null) || code=000

if [ "$code" = "200" ]; then
    if [ "$(date +%M)" = "00" ]; then
        echo "[$TS] ok 200" >>"$LOG"
    fi
else
    echo "[$TS] FAIL code=$code url=$URL" >>"$LOG"
fi
