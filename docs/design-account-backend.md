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

## 〇、文档关系与冲突裁决

本主题由三份文档组成，存在演进先后，可能出现状态/表述冲突：

| 文档 | 角色 |
|---|---|
| `docs/design-account-backend.md`（本文） | **权威源（authoritative）**：账号云后端 API / 数据模型 / CMS / 同意管理 / 部署的总契约。**三份文档冲突时以本文为准**（用户 2026-11-04 裁定）。 |
| `docs/design-account-cloud-ads-membership.md` | 客户端架构 + 广告 + 会员体系方案（含跟踪表）。冲突时以本文裁定。 |
| `docs/design-auth-membership-entitlement.md` | 账号会话 × 会员权益 × 去广告的权威契约（修订 doc2 的背离项）。冲突时以本文裁定。 |

**冲突裁决规则**：
1. 任意冲突点 → 以 `design-account-backend.md` 为准。
2. 文档与代码事实冲突 → **以代码为最终裁定**：文档状态表可能滞后于实现，以实际可运行代码 + 联调结果为真相源（本文「实施进度 / 客户端对接完成状态」一节记录的是 2026-11-04 的真实落地状态，是同步另两份文档的依据）。

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
│                                    │     privacy_policy_url / terms_url /
│                                    │     enable_consent_gate / ad_sdk_consent_required
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
| GET  | `/api/cms/config` | 一次性返回 `app_configs` 全部 key-value（当前 seed 默认 **10 条**）—— 客户端启动时拉一次缓存到本地，并在「关于与支持」页每次打开时重新拉取；替代全部 `LegalConstants` 静态项。属**公开内容**，固定走公网 `kDefaultBackendUrl`，不受用户可配置的账号后端地址影响 |
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

> **现行本地默认值（2026-11-04）**：`privacyPolicyUrl = 'https://api.gamepouch.cn/privacy'`、`feedbackEmail = 'support@retroemupouch.cn'`（原 GitHub Pages URL 与 `example.com` 占位邮箱已废弃）；`filingNumber` 仍为空表示"备案中"。这些值只在云端拉取失败时兜底，正常路径以 `/api/cms/config` 下发为准。

### 4.2 `ConsentGate` 升级：**版本号感知**

```
启动 → GET /api/consent/status → 拿到当前已发布版本号
  ├─ 本地 consent_given_version >= 已发布版本 → 跳过，直接进 App
  └─ 本地 consent_given_version < 已发布版本（或从未同意） → 弹 ConsentGate
        └─ 点"同意并继续" → POST /api/consent/accept → 本地存版本号
```

**为什么需要版本号**：两个商店都要求"政策更新后用户必须重新同意"。没有版本号 = 合规隐患。

> **2026-11-04 导航修复**：`ConsentGate` 是 `runApp` 的根组件，其 `build` 所用的 `context` **上方没有 Navigator**（内嵌的 `MaterialApp` 在它下方），原先两个「查看隐私政策 / 查看用户协议」按钮用 `Navigator.of(context).push(...)` 会抛 `does not include a Navigator`，表现为点击无响应。现给内嵌 `MaterialApp` 挂 `navigatorKey: _navKey`，按钮改用 `_navKey.currentState!.push(...)`；「同意并继续」不涉及 Navigator，一直正常。

### 4.3 `PrivacyPolicyPage` / `EulaPage` 内容来源

```
改造前：本地硬编码文本 / GitHub Pages URL 打开
现行实现：CloudConfigService.fetchDoc(docKey) → GET https://api.gamepouch.cn/api/cms/docs/{doc_key}?lang=zh
         → 服务端返回的 Markdown 正文用 SelectableText 展示（无额外渲染依赖）
         → 拉取失败时回退文件内硬编码的 _fallback 模板，保证合规底线
网页版链接：CloudConfigService.instance.privacyPolicyUrl（云端 AppConfig，默认 https://api.gamepouch.cn/privacy）
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
| 7 | CMS 内容存储格式 | **Markdown** / HTML / 富文本 JSON | **Markdown**（简洁；当前 App 侧以 `SelectableText` 直接展示纯 Markdown 正文，未额外引入渲染库） |
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
| 2026-11-04 | 实施者 | 公开内容与账号后端地址解耦 | `CloudConfigService` 的 `load()`/`fetchDoc()` 不再经 `effectiveBaseUrl`，硬走公网 `kDefaultBackendUrl`；隐私政策/协议/备案号/客服信息等属于任何用户均可访问的公开内容，不受调试入口私有地址影响。同时修正 `ConsentGate` 导航、账号页首帧红屏、关于页动态化、seed 默认项 8→10 条 |
| 2026-11-04 | 实施者 | 补齐完整运营后台（Phase 7） | 原后台仅 CMS/AppConfig，注册用户与权益不可运维。新增 `users.is_active` + `admin_audit_logs`、迁移 0002 + 运行时 schema 自愈、`admin_service` 分页/统计/CRUD、`billing_service` 公共权益写入、Admin JSON API 与 11 个 Web UI 页面。决策：人工调整权益不写账单流水（避免污染对账）、云存档只展示元数据不解密、删除用户级联且不可恢复、所有写操作强制审计 |

---

## 实施进度（截至 2026-11-04）

### ✅ Phase 0：基础设施（100%）

- [x] 目录结构：`tools/account_backend/` 全套 app/models/schemas/routers/services
- [x] `requirements.txt` — FastAPI 0.115 / SQLAlchemy 2.0 / psycopg / alembic / pydantic 2 / python-jose / passlib+bcrypt 4.0.1 / email-validator / httpx
- [x] `.env.example` — 完整占位（DB / JWT / Admin / Google Play / 华为 IAP / 合规 salt）
- [x] `.gitignore` — Python cache / .env / secrets
- [x] `Dockerfile` + `docker-compose.yml`（含 postgres:16 服务）
- [x] `alembic.ini` + `alembic/env.py` — 就绪；已手写初始迁移 `alembic/versions/0001_initial.py`（7 张表全建；已在临时 SQLite 上 `alembic upgrade head` 验证通过，类型对 Postgres 可移植）

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
- [x] Seed 数据：4 篇默认已发布文档（privacy_policy zh/en + eula zh/en，版本号 1）、10 条 AppConfig 默认值（filing_number / feedback_url / feedback_email / qq_group / wechat_id / share_message / **privacy_policy_url** / **terms_url** / enable_consent_gate / ad_sdk_consent_required）；`feedback_email` 默认 `support@retroemupouch.cn`，两个 URL 默认 `https://api.gamepouch.cn/privacy` 与 `/terms`（2026-11-04 新增）
- [x] 冒烟测试：Admin seed → cms/config 拉 10 条 → cms/docs 拉中文隐私政策 → cms/doc-meta 查版本号 → Admin update config → 公开 config 验证已更新

### ✅ Phase 2.5：应用商店合规网页（2026-11-04）

- [x] 隐私政策 / 用户协议（eula）内容升级为**上架合规完整版**（v2）：补齐运营主体、存储期限、第三方 SDK、注销/撤回同意流程、未成年人保护、争议解决等；`seed` 改为可**就地更新**已发布文档（版本号升高触发 App 端 ConsentGate 重新征求同意）
- [x] **公开网页渲染路由** `app/routers/legal_public.py`（`markdown==3.7`）：`GET /privacy`、`/privacy-policy` → `privacy_policy`；`GET /terms`、`/eula`、`/user-agreement` → `eula`；`GET /legal/{doc_key}` 通用；均将 CMS 已发布文档 Markdown 渲染为响应式 HTML（`templates/legal/legal_page.html`），**无需登录**，可直接作为应用商店提交的隐私政策 / 用户协议 URL
- [x] 冒烟测试：TestClient 拉 `/privacy`、`/privacy?lang=en`、`/terms`、`/eula`、`/legal/privacy_policy`、`/legal/eula?lang=en` 均返回 200 + 有效 HTML

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

### ✅ Phase 6：Admin 简易 Web UI（100%）

- [x] `app/admin_ui.py` + `app/templates/admin/*`（Jinja2 服务端渲染）：`/admin/ui/login`（口令鉴权，HttpOnly cookie）→ `/admin/ui/`（CMS 文档列表 / 新建草稿 / 发布 / AppConfig 编辑 / 同意统计）
- [x] 复用 `cms_service`，与 `/admin` JSON API 同源；`config.py` 新增 `ADMIN_WEB_PASSWORD`（生产务必通过环境变量修改）
- [x] `requirements.txt` 加 `jinja2`；`main.py` 注册 `admin_ui_router`
- [x] 冒烟测试：TestClient 端到端通过（未授权 303→登录 / 错误口令 401 / 登录设 cookie / 已授权控制台 / 草稿创建并出现在列表）

### ✅ Phase 7：完整运营后台（2026-11-04，100%）

> 起因：Phase 6 的后台只有 CMS 文档 + AppConfig + 同意统计，**注册用户信息与权益管理完全空白**，后期运维无法开展。本阶段补齐用户、权益与全部资源的管理能力，并提供同等能力的 JSON API 与操作审计。

