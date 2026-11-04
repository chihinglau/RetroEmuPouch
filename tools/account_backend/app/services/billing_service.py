"""Billing service —— 收据校验分平台（MVP 走 dev mock stub）。"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
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


TIER_CHOICES: tuple[str, ...] = ("free",) + tuple(SKU_MAP.keys())


def entitlement_state(ent: Entitlement | None) -> str:
    """给后台列表用的人类可读权益状态。"""
    if ent is None:
        return "无记录"
    if ent.tier == "free":
        return "试用中" if ent.is_trial_active else "免费"
    if ent.is_lifetime:
        return "终身有效"
    return "有效" if ent.is_premium_active else "已过期"


def set_entitlement(
    db: Session,
    user_id: str,
    tier: str,
    *,
    lifetime: bool = False,
    duration_days: int | None = None,
    expiry_at: datetime | None = None,
) -> Entitlement:
    """后台/购买共用的权益写入（幂等 upsert）。

    tier='free' 表示撤销权益（清终身标记与到期时间，保留 trial_start 试用记录）。
    其它档位：终身档或 lifetime=True 忽略到期；否则优先 expiry_at，其次
    duration_days，最后按 SKU_MAP 的月数自动计算。
    不写 BillingTransaction（后台人工调整由审计日志记录，避免污染对账流水）。
    """
    if tier not in TIER_CHOICES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="unknown_tier")

    now = datetime.now(timezone.utc)
    ent = db.query(Entitlement).filter(Entitlement.user_id == user_id).first()
    if not ent:
        ent = Entitlement(id=str(uuid.uuid4()), user_id=user_id, tier="free")
        db.add(ent)

    if tier == "free":
        ent.tier = "free"
        ent.is_lifetime = False
        ent.expiry_at = None
    else:
        is_lifetime = bool(lifetime) or tier.endswith("_lifetime")
        if is_lifetime:
            expiry = None
        elif expiry_at is not None:
            # 表单/API 可能传 naive 时间，统一按 UTC 解释
            expiry = expiry_at if expiry_at.tzinfo else expiry_at.replace(tzinfo=timezone.utc)
        elif duration_days and duration_days > 0:
            expiry = now + timedelta(days=duration_days)
        else:
            months = SKU_MAP[tier][1]
            expiry = _add_months(now, months) if months else None
            is_lifetime = months is None

        ent.tier = tier
        ent.is_lifetime = is_lifetime
        ent.expiry_at = expiry

    ent.updated_at = now
    db.commit()
    db.refresh(ent)
    return ent


def set_trial(db: Session, user_id: str, enabled: bool) -> Entitlement:
    """后台开启/清除 7 天试用（同时写 users.trial_start 与 entitlement.trial_start）。"""
    user = db.get(User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user_not_found")
    ent = db.query(Entitlement).filter(Entitlement.user_id == user_id).first()
    if not ent:
        ent = Entitlement(id=str(uuid.uuid4()), user_id=user_id, tier="free")
        db.add(ent)
    moment = datetime.now(timezone.utc) if enabled else None
    user.trial_start = moment
    ent.trial_start = moment
    ent.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(ent)
    return ent


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
