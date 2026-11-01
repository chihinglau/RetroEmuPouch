from pydantic import BaseModel


class CmsDocResponse(BaseModel):
    doc_key: str
    language: str
    version: int
    title: str
    summary: str | None = None
    content: str


class CmsDocMetaResponse(BaseModel):
    doc_key: str
    language: str
    latest_published_version: int
    summary: str | None = None
    published_at: str | None = None


class AppConfigItem(BaseModel):
    config_key: str
    config_value: str


class AppConfigMap(BaseModel):
    # 动态 key-value，App 启动时一次性拉取
    configs: dict[str, str]


# ── Admin ──
class CmsDocCreateRequest(BaseModel):
    doc_key: str
    language: str
    version: int
    title: str
    content: str
    summary: str | None = None


class CmsDocUpdateRequest(BaseModel):
    title: str | None = None
    content: str | None = None
    summary: str | None = None


class AppConfigUpdateRequest(BaseModel):
    config_value: str
    description: str | None = None


class ConsentStatsItem(BaseModel):
    version: int
    consented_count: int


class ConsentStatsResponse(BaseModel):
    doc_key: str
    total_consents: int
    latest_published_version: int
    breakdown: list[ConsentStatsItem]