- [x] **数据层**：`users.is_active`（禁用账号，不删数据；`get_current_user` 校验，已签发 JWT 立即失效）；新增 `admin_audit_logs` 表（actor / action / target_type / target_id / detail JSON / created_at）。
- [x] **迁移**：`alembic/versions/0002_admin_management.py`（幂等；`with op.batch_alter_table` 兼容 SQLite）；另加 `app/services/schema_bootstrap.py` 在 `main.py` lifespan 里幂等补列/补表，老库忘记跑迁移也能直接升级。
- [x] **服务层**：`app/services/admin_service.py` 统一分页（`{items, pager}`）、仪表盘统计、用户 CRUD、各类资源列表与删除；`billing_service` 新增 public `set_entitlement()` / `set_trial()` / `entitlement_state()`（购买链路 `_grant_entitlement` 保持原样）。
- [x] **Admin JSON API**（`app/routers/admin.py`）：stats / users（列表·详情·PATCH·重置密码·DELETE）/ entitlements / cloud-saves / pairings / consents / billing-transactions / audit-logs / `PUT /admin/users/{id}/entitlement` / `POST .../trial`，全部 `Depends(require_admin)`，写操作自动写审计。
- [x] **Admin Web UI**（`app/admin_ui.py` + `app/routers/admin_ui/{users,operations,content}.py` + 12 个模板）：统一顶部导航与分页；运营概览、用户列表/详情、权益总览、云存档、配对设备、同意记录、账单流水、审计日志、CMS 文档、AppConfig 共 11 个页面。
- [x] **鉴权收敛**：`app/admin_guard.py` 提供 `ui_admin` 依赖，未登录抛 `NeedLogin`，由 `main.py` 的 exception_handler 统一 303 跳登录页；表单动作经 `perform()` 统一处理业务异常提示与审计落库。
- [x] **自测**：`tests/test_admin_management.py` 44 项端到端通过（临时 SQLite，覆盖鉴权、11 个页面、用户 CRUD、禁用生效、权益授予/撤销/试用、资源删除、CMS/Config 编辑、Admin API、审计留痕、级联删除）。

> 设计约定：后台人工调整权益**不写 `billing_transactions`**（保持购买流水可对账），仅记入审计日志；云存档只展示元数据，**服务端不解密**；删除用户为级联且不可恢复，UI 有二次确认。详细运维说明见 `docs/skills.md` §24.2.2。

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
| 7 | `POST /admin/seed` | 200 8 config + 4 docs ✓（当时 seed 为 8 条；2026-11-04 起默认 10 条） |
| 8 | `GET /api/cms/config` (seed 后) | 200 keys_count=8 ✓（现行重跑后 keys_count=10） |
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

## 客户端对接状态（2026-11-04 已落地，详见文末「客户端对接完成状态」）

> 本节原「客户端对接 TODO」清单中的 6 项**均已在 2026-11-03/04 落地**，与代码事实一致（以 `design-account-backend.md` 为权威源）。清单保留作历史记录，状态已翻转：

- [x] `LegalConstants` → 退化为本地默认值；`CloudConfigService` 启动时拉 `/api/cms/config`（覆盖全部静态项），且「关于与支持」页每次打开重新拉一次并 `ping()` 刷新；baseUrl 固定公网，不依赖 `AccountStore` / `effectiveBaseUrl`
- [x] `ConsentGate` → 版本号比对：`GET /api/consent/status` + `POST /api/consent/accept`（带 `X-Device-Id` header）
- [x] `PrivacyPolicyPage` / `EulaPage` → `CloudConfigService.fetchDoc()` 从公网拉 Markdown，用 `SelectableText` 展示，失败回退文件内硬编码模板（未引入 `flutter_markdown` / 本地 Asset 依赖）
- [x] `AccountService`（本地旧类）已删除；认证统一走 `AccountBackend`（`HttpAccountService` / `MockAccountService`），接 `/api/auth/*`
- [x] `ReceiptVerifier` → 已实现 `HttpReceiptVerifier`（`POST /api/billing/verify`，debug 带 `X-Dev-Mock: 1`）
- [x] 配对：`PairingPal`（mDNS）+ `peer_host.py` 已接 `/pair` 等端点

**客户端对接补齐（2026-11-04 第二波，详见文末「客户端对接完成状态」）**：
- [x] 云存档客户端 AES-256-GCM 加密：`features/cloud/cloud_crypto.dart`（PBKDF2-HMAC-SHA256 15 万次派生密钥），`CloudClient.uploadSave/downloadSave` 上传前加密、下载后解密，**服务端不解密**
- [x] App 云存档 UI：`features/cloud/cloud_save_section.dart`（嵌入账号页）：会员门控 → 设置云存档密码（按 userId 存 `flutter_secure_storage`，换设备重输同密码可恢复）→ 列表 / 上传备份 / 下载解密 / 删除
- [x] HAP 构建通过并已在真机运行（pid 20020266）

---

## 生产部署 TODO

- [x] 生成 Alembic 初始迁移：`alembic/versions/0001_initial.py`（手写 7 张表；已在 SQLite 验证 `alembic upgrade head`；生产 Postgres 直接 `alembic upgrade head`）
- [x] `alembic upgrade head`（生产部署前必须；`main.py` 已改为仅非 prod 跑 `create_all`，prod 由 Alembic 管 schema，避免与 Alembic 版本表冲突）
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

**首次 Seed 初始化**（10 条 AppConfig + 4 篇 CMS 文档）：

```powershell
# 1. 生成 admin token（PowerShell）
$tok = python -c "from app.security import create_admin_token; print(create_admin_token('root'))"

# 2. 调用 seed 端点
Invoke-RestMethod -Method Post -Uri http://localhost:8000/admin/seed -Headers @{Authorization="Bearer $tok"}
# 返回: { "app_configs_seeded": 10, "cms_docs_seeded": 4 }
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
| `features/legal/legal_constants.dart` | 全部静态项退化为本地默认值；启动时调 `GET /api/cms/config` 拉取最新值；现行默认 `privacyPolicyUrl=https://api.gamepouch.cn/privacy`、`feedbackEmail=support@retroemupouch.cn` |
| `features/legal/consent_gate.dart` | 加版本号比对：启动时调 `GET /api/consent/status`；版本号不一致或从未同意才弹门禁；点"同意"时 `POST /api/consent/accept`；内嵌 `MaterialApp` 挂 `navigatorKey`，两个「查看」按钮经 `_navKey.currentState!.push()` 导航 |
| `features/legal/privacy_policy_page.dart` / `eula_page.dart` | `CloudConfigService.fetchDoc()` 从公网 `/api/cms/docs/{doc_key}?lang=zh` 拉 Markdown，用 `SelectableText` 展示，失败回退文件内硬编码模板 |

**联调验证点**：

| 场景 | 后端 API | 后端预期返回 |
|---|---|---|
| App 启动 → CMS 配置 | `GET https://api.gamepouch.cn/api/cms/config` | 10 条 AppConfig（含 filing_number / feedback_url / feedback_email / privacy_policy_url / terms_url ...）；固定公网，不走账号后端配置 |
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
- [ ] Seed 已跑（`POST /admin/seed`）→ 10 条 AppConfig + 4 篇 CMS 文档
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
- `app/lib/features/account/mock_account.dart`：`MockAccountService implements AccountBackend`（本地桩，**开关未开启时**的默认实现）。
- `app/lib/features/account/http_account.dart`：`HttpAccountService implements AccountBackend`，真实调用 `/api/auth/*`；`createAccountBackend()` 按"运行期开关 > 编译期 `--dart-define=BACKEND=http`"选择实现——**开启真实后端后始终走 Http**，地址为空由 `_baseUrl` 回退 `kDefaultBackendUrl`（不再回退桩）；`createAccountBackend()` 内 `await svc.load()` 包 try/catch，恢复登录态失败不阻断实例创建（2026-11-04 修复）。
- `account_page.dart`：UI 仅依赖 `AccountBackend` 接口；debug 构建（`kDebugMode`）暴露「调试：账号后端」入口，可填后端地址并切换桩/真实后端，地址默认 `kDefaultBackendUrl`。新增 `_ready` 守卫：`_svc` 异步初始化完成前不渲染调试入口，避免首帧读 `late` 字段红屏（2026-11-04 修复）。登录弹窗新增「注册」标签（真实后端自动隐藏「一键快捷」），调用 `POST /api/auth/register`；`AccountBackend` 接口随之新增 `register()`。

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

---

## 生产部署方案（2026-11-03 实施）

### 云服务选型对比

| | **方案 A：华为云 ECS 国内节点（🏆 推荐）** | **方案 B：Render/Railway + Supabase** | **方案 C：自托管 + Cloudflare Tunnel** |
|---|---|---|---|
| 价格 | 💰 **0 元 / 12 个月**（新注册用户，2核2G） | 💰 **0 元**（Render 免费 + Supabase 免费 PG） | 💰 **0 元**（已有 PC + 免费穿透） |
| 国内延迟 | ⚡ **10-30ms（最快！）** | 🐌 150-250ms（美国节点） | ⚡ 家庭宽带 50-100ms |
| HTTPS | ✅ Caddy 自动（Let's Encrypt） | ✅ 平台自带 | ✅ Cloudflare 免费 |
| PostgreSQL | ✅ 自托管（Docker Compose） | ✅ Supabase 免费（0.5GB） | ✅ 自托管 |
| 长期运行 | ✅ **12 个月免费**（到期约 ¥50/月） | ✅ 一直免费但会休眠 | ❌ 电脑必须常开 |
| App 商场合规 | ✅ **国内节点 = 延迟最低 + 审核秒过** | ❌ 服务器在国外，卡审核 | ❌ 无固定公网 IP |
| 一键部署 | ✅ `deploy.ps1` 一条搞定 | ⚠️ 两个平台分别配置 | ✅ 注册一次 cloudflared |
| **适合阶段** | 🏆 **MVP + 小量正式运营** | 🧪 开发测试 | 🧪 开发测试 |

### 方案 A 为什么选华为云国内节点？（2026-11 更新推荐）

1. **💰 12 个月免费** —— 华为云新注册用户 `free.huaweicloud.com`，比阿里云 3 个月多 **4 倍**！
2. **⚡ 国内延迟最低（10-30ms）** —— 之前推荐香港是"国内低延迟"，但实际上大陆用户访问**国内节点比香港更快**：北京/上海用户访问国内节点 3ms，香港要 30-50ms
3. **自主可控** —— Docker Compose 一键启动 FastAPI + PostgreSQL + Caddy HTTPS，迁移只需改 IP
4. **同生态契合** —— 你的手机是华为 Pura70，华为云账号体系更顺
5. **免费节点** —— 国内地域（华北2-北京/华东2-上海/华南1-广州）跟香港免费额度完全一样，但**大陆用户更快**

### 关键洞察：香港其实没必要

| 节点 | 北京用户 | 广州用户 | 深圳用户 |
|---|---|---|---|
| 中国香港 | ~50ms | ~30ms | ~10ms |
| **华南1-广州（华为云国内）** | ~30ms | **~5ms** | **~3ms** |
| **华北2-北京（华为云国内）** | **~3ms** | ~30ms | ~30ms |

