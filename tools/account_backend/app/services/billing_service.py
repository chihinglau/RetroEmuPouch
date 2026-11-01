"""Billing service —— 收据校验分平台（MVP 走 dev mock stub）。"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException, Request, status
from sqlalchemy.orm import Session

from ..config import settings
from ..models import BillingTransaction, Entitlement, User


# SKU → (tier, 周期月数)
# 月/年/终身：m 次/年/终身
# 普通 VIP (vip_*) vs 超级 VIP (premium_*)
# 终身档 is_lifetime=True，expiry_at=None
# 月/年档计算 expiry_at = now + N months
SKU_MAP = {
    "premium_monthly": ("premium_monthly", 1),
    "premium_yearly": ("premium_yearly", 12),
    "premium_lifetime": ("premium_lifetime", None),
    "vip_monthly": ("vip_monthly", 1),
    "vip_yearly": ("vip_yearly", 12),
    "vip_lifetime": ("vip_lifetime", None),
}


def _add_months(dt: datetime, n: int) -> datetime:
    """简单按月推进（不处理月末边界，模拟器够用）。"""
    new_month = dt.month - 1 + n
    new_year = dt.year + new_month // 12
    final_month = new_month % 12 + 1
    try:
        return dt.replace(year=new_year, month=final_month)
    except ValueError:
        # 月末溢出（如 1月31日 加1月 → 2月28日/29日）
        return dt.replace(year=new_year, month=final_month, day=28)


def _grant_entitlement(db: Session, user_id: str, sku: str, now: datetime | None = None) -> Entitlement:
    """根据 SKU 写入 entitlement 并返回。"""
    if sku not in SKU_MAP:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="unknown_sku")

    tier, months = SKU_MAP[sku]
    now = now or datetime.now(timezone.utc)
    is_lifetime = months is None
    expiry_at: Optional[datetime] = None if is_lifetime else _add_months(now, months)

    ent = db.query(Entitlement).filter(Entitlement.user_id == user_id).first()
    if not ent:
        ent = Entitlement(id=str(uuid.uuid4()), user_id=user_id)
        db.add(ent)

    ent.tier = tier
    ent.is_lifetime = is_lifetime
    ent.expiry_at = expiry_at
    ent.updated_at = now
    db.commit()
    db.refresh(ent)
    return ent


def verify_purchase(
    db: Session,
    user: User,
    platform: str,
    sku: str,
    purchase_token: str,
    request: Request | None = None,
) -> Entitlement:
    """校验收据并授予 entitlement。MVP 阶段走 dev mock。

    真实 Phase 5：platform=android → Google Play Developer API；ohos → 华为 IAP Server API。
    """
    platform = platform.lower()
    if platform not in ("android", "ohos"):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="bad_platform")

    # ── Phase 5 真实验真（暂不实现） ──
    # if platform == "android":
    #     verified = _verify_google_play(purchase_token, sku)
    # elif platform == "ohos":
    #     verified = _verify_huawei_iap(purchase_token, sku)

    # ── MVP: dev mock ──
    header_mock = request.headers.get("X-Dev-Mock", "") if request else ""
    if settings.is_prod and not settings.ALLOW_DEV_MOCK:
        # prod 且禁 mock → 必须走真实验真（未实现）
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="verify_unavailable")
    if not header_mock:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="dev_mock_required (send X-Dev-Mock: 1 header)",
        )

    # 记录交易
    txn = BillingTransaction(
        id=str(uuid.uuid4()),
        user_id=user.id,
        platform=platform,
        sku=sku,
        purchase_token=purchase_token,
        status="verified",
        verified_at=datetime.now(timezone.utc),
    )
    db.add(txn)
    ent = _grant_entitlement(db, user.id, sku)
    return ent


def start_trial(db: Session, user: User) -> Entitlement:
    """首次登录时触发 7 天试用。服务端权威校验：trial_start IS NULL。"""
    ent = db.query(Entitlement).filter(Entitlement.user_id == user.id).first()
    if not ent:
        ent = Entitlement(id=str(uuid.uuid4()), user_id=user.id, tier="free")
        db.add(ent)

    if ent.trial_start is not None:
        # 已经启动过
        return ent

    now = datetime.now(timezone.utc)
    user.trial_start = now
    ent.trial_start = now
    ent.tier = "free"  # 试用期间 tier 仍为 free，试用判定靠 trial_start
    db.commit()
    db.refresh(ent)
    return ent
