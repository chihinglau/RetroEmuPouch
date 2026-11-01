"""全局配置 —— 从环境变量/.env 加载，所有模块通过 settings 单例访问。"""
from __future__ import annotations

from functools import lru_cache
from typing import List

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # ── 基础 ──
    APP_NAME: str = "RetroEmuPouch-AccountBackend"
    APP_ENV: str = "dev"
    APP_PORT: int = 8000
    APP_CORS_ORIGINS: str = "*"

    # ── 数据库 ──
    DATABASE_URL: str = (
        "postgresql+psycopg://retroemupouch:changeme@localhost:5432/retroemupouch"
    )

    # ── JWT ──
    JWT_SECRET: str = "dev-secret-change-me"
    JWT_ALGORITHM: str = "HS256"
    JWT_ACCESS_TOKEN_EXPIRE_MINUTES: int = 15
    JWT_REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    ADMIN_TOKEN_SECRET: str = "dev-admin-secret-change-me"

    # ── 收据校验 ──
    GOOGLE_PLAY_SA_KEY_B64: str = ""
    GOOGLE_PLAY_PACKAGE_NAME: str = "com.retroemupouch.app"
    HUAWEI_IAP_CLIENT_ID: str = ""
    HUAWEI_IAP_CLIENT_SECRET: str = ""
    HUAWEI_IAP_APP_ID: str = ""

    # ── 安全 ──
    CLOUD_SAVE_KEY_SALT: str = "dev-cloud-save-salt"
    DEVICE_ID_SALT: str = "dev-device-id-salt"
    ALLOW_DEV_MOCK: bool = True

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def cors_origins_list(self) -> List[str]:
        if self.APP_CORS_ORIGINS.strip() == "*":
            return ["*"]
        return [o.strip() for o in self.APP_CORS_ORIGINS.split(",") if o.strip()]

    @property
    def is_prod(self) -> bool:
        return self.APP_ENV == "prod"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
