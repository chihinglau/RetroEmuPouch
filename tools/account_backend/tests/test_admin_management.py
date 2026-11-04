"""后台管理功能自测（无需 pytest，直接 `python tests/test_admin_management.py`）。

覆盖：登录鉴权、全部页面渲染、用户 CRUD、禁用生效、权益授予/撤销/试用、
云存档与配对删除、CMS/AppConfig 编辑、Admin JSON API、审计留痕。
使用临时 SQLite，不触碰真实数据库。
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]  # tools/account_backend
sys.path.insert(0, str(_ROOT))

_DB = Path(tempfile.gettempdir()) / "retroemupouch_admin_management_test.db"
if _DB.exists():
    _DB.unlink()
os.environ["DATABASE_URL"] = "sqlite:///" + _DB.as_posix()
os.environ["ADMIN_WEB_PASSWORD"] = "test-admin-pw"
os.environ["APP_ENV"] = "dev"

from fastapi.testclient import TestClient  # noqa: E402

from app import models  # noqa: E402,F401
from app.database import Base, SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import (  # noqa: E402
    BillingTransaction,
    CloudSaveBlob,
    CmsDocument,
    ConsentRecord,
    PcPairing,
    User,
)
from app.security import create_access_token, create_admin_token, verify_password  # noqa: E402
from app.services import auth_service, seed  # noqa: E402
from app.services.schema_bootstrap import ensure_runtime_schema  # noqa: E402

PASS: list[str] = []


def check(label: str, cond: bool, extra: str = "") -> None:
    if not cond:
        raise AssertionError(f"FAILED: {label} {extra}")
    PASS.append(label)
    print(f"  ok  {label}")


def prepare() -> dict:
    Base.metadata.create_all(engine)
    ensure_runtime_schema(engine)
    db = SessionLocal()
    seed.run_seed(db)

    u1 = auth_service.register(db, "ops1@example.com", "Passw0rd!1", "运维甲")
    u2 = auth_service.register(db, "ops2@example.com", "Passw0rd!2", "运维乙")
    uid1, uid2 = u1.id, u2.id

    blob = CloudSaveBlob(
        user_id=uid1, save_name="slot1.sav", client_key_hash="h" * 64,
        encrypted_blob=b"cipher-text-not-decrypted", sha256="a" * 64,
        size_bytes=2048,
    )
    pairing = PcPairing(
        user_id=uid1, pc_name="书房 PC", pc_mac_hash="m" * 64,
        access_token_hash="t" * 64,
    )
    txn = BillingTransaction(
        user_id=uid1, platform="android", sku="premium_monthly",
        purchase_token="tok", status="verified",
    )
    consent = ConsentRecord(
        user_id=uid1, device_id="device-abc", doc_key="privacy_policy", version=1,
    )
    db.add_all([blob, pairing, txn, consent])
    db.commit()
    ids = {"uid1": uid1, "uid2": uid2, "blob": blob.id, "pairing": pairing.id}
    db.close()
    return ids


def main() -> None:
    ids = prepare()
    db = SessionLocal()
    c = TestClient(app)

    print("\n[1] 鉴权")
    r = c.get("/admin/ui/", follow_redirects=False)
    check("未登录访问后台跳登录页", r.status_code == 303 and "/login" in r.headers.get("location", ""))
    r = c.post("/admin/ui/login", data={"password": "wrong"}, follow_redirects=False)
    check("错误口令被拒绝", r.status_code == 401)
    r = c.post("/admin/ui/login", data={"password": "test-admin-pw"}, follow_redirects=False)
    check("正确口令登录成功", r.status_code == 303)

    print("\n[2] 页面渲染")
    pages = {
        "/admin/ui/": "运营概览",
        "/admin/ui/users": "用户管理",
        f"/admin/ui/users/{ids['uid1']}": "权益管理",
        "/admin/ui/entitlements": "权益总览",
        "/admin/ui/cloud-saves": "云存档管理",
        "/admin/ui/pairings": "配对设备",
        "/admin/ui/consents": "同意记录",
        "/admin/ui/billing": "账单流水",
        "/admin/ui/audit": "审计日志",
        "/admin/ui/cms": "CMS 文档管理",
        "/admin/ui/config": "AppConfig",
    }
    for path, keyword in pages.items():
        resp = c.get(path)
        check(f"GET {path}", resp.status_code == 200 and keyword in resp.text,
              f"status={resp.status_code} body={resp.text[:160]!r}")

    print("\n[3] 用户管理")
    resp = c.post(
        f"/admin/ui/users/{ids['uid1']}/update",
        data={"email": "ops1-new@example.com", "display_name": "运维甲（改）"},
        follow_redirects=False,
    )
    db.expire_all()
    u = db.get(User, ids["uid1"])
    check("编辑用户资料", resp.status_code == 303 and u.email == "ops1-new@example.com"
          and u.display_name == "运维甲（改）")

    c.post(f"/admin/ui/users/{ids['uid1']}/toggle-active", follow_redirects=False)
    db.expire_all()
    check("禁用账号", db.get(User, ids["uid1"]).is_active is False)
    token = create_access_token(sub=ids["uid1"])
    resp = c.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    check("禁用后已签发 token 立即失效", resp.status_code == 403,
          f"status={resp.status_code}")
    c.post(f"/admin/ui/users/{ids['uid1']}/toggle-active", follow_redirects=False)
    db.expire_all()
    check("解除禁用", db.get(User, ids["uid1"]).is_active is True)

    c.post(
        f"/admin/ui/users/{ids['uid1']}/reset-password",
        data={"new_password": "NewPassw0rd!"}, follow_redirects=False,
    )
    db.expire_all()
    check("重置密码", verify_password("NewPassw0rd!", db.get(User, ids["uid1"]).password_hash))

    print("\n[4] 权益管理")
    c.post(
        f"/admin/ui/users/{ids['uid1']}/entitlement",
        data={"tier": "premium_monthly", "duration_days": "30",
              "expiry_at": "", "lifetime": ""},
        follow_redirects=False,
    )
    db.expire_all()
    ent = db.get(User, ids["uid1"]).entitlement
    check("授予 premium_monthly 并设置 30 天有效期",
          ent.tier == "premium_monthly" and ent.expiry_at is not None
          and ent.cloud_save_enabled is True)

    c.post(
        f"/admin/ui/users/{ids['uid1']}/entitlement",
        data={"tier": "vip_lifetime", "duration_days": "", "expiry_at": "", "lifetime": "1"},
        follow_redirects=False,
    )
    db.expire_all()
    ent = db.get(User, ids["uid1"]).entitlement
    check("授予终身档", ent.tier == "vip_lifetime" and ent.is_lifetime and ent.expiry_at is None)

    c.post(
        f"/admin/ui/users/{ids['uid1']}/entitlement",
        data={"tier": "free", "duration_days": "", "expiry_at": "", "lifetime": ""},
        follow_redirects=False,
    )
    db.expire_all()
    ent = db.get(User, ids["uid1"]).entitlement
    check("撤销权益回 free", ent.tier == "free" and not ent.is_lifetime and ent.expiry_at is None)

    c.post(f"/admin/ui/users/{ids['uid1']}/trial", data={"enabled": "1"}, follow_redirects=False)
    db.expire_all()
    check("开启试用", db.get(User, ids["uid1"]).entitlement.trial_start is not None)
    c.post(f"/admin/ui/users/{ids['uid1']}/trial", data={"enabled": "0"}, follow_redirects=False)
    db.expire_all()
    check("清除试用", db.get(User, ids["uid1"]).entitlement.trial_start is None)

    print("\n[5] 资源与内容管理")
    c.post(f"/admin/ui/cloud-saves/{ids['blob']}/delete", follow_redirects=False)
    db.expire_all()
    check("删除云存档", db.get(CloudSaveBlob, ids["blob"]) is None)
    c.post(f"/admin/ui/pairings/{ids['pairing']}/delete", follow_redirects=False)
    db.expire_all()
    check("解绑配对设备", db.get(PcPairing, ids["pairing"]) is None)

    c.post("/admin/ui/config", data={
        "config_key": "filing_number", "config_value": "京ICP备12345678号", "description": "备案号",
    }, follow_redirects=False)
    c.post("/admin/ui/config/add", data={
        "config_key": "contact_phone", "config_value": "400-000-0000", "description": "客服电话",
    }, follow_redirects=False)
    db.expire_all()
    from app.models import AppConfig
    check("编辑与新增 AppConfig",
          db.query(AppConfig).filter_by(config_key="filing_number").one().config_value == "京ICP备12345678号"
          and db.query(AppConfig).filter_by(config_key="contact_phone").count() == 1)

    from sqlalchemy import func as _func
    max_ver = (
        db.query(_func.max(CmsDocument.version))
        .filter(CmsDocument.doc_key == "privacy_policy", CmsDocument.language == "zh")
        .scalar()
    ) or 0
    next_ver = max_ver + 1
    resp = c.post("/admin/ui/docs", data={
        "doc_key": "privacy_policy", "language": "zh", "version": str(next_ver),
        "title": f"隐私政策 v{next_ver}", "content": "# 新版本\n\n测试正文", "summary": "",
    }, follow_redirects=False)
    check("创建 CMS 草稿", resp.status_code == 303 and "err=" not in resp.headers.get("location", ""),
          f"location={resp.headers.get('location')}")
    db.expire_all()
    draft = db.query(CmsDocument).filter_by(
        doc_key="privacy_policy", language="zh", version=next_ver
    ).first()
    check("创建 CMS 草稿", draft is not None and draft.status == "draft")
    c.post(f"/admin/ui/docs/{draft.id}/edit", data={
        "title": "隐私政策 v2（已改）", "content": "改过的正文", "summary": "",
    }, follow_redirects=False)
    c.post(f"/admin/ui/docs/{draft.id}/publish", follow_redirects=False)
    db.expire_all()
    check("编辑并发布草稿", db.get(CmsDocument, draft.id).status == "published")

    print("\n[6] Admin JSON API")
    hdr = {"Authorization": f"Bearer {create_admin_token('root')}"}
    resp = c.get("/admin/stats", headers=hdr)
    check("GET /admin/stats", resp.status_code == 200 and resp.json()["total_users"] == 2,
          f"status={resp.status_code} body={resp.text[:160]!r}")
    resp = c.get("/admin/users?q=ops1", headers=hdr)
    check("GET /admin/users 搜索", resp.status_code == 200 and resp.json()["pager"]["total"] == 1)
    resp = c.get(f"/admin/users/{ids['uid1']}", headers=hdr)
    check("GET /admin/users/{id}", resp.status_code == 200
          and resp.json()["counters"]["cloud_saves"] == 0)
    resp = c.patch(f"/admin/users/{ids['uid2']}", json={"is_active": False}, headers=hdr)
    check("PATCH /admin/users/{id}", resp.status_code == 200)
    resp = c.put(f"/admin/users/{ids['uid1']}/entitlement",
                 json={"tier": "premium_yearly"}, headers=hdr)
    check("PUT 权益（API）", resp.status_code == 200 and resp.json()["tier"] == "premium_yearly")
    for path in ("/admin/entitlements", "/admin/cloud-saves", "/admin/pairings",
                 "/admin/consents", "/admin/billing-transactions", "/admin/audit-logs"):
        resp = c.get(path, headers=hdr)
        check(f"GET {path}", resp.status_code == 200 and "pager" in resp.json(),
              f"status={resp.status_code}")
    resp = c.get("/admin/audit-logs", headers=hdr)
    actions = {i["action"] for i in resp.json()["items"]}
    check("审计日志留痕", {"user.update", "entitlement.set", "cms.publish",
                       "config.update", "cloud_save.delete"} <= actions,
          f"actions={actions}")

    print("\n[7] 用户删除与级联")
    c.post(f"/admin/ui/users/{ids['uid2']}/delete", follow_redirects=False)
    db.expire_all()
    check("删除用户", db.get(User, ids["uid2"]) is None)
    resp = c.get("/admin/audit-logs?q=user.delete", headers=hdr)
    check("删除后审计日志仍可查", resp.json()["pager"]["total"] >= 1)

    db.close()
    print(f"\n[PASS] 全部 {len(PASS)} 项通过\n")
    try:
        _DB.unlink(missing_ok=True)
    except OSError:
        pass


if __name__ == "__main__":
    main()
