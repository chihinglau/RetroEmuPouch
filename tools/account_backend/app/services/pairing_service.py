"""Pairing service —— PC 配对 token 签发/撤销。"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timezone

from fastapi import HTTPException, status
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from ..models import PcPairing, User

pairing_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")


def _hash_mac(mac: str, salt: str = "") -> str:
    return hashlib.sha256((mac + salt).encode()).hexdigest()


def register_pairing(
    db: Session,
    user: User,
    pc_name: str,
    pc_mac_hash: str,
) -> tuple[PcPairing, str]:
    """生成 per-user 的 PC 访问 token，返回 (pairing, raw_token)。

    raw_token 只返回一次（PC 端持久），DB 只存 bcrypt hash。
    """
    raw_token = secrets.token_urlsafe(48)
    token_hash = pairing_ctx.hash(raw_token)

    pairing = PcPairing(
        user_id=user.id,
        pc_name=pc_name,
        pc_mac_hash=pc_mac_hash,
        access_token_hash=token_hash,
    )
    db.add(pairing)
    db.commit()
    db.refresh(pairing)
    return pairing, raw_token


def list_pairings(db: Session, user: User) -> list[PcPairing]:
    return db.query(PcPairing).filter(PcPairing.user_id == user.id).order_by(PcPairing.created_at.desc()).all()


def delete_pairing(db: Session, user: User, pairing_id: str) -> None:
    p = db.query(PcPairing).filter(PcPairing.id == pairing_id, PcPairing.user_id == user.id).first()
    if not p:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="pairing_not_found")
    db.delete(p)
    db.commit()
