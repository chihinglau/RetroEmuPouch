"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-11-04
"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("email", sa.String(255), nullable=False, unique=True),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column("display_name", sa.String(64), nullable=False,
                  server_default="Player"),
        sa.Column("trial_start", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_admin", sa.Boolean(), nullable=False,
                  server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
    )
    op.create_index("ix_users_email", "users", ["email"])

    op.create_table(
        "entitlements",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("tier", sa.String(32), nullable=False,
                  server_default="free"),
        sa.Column("expiry_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_lifetime", sa.Boolean(), nullable=False,
                  server_default=sa.false()),
        sa.Column("trial_start", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("user_id"),
    )
    op.create_index("ix_entitlements_user_id", "entitlements", ["user_id"])

    op.create_table(
        "pc_pairings",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("pc_name", sa.String(64), nullable=False),
        sa.Column("pc_mac_hash", sa.String(128), nullable=False),
        sa.Column("access_token_hash", sa.String(255), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_pc_pairings_user_id", "pc_pairings", ["user_id"])

    op.create_table(
        "billing_transactions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("platform", sa.String(16), nullable=False),
        sa.Column("sku", sa.String(64), nullable=False),
        sa.Column("purchase_token", sa.String(512), nullable=False),
        sa.Column("status", sa.String(16), nullable=False,
                  server_default="pending"),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_billing_transactions_user_id",
                    "billing_transactions", ["user_id"])

    op.create_table(
        "cloud_save_blobs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("save_name", sa.String(255), nullable=False),
        sa.Column("client_key_hash", sa.String(128), nullable=False),
        sa.Column("encrypted_blob", sa.LargeBinary(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_cloud_save_blobs_user_id",
                    "cloud_save_blobs", ["user_id"])

    op.create_table(
        "cms_documents",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("doc_key", sa.String(32), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("language", sa.String(5), nullable=False),
        sa.Column("title", sa.String(128), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("summary", sa.String(255), nullable=True),
        sa.Column("status", sa.String(16), nullable=False,
                  server_default="draft"),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.String(36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.UniqueConstraint("doc_key", "version", "language",
                             name="uq_cms_doc_key_ver_lang"),
    )
    op.create_index("idx_cms_doc_key_lang_pub", "cms_documents",
                    ["doc_key", "language", "status"])
    op.create_index("ix_cms_documents_doc_key", "cms_documents", ["doc_key"])

    op.create_table(
        "app_configs",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("config_key", sa.String(64), nullable=False, unique=True),
        sa.Column("config_value", sa.Text(), nullable=False),
        sa.Column("description", sa.String(255), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
    )

    op.create_table(
        "consent_records",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=True),
        sa.Column("device_id", sa.String(128), nullable=False),
        sa.Column("doc_key", sa.String(32), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("consented_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.Column("ip_hash", sa.String(128), nullable=True),
        sa.Column("user_agent", sa.String(512), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="SET NULL"),
    )
    op.create_index("ix_consent_records_user_id", "consent_records", ["user_id"])
    op.create_index("ix_consent_records_device_id",
                    "consent_records", ["device_id"])
    op.create_index("ix_consent_records_doc_key",
                    "consent_records", ["doc_key"])


def downgrade() -> None:
    op.drop_table("consent_records")
    op.drop_table("app_configs")
    op.drop_table("cms_documents")
    op.drop_table("cloud_save_blobs")
    op.drop_table("billing_transactions")
    op.drop_table("pc_pairings")
    op.drop_table("entitlements")
    op.drop_table("users")
