"""后台管理服务 —— 用户 / 权益 / 云存档 / 配对 / 同意 / 流水 / 统计 / 审计。

供 Admin JSON API 与 Admin Web UI 共用；所有写操作由调用方配合 `log_action()` 记审计。
返回统一的分页结构 {items, pager}，items 为普通 dict，模板与 JSON 都能直接消费。
"""
from __future__ import annotations

import json
import math
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import HTTPException, status
from sqlalchemy import func, or_
from sqlalchemy.orm import Session, defer

from ..models import (
    AdminAuditLog,
    BillingTransaction,
    CloudSaveBlob,
    ConsentRecord,
    Entitlement,
    PcPairing,
    User,
)
from ..security import hash_password
from .billing_service import entitlement_state

PAGE_SIZE_DEFAULT = 20
PAGE_SIZE_MAX = 100


def _utc(dt: datetime | None) -> datetime | None:
    """SQLite 回读的 DateTime 会丢 tzinfo，统一按 UTC 解释。"""
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _norm_page(page: int | None, page_size: int | None) -> tuple[int, int]:
    p = max(1, int(page or 1))
    s = max(1, min(PAGE_SIZE_MAX, int(page_size or PAGE_SIZE_DEFAULT)))
    return p, s


def _paginate(query, page: int, page_size: int) -> tuple[list[Any], dict[str, int]]:
    total = query.count()
    pages = max(1, math.ceil(total / page_size))
    page = min(page, pages)
    items = query.offset((page - 1) * page_size).limit(page_size).all()
    return items, {"total": total, "page": page, "pages": pages, "page_size": page_size}


def _pager_params(**kwargs) -> str:
    """构造分页链接的 query string（跳过空值）。"""
    parts = [f"{k}={v}" for k, v in kwargs.items() if v not in (None, "")]
    return "&".join(parts)


# ── 审计 ──────────────────────────────────────────────────────────────

def log_action(
    db: Session,
    actor: str,
    action: str,
    target_type: str = "",
    target_id: str = "",
    detail: dict | None = None,
) -> AdminAuditLog:
    row = AdminAuditLog(
        actor=actor or "root",
        action=action,
        target_type=target_type,
        target_id=str(target_id or ""),
        detail=json.dumps(detail or {}, ensure_ascii=False),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def list_audit(db: Session, *, q: str = "", page: int = 1, page_size: int = PAGE_SIZE_DEFAULT):
    page, page_size = _norm_page(page, page_size)
    query = db.query(AdminAuditLog)
    if q:
        query = query.filter(
            or_(
                AdminAuditLog.actor.ilike(f"%{q}%"),
                AdminAuditLog.action.ilike(f"%{q}%"),
                AdminAuditLog.target_id.ilike(f"%{q}%"),
            )
        )
    query = query.order_by(AdminAuditLog.created_at.desc(), AdminAuditLog.id.desc())
    rows, pager = _paginate(query, page, page_size)
    items = [
        {
            "id": r.id,
            "actor": r.actor,
            "action": r.action,
            "target_type": r.target_type,
            "target_id": r.target_id,
            "detail": r.detail,
            "created_at": _utc(r.created_at),
        }
        for r in rows
    ]
    return {"items": items, "pager": pager}


# ── 仪表盘统计 ────────────────────────────────────────────────────────

def dashboard_stats(db: Session) -> dict:
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=7)
    created_at_values = [r[0] for r in db.query(User.created_at).all()]
    new_7d = sum(1 for dt in created_at_values if _utc(dt) and _utc(dt) >= cutoff)

    tier_rows = db.query(Entitlement.tier, func.count(Entitlement.id)).group_by(Entitlement.tier).all()
    tier_counts = {tier: n for tier, n in tier_rows}
    state_counts: dict[str, int] = {}
    for ent in db.query(Entitlement).all():
        state = entitlement_state(ent)
        state_counts[state] = state_counts.get(state, 0) + 1

    total_users = db.query(func.count(User.id)).scalar() or 0
    disabled = db.query(func.count(User.id)).filter(User.is_active.is_(False)).scalar() or 0
    saves = db.query(
        func.count(CloudSaveBlob.id),
        func.coalesce(func.sum(CloudSaveBlob.size_bytes), 0),
    ).one()

    recent = (
        db.query(User).order_by(User.created_at.desc(), User.id.desc()).limit(8).all()
    )
    recent_rows = []
    for u in recent:
        recent_rows.append(
            {
                "id": u.id,
                "email": u.email,
                "display_name": u.display_name,
                "is_active": u.is_active,
                "created_at": _utc(u.created_at),
                "state": entitlement_state(u.entitlement),
            }
        )

    return {
        "total_users": total_users,
        "active_users": total_users - disabled,
        "disabled_users": disabled,
        "new_7d": new_7d,
        "tier_counts": tier_counts,
        "state_counts": state_counts,
        "cloud_save_count": saves[0] or 0,
        "cloud_save_bytes": saves[1] or 0,
        "pairing_count": db.query(func.count(PcPairing.id)).scalar() or 0,
        "consent_count": db.query(func.count(ConsentRecord.id)).scalar() or 0,
        "billing_count": db.query(func.count(BillingTransaction.id)).scalar() or 0,
        "audit_count": db.query(func.count(AdminAuditLog.id)).scalar() or 0,
        "recent_users": recent_rows,
        "generated_at": now,
    }


