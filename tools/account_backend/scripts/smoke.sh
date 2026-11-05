#!/bin/bash
# =================================================================
# RetroEmuPouch Account Backend — H2 端点回归（在 ECS 宿主机执行）
# 用法：scripts/smoke.sh [base_url]      默认 http://127.0.0.1
# 说明：会注册一个 smoke_<ts>@example.com 临时账号 + 一个 smoke-<ts> 设备，
#       跑完 DELETE /api/auth/me 并清掉本次的 consent_records，不留测试数据。
#       云存档需要付费档，这里只验证"未解锁时被 403 拦下"的闸门行为。
# =================================================================
set -uo pipefail

BASE=${1:-http://127.0.0.1}
APP_DIR=/opt/retroemupouch-account
ENV_FILE=$APP_DIR/.env.production
PASS=0
FAIL=0
BODY=/tmp/gp_smoke_body

# 每次跑用唯一 device_id，便于精确清理 consent_records（存的是 sha256(device+salt)）
DEVICE="smoke-$(date +%s)"
DEV_HASH=""
if [ -r "$ENV_FILE" ]; then
    SALT=$(grep '^DEVICE_ID_SALT=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r' || true)
    if [ -n "${SALT:-}" ]; then
        DEV_HASH=$(printf '%s' "$DEVICE$SALT" | sha256sum | cut -d' ' -f1)
    fi
fi

ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
no() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

code() { curl -s -o "$BODY" -w '%{http_code}' --max-time 10 "$@"; }

expect() { # expect <期望码> <描述> <curl 参数...>
    local want=$1 desc=$2
    shift 2
    local got
    got=$(code "$@")
    if [ "$got" = "$want" ]; then
        ok "$desc ($got)"
    else
        no "$desc (want $want got $got): $(head -c 160 "$BODY")"
    fi
}

jget() { # jget <key> [key...] —— 逐层取 JSON 字段
    python3 - "$@" <<'PY'
import json, sys
try:
    d = json.load(open("/tmp/gp_smoke_body"))
except Exception:
    print("")
    raise SystemExit
for k in sys.argv[1:]:
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)
PY
}

echo "== 公开端点（$BASE）=="
for p in /healthz /api/cms/config /privacy /terms /docs /admin/ui/login \
         /api/cms/docs/privacy_policy /api/cms/doc-meta/privacy_policy; do
    expect 200 "GET $p" "$BASE$p"
done
expect 404 "GET /api/cms/docs/not_exists" "$BASE/api/cms/docs/not_exists"

echo "== 账号 / 权益 / 配对 =="
EMAIL="smoke_$(date +%s)@example.com"
PASSWD=SmokePass123
expect 201 "POST /api/auth/register" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWD\",\"display_name\":\"Smoke\"}" \
    "$BASE/api/auth/register"
AT=$(jget access_token)
RT=$(jget refresh_token)
if [ -n "$AT" ]; then ok "拿到 access_token"; else no "access_token 为空"; fi
AUTH="Authorization: Bearer $AT"

expect 200 "GET /api/auth/me" -H "$AUTH" "$BASE/api/auth/me"
expect 200 "POST /api/auth/refresh" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"refresh_token\":\"$RT\"}" "$BASE/api/auth/refresh"
expect 200 "GET /api/billing/entitlement" -H "$AUTH" "$BASE/api/billing/entitlement"
expect 200 "POST /api/billing/trial/start" -X POST -H "$AUTH" "$BASE/api/billing/trial/start"
expect 200 "POST /api/pairing/register" \
    -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{"code":"SMOKE-CODE-123456","pc_name":"smoke-pc","pc_mac_hash":"00112233445566778899aabbccddeeff"}' \
    "$BASE/api/pairing/register"
expect 200 "GET /api/pairing/list" -H "$AUTH" "$BASE/api/pairing/list"
expect 403 "云存档闸门 GET /api/cloud/saves/list（free 档应 403）" \
    -H "$AUTH" "$BASE/api/cloud/saves/list"
