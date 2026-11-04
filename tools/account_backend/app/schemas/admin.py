"""后台管理 API 请求体。"""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field


class UserUpdateRequest(BaseModel):
    email: str | None = None
    display_name: str | None = None
    is_active: bool | None = None


class ResetPasswordRequest(BaseModel):
    new_password: str = Field(min_length=8, max_length=128)


class EntitlementUpdateRequest(BaseModel):
    tier: str
    lifetime: bool = False
    duration_days: int | None = Field(default=None, ge=1, le=3650)
    expiry_at: datetime | None = None


class TrialRequest(BaseModel):
    enabled: bool