# ── 用户 ──────────────────────────────────────────────────────────────

def _save_count_map(db: Session) -> dict[str, int]:
    rows = (
        db.query(CloudSaveBlob.user_id, func.count(CloudSaveBlob.id))
        .group_by(CloudSaveBlob.user_id)
        .all()
    )
    return {uid: n for uid, n in rows}


def list_users(
    db: Session,
    *,
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(User).outerjoin(Entitlement, Entitlement.user_id == User.id)
    if q:
        like = f"%{q.strip()}%"
        query = query.filter(or_(User.email.ilike(like), User.display_name.ilike(like)))
    if tier and tier != "all":
        query = query.filter(Entitlement.tier == tier)
    if state == "active":
        query = query.filter(User.is_active.is_(True))
    elif state == "disabled":
        query = query.filter(User.is_active.is_(False))
    query = query.order_by(User.created_at.desc(), User.id.desc())

    rows, pager = _paginate(query, page, page_size)
    save_counts = _save_count_map(db)
    items = [
        {
            "id": u.id,
            "email": u.email,
            "display_name": u.display_name,
            "is_active": u.is_active,
            "is_admin": u.is_admin,
            "created_at": _utc(u.created_at),
            "tier": u.entitlement.tier if u.entitlement else "无记录",
            "ent_state": entitlement_state(u.entitlement),
            "expiry_at": _utc(u.entitlement.expiry_at) if u.entitlement else None,
            "trial_start": _utc(u.entitlement.trial_start) if u.entitlement else None,
            "save_count": save_counts.get(u.id, 0),
        }
        for u in rows
    ]
    return {"items": items, "pager": pager}


def get_user_detail(db: Session, user_id: str) -> dict:
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    ent = user.entitlement
    saves = (
        db.query(CloudSaveBlob)
        .options(defer(CloudSaveBlob.encrypted_blob))
        .filter(CloudSaveBlob.user_id == user_id)
        .order_by(CloudSaveBlob.updated_at.desc())
        .limit(20)
        .all()
    )
    txns = (
        db.query(BillingTransaction)
        .filter(BillingTransaction.user_id == user_id)
        .order_by(BillingTransaction.created_at.desc())
        .limit(20)
        .all()
    )
    consents = (
        db.query(ConsentRecord)
        .filter(ConsentRecord.user_id == user_id)
        .order_by(ConsentRecord.consented_at.desc())
        .limit(20)
        .all()
    )
    pairings = (
        db.query(PcPairing)
        .filter(PcPairing.user_id == user_id)
        .order_by(PcPairing.created_at.desc())
        .limit(20)
        .all()
    )
    save_bytes = (
        db.query(func.coalesce(func.sum(CloudSaveBlob.size_bytes), 0))
        .filter(CloudSaveBlob.user_id == user_id)
        .scalar()
        or 0
    )
    return {
        "user": user,
        "ent": ent,
        "ent_state": entitlement_state(ent),
        "save_count": db.query(func.count(CloudSaveBlob.id)).filter(CloudSaveBlob.user_id == user_id).scalar() or 0,
        "save_bytes": save_bytes,
        "pairing_count": db.query(func.count(PcPairing.id)).filter(PcPairing.user_id == user_id).scalar() or 0,
        "txn_count": db.query(func.count(BillingTransaction.id)).filter(BillingTransaction.user_id == user_id).scalar() or 0,
        "consent_count": db.query(func.count(ConsentRecord.id)).filter(ConsentRecord.user_id == user_id).scalar() or 0,
        "saves": saves,
        "txns": txns,
        "consents": consents,
        "pairings": pairings,
    }


def update_user(
    db: Session,
    user_id: str,
    *,
    email: str | None = None,
    display_name: str | None = None,
) -> User:
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    if email is not None:
        new_email = email.strip().lower()
        if not new_email:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="email_required")
        dup = (
            db.query(User)
            .filter(User.email == new_email, User.id != user_id)
            .first()
        )
        if dup:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="email_exists")
        user.email = new_email
    if display_name is not None:
        user.display_name = display_name.strip() or "Player"
    db.commit()
    db.refresh(user)
    return user


