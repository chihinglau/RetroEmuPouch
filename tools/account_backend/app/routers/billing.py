from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import get_current_user
from ..models import Entitlement, User
from ..schemas.entitlement import *
from ..services import billing_service

router = APIRouter(prefix="/api/billing", tags=["billing"])


def _ent_to_response(user: User, ent: Entitlement) -> EntitlementResponse:
    return EntitlementResponse(
        user_id=user.id,
        tier=ent.tier,
        expiry_at=ent.expiry_at.isoformat() if ent.expiry_at else None,
        is_lifetime=ent.is_lifetime,
        trial_start=(ent.trial_start or user.trial_start).isoformat() if (ent.trial_start or user.trial_start) else None,
        is_ad_free=ent.is_ad_free,
        is_vip_active=ent.is_vip_active,
        blocks_interstitial_ads=ent.blocks_interstitial_ads,
        cloud_save_enabled=ent.cloud_save_enabled,
    )


@router.get("/entitlement", response_model=EntitlementResponse)
def get_entitlement(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    ent = db.query(Entitlement).filter(Entitlement.user_id == current_user.id).first()
    if not ent:
        ent = Entitlement(user_id=current_user.id, tier="free")
        db.add(ent)
        db.commit()
        db.refresh(ent)
    return _ent_to_response(current_user, ent)


@router.post("/verify", response_model=BillingVerifyResponse)
def verify_purchase(
    req: BillingVerifyRequest,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        ent = billing_service.verify_purchase(
            db, current_user, req.platform, req.sku, req.purchase_token, request
        )
        return BillingVerifyResponse(ok=True, entitlement=_ent_to_response(current_user, ent))
    except Exception as e:
        return BillingVerifyResponse(ok=False, error=str(e))


@router.post("/trial/start", response_model=TrialStartResponse)
def start_trial(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    ent = billing_service.start_trial(db, current_user)
    already = ent.trial_start is not None
    return TrialStartResponse(
        ok=True,
        trial_start=ent.trial_start.isoformat() if ent.trial_start else None,
        already_started=already,
    )
