"""CMS service —— 文档版本管理 + AppConfig + ConsentRecord。"""
from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..config import settings
from ..models import AppConfig, CmsDocument, ConsentRecord


# ── CMS 文档 ──

def get_latest_published(db: Session, doc_key: str, language: str = "zh") -> Optional[CmsDocument]:
    return (
        db.query(CmsDocument)
        .filter(
            CmsDocument.doc_key == doc_key,
            CmsDocument.language == language,
            CmsDocument.status == "published",
        )
        .order_by(CmsDocument.version.desc())
        .first()
    )


def get_latest_meta(db: Session, doc_key: str, language: str = "zh") -> Optional[CmsDocument]:
    return get_latest_published(db, doc_key, language)


def list_all_docs(db: Session) -> list[CmsDocument]:
    return db.query(CmsDocument).order_by(CmsDocument.doc_key, CmsDocument.language, CmsDocument.version.desc()).all()


def create_draft(
    db: Session,
    doc_key: str,
    language: str,
    version: int,
    title: str,
    content: str,
    summary: Optional[str] = None,
    created_by: Optional[str] = None,
) -> CmsDocument:
    # 版本号必须大于已存在的该 doc_key+language 最大版本
    max_existing = (
        db.query(func.max(CmsDocument.version))
        .filter(CmsDocument.doc_key == doc_key, CmsDocument.language == language)
        .scalar()
    ) or 0
    if version <= max_existing:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"version_must_be_gt_{max_existing}",
        )

    doc = CmsDocument(
        doc_key=doc_key,
        version=version,
        language=language,
        title=title,
        content=content,
        summary=summary,
        status="draft",
        created_by=created_by,
    )
    db.add(doc)
    db.commit()
    db.refresh(doc)
    return doc


def update_draft(
    db: Session,
    doc_id: str,
    title: Optional[str] = None,
    content: Optional[str] = None,
    summary: Optional[str] = None,
) -> CmsDocument:
    doc = db.get(CmsDocument, doc_id)
    if not doc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="doc_not_found")
    if doc.status != "draft":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="only_draft_can_edit")
    if title is not None:
        doc.title = title
    if content is not None:
        doc.content = content
    if summary is not None:
        doc.summary = summary
    doc.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(doc)
    return doc


def publish_draft(db: Session, doc_id: str) -> CmsDocument:
    """发布草稿：同一 doc_key+language 之前的 published 自动归档。"""
    doc = db.get(CmsDocument, doc_id)
    if not doc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="doc_not_found")
    if doc.status != "draft":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="only_draft_can_publish")

    # 归档同 doc_key+language 已发布的旧版本
    db.query(CmsDocument).filter(
        CmsDocument.doc_key == doc.doc_key,
        CmsDocument.language == doc.language,
        CmsDocument.status == "published",
        CmsDocument.id != doc.id,
    ).update({"status": "archived"})

    doc.status = "published"
    doc.published_at = datetime.now(timezone.utc)
    doc.updated_at = doc.published_at
    db.commit()
    db.refresh(doc)
    return doc


# ── AppConfig ──

def get_all_configs(db: Session) -> dict[str, str]:
    rows = db.query(AppConfig).all()
    return {r.config_key: r.config_value for r in rows}


def upsert_config(
    db: Session,
    config_key: str,
    config_value: str,
    description: Optional[str] = None,
) -> AppConfig:
    row = db.query(AppConfig).filter(AppConfig.config_key == config_key).first()
    if row:
        row.config_value = config_value
        if description is not None:
            row.description = description
        row.updated_at = datetime.now(timezone.utc)
    else:
        row = AppConfig(config_key=config_key, config_value=config_value, description=description)
        db.add(row)
    db.commit()
    db.refresh(row)
    return row


# ── ConsentRecord ──

def _hash_device_id(device_id: str) -> str:
    return hashlib.sha256((device_id + settings.DEVICE_ID_SALT).encode()).hexdigest()


def _hash_ip(ip: str | None) -> str | None:
    if not ip:
        return None
    return hashlib.sha256((ip + settings.DEVICE_ID_SALT).encode()).hexdigest()


def record_consent(
    db: Session,
    doc_key: str,
    version: int,
    device_id: str,
    user_id: Optional[str] = None,
    ip: Optional[str] = None,
    user_agent: Optional[str] = None,
) -> ConsentRecord:
    """记录同意。不做去重 —— 每次点同意都写一条，审计用。"""
    rec = ConsentRecord(
        user_id=user_id,
        device_id=_hash_device_id(device_id),
        doc_key=doc_key,
        version=version,
        consented_at=datetime.now(timezone.utc),
        ip_hash=_hash_ip(ip),
        user_agent=user_agent,
    )
    db.add(rec)
    db.commit()
    db.refresh(rec)
    return rec


def get_latest_consented_version(
    db: Session,
    doc_key: str,
    device_id_hash: str,
    user_id: Optional[str] = None,
) -> Optional[int]:
    """查用户或设备针对某文档的最新已同意版本号。"""
    q = db.query(ConsentRecord).filter(ConsentRecord.doc_key == doc_key)
    if user_id:
        # 优先查已登录用户的同意记录
        q = q.filter(ConsentRecord.user_id == user_id)
        rec = q.order_by(ConsentRecord.consented_at.desc()).first()
        if rec:
            return rec.version
    # 回退：查 device_id
    rec = (
        db.query(ConsentRecord)
        .filter(ConsentRecord.doc_key == doc_key, ConsentRecord.device_id == device_id_hash)
        .order_by(ConsentRecord.consented_at.desc())
        .first()
    )
    return rec.version if rec else None


def consent_stats(db: Session, doc_key: str) -> dict:
    total = (
        db.query(func.count(ConsentRecord.id))
        .filter(ConsentRecord.doc_key == doc_key)
        .scalar() or 0
    )
    by_version = (
        db.query(ConsentRecord.version, func.count(ConsentRecord.id))
        .filter(ConsentRecord.doc_key == doc_key)
        .group_by(ConsentRecord.version)
        .order_by(ConsentRecord.version.desc())
        .all()
    )
    latest = get_latest_published(db, doc_key)
    return {
        "doc_key": doc_key,
        "total_consents": total,
        "latest_published_version": latest.version if latest else 0,
        "breakdown": [{"version": v, "consented_count": c} for v, c in by_version],
    }