def set_user_active(db: Session, user_id: str, active: bool) -> User:
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    user.is_active = bool(active)
    db.commit()
    db.refresh(user)
    return user


def reset_password(db: Session, user_id: str, new_password: str) -> User:
    if not new_password or len(new_password) < 8:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="password_too_short")
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    user.password_hash = hash_password(new_password)
    db.commit()
    db.refresh(user)
    return user


def delete_user(db: Session, user_id: str) -> None:
    """级联清理 entitlement / 云存档 / 配对 / 流水 / 同意记录（事务内删除）。"""
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    db.delete(user)
    db.commit()


# ── 各类列表 ──────────────────────────────────────────────────────────

def _user_email_map(db: Session, ids: list[str]) -> dict[str, str]:
    if not ids:
        return {}
    rows = db.query(User.id, User.email).filter(User.id.in_(set(ids))).all()
    return {uid: email for uid, email in rows}


def list_entitlements(
    db: Session,
    *,
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(Entitlement).join(User, User.id == Entitlement.user_id)
    if q:
        query = query.filter(User.email.ilike(f"%{q.strip()}%"))
    if tier and tier != "all":
        query = query.filter(Entitlement.tier == tier)
    query = query.order_by(Entitlement.updated_at.desc())

    def to_item(e: Entitlement, email: str) -> dict:
        return {
            "id": e.id,
            "user_id": e.user_id,
            "user_email": email,
            "tier": e.tier,
            "state": entitlement_state(e),
            "is_lifetime": e.is_lifetime,
            "expiry_at": _utc(e.expiry_at),
            "trial_start": _utc(e.trial_start),
            "updated_at": _utc(e.updated_at),
        }

    # 状态由 Python 计算（试用窗/到期判断），有状态过滤时先全量筛再分页，
    # 保证 total 与分页链接准确。
    if state and state != "all":
        all_rows = query.all()
        emails = _user_email_map(db, [r.user_id for r in all_rows])
        filtered = [
            to_item(e, emails.get(e.user_id, "(已删除)"))
            for e in all_rows
            if entitlement_state(e) == state
        ]
        total = len(filtered)
        pages = max(1, math.ceil(total / page_size))
        page = min(page, pages)
        start = (page - 1) * page_size
        return {
            "items": filtered[start : start + page_size],
            "pager": {"total": total, "page": page, "pages": pages, "page_size": page_size},
        }

    rows, pager = _paginate(query, page, page_size)
    emails = _user_email_map(db, [r.user_id for r in rows])
    return {
        "items": [to_item(e, emails.get(e.user_id, "(已删除)")) for e in rows],
        "pager": pager,
    }


def list_cloud_saves(
    db: Session,
    *,
    user_id: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(CloudSaveBlob).options(defer(CloudSaveBlob.encrypted_blob))
    if user_id:
        query = query.filter(CloudSaveBlob.user_id == user_id)
    if q:
        query = query.filter(CloudSaveBlob.save_name.ilike(f"%{q.strip()}%"))
    query = query.order_by(CloudSaveBlob.updated_at.desc())
    rows, pager = _paginate(query, page, page_size)
    emails = _user_email_map(db, [r.user_id for r in rows])
    return {
        "items": [
            {
                "id": b.id,
                "user_id": b.user_id,
                "user_email": emails.get(b.user_id, "(已删除)"),
                "save_name": b.save_name,
                "size_bytes": b.size_bytes,
                "sha256": b.sha256,
                "created_at": _utc(b.created_at),
                "updated_at": _utc(b.updated_at),
            }
            for b in rows
        ],
        "pager": pager,
    }


def delete_cloud_save(db: Session, blob_id: str) -> None:
    blob = db.get(CloudSaveBlob, blob_id)
    if not blob:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="blob_not_found")
    db.delete(blob)
    db.commit()


def list_pairings(
    db: Session,
    *,
    user_id: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(PcPairing)
    if user_id:
        query = query.filter(PcPairing.user_id == user_id)
    if q:
        query = query.filter(PcPairing.pc_name.ilike(f"%{q.strip()}%"))
    query = query.order_by(PcPairing.created_at.desc())
    rows, pager = _paginate(query, page, page_size)
    emails = _user_email_map(db, [r.user_id for r in rows])
    return {
        "items": [
            {
                "id": p.id,
                "user_id": p.user_id,
                "user_email": emails.get(p.user_id, "(已删除)"),
                "pc_name": p.pc_name,
                "last_seen_at": _utc(p.last_seen_at),
                "created_at": _utc(p.created_at),
            }
            for p in rows
        ],
        "pager": pager,
    }


def delete_pairing(db: Session, pairing_id: str) -> None:
    row = db.get(PcPairing, pairing_id)
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="pairing_not_found")
    db.delete(row)
    db.commit()


def list_consents(
    db: Session,
    *,
    doc_key: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(ConsentRecord)
    if doc_key and doc_key != "all":
        query = query.filter(ConsentRecord.doc_key == doc_key)
    if q:
        query = query.filter(
            or_(
                ConsentRecord.device_id.ilike(f"%{q.strip()}%"),
                ConsentRecord.user_id.ilike(f"%{q.strip()}%"),
            )
        )
    query = query.order_by(ConsentRecord.consented_at.desc())
    rows, pager = _paginate(query, page, page_size)
    emails = _user_email_map(db, [r.user_id for r in rows if r.user_id])
    return {
        "items": [
            {
                "id": c.id,
                "user_id": c.user_id,
                "user_email": emails.get(c.user_id, "匿名设备") if c.user_id else "匿名设备",
                "doc_key": c.doc_key,
                "version": c.version,
                "device_id": c.device_id,
                "consented_at": _utc(c.consented_at),
            }
            for c in rows
        ],
        "pager": pager,
    }


def list_billing(
    db: Session,
    *,
    status_filter: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = PAGE_SIZE_DEFAULT,
):
    page, page_size = _norm_page(page, page_size)
    query = db.query(BillingTransaction)
    if status_filter and status_filter != "all":
        query = query.filter(BillingTransaction.status == status_filter)
    if q:
        query = query.filter(
            or_(
                BillingTransaction.sku.ilike(f"%{q.strip()}%"),
                BillingTransaction.user_id.ilike(f"%{q.strip()}%"),
            )
        )
    query = query.order_by(BillingTransaction.created_at.desc())
    rows, pager = _paginate(query, page, page_size)
    emails = _user_email_map(db, [r.user_id for r in rows])
    return {
        "items": [
            {
                "id": t.id,
                "user_email": emails.get(t.user_id, "(已删除)"),
                "platform": t.platform,
                "sku": t.sku,
                "status": t.status,
                "created_at": _utc(t.created_at),
                "verified_at": _utc(t.verified_at),
            }
            for t in rows
        ],
        "pager": pager,
    }
