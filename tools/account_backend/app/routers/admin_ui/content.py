"""内容管理：CMS 文档（草稿/编辑/发布）与 AppConfig 动态配置。

保留原有表单路径 /admin/ui/docs、/admin/ui/docs/{id}/publish、/admin/ui/config，
新增独立页面 /cms 与 /config，以及草稿编辑、配置项新增。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Request
from fastapi.responses import HTMLResponse
from sqlalchemy import func
from sqlalchemy.orm import Session

from ...admin_guard import render, ui_admin
from ...database import get_db
from ...models import AppConfig, CmsDocument
from ...services import cms_service
from ._common import perform

router = APIRouter()


@router.get("/cms", response_class=HTMLResponse)
def cms_page(
    request: Request,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    # 全局最大版本 +1 保证对任意 doc_key+language 都是合法的新版本号
    max_version = db.query(func.max(CmsDocument.version)).scalar() or 0
    return render(
        "admin/cms.html", request, active="cms",
        docs=cms_service.list_all_docs(db),
        max_version=max_version,
        suggested_version=max_version + 1,
        privacy_stats=cms_service.consent_stats(db, "privacy_policy"),
        eula_stats=cms_service.consent_stats(db, "eula"),
    )


@router.get("/config", response_class=HTMLResponse)
def config_page(
    request: Request,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    return render(
        "admin/config.html", request, active="config",
        configs=db.query(AppConfig).order_by(AppConfig.config_key).all(),
    )


@router.post("/docs")
def create_doc(
    doc_key: str = Form(...),
    language: str = Form(...),
    version: int = Form(...),
    title: str = Form(...),
    content: str = Form(...),
    summary: str = Form(""),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="cms.create_draft",
        target_type="cms_doc", target_id=doc_key,
        back="/admin/ui/cms",
        fn=lambda: cms_service.create_draft(
            db, doc_key.strip(), language.strip(), version, title.strip(), content,
            summary or None, created_by=actor,
        ),
        detail={"doc_key": doc_key, "language": language, "version": version},
    )


@router.post("/docs/{doc_id}/edit")
def edit_doc(
    doc_id: str,
    title: str = Form(...),
    content: str = Form(...),
    summary: str = Form(""),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="cms.update_draft",
        target_type="cms_doc", target_id=doc_id,
        back="/admin/ui/cms",
        fn=lambda: cms_service.update_draft(
            db, doc_id, title=title.strip(), content=content, summary=summary or None
        ),
        detail={"title": title},
    )


@router.post("/docs/{doc_id}/publish")
def publish_doc(
    doc_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="cms.publish",
        target_type="cms_doc", target_id=doc_id,
        back="/admin/ui/cms",
        fn=lambda: cms_service.publish_draft(db, doc_id),
    )


@router.post("/config")
def update_config(
    config_key: str = Form(...),
    config_value: str = Form(...),
    description: str = Form(""),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="config.update",
        target_type="app_config", target_id=config_key,
        back="/admin/ui/config",
        fn=lambda: cms_service.upsert_config(
            db, config_key.strip(), config_value, description or None
        ),
        detail={"config_key": config_key, "config_value": config_value},
    )


@router.post("/config/add")
def add_config(
    config_key: str = Form(...),
    config_value: str = Form(""),
    description: str = Form(""),
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="config.create",
        target_type="app_config", target_id=config_key.strip(),
        back="/admin/ui/config",
        fn=lambda: cms_service.upsert_config(
            db, config_key.strip(), config_value, description or None
        ),
        detail={"config_key": config_key, "config_value": config_value},
    )