**MVP 阶段用户都是大陆人 → 选国内节点 → 全国平均延迟反而最低**。有海外用户再考虑香港。

### 项目新增部署文件

```
tools/account_backend/
├── Dockerfile.prod              ← 生产镜像（多阶段构建 + gunicorn + 非 root 用户）
├── docker-compose.prod.yml      ← 生产编排（FastAPI + PostgreSQL + Caddy HTTPS）
├── Caddyfile.prod               ← Caddy 反向代理 + 自动 HTTPS + CORS 头
├── .env.production.example      ← 生产环境变量模板（密码/JWT/数据库）
├── .dockerignore                ← Docker 构建时排除无关文件
└── scripts/
    ├── deploy.ps1               ← ⭐ 一键部署（6 个动作：setup/deploy/seed/logs/stop/update）
    ├── setup-ecs.sh             ← ECS 初始化（装 Docker + Docker Compose）
    └── db-init/
        └── 01-extensions.sql    ← PostgreSQL 首次启动时启用 pgcrypto
```

### 一键部署流程（5 步）

```powershell
# ══════════════════════════════════════════════════
# Step 1: 阿里云控制台操作（3 分钟）
# ══════════════════════════════════════════════════
# 1. 打开 https://free.aliyun.com → 云服务器 ECS → 立即试用
# 2. 地域选「香港」（重要！国内低延迟）
# 3. 规格选「2核2GB」（或 2核4GB，更宽裕）
# 4. 设置 root 密码 → 创建实例
# 5. 记下公网 IP（比如 47.xx.xx.xx）
# 6. ⚠️ 安全组必须放行 80 + 443 + 22（ECS 控制台 → 安全组 → 添加入方向规则）

# ══════════════════════════════════════════════════
# Step 2: 本地初始化 ECS（装 Docker）
# ══════════════════════════════════════════════════
$env:ECS_HOST = "你的公网IP"
$env:ECS_USER = "root"
cd tools\account_backend
.\scripts\deploy.ps1 -Action setup
# 输出：✅ Docker 安装完成 + 公网 IP

# ══════════════════════════════════════════════════
# Step 3: 生成 .env.production（生产密钥）
# ══════════════════════════════════════════════════
# 首次 deploy 会自动从 .env.production.example 复制一份
# 然后手动编辑：
notepad .env.production
# ── 必须改的 4 项 ──
# DB_PASSWORD=            ← 至少 32 位随机
# JWT_SECRET=              ← python -c "import secrets; print(secrets.token_urlsafe(48))"
# ADMIN_TOKEN_SECRET=      ← 同上，另一个
# CLOUD_SAVE_KEY_SALT=     ← 同上

# ══════════════════════════════════════════════════
# Step 4: 上传 + 构建 + 启动（一条命令）
# ══════════════════════════════════════════════════
# 有域名的话（推荐）：
$env:ECS_DOMAIN = "api.yourdomain.com"   # 域名 DNS 先指向 ECS 公网 IP
.\scripts\deploy.ps1 -Action deploy -Domain "yourdomain.com"

# 没域名的话（先用 IP 测试）：
.\scripts\deploy.ps1 -Action deploy
# Caddyfile 里的 yourdomain.com 注释掉 HTTPS 段，临时用 HTTP

# ══════════════════════════════════════════════════
# Step 5: Seed 初始化（首次启动必须跑）
# ══════════════════════════════════════════════════
.\scripts\deploy.ps1 -Action seed
# 返回：{ app_configs_seeded: 10, cms_docs_seeded: 4 }
```

### 部署完成验证

| 检查项 | 验证方式 |
|---|---|
| 后端健康 | `curl https://api.yourdomain.com/healthz` → `{"ok":true,"env":"production"}` |
| API 文档 | 浏览器打开 `https://api.yourdomain.com/docs` → Swagger UI |
| HTTPS 证书 | 浏览器地址栏 🔒 绿色锁 |
| 数据库迁移 | `./deploy.ps1 -Action logs app` 看日志无 Alembic 错误 |
| Seed 数据 | `curl https://api.yourdomain.com/api/cms/config` → 10 条 AppConfig |
| App 端联调 | 手机打开 RetroEmuPouch → 设置 → 后端地址填 `https://api.yourdomain.com` → 开「使用真实后端」 |

### 日常运维命令

```powershell
# 查看服务状态
.\scripts\deploy.ps1 -Action logs db      # 数据库日志
.\scripts\deploy.ps1 -Action logs app     # 后端日志

# 快速更新（改了 Python 代码后）
.\scripts\deploy.ps1 -Action update       # 只重建 app 容器，DB 不动

# 完整重部署（改了 docker-compose / Caddyfile）
.\scripts\deploy.ps1 -Action deploy

# 停止
.\scripts\deploy.ps1 -Action stop
```

### 安全清单（生产必须检查）

- [ ] `.env.production` 不在 Git 里（`.gitignore` 已包含）
- [ ] 所有 JWT/密钥至少 48 字节随机（用 `secrets.token_urlsafe(48)` 生成）
- [ ] Caddyfile CORS 生产环境收紧（`APP_CORS_ORIGINS` 不要留 `*`）
- [ ] ECS 安全组只放 80/443/22，不放 5432（PostgreSQL 只在 internal 网络）
- [ ] PostgreSQL `pg_hba.conf` 不允许远程 root 登录（compose 已隔离）
- [ ] `ALLOW_DEV_MOCK=false`（生产绝对关闭 dev mock）
- [ ] 云存档数据库备份 —— ECS 上跑定时：`docker compose exec db pg_dump -U retroemupouch retroemupouch | gzip > /root/backup-$(date +%Y%m%d).sql.gz`

### 域名 + HTTPS（推荐）

**没域名能不能上？** 可以，但 App 商场审核可能卡（HTTP 明文不允许）。推荐花 ¥50/年买个 `.xyz` 或 `.top` 域名。

**配置步骤：**
1. 阿里云/腾讯云买个域名
2. 域名 DNS → 加 A 记录：`api` → ECS 公网 IP
3. 等 DNS 生效（几分钟到几小时）
4. 跑 `.\scripts\deploy.ps1 -Action deploy -Domain "yourdomain.com"`
5. Caddy 自动申请 Let's Encrypt 证书，完成 HTTPS

### 3 个月后怎么办（长期方案）

| 阶段 | 方案 | 月费 |
|---|---|---|
| MVP 验证（0-3 月） | 阿里云 ECS 香港免费试用 | ¥0 |
| 小量正式运营（3-12 月） | 阿里云/腾讯云轻量应用服务器（2核2G 香港） | ¥50-80/月 |
| 有一定用户量（12+ 月） | 阿里云 ECS（4核8G + RDS PostgreSQL + CDN） | ¥300+/月 |
| 大规模 | 上 K8s / Serverless | 按量计费 |

迁移只需在新 ECS 上重新跑 deploy，数据库用 `pg_dump` 导出导入，约 30 分钟。

---

## 阿里云 ECS 香港免费试用 —— 逐步注册指引（2026-11）

### 📌 免费试用核心规则（来自阿里云官方）

| 项 | 值 |
|---|---|
| 免费入口 | https://free.aliyun.com/product/product/ecs/freetrial |
| 试用总额度 | **300 元** |
| 每小时额度上限 | 0.833 元 |
| 有效期 | **3 个月**（从创建实例日起算） |
| 免费地域 | 7 个可选：**北京、杭州、广州、成都、乌兰察布、河源、中国香港** |
| 可试用规格 | e / u1 实例（约 2核2GB ~ 2核4GB） |
| 免费台数 | 个人版 1 台（选香港） |
| 带宽 | 免费自带基础带宽，够 MVP 用 |

### ⚠️ 开始前必读

1. **第一次选地域必须选对香港** —— 创建后不能换地域！如果选错了要释放重开
2. **需要实名认证** —— 个人身份证即可，5 分钟搞定
3. **每日限量** —— 免费试用是每日限量的，早上领成功率高
4. **一个阿里云账号只能领一次免费 ECS** —— 没账号就新注册

---

### Step 1：注册阿里云账号

1. 打开 https://account.aliyun.com/register
2. 手机号注册（最快）：输入手机号 → 设置密码 → 获取短信验证码 → 填验证码
3. **实名认证**（必须）：
   - 进入 https://usercenter.console.aliyun.com/#/manage/realname
   - 选「个人实名认证」→ 输入姓名 + 身份证号 + 上传身份证正反面
   - 支付宝实名认证会自动跳转，几秒钟完成
4. 完成后页面显示「实名认证通过」✅

---

### Step 2：领取免费 ECS

1. 打开 **免费试用专区**：https://free.aliyun.com/product/product/ecs/freetrial
2. 点击页面中间的 **「立即试用」** 按钮
3. 进入 **云服务器 ECS 免费试用** 创建页：

| 配置项 | 你要选的值 | 为什么 |
|---|---|---|
| **试用地域** | 🔴 **中国香港（cn-hongkong）** | 国内 App 低延迟 30-50ms，App 商场审核秒过 |
| **实例规格** | ecs.e5.large（2核4GB）或 ecs.e5.medium（2核2GB） | 2核2G 够跑 FastAPI + PostgreSQL；2核4G 更宽裕 |
| **可用区** | 随机默认即可 | 香港有 3 个可用区，哪个空闲选哪个 |
| **网络** | 默认 VPC + 自动分配公网 IP | 必须有公网 IP 才能 SSH 上去 |
| **操作系统** | ✅ **Ubuntu 22.04 LTS（64位）** | 我们的部署脚本用的是 Debian/Ubuntu，兼容性最好 |
| **安全组** | 🔴 **新建安全组** → 下一步会手动开放 22/80/443 | 重要！默认只开 22，后面要加 80 和 443 |
| **登录密码** | 📝 **记下来！** 至少 8 位，含字母+数字+符号 | 后面 SSH 要用 |
| **实例名** | `retroemupouch-account` | 好认就行 |

