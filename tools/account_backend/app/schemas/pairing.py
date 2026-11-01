from pydantic import BaseModel, Field


class PairingRegisterRequest(BaseModel):
    code: str = Field(min_length=8, max_length=64)
    pc_name: str = Field(min_length=1, max_length=64)
    pc_mac_hash: str = Field(min_length=8, max_length=128)


class PairingRegisterResponse(BaseModel):
    ok: bool
    pc_access_token: str | None = None
    error: str | None = None


class PairingItem(BaseModel):
    id: str
    pc_name: str
    pc_mac_hash: str
    last_seen_at: str | None = None
    created_at: str


class PairingListResponse(BaseModel):
    pairings: list[PairingItem]
