"""Admin 端点 —— 独立 JWT secret 签发，仅你自己用。"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import require_admin
from ..schemas.cms import *
from ..services import cms_service, seed

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
    rows = db.query(__import__("app.models.cms", fromlist=["AppConfig"]).AppConfig).all()
    return [{"config_key": r.config_key, "config_value": r.config_value, "description": r.description} for r in rows]


@router.put("/config/{key}")
def update_config(key: str, req: AppConfigUpdateRequest, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    row = cms_service.upsert_config(db, key, req.config_value, req.description)
    return {"config_key": row.config_key}


# ── Consent 统计 ──
@router.get("/consent-stats", response_model=ConsentStatsResponse)
def consent_stats(doc_key: str, db: Session = Depends(get_db), _: str = Depends(require_admin)):
    return ConsentStatsResponse(**cms_service.consent_stats(db, doc_key))
