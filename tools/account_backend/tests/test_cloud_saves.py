"""云存档端点契约自测（无需 pytest，直接 `python tests/test_cloud_saves.py`）。

覆盖 App 端 CloudClient 实际依赖的全部契约点：
  * 会员门控 403 / 未登录 401
  * multipart 字段：save_name + client_key + file
  * 扩展名白名单（.zip → 400）、受限关键词、10MB 上限
  * client_key 覆盖语义（同一 key 重复上传 → id 不变、行数不增）
  * list 元信息（size/sha256/时间）、download 二进制 + X-Save-SHA256
  * 跨用户隔离（他人 blob → 404）、删除后 404
  * 错误体统一 `{"detail": ...}`（Dart 端 CloudClient.errorOf 解析此键）
使用临时 SQLite，不触碰真实数据库。
"""
from __future__ import annotations

import hashlib
import os
import sys
import tempfile
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]  # tools/account_backend
sys.path.insert(0, str(_ROOT))

_DB = Path(tempfile.gettempdir()) / "retroemupouch_cloud_saves_test.db"
if _DB.exists():
    _DB.unlink()
os.environ["DATABASE_URL"] = "sqlite:///" + _DB.as_posix()
os.environ["APP_ENV"] = "dev"

from fastapi.testclient import TestClient  # noqa: E402

from app import models  # noqa: E402,F401
from app.database import Base, SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import CloudSaveBlob  # noqa: E402
from app.services import auth_service, seed  # noqa: E402
from app.services.billing_service import set_entitlement  # noqa: E402
from app.services.schema_bootstrap import ensure_runtime_schema  # noqa: E402

PASS: list[str] = []


def check(label: str, cond: bool, extra: str = "") -> None:
    if not cond:
        raise AssertionError(f"FAILED: {label} {extra}")
    PASS.append(label)
    print(f"  ok  {label}")


def _upload(c: TestClient, token: str, save_name: str, client_key: str, data: bytes):
    return c.post(
        "/api/cloud/saves/upload",
        headers={"Authorization": f"Bearer {token}"},
        data={"save_name": save_name, "client_key": client_key},
        files={"file": (save_name, data, "application/octet-stream")},
    )


def prepare() -> dict:
    Base.metadata.create_all(engine)
    ensure_runtime_schema(engine)
    db = SessionLocal()
    seed.run_seed(db)

    free = auth_service.register(db, "free@example.com", "Passw0rd!1", "免费用户")
    vip = auth_service.register(db, "vip@example.com", "Passw0rd!2", "会员用户")
    set_entitlement(db, vip.id, "premium_monthly")
    ids = {"free": free.email, "vip": vip.email, "vip_id": vip.id}
    db.close()
    return ids


