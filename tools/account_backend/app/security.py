"""密码哈希 + JWT 签发/验签。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Literal

from jose import JWTError, jwt
from passlib.context import CryptContext

from .config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(plain: str) -> str:
    return pwd_context.hash(plain)


def verify_password(plain: str, hashed: str) -> bool:
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        return False


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def create_access_token(sub: str, extra: Dict[str, Any] | None = None) -> str:
    expire = _now_utc() + timedelta(minutes=settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES)
    payload: Dict[str, Any] = {"sub": sub, "exp": expire, "type": "access"}
    if extra:
        payload.update(extra)
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)


def create_refresh_token(sub: str) -> str:
    expire = _now_utc() + timedelta(days=settings.JWT_REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {"sub": sub, "exp": expire, "type": "refresh"}
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)


def decode_token(token: str) -> Dict[str, Any] | None:
    try:
        return jwt.decode(token, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
    except JWTError:
        return None


def create_admin_token(sub: str) -> str:
    """Admin JWT —— 用独立 secret 签发，payload 带 role=admin。"""
    expire = _now_utc() + timedelta(hours=8)
    payload: Dict[str, Any] = {"sub": sub, "exp": expire, "type": "access", "role": "admin"}
    return jwt.encode(payload, settings.ADMIN_TOKEN_SECRET, algorithm=settings.JWT_ALGORITHM)


def decode_admin_token(token: str) -> Dict[str, Any] | None:
    try:
        payload = jwt.decode(token, settings.ADMIN_TOKEN_SECRET, algorithms=[settings.JWT_ALGORITHM])
        if payload.get("role") != "admin":
            return None
        return payload
    except JWTError:
        return None
