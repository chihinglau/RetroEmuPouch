"""Entitlement schema —— 严格对齐 Dart 端 EntitlementResponse 字段。"""
from pydantic import BaseModel


class EntitlementResponse(BaseModel):
    user_id: str
    tier: str                       # free / premium_monthly / premium_yearly / premium_lifetime / vip_monthly / ...
    expiry_at: str | None = None    # ISO 8601
    is_lifetime: bool = False
    trial_start: str | None = None  # ISO 8601

    # ── 派生（对齐 Dart 端判定）──
    is_ad_free: bool = False        # 超级 VIP / 终身 / 试用窗内
    is_vip_active: bool = False     # 普通 VIP 生效中
    blocks_interstitial_ads: bool = False
    cloud_save_enabled: bool = False


class BillingVerifyRequest(BaseModel):
    platform: str                   # android / ohos
    sku: str                        # premium_monthly / ...
    purchase_token: str             # 平台返回的 purchaseToken / receipt
    # 可选：dev mock 时指定要授予的 tier
    dev_target_tier: str | None = None


class BillingVerifyResponse(BaseModel):
    ok: bool
    entitlement: EntitlementResponse | None = None
    error: str | None = None


class BillingRestoreRequest(BaseModel):
    platform: str
    # Android 传 purchase_token (Google 恢复购买时返回)
    # OHOS 传 orderId
    user_purchase_identifier: str | None = None


class TrialStartResponse(BaseModel):
    ok: bool
    trial_start: str | None = None
    already_started: bool = False
