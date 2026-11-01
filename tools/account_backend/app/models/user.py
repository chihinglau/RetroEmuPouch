from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, func, Boolean, Integer
import uuid
from datetime import datetime, timezone


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    display_name: Mapped[str] = mapped_column(String(64), nullable=False, default="Player")
    trial_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    is_admin: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)

    entitlement: Mapped["Entitlement | None"] = relationship(back_populates="user", uselist=False, cascade="all, delete-orphan")
    pairings: Mapped[list["PcPairing"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    billing_transactions: Mapped[list["BillingTransaction"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    cloud_saves: Mapped[list["CloudSaveBlob"]] = relationship(back_populates="user", cascade="all, delete-orphan")
    consent_records: Mapped[list["ConsentRecord"]] = relationship(back_populates="user", cascade="all, delete-orphan")