def login(c: TestClient, email: str, password: str) -> str:
    r = c.post("/api/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def main() -> None:
    ids = prepare()
    c = TestClient(app)
    free_tok = login(c, ids["free"], "Passw0rd!1")
    vip_tok = login(c, ids["vip"], "Passw0rd!2")
    db = SessionLocal()

    print("\n[1] 鉴权与会员门控")
    r = c.get("/api/cloud/saves/list")
    check("无 token → 401", r.status_code == 401, r.text)
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {free_tok}"})
    check("免费档 list → 403", r.status_code == 403, r.text)
    check(
        "403 错误体是 detail=cloud_save_requires_premium",
        r.json().get("detail") == "cloud_save_requires_premium",
        r.text,
    )
    r = _upload(c, free_tok, "a.sav", "slot0", b"x")
    check("免费档 upload → 403", r.status_code == 403, r.text)

    print("\n[2] 上传（multipart: save_name + client_key + file）")
    plain1 = b"PLAINTEXT-SAVE-1" * 100
    cipher1 = bytes(reversed(hashlib.sha256(plain1).digest())) * 40
    r = _upload(c, vip_tok, "slot1.sav", "slot1", cipher1)
    check("会员 upload → 200", r.status_code == 200, r.text)
    body = r.json()
    save_id = body.get("save_id") or ""
    check("响应 ok=true 且带 save_id", body.get("ok") is True and len(save_id) == 36, r.text)

    print("\n[3] list 元信息")
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {vip_tok}"})
    check("会员 list → 200", r.status_code == 200, r.text)
    rows = r.json()
    check("list 返回 1 条", len(rows) == 1, r.text)
    row = rows[0]
    check("save_name 原样回显", row.get("save_name") == "slot1.sav", r.text)
    check("size_bytes 是密文长度", row.get("size_bytes") == len(cipher1), str(row))
    check(
        "sha256 是密文摘要（服务端不解密）",
        row.get("sha256") == hashlib.sha256(cipher1).hexdigest(),
        str(row),
    )
    check("created_at/updated_at 可解析", bool(row.get("created_at")) and bool(row.get("updated_at")))

    print("\n[4] download（二进制 + X-Save-SHA256）")
    r = c.get(f"/api/cloud/saves/{save_id}", headers={"Authorization": f"Bearer {vip_tok}"})
    check("download → 200", r.status_code == 200, r.text)
    check("字节与上传密文一致", r.content == cipher1, f"{len(r.content)} vs {len(cipher1)}")
    check(
        "X-Save-SHA256 头与密文摘要一致",
        r.headers.get("x-save-sha256") == hashlib.sha256(cipher1).hexdigest(),
        str(dict(r.headers)),
    )

    print("\n[5] client_key 覆盖语义（App 重复备份不堆积）")
    cipher2 = b"SECOND-UPLOAD-CIPHER" * 60
    r = _upload(c, vip_tok, "slot1-renamed.sav", "slot1", cipher2)
    check("同 client_key 再上传 → 200", r.status_code == 200, r.text)
    check("覆盖后 id 不变", r.json().get("save_id") == save_id, r.text)
    db.expire_all()
    blobs = db.query(CloudSaveBlob).filter(CloudSaveBlob.user_id == ids["vip_id"]).all()
    check("行数仍为 1", len(blobs) == 1, str(len(blobs)))
    check("内容已替换", blobs[0].encrypted_blob == cipher2 and blobs[0].size_bytes == len(cipher2))
    check("save_name 已更新", blobs[0].save_name == "slot1-renamed.sav", blobs[0].save_name)

    r = _upload(c, vip_tok, "slot2.sav", "slot2", b"another-cipher")
    check("不同 client_key → 新增一行", r.status_code == 200 and r.json()["save_id"] != save_id, r.text)
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {vip_tok}"})
    check("list 变 2 条", len(r.json()) == 2, r.text)

    print("\n[6] 合规校验")
    r = _upload(c, vip_tok, "kof97.zip", "rom", b"PK\x03\x04")
    check("ROM 扩展名 .zip → 400", r.status_code == 400, r.text)
    check(
        "错误体说明扩展名不允许",
        "extension_not_allowed" in str(r.json().get("detail", "")),
        r.text,
    )
    r = _upload(c, vip_tok, "neogeo.zip.sav", "bios", b"x")
    check("受限关键词 → 400 forbidden_keyword", r.status_code == 400 and r.json().get("detail") == "forbidden_keyword", r.text)
    big = b"0" * (10 * 1024 * 1024 + 1)
    r = _upload(c, vip_tok, "big.sav", "big", big)
    check("超过 10MB → 413 too_large", r.status_code == 413 and r.json().get("detail") == "too_large", r.text)
    r = _upload(c, vip_tok, "nosuffix", "nosuffix", b"x")
    check("无扩展名 → 400", r.status_code == 400, r.text)

    print("\n[7] 跨用户隔离与删除")
    other = auth_service.register(db, "other@example.com", "Passw0rd!3", "另一个会员")
    set_entitlement(db, other.id, "premium_monthly")
    other_tok = login(c, "other@example.com", "Passw0rd!3")
    r = c.get(f"/api/cloud/saves/{save_id}", headers={"Authorization": f"Bearer {other_tok}"})
    check("他人 blob 下载 → 404 blob_not_found", r.status_code == 404 and r.json().get("detail") == "blob_not_found", r.text)
    r = c.delete(f"/api/cloud/saves/{save_id}", headers={"Authorization": f"Bearer {other_tok}"})
    check("他人 blob 删除 → 404", r.status_code == 404, r.text)

    r = c.delete(f"/api/cloud/saves/{save_id}", headers={"Authorization": f"Bearer {vip_tok}"})
    check("本人删除 → 200 ok=true", r.status_code == 200 and r.json().get("ok") is True, r.text)
    r = c.get(f"/api/cloud/saves/{save_id}", headers={"Authorization": f"Bearer {vip_tok}"})
    check("删除后再下载 → 404", r.status_code == 404, r.text)
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {vip_tok}"})
    check("删除后 list 剩 1 条", len(r.json()) == 1, r.text)

    print("\n[8] 客户端存档命名规约（CloudSaveSync.nameFor）")
    # 客户端真实存档命名：<CRC>.sav / <CRC>.state / <CRC>.slotN.state /
    # <CRC>.slotN.thumb.dat（缩略图用 .dat 承载 JPEG，绕开后端 .jpg 白名单限制）
    names = [
        "AABBCCDD.sav",
        "AABBCCDD.state",
        "AABBCCDD.slot1.state",
        "AABBCCDD.slot1.thumb.dat",
    ]
    for n in names:
        r = _upload(c, vip_tok, n, f"gp-save:AABBCCDD:{n}", b"cipher-" + n.encode())
        check(f"存档命名 {n} → 200", r.status_code == 200, r.text)
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {vip_tok}"})
    check("4 份存档全部落库（+ 之前 1 条 = 5）", len(r.json()) == 5, r.text)
    # 同名不同 clientKey 会各存一份（客户端用稳定 clientKey 避免这点）
    r = _upload(c, vip_tok, "AABBCCDD.sav", "another-key", b"dup")
    check("同 save_name 不同 clientKey 视为不同 blob", r.status_code == 200, r.text)
    r = c.get("/api/cloud/saves/list", headers={"Authorization": f"Bearer {vip_tok}"})
    check("list 变 6 条", len(r.json()) == 6, r.text)

    db.close()
    print("\n-------------------------------------------")
    print(f"ALL GREEN ({len(PASS)} checks)")


if __name__ == "__main__":
    main()
