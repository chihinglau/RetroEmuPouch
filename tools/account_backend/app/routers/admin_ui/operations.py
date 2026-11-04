"""运维资源页面：权益总览 / 云存档 / 配对设备 / 同意记录 / 账单流水 / 审计日志。"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from ...admin_guard import render, ui_admin
from ...database import get_db
from ...services import admin_service, billing_service
from ._common import perform

router = APIRouter()
_PS = admin_service.PAGE_SIZE_DEFAULT


@router.get("/entitlements", response_class=HTMLResponse)
def entitlements_page(
    request: Request,
    q: str = "",
    tier: str = "",
    state: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_entitlements(
        db, q=q, tier=tier, state=state, page=page, page_size=_PS
    )
    return render(
        "admin/entitlements.html", request, active="entitlements", data=data,
        q=q, tier=tier, state=state,
        tiers=sorted(billing_service.TIER_CHOICES),
        states=["免费", "试用中", "有效", "已过期", "终身有效"],
        query=admin_service._pager_params(q=q, tier=tier, state=state),
    )


@router.get("/cloud-saves", response_class=HTMLResponse)
def cloud_saves_page(
    request: Request,
    user_id: str = "",
    q: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_cloud_saves(
        db, user_id=user_id, q=q, page=page, page_size=_PS
    )
    return render(
        "admin/cloud_saves.html", request, active="cloud_saves", data=data,
        user_id=user_id, q=q,
        query=admin_service._pager_params(user_id=user_id, q=q),
    )


@router.post("/cloud-saves/{blob_id}/delete")
def delete_cloud_save(
    blob_id: str,
    request: Request,
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    back = "/admin/ui/cloud-saves"
    qs = request.query_params.get("back_query", "")
    if qs:
        back += f"?{qs}"
    return perform(
        db, actor=actor, action="cloud_save.delete",
        target_type="cloud_save", target_id=blob_id, back=back,
        fn=lambda: admin_service.delete_cloud_save(db, blob_id),
    )


@router.get("/pairings", response_class=HTMLResponse)
def pairings_page(
    request: Request,
    user_id: str = "",
    q: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_pairings(
        db, user_id=user_id, q=q, page=page, page_size=_PS
    )
    return render(
        "admin/pairings.html", request, active="pairings", data=data,
        user_id=user_id, q=q,
        query=admin_service._pager_params(user_id=user_id, q=q),
    )


@router.post("/pairings/{pairing_id}/delete")
def delete_pairing(
    pairing_id: str,
    db: Session = Depends(get_db),
    actor: str = Depends(ui_admin),
):
    return perform(
        db, actor=actor, action="pairing.delete",
        target_type="pairing", target_id=pairing_id,
        back="/admin/ui/pairings",
        fn=lambda: admin_service.delete_pairing(db, pairing_id),
    )


@router.get("/consents", response_class=HTMLResponse)
def consents_page(
    request: Request,
    doc_key: str = "",
    q: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_consents(db, doc_key=doc_key, q=q, page=page, page_size=_PS)
    return render(
        "admin/consents.html", request, active="consents", data=data,
        doc_key=doc_key, q=q,
        query=admin_service._pager_params(doc_key=doc_key, q=q),
    )


@router.get("/billing", response_class=HTMLResponse)
def billing_page(
    request: Request,
    status_filter: str = "",
    q: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_billing(
        db, status_filter=status_filter, q=q, page=page, page_size=_PS
    )
    return render(
        "admin/billing.html", request, active="billing", data=data,
        status_filter=status_filter, q=q,
        query=admin_service._pager_params(status_filter=status_filter, q=q),
    )


@router.get("/audit", response_class=HTMLResponse)
def audit_page(
    request: Request,
    q: str = "",
    page: int = 1,
    db: Session = Depends(get_db),
    _: str = Depends(ui_admin),
):
    data = admin_service.list_audit(db, q=q, page=page, page_size=_PS)
    return render(
        "admin/audit.html", request, active="audit", data=data, q=q,
        query=admin_service._pager_params(q=q),
    )
