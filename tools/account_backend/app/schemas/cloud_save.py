from pydantic import BaseModel


class CloudSaveListResponse(BaseModel):
    id: str
    save_name: str
    size_bytes: int
    sha256: str
    created_at: str
    updated_at: str


class CloudSaveUploadResponse(BaseModel):
    ok: bool
    save_id: str