got=$(code -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{"platform":"google_play","sku":"premium_monthly","purchase_token":"x"}' \
    "$BASE/api/billing/verify")
if [ "$got" = 200 ] && grep -q '"ok":false' "$BODY"; then
    ok "POST /api/billing/verify（prod 禁 dev mock → 200 + ok=false）"
else
    no "POST /api/billing/verify（want 200 + ok=false, got $got）: $(head -c 160 "$BODY")"
fi

echo "== 同意管理 =="
expect 200 "GET /api/consent/status" -H "X-Device-Id: $DEVICE" "$BASE/api/consent/status"
expect 200 "GET /api/cms/doc-meta/privacy_policy" "$BASE/api/cms/doc-meta/privacy_policy"
VER=$(jget latest_published_version)
expect 200 "POST /api/consent/accept (v$VER)" \
    -X POST -H 'Content-Type: application/json' -H "X-Device-Id: $DEVICE" \
    -d "{\"doc_key\":\"privacy_policy\",\"version\":$VER,\"device_id\":\"$DEVICE\"}" \
    "$BASE/api/consent/accept"

echo "== 改密 / 清理 =="
NEWPWD=SmokePass456
expect 200 "POST /api/auth/change-password" \
    -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{\"old_password\":\"$PASSWD\",\"new_password\":\"$NEWPWD\"}" \
    "$BASE/api/auth/change-password"
expect 200 "POST /api/auth/login（新密码）" \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$NEWPWD\"}" "$BASE/api/auth/login"
AT=$(jget access_token)
expect 200 "DELETE /api/auth/me（删除临时账号）" -X DELETE -H "Authorization: Bearer $AT" \
    "$BASE/api/auth/me"

# 匿名同意记录不随删号级联（user_id 为 NULL），按本次 device hash 精确清理
if [ -n "$DEV_HASH" ] && [ -r "$APP_DIR/docker-compose.prod.yml" ]; then
    if ( cd "$APP_DIR" && docker compose -f docker-compose.prod.yml exec -T db \
        psql -U retroemupouch -d retroemupouch \
        -c "delete from consent_records where device_id = '$DEV_HASH'" >/dev/null ); then
        ok "清理本次 consent_records（device=$DEVICE）"
    else
        no "清理 consent_records 失败（device=$DEVICE）"
    fi
fi

echo "== 运营后台（11 页，需 ADMIN_WEB_PASSWORD）=="
JAR=/tmp/gp_smoke_cookie
PW_FILE=/tmp/gp_smoke_pw
rm -f "$JAR" "$PW_FILE"
if [ -r "$ENV_FILE" ]; then
    # .env.production 可能是 CRLF（Windows 写入），必须去掉 \r 否则口令比对失败 401
    printf '%s' "$(grep '^ADMIN_WEB_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r')" > "$PW_FILE"
    chmod 600 "$PW_FILE"
    # 未登录应 303 跳登录页
    expect 303 "GET /admin/ui/users（未登录 → 303）" "$BASE/admin/ui/users"
    # 用 --data-urlencode @file 传口令，避免出现在 ps / shell history
    got=$(curl -s -o "$BODY" -w '%{http_code}' --max-time 10 -c "$JAR" -X POST \
        --data-urlencode "password@$PW_FILE" "$BASE/admin/ui/login")
    if [ "$got" = 303 ]; then ok "POST /admin/ui/login（303 + 种 cookie）"; else no "POST /admin/ui/login（want 303 got $got）"; fi
    for p in / /users /entitlements /cloud-saves /pairings /consents /billing /audit /cms /config; do
        expect 200 "GET /admin/ui$p（已登录）" -b "$JAR" "$BASE/admin/ui$p"
    done
    rm -f "$JAR" "$PW_FILE"
else
    no "读不到 $ENV_FILE，跳过后台页面校验"
fi

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
