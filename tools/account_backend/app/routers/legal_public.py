"""公开法律文档网页 —— 供应用商店提交的稳定可访问 URL（无需登录）。

路由：
  GET /legal/{doc_key}          渲染最新已发布文档（Markdown -> HTML）
  GET /privacy  /privacy-policy 别名 -> privacy_policy
  GET /terms    /eula /user-agreement 别名 -> eula
"""
from __future__ import annotations

import markdown
import os

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse
from jinja2 import TemplateNotFound
from sqlalchemy.orm import Session

from ..database import get_db
from ..services import cms_service

_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_TEMPLATES = os.path.join(_BASE_DIR, "..", "templates")
from jinja2 import Environment, FileSystemLoader, select_autoescape

_env = Environment(
    loader=FileSystemLoader(os.path.abspath(_TEMPLATES)),
    autoescape=select_autoescape(["html", "xml"]),
)

router = APIRouter(tags=["legal-public"])

# 友好别名 -> doc_key
_ALIASES = {
    "privacy": "privacy_policy",
    "privacy-policy": "privacy_policy",
    "terms": "eula",
    "user-agreement": "eula",
    "eula": "eula",
}


def _render(doc_key: str, lang: str, db: Session) -> HTMLResponse:
    doc = cms_service.get_latest_published(db, doc_key, lang)
    if doc is None and lang != "zh":
        doc = cms_service.get_latest_published(db, doc_key, "zh")
    if doc is None:
        raise HTTPException(status_code=404, detail="doc_not_found")

    body_html = markdown.markdown(
        doc.content or "",
        extensions=["extra", "sane_lists", "tables"],
    )
    try:
        template = _env.get_template("legal/legal_page.html")
    except TemplateNotFound:
        # 兜底：极简渲染，避免模板缺失导致 500
        template = _env.from_string(
            "<!doctype html><html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>{{ title }}</title></head><body style='font-family:sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem'>"
            "<h1>{{ title }}</h1><article>{{ body | safe }}</article></body></html>"
        )
    html = template.render(
        title=doc.title or doc.doc_key,
        body=body_html,
        version=doc.version,
        updated=(doc.published_at.strftime("%Y-%m-%d") if doc.published_at else ""),
        lang=lang,
    )
    return HTMLResponse(content=html, media_type="text/html")


@router.get("/legal/{doc_key}", response_class=HTMLResponse)
def legal_doc(
    doc_key: str,
    lang: str = Query(default="zh", alias="lang"),
    db: Session = Depends(get_db),
):
    return _render(doc_key, lang, db)


def _alias(lang: str, db: Session, doc_key: str) -> HTMLResponse:
    return _render(doc_key, lang, db)


@router.get("/privacy", response_class=HTMLResponse)
@router.get("/privacy-policy", response_class=HTMLResponse)
def privacy_page(
    lang: str = Query(default="zh", alias="lang"),
    db: Session = Depends(get_db),
):
    return _render("privacy_policy", lang, db)


@router.get("/terms", response_class=HTMLResponse)
@router.get("/eula", response_class=HTMLResponse)
@router.get("/user-agreement", response_class=HTMLResponse)
def terms_page(
    lang: str = Query(default="zh", alias="lang"),
    db: Session = Depends(get_db),
):
    return _render("eula", lang, db)