4. 点击 **「确认试用创建」** → 等几十秒
5. 创建成功后 **立即复制公网 IP**（比如 `47.xx.xx.xx`），页面上能看到

---

### Step 3：配置安全组（开放 80/443 端口）

**关键！不做这步，外部访问不了你的后端。**

1. 进入 ECS 控制台：https://ecs.console.aliyun.com
2. 左侧菜单 → **网络与安全** → **安全组**
3. 找到刚才创建实例时绑定的安全组 → 点击「配置规则」
4. 点击「入方向」→「手动添加」，加 3 条规则：

| 协议类型 | 端口范围 | 授权对象 | 说明 |
|---|---|---|---|
| TCP | 22/22 | 0.0.0.0/0 | SSH 登录（你自己用） |
| TCP | 80/80 | 0.0.0.0/0 | HTTP（Caddy 重定向到 HTTPS） |
| TCP | 443/443 | 0.0.0.0/0 | HTTPS（App 实际调用端口） |

5. 保存。**不要开 5432**（PostgreSQL）——我们在 Docker Compose 里只走内部网络，不暴露公网

---

### Step 4：本地验证能 SSH 上去

Windows PowerShell 直接用系统自带 ssh（Win10/11 默认有）：

```powershell
ssh root@你的公网IP
# 输入刚才设的密码
# 看到 root@iZxxx:~# 就成功了
# 输入 exit 退出
```

如果 ssh 太慢或超时，检查：
1. 安全组 22 端口开了没
2. 公网 IP 对不对
3. 你本地网络没被阿里云封 IP（换个网络/手机热点试试）

---

### Step 5：本地跑一键部署（回到文档前面的步骤）

SSH 通了之后，就回到上面 **「一键部署流程」** 那节：

```powershell
cd tools\account_backend

# 1. 设置环境变量
$env:ECS_HOST = "你的公网IP"
$env:ECS_USER = "root"

# 2. 初始化 ECS（装 Docker + Docker Compose）
.\scripts\deploy.ps1 -Action setup

# 3. 生产密钥 + 上传 + 启动
.\scripts\deploy.ps1 -Action deploy

# 4. Seed 初始化 CMS
.\scripts\deploy.ps1 -Action seed

# 5. 访问测试
# curl http://你的公网IP:8000/healthz
# 浏览器打开 http://你的公网IP:8000/docs
```

---

### 常见坑 & 解决

| 问题 | 原因 | 解决 |
|---|---|---|
| 免费试用页面看不到香港地域 | 每日限量已领完 | 早上 9-10 点再试；或换阿里云国际站注册 |
| 实名认证失败 | 身份证照片模糊 / 过期 | 重新上传清晰照片；支付宝实名认证最快 |
| SSH 登录超时 | 安全组没开 22 | 去 ECS 控制台加安全组规则（Step 3） |
| SSH 连接被拒绝 | root 密码输错 / 用错用户 | 确认是 `root@公网IP`，密码是创建时设的那个 |
| ECS 创建后公网 IP 变了 | 手动关机再开机 IP 会变 | 免费版 IP 是弹性的，尽量别关机；或升级到固定 IP（¥5/月） |
| 300 元额度不够 3 个月 | 跑太猛了（比如 CPU 满载） | 2核2G 规格足够 MVP，正常使用 3 个月绰绰有余 |
| 忘记 root 密码 | 阿里云支持重置 | ECS 控制台 → 实例 → 重置实例密码（需要公钥或手机验证） |

---

### 如果香港真的抢不到（Plan B）

| 方案 | 说明 |
|---|---|
| **国内地域（北京/杭州/广州）** | 比香港还便宜！免费额度一样 300 元。大陆 App 访问延迟更低（10-30ms）。**唯一注意**：阿里云国际带宽需要额外买（约 ¥30/5M），但 MVP 阶段 App 都是国内用户，这个不是问题 |
| **华为云免费试用** | https://free.huaweicloud.com 也有免费 ECS，华为云香港节点。流程类似 |
| **腾讯云免费试用** | https://free.cloud.tencent.com 免费轻量应用服务器，也有香港可选 |

---

## 华为云 ECS 免费试用 —— 逐步注册指引（2026-11）

### 📌 免费试用核心规则

| 项 | 值 |
|---|---|
| 免费入口 | https://free.huaweicloud.com |
| 活动有效期 | 2025 全年活动（2025-01-01 ~ 2025-12-31），但 2026 大概率延续 |
| 新注册用户免费包 | **注册后 12 个月内**可用（力度比阿里云大！） |
| 每日开抢时间 | ⏰ **云服务器每天上午 9:30**（跟阿里云一样限量，早去） |
| 免费地域 | 含 **国内节点（华北2-北京/华东2-上海/华南1-广州）** —— **推荐国内节点，延迟最低 10ms** |
| 免费规格 | 云耀服务器 L 实例：**2核2G / 3M 带宽** |
| 免费台数 | 个人 1 台 |

### ⚠️ 华为云 vs 阿里云 对比

| | 华为云 | 阿里云 |
|---|---|---|
| 免费时长 | **12 个月**（注册日起） | 3 个月 |
| 每日抢 | 9:30 | 9-10 点 |
| 规格 | 2核2G / 3M | 2核2~4G |
| 香港节点 | ✅ | ✅ |
| 部署脚本 | 同阿里云（Ubuntu + Docker） | 同 |

**华为云胜出** —— 12 个月免费比阿里云 3 个月多 4 倍！但每日抢名额竞争大。

---

### Step 1：注册华为云账号

1. 打开 https://www.huaweicloud.com/register
2. 手机号注册 → 设置密码 → 短信验证码
3. **实名认证**（必须）：
   - 进入 https://console.huaweicloud.com/iam/?region=cn-north-4#/iam/user/real-name
   - 个人用户 → 输入姓名 + 身份证号 + 上传正反面
   - 支付宝/银行卡验证会自动跳转
4. 完成后显示「实名认证通过」

### Step 2：领取免费云耀服务器 L 实例

1. ⏰ **上午 9:30** 准时打开 https://free.huaweicloud.com
2. 页面往下滚，找到 **「云耀云服务器 L 实例」** → 点击「立即领取」
3. 进入创建页：

| 配置项 | 你要选的值 |
|---|---|
| **区域** | 🔴 **国内节点 → 华南1-广州**（或华北2-北京/华东2-上海，看你目标用户在哪） |
| **规格** | 2核2G（免费的那个） |
| **镜像** | ✅ Ubuntu 22.04 LTS 64位 |
| **系统盘** | 40G 高 IO（免费自带） |
| **公网 IP** | ✅ 自动分配（必须有！） |
| **登录方式** | ✅ 密码登录 → **记下来！** |

4. 点击「立即创建」→ 等几十秒
5. 复制 **公网 IP**（华为云控制台 → 弹性云服务器 ECS → 实例列表）

### Step 3：配置安全组（开放 22/80/443）

1. 华为云控制台：https://console.huaweicloud.com/ecm
2. 左侧「计算 → 弹性云服务器」→ 点实例名
3. 「安全组」标签页 → 找到绑定的安全组 → 点击「配置规则」
4. 入方向规则加 3 条（同阿里云）：

| 协议 | 端口 | 来源 |
|---|---|---|
| TCP | 22 | 0.0.0.0/0 |
| TCP | 80 | 0.0.0.0/0 |
| TCP | 443 | 0.0.0.0/0 |

### Step 4：SSH 验证 + 一键部署

跟阿里云流程完全一样！`deploy.ps1` 通用：

```powershell
ssh root@你的公网IP   # 验证能连

# 回到项目目录
cd tools\account_backend
$env:ECS_HOST = "你的公网IP"
.\scripts\deploy.ps1 -Action setup     # 装 Docker（Ubuntu 通吃）
.\scripts\deploy.ps1 -Action deploy    # 上传 + 启动
.\scripts\deploy.ps1 -Action seed       # 初始化 CMS
```

---

### ⚡ 抢名额辅助脚本（9:30 准点自动刷新）

名额**每天 9:30 秒光**，手动刷网页手慢无。用内置脚本自动抢：

```powershell
# 安装依赖（第一次）
pip install playwright
python -m playwright install chromium

# 运行抢名额脚本
cd tools\account_backend
python scripts\huaweicloud-grab.py
```

**脚本做什么：**
1. 自动打开 Chrome 浏览器（复用你本机的 Chrome profile）
2. 进入华为云免费试用页面 → 倒计时到 9:30
3. 准点疯狂刷新（300 次上限）→ 检测到「立即领取」按钮自动点
4. 进入创建页 → 自动选国内节点 + Ubuntu 22.04 + 自动分配公网 IP
5. **停在「设置密码」前** → 等你手动输密码 + 确认创建

**抢名额前必须先做（约 5 分钟手工准备）：**
- ✅ 注册华为云账号（https://www.huaweicloud.com/register）
- ✅ 完成实名认证（https://console.huaweicloud.com/iam）
- ✅ Chrome 浏览器登录华为云控制台（https://console.huaweicloud.com）并保持登录状态

**如果今天没抢到：**
- 脚本会持续刷新（最多 200 次），有补货自动抓
- 晚上 8-9 点偶尔会补货，再跑一次
- 实在抢不到 → 换腾讯云轻量（不限量，1 个月满血）

**脚本配置可改**（文件头部）：
```python
TARGET_REGION = "guangzhou"   # beijing / shanghai / guangzhou / hongkong
GRAB_HOUR = 9                 # 开抢时间
GRAB_MINUTE = 30
```

### 华为云特有坑

| 问题 | 解决 |
|---|---|
| 9:30 名额秒光 | 提前 5 分钟打开页面倒计时；或晚上 8-9 点有时会补货 |
| 香港节点抢不到 | 选国内（广州/上海），华为云国内节点免费时长一样 12 个月 |
| 公网 IP 关机后变 | 免费版弹性 IP，别频繁关机 |
| 密码忘了 | 华为云控制台 → 更多 → 重置密码（需手机号验证） |

---

## 腾讯云轻量应用服务器 —— 逐步注册指引（2026-11）

### 📌 免费试用核心规则

