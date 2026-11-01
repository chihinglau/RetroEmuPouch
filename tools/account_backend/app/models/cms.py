from .database import Base
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, DateTime, Text, Integer, UniqueConstraint, Index
from datetime import datetime, timezone
import uuid


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class CmsDocument(Base):
    """CMS 文档 —— 隐私政策 / 用户协议 / 关于页文案 / FAQ。

    每个 (doc_key, language) 可有多 version 多状态（draft/published），
    同一 doc_key+language 同一时刻仅一个 published 版本（旧 published 自动归档）。
    """

    __tablename__ = "cms_documents"
    __table_args__ = (
        UniqueConstraint("doc_key", "version", "language", name="uq_cms_doc_key_ver_lang"),
        Index("idx_cms_doc_key_lang_pub", "doc_key", "language", "status"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    doc_key: Mapped[str] = mapped_column(String(32), index=True, nullable=False)
    # doc_key: privacy_policy / eula / about / faq
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    language: Mapped[str] = mapped_column(String(5), nullable=False)  # zh / en
    title: Mapped[str] = mapped_column(String(128), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)  # Markdown
    summary: Mapped[str | None] = mapped_column(String(255), nullable=True)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="draft")
    # status: draft / published / archived
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, nullable=False)


class AppConfig(Base):
    """应用动态配置 —— 替代客户端 LegalConstants 全部静态项。"""

    __tablename__ = "app_configs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    config_key: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    config_value: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str | None] = mapped_column(String(255), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, onupdate=_utcnow, nullable=False)


class ConsentRecord(Base):
    """用户同意记录 —— 合规模板：谁在什么时候同意了哪个版本的哪个文档。"""

    __tablename__ = "consent_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    device_id: Mapped[str] = mapped_column(String(128), index=True, nullable=False)
    doc_key: Mapped[str] = mapped_column(String(32), index=True, nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    consented_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow, nullable=False)
    ip_hash: Mapped[str | None] = mapped_column(String(128), nullable=True)
    user_agent: Mapped[str | None] = mapped_column(String(512), nullable=True)

    user: Mapped["User | None"] = relationship(back_populates="consent_records")
