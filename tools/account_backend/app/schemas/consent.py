from pydantic import BaseModel


class ConsentAcceptRequest(BaseModel):
    doc_key: str          # privacy_policy / eula
    version: int          # 用户点同意时文档的版本号（必须等于已发布版本）
    device_id: str        # 客户端生成 / 取 AndroidID 等 hash
    ip_hash: str | None = None
    user_agent: str | None = None


class ConsentStatusItem(BaseModel):
    doc_key: str
    latest_published_version: int
    my_consented_version: int | None = None     # None = 从未同意
    needs_reconsent: bool = False


class ConsentStatusResponse(BaseModel):
    statuses: list[ConsentStatusItem]


class ConsentAcceptResponse(BaseModel):
    ok: bool
    recorded_at: str
    version: int
