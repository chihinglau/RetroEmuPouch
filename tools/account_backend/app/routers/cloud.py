from fastapi import APIRouter, Depends, File, Form, UploadFile
from sqlalchemy.orm import Session

from ..database import get_db
from ..dependencies import require_cloud_save_entitlement
from ..models import CloudSaveBlob, User
from ..schemas.cloud_save import *
from ..services import cloud_service

router = APIRouter(prefix="/api/cloud/saves", tags=["cloud-saves"])


@router.post("/upload", response_model=CloudSaveUploadResponse)
async def upload(
    save_name: str = Form(...),
    client_key: str = Form(...),
    file: UploadFile = File(...),
    current_user: User = Depends(require_cloud_save_entitlement),
    db: Session = Depends(get_db),
):
    blob = await cloud_service.upload_blob(db, current_user, save_name, client_key, file)
    return CloudSaveUploadResponse(ok=True, save_id=blob.id)


@router.get("/list", response_model=list[CloudSaveListResponse])
def list_saves(
    current_user: User = Depends(require_cloud_save_entitlement),
    db: Session = Depends(get_db),
):
    blobs = cloud_service.list_blobs(db, current_user)
    return [
        CloudSaveListResponse(
            id=b.id,
            save_name=b.save_name,
            size_bytes=b.size_bytes,
            sha256=b.sha256,
            created_at=b.created_at.isoformat(),
            updated_at=b.updated_at.isoformat(),
        )
        for b in blobs
    ]


@router.get("/{blob_id}")
def download(
    blob_id: str,
    current_user: User = Depends(require_cloud_save_entitlement),
    db: Session = Depends(get_db),
):
    blob = cloud_service.get_blob(db, current_user, blob_id)
    from fastapi.responses import Response
    return Response(
        content=blob.encrypted_blob,
        media_type="application/octet-stream",
        headers={"X-Save-SHA256": blob.sha256},
    )


@router.delete("/{blob_id}")
def delete(
    blob_id: str,
    current_user: User = Depends(require_cloud_save_entitlement),
    db: Session = Depends(get_db),
):
    cloud_service.delete_blob(db, current_user, blob_id)
    return {"ok": True}
