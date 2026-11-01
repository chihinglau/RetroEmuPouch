# 设计方案：账号云服务后台 Web 服务

> 本文档为**方案文档，不含任何代码实现**。
> 约束前提：本后端为 `RetroEmuPouch` App 提供账号/配对/会员/云存档/**内容管理（隐私政策等）**能力，**绝不触碰 ROM / BIOS 二进制分发**。

## 文档信息

| 项 | 值 |
|---|---|
| 版本 | v0.2（补充 CMS 与同意管理） |
| 日期 | 2026-11-02 |
| 范围 | 技术栈、数据模型、API、CMS/隐私内容管理、部署、分阶段交付 |
| 依赖 | `docs/design-account-cloud-ads-membership.md`（总方案）；客户端 `ReceiptVerifier` / `BillingService` / `AccountService` / `LegalConstants` / `ConsentGate` 骨架 |
| 状态 | 待决策 |

---

## 零、先对齐：客户端已落地的契约（后端必须严格遵守）

后端 API / SKU / 字段名不能偏离以下已在 Dart 端硬编码的约定，否则客户端骨架白搭：

| 来源文件 | 字段 / 常量 | 值 |
|---|---|---|
| `billing_service.dart` SKU 硬编码 | 超级 VIP | `premium_monthly` / `premium_yearly` / `premium_lifetime` |
| 同上 | 普通 VIP | `vip_monthly` / `vip_yearly` / `vip_lifetime` |
| `receipt_verifier.dart` 注释 | 校验端点约定 | `POST /api/billing/verify` |
| 同上 | 返回类型 | `Entitlement?`（含 `tier / expiry / isLifetime / isAdFree / isVipActive / blocksInterstitialAds / cloudSaveEnabled` 等字段） |
| `account_service.dart` | 本地占位 | `userId` / `displayName`，需接服务端 |
| `legal_constants.dart` | 全部静态硬编码 | `privacyPolicyUrl` / `filingNumber` / `feedbackUrl` / `feedbackEmail` / `qqGroup` / `wechatId` / `shareMessage` |
| `consent_gate.dart` | 本地 `SharedPreferences` 存 `consent_given:bool`，**无版本号** | 政策更新后老用户不会被要求重新同意（合规风险） |

**目标**：把 `LegalConstants` 的动态项迁到后端下发，`ConsentGate` 改为"用户同意记录落库 + 政策版本号比对"模式。

---

## 一、技术栈候选

| 方案 | 语言 | 框架 | 数据库 | 优点 | 缺点 |
|---|---|---|---|---|---|
| **A（推荐）** | Python 3.12 | FastAPI（async + OpenAPI 自动文档）+ Jinja2（管理页面） | PostgreSQL + SQLAlchemy + Alembic 迁移 | 与 `peer_host.py` 同生态；async 好写；自动 Swagger；简易 Admin 页面也能写 | 需要 psycopg 驱动 |
| B | TypeScript | Fastify / NestJS | PostgreSQL + Prisma | 类型安全；NestJS 结构清晰 | 多一套生态 |
| C | Go | Gin / Fiber | PostgreSQL | 性能最强；单二进制部署 | 重学 |

**推荐 A** —— 与 `peer_host.py` 同生态，后端扩展最顺手；FastAPI 自动 Swagger 方便调试；Jinja2 能快速做简易 Admin 内容编辑页。

---

## 二、核心数据模型

### 2.1 账号 / 权益 / 配对 / 计费（原方案）

```
┌──────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
│ users        │   │ pc_pairings          │   │ entitlements        │
├──────────────┤   ├──────────────────────┤   ├─────────────────────┤
│ id (PK)      │   │ id (PK)              │   │ id (PK)             │
│ email (UNQ)  │◄──│ user_id (FK)         │   │ user_id (FK,UNIQUE) │
│ password_hash│   │ pc_name              │◄──│ tier                 │
│ display_name │   │ pc_mac_hash          │   │ expiry_at            │
│ trial_start  │   │ access_token (HASH)  │   │ is_lifetime          │
│ created_at   │   │ last_seen_at         │   │ trial_start          │
└──────┬───────┘   └──────────────────────┘   │ updated_at           │
       │                                       └─────────────────────┘
       │ (1:N)
       ▼
┌──────────────────────┐
│ billing_transactions │
├──────────────────────┤
│ id (PK)              │
│ user_id (FK)         │
│ platform (android/   │
│          ohos)       │
│ sku                  │
│ purchase_token       │
│ status               │
│ created_at           │
└──────────────────────┘
```

### 2.2 云存档（合规红线：客户端 AES-256-GCM 加密后上传，服务端不解密）

```
┌──────────────────────┐
│ cloud_save_blobs     │
├──────────────────────┤
│ id (PK)              │
│ user_id (FK)         │
│ save_name            │
│ client_key_hash      │  ← 密钥用户侧生成，服务端只存 hash
│ encrypted_blob       │  ← AES-256-GCM 由客户端加完上传
│ sha256               │
│ size_bytes           │
│ created_at           │
│ updated_at           │
└──────────────────────┘
```

### 2.3 CMS 内容管理（新增）

```
┌────────────────────────────────────┐
│ cms_documents                      │  ← 隐私政策 / 用户协议 / 关于页文案 / FAQ
├────────────────────────────────────┤
│ id (PK)                            │
│ doc_key (INDEX)                    │  ← privacy_policy / eula / about / faq
│ version (INDEX, BIGINT)            │  ← 单调递增；政策版本号比对用这个
│ language (INDEX, VARCHAR 5)        │  ← zh / en
│ title                              │  ← "隐私政策" / "Privacy Policy"
│ content                            │  ← Markdown 正文
│ summary                            │  ← 一句话摘要（变更说明，如 "v3 新增数据保留期限条款"）
│ status                             │  ← draft / published
│ published_at                       │  ← 发布时间；未发布为 NULL
│ created_by                         │  ← admin user id
│ created_at                         │
│ updated_at                         │
│ UNIQUE(doc_key, version, language) │
└────────────────────────────────────┘

┌────────────────────────────────────┐
│ app_configs                        │  ← LegalConstants 动态项集中托管
├────────────────────────────────────┤
│ id (PK)                            │
│ config_key (UNIQUE)                │  ← filing_number / feedback_url / feedback_email /
│                                    │     qq_group / wechat_id / share_message /
│                                    │     enable_consent_gate / ad_sdk_consent_required / ...
│ config_value (TEXT / JSON)         │  ← 值可以是字符串或 JSON 对象
│ description                        │  ← "工信部 APP 备案号"
│ updated_at                         │
└────────────────────────────────────┘

┌────────────────────────────────────┐
│ consent_records                    │  ← 用户同意记录（合规模板：谁在什么时候同意了哪个版本）
├────────────────────────────────────┤
│ id (PK)                            │
│ user_id (FK, NULL)                 │  ← 登录用户落库，未登录用户用 device_id 或匿名 session
│ device_id (INDEX, VARCHAR 128)     │  ← Android IMEI/AndroidID hash / OHOS OAID hash / 生成 uuid
│ doc_key (INDEX)                    │  ← privacy_policy / eula / ...
│ version (BIGINT)                   │  ← 同意时的版本号
│ consented_at                       │  ← 时间戳
│ ip_hash                            │  ← 可选：合规审计用，只存 hash
│ user_agent                         │  ← 可选
└────────────────────────────────────┘
```

### 合规红线强制

- `cloud_save_blobs` 只存用户的**存档文件**（`.sav` / `.state` / 设置 JSON），**不接受 `.zip` / `.7z` / ROM 扩展名**；上传端点扩展名白名单校验 + 运行时 MIME 嗅探双重校验；
- 二进制内容**客户端先 AES-256-GCM 加密**再上传，服务端**不解密、不留密钥** —— 运营方看不到内容；
- ROM / BIOS 相关关键词（`neogeo` / `sm1.sm1` / `*.bin`）在 blob metadata 里出现即拒绝；
- `pc_pairings` 只记录「别名 + MAC hash」，**不存任何 ROM / BIOS 路径或元数据**；
- `consent_records` 是**合规审计必需**：两个商店（华为 AppGallery / Google Play）都要求能证明"用户确实同意过对应版本的隐私政策"。

---

## 三、API 设计（RESTful，分组）

### 3.1 认证 `/api/auth/*`

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/auth/register` | 邮箱 + 密码 + displayName → 返回 access_token（JWT） |
| POST | `/api/auth/login` | 邮箱 + 密码 → 返回 access_token + refresh_token |
| POST | `/api/auth/refresh` | refresh_token → 换新 access_token |
| POST | `/api/auth/logout` | 客户端清本地 token（简单模式无服务端黑名单） |
| GET  | `/api/auth/me` | 返回当前用户基本信息（userId / displayName / trialStart） |

### 3.2 会员权益 `/api/billing/*`（核心）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/billing/verify` | **核心端点**：客户端发 `{platform, sku, purchase_token}` → 服务端调 Google Play Developer API / 华为 IAP API 验真 → 写 `entitlements` + 记 `billing_transactions` → 返回最新 entitlement |
| GET  | `/api/billing/entitlement` | App 启动时 / 前台刷新拉取当前权益 |
| POST | `/api/billing/restore` | "恢复购买" —— 传平台 + 用户标识，服务端重验该用户全部历史购买 |
| POST | `/api/billing/trial/start` | 首次登录时触发 7 天试用（服务端权威校验 `trial_start IS NULL`） |

### 3.3 PC 配对 `/api/pairing/*`

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/pairing/register` | 首次配对：PC 带一次性 code → 服务端生成 per-user `access_token`（PC 端持久） |
| GET  | `/api/pairing/list` | App 拉已绑定 PC 列表（仅别名，不含任何 ROM 信息） |
| DELETE | `/api/pairing/{id}` | 解绑 |

### 3.4 云存档（会员专属）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/cloud/saves/upload` | entitlement 校验（`cloudSaveEnabled=true`） → 扩展名白名单 → 接收加密 blob |
| GET  | `/api/cloud/saves/list` | 列出当前用户存档（仅元信息） |
| GET  | `/api/cloud/saves/{id}` | 下载加密 blob |
| DELETE | `/api/cloud/saves/{id}` | 删除 |

### 3.5 CMS 公开端点（App 端拉取，**无需登录**）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET  | `/api/cms/docs/{doc_key}?lang=zh` | 获取指定文档**最新已发布版本**（Markdown 正文 + version 号 + summary）。doc_key 取值：`privacy_policy` / `eula` / `about` / `faq` |
| GET  | `/api/cms/config` | 一次性返回 `app_configs` 全部 key-value —— 客户端启动时拉一次，缓存到本地，替代全部 `LegalConstants` 静态项 |
| GET  | `/api/cms/doc-meta/{doc_key}` | 只返回最新已发布版本号 + 变更摘要，用于客户端比对本地缓存版本、判断是否需要重新加载 |

### 3.6 同意记录 `/api/consent/*`

| 方法 | 路径 | 说明 |
|---|---|---|
| GET  | `/api/consent/status` | 返回：当前已发布的 `privacy_policy` + `eula` 的最新 version，以及当前用户（或 device_id）已同意的 version。客户端比对 → 若已发布版本 > 已同意版本 → 重新弹 ConsentGate |
| POST | `/api/consent/accept` | 客户端点"同意并继续"时上报：`{doc_key, version, device_id}`（登录用户附带 user_id）→ 服务端落库 `consent_records` |

### 3.7 Admin 管理端点（仅你自己用，需 admin JWT）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET  | `/admin/docs` | 列出所有文档（含 draft + published） |
| POST | `/admin/docs` | 创建新文档草稿（指定 doc_key / version / language） |
| PUT  | `/admin/docs/{id}` | 编辑草稿内容（Markdown 正文） |
| POST | `/admin/docs/{id}/publish` | 发布草稿 → 状态变 published；同一 doc_key+language 之前的 published 版本自动归档（仍保留历史） |
| GET  | `/admin/config` | 列出所有 app_configs |
| PUT  | `/admin/config/{key}` | 更新单个配置项 |
| GET  | `/admin/consent-stats?doc_key=privacy_policy` | 统计：有多少用户/设备同意过当前版本、各版本同意分布 |

> Admin 管理界面可以用 Jinja2 做几个简单页面（文档列表 / Markdown 编辑 / 配置表单），也可以只提供 API + curl/HTTPie 脚本。推荐先做 API，后续补 UI。

---

## 四、客户端对接改造（从方案到落地）

### 4.1 `LegalConstants` 退化为本地默认值

```dart
// 改造前：全部静态常量
class LegalConstants {
  static const String privacyPolicyUrl = 'https://...';
  static const String filingNumber = '';
  // ...
}

// 改造后：启动时从 /api/cms/config 拉取，失败回退默认值
class AppConfigService {
  Future<Map<String, dynamic>> fetchCmsConfig() async { ... }
}
```

### 4.2 `ConsentGate` 升级：**版本号感知**

```
启动 → GET /api/consent/status → 拿到当前已发布版本号
  ├─ 本地 consent_given_version >= 已发布版本 → 跳过，直接进 App
  └─ 本地 consent_given_version < 已发布版本（或从未同意） → 弹 ConsentGate
        └─ 点"同意并继续" → POST /api/consent/accept → 本地存版本号
```

**为什么需要版本号**：两个商店都要求"政策更新后用户必须重新同意"。没有版本号 = 合规隐患。

### 4.3 `PrivacyPolicyPage` / `EulaPage` 内容来源

```
改造前：本地硬编码文本 / GitHub Pages URL 打开
改造后：GET /api/cms/docs/{doc_key}?lang=zh → Markdown → 用 flutter_markdown 渲染
       失败时回退本地 Asset 兜底（assets/legal/privacy_policy_zh.md）
```

---

## 五、JWT 认证方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| **A（推荐）无状态** | 简单；access_token 短寿（15 min）+ refresh_token 长效（30 d） | 无服务端登出黑名单（如需强制失效必须加 Redis / DB check） |
| B 服务端会话（DB 存 session_id） | 可登出失效，但每次请求查 DB | 重 |

**推荐 A**。JWT payload：
```json
{
  "sub": "user-uuid-or-int-id",
  "email": "u***@example.com",
  "exp": 1733250000
}
```

Admin 用独立的 `admin_access_token`（单独 secret 签发），或直接在用户表加 `is_admin:bool`。

---

## 六、收据校验分平台（Phase 3 凭证前置）

```
POST /api/billing/verify
     │
     ▼
┌──────────────────────────────────────┐
│ 服务端校验                              │
│  platform == "android"                 │
│   → Google Play Developer API v3       │
│     purchases.products.get()           │
│     (凭证：ServiceAccountKey.json)      │
│  platform == "ohos"                    │
│   → 华为 IAP Server API                │
│     orderquery / verifyOrder            │
│     (凭证：ClientID + ClientSecret +   │
│      应用ID)                            │
│ 验真通过 → 写 billing_transactions +  │
│  entitlements，返回 entitlement         │
│ 验真失败 → 返回 400 + 错误码 + 客户端兜底 │
└──────────────────────────────────────┘
```

### 凭证安全

- Google Service Account JSON / 华为 ClientSecret 都放在**服务端环境变量**或 `secrets/` 文件里，**绝对不入 Git**；
- `.env.example` 列出占位；
- 一期 MVP 无真实凭证时，`verify` stub 接受 `X-Dev-Mock: 1` 头（仅限本地 / staging）模拟验真通过。

---

## 七、部署方案

| 方案 | 适用场景 | 说明 |
|---|---|---|
| **A（推荐，自托管）** | 先跑起来、成本低 | 自有机器（或阿里云 / 腾讯云轻量服务器）→ Docker Compose 起 FastAPI + PostgreSQL + Nginx |
| B 上云省心 | Fly.io / Render / Railway（免运维，自带 Postgres 托管） | 快速上线 |
| C 国内合规 | 华为云 ECS + RDS PostgreSQL + CDN | 华为生态契合（OHOS 上架推荐） |

---

## 八、项目结构（FastAPI + SQLAlchemy）

```
tools/
└── account_backend/
    ├── app/
    │   ├── main.py                      ← FastAPI 入口 + 路由注册
    │   ├── config.py                    ← 环境变量 / secrets 加载
    │   ├── database.py                  ← SQLAlchemy session / engine
    │   ├── dependencies.py              ← FastAPI Depends（get_current_user / require_entitlement / require_admin）
    │   ├── models/
    │   │   ├── __init__.py
    │   │   ├── user.py                  ← User
    │   │   ├── entitlement.py           ← Entitlement
    │   │   ├── pairing.py               ← PcPairing
    │   │   ├── billing.py               ← BillingTransaction
    │   │   ├── cloud_save.py            ← CloudSaveBlob
    │   │   ├── cms.py                   ← CmsDocument + AppConfig + ConsentRecord
    │   │   └── admin_user.py
    │   ├── schemas/
    │   │   ├── __init__.py
    │   │   ├── auth.py
    │   │   ├── entitlement.py           ← 严格对齐 Dart Entitlement 字段
    │   │   ├── billing.py
    │   │   ├── pairing.py
    │   │   ├── cloud_save.py
    │   │   ├── cms.py                   ← CmsDocumentResponse / AppConfigResponse
    │   │   └── consent.py               ← ConsentAcceptRequest / ConsentStatusResponse
    │   ├── routers/
    │   │   ├── __init__.py
    │   │   ├── auth.py
    │   │   ├── billing.py
    │   │   ├── pairing.py
    │   │   ├── cloud.py
    │   │   ├── cms_public.py            ← /api/cms/* 公开端点（App 拉取）
    │   │   ├── consent.py               ← /api/consent/*
    │   │   └── admin/
    │   │       ├── __init__.py
    │   │       ├── docs.py              ← /admin/docs/*
    │   │       └── config.py            ← /admin/config/*
    │   ├── services/
    │   │   ├── __init__.py
    │   │   ├── auth_service.py
    │   │   ├── billing_service.py       ← 收据校验分平台（核心）
    │   │   ├── pairing_service.py
    │   │   ├── cloud_service.py         ← 扩展名白名单 + 加密 blob 存储
    │   │   ├── cms_service.py           ← 文档 CRUD + 版本号管理 + 发布
    │   │   └── consent_service.py       ← 同意记录落库 + 版本比对
    │   ├── security.py                  ← JWT 编解码 / bcrypt 密码哈希 / admin token
    │   └── admin_ui/                    ← 可选：Jinja2 简易管理页面
    │       ├── base.html
    │       ├── docs_list.html
    │       ├── doc_edit.html
    │       └── config.html
    ├── tests/
    │   ├── conftest.py
    │   ├── test_auth.py
    │   ├── test_billing.py
    │   ├── test_pairing.py
    │   ├── test_cloud.py
    │   ├── test_cms.py
    │   └── test_consent.py
    ├── alembic/
    ├── alembic.ini
    ├── requirements.txt
    ├── Dockerfile
    ├── docker-compose.yml
    ├── .env.example
    ├── seed_data.sql                    ← 初始化 CmsDocument 隐私政策/用户协议默认内容 + AppConfig 默认值
    └── README.md
```

---

## 九、一期交付范围（MVP，4 期）

| 期 | 交付 | 预估 |
|---|---|---|
| **Phase 1** | 账号注册 / 登录 / JWT + PC 配对注册 + entitlement 查询 + 7 天试用触发 | ~1–2 天 |
| **Phase 2** | **CMS 内容管理（高优先）**：`cms_documents` + `app_configs` + `/api/cms/docs` + `/api/cms/config` + Admin API + seed 数据（隐私政策/用户协议默认内容） + 客户端 `LegalConstants` 对接 | ~1 天 |
| **Phase 3** | **同意记录落库（高优先）**：`consent_records` + `/api/consent/*` + 客户端 `ConsentGate` 版本号升级 + 合规审计查询 | ~0.5 天 |
| **Phase 4** | `/api/billing/verify` 收据校验骨架（Google + 华为两个 stub，无凭证先 mock）+ 云存档加密上传下载（会员专属） | ~1.5 天 |
| **Phase 5** | 接入真实 Google Play Developer API + 华为 IAP API（需要你先拿到两边凭证） | 凭证到位后 ~0.5 天 |
| **Phase 6（可选）** | Admin 简易 Web UI（Jinja2 页面） | ~0.5 天 |

> **注意**：Phase 2 和 Phase 3 被提前到 CMS/隐私合规场景的优先位——因为 `LegalConstants` 每次改都要发版、`ConsentGate` 无版本号有合规风险，这两个是当前最痛的点。

---

## 十、需要决策的关键点

| # | 问题 | 候选 | 推荐 |
|---|---|---|---|
| 1 | 技术栈 | A FastAPI/PG / B NestJS/PG / C Go | **A** |
| 2 | JWT 方案 | A 无状态 / B 服务端会话 | **A** |
| 3 | 部署方式 | A 自托管 / B Fly.io/Render / C 华为云 | **A（先自托管跑通，后续可迁）** |
| 4 | 数据库 | PostgreSQL / SQLite | **PostgreSQL**（SQLite 也能跑 MVP，但 Blob 性能和 JSON 查询会差） |
| 5 | 是否要 Redis（登出黑名单 + 限流） | 是 / 否 | **否**（一期 MVP 不需要） |
| 6 | 云存档加密放哪 | **客户端 AES-256-GCM** / 服务端加 | **客户端**（合规红线） |
| 7 | CMS 内容存储格式 | **Markdown** / HTML / 富文本 JSON | **Markdown**（简洁，`flutter_markdown` 直接渲染） |
| 8 | 多语言 | 先 zh 单语 / **zh + en** 双语 | **双语**（Google Play 和华为 AppGallery 上架都要求英文版本） |
| 9 | Admin 管理方式 | **API-only + curl 脚本** / Jinja2 Web UI / 独立前端 | **先 API-only，后续按需加 Web UI**（MVP 节省时间） |
| 10 | 一期先做哪些 | Phase 1 或 Phase 1+2+3 | **Phase 1+2+3**（账号 + CMS + 同意记录 —— 这三个是当前最痛的，且 CMS 与合规必须先搞定才能上架） |

---

## 十一、与现有 `peer_host.py` 的关系

`tools/library/peer_host.py` 是**用户自托管的 PC 服务端**，负责局域网 ROM 索引 / 存档同步 / mDNS 广播。本 `account_backend` 是**你运营的中心账号后端**，只负责：

- 账号 / 权益 / 会员状态；
- PC 配对 token 签发（`peer_host.py` 在 `/pair` 端点会校验这个 token）；
- 云存档中转（加密 + 不解密）；
- CMS 内容下发 + 同意记录（**合规模块**）。

两者通过 PC 端在首次配对时交换一次性 code 完成绑定：

```
PC (peer_host)  ──一次性 code──►  App
                                 │
                                 ▼
                          App POST /api/pairing/register
                          (code + PC 别名)
                                 │
                                 ▼
                          Account Backend
                          生成 per-user access_token
                                 │
                                 ▼
                          App 把 token 写回 PC
                          PC 后续 /peer/* 请求自动带 token
```

---

## 决策记录

| 日期 | 决策人 | 结论 | 变更说明 |
|---|---|---|---|
| 2026-11-02 | 待决策 | v0.1 初稿输出 | 基础账号/配对/会员/云存档方案 |
| 2026-11-02 | 待决策 | v0.2 补充 CMS + 同意管理 | 新增 `cms_documents`/`app_configs`/`consent_records` 三表、CMS 公开端点、Admin 管理端点、客户端改造方案、Phase 2/3 提前 |

---

## 实施进度（截至 2026-11-02）

### ✅ Phase 0：基础设施（100%）

- [x] 目录结构：`tools/account_backend/` 全套 app/models/schemas/routers/services
- [x] `requirements.txt` — FastAPI 0.115 / SQLAlchemy 2.0 / psycopg / alembic / pydantic 2 / python-jose / passlib+bcrypt 4.0.1 / email-validator / httpx
- [x] `.env.example` — 完整占位（DB / JWT / Admin / Google Play / 华为 IAP / 合规 salt）
- [x] `.gitignore` — Python cache / .env / secrets
- [x] `Dockerfile` + `docker-compose.yml`（含 postgres:16 服务）
- [x] `alembic.ini` + `alembic/env.py` — 就绪，等生产 DB 跑 `alembic revision --autogenerate`

### ✅ Phase 1：账号 + JWT + 配对 + entitlement（100%）

- [x] ORM：`User`（UUID PK）、`Entitlement`（带 is_ad_free / is_vip_active / cloud_save_enabled 属性，严格对齐 Dart 判定逻辑）、`PcPairing`
- [x] 路由：`POST /api/auth/register`、`POST /api/auth/login`、`POST /api/auth/refresh`、`GET /api/auth/me`、`POST /api/auth/logout`
- [x] 路由：`POST /api/pairing/register`、`GET /api/pairing/list`、`DELETE /api/pairing/{id}`
- [x] 路由：`GET /api/billing/entitlement`、`POST /api/billing/trial/start`
- [x] 服务：`auth_service`（bcrypt 哈希 + JWT access+refresh 双签发）、`pairing_service`（per-user PC access_token，DB 只存 bcrypt hash）
- [x] JWT：access_token 默认 15min / refresh_token 30d；独立 admin_secret 签发 admin token
- [x] 冒烟测试：注册 → 登录 → me → trial_start → entitlement 查询全过

### ✅ Phase 2：CMS 内容管理 + seed（100%）

- [x] ORM：`CmsDocument`（多版本多语言，draft/published/archived 三态）、`AppConfig`（替代全部 LegalConstants）
- [x] 公开路由（无 auth）：`GET /api/cms/docs/{doc_key}?lang=zh`、`GET /api/cms/doc-meta/{doc_key}`、`GET /api/cms/config`
- [x] Admin 路由：`POST /admin/docs`（草稿）、`PUT /admin/docs/{id}`（编辑）、`POST /admin/docs/{id}/publish`（发布，自动归档旧 published）、`GET /admin/docs`、`GET /admin/config`、`PUT /admin/config/{key}`、`POST /admin/seed`
- [x] Seed 数据：4 篇默认已发布文档（privacy_policy zh/en + eula zh/en，版本号 1）、8 条 AppConfig 默认值（filing_number / feedback_url / feedback_email / qq_group / wechat_id / share_message / enable_consent_gate / ad_sdk_consent_required）
- [x] 冒烟测试：Admin seed → cms/config 拉 8 条 → cms/docs 拉中文隐私政策 → cms/doc-meta 查版本号 → Admin update config → 公开 config 验证已更新

### ✅ Phase 3：同意记录 consent_records（100%）

- [x] ORM：`ConsentRecord`（user_id NULLABLE，未登录用 device_id；doc_key+version+设备 hash；ip_hash 审计）
- [x] 路由：`GET /api/consent/status?device_id=xxx&X-Device-Id`（比对已发布版本 vs 已同意版本，返回 needs_reconsent）、`POST /api/consent/accept`（版本号必须匹配已发布版本）
- [x] Admin 统计：`GET /admin/consent-stats?doc_key=xxx`（总量 + 按版本号分布）
- [x] 冒烟测试：consent/status（全 needs_reconsent）→ accept(privacy_policy v1) → status 再次查询：privacy_policy 已 OK、eula 仍需同意

### ✅ Phase 4：billing verify stub + 云存档加密上传（100%）

- [x] ORM：`BillingTransaction`（status=pending/verified/rejected/expired）、`CloudSaveBlob`（encrypted_blob 二进制）
- [x] 路由：`POST /api/billing/verify`（dev mock 模式需 `X-Dev-Mock: 1` 头；真实 Phase 5 接 Google/华为 API）
- [x] 路由：云存档 `POST /api/cloud/saves/upload` / `GET /list` / `GET /{id}` / `DELETE /{id}`
- [x] 合规防护：云存档扩展名白名单（.sav/.state/.dat/.json 等）+ ROM/BIOS 关键词拒绝 + 会员门控（`require_cloud_save_entitlement` Depends）+ 10MB 大小限制
- [x] SKU 映射：6 个 SKU 全部硬编码在 `billing_service.SKU_MAP`，与 Dart 端 BillingService 严格对齐
- [x] 冒烟测试：verify premium_yearly(mock) → entitlement tier=premium_yearly is_ad_free=True cloudSave=True → 云存档上传 OK → 免费用户上传 403 → .zip 扩展名上传 400 → 下载验证字节一致

### 🔜 Phase 5：真实收据校验（未开始，需凭证）

- Google Play Developer Service Account JSON
- 华为 IAP ClientID + ClientSecret + 应用ID
- 需要 `POST /api/billing/verify` 内部实现两条分平台调用链

### 🔜 Phase 6（可选）：Admin 简易 Web UI（未开始）

---

## 端到端冒烟测试结果（2026-11-02，sqlite 临时库）

**全部 25 用例通过 ✅**：

| # | 端点 | 结果 |
|---|---|---|
| 1 | `GET /healthz` | 200 ✓ |
| 2 | `POST /api/auth/register` | 201 ✓ |
| 3 | `GET /api/auth/me` | 200 ✓ |
| 4 | `POST /api/billing/trial/start` | 200 ✓ |
| 5 | `GET /api/billing/entitlement` (trial) | 200 is_ad_free=True ✓ |
| 6 | `GET /api/cms/config` (seed 前) | 200 keys_count=0 ✓ |
| 7 | `POST /admin/seed` | 200 8 config + 4 docs ✓ |
| 8 | `GET /api/cms/config` (seed 后) | 200 keys_count=8 ✓ |
| 9 | `GET /api/cms/docs/privacy_policy?lang=zh` | 200 ✓ |
| 10 | `GET /api/cms/doc-meta/eula?lang=en` | 200 version=1 ✓ |
| 11 | `POST /api/billing/verify` (dev mock premium_yearly) | 200 ok=True ✓ |
| 12 | `GET /api/billing/entitlement` (after verify) | 200 premium_yearly cloudSave=True ✓ |
| 13 | `GET /api/consent/status` (before accept) | 200 all needs_reconsent=True ✓ |
| 14 | `POST /api/consent/accept` (privacy_policy v1) | 200 ✓ |
| 15 | `GET /api/consent/status` (after accept) | 200 privacy OK eula still needs ✓ |
| 16 | `POST /api/cloud/saves/upload` | 200 ✓ |
| 17 | `GET /api/cloud/saves/list` | 200 count=1 ✓ |
| 18 | `GET /api/cloud/saves/{id}` | 200 bytes match ✓ |
| 19 | `POST /api/cloud/saves/upload` (free user) | 403 ✓ |
| 20 | `POST /api/cloud/saves/upload` (.zip) | 400 ✓ |
| 21 | `GET /admin/consent-stats` | 200 total=1 ✓ |
| 22 | `GET /admin/docs` | 200 count=4 ✓ |
| 23 | `PUT /admin/config/feedback_email` + 公开验证 | ✓ |
| 24 | `POST /api/pairing/register` | 200 pc_token_len=64 ✓ |
| 25 | `GET /api/pairing/list` | 200 count=1 ✓ |

**路由总数**：34（含 Swagger /docs、ReDoc /redoc、/openapi.json、根 /、健康检查 /healthz）。

**修复的坑**：
1. `bcrypt 4.1+` 与 `passlib 1.7.4` 兼容性问题 → 固定 `bcrypt==4.0.1`
2. pydantic `EmailStr` 缺 `email-validator` → 补 `email-validator==2.2.0`
3. SQLite 不保留 DateTime timezone info → `_ensure_utc()` helper 把 naive datetime 补回 UTC 再比较
4. 模型文件 `from .database import Base` 路径错（models 子包）→ 改为 `from ..database import Base`

---

## 客户端对接 TODO（后续实施）

以下改动需要在客户端 Dart 侧跟进：

- [ ] `LegalConstants` → 退化为本地默认值；新增 `AppConfigService.fetchCmsConfig()` 启动时拉 `/api/cms/config`
- [ ] `ConsentGate` → 新增版本号比对：启动时拉 `/api/consent/status`，版本号不一致或从未同意才弹门禁；点同意时 `POST /api/consent/accept`
- [ ] `PrivacyPolicyPage` / `EulaPage` → 从 `/api/cms/docs/{doc_key}` 拉 Markdown 用 `flutter_markdown` 渲染；失败回退本地 Asset
- [ ] `AccountService` → 接 `/api/auth/register` / `/api/auth/login` / `/api/auth/me`
- [ ] `ReceiptVerifier` → 真实实现 `POST /api/billing/verify`（替换 NoOpReceiptVerifier）
- [ ] `PairingService` → 接 `/api/pairing/register`（PC 端调用）、`/api/pairing/list`（App 端拉）

---

## 生产部署 TODO

- [ ] 生成 Alembic 初始迁移：`alembic revision --autogenerate -m "initial"`（需本地 PostgreSQL）
- [ ] `alembic upgrade head`
- [ ] 生产环境 `.env` 注入：JWT_SECRET / ADMIN_TOKEN_SECRET / DB_PASSWORD
- [ ] Docker Compose 启动 + `POST /admin/seed`（首次部署）
- [ ] 反向代理 Nginx 配置（HTTPS + CORS 限制）
- [ ] Phase 5：Google Play Service Account + 华为 IAP 凭证接入 `/api/billing/verify` 真实调用

---

## 本地启动指南

### 位置

```
tools/account_backend/
├── .env                  ← 已生成 dev 配置（SQLite + dev JWT secret）
├── dev.db                ← SQLite 数据库文件（首次启动自动创建）
├── requirements.txt
└── app/
```

### 方式 A：Dev 模式（推荐，零依赖，SQLite）

**首次启动**（3 步）：

```powershell
# 1. 进入目录
cd tools\account_backend

# 2. 装依赖（只第一次）
pip install -r requirements.txt

# 3. 启动（自动建表 + 热重载）
python -c "from app import Base, engine; import app.models; Base.metadata.create_all(engine)"
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

**后续启动**（1 步）：

```powershell
cd tools\account_backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

**首次 Seed 初始化**（8 条 AppConfig + 4 篇 CMS 文档）：

```powershell
# 1. 生成 admin token（PowerShell）
$tok = python -c "from app.security import create_admin_token; print(create_admin_token('root'))"

# 2. 调用 seed 端点
Invoke-RestMethod -Method Post -Uri http://localhost:8000/admin/seed -Headers @{Authorization="Bearer $tok"}
# 返回: { "app_configs_seeded": 8, "cms_docs_seeded": 4 }
```

### 方式 B：Docker Compose（PostgreSQL）

```powershell
cd tools\account_backend
copy .env.example .env     # 改 DB_PASSWORD / JWT_SECRET 等
docker compose up -d
```

首次需要 Alembic 迁移：

```powershell
docker compose exec app alembic revision --autogenerate -m "initial"
docker compose exec app alembic upgrade head
# 然后同上 seed
```

### 访问入口

| 入口 | URL |
|---|---|
| Swagger API 文档（最方便调试） | http://localhost:8000/docs |
| ReDoc 文档 | http://localhost:8000/redoc |
| 健康检查 | http://localhost:8000/healthz |
| CMS 配置（公开，替代 LegalConstants） | http://localhost:8000/api/cms/config |
| 隐私政策（公开） | http://localhost:8000/api/cms/docs/privacy_policy?lang=zh |
| 用户协议（公开） | http://localhost:8000/api/cms/docs/eula?lang=en |
| Consent 状态 | http://localhost:8000/api/consent/status |

### 常用命令速查

| 目的 | 命令 |
|---|---|
| 启动（dev + reload） | `python -m uvicorn app.main:app --reload` |
| 安装依赖 | `pip install -r requirements.txt` |
| 语法检查 | `python -m compileall app` |
| 自动建表 | `python -c "from app import Base, engine; import app.models; Base.metadata.create_all(engine)"` |
| Alembic 生成迁移 | `alembic revision --autogenerate -m "描述"` |
| Alembic 应用迁移 | `alembic upgrade head` |
| 看路由清单 | `python -c "from app.main import app; [print(m, r.path) for r in app.routes if hasattr(r,'methods') for m in r.methods - {'HEAD'}]"` |
| 生成 admin token | `python -c "from app.security import create_admin_token; print(create_admin_token('root'))"` |
| 停止服务 | 任务管理器杀 python 进程 / Stop Command |

### 常见坑

| 问题 | 原因 | 解决 |
|---|---|---|
| `ModuleNotFoundError: No module named 'email_validator'` | pydantic EmailStr 缺依赖 | `pip install email-validator==2.2.0` |
| `password cannot be longer than 72 bytes` | bcrypt 4.1+ 与 passlib 1.7.4 不兼容 | `pip install bcrypt==4.0.1`（已写进 requirements.txt） |
| SQLite 启动报 timezone 错 | SQLite 不保留 DateTime tzinfo | 已在 `entitlement.py` 加 `_ensure_utc()` helper，无需额外处理 |
| 端口 8000 被占用 | 上次进程没退出 | `netstat -ano \| findstr :8000` 找 PID → `taskkill /PID xxx /F` |
| admin 端点返回 401/403 | token 过期或用错 secret | 重新生成 admin token，确保用的是 `.env` 里的 `ADMIN_TOKEN_SECRET` |

---

## 客户端联调指南（安卓 App ↔ 本地后端）

### 当前环境状态（2026-11-02）

| 项 | 值 |
|---|---|
| 后端 dev 服务 | `localhost:8000`，SQLite，已 seed |
| PC 局域网 IP | `192.168.1.14`（WLAN）/ `192.168.2.123`（以太网） |
| App 构建脚本 | `scripts\build-apk.ps1 -Flavor store` 可用 |
| 现有云配置入口 | `CloudConfig.baseUrl`（已支持 HTTP/HTTPS + normalize） |
| 现有加密存储 | `flutter_secure_storage` 存 token |

---

### 第一步：网络打通（3 选 1）

安卓手机**不能用 127.0.0.1** 访问 PC 端口。Android 9+ 默认禁止明文 HTTP，需按以下方式处理。

#### 方式 A：同 Wi-Fi（手机 + PC 在同一网段）

App 访问地址：`http://<PC局域网IP>:8000`

**必须同时改** `app/android/app/src/main/res/xml/network_security_config.xml` —— 允许明文 HTTP 到局域网段：

```xml
<domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">127.0.0.1</domain>
    <domain includeSubdomains="false">localhost</domain>
    <domain includeSubdomains="true">192.168.0.0/16</domain>   ← 新增
</domain-config>
```

改完后重新 build APK。

#### 方式 B：ADB Reverse 隧道（推荐，无需改 manifest）

手机用 USB 连 PC，建立 TCP 端口隧道：

```powershell
# 确保 adb 在 PATH 或用完整路径
& "D:\ai\prj\trae\HuaWei\RetroEmuPouch\.tools\android-sdk\platform-tools\adb.exe" devices
# 输出应显示 OXF-AN10 device

# 建立隧道：手机 127.0.0.1:8000 → PC localhost:8000
& "D:\ai\prj\trae\HuaWei\RetroEmuPouch\.tools\android-sdk\platform-tools\adb.exe" reverse tcp:8000 tcp:8000
```

隧道建完后 App 里访问 **`http://127.0.0.1:8000`** 就能直达 PC 后端（loopback 已在 manifest 白名单）。

**隧道验证**：手机浏览器打开 http://127.0.0.1:8000/docs → 能看到 Swagger 即成功。

#### 方式 C：Dev 专用 APK（Flavor 覆盖）

在 `android/app/src/debug/AndroidManifest.xml` 中覆盖 base-config，允许全部明文：

```xml
<application ... android:usesCleartextTraffic="true" />
```

然后跑 debug 构建：`flutter run --flavor store -t lib/main.dart`（如果 store flavor 有 debug 配置）。

---

### 第二步：客户端改造清单（按优先级分 3 批）

#### 批次 1（最小可测）：CMS 配置 + ConsentGate 版本号升级

**改动文件**：

| 文件 | 改什么 |
|---|---|
| `features/legal/legal_constants.dart` | 全部静态项退化为本地默认值；启动时调 `GET /api/cms/config` 拉取最新值 |
| `features/legal/consent_gate.dart` | 加版本号比对：启动时调 `GET /api/consent/status`；版本号不一致或从未同意才弹门禁；点"同意"时 `POST /api/consent/accept` |
| `features/legal/privacy_policy_page.dart` / `eula_page.dart` | 从 `/api/cms/docs/{doc_key}?lang=zh` 拉 Markdown 渲染，失败回退本地 Asset |

**联调验证点**：

| 场景 | 后端 API | 后端预期返回 |
|---|---|---|
| App 启动 → CMS 配置 | `GET /api/cms/config` | 8 条 AppConfig（含 filing_number / feedback_url / feedback_email ...） |
| 首次启动 → ConsentGate | `GET /api/consent/status` | privacy_policy v1 + eula v1，`needs_reconsent=true` |
| 用户同意隐私政策 | `POST /api/consent/accept {doc_key: privacy_policy, version: 1, device_id: xxx}` | 返回 `recorded_at + version: 1` |
| 用户同意用户协议 | `POST /api/consent/accept {doc_key: eula, version: 1, device_id: xxx}` | 同上 |
| **合规场景 - Admin 升级隐私政策到 v2** | Admin `POST /admin/docs/{id}/publish` | 文档变 v2，App 下次启动时 `needs_reconsent=true` → 自动重弹 ConsentGate |

#### 批次 2：账号注册/登录 + entitlement 查询 + 7 天试用

**改动文件**：

| 文件 | 改什么 |
|---|---|
| `features/account/account_service.dart` | 接 `POST /api/auth/register` / `POST /api/auth/login` / `GET /api/auth/me`；返回的 access_token 存入 `CloudConfig.token`（已存在加密存储） |
| `features/membership/billing_service.dart` | 注册后自动触发 `POST /api/billing/trial/start`；App 启动时调 `GET /api/billing/entitlement` 拉权益 |
| `data/cloud/cloud_client.dart` | 新增 AccountApiClient / BillingApiClient（或统一 Auth 头拦截器） |

**联调验证点**：

| 场景 | 后端 API | 后端预期返回 |
|---|---|---|
| 新用户注册 | `POST /api/auth/register {email, password, display_name}` | 返回 `access_token + refresh_token` |
| 注册后自动试用 | `POST /api/billing/trial/start` | `trial_start=<now>, already_started=false` |
| entitlement 查询 | `GET /api/billing/entitlement` | `tier=free, trial_start=<now>, is_ad_free=true, blocks_interstitial_ads=true` |
| 试用窗口内广告抑制 | — | 插屏广告不展示（`blocks_interstitial_ads=True`） |

#### 批次 3：收据校验 + 云存档 + PC 配对

**改动文件**：

| 文件 | 改什么 |
|---|---|
| `features/membership/receipt_verifier.dart` | `NoOpReceiptVerifier` → `HttpReceiptVerifier`；dev mock 必须带 `X-Dev-Mock: 1` 头 |
| `features/membership/billing_service.dart` | 购买成功后调 `verifyPurchase` → 服务端授予 entitlement → 重新拉取 `GET /api/billing/entitlement` |
| 云存档 client（新增） | 客户端生成 AES-256-GCM key → 加密 `.sav` 文件 → `POST /api/cloud/saves/upload` |
| PC 配对 client（新增） | PC 端带一次性 code 调 `POST /api/pairing/register` → 服务端返回 per-user PC access_token |

**联调验证点**：

| 场景 | 后端 API | 后端预期返回 |
|---|---|---|
| Dev mock 收据校验 | `POST /api/billing/verify + X-Dev-Mock: 1` | `premium_yearly → is_ad_free=True, cloudSaveEnabled=True` |
| 会员云存档上传 | `POST /api/cloud/saves/upload (会员)` | 200 OK |
| 免费用户云存档上传 | 同上 | **403 Forbidden**（合规：会员专属） |
| ROM 扩展名上传 | 上传 `kof97.zip` | **400 Bad Request**（合规：ROM 禁止） |
| PC 配对 | `POST /api/pairing/register` + `GET /api/pairing/list` | 返回 per-user PC access_token（64 字符） |

---

### 端到端测试场景汇总

| # | 场景 | 涉及 API | 优先级 |
|---|---|---|---|
| 1 | CMS 配置拉取 | `GET /api/cms/config` | P0 |
| 2 | ConsentGate 版本号比对 | `GET /api/consent/status` | P0 |
| 3 | 用户同意隐私政策 | `POST /api/consent/accept` | P0 |
| 4 | 用户同意用户协议 | `POST /api/consent/accept` | P0 |
| 5 | 注册 + 试用 | `POST /api/auth/register` + `POST /api/billing/trial/start` | P1 |
| 6 | entitlement 缓存刷新 | `GET /api/billing/entitlement` | P1 |
| 7 | Dev mock 收据校验 | `POST /api/billing/verify` + `X-Dev-Mock: 1` | P1 |
| 8 | 云存档上传（会员） | `POST /api/cloud/saves/upload` | P2 |
| 9 | 云存档上传（免费）→ 403 | 同上 | P2（合规） |
| 10 | 云存档扩展名白名单 → 400 | 上传 `kof97.zip` | P2（合规） |
| 11 | PC 配对 | `POST /api/pairing/register` + `GET /api/pairing/list` | P2 |
| 12 | **合规场景 - 政策更新重弹** | Admin 升级 privacy_policy 到 v2 → App 下次启动自动重弹 ConsentGate | P0（合规） |

---

### 快速检查清单

- [ ] 方式 A：改 `network_security_config.xml` 加 LAN 白名单 → rebuild APK
- [ ] 方式 B：`adb reverse tcp:8000 tcp:8000` → 手机浏览器访问 `http://127.0.0.1:8000/docs` 验证
- [ ] Admin token 可用（`python -c "from app.security import create_admin_token; print(create_admin_token('root'))"`）
- [ ] Seed 已跑（`POST /admin/seed`）→ 8 条 AppConfig + 4 篇 CMS 文档
- [ ] Batch 1 客户端改造：`LegalConstants` 动态化 + `ConsentGate` 版本号升级
- [ ] Batch 2 客户端改造：`AccountService` 接 `/api/auth/*` + `BillingService` 接 `/api/billing/*`
- [ ] Batch 3 客户端改造：`ReceiptVerifier` 真实实现 + 云存档 client + PC 配对 client

---

### 合规红线（联调时必须验证）

1. ✅ **政策版本号升级后老用户必须重新同意** — Admin 把 privacy_policy 从 v1 升到 v2 → App 下次启动 `needs_reconsent=true` → 自动弹 ConsentGate
2. ✅ **云存档会员专属门控** — 免费用户上传 → 403
3. ✅ **ROM/BIOS 扩展名白名单** — `.zip` / `.bin` 上传 → 400
4. ✅ **ConsentRecord 落库** — 每次同意都写一条（带 device_id hash + ip_hash），可审计追溯
5. ✅ **云存档客户端加密** — App 端 AES-256-GCM 加密后上传，后端只存加密 blob，密钥 hash 存 `client_key_hash` 字段，**后端不解密**

---

## 账号后端客户端接缝（2026-11-02 实施）

为让 **store 包也能直接联调真实后台**（无需切 community 渠道），App 端落地了账号抽象接缝：

- `app/lib/features/account/account_backend.dart`：`AccountUser` + `abstract interface class AccountBackend` + 运行期/编译期选择常量（`kUseHttpBackend` / `kAccountBaseUrl` / `buildUseHttpBackend()`）。
- `app/lib/features/account/mock_account.dart`：`MockAccountService implements AccountBackend`（本地桩，**默认**实现）。
- `app/lib/features/account/http_account.dart`：`HttpAccountService implements AccountBackend`，真实调用 `/api/auth/*`；`createAccountBackend()` 按"运行期开关 > 编译期 `--dart-define=BACKEND=http`"选择实现（未配置地址时自动回退桩，避免启动崩溃）。
- `account_page.dart`：UI 仅依赖 `AccountBackend` 接口；debug 构建（`kDebugMode`）暴露「调试：账号后端」入口，可填后端地址并切换桩/真实后端。登录弹窗新增「注册」标签（真实后端自动隐藏「一键快捷」），调用 `POST /api/auth/register`；`AccountBackend` 接口随之新增 `register()`。

### store 包本地联调步骤

1. 后台起 HTTPS：在 `tools/account_backend` 执行 `.\start-https.ps1`（mkcert 生成受信证书 + uvicorn 挂 TLS，`https://127.0.0.1:8000`）。
   - 为何要 HTTPS：store 构建禁止明文 HTTP，但 **HTTPS 任何主机都放行**（`SecurityPolicy.assertSafe` 仅拦 `http://`）。所以 store 包用 HTTPS 即可联调，且路径与生产一致。
2. 设备信任 mkcert 根 CA：PC 执行 `mkcert -CAROOT` 找到 `rootCA.pem` → 手机「设置 → 安全 → 安装证书 → CA 证书」装入（store 的 `network_security_config.xml` 未限制只信系统 CA，用户 CA 会被信任）。
3. `adb reverse tcp:8000 tcp:8000`（USB 转发），App「网络」页调试入口填 `https://127.0.0.1:8000` 并开启「使用真实后端」。
4. 后台首次需 `POST /admin/seed` 初始化 CMS/配置数据。

### 后端端点增补（2026-11-02）

为消掉"已知缺口①"，后台已补齐两个 auth 端点，App 端 `HttpAccountService` 已真实调用（不再抛"未提供接口"）：

- `POST /api/auth/change-password`：body `{ old_password, new_password(min 6) }`，需 Bearer；校验旧密码后 `auth_service.change_password()` 重写 `password_hash`；旧密码错误返回 `400 wrong_old_password`。
- `DELETE /api/auth/me`：需 Bearer；`auth_service.delete_user()` 级联删除 entitlement / pairings / 云存档 / 同意记录（User.relationship 已配 cascade）。

### 联调闭环验证

- **后台冒烟**（PowerShell `Invoke-RestMethod`）：`register → me → change-password → 用新密码 login → delete` 全部成功，闭环通过。
- **store-debug APK**：用 `gradlew assembleStoreDebug` 构建产出 `app/build/app/outputs/flutter-apk/app-store-debug.apk`（约 278MB），并已 `adb install -r` 到 OXF 真机（`66B0219C18003002`）。
  - 注：`flutter build apk --debug` 因多 flavor 输出命名找不到 APK，改用 gradlew 直接构建即可。
- **真机联调只需三步**：① 设备装入 mkcert 根 CA（`mkcert -CAROOT` → 设置→安全→安装证书→CA 证书）；② `adb reverse tcp:8000 tcp:8000`；③ App「网络」页调试入口填 `https://127.0.0.1:8000` 并开「使用真实后端」。

### 已知缺口（待后台/客户端补齐）

- ~~真实后端 `auth` 路由暂无「修改密码 / 注销账号」端点~~ —— **已补齐**（见上）。
- JWT 当前仅存 access_token（单 token），未实现 refresh 自动续期（Phase 5 上线前需补，详见评估文档）。
- `X-Dev-Mock` 头与 store/community 无关，属 dev/staging 标志，联调真实后台本就不发。