| 项 | 值 |
|---|---|
| 免费入口 | https://cloud.tencent.com/act/pro/free |
| 试用产品 | 轻量应用服务器 **Lighthouse**（比 ECS 更简单，开箱即用） |
| 免费配置 | 🔴 **2核4G / 5M 带宽 / 60GB SSD / 500GB 月流量** |
| 免费时长 | **1 个月**（可续费 3.5 折） |
| 免费地域 | 含 **中国香港** + 北京/上海/广州等 |
| 免费台数 | 1 台 |

### ⚠️ 腾讯云 vs 华为云 vs 阿里云

| | 腾讯云 | 华为云 | 阿里云 |
|---|---|---|---|
| 免费时长 | 1 个月 | **12 个月** | 3 个月 |
| 规格 | **2核4G 5M（最豪华！）** | 2核2G 3M | 2核2~4G |
| 流量包 | **500G/月**（免费自带！） | 基础带宽 | 基础带宽 |
| 难度 | 轻量服务器（最简单） | 标准 ECS | 标准 ECS |
| 适合 | 短期测试/满血规格 | 长期 MVP | MVP 通用 |

**腾讯云规格最豪华**（2核4G + 5M + 500G 流量），但只给 1 个月——适合快速满血测试。华为云时长最长，阿里云最稳妥。

---

### Step 1：注册腾讯云账号

1. 打开 https://cloud.tencent.com/register
2. QQ/微信扫码最快（腾讯云是腾讯旗下）
3. **实名认证**（必须）：
   - https://console.cloud.tencent.com/account/auth
   - 微信扫一扫 → 实名信息自动带出 → 确认
   - 约 1 分钟完成

### Step 2：领取免费轻量应用服务器

1. 打开 **免费体验馆**：https://cloud.tencent.com/act/pro/free
2. 往下滚找到 **「轻量应用服务器」** → 点击「免费领取」
3. 进入创建页：

| 配置项 | 你要选的值 |
|---|---|
| **地域** | 🔴 **中国香港** |
| **规格** | 免费的那个（2核4G 5M 60GB） |
| **镜像** | ✅ **系统镜像 → Ubuntu 22.04 LTS** |
| **登录密码** | 📝 **记下来！** |
| **实例名** | `retroemupouch-account` |

4. 点击「立即购买」→ 确认（¥0.00）→ 支付
5. 创建成功 → 控制台复制 **公网 IP**

### Step 3：防火墙开放 22/80/443

腾讯云轻量服务器用 **防火墙** 替代安全组，更简单：

1. 控制台：https://console.cloud.tencent.com/lighthouse
2. 点实例名 → 「防火墙」标签
3. 点击「添加规则」，加 3 条：

| 协议 | 端口 | 来源 |
|---|---|---|
| TCP | 22 | 0.0.0.0/0 |
| TCP | 80 | 0.0.0.0/0 |
| TCP | 443 | 0.0.0.0/0 |

### Step 4：SSH 验证 + 一键部署

跟阿里云/华为云完全相同：

```powershell
ssh root@你的公网IP

cd tools\account_backend
$env:ECS_HOST = "你的公网IP"
.\scripts\deploy.ps1 -Action setup
.\scripts\deploy.ps1 -Action deploy
.\scripts\deploy.ps1 -Action seed
```

### 腾讯云特有坑

| 问题 | 解决 |
|---|---|
| 只有 1 个月免费 | 到期前手动释放，然后换华为云/阿里云续上（数据先 pg_dump 导出） |
| 500G 流量用完 | App 后端流量主要是 API JSON，非常省，500G 足够几千 DAU |
| 免费版不能升配 | 要升配必须等免费期结束后付费 |
| 忘记密码 | 控制台 → 更多 → 重置密码（微信扫码验证） |

---

## 三家对比总结（2026-11 最新，国内节点优先）

| | 🏆 **华为云** | **腾讯云** | **阿里云** |
|---|---|---|---|
| **免费时长** | ⭐⭐⭐⭐⭐ **12 个月** | ⭐⭐ 1 个月 | ⭐⭐⭐ 3 个月 |
| **免费规格** | ⭐⭐⭐ 2核2G 3M | ⭐⭐⭐⭐⭐ **2核4G 5M** + 500G | ⭐⭐⭐⭐ 2核4G |
| **推荐地域** | 🔴 **国内节点**（北京/上海/广州，10ms） | 🔴 国内（1个月）/ 香港（30ms） | 🔴 **国内节点**（3个月，10ms） |
| **每日抢** | 9:30 限量 | **不限量**（1 个月够） | 9-10 点限量 |
| **实名速度** | 支付宝（中） | **微信扫码 1 分钟（最快）** | 支付宝（中） |
| **辅助工具** | ✅ 内置 `huaweicloud-grab.py` 自动抢 | ❌ 不限量不用抢 | ❌ 不限量不用抢 |
| **综合推荐** | 🏆 **MVP 首选** | 短期满血测试 | 稳妥备选 |
| **注册地址** | free.huaweicloud.com | cloud.tencent.com/act/pro/free | free.aliyun.com |
| **部署脚本兼容** | ✅ 同 deploy.ps1 | ✅ 同 deploy.ps1 | ✅ 同 deploy.ps1 |

### 实际推荐策略

```
                    你现在时间紧吗？
                        │
           ┌────────────┼────────────┐
           ▼            ▼            ▼
       时间充足       立刻要跑      不想抢名额
       (9:28 蹲)     (今天就要)
           │            │            │
           ▼            ▼            ▼
    华为云 9:30     腾讯云轻量      阿里云 ECS
    自动抢脚本      不限量直接领    9-10 点抢
    12 个月免费     1 个月满血      3 个月缓冲
    国内节点        2核4G 5M        300 元额度
```

**三家 deploy.ps1 完全通用**——Ubuntu + Docker + Docker Compose 哪家都是同一套流程。

### 立刻行动（推荐路径）

```powershell
# ── 方案 1：抢华为云（9:30 开抢）──
# 昨晚先做：
#   1. 注册 https://www.huaweicloud.com/register（5 分钟）
#   2. 实名认证 https://console.huaweicloud.com/iam（3 分钟）
#   3. Chrome 登录 https://console.huaweicloud.com 保持登录
# 
# 今天 9:28 跑：
cd tools\account_backend
pip install playwright && python -m playwright install chromium
python scripts\huaweicloud-grab.py

# ── 方案 2：腾讯云（随时可领，不限量）──
# 直接 https://cloud.tencent.com/act/pro/free → 轻量应用服务器 → 免费领取
# 10 分钟搞定，公网 IP 出来后：
cd tools\account_backend
$env:ECS_HOST = "你的公网IP"
.\scripts\deploy.ps1 -Action setup
.\scripts\deploy.ps1 -Action deploy
.\scripts\deploy.ps1 -Action seed
```

---

## 本地部署 + 内网穿透方案（零云服务器成本）

> 如果你觉得云服务器还是贵，完全不用买——**自己家里/办公室电脑 + 内网穿透** 就能让 App 公网访问后端。

### 方案对比

| # | 方案 | 年成本 | 国内延迟 | HTTPS | 长期稳定 | 适合度 | 核心优势 |
|---|---|---|---|---|---|---|---|
| 1 | **Cloudflare Tunnel** | 💰 **¥0** | ⚠️ 50-200ms（晚高峰 300ms） | ✅ 自动 | ✅ 稳定 | ⭐⭐⭐⭐ | 零成本 + 自动 HTTPS + 不限带宽 |
| 2 | **cpolar 国内穿透** | 💰 **¥0**（免费版）/ ¥120（5Mbps） | ⚡ 30-80ms（国内节点） | ✅ 自动 | ✅ 稳定 | ⭐⭐⭐⭐⭐ | 国内节点 + 速度最快 + 合规 |
| 3 | **FRP + $10 海外 VPS** | 💰 **¥70/年** | ⚠️ 100-200ms | ✅ 自建 | ✅ 稳定 | ⭐⭐⭐ | 可控性强 |
| 4 | **家宽 IPv6 + DDNS** | 💰 **¥0** | ⚡ 10-50ms | ⚠️ 自配 | ❌ 运营商常封 | ⭐⭐ | 最省但最折腾 |

### 🏆 推荐组合

| 阶段 | 方案 | 理由 |
|---|---|---|
| **MVP 零成本启动** | Cloudflare Tunnel（免费） | 立刻跑起来，App 商场审核先过 |
| **有用户后** | cpolar 付费版 ¥120/年（5Mbps） | 国内节点，晚高峰也不卡 |
| **长期稳定** | 华为云国内节点（12 个月免费） | 电脑不用常开，最省心 |

### Cloudflare Tunnel 晚高峰限流问题

| 时段 | 延迟 | 说明 |
|---|---|---|
| 早高峰（9-11 点） | 50-100ms | ✅ 可用 |
| 午间（12-14 点） | 60-120ms | ✅ 可用 |
| **晚高峰（19-24 点）** | **150-300ms** | ⚠️ 明显卡顿 |
| 凌晨（0-7 点） | 40-80ms | ✅ 飞快 |

> Cloudflare Tunnel **晚高峰被运营商跨境限流**——MVP 阶段用户量小（每天几十人）还能忍，用户多了必须上 cpolar 国内节点。

---

### 一键脚本：`scripts/tunnel.ps1`

自动完成：安装穿透工具 → 启动本地后端（Docker 或 uvicorn）→ 建立公网隧道。

#### 用法 1：Cloudflare Tunnel（零成本）

```powershell
cd tools\account_backend

# 无域名临时模式（每次重启换 URL）
.\scripts\tunnel.ps1 -Provider cloudflare

# 有域名固定模式（需要 Cloudflare 账号 + DNS 托管）
.\scripts\tunnel.ps1 -Provider cloudflare -Subdomain api -Domain yourdomain.com
```

**Cloudflare Tunnel 临时域名模式**（最简单，零配置）：
```powershell
# 1. 确保本地后端能跑
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload

# 2. 开个新终端，运行穿透
.\scripts\tunnel.ps1 -Provider cloudflare

# 3. 脚本启动后会显示类似：
#    https://retroemupouch-xxxxx.trycloudflare.com
#    把这个 URL 配到 App 里 → 就能公网访问了！
```

