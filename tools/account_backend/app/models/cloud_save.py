from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, ForeignKey, LargeBinary, Integer
from datetime import datetime, timezone
import uuid


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class CloudSaveBlob(Base):
    """云存档 Blob —— 客户端 AES-256-GCM 加密后上传，服务端不解密。"""

    __tablename__ = "cloud_save_blobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False)
    save_name: Mapped[str] = mapped_column(String(255), nullable=False)
    client_key_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    encrypted_blob: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, nullable=False)

    user: Mapped["User"] = relationship(back_populates="cloud_saves")
