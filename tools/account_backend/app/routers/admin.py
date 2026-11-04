"""Admin 端点 —— 独立 JWT secret 签发，仅你自己用。"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import require_admin
from ..models import AppConfig, User
from ..schemas.cms import *
from ..schemas.admin import (
    EntitlementUpdateRequest,
    ResetPasswordRequest,
    TrialRequest,
    UserUpdateRequest,
)
from ..services import admin_service, billing_service, cms_service, seed

router = APIRouter(prefix="/admin", tags=["admin"])


# ── Seed（首次部署调用一次） ──
@router.post("/seed")
def seed_database(db: Session = Depends(get_db), _: str = Depends(require_admin)):
    return seed.run_seed(db)


# ── CMS 文档管理 ──
@router.get("/docs")
def list_docs(db: Session = Depends(get_db), _: str = Depends(require_admin)):
    docs = cms_service.list_all_docs(db)
    return [
        {
            "id": d.id,
            "doc_key": d.doc_key,
            "language": d.language,
            "version": d.version,
            "title": d.title,
            "status": d.status,
            "published_at": d.published_at.isoformat() if d.published_at else None,
        }
        for d in docs
    ]


@router.post("/docs")
def create_draft(req: CmsDocCreateRequest, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    doc = cms_service.create_draft(
        db, req.doc_key, req.language, req.version, req.title, req.content, req.summary
    )
    return {"id": doc.id}


@router.put("/docs/{doc_id}")
def update_draft(doc_id: str, req: CmsDocUpdateRequest, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    doc = cms_service.update_draft(
        db, doc_id, title=req.title, content=req.content, summary=req.summary
    )
    return {"id": doc.id, "status": doc.status}


@router.post("/docs/{doc_id}/publish")
def publish(doc_id: str, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    doc = cms_service.publish_draft(db, doc_id)
    return {"id": doc.id, "status": doc.status, "published_at": doc.published_at.isoformat()}


# ── AppConfig 管理 ──
@router.get("/config")
def list_configs(db: Session = Depends(get_db), _: str = Depends(require_admin)):
    rows = db.query(AppConfig).all()
    return [{"config_key": r.config_key, "config_value": r.config_value, "description": r.description} for r in rows]


@router.put("/config/{key}")
def update_config(key: str, req: AppConfigUpdateRequest, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    row = cms_service.upsert_config(db, key, req.config_value, req.description)
    return {"config_key": row.config_key}


# ── Consent 统计 ──
@router.get("/consent-stats", response_model=ConsentStatsResponse)
def consent_stats(doc_key: str, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    return ConsentStatsResponse(**cms_service.consent_stats(db, doc_key))


# ── 运营仪表盘 ──
@router.get("/stats")
def stats(db: Session = Depends(get_db), _: str = Depends(require_admin)):
    return admin_service.dashboard_stats(db)


# ── 用户管理 ──
@router.get("/users")
def users(
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_users(db, q=q, tier=tier, state=state, page=page, page_size=page_size)


@router.get("/users/{user_id}")
def user_detail(user_id: str, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    d = admin_service.get_user_detail(db, user_id)
    u = d["user"]
    return {
        "id": u.id,
        "email": u.email,
        "display_name": u.display_name,
        "is_active": u.is_active,
        "is_admin": u.is_admin,
        "created_at": admin_service._utc(u.created_at),
        "trial_start": admin_service._utc(u.trial_start),
        "entitlement": {
            "tier": d["ent"].tier if d["ent"] else None,
            "state": d["ent_state"],
            "is_lifetime": bool(d["ent"].is_lifetime) if d["ent"] else False,
            "expiry_at": admin_service._utc(d["ent"].expiry_at) if d["ent"] else None,
            "trial_start": admin_service._utc(d["ent"].trial_start) if d["ent"] else None,
        },
        "counters": {
            "cloud_saves": d["save_count"],
            "cloud_save_bytes": d["save_bytes"],
            "pairings": d["pairing_count"],
            "billing_transactions": d["txn_count"],
            "consents": d["consent_count"],
        },
    }


@router.patch("/users/{user_id}")
def update_user(
    user_id: str,
    req: UserUpdateRequest,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    before = db.get(User, user_id)
    user = admin_service.update_user(
        db, user_id, email=req.email, display_name=req.display_name
    )
    if req.is_active is not None:
        user = admin_service.set_user_active(db, user_id, req.is_active)
    admin_service.log_action(
        db, actor, "user.update", "user", user_id,
        {"email": user.email, "display_name": user.display_name, "is_active": user.is_active,
         "before_email": before.email if before else None},
    )
    return {"ok": True, "id": user.id}


@router.post("/users/{user_id}/reset-password")
def reset_password(
    user_id: str,
    req: ResetPasswordRequest,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    admin_service.reset_password(db, user_id, req.new_password)
    admin_service.log_action(db, actor, "user.reset_password", "user", user_id)
    return {"ok": True}


@router.delete("/users/{user_id}")
def delete_user(
    user_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    user = db.get(User, user_id)
    email = user.email if user else user_id
    admin_service.delete_user(db, user_id)
    admin_service.log_action(db, actor, "user.delete", "user", user_id, {"email": email})
    return {"ok": True, "deleted": email}


# ── 权益管理 ──
@router.get("/entitlements")
def entitlements(
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_entitlements(
        db, q=q, tier=tier, state=state, page=page, page_size=page_size
    )


@router.put("/users/{user_id}/entitlement")
def set_entitlement(
    user_id: str,
    req: EntitlementUpdateRequest,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    ent = billing_service.set_entitlement(
        db, user_id, req.tier,
        lifetime=req.lifetime, duration_days=req.duration_days, expiry_at=req.expiry_at,
    )
    admin_service.log_action(
        db, actor, "entitlement.set", "user", user_id,
        {"tier": ent.tier, "is_lifetime": ent.is_lifetime,
         "expiry_at": ent.expiry_at.isoformat() if ent.expiry_at else None},
    )
    return {
        "ok": True,
        "tier": ent.tier,
        "state": billing_service.entitlement_state(ent),
        "is_lifetime": ent.is_lifetime,
        "expiry_at": ent.expiry_at,
    }


@router.post("/users/{user_id}/trial")
def set_trial(
    user_id: str,
    req: TrialRequest,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    ent = billing_service.set_trial(db, user_id, req.enabled)
    admin_service.log_action(
        db, actor, "entitlement.trial", "user", user_id, {"enabled": req.enabled}
    )
    return {"ok": True, "trial_start": ent.trial_start}


# ── 云存档 / 配对设备 ──
@router.get("/cloud-saves")
def cloud_saves(
    user_id: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_cloud_saves(db, user_id=user_id, q=q, page=page, page_size=page_size)


@router.delete("/cloud-saves/{blob_id}")
def delete_cloud_save(
    blob_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    admin_service.delete_cloud_save(db, blob_id)
    admin_service.log_action(db, actor, "cloud_save.delete", "cloud_save", blob_id)
    return {"ok": True}


@router.get("/pairings")
def pairings(
    user_id: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_pairings(db, user_id=user_id, q=q, page=page, page_size=page_size)


@router.delete("/pairings/{pairing_id}")
def delete_pairing(
    pairing_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(require_admin),
):
    admin_service.delete_pairing(db, pairing_id)
    admin_service.log_action(db, actor, "pairing.delete", "pairing", pairing_id)
    return {"ok": True}


# ── 同意记录 / 账单流水 / 审计日志（只读） ──
@router.get("/consents")
def consents(
    doc_key: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_consents(db, doc_key=doc_key, q=q, page=page, page_size=page_size)


@router.get("/billing-transactions")
def billing_transactions(
    status_filter: str = "",
    q: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_billing(
        db, status_filter=status_filter, q=q, page=page, page_size=page_size
    )


@router.get("/audit-logs")
def audit_logs(
    q: str = "",
    page: int = 1,
    page_size: int = admin_service.PAGE_SIZE_DEFAULT,
    db: Session = Depends(get_db),
    _: str = Depends(require_admin),
):
    return admin_service.list_audit(db, q=q, page=page, page_size=page_size)