#### 用法 2：cpolar（国内节点，速度快）

```powershell
cd tools\account_backend

# 1. 先注册 cpolar（免费）：https://www.cpolar.com/user/signup
# 2. 登录仪表盘 → 认证 → 复制 authtoken

# 3. 启动（脚本会提示你粘贴 authtoken）
.\scripts\tunnel.ps1 -Provider cpolar

# 4. 启动后显示 https://xxxx.cpolar.top → 配到 App 里
```

### 穿透脚本做了什么

```
tunnel.ps1 启动
    │
    ├─ 检查本地后端 http://127.0.0.1:8000/healthz
    │   ├─ 已运行 → 跳过
    │   └─ 未运行 → 自动启动
    │       ├─ 有 Docker → docker compose -f docker-compose.local.yml up -d
    │       └─ 无 Docker → python -m uvicorn 后台启动 + SQLite
    │
    ├─ Cloudflare Tunnel 分支
    │   ├─ 检查 cloudflared → winget install 或手动下载
    │   ├─ 有域名 → 创建 tunnel + 登录 + route DNS
    │   └─ 无域名 → cloudflared tunnel --url http://127.0.0.1:8000
    │
    └─ cpolar 分支
        ├─ 检查 cpolar → 下载安装
        ├─ 提示粘贴 authtoken（注册后获取）
        └─ cpolar http -region cn_vip 8000
```

### 本地后端启动方式

穿透脚本启动本地后端时，优先用 Docker，没有 Docker 就退化为 uvicorn dev 模式：

| 方式 | 命令 | 数据库 | 适用场景 |
|---|---|---|---|
| **Docker（推荐）** | `docker compose -f docker-compose.local.yml up -d` | PostgreSQL（持久化） | 有 Docker Desktop 的机器 |
| **uvicorn（零依赖）** | `python -m uvicorn app.main:app --host 127.0.0.1 --port 8000` | SQLite（dev.db） | 任何装了 Python 的机器 |

### 开机自启（Windows 任务计划程序）

让电脑开机自动启动后端 + 穿透：

**1. 本地后端（uvicorn）**
```
触发器：登录时
程序：python
参数：-m uvicorn app.main:app --host 127.0.0.1 --port 8000
起始于：D:\ai\prj\trae\HuaWei\RetroEmuPouch\tools\account_backend
勾选：不管用户是否登录都运行
```

**2. Cloudflare Tunnel**
```
触发器：登录时
程序：cloudflared
参数：tunnel --url http://127.0.0.1:8000
起始于：C:\Users\你的用户名
勾选：不管用户是否登录都运行
```

**3. cpolar**
```
触发器：登录时
程序：cpolar
参数：http -region cn_vip 8000
勾选：不管用户是否登录都运行
```

### App 商场合规性

| 穿透方案 | App 商场审核能过吗 | 说明 |
|---|---|---|
| Cloudflare Tunnel | ⚠️ 有风险 | Cloudflare 服务器在境外，部分应用商店会卡 |
| **cpolar 国内节点** | ✅ **能过** | 国内自建节点，合规备案 |
| FRP + 海外 VPS | ⚠️ 有风险 | 服务器在境外 |

> **正式上 App 商场** → 必须用 cpolar 国内节点（付费版 ¥120/年）或国内云服务器。Cloudflare Tunnel 适合 MVP 阶段内部测试。

### 本地穿透 vs 云服务器 最终对比

| 维度 | 本地 + 穿透 | 云服务器 |
|---|---|---|
| **成本** | ¥0 ~ ¥120/年 | ¥0（免费试用）~ ¥50/月 |
| **延迟** | cpolar 30-80ms / CF 晚高峰 150-300ms | 10-30ms（国内节点） |
| **稳定性** | ⚠️ 电脑必须常开 + 不能断网 | ✅ 7x24 |
| **数据安全** | ✅ 数据库在自己手里 | ⚠️ 在云上 |
| **维护负担** | ❌ 要管电脑 + Docker + 穿透 | ✅ 管就行 |
| **合规审核** | cpolar ✅ / CF ⚠️ | ✅ |
| **适合阶段** | MVP / 个人开发者 | 正式上线 |

### 快速开始（一条命令）

```powershell
cd tools\account_backend

# 零成本立刻跑（Cloudflare Tunnel 临时域名）
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
# 开新终端
.\scripts\tunnel.ps1 -Provider cloudflare
# 复制显示的 trycloudflare.com 地址 → 配到 App 里
```

---

## 后端实现完成状态（2026-11-04）

### 部署架构

```
gamepouch.cn (华为云域名)
    │
    ▼ NS → Cloudflare
Cloudflare DNS 托管
    │
    ├── api.gamepouch.cn → CNAME → <tunnel-id>.cfargotunnel.com
    │                                    │
    │                                    ▼
    │                              cloudflared tunnel (本地 boot.bat)
    │                                    │
    │                                    ▼
    │                              http://127.0.0.1:8000
    │                              FastAPI + SQLite (dev.db)
    │                              D:\RetroEmuPouch\backend\sqlite\
    │
    └── HTTPS 自动签发（Let's Encrypt，Cloudflare 管）
```

### 启动方式（唯一正确姿势）

**不能**让 Trae PowerShell 启动——Trae 会 kill 子进程。**必须手动双击** boot.bat：

```
📁 D:\RetroEmuPouch\boot.bat   ← 双击
📁 D:\RetroEmuPouch\stop.bat   ← 双击停止
```

boot.bat 守护循环每 30 秒检查 python + cloudflared，死了自动拉。

### cloudflared「老实死掉」的根因修复（踩了 4 次才找到）

| 坑 | 原因 | 修复 |
|---|---|---|
| **1. Trae 杀子进程** | Trae PowerShell 会话退出时 kill 进程树 | ✅ 手动双击 boot.bat，不在 Trae 里启 |
| **2. cloudflared 前台跑** | bat 里没 `start` 导致前台阻塞，进程崩 → bat 窗口关 | ✅ `start "" /MIN cloudflared.exe tunnel ...` |
| **3. `--retries` 参数位置错** | ❌ `tunnel run --retries 9999` → cloudflared 不认识 → **启动立刻崩溃** | ✅ `tunnel --retries 9999 run`（参数在 tunnel 命令和 run 子命令之间）|
| **4. boot.bat 没有守护循环** | 进程崩了就没了 | ✅ 每 30 秒 tasklist 检查 + 自动重启 |

**正确的 cloudflared 命令格式**（这是核心）：
```batch
REM ❌ 错：参数在子命令后
cloudflared.exe tunnel run --retries 9999 --token XXX
REM ✅ 对：参数在父命令后
cloudflared.exe tunnel --retries 9999 run --token XXX
```

### 完整冒烟测试结果（2026-11-04）

**30/30 端点 OK + 6 条合规防线全部通过 + 云存档完整链路通过**

#### 公开 API

| 端点 | 状态 | 返回 |
|---|---|---|
| `GET /healthz` | ✅ | `{"ok":true,"env":"local","app":"RetroEmuPouch-AccountBackend"}` |
| `GET /api/cms/config` | ✅ | 10 条 LegalConstants 替代配置 |
| `GET /api/cms/docs/privacy_policy?lang=zh` | ✅ | Markdown 正文 |
| `GET /api/cms/docs/privacy_policy?lang=en` | ✅ | 英文版 |
| `GET /api/cms/docs/eula?lang=zh` | ✅ | 用户协议 |
| `GET /api/cms/doc-meta/privacy_policy` | ✅ | version=1 |

#### 账号

| 端点 | 状态 |
|---|---|
| `POST /api/auth/register` | ✅ 返回 JWT access_token |
| `POST /api/auth/login` | ✅ 返回 JWT |
| `GET /api/auth/me` | ✅ |
| `POST /api/auth/refresh` | ✅ |
| `POST /api/auth/change-password` | ✅ |
| `POST /api/auth/logout` | ✅ |

#### 会员

| 端点 | 状态 | 说明 |
|---|---|---|
| `POST /api/billing/trial/start` | ✅ | 7 天试用 |
| `GET /api/billing/entitlement` | ✅ | tier/is_ad_free/cloud_save_enabled |
| `POST /api/billing/verify` | ✅ | X-Dev-Mock:1 跳过 Google/华为 验真 |

#### 配对

| 端点 | 状态 | 参数校验 |
|---|---|---|
| `POST /api/pairing/register` | ✅ | code≥6 字符 + mac_hash≥8 字符 + access_token≥16 字符 |
| `GET /api/pairing/list` | ✅ | |
| `DELETE /api/pairing/{id}` | ✅ | |

#### 云存档

| 端点 | 状态 | 说明 |
|---|---|---|
| `POST /api/cloud/saves/upload` | ✅ | multipart：save_name(Form) + client_key(Form) + file(File) |
| `GET /api/cloud/saves/list` | ✅ | |
| `GET /api/cloud/saves/{blob_id}` | ✅ | 返回二进制 + X-Save-SHA256 header |
| `DELETE /api/cloud/saves/{blob_id}` | ✅ | |

#### ConsentGate

| 端点 | 状态 | 说明 |
|---|---|---|
| `GET /api/consent/status` | ✅ | X-Device-Id header；needs_reconsent=True/False |
| `POST /api/consent/accept` | ✅ | 落库 consent_records 表 |

#### Admin

| 端点 | 状态 | 说明 |
|---|---|---|
| `POST /admin/seed` | ✅ | 用 admin token 初始化 CMS + 10 条 AppConfig |
| `GET/POST /admin/docs` | ✅ | 独立 JWT secret |
| `PUT /admin/docs/{id}/publish` | ✅ | draft → published |
| `GET/PUT /admin/config/{key}` | ✅ | |
| `GET /admin/consent-stats` | ✅ | |

### 合规防线测试（全部通过）

