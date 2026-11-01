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
