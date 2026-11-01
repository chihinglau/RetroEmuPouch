"""Cloud save service —— 客户端 AES-256-GCM 加密后上传，服务端不解密。"""
from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone

from fastapi import HTTPException, UploadFile, status
from sqlalchemy.orm import Session

from ..config import settings
from ..models import CloudSaveBlob, User

# 白名单扩展名 —— 合规红线：只允许用户存档文件
ALLOWED_EXTENSIONS = {
    ".sav", ".state", ".save", ".bak",
    ".json", ".dat", ".mem", ".gm1",
}

# 黑名单关键词 —— ROM / BIOS / 大体积二进制
FORBIDDEN_KEYWORDS = re.compile(
    r"(neogeo\.zip|sm1\.sm1|qsound\.zip|\.rom$|\.bin$|\.zip$|\.7z$|\.iso$|\.chd$)",
    re.IGNORECASE,
)

MAX_UPLOAD_SIZE = 10 * 1024 * 1024  # 10 MB 每份存档足够


def _hash_device_key(raw_key: str) -> str:
    return hashlib.sha256((raw_key + settings.CLOUD_SAVE_KEY_SALT).encode()).hexdigest()


def _validate_save_name(name: str) -> None:
    if not name or len(name) > 255:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="bad_save_name")
    ext = "." + name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"extension_not_allowed (got {ext})",
        )
    if FORBIDDEN_KEYWORDS.search(name):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="forbidden_keyword")


async def upload_blob(
    db: Session,
    user: User,
    save_name: str,
    client_key: str,
    file: UploadFile,
) -> CloudSaveBlob:
    _validate_save_name(save_name)
    data = await file.read()
    if len(data) > MAX_UPLOAD_SIZE:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="too_large")

    blob = CloudSaveBlob(
        user_id=user.id,
        save_name=save_name,
        client_key_hash=_hash_device_key(client_key),
        encrypted_blob=data,
        sha256=hashlib.sha256(data).hexdigest(),
        size_bytes=len(data),
    )
    db.add(blob)
    db.commit()
    db.refresh(blob)
    return blob


def list_blobs(db: Session, user: User) -> list[CloudSaveBlob]:
    return (
        db.query(CloudSaveBlob)
        .filter(CloudSaveBlob.user_id == user.id)
        .order_by(CloudSaveBlob.updated_at.desc())
        .all()
    )


def get_blob(db: Session, user: User, blob_id: str) -> CloudSaveBlob:
    b = db.query(CloudSaveBlob).filter(CloudSaveBlob.id == blob_id, CloudSaveBlob.user_id == user.id).first()
    if not b:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="blob_not_found")
    return b


def delete_blob(db: Session, user: User, blob_id: str) -> None:
    b = get_blob(db, user, blob_id)
    db.delete(b)
    db.commit()