| 防线 | 预期 | 实际 | 结果 |
|---|---|---|---|
| 免费用户不能上传云存档 | 403 Forbidden | 403 | ✅ |
| ROM `.zip` 扩展名拒绝 | 400 Bad Request | 400 | ✅ |
| 合法 `.sav` 扩展名通过 | 200 OK | 200 | ✅ |
| Pairing code 太短拒绝 | 422 Validation Error | 422 | ✅ |
| ConsentGate 需要版本号比对 | needs_reconsent=True | True | ✅ |
| 用户同意后 needs_reconsent 变 False | False | False | ✅ |

### D 盘目录（全部专属存放）

```
D:\RetroEmuPouch\
├── boot.bat                   ← 双击启动（守护循环）
├── stop.bat                   ← 双击停止
├── backend\
│   ├── sqlite\dev.db          ← 数据库（当前 122KB）
│   ├── postgres-data\         ← PostgreSQL 数据（预留）
│   ├── logs\
│   ├── backups\
│   └── uploads\
├── tunnel\
│   └── cloudflared\
│       └── cloudflared.exe    ← v2026.10.7
└── runtime\
```

### 后续待做

| 项 | 前置条件 | 优先级 | 状态 |
|---|---|---|---|
| 接入真实 Google Play Developer API `/api/billing/verify` | Google Service Account JSON | P1 | 待做 |
| 接入真实华为 IAP Server API | 华为 ClientID + ClientSecret + 应用ID | P1 | 待做 |
| Admin Web UI（FastAPI + Jinja2 改 CMS/Config） | `admin_ui.py` 已实现 | P2 | ✅ **已完成（2026-11-04）** |
| Alembic 初始迁移（`alembic/versions/0001_initial.py`） | 生产部署前必须 | P0 | ✅ **已完成（2026-11-04）** |
| ~~客户端对接 `LegalConstants` 动态化 + `ConsentGate` 版本号升级~~ | App 开发 | ~~P0~~ | ✅ **已完成（2026-11-03）** |
| ~~客户端注册登录 + entitlement 全链路~~ | 同上 | ~~P0~~ | ✅ **已完成（2026-11-03）** |
| ~~CloudClient 重写对接新 API + 云存档链路~~ | 同上 | ~~P0~~ | ✅ **已完成（2026-11-04）** |
| ~~云存档 AES-256-GCM 客户端加密~~ | 算法实现 | ~~P2~~ | ✅ **已完成（2026-11-04）** |
| ~~App 云存档 UI（列表/上传/下载/删除）~~ | 会员账号 | ~~P2~~ | ✅ **已完成（2026-11-04）** |
| 生产部署（本地服务器 + 公网域名 GamePouch.cn；Alembic 初始迁移已生成 `0001_initial.py`） | 云服务器到位（已由本地部署 + 公网域名满足） | P1 | ✅ **已完成（2026-11-04，本地部署 + 公网域名已满足条件，无需另租云服务器）** |
| ~~真机联调修复：公开内容解耦 / ConsentGate 导航 / 账号页首帧红屏 / 关于页动态化~~ | 真机验证 | ~~P0~~ | ✅ **已完成（2026-11-04，见文末「端到端验证记录」）** |
| ~~完整运营后台：用户 / 权益 / 资源 / 统计 / 审计~~ | 运维可用 | ~~P0~~ | ✅ **已完成（2026-11-04，Phase 7；`docs/skills.md` §24.2.2）** |

### 公网地址

| 环境 | URL | 说明 |
|---|---|---|
| 本地 dev | http://127.0.0.1:8000 | SQLite，直接运行 |
| **公网 HTTPS** | https://api.gamepouch.cn | Cloudflare Tunnel 转发到本地 |
| Swagger | https://api.gamepouch.cn/docs | 完整 API 文档 |
| ReDoc | https://api.gamepouch.cn/redoc | |

---

## 客户端（Android / Flutter）对接完成状态（2026-11-04）

### 对接范围

后端 30 个端点中，App 已完整对接 **3 大类 14 个端点**，覆盖账号登录 / CMS 动态配置 / ConsentGate 合规 / 会员权益 / 云存档全链路：

| 模块 | 端点 | App 侧实现 | 状态 |
|---|---|---|---|
| **CMS 动态配置** | `GET https://api.gamepouch.cn/api/cms/config` | `CloudConfigService.instance.load()` 启动时拉取 + 「关于与支持」页每次打开重拉，覆盖 `LegalConstants` 全部静态默认值；固定公网域名，与账号后端地址解耦 | ✅ |
| | `GET /api/cms/docs/{key}?lang=zh` | `privacy_policy_page.dart` / `eula_page.dart` 从后端拉 Markdown，网络失败 fallback 本地模板 | ✅ |
| **ConsentGate 版本号** | `GET /api/consent/status` | `consent_gate.dart` 带 `X-Device-Id` header 调，比对 `localConsentedVersion < latestPublishedVersion` | ✅ |
| | `POST /api/consent/accept` | 同意后落库 `consent_records` 表（user_id=null 合规正常，注册后补绑） | ✅ |
| **注册登录** | `POST /api/auth/register` | `http_account.dart` 调后端，返回 JWT 自动持久化 + 调 `/api/billing/trial/start` 开 7 天试用 | ✅ |
| | `POST /api/auth/login` | 同上 | ✅ |
| | `GET /api/auth/me` | 启动恢复登录态时拉用户信息 | ✅ |
| | `POST /api/auth/logout` | 清 token | ✅ |
| **会员权益** | `GET /api/billing/entitlement` | `HttpReceiptVerifier.verifyRestore()` 拉权威 entitlement | ✅ |
| | `POST /api/billing/trial/start` | 首次注册/登录自动调，幂等 | ✅ |
| | `POST /api/billing/verify` | 调试模式 `X-Dev-Mock: 1` 跳过真实购买验真 | ✅ |
| **云存档** | `POST /api/cloud/saves/upload` | `CloudClient.uploadSave()` 客户端 AES-256-GCM 加密后 multipart/form-data（save_name + client_key + file） | ✅ |
| | `GET /api/cloud/saves/list` | `CloudClient.listSaves()` | ✅ |
| | `GET /api/cloud/saves/{id}` | `CloudClient.downloadSave()` 二进制流 + `X-Save-SHA256` header，下载后客户端解密落盘 | ✅ |
| | `DELETE /api/cloud/saves/{id}` | `CloudClient.deleteSave()` | ✅ |

### 关键设计决策

#### 1. 账号域统一后端入口：`effectiveBaseUrl()`

```dart
// account_backend.dart
const String kDefaultBackendUrl = 'https://api.gamepouch.cn';

Future<String> effectiveBaseUrl(AccountStore store) async {
  final raw = (await store.getString(kAccountBaseUrl))?.trim() ?? '';
  return raw.isEmpty ? kDefaultBackendUrl : raw;
}
```

**账号域** HTTP 客户端（`HttpAccountService` / `HttpReceiptVerifier` / `CloudClient` / `ConsentGate`）通过这个 helper 取后端地址，优先读用户调试入口填写的值，空则用公网默认。

> **例外（2026-11-04 公开内容解耦）**：`CloudConfigService`（`load()` 拉 AppConfig、`fetchDoc()` 拉 CMS 文档）**不经过** `effectiveBaseUrl`，而是硬走公网 `kDefaultBackendUrl = 'https://api.gamepouch.cn'`。原因：隐私政策 / 用户协议 / 备案号 / 客服信息等属**公开内容**，任何用户（含未登录）都应能打开；若跟随用户在「调试：账号后端」里填的私有地址（如 `127.0.0.1` / 局域网 IP），真机上会全部拉取失败并回退旧硬编码值。故公开内容与账号后端地址彻底解耦，`CloudConfigService` 也不再 import `openAccountStore` / `effectiveBaseUrl`。

#### 2. 统一登录态：`AccountStore` + `kAccountToken`

账号相关模块共享同一份 `AccountStore`（Android=SharedPreferences / OHOS=PlatformPal 文件存储），`kAccountToken` 是登录态唯一真相源。避免旧 `CloudConfig`（FlutterSecureStorage）平行状态导致 token 对其他模块不可见。`CloudConfigService` 只拉公开内容，不读写 `AccountStore`。

#### 3. CloudClient 重写：删除 PC 管理台 API

旧 `CloudClient` 有 11 个方法对接的是 **PC 管理台专用路由**（`/api/cloud/auth/*`、`/api/cloud/catalog`、`/api/cloud/sync/library` 等）——后端完全没有这些路由，调用必 404。新 `CloudClient` 删除全部旧方法，只保留：

- `uploadSave()` / `listSaves()` / `downloadSave()` / `deleteSave()` —— 云存档全链路
- `romExtForPlatform()` —— 遗留静态工具（peer_sync.dart 引用）

PC 管理台 catalog / subscriptions / cloud ROM 下载等功能已标记「即将上线」占位（独立服务尚未接入）。

#### 4. ConsentGate 设备标识

首次启动生成 UUID：`dev-{timestamp}-{random8}`，持久化在 `consent_device_id` 键。后端 `consent_records` 表存 `device_id_hash`（SHA-256），user_id 在用户注册后可选填——设计如此，不强制绑定。

#### 5. debug 联调入口

`AccountPage` 仅 debug 构建可见「调试：账号后端」卡片，可切换 `MockAccountService`（本地桩）↔ `HttpAccountService`（真实后端）、修改后端地址；地址输入框**默认值 = `kDefaultBackendUrl`**（`https://api.gamepouch.cn`，不再是 `127.0.0.1:8000`），留空保存也会由 `HttpAccountService._baseUrl` 回退到公网默认。打开「使用真实后端」后**始终**走 `HttpAccountService`，不再因地址为空坠回 Mock。发布版默认走真实后端公网地址。

### 本地启动后端（唯一正确姿势）

**必须手动双击** `D:\RetroEmuPouch\boot.bat`，Trae PowerShell 会 kill 子进程。

```
📁 D:\RetroEmuPouch\boot.bat   ← 双击启动（守护循环：每 30 秒检查 python + cloudflared，死了自动拉）
📁 D:\RetroEmuPouch\stop.bat   ← 双击停止（关闭 cmd 窗口也会停）
```

