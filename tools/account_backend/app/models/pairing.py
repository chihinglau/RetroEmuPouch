from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, ForeignKey
from datetime import datetime, timezone
import uuid


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class PcPairing(Base):
    __tablename__ = "pc_pairings"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False)
    pc_name: Mapped[str] = mapped_column(String(64), nullable=False)
    pc_mac_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    access_token_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)

    user: Mapped["User"] = relationship(back_populates="pairings")
