"""CMS 公开端点 —— App 端拉取，无需登录。"""
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..schemas.cms import *
from ..services import cms_service

router = APIRouter(prefix="/api/cms", tags=["cms-public"])


@router.get("/docs/{doc_key}", response_model=CmsDocResponse)
def get_doc(
    doc_key: str,
    lang: str = Query(default="zh", alias="lang"),
    db: Session = Depends(get_db),
):
    doc = cms_service.get_latest_published(db, doc_key, lang)
    if not doc:
        raise HTTPException(status_code=404, detail="doc_not_found")
    return CmsDocResponse(
        doc_key=doc.doc_key,
        language=doc.language,
        version=doc.version,
        title=doc.title,
        summary=doc.summary,
        content=doc.content,
    )


@router.get("/doc-meta/{doc_key}", response_model=CmsDocMetaResponse)
def get_doc_meta(
    doc_key: str,
    lang: str = Query(default="zh", alias="lang"),
    db: Session = Depends(get_db),
):
    doc = cms_service.get_latest_meta(db, doc_key, lang)
    if not doc:
        raise HTTPException(status_code=404, detail="doc_not_found")
    return CmsDocMetaResponse(
        doc_key=doc.doc_key,
        language=doc.language,
        latest_published_version=doc.version,
        summary=doc.summary,
        published_at=doc.published_at.isoformat() if doc.published_at else None,
    )


@router.get("/config", response_model=AppConfigMap)
def get_config(db: Session = Depends(get_db)):
    configs = cms_service.get_all_configs(db)
    return AppConfigMap(configs=configs)
