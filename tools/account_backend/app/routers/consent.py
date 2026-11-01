"""同意记录端点 —— App 端调用。"""
from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import get_current_user_optional
from ..models import User
from ..schemas.consent import *
from ..services import cms_service

router = APIRouter(prefix="/api/consent", tags=["consent"])


# 必须有的文档清单（App 启动时要比对的）
REQUIRED_DOC_KEYS = ["privacy_policy", "eula"]


@router.get("/status", response_model=ConsentStatusResponse)
def get_status(
    request: Request,
    current_user: User | None = Depends(get_current_user_optional),
    db: Session = Depends(get_db),
):
    from ..services.cms_service import _hash_device_id
    # device_id 从 query 或 header 取（未登录时必须有）
    device_id = request.headers.get("X-Device-Id") or request.query_params.get("device_id")
    device_hash = _hash_device_id(device_id) if device_id else None

    statuses: list[ConsentStatusItem] = []
    for doc_key in REQUIRED_DOC_KEYS:
        latest = cms_service.get_latest_published(db, doc_key)
        latest_ver = latest.version if latest else 0

        consented = None
        if device_hash:
            consented = cms_service.get_latest_consented_version(
                db, doc_key, device_hash, current_user.id if current_user else None
            )

        statuses.append(ConsentStatusItem(
            doc_key=doc_key,
            latest_published_version=latest_ver,
            my_consented_version=consented,
            needs_reconsent=(consented is None or consented < latest_ver),
        ))

    return ConsentStatusResponse(statuses=statuses)


@router.post("/accept", response_model=ConsentAcceptResponse)
def accept(
    req: ConsentAcceptRequest,
    request: Request,
    current_user: User | None = Depends(get_current_user_optional),
    db: Session = Depends(get_db),
):
    # 验证：req.version 必须等于当前已发布版本
    latest = cms_service.get_latest_published(db, req.doc_key)
    if not latest:
        return ConsentAcceptResponse(ok=False, recorded_at="", version=0).model_dump()
    if req.version != latest.version:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=400,
            detail=f"version_mismatch (need {latest.version}, got {req.version})",
        )

    # 取 IP / UA
    client_ip = request.client.host if request.client else None
    ua = request.headers.get("user-agent")

    rec = cms_service.record_consent(
        db,
        doc_key=req.doc_key,
        version=req.version,
        device_id=req.device_id,
        user_id=current_user.id if current_user else None,
        ip=client_ip,
        user_agent=req.user_agent or ua,
    )
    return ConsentAcceptResponse(
        ok=True,
        recorded_at=rec.consented_at.isoformat(),
        version=rec.version,
    )
