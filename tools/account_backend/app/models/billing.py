from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, ForeignKey, Integer
from datetime import datetime, timezone
import uuid


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class BillingTransaction(Base):
    __tablename__ = "billing_transactions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False)
    platform: Mapped[str] = mapped_column(String(16), nullable=False)  # android / ohos
    sku: Mapped[str] = mapped_column(String(64), nullable=False)
    purchase_token: Mapped[str] = mapped_column(String(512), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")
    # status: pending / verified / rejected / expired
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)

    user: Mapped["User"] = relationship(back_populates="billing_transactions")