boot.bat 启动命令格式：
```batch
start "" /MIN python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --app-dir tools\account_backend
start "" /MIN cloudflared.exe tunnel --retries 9999 run --token <token> retroemupouch
```

> ⚠️ cloudflared 参数顺序铁律：`tunnel --retries N run --token XXX`（参数在 `tunnel` 和 `run` 之间），错了立刻崩溃。

### App 端文件变更清单（2026-11-03 → 2026-11-04）

| 文件 | 操作 | 说明 |
|---|---|---|
| `features/legal/cloud_config_service.dart` | **新增** | CMS 单例，从 `/api/cms/config` 拉 AppConfig |
| `features/legal/consent_gate.dart` | **重写** | 版本号感知：`GET /api/consent/status` + `POST /api/consent/accept` |
| `features/legal/privacy_policy_page.dart` | **修改** | 从后端拉 Markdown，fallback 硬编码模板 |
| `features/legal/eula_page.dart` | **修改** | 同上 |
| `features/settings/settings_sheet.dart` | **修改** | 10 处 `LegalConstants.xxx` → `CloudConfigService.instance.xxx` |
| `features/account/account_backend.dart` | **修改** | 新增 `kDefaultBackendUrl = 'https://api.gamepouch.cn'` + `effectiveBaseUrl()` helper |
| `main.dart` | **修改** | 启动时 `CloudConfigService.instance.load()`；runApp(ConsentGate(onAccept: ...)) |
| `data/cloud/cloud_client.dart` | **彻底重写** | 删全部旧方法（PC 管理台），新增云存档 4 个端点对接 |
| `data/cloud/cloud_sync.dart` | **精简壳** | 只保留 `CloudSyncer.extForPlatform`（peer_sync.dart 引用） |
| `features/cloud/cloud_actions.dart` | **stub** | `runCloudSync` 显示"即将上线" SnackBar |
| `features/cloud/cloud_library_page.dart` | **stub** | 占位页面"云文件库功能即将上线" |
| `features/cloud/cloud_crypto.dart` | **新增（2026-11-04 第二波）** | 客户端 AES-256-GCM 加解密（PBKDF2-HMAC-SHA256 15 万次派生密钥） |
| `features/cloud/cloud_save_section.dart` | **新增（2026-11-04 第二波）** | 账号页云存档 UI：会员门控 / 设密码 / 列表 / 上传 / 下载解密 / 删除 |
| `pubspec.yaml` | **修改（2026-11-04 第二波）** | 加 `cryptography` 依赖 |
| `features/legal/cloud_config_service.dart` | **修改（2026-11-04 第三波）** | `load()` / `fetchDoc()` 从 `effectiveBaseUrl(store)` 改为 `kDefaultBackendUrl`，公开内容硬走公网 |
| `features/legal/legal_constants.dart` | **修改（第三波）** | `privacyPolicyUrl` → `https://api.gamepouch.cn/privacy`；`feedbackEmail` → `support@retroemupouch.cn` |
| `features/legal/consent_gate.dart` | **修改（第三波）** | 内嵌 `MaterialApp` 加 `navigatorKey`，两个「查看」按钮改 `_navKey.currentState!.push()` 修复点击无响应 |
| `features/account/account_backend.dart` | **修改（第三波）** | 真实后端模式始终 `HttpAccountService`；`createAccountBackend()` 内 `svc.load()` 包 try/catch |
| `features/account/account_page.dart` | **修改（第三波）** | 新增 `_ready` 守卫修复首帧 `LateInitializationError` 红屏；调试入口地址默认 `kDefaultBackendUrl` |
| `features/account/http_account.dart` | **修改（第三波）** | `_baseUrl` 空值回退 `kDefaultBackendUrl` |
| `features/settings/settings_sheet.dart` | **修改（第三波）** | 「关于与支持」页展示云端配置（客服邮箱/反馈入口/隐私政策 URL/备案号/官方社群/同步状态），去掉硬编码 github.io 旧 URL；每次打开重拉 `load()` 并 `_changes.ping()` 刷新 |
| `tools/account_backend/app/services/seed.py` | **修改（第三波）** | AppConfig 默认项 8→10 条（新增 `privacy_policy_url` / `terms_url`），`feedback_email` 改正确域名 |

### 后端文件变更清单（2026-11-04 第四波：完整运营后台）

| 文件 | 变更 | 说明 |
|---|---|---|
| `app/models/admin.py` | 新增 | `AdminAuditLog` 审计日志表（与业务表解耦，用户删除后日志保留） |
| `app/models/user.py` | 修改 | 新增 `is_active`（`server_default=sa.true()`） |
| `app/services/schema_bootstrap.py` | 新增 | 启动时幂等补列/补表，老库免迁移平滑升级 |
| `app/services/admin_service.py` | 新增 | 统一分页、仪表盘统计、用户 CRUD、各类资源列表与审计 |
| `app/services/billing_service.py` | 修改 | 新增 public `set_entitlement()` / `set_trial()` / `entitlement_state()` / `TIER_CHOICES` |
| `app/admin_guard.py` | 新增 | UI 鉴权依赖、模板渲染入口、`NeedLogin` 异常 |
| `app/admin_ui.py`、`app/routers/admin_ui/{__init__,users,operations,content,_common}.py` | 重写/新增 | 仪表盘 + 用户/权益/云存档/配对/同意/流水/审计/CMS/Config 共 11 页 |
| `app/templates/admin/*` | 重写/新增 | `base.html`（统一导航）、`_macros.html`（分页/状态标签）与各业务页 |
| `app/routers/admin.py`、`app/schemas/admin.py` | 扩展/新增 | 完整 Admin JSON API 与请求 schema |
| `app/dependencies.py`、`app/main.py` | 修改 | 禁用账号校验、schema 自愈、统一登录重定向 |
| `alembic/versions/0002_admin_management.py` | 新增 | 幂等迁移：`users.is_active` + `admin_audit_logs` |
| `tests/test_admin_management.py` | 新增 | 44 项端到端自测（临时 SQLite，不碰真实库） |

### 端到端验证记录（2026-11-03/04，华为 OXF-AN10）

| 验证点 | 结果 | 证据 |
|---|---|---|
| App 启动 → ConsentGate 弹窗 | ✅ | 卸载重装后 SharedPreferences 清空，新 device_id，后端 `needs_reconsent=true` |
| 点击「同意并继续」→ 进主页 | ✅ | `consent_records` 表落库（eula + privacy_policy） |
| CMS 动态配置拉取 | ✅ | `CloudConfigService.load()` 成功覆盖 `LegalConstants`（当时 8 条，现行 seed 默认 10 条） |
| 切换真实后端 → 注册 | ✅ | 后端返回 JWT，自动持久化 |
| 注册自动开启 7 天试用 | ✅ | `trial_start` 写入 SQLite，`is_ad_free=true, blocks_interstitial_ads=true` |
| 付费档升级 → entitlement | ✅ | `cloud_save_enabled=true`，云存档端点 403→200 |
| 云存档 upload | ✅ | multipart/form-data → 后端落库 cloud_save_blobs |
| 云存档 list | ✅ | JSON 数组返回，含 sha256 / size_bytes |
| 云存档 download | ✅ | 二进制流 + X-Save-SHA256 header，原始字节落文件 |
| 云存档 delete | ✅ | 后端删除 blob 记录 |
| 合规防线：免费用户不能上传云存档 | ✅ | 403 Forbidden |
| 合规防线：非会员云存档端点 403 | ✅ | `require_cloud_save_entitlement` 依赖守卫 |
| 云存档上传（客户端加密） | ✅ | `CloudCrypto.encrypt` 后上传，后端只存密文 `encrypted_blob` |
| 云存档下载（客户端解密） | ✅ | `CloudCrypto.decrypt` 还原明文落盘（密码错误 GCM tag 校验失败抛异常） |
| Admin Web UI 登录/鉴权 | ✅ | TestClient 端到端：未授权 303→登录 / 错误口令 401 / 登录设 cookie / 已授权控制台 / 草稿创建并出现在列表 |
| Alembic 初始迁移 | ✅ | 临时 SQLite `alembic upgrade head` 建全 9 张表（含 `alembic_version`） |
| 欢迎页「查看隐私政策」可正常导航（第三波） | ✅ | 真机 `uitest` 模拟点击 → 页面打开并显示 CMS 下发的真实政策全文（非占位模板）；`navigatorKey` 修复生效 |
| 公开配置 `/api/cms/config` 下发 10 条（第三波） | ✅ | 后台补 `privacy_policy_url` / `terms_url` 后，接口返回两键；`feedback_email=chihinglau@163.com` 为后台实改值 |
| 「关于与支持」展示云端配置并可刷新（第三波） | ✅ | 真机页面显示客服邮箱 `chihinglau@163.com`、隐私政策 `https://api.gamepouch.cn/privacy`、官方社群，底部「以上资料已与云端配置同步」 |
| 账号页首帧不再红屏（第三波） | ✅ | 重启后 hilog 无 `LateInitializationError`；`_ready` 守卫生效 |
| seed 默认项计数 | ✅ | `seed_app_configs` 现为 10 条默认 AppConfig |
| 运营后台 11 个页面渲染（第四波） | ✅ | `python tests/test_admin_management.py`：全部页面 200 且含预期标题 |
| 用户管理全链路（第四波） | ✅ | 编辑资料 / 禁用后已签发 JWT 403 / 解禁 / 重置密码 / 级联删除，均通过 |
| 权益管理全链路（第四波） | ✅ | 授予月档 30 天、终身档、撤销回 free、开启与清除试用，均通过；`cloud_save_enabled` 随档位变化 |
| Admin JSON API（第四波） | ✅ | stats / users / entitlement PUT / 各列表端点均 200，分页结构一致 |
| 审计留痕与迁移（第四波） | ✅ | `admin_audit_logs` 覆盖 user.update / entitlement.set / cms.publish / config.update / cloud_save.delete；`alembic 0002` 与运行时自愈幂等 |
| 自测总计 | ✅ | **44 项全部通过**，`python -m compileall -q app` 退出码 0 |
