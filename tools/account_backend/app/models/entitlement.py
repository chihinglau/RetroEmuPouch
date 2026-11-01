from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, Boolean, ForeignKey
from datetime import datetime, timezone


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Entitlement(Base):
    """会员权益 —— 严格对齐 Dart 端 Entitlement 字段。"""

    __tablename__ = "entitlements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), unique=True, nullable=False)
    tier: Mapped[str] = mapped_column(String(32), nullable=False, default="free")
    # tier 取值: free / premium_monthly / premium_yearly / premium_lifetime
    #          / vip_monthly / vip_yearly / vip_lifetime
    expiry_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_lifetime: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    trial_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, nullable=False)

    user: Mapped["User"] = relationship(back_populates="entitlement")

    @property
    def is_trial_active(self) -> bool:
        if not self.trial_start or self.tier != "free":
            return False
        return (datetime.now(timezone.utc) - self.trial_start).days < 7

    @property
    def is_premium_active(self) -> bool:
        if self.is_lifetime:
            return True
        if not self.expiry_at:
            return False
        return datetime.now(timezone.utc) < self.expiry_at

    @property
    def is_vip_active(self) -> bool:
        """普通 VIP（vip_*）—— 仅去插屏。"""
        return self.tier in ("vip_monthly", "vip_yearly", "vip_lifetime") and self.is_premium_active

    @property
    def blocks_interstitial_ads(self) -> bool:
        return self.is_ad_free or self.is_vip_active or self.is_trial_active

    @property
    def is_ad_free(self) -> bool:
        """超级 VIP / 终身 / 试用窗内 —— 完全去广告。"""
        if self.tier in ("premium_monthly", "premium_yearly", "premium_lifetime") and self.is_premium_active:
            return True
        if self.is_trial_active:
            return True
        return False

    @property
    def cloud_save_enabled(self) -> bool:
        """付费档解锁云存档。"""
        if self.tier in ("premium_monthly", "premium_yearly", "premium_lifetime") and self.is_premium_active:
            return True
        if self.tier in ("vip_monthly", "vip_yearly", "vip_lifetime") and self.is_premium_active:
            return True
        return False
