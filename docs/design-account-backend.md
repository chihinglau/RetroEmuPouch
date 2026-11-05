# 设计方案：账号云服务后台 Web 服务

> 本文档为**方案文档，不含任何代码实现**。
> 约束前提：本后端为 `RetroEmuPouch` App 提供账号/配对/会员/云存档/**内容管理（隐私政策等）**能力，**绝不触碰 ROM / BIOS 二进制分发**。

## 文档信息

| 项 | 值 |
|---|---|
| 版本 | v0.3（线上 staging 运行中 + 云存档产品化） |
| 日期 | 2026-11-05 |
| 范围 | 技术栈、数据模型、API、CMS/隐私内容管理、部署、分阶段交付、运维双轨 |
| 依赖 | `docs/design-account-cloud-ads-membership.md`（总方案）；客户端 `ReceiptVerifier` / `BillingService` / `AccountService` / `LegalConstants` / `ConsentGate` 骨架 |
| 状态 | **已上线（备案前 staging）**：ECS `112.74.114.146` 纯 HTTP + Caddy，`smoke` 38/38 |

---

## 当前状态快照（2026-11-05）

| 维度 | 现状 |
|---|---|
| 线上环境 | 阿里云 ECS `112.74.114.146`（Ubuntu 24.04，Docker Compose：app + db + caddy），`http://<IP>/healthz` = 200，`smoke.sh` PASS=38 FAIL=0 |
| 备案 | 阿里云订单 `2036873543813`（首次备案），处于**第 4 步「工信部短信核验」**（24h 内用手机流量打开 12381 短信链接）；后续为管局审核 |
| HTTPS | 安全组已放行 80/443；443 当前 `RST` 属预期（远端仍是 `Caddyfile.staging`，只有 `:80` 站点，Caddy 未在 443 提供 TLS）。备案下号后 `deploy.ps1 -Action deploy -Domain <域名>` 自动签发证书 |
| 运维 | cron：`03:15 backup-db.sh` / `*/10 healthcheck.sh` / 周日 `04:30 docker system prune`；compose 日志轮转 10m×3；备份恢复演练通过（9 表行数一致） |
| 开发/发布双轨 | 本地 `scripts/dev.ps1`（Postgres 同构，无 Docker 自动退化 SQLite）+ 云端 `deploy.ps1 -Action update`（只换代码，不碰 Caddy/compose）；三条红线见「本地 / 云端双轨维护」 |
| 云存档 | 契约对齐 + `client_key` 覆盖语义；真实存档同步（电池/自动/手动槽 + 缩略图）**上传 / 恢复 / 冲突决策**三件事全部完成；库设置备份走独立 `library-backup` key |
| 测试基线 | Flutter `flutter test`=56 全绿、`flutter analyze` 无新增告警；后端 `tests/test_cloud_saves.py`=39、`tests/test_admin_management.py`=44 全绿；Dart 云存档层 20 项单测 + 一次真实后端端到端（上传→清空→恢复逐字节一致） |
| 未完成 | Phase 5 真实收据校验（Google/华为凭证）、备案下号切 HTTPS、自动同步开关（启动检查/退出上传）、OHOS Asset Store Kit 替换明文密码兜底 |

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
| 2026-11-05 | 实施者 | 运维收尾 + 云存档产品化 + 双轨定稿 | ① J3 探活/日志轮转/prune、J2b 备份恢复演练落地；② 云存档契约对齐（错误体 `detail`、网络异常收敛、`X-Save-SHA256` 校验）并把 `client_key` 改成覆盖语义；③ 新增真实存档同步层（上传/恢复/冲突决策）；④ 本地开发与云端生产双轨流程（`dev.ps1`、`update` 不再覆盖 Caddyfile、三条红线）。事故：`-Action update` 曾把 prod Caddyfile 覆盖到远端导致整站 308，已修并回归 |
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

### 方式 A：一键脚本（推荐）

```powershell
cd tools\account_backend
pip install -r requirements.txt      # 只第一次
./scripts/dev.ps1                    # 自动选库：有 Docker→Postgres（与云端同构），否则 SQLite
```

脚本会做完：检查依赖 → 起本地 Postgres 容器（或退化为 SQLite）→ 跑 `alembic upgrade head` →
打印 `http://<局域网IP>:8000` 供 App 填写 → 启动 `uvicorn --reload`。

常用变体：

| 场景 | 命令 |
|---|---|
| 强制与云端同构的 Postgres（推荐） | `./scripts/dev.ps1 -Db postgres` |
| 无 Docker 时的快速调试 | `./scripts/dev.ps1 -Db sqlite` |
| 只准备库 + 迁移，不起服务 | `./scripts/dev.ps1 -MigrateOnly` |
| 换端口 | `./scripts/dev.ps1 -Port 8001` |

> `-Db postgres` 需要先在 `.env.local` 里设 `DB_PASSWORD`（脚本首次会从模板生成）。

**手动等价命令**（脚本坏掉时的退路）：

```powershell
cd tools\account_backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload   # SQLite 由 main.py create_all 兜底
```

**首次 Seed 初始化**（10 条 AppConfig + 4 篇 CMS 文档）：

```powershell
# 1. 生成 admin token（PowerShell）
$tok = python -c "from app.security import create_admin_token; print(create_admin_token('root'))"

# 2. 调用 seed 端点
Invoke-RestMethod -Method Post -Uri http://localhost:8000/admin/seed -Headers @{Authorization="Bearer $tok"}
# 返回: { "app_configs_seeded": 10, "cms_docs_seeded": 4 }
```

### 方式 B：Docker Compose 整栈（本地生产级）

```powershell
cd tools\account_backend
copy .env.local.example .env.local   # 改 DB_PASSWORD / JWT_SECRET 等
docker compose -f docker-compose.local.yml up -d --build
docker compose -f docker-compose.local.yml exec -T app alembic upgrade head
# 然后同上 seed
```

`docker-compose.local.yml` 的 `db` 只绑 `127.0.0.1:5432`（供宿主机 uvicorn / alembic / 测试脚本连），
不对局域网暴露数据库；数据目录在 `D:\RetroEmuPouch\backend\postgres-data`。
迁移脚本仓库里已有（`alembic/versions/0001_initial.py`、`0002_admin_management.py`），
**不要**再 `alembic revision --autogenerate` 造第二份 initial。

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
| 一键起本地开发环境 | `./scripts/dev.ps1 -Db postgres` |
| 本地端到端冒烟 | `bash scripts/smoke.sh http://127.0.0.1` |
| 后端自测 | `python tests/test_cloud_saves.py`、`python tests/test_admin_management.py` |
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

## 本地 / 云端双轨维护（2026-11-05 定稿）

**定位**：本地是唯一开发/调试环境，云端是唯一对外生产环境；两者代码同源、数据隔离，
「本地改 → 本地测通 → 部署云端 → 云端再验」是唯一上线路径。不搞灰度双写，也不允许
本地直连生产库。

### 三条红线

1. **库不互连、不双写。** 本地（SQLite 或本地 Postgres）与云端 Postgres 之间没有任何
   连接配置。要复现线上问题，用远端 `pg_dump` 拉一份副本到本地（涉及用户数据先脱敏），
   绝不反向回写。用完即删。
2. **schema 只走 alembic。** 改模型 = 同时写 `alembic/versions/xxxx.py`。
   本地 `alembic upgrade head` 验证 → 部署时 `deploy.ps1` 已在远端执行 `alembic upgrade head`。
   `create_all`（仅非 prod）与 `schema_bootstrap`（幂等补列）只是兜底，不能当作迁移来源。
3. **本地默认 Postgres。** SQLite 仅在没有 Docker 时降级使用，涉及 schema/约束/时区的改动
   必须在 Postgres 上再跑一遍（`scripts/dev.ps1 -Db postgres`）。

### 环境对照

| 维度 | 本地开发 | 云端生产 |
|---|---|---|
| 入口 | `scripts/dev.ps1` | `scripts/deploy.ps1 -Action deploy\|update` |
| compose | `docker-compose.local.yml`（或裸 uvicorn） | `docker-compose.prod.yml` |
| 环境变量 | `.env`（dev 值）+ `.env.local`（本地 compose 用） | `.env.production`（仅存在于 ECS） |
| 数据库 | SQLite（降级）或本地 Postgres:16 | 云端 Postgres:16（容器 `db`，不对外暴露端口） |
| 反向代理 | 无（直连 8000） | Caddy（`Caddyfile.staging` 纯 HTTP / `Caddyfile.prod` 自动 HTTPS） |
| 数据目录 | `D:\RetroEmuPouch\backend\{sqlite,postgres-data,logs,backups}` | ECS `/opt/retroemupouch-account` + 容器卷 |
| 备份 | 无需 | `backup-db.sh`（cron 03:15）+ `migrate-db.sh --restore-drill` 演练 |
| 探活 | 手动 `curl /healthz` | `healthcheck.sh`（cron 每 10 分钟，失败写 `/var/log/gp-health.log`） |
| 冒烟 | `bash scripts/smoke.sh http://127.0.0.1` | `ssh … 'cd /opt/retroemupouch-account && scripts/smoke.sh http://127.0.0.1'` |
| 客户端地址 | `http://<PC局域网IP>:8000`（debug/community 才允许明文） | `https://api.<域名>`（store 渠道唯一允许的形态） |

### 日常循环

```powershell
# ① 本地起服务（自动选库 + 迁移 + 局域网地址提示）
cd tools\account_backend; ./scripts/dev.ps1 -Db postgres

# ② 改代码后跑自测（后端两个脚本 + 客户端 Dart 测试）
python tests/test_cloud_saves.py
python tests/test_admin_management.py
cd ..\..\app; flutter analyze; flutter test

# ③ 本地端到端冒烟（PASS=38 才算过）
cd ..\tools\account_backend; bash scripts/smoke.sh http://127.0.0.1

# ④ 真机联调（可选，App 里把后端地址改成 http://<PC局域网IP>:8000）
```

发布：

```powershell
$env:ECS_HOST="112.74.114.146"; $env:ECS_USER="root"; $env:ECS_SSH_KEY="C:\Users\<你>\.ssh\id_ecs99"
./scripts/deploy.ps1 -Action update                  # 只换 app 代码 + alembic upgrade（Caddy/compose/库都不动）
./scripts/deploy.ps1 -Action deploy -Staging         # 动了 compose/Caddyfile/环境变量时用（备案前必须带 -Staging）
# 远端回归
ssh … 'cd /opt/retroemupouch-account && scripts/smoke.sh http://127.0.0.1 | tail -3'
```

> ⚠️ 2026-11-05 踩坑：`-Action update` 原本会顺手把本地 `Caddyfile.prod`（HTTPS + 自动 ACME）
> 覆盖到远端，把备案前的 staging 纯 HTTP 站点切成整站 308 → 线上不可用。
> 现已改为 update **不碰** Caddyfile/compose；Caddy 配置只由 `deploy`（带 `-Staging`/`-Domain`）切换。

### 发布门禁（缺一不部署）

- [ ] `python tests/test_cloud_saves.py` = ALL GREEN
- [ ] `python tests/test_admin_management.py` = 44/44
- [ ] `flutter analyze` 无新增 error/warning；相关 `flutter test` 全绿
- [ ] 本地 `scripts/smoke.sh` PASS=38 FAIL=0
- [ ] 模型改动已配套 alembic revision，且本地 `alembic upgrade head` 通过
- [ ] 若改了环境变量/端口/compose，`deploy.ps1 -Action deploy` 且远端 `/healthz` = 200

### 回滚

1. 代码：`git revert`/回退到上一个 commit 后 `deploy.ps1 -Action update`（镜像重建，库不动）。
2. 数据：`/opt/backups/gp-*.sql.gz`（每日 03:15）。**先演练**再真恢复：
   `scripts/migrate-db.sh --restore-drill`（恢复到临时库 `gp_migrate_test` 并逐表比行数），
   确认无误后 `--apply`，最后 `--cleanup`。
3. 部署后异常：`deploy.ps1 -Action logs -Service app|caddy`；`/var/log/gp-health.log` 看探活记录。

### 已知限制

- 本机（Windows，2026-11-05）**没有安装 Docker**，`scripts/dev.ps1` 会自动降级 SQLite 并打警告；
  Postgres 同构路径需要在装有 Docker Desktop 的机器上验证。
- store 渠道 release 包只允许 HTTPS；本地明文联调必须用 debug 或 `--dart-define=CHANNEL=community`
  （`SecurityPolicy` 只对 loopback 与 RFC1918 私网放行明文）。
- 云端当前是备案前的 `-Staging` 纯 HTTP IP 直连；备案下号后切 DNS + 去掉 `-Staging` 即可上自动 HTTPS。

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
├── Caddyfile.prod               ← Caddy 反向代理 + 自动 HTTPS + 安全头
├── Caddyfile.staging            ← 备案前临时配置：`:80` 纯 HTTP、无域名站点（不触发 ACME）
├── .env.production.example      ← 生产环境变量模板（密码/JWT/数据库）
├── .dockerignore                ← Docker 构建时排除无关文件
└── scripts/
    ├── deploy.ps1               ← ⭐ 一键部署（6 个动作：setup/deploy/seed/logs/stop/update）
    ├── setup-ecs.sh             ← ECS 初始化（Docker CE + 镜像加速 + ufw）
    ├── backup-db.sh             ← 每日 pg_dump（setup 时装进 root crontab，保留 7 天）
    ├── smoke.sh                 ← H2/H3 回归（公开端点 + 账号/权益/配对 + 后台 11 页，自清理）
    ├── healthcheck.sh           ← 探活（cron 每 10 分钟，失败才写 /var/log/gp-health.log）
    ├── migrate_sqlite.py        ← G 阶段：本地 SQLite → 可审阅 SQL（inspect / dump）
    ├── migrate-db.sh            ← G 阶段：临时库试跑 / --apply 正式导入（先快照）/ --restore-drill / 清理
    └── db-init/
        └── 01-extensions.sql    ← PostgreSQL 首次启动时启用 pgcrypto（必须是纯 SQL）
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
# 有域名且已备案、DNS 已指向 ECS 公网 IP：
$env:ECS_DOMAIN = "gamepouch.cn"          # 只传主域，脚本内部拼成 api.gamepouch.cn
.\scripts\deploy.ps1 -Action deploy -Domain "gamepouch.cn"

# 没域名 / 域名未备案（推荐：加 -Staging，纯 HTTP + IP 直连）：
.\scripts\deploy.ps1 -Action deploy -Staging
# 脚本会把 Caddyfile.staging 上传为远程的 Caddyfile.prod（compose 挂载路径不变），
# Caddy 只监听 :80、站点块不含域名 → 不触发自动 HTTPS，也绕开未备案域名拦截。
# 备案通过后去掉 -Staging 再跑一次 deploy 即可切回 api.<domain> 自动证书。

# ══════════════════════════════════════════════════
# Step 5: Seed 初始化（首次启动必须跑）
# ══════════════════════════════════════════════════
.\scripts\deploy.ps1 -Action seed
# 返回：{ app_configs_seeded: 10, cms_docs_seeded: 4 }
```

### 部署完成验证

| 检查项 | 验证方式 |
|---|---|
| 备案前（Staging） | `curl http://<ECS公网IP>/healthz` → `{"ok":true,"env":"prod"}`；安全组需放行 TCP 80 |
| 后端健康 | `curl https://api.yourdomain.com/healthz` → `{"ok":true,"env":"prod"}` |
| API 文档 | 浏览器打开 `https://api.yourdomain.com/docs` → Swagger UI |
| HTTPS 证书 | 浏览器地址栏 🔒 绿色锁 |
| 数据库迁移 | `./deploy.ps1 -Action logs app` 看日志无 Alembic 错误 |
| Seed 数据 | `curl https://api.yourdomain.com/api/cms/config` → 10 条 AppConfig |
| App 端联调 | 手机打开 RetroEmuPouch → 设置 → 后端地址填 `https://api.yourdomain.com`（备案前填 `http://<ECS公网IP>`）→ 开「使用真实后端」 |

> **备案前用 IP + HTTP 联调 App 时必须用 `community` flavour**：`main`（store）flavour 的
> `network_security_config.xml` 全局 `cleartextTrafficPermitted="false"`，只放行 127.0.0.1/localhost/::1，
> 明文打公网 IP 会被系统拦断（`Cleartext HTTP traffic not permitted`）；`community` flavour 允许明文。
> 鸿蒙侧无 ATS 限制，`module.json5` 已声明 `ohos.permission.INTERNET`，可直接填 `http://<IP>`。

### 日常运维命令

```powershell
# 查看服务状态
.\scripts\deploy.ps1 -Action logs db      # 数据库日志
.\scripts\deploy.ps1 -Action logs app     # 后端日志

# 快速更新（改了 Python 代码后）
.\scripts\deploy.ps1 -Action update -Staging   # 只重建 app 容器，DB 不动

# 完整重部署（改了 docker-compose / Caddyfile）
.\scripts\deploy.ps1 -Action deploy -Staging

# 回归冒烟（在 ECS 上跑，38 项断言 + 后台 11 页，自动清理测试数据）
ssh root@<ECS_IP> /opt/retroemupouch-account/scripts/smoke.sh http://127.0.0.1

# 立即备份一次（日常由 cron 03:15 自动跑）
ssh root@<ECS_IP> /opt/retroemupouch-account/scripts/backup-db.sh

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

# 3. 生产密钥 + 上传 + 启动（域名未备案时加 -Staging）
.\scripts\deploy.ps1 -Action deploy -Staging

# 4. Seed 初始化 CMS
.\scripts\deploy.ps1 -Action seed

# 5. 访问测试（Caddy 映射 80/443，宿主机不暴露 8000）
# curl http://你的公网IP/healthz
# 浏览器打开 http://你的公网IP/docs
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
| `POST /api/cloud/saves/upload` | ✅ | multipart：save_name(Form) + client_key(Form) + file(File)；**同一 user+client_key 覆盖原 blob（id 不变）** |
| `GET /api/cloud/saves/list` | ✅ | 元信息数组，按 `updated_at DESC` |
| `GET /api/cloud/saves/{blob_id}` | ✅ | 返回二进制 + X-Save-SHA256 header（客户端据此校验密文） |
| `DELETE /api/cloud/saves/{blob_id}` | ✅ | |

> 客户端契约对齐（2026-11-05）：`CloudClient.errorOf()` 同时解析 `{"detail":...}`（FastAPI）
> 与 `{"error":...}`（旧接口）并翻译已知错误码；网络异常统一转 `CloudException`；
> multipart 首段不再带前导 CRLF、boundary 去前导 `--`；下载校验 `X-Save-SHA256`，
> 解密失败提示"密码不正确或文件损坏"。库备份固定用 `clientKey=library-backup`，
> 重复备份只更新同一份云端 blob。
> 回归脚本：`python tests/test_cloud_saves.py`（39 项，临时 SQLite）+ Dart
> `test/data/cloud/cloud_client_error_test.dart`（7 项）；另做过一次「Dart 原始
> multipart 帧 → 真实 FastAPI 路由回放」验证（200、字段解析一致、密文字节一致）。

#### 真实游戏存档同步层（2026-11-05 新增）

`app/lib/data/cloud/cloud_save_sync.dart` 把「库设置备份」升级到「真实存档」，
本地布局与 `EmulatorActivity` / `peer_server` 一致（`<filesDir>/saves/`）：

| 类型 | 本地文件 | 云端 `save_name` | `client_key` |
|---|---|---|---|
| 电池存档 | `<CRC>.sav` | `<CRC>.sav` | `gp-save:<CRC>:battery` |
| 自动存档 | `<CRC>.state` | `<CRC>.state` | `gp-save:<CRC>:auto` |
| 手动槽位 | `<CRC>.slotN.state` | `<CRC>.slotN.state` | `gp-save:<CRC>:slot:N` |
| 槽位缩略图 | `<CRC>.slotN.jpg` | `<CRC>.slotN.thumb.dat` | `gp-save:<CRC>:slot:N:thumb` |

- 缩略图用 `.dat` 承载 JPEG 字节，因为后端扩展名白名单不含 `.jpg`（服务端不解析内容）。
- `client_key` 稳定 → 同一槽位反复上传只覆盖一份 blob；`save_name` 与本地同名，
  恢复时直接写回 `saves/`。
- 空 `.sav`（核心初始化的 0 字节产物）、`.preplay`、街机 `<driver>.nv/.fs`
  暂不纳管（后两者不在白名单内，待放开）。
- `scanLocal` → `listCloud` → `diff`（localOnly / localNewer / inSync / cloudOnly）
  供 UI 显示「未同步 N 份」，其中 `localNewer` 的判定是
  `本地 mtime > 云端 updated_at + 3s`（云端只有上传时间，没有原始 mtime）。

**恢复链路（2026-11-05 同日完成）**

- `restore({items})`：`items` 为空即恢复云端全部；同一槽位存在多份（不同
  `client_key`/旧设备）时只取 `updated_at` 最新的一份。
- 落地流程：`downloadSave` → 临时文件 `<目标>.part` → 校验非空 →
  若本地已有旧档先 `copy` 成 `<目标>.bak-<毫秒时间戳>` → `rename` 原子替换。
  下载或解密失败只清理 `.part`，**本地原档保持不变**（错误的云存档密码不会毁档）。
- 槽位缩略图（`*.thumb.dat`）随本体一起恢复成 `<CRC>.slotN.jpg`。
- UI：账号页「云存档 → 游戏存档」列出「云端有 N 份本机没有的存档」，
  支持逐条恢复与「全部恢复」，恢复成功后自动重扫并刷新状态。
**冲突策略（2026-11-05 同日完成）**

- `diff` 改为四态：`localOnly`（未上传）/ `localNewer`（上传后本地又改）/ 
  `remoteNewer`（别的设备上传过，云端新）/ `inSync`，另有 `cloudOnly`（本机没有）。
  判定用时间戳，**容差 30s**（吸收上传耗时与设备/服务器时钟漂移；代价是同步后
  30 秒内的修改会先显示为已同步）。
- 恢复落盘后把文件 mtime 对齐云端 `updated_at`，否则刚下载的文件会因为“比云端新”
  立刻又被判成 `localNewer`（假冲突）。
- UI：`localNewer` / `localOnly` → 行尾「上传」（覆盖云端旧版）；
  `remoteNewer` → 行尾「用云端覆盖本机」（自动 `.bak`）；
  顶部批量按钮分别是「恢复云端较新的 N 份」与「上传本地较新的 M 份」，并明示
  「上传会覆盖云端旧版本；恢复会覆盖本机且自动备份」。
**自动同步开关（2026-11-05）**

- 新增 `CloudSaveService`（`data/cloud/cloud_save_service.dart`）：把「账号存储 + 密码读取
  （安全存储 → 鸿蒙文件兜底）+ 会员校验 + 差异刷新 + 上传未同步」从账号页 widget 抽出，
  供 UI 与后台钩子共用同一套逻辑。
- 两个 **opt-in** 开关（默认关闭，设置页「个性化设置 → 云存档」）：
  - `autoCheckSavesOnLaunch`：首帧之后后台比对一次，若 `pendingDownload > 0` 则在**游戏库顶部**
    显示「云端有 N 份存档可恢复」横幅，点击进入账号页；
  - `autoUploadSavesOnExit`：从模拟器返回游戏库时自动上传「未上传 / 本地较新」的存档，
    成功弹 3 秒提示，失败只写日志，不影响返回主界面。
- 三重门控：未登录 / 非会员 / 未设置云存档密码 → `syncIfReady()` 返回 null，钩子静默跳过。
- 回归：Dart `test/data/cloud/cloud_save_sync_test.dart` **20 项**（命名互逆、
  噪声过滤、diff 五态、覆盖上传、单条失败不中断、恢复逐字节一致、
  覆盖前 `.bak`、下载失败不破坏本地、多份取最新、`includeThumbs=false`、
  三种冲突决策后 `diff.isClean`）；
  后端 `tests/test_cloud_saves.py` 第 8 组（4 种命名与 `.dat` 缩略图均 200）。
  另做了一次真实端到端：本地 uvicorn(:8000, dev SQLite) + 真实 AES-256-GCM，
  上传 3 份存档+1 缩略图 → 清空本机 → 恢复 → 逐字节一致；错误密码不覆盖本地；
  测试后清理云端 blob 与临时账号。

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

---

## 阿里云 ECS 99 购买及部署任务清单（2026-11-04）

> **状态：计划已落文档，尚未执行。按编号逐项推进，完成后把 `- [ ]` 改成 `- [x]`。**
> 负责人标记：`用户` = 需账号/实名/付款/控制台操作；`助手` = 代码/脚本/验证；`共同` = 联调验收。

### 0. 决策、费用与硬约束

**决策**：放弃「本地 PC + Cloudflare Tunnel」作为线上主链路（国内偶发 502 / 需多次刷新），改用**阿里云 ECS 99 计划 + Docker Compose（PostgreSQL + FastAPI + Caddy）**。原穿透链路保留为回滚兜底。

| 项 | 费用 | 说明 |
|---|---|---|
| ECS 99 计划 | **99 元/年** | 2 核 2G / 3M 固定带宽 / 40G ESSD Entry / 不限流量；活动页标注续费同价、新老同享，**以下单页实际条款为准** |
| 域名 `gamepouch.cn` | 已有，按实际续费价 | 华为云注册，DNS 托管在 Cloudflare |
| HTTPS 证书 | 0 | Caddy 自动申请/续期 Let's Encrypt |
| ICP 备案 | 0 | 阿里云免费；条件 = ECS 位于**中国大陆节点** + 包年包月 ≥3 个月 + 有公网带宽（99 计划 1 年 + 3M 固定带宽，均符合） |
| **合计** | **≈ 99 元/年 + 域名续费** | 对比 cpolar 付费版 ¥120/年 + 本地 PC 常开电费 |

**硬约束（决定后续所有步骤）**：

1. **App 不用发版**：`CloudConfigService` 的 `kDefaultBackendUrl = 'https://api.gamepouch.cn'` 固定，只要把 `api.gamepouch.cn` 的 DNS 从 Cloudflare Tunnel CNAME 切到 ECS 公网 IP，客户端无感。这是本次必须沿用同域名的原因。
2. **备案前大陆 ECS 不能用域名开 80/443**：备案审核期（阿里云初审 1~2 工作日 + 管局审核 20 工作日内）走「双轨」——线上继续由 Cloudflare Tunnel 提供，ECS 用 `公网 IP + 非标端口` 联调；备案通过后再切 DNS。
3. **切 DNS 必须关 Cloudflare 代理**（灰云 / DNS only），只改 A 记录不改代理状态，流量仍绕 Cloudflare 边缘，国内不稳定的老问题不会解决。
4. **镜像推荐 `Ubuntu 24.04 LTS 64位`**（22.04 / 26.04 LTS 亦可用）：`scripts/setup-ecs.sh` 用 `apt-get` / `ufw`，Alibaba Cloud Linux、CentOS、Anolis 等 RPM 系会直接失败。版本依据：22.04 标准支持到 **2027-04**（本台 1 年期 ECS 的后半段会失去常规安全更新，需另开 Ubuntu Pro ESM）、24.04 到 **2029**、26.04 LTS 到 **2031-05**；Docker CE 官方源在 2026-11 已同时支持 24.04 / 26.04（Engine 29.x + Compose v5），所以「26.04 太新装不了 Docker」的说法已不成立。业务全部跑在容器里（`python:3.12-slim` / `postgres:16-alpine` / `caddy:2-alpine`），宿主机只提供内核与 Docker，发行版版本对业务代码几乎无影响，因此按「标准支持覆盖服务器寿命 + 线上验证年限」选 **24.04** 最稳。（本文前半部分关于华为云等方案的历史章节仍写 22.04，属当时记录，本次 ECS 99 部署一律以 24.04 为准。）
5. **地域只要是「中国大陆节点」即可，深圳可以选**：华南 1（深圳）、华东 1（杭州）、华北 2（北京）、华东 2（上海）、华北 3（张家口）、西南 1（成都）等都满足备案要求；**ECS 地域与备案归属管局无关**（管局按备案主体证件所在地划分），地域只影响网络延迟。地域开通后不能直接变更，跨地域要靠自定义镜像 + 快照迁移重开实例，因此**购买时一次定好**：用户主要在华南就选深圳，主要在华东/华北就选杭州/北京。
6. **2 核 2G / 3M 带宽**：约 384 KB/s，够账号 API、CMS、隐私页、几十 KB 的 `.sav` 云存档；**不适合分发 ROM / APK / 大图**。三容器（PostgreSQL + gunicorn + Caddy）内存吃紧，必须加 swap 并降 worker 数。
7. **只放通 22 / 80 / 443**：8000（app）、5432（db）绝不暴露公网，compose 已用 `internal: true` 网络隔离 db。

**迁移策略**：`双轨并行 → 数据迁移 → 全量验证 → DNS 切换 → 观察 7 天 → 停 Tunnel`。

```
[现在]  App ──https://api.gamepouch.cn──> Cloudflare ──> cloudflared(本地PC) ──> SQLite dev.db
[过渡]  App ──https://api.gamepouch.cn──> Cloudflare ──> cloudflared(本地PC) ──> SQLite   ← 线上不动
        验证 ──http://<ECS_IP>─────────────────────────> Caddy/ECS ──> PostgreSQL    ← 并行联调
[切换]  App ──https://api.gamepouch.cn──> DNS A(灰云) ──> Caddy/ECS ──> PostgreSQL
[兜底]  cloudflared 保持运行 7 天，异常时把 DNS 改回 CNAME 即回滚
```

### 1. 上线前阻塞项（已核对代码，必须在 Phase C 修完）

| # | 文件 | 问题 | 后果 | 修复方式 |
|---|---|---|---|---|
| P0-1 | `Dockerfile.prod:44` / `requirements.txt` | CMD 用 `gunicorn`，但依赖里没有 gunicorn | 容器启动即 `executable file not found`，服务起不来 | `requirements.txt` 加 `gunicorn==22.0.0`，或 CMD 改 `uvicorn app.main:app --workers 1`（推荐前者，配合降 worker） |
| P0-2 | `docker-compose.prod.yml:42` / `.env.production.example:8` / `config.py:52` / `main.py:32` / `billing_service.py:175` | 全链路写 `APP_ENV=production`，但代码判 `== "prod"`；且 compose 的 `environment` 会**覆盖** env_file | 生产仍执行 `create_all`（与 Alembic 冲突）、`is_prod=False` 使 dev mock 收据验真被放行，属合规风险 | 统一为 `APP_ENV=prod`（compose + example 同时改）；或把 `config.is_prod` 改成 `in ("prod","production")`，**二选一，不要两边都改** |
| P0-3 | `Caddyfile.prod:36,40,10-13,22-33` | `client_max_body_size 10M` 是 nginx 指令；`log output file /data/logs/access.log` 目录不存在；`reverse_proxy` 内 `timeout/keepalive` 写法待校验；CORS 头与 FastAPI `CORSMiddleware` 重复 | Caddy 配置校验失败 → 443 不通 | 删除 `client_max_body_size`（或改 Caddy v2 `request_body { max_size 10MB }`）；日志改 `output stdout`；CORS 头全删交给后端；上线前跑 `caddy validate` |
| P0-4 | `.gitignore` / `.env.production.example:4` | 模板声称「已在 .gitignore 中」，实际 `.gitignore` 只有 `.env`，**`.env.production` 未被忽略**（`git check-ignore` 无输出） | 一旦生成真实 secrets，极易误提交到 GitHub | `.gitignore` 增加 `.env.production`、`.env.production.*`，并 `git check-ignore -v` 验证 |
| P0-5 | `.env.production.example` / `config.py:28` | 模板**没有 `ADMIN_WEB_PASSWORD`**，默认口令 `admin` | 运营后台 `/admin/ui/login` 弱口令裸奔 | 模板补 `ADMIN_WEB_PASSWORD=CHANGE_ME...`，部署时必填强口令 |
| P0-6 | `deploy.ps1:119-122`（`seed` 分支） | 在 ECS 宿主机上 `curl http://localhost:8000/admin/seed`，但 compose 未映射 app 端口 | seed 必然失败，CMS/AppConfig 为空 | 改为容器内调用：`docker compose exec -T app python -c "import httpx; ...post('http://localhost:8000/admin/seed'...)"` |
| P0-7 | `deploy.ps1:80-84` / `docker-compose.prod.yml:21` | `scripts/db-init/` 被 scp 到 `/opt/retroemupouch-account/db-init/`，而 compose 挂载 `./scripts/db-init` | `01-extensions.sql` 不执行，`pgcrypto` 扩展缺失 | 远程先 `mkdir -p .../scripts`，scp 目标改 `.../scripts/`，或直接把初始化 SQL 打进镜像/启动命令 |
| P0-8 | `deploy.ps1` | `deploy` 分支不跑 `setup-ecs.sh`、不自动 seed；`alembic upgrade head` 用 `exec`（非 `-T`）在非交互 SSH 下易挂；`setup` 用 `get.docker.com` 国内易超时 | 首次部署链路断裂 | 部署顺序显式化为 `setup → deploy → seed`；`exec -T`；Docker 换阿里云镜像源 |
| P1-1 | `docker-compose.prod.yml` / `Dockerfile.prod` | 2 核 2G 跑 PostgreSQL + gunicorn 2 workers + Caddy | OOM 风险 | gunicorn `--workers 1`；加 2G swap；`POSTGRES` 不动实为最省事路径 |
| P1-2 | `deploy.ps1:91` / `.env.production.example:11` | `-Domain` 只 sed 替换 Caddyfile；`APP_CORS_ORIGINS` 仍是 `yourdomain.com`；`-Domain` 若传 `api.gamepouch.cn` 会变成 `api.api.gamepouch.cn` | CORS 不生效 / 证书签错域名 | 约定 `-Domain` **只传主域 `gamepouch.cn`**；同时替换 `.env.production` 的 CORS 域名 |
| P1-3 | `scripts/setup-ecs.sh:39-41,51-56` | Compose 安装兜底写的是 `pip install docker-compose`（v1 旧包），Ubuntu 24.04/26.04 受 PEP 668 限制会拒绝全局 pip 安装；且 Docker 发布端口会绕过 `ufw` 规则（Docker 官方已知行为） | apt 装 `docker-compose-plugin` 一旦失败，兜底必然跟着失败；误以为 ufw 挡住了 8000/5432 会产生安全错觉 | 删掉 pip 兜底、改成显式报错并提示手动装 `docker-compose-plugin`；端口隔离**只依赖阿里云安全组**（compose 已用 `internal` 网络隔离 db），不依赖 ufw |

> **Phase C 修复已完成（2026-11-04）**：P0-1~P0-8、P1-1~P1-3 全部落地，共改动 9 个文件；修复过程中另发现并修掉两项：
> - **P0-9** `deploy.ps1`：原版用了 PowerShell 7 的 `??` 运算符，且文件是无 BOM 的 UTF-8 中文脚本，Windows PowerShell 5.1 直接解析失败。已改为 5.1 兼容写法、补 UTF-8 BOM，并把 `Invoke-Expression` 字符串拼接换成参数数组 `& ssh @SshOpts ...`（顺带消除引号嵌套与错误被吞）。
> - **P0-10** `docker-compose.prod.yml:16,41`：`${DB_PASSWORD:?ERROR: DB_PASSWORD must be set}` 未加引号，`: ` 被 YAML 当成 mapping 分隔导致解析失败；生产与 `docker-compose.local.yml` 的同类插值共四处已加双引号。
>
> **已验证**：`python -m compileall -q app` = 0；`tests/test_admin_management.py` 44/44 通过；`git check-ignore` 命中 `.env.production` 且 `.env.production.example` 仍可提交；`yaml.safe_load(docker-compose.prod.yml)` 通过（services = db/app/caddy）；`wsl bash -n setup-ecs.sh` = 0；`deploy.ps1` 用 `[scriptblock]::Create` 与 `powershell -File -Action __syntax_check__` 在 PS 5.1 下均通过。
>
> **未能本地验证**：本机没有 Docker（`docker` 命令不存在），因此 `docker compose config`、`caddy validate`、三容器演练只能在 ECS 首次部署时执行，已并入 C4 / D1 / F2 验收。

### 2. 任务列表

#### Phase A — 购买与账号（用户）

- [x] **A1 阿里云账号 + 个人实名认证**｜前置：无 ✅ 2026-11-04
  - 打开阿里云官网注册/登录 → 账号中心 → 实名认证（个人，支付宝/刷脸，约 10 分钟）。
  - **验收**：控制台显示「已实名」，可下单付费产品。
- [x] **A2 下单 ECS 99 计划**｜前置：A1 ✅ 2026-11-04（实例运行中）
  - 进入 ECS 99 元/年活动页（官网搜「ECS 99 计划 / 经济型 e 实例」），**先核对活动条款：是否续费同价、是否新老同享、是否限购 1 台、是否限地域**。
  - 配置：**地域选中国大陆节点，深圳（华南 1）可以选**、**公共镜像 Ubuntu 24.04 LTS 64 位**、2 核 2G、40G ESSD Entry、3M 固定带宽、时长 **1 年**、数量 1。
  - 99 元活动常见可选地域包含北京 / 杭州 / 上海 / 呼和浩特 / **深圳** / 成都等（第三方活动规则汇总，**以购买页实际可选列表与库存为准**；深圳无库存再换杭州 / 北京）。按用户分布就近选——切灰云直连后地域直接决定延迟。
  - **不要**选按量付费/试用机（无法申请备案服务码）；**不要**选香港/新加坡等境外地域（不能备案，且 99 活动通常不含）。
  - **购买页实测（2026-11-04）**：地域默认「华南 1（深圳）」、规格 `ecs.e-c1m1.large` 2C2G、ESSD Entry 40GiB、专有网络 + 默认交换机、固定带宽 3Mbps、时长 1 年、数量 1、¥99.00（划线价 ¥1009.19）——这些**全部保持默认**。**唯一必须改的是镜像**：页面默认 `Alibaba Cloud Linux 3.2104 LTS 64 位`（RPM 系），`scripts/setup-ecs.sh` 用 `apt-get` 会直接失败，镜像下拉切到 Ubuntu 分类后默认落在 `Ubuntu 26.04 64位`，**改选 `Ubuntu 24.04 64位`**（普通版，任何 `UEFI版` 都不选）。理由：22.04 标准支持 2027-04，会在这台 1 年期 ECS 的后半段失去常规安全更新（需另开 Ubuntu Pro ESM）；24.04 支持到 2029 且 Docker CE / Compose 已成熟；26.04 LTS 支持到 2031-05、Docker 官方源也已适配，可作「想要最长支持周期」的备选，只是线上验证年限比 24.04 少两年。若活动页镜像列表不含 Ubuntu，则改为把 `setup-ecs.sh` 适配 `dnf/yum`，不要硬买。
  - **其余选项**：可用区「随机分配」保持；「自动续费」可勾（页面标注提前锁定优惠、可随时取消），但到期前 30 天仍要核实实际续费价；优惠券无可用则忽略；点「查看明细」核对续费条款。
  - **公网 IPv4 怎么确认**：阿里云官方规则是「购买公网带宽（≠0 Mbit/s）即从公网 IP 池分配一个固定公网 IPv4；带宽 0 或选『不分配』则没有」，所以购买页的 **「按固定带宽 3 Mbps」本身就是确认点**，备案要求的「有公网带宽」也由此满足；部分版本页面在「网络类型 / 虚拟交换机」附近另有独立的「公网 IP：分配 / 不分配」或「分配公网 IPv4 地址」勾选框，若看到则确认为「分配」。订单页「查看明细」应列出公网带宽 3Mbps。**最可靠的确认在开通后**：ECS 控制台 → 实例与镜像 → 实例（地域选华南 1 深圳）→ 「IP 地址」列会同时显示公网 IP 与私网 IP，实例详情 → 网络信息也可查。若只有私网 IP，用「资源变配 / 升级配置」把带宽调到 >0 Mbit/s 即可让系统补分配公网 IPv4（优先于单独购买 EIP，避免额外费用）。**切勿把带宽改成 0 Mbps**——会回收公网 IP 且不再满足备案条件。
  - **订单确认页实测（2026-11-04）**：「参数配置」显示 操作系统 `Ubuntu 24.04 64位`、地域 `华南1(深圳)`、付费方式 `包年包月`、时长 1 年、数量 1、带宽 `按固定带宽 3`、系统盘 `ESSD Entry 40`、官网折扣价 ¥1009.19、优惠金额 ¥910.19、**应付 ¥99.00**，气泡文案「云服务器包 1 年享 99 元，仅限 1 台」——配置全部正确，可下单。**订单页未展示续费价**：开通后到控制台「续费管理 / 费用中心」核实次年价格，不要默认第二年仍是 99。
  - **验收**：订单支付成功，收到实例 ID；记录 `实例ID / 地域 / 公网IP / 到期日` 到本节表格。
- [x] **A3 设置登录凭据**｜前置：A2 ✅ 2026-11-04（自建 ed25519 密钥，Workbench 写入公钥）
  - 设置 root 密码（或直接绑定 SSH 密钥对，`ECS_SSH_KEY` 给 `deploy.ps1` 用）；密码存密码管理器。实例详情页有「重置密码」按钮，**重置后需重启实例才生效**；更推荐绑定 SSH 密钥对，避免口令爆破。
  - **推荐路线 · 自建密钥（私钥不出本机、无需重启）**：本地 `ssh-keygen -t ed25519 -f "$($env:USERPROFILE)\.ssh\id_ecs99"`（**passphrase 留空**，否则 `deploy.ps1` 非交互会卡）→ `Get-Content ...\id_ecs99.pub` 复制公钥文本 → 控制台「远程连接 / **Workbench**」网页终端（Ubuntu 云镜像默认免密可进；若要求密码，用「重置密码」+ 重启后走 **VNC** 登录）→ 终端内 `whoami` 确认 root（否则 `sudo -i`），执行 `mkdir -p /root/.ssh && chmod 700 /root/.ssh`、`echo '<公钥文本>' >> /root/.ssh/authorized_keys`、`chmod 600 /root/.ssh/authorized_keys` → 本地 `ssh -i <私钥> root@<公网IP>` 验证 → `$env:ECS_SSH_KEY="<私钥绝对路径>"` 供 `deploy.ps1` 使用。Windows 若报 `UNPROTECTED PRIVATE KEY FILE`，用 `icacls <私钥> /inheritance:r /grant:r "<当前用户>:F"` 收紧 ACL。
  - **实测坑（2026-11-04）**：阿里云 Ubuntu 24.04 公共镜像默认 `PasswordAuthentication no`（服务端只提供 `publickey` 认证），在公钥装好**之前**任何 `ssh/scp` 都会报 `Permission denied (publickey)`——所以「先 scp 上传 `.pub` 再写 `authorized_keys`」是循环依赖，不成立；必须先用 Workbench/VNC 在服务器内写入公钥。能收到该报错说明 22 端口与安全组已通，不是网络问题。不必为此「临时打开密码登录」，降低安全性且无必要。
  - **控制台路线 · 阿里云托管密钥对**：ECS 控制台 →「网络与安全 → 密钥对」（**地域必须选华南1深圳，密钥对与实例同地域**）→ 创建或导入 → 实例详情「全部操作 → 绑定密钥对」→ **重启实例生效**。官方规则（`AttachKeyPair`）：绑定后**禁用用户名+密码验证**、运行中实例必须重启才生效、已有密钥会被新密钥替换；自动创建的 `.pem` 私钥只提供一次下载。⚠️ `ImportKeyPair` 只接受 `rsa / dsa / ssh-rsa / ssh-dss / ecdsa`，**不支持 `ssh-ed25519`**：走本路线需另跑 `ssh-keygen -t rsa -b 4096 -f ...\id_ecs99_rsa` 并把 `ECS_SSH_KEY` 指向该 RSA 私钥；这也是优先选 Workbench 路线的原因。
  - 确认密钥登录稳定后再在 `/etc/ssh/sshd_config` 设 `PasswordAuthentication no` / `PermitRootLogin prohibit-password` 并 `systemctl restart sshd`；保留 Workbench 作兜底，先把安全组 22 限制为自己出口 IP。
  - **首次连接会问 host key**：第一次 `ssh/scp` 到新 ECS 会提示 `Are you sure you want to continue connecting (yes/no/[fingerprint])?`，必须输入完整 `yes`（直接回车默认 `no` → `Host key verification failed`，输 `y` 也可能不被接受）。严谨做法：先在 Workbench 终端跑 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 核对指纹；省事做法：`ssh/scp -o StrictHostKeyChecking=accept-new ...` 自动接受新主机并写入 `known_hosts`（比 `=no` 安全，已变更的主机仍会拒绝）。**务必先手动连一次再跑 `deploy.ps1`**，否则脚本里非交互的 `ssh/scp` 会卡在同一提示；Phase C 可在 `deploy.ps1` 的 ssh/scp 命令统一加 `-o StrictHostKeyChecking=accept-new`。写错旧记录用 `ssh-keygen -R <公网IP>` 清除。
  - **验收**：`ssh -i <私钥> root@<ECS_IP>` 非交互直接登录成功（无密码/passphrase 提示）。**实测通过（2026-11-04）**：返回 `iZwz9bfqgjtrmiulpyesovZ` 与 `Ubuntu 24.04.5 LTS`，确认密钥认证、22 端口、host key 均已就绪，镜像为 24.04 的 point release。
  - **环境变量（当前 PowerShell 会话有效）**：`$env:ECS_HOST` / `$env:ECS_USER="root"` / `$env:ECS_SSH_KEY="<私钥绝对路径>"` 必须逐行设置并验证（`Test-Path $env:ECS_SSH_KEY`），`deploy.ps1` 要在**同一窗口**运行；换行粘贴错位时变量会没设上，务必回显确认。
- [ ] **A4 安全组放通**｜前置：A2
  - ECS 控制台 → 安全组 → 入方向：`22/tcp` 来源限制为自家出口 IP、`80/tcp` 与 `443/tcp` 来源 `0.0.0.0/0`；**不放通 8000 / 5432**。
  - 备案联调期走 `80/tcp`（已在上面放通），Caddy 的 staging 站点就监听 80；**不需要额外放通 8080**。
  - **验收**：`curl http://<ECS_IP>` 在 80 未起服务时表现为连接被拒/超时但端口可达，`nmap`/`telnet` 确认 5432 不可达。
- [ ] **A5 记录资产台账**｜前置：A2~A4
  - 记录到本节表格：`实例 ID`、`地域`、`到期日`、`域名 = gamepouch.cn`、`备案服务码`。**公网 IP、root 密码、SSH 私钥只存本地密码管理器，不写入 Git 文档**——本仓库会推送到公开 GitHub，明文公网 IP 会招来端口扫描与 SSH 爆破。
  - **实例开通实测（2026-11-04）**：状态「运行中」、地域 `华南1(深圳) 可用区 D`、`Ubuntu 24.04 64位`、规格 `ecs.e-c1m1.large 2C2G`、付费类型包年包月、到期 `2027-11-04 23:59:59`；「基本信息」显示**公网 IP 已分配**、主私网 IP `172.29.150.172`，公网 IP 下方有「转换为弹性公网 IP」（**不要点**，固定公网 IP 随 3M 带宽已够用，转换会改变计费形态）。右侧「事件和提醒」弹出「开启内存优化 / 易发生内存耗尽」——正好印证 D2 的 2G swap 与 P1-1 的单 gunicorn worker 必须做；可点「不再展示」，按自己的方案加 swap 更可控。

#### Phase B — 域名与 ICP 备案（用户，可与 Phase C~F 并行）

- [x] **B1 确认域名状态**｜前置：拥有 `gamepouch.cn` ✅ 2026-11-04（域名信息 + 可备案检测通过）
  - **跨注册商核对（本项目易踩坑）**：域名在华为云注册、DNS 托管 Cloudflare，按「谁接入谁备案」原则可直接在阿里云备案，**不需要把域名转入阿里云**。但必须保证：域名已实名认证、域名持有者姓名/证件类型/证件号与备案主体（本人身份证）**完全一致**、未开启隐私保护遮挡注册人信息、`.cn` 后缀已获工信部批复。若刚做过实名认证或过户，需等 **2~3 天** 信息同步到管局系统再提交，否则会报「域名与主体信息不一致」。
  - 核对域名有效期 ≥ 备案周期 + 1 个月；到 `beian.aliyun.com` 用「检测域名是否可备案 / 检测账号是否可备案」先自检。
  - 记录现状：`api.gamepouch.cn` 当前是 **CNAME → `<tunnel-id>.cfargotunnel.com`**（代理开启），**切换前不要删**。
  - **实测（2026-11-04，脱敏记录）**：华为云域名详情页显示 `域名状态 ok`、`所有者实名认证 已实名认证`、`用户类型 个人用户 / 证件类型 身份证`、域名所有者与联系人一致、`到期 2029-11-03`（远超备案周期，且覆盖 ECS 首年 2027-11-04）、DNS 为 Cloudflare NS（与现状一致，不影响跨注册商备案）；主体所在省份为广东，与华南 1 深圳 ECS 同省，备案地区选广东省。**证件号、手机号、邮箱、通讯地址一律不写入本文/仓库**。截图无法确认、需用户自行核对：① 实名证件号与阿里云备案主体逐位一致（最常见驳回原因）；② 若实名认证/过户是近 2~3 天内完成，需等管局信息同步再提交；③ 域名未开启 WHOIS 隐私保护。
  - **可备案检测（2026-11-04）**：`beian.aliyun.com`「检测域名是否可备案」返回「后缀已获工信部批复」「注册服务商已通过工信部批复」两项均通过；第三段「域名实名信息注意事项」是**通用提示而非失败项**——域名在华为云注册，阿里云读不到实名明细，需人工保证备案订单的**姓名（中文全名）/ 证件类型（身份证）/ 证件号码**与华为云实名信息逐项一致，不要用英文名或拼音。
  - **验收**：华为云控制台实名信息与备案主体一致；`nslookup api.gamepouch.cn` 返回 Cloudflare CNAME。
- [ ] **B2 申请备案服务码并提交备案**｜前置：A2（包年 ECS）、B1
  - **两条验证路径**：① 推荐 `beian.aliyun.com` →「开始备案」→ 验证方式选「**阿里云 ECS 实例**」→ 选华南 1 深圳这台，系统自动校验，无需单独申请服务码；② ECS 控制台 →「备案服务码 / 服务码获取」→ 用该 ECS 申请（中国大陆节点 + 包年包月 ≥3 个月 + 公网带宽；每台可申请 5 个、每个仅用一次）→ 在备案订单里粘贴服务码。
  - **备案方式选择页实测（2026-11-04）**：`beian.aliyun.com` →「我的备案」→「选择备案方式」有「免费自助备案 / 付费代办服务」两个 Tab，以及「万小智备案助手（AI 引导，约 10 分钟，暂不支持 APP 备案）」「传统表单自助备案（标准表单，约 30 分钟）」两张免费卡片。**选「免费自助备案」→「传统表单自助备案」→ 开始备案**：逐字段可见，便于核对跨注册商实名三项一致性，且后续 App 备案也走表单；不要选付费代办。顶部「还没有备案服务码？开通万小智 AI 建站即赠」是营销引导，本 ECS 已符合备案条件，可直接用 ECS 实例验证或免费申请服务码，**不需要购买任何产品**。页面流程「填写信息 → 阿里云初审 → 工信部短信核验 → 管局审核 → 备案成功」与本文时间线一致。
  - 填写要点：**备案地区按身份证住所地选，与 ECS 地域无关**；主体选个人；域名 `gamepouch.cn`；网站名称避开「博客 / 论坛」等个人备案敏感词；服务内容选非经营性，不要勾需前置审批的类目。
  - **网站信息页实测（2026-11-04）**：网站名称 `趣玩匣`、域名 `gamepouch.cn`、网站内容 `其他`、网站语言 `中文简体`。个人备案服务内容**本来就选「其他」**（各接入商规则如此），但会强制要求备注「不少于 20 字、说明网站开办后大致内容」，为空会红字拦截。可套用的备注模板：「本网站为个人非经营性网站，由本人独立开发维护，主要用于展示本人开发的移动应用的用户协议、隐私政策、版本说明及联系方式，并提供该应用账号与数据备份功能的说明。网站仅作信息展示使用，不设论坛社区，不含企业、单位等非个人网站信息，不提供下载服务、在线交易、付费服务或广告合作，也不涉及新闻、出版、教育、医疗等需要前置审批的内容。」**不要写**「游戏下载 / ROM / 资源分发 / 会员付费 / 商城 / 交易 / 广告」等词（个人备案对软件下载站与经营性内容敏感）；初审电话的回答要与备注一致。「网站接入信息」云服务选 `ECS`，**云产品实例为必填**：直接选系统蓝色提示推荐的那台「可免费备案实例」（即华南 1 深圳 ECS，公网 IP 不写入本文），选完点「完成填写」而不是「保存草稿」。备注框下方红字「不少于 20 个字 / 不能为空」是**常驻提示文案**，填了内容仍会显示，以「完成填写」时的实际校验为准；若下拉无实例，检查地域、包年包月时长与公网带宽，或改走备案服务码路径。**互联网信息服务页（2026-11-04 20:11）**：网站信息保存成功，列表中 1 条「网站 / 趣玩匣 / gamepouch.cn」。三条流程提示里第 3 条最关键：**管局审核通过前同一阿里云账号只能有一个在审订单**（官方 App 备案 FAQ 亦确认），而阿里云允许「一次申请中同时完成网站备案与 App 备案」。因此此处需决策是否点「新增其它 App」把 App 备案并入本订单：并入可省整整一轮管局审核；不并入须等本单结束后再开订单。App 备案额外材料：App 名称/图标/截图、包名、公钥、**签名 MD5（去掉冒号）**、可访问的隐私政策 URL、接入域名、运行平台。材料不齐不要并入，避免任一不合格拖累整个订单被退回；先看页面「各地区数量规则」确认广东省是否允许同一订单同时提交网站 + App。只备案 1 个域名，不触发广东「累计超 5 个域名需网站建设方案书」，不要点「新增其它网站」。
  - **广东省 ICP 备案重要规则（2026-11-04 核对）**：① 负责人年满 16 周岁；② **证件住所需为本省**——本项目身份证住所与通信地址同属广东省，无需居住证/房产证/社保证明，初审电话如实说明即可；③ 备案个人须在第 4 步上传资料时**下载打印《互联网信息服务核准承诺书》、本人用黑色或蓝色笔工整签字后拍照上传**（广东特有，漏传会被退回）；④ 域名有效期 >30 天（本例 2029-11-03 ✅）、域名持有者与主办人名称一致（B1 已核对 ✅）；⑤ 网站数量 >5 个才需网站建设方案书（本例 1 个，不涉及）；⑥ **已取得备案号的域名必须可访问，且页面下方须展示主体备案号并链接至工信部备案管理系统**，与实际备案号一致——对应 B4，需在隐私页/网站页脚实现；⑦ 个人网站名称另有命名要求，提交前点「个人网站名称命名要求」核对 `趣玩匣`。
  - 材料：身份证**原件彩色拍照**（正反面、四角完整、无反光、**证件剩余有效期 >1 个月**）、网站负责人人脸核验（短信链接或阿里云 APP 扫码）、上条承诺书签字件；阿里云初审会电话核验，保持手机畅通。因广东额外要求签字件、App 备案材料更多，**本订单只提交网站备案**，App 备案待本单通过后再开订单更稳。
  - **时间线**：阿里云初审 1 工作日 → 工信部短信核验须在 **24 小时内**完成（超时作废需重提）→ 管局审核 ≤20 工作日。常见驳回：域名实名信息不一致/未同步、证件非最新版、网站名称违规、人脸核验失败、初审电话未接。
  - **注意**：备案期间域名不要指向大陆 ECS 的 80/443；线上继续走 Cloudflare Tunnel。若后续 App 上架，工信部另要求 **App 备案**（同一备案系统另有入口），同样依赖大陆服务器。
  - **已提交（2026-11-04 23:06）**：审核进度显示「提交审核 已提交」→「阿里云初审 审核中，明天 20 点前审核」，后续依次为「待提交管局 / 工信部短信核验 / 管局审核」；页面提示注意接听阿里云备案审核来电（95187、0571 号段），可关注「阿里云万网」微信服务号查进度。公安联网备案显示「已完成授权，数据码将在通信管理局审核通过后生成」，本阶段无需操作。此时 B2 的**用户侧动作已全部完成**，剩余为被动配合与等待，可与 D/E/F 并行；B2 的验收（进入管局审核）尚未达成，暂不打勾。
  - **验收**：备案订单进入「管局审核」，状态可查。
- [ ] **B3 过渡期访问方案**｜前置：A4、B2
  - **已实现**：`Caddyfile.staging`（站点块只有 `:80`、不含任何主机名 → 不触发自动 HTTPS/ACME），由 `deploy.ps1 -Action deploy -Staging` 上传为远程的 `Caddyfile.prod`，compose 挂载路径不变；`https://api.gamepouch.cn` 保持指向 Tunnel。
  - **原因**：`Caddyfile.prod` 的 `api.yourdomain.com` 站点会触发 Caddy 自动申请 Let's Encrypt 证书；备案未通过时域名不能解析到大陆 ECS，ACME 校验必然失败并反复重试（刷满日志、可能触发速率限制）。staging 用 `http://<ECS_IP>`（80 端口）直连，既不涉及域名解析，也不改 compose 端口映射。备案通过、DNS 切到 ECS 后带 `-Domain` 且去掉 `-Staging` 重新 deploy 即切回 `Caddyfile.prod`。
  - **验收**：本机 `curl http://<ECS_IP>/healthz` 返回 `{"ok":true,"env":"prod"}`，且线上 `https://api.gamepouch.cn/healthz` 仍正常。
- [ ] **B4 备案通过确认**｜前置：B2，管局审核通过
  - 拿到备案号 → 回填到后台 `AppConfig.filing_number`（`docs/release-plan.md` 已约定由后台下发）；网站/隐私页底部展示备案号并链接 `https://beian.miit.gov.cn`；备案成功后 30 天内完成**公安联网备案**。
  - **验收**：工信部备案查询可查到 `gamepouch.cn`；后台 `/admin/ui/config` 的 `filing_number` 已更新；此时才满足 I1 切 DNS 的前置条件。

#### Phase C — 上线前代码修复（助手，购买前后均可先做）

- [x] **C1 修 P0-1 / P0-2（服务启动三件套）** ✅ 2026-11-04
  - `requirements.txt` 补 `gunicorn==22.0.0`；`Dockerfile.prod` CMD `--workers 2` → `1`；`docker-compose.prod.yml:42` 与 `.env.production.example:8` 的 `APP_ENV` 统一为 `prod`（`config.is_prod` 不变）。
  - **验收**：YAML 解析已通过；`/healthz` 返回 `"env":"prod"`、`prod mode: skipping create_all`、`/api/billing/verify` 返回 503 这三项待 ECS 首次启动确认（本机无 Docker）。
- [x] **C2 修 P0-3 / P1-2（Caddy 与域名）** ✅ 2026-11-04
  - `Caddyfile.prod` 删除 nginx 风格 `client_max_body_size`、日志改 `output stdout`、去掉重复 CORS 头、`reverse_proxy` 改为 Caddy v2 标准写法；`deploy.ps1 -Domain` 同时替换 Caddyfile 与 `.env.production` 的 CORS，并拒绝传入 `api.*` 前缀。
  - **验收**：`caddy validate` 与无重复 CORS 头待 ECS 首次启动确认。
- [x] **C3 修 P0-4 ~ P0-8（secrets 与部署脚本）** ✅ 2026-11-04
  - `.gitignore` 忽略 `.env.production` 但保留模板；模板补 `ADMIN_WEB_PASSWORD`；`deploy.ps1` 改容器内 seed、`scripts/db-init` 正确落盘、`exec -T`、`setup → deploy → seed` 顺序、host key `accept-new`、`chmod 600`、`CHANGE_ME` 拦截；`setup-ecs.sh` 改阿里云 Docker 镜像源并删掉 PEP 668 下必然失败的 pip 兜底。
  - **验收**：`git check-ignore` ✅、44 项自测 ✅、compileall ✅、PS 5.1 语法与加载 ✅、`bash -n` ✅。
- [ ] **C4 三容器演练（移至 ECS 首次部署执行）**
  - 本机未安装 Docker，改为在 D1/F2 阶段用 `docker compose -f docker-compose.prod.yml up -d --build` 于 ECS 上验证 `/healthz`、`/privacy`、`/terms`、`/api/cms/config`、`/admin/ui/login`，并跑 `caddy validate`。
  - **验收**：三容器 healthy、`/healthz` 返回 `"env":"prod"`、Caddy 配置校验通过、无 OOM。

#### Phase D — ECS 初始化（共同）

- [x] **D1 上传并执行初始化脚本**｜前置：A3、A4、C3 ✅ 2026-11-04
  - 用 `.\scripts\deploy.ps1 -Action setup`（在 `tools\account_backend` 下执行；从仓库根目录则用 `.\tools\account_backend\scripts\deploy.ps1 -Action setup`），脚本会自动上传 `scripts/setup-ecs.sh` 到 ECS 并执行。
  - **实测坑（2026-11-04，已修）**：首跑报 `curl: (35) Recv failure: Connection reset by peer` → `Failed to enable unit: Unit file docker.service does not exist`。根因是 **`get.docker.com` 在大陆 ECS 被连接重置**；`--mirror Aliyun` 只改安装脚本内部的 apt 源，脚本本身仍要从 `get.docker.com` 下载，因此无效；且 `curl | sh` 管道退出码取 `sh`（空输入返回 0），`set -e` 没拦住，直到 `systemctl` 才失败。已把 `setup-ecs.sh` 改为**直接配置阿里云 Docker CE 镜像站**（`mirrors.aliyun.com/docker-ce/linux/ubuntu` 的 GPG + `sources.list.d/docker.list`，当前 codename 无 Release 时回退 `jammy`），再 `apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` → `systemctl enable --now docker`。`bash -n` 校验通过；首次失败时未执行到 apt 安装，无残留半装状态，**直接重跑同一条命令即可**。若镜像站仍不可达，ECS 可换内网域名 `mirrors.cloud.aliyuncs.com`。
  - **D1 实测通过（2026-11-04）**：ECS 上只读核对 `Docker version 29.9.3`、`Docker Compose version v5.7.0`（v2 插件）、`systemctl is-active docker = active`、`docker.list` 使用 `noble` 仓库（阿里云镜像已同步，未触发 jammy 回退）。`free -h` 显示总内存仅 **1.7Gi、可用 1.2Gi、无 swap**，印证 D2 的 2G swap 与单 gunicorn worker 必须做。另修掉初始化脚本输出里的提示 bug：原 `echo '$env:ECS_HOST="' + $PUBLIC_IP + '"'` 把 bash 拼接写进单引号导致打印出字面量，且提示的下一步路径写成 `./deploy.ps1` 并误导「立刻 deploy」；已改为 `printf` 正确插值、补全三个环境变量、明确「先 D2/E 阶段再部署」。
  - **镜像拉取坑（2026-11-05，已修）**：`get.docker.com` 装好了 Docker，但 `docker compose up --build` 拉 `postgres:16-alpine` / `caddy:2-alpine` / `python:3.12-slim` 时 `registry-1.docker.io` 仍 i/o timeout。`setup-ecs.sh` 现会幂等写入 `/etc/docker/daemon.json` 的 `registry-mirrors`（`docker.m.daocloud.io` / `docker.1ms.run` / `hub.rat.dev`）并 `systemctl restart docker`；重跑 `-Action setup` 即可应用。`/v2/` 探测返回 401 属正常（可达、未带鉴权）。
  - **验收**：`docker --version`、`docker compose version` 均有输出（**必须是 Compose v2 插件 `docker compose`，不是旧 `docker-compose` v1 命令**）；`systemctl is-active docker` = active；`docker compose -f docker-compose.prod.yml config` 无报错。
- [ ] **D2 加 swap + 基础设置**｜前置：D1
  - `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`，写进 `/etc/fstab`；设置 `vm.swappiness=10`；时区 `timedatectl set-timezone Asia/Shanghai`。
  - **验收**：`free -h` 显示 Swap 2.0Gi；`date` 为北京时间。
- [x] **D3 创建部署目录并收紧权限**｜前置：D1 ✅ 2026-11-05
  - `mkdir -p /opt/retroemupouch-account/scripts /opt/backups`，`chmod 700 /opt/retroemupouch-account`；`.env.production` 上传后 `chmod 600`。
  - **已实现**：`deploy.ps1 -Action setup` 的第二段会自动 `install` 备份脚本、建 `/opt/backups` 并 `chmod 700` 两个目录；实测 `ls -ld` 两个目录均为 `drwx------ root root`。
- [ ] **D4 确认端口与安全组一致**｜前置：A4、D1
  - **验收**：ECS 内 `ss -lntp` 只看到 80/443（staging 站点复用 80，无 8080），`docker ps` 中 db 无端口映射。

#### Phase E — 生产 secrets 与配置（用户 + 助手）

- [x] **E1 生成全部随机值**｜前置：C3 ✅ 2026-11-05
  - `python -c "import secrets; print(secrets.token_urlsafe(48))"` 生成 5 个独立值：`DB_PASSWORD`、`JWT_SECRET`、`ADMIN_TOKEN_SECRET`、`CLOUD_SAVE_KEY_SALT`、`DEVICE_ID_SALT`；另设 `ADMIN_WEB_PASSWORD` 强口令。
  - **已完成**：6 个值已用 `RandomNumberGenerator`（base64url）生成并写入本地 `.env.production`（gitignored；`DB_PASSWORD` 与 `DATABASE_URL` 一致）。生成过程中旧值曾被部署日志打印，已整体轮换一次；`app/database.py` 也已改为 `hide_password=True`，不会再明文输出。
  - **注意**：`JWT_SECRET` / `ADMIN_TOKEN_SECRET` / 两个 salt **一旦更换会导致已签发 JWT 失效、云存档密钥推导变化**，因此「本地 → ECS」切换时客户端最多需要重新登录，云存档密文不受影响（客户端加密，服务端只存 blob）。
- [x] **E2 填写 `.env.production`**｜前置：E1、C3 ✅ 2026-11-05
  - 从 `.env.production.example` 复制；逐项替换 `CHANGE_ME`；`APP_ENV=prod`；`APP_CORS_ORIGINS=https://api.gamepouch.cn`；`DATABASE_URL` 的 `DB_PASSWORD` 与 compose 中 `${DB_PASSWORD}` **必须完全一致**；`ALLOW_DEV_MOCK=false`；`ADMIN_WEB_PASSWORD` 必填。
  - **验收**：`grep -c CHANGE_ME .env.production` = 0；`git status --short` 不出现该文件。
  - **Compose 插值坑（已修）**：`docker-compose.prod.yml` 里的 `${DB_PASSWORD:?...}` 从 shell 环境 / `./.env` 取值，**不会读 `env_file: .env.production`**。直接 `up -d` 会报 `required variable DB_PASSWORD is missing a value`。`deploy.ps1` 上传后会在远端执行 `grep '^DB_PASSWORD=' .env.production > .env && chmod 600 .env` 供 Compose 插值（`deploy` / `update` 均已覆盖）；`DATABASE_URL` 里的密码必须与 `DB_PASSWORD` 完全一致。
- [ ] **E3 域名与 Caddyfile**｜前置：B1、C2
  - 备案前无需改 `Caddyfile.prod`：`deploy.ps1 -Staging` 会用 `Caddyfile.staging`（`:80` 纯 HTTP、无域名站点）覆盖远程同名文件，并跳过域名 `sed`；`api.gamepouch.cn` 保持指向 Cloudflare Tunnel。备案通过后带 `-Domain gamepouch.cn` 且去掉 `-Staging` 重新 deploy，脚本自动把 `yourdomain.com` 替换为主域并启用自动 HTTPS（**只传主域**）。
  - **验收**：`caddy validate` 通过（deploy 脚本已内置校验，失败会中止并打印 caddy 日志）；`api.gamepouch.cn` 在 Cloudflare 仍指向 Tunnel（**此时不切 DNS**）。
- [ ] **E4 secrets 备份**｜前置：E2
  - 加密保存到本地密码管理器/离线位置，不进 Git、不发聊天工具。
  - **验收**：本地有一份可恢复的 secrets 副本。

#### Phase F — 部署与数据库初始化（助手 + 用户）

- [ ] **F1 设置部署环境变量**｜前置：A3、E2
  ```powershell
  cd tools\account_backend   # 若不 cd，则在仓库根目录用完整路径 .\tools\account_backend\scripts\deploy.ps1
  $env:ECS_HOST="<ECS公网IP>"
  $env:ECS_USER="root"
  $env:ECS_SSH_KEY="C:\Users\<你>\.ssh\id_ecs99"
  # 备案前保持 ECS_DOMAIN 为空；deploy.ps1 -Staging 会跳过域名 sed，不会生成域名站点
  # 备案通过、切 DNS 阶段再设 $env:ECS_DOMAIN="gamepouch.cn" 并去掉 -Staging
  ```
- [ ] **F2 执行部署**｜前置：D1~D4、F1
  ```powershell
  # 以下命令默认已 cd tools\account_backend；从仓库根目录调用请把 .\scripts\ 换成 .\tools\account_backend\scripts\
  .\scripts\deploy.ps1 -Action setup             # 必须执行：本机无 Docker，Docker/Compose 在 ECS 上装
  .\scripts\deploy.ps1 -Action deploy -Staging  # 备案前：Caddyfile.staging，纯 HTTP :80
  .\scripts\deploy.ps1 -Action seed             # 初始化 CMS 文档 + 10 条 AppConfig
  .\scripts\deploy.ps1 -Action logs -Service app
  ```
  - ⚠️ **`cd` 与脚本调用必须分成两行**（或用 `& <脚本完整路径> -Action setup`）。把 `cd d:\...\account_backend.\scripts\deploy.ps1 -Action setup` 粘成一行时，PowerShell 会把 `.\scripts\deploy.ps1` 和 `-Action` 当成 `Set-Location` 的参数，报 `A parameter cannot be found that matches parameter name 'Action'`。
  - 顺序不可颠倒：`alembic upgrade head` 前 db 必须 healthcheck 通过；`ensure_runtime_schema` 会补 `users.is_active` / `admin_audit_logs`，但仍以 Alembic 为主。
  - **备案前部署**：`-Staging` 会把 `Caddyfile.staging` 上传为远程 `Caddyfile.prod`、跳过域名 sed、校验 Caddyfile、重启 caddy、跑 Alembic 并做一次 `curl http://127.0.0.1/healthz` 自检；`api.gamepouch.cn` 继续指向 Cloudflare Tunnel。备案通过后带 `-Domain` 去掉 `-Staging` 重新部署一次即切回自动 HTTPS。
  - **验收**：`docker compose -f docker-compose.prod.yml ps` 三个服务 healthy；日志出现 `prod mode: skipping create_all`；seed 返回 `app_configs_seeded: 10, cms_docs_seeded: 4`。
  - **seed 改为 CLI**：`deploy.ps1 -Action seed` 现在执行 `python -m app.cli_seed`（直接调 `seed.run_seed()`），不再用 `python -c "import httpx; ..."`——后者经 PowerShell → ssh → bash 时内层双引号会被吞，远程必报 `syntax error near unexpected token ('`。宿主机不映射 8000，CLI 也不需要 HTTP。
  - **实测坑（2026-11-05，均已修）**：① Compose 的 `${DB_PASSWORD}` 不读 `env_file`，需远端 `./.env`（deploy/update 已自动生成）；② 大陆 ECS 直连 `registry-1.docker.io` 超时，`setup-ecs.sh` 已配置 `daemon.json` 的 `registry-mirrors`（daocloud / 1ms / rat.dev）；③ `Dockerfile.prod` 原本的 `apt-get update`（deb.debian.org）卡十几分钟，因依赖全有 manylinux wheel 已去掉并改用阿里云 PyPI；④ `scripts/db-init/01-extensions.sql` 曾写成 shell heredoc，postgres 把 `*.sql` 交给 psql 导致 `syntax error at or near "#"`、db unhealthy，已改成纯 SQL；⑤ `app/database.py` 打印 Engine URL 会泄露明文 DB 密码，已改为 `render_as_string(hide_password=True)`。
  - **实测结果（2026-11-05）**：ECS 上 `deploy -Staging` + `seed` 全绿；`alembic current` = `0002_admin_management (head)`；`/healthz`、`/api/cms/config`、`/privacy`、`/terms`、`/docs`、`/admin/ui/login` 均 200。Caddy 日志明确 `server is listening only on the HTTP port, so no automatic HTTPS will be applied`（符合预期，无 ACME 失败刷屏）。**公网 80 仍不通**：ECS 内 `ss -lntp` 已监听 80、ufw inactive、本机 curl 正常，但外部 `Test-NetConnection :80` 失败而 :22 成功 → 只剩阿里云安全组入方向未放通 `80/tcp`，需控制台手动加规则。
- [ ] **F3 校验 schema 与 seed**｜前置：F2
  - 容器内执行 `alembic current` = `0002_admin_management`；核对 `app_configs` = 10 条、`cms_documents` 有 privacy_policy/eula 等草稿或已发布版本、`users.is_active` 列存在、`admin_audit_logs` 表存在。
  - **验收**：`GET /api/cms/config` 返回 10 项；`GET /privacy` 与 `/terms` 正常渲染。

#### Phase G — 本地 SQLite 数据迁移（助手 + 用户确认）

- [x] **G1 全量备份本地库**｜前置：F3 ✅ 2026-11-05
  - 复制 `D:\RetroEmuPouch\backend\sqlite\dev.db`（163840 B / 9 用户 / 9 表 65 行）到 `D:\RetroEmuPouch\backend\backups\dev-20261105-0944.db`，SHA256 `88F3D43F…B470D43`。
  - **验收**：备份可读，`sqlite3` 以只读模式打开成功。
- [x] **G2 编写并试跑一次性迁移脚本**｜前置：G1 ✅ 2026-11-05
  - **实现（改为纯 SQL 导出，不直连生产库）**：
    - `scripts/migrate_sqlite.py`（标准库 sqlite3，只导出）：`inspect` 打印源表/列/行数；`dump --out x.sql` 按外键顺序生成 `insert … on conflict (pk) do nothing`，布尔转 `TRUE/FALSE`，BLOB 转 `decode('hex','hex')`，bytea/时间戳原样保留；默认**跳过** `app_configs` / `cms_documents`（seed 已写）；`users.is_admin` 一律不带入生产（管理员只经 seed/后台授予）。
    - `scripts/migrate-db.sh`（在 ECS 上执行）：`<dump.sql>` 默认进**临时库** `gp_migrate_test` 试跑（自动 `create database` + `alembic upgrade head` + 导入 + 逐表行数），`--apply` 才动生产（先 `pg_dump` 快照到 `/opt/backups/pre-migrate-<ts>.sql.gz`），`--cleanup` 删临时库。
  - **试跑结果（临时库）**：users 9 / entitlements 9 / billing_transactions 4 / cloud_save_blobs 1 / pc_pairings 2 / consent_records 26 / admin_audit_logs 0，与源库逐表一致；`created_at` 保留为 UTC（`…+00`）、blob 9 字节且 sha256 一致、`password_hash` 全部 `$2b$12$` len=60、pairings 外键都能匹配到 users。
- [x] **G3 正式导入并冻结写入**｜前置：G2、切流前 ✅ 2026-11-05（导入完成；登录抽验待用户）
  - 生产快照：`/opt/backups/pre-migrate-20261105-0947.sql.gz`（9.9K）。
  - 导入结果：`users=9 / entitlements=9 / billing_transactions=4 / cloud_save_blobs=1 / pc_pairings=2 / consent_records=30`（26 条新导入 + 4 条 H4 真机匿名同意）、`app_configs=10 / cms_documents=4` 未被覆盖。
  - **密码兼容验证**：`POST /api/auth/login` 用迁移账号 + 错误密码 → `401 {"detail":"bad_credentials"}`（说明 bcrypt hash 可被 passlib 正确解析，若 hash 坏会 500）。
  - **仍待人工**：① 用 3 个真实账号的原密码登录（只有你掌握明文），并核对 `/api/billing/entitlement` 档位；② 本地后端若还在写 `dev.db`，正式切流前需再导一次（本次基线 sha256 见 G1）。

#### Phase H — 全量验证（共同，切 DNS 之前必须全绿）

- [x] **H1 公网可达性（HTTP 部分）**｜前置：F2、B3 ✅ 2026-11-05
  - 备案前：`curl http://<ECS_IP>/healthz`（80 端口）。
  - **实测**：安全组放行 `80/tcp` 后，外部 `Test-NetConnection :80 = True`；`/healthz`、`/api/cms/config`、`/privacy`、`/terms`、`/docs`、`/admin/ui/login` 均 200，`healthz` 返回 `{"ok":true,"env":"prod",...}`。
  - **仍待备案后**：`curl -I https://api.gamepouch.cn/healthz` 验证证书链、HSTS、无重复 CORS 头（需切 DNS + `-Domain` 重新部署）。
- [x] **H2 端点回归（对齐 30/30 冒烟）**｜前置：F3 ✅ 2026-11-05
  - `/healthz`、公开 CMS、`/api/cms/config`、`/api/cms/docs/*`、`/privacy`、`/terms`、注册/登录/me/refresh/改密/logout、试用/权益、配对、云存档闸门、`/api/consent/status|accept`。
  - **已实现**：`scripts/smoke.sh [base_url]`（`deploy.ps1 -Action setup` 会装到远端 `scripts/smoke.sh`）。在 ECS 上跑 `scripts/smoke.sh http://127.0.0.1` → **PASS=38 FAIL=0**（含 200/404/303/403 期望码断言）。脚本会注册 `smoke_<ts>@example.com` 临时账号、用唯一 device_id 走同意流程，结束时 `DELETE /api/auth/me` 并按 `sha256(device+DEVICE_ID_SALT)` 精确删除本次 `consent_records`，**不留测试数据**（实测 users/pc_pairings/consent_records 均回到 0）。
  - **验收**：生产下 `POST /api/billing/verify` 返回 `200 + ok=false`（dev mock 关闭）；free 档 `GET /api/cloud/saves/list` 返回 `403 cloud_save_requires_premium`（云存档闸门生效）。
- [x] **H3 运营后台回归（44 项自测的线上版）**｜前置：F3 ✅ 2026-11-05（页面层）
  - `/admin/ui/login` 用 `ADMIN_WEB_PASSWORD` 登录；逐页打开 dashboard / users / entitlements / cloud-saves / pairings / consents / billing / audit / cms / config。
  - **实测**：未登录访问 `/admin/ui/users` → 303 跳登录页；`POST /admin/ui/login`（口令经 `--data-urlencode password@file` 传入，不出现在 ps/history）→ 303 + `admin_token` cookie；**11 个页面全部 200**。注意 `.env.production` 若为 CRLF，`cut -f2-` 会带上 `\r` 导致口令 401（脚本已 `tr -d '\r'`，文件本身也已统一为 LF）。
  - 仍待人工：禁用账号后旧 JWT 立即 403、权益 7 档调整、审计日志落库（需真实账号，适合 H4 一起做）。
- [x] **H4 App 端到端（临时指向 ECS）**｜前置：H2、H3 ✅ 2026-11-05（真机 OXF-AN10 / Android 12）
  - **关键约束**：`SecurityPolicy.assertSafe()` 只允许 `https` 或 `127.0.0.1 / localhost / ::1 / RFC1918` 的明文，**公网 IP + HTTP 会被 App 自己拒掉**（`SecurityException: 拒绝不安全的明文连接`），因此不能直接把 `http://<ECS_IP>` 填进调试入口。联调走 **SSH 隧道 + adb reverse**：
    `ssh -N -L 8080:127.0.0.1:80 root@<ECS>` + `adb reverse tcp:8080 tcp:8080`，App 里填 `http://127.0.0.1:8080`（loopback 合法 → 经 PC 隧道打到 ECS 的 Caddy）。
  - **产物**：`scripts/build-apk.ps1 -Flavor community -DebugBuild`（必须 debug：只有 `kDebugMode` 才显示「调试：账号后端」卡片；必须 community：`main`/store 的 `network_security_config.xml` 全局禁明文）。
  - **实测通过**：ConsentGate（v2）→ 注册 `e2e1105@example.com`（Caddy 日志 `POST /api/auth/register 201`）→ `/api/auth/me 200` → 会员页 `当前状态：试用中 · 剩余 7 天` → 修改密码（`change-password 200`）→ 账户注销（`DELETE /api/auth/me 200`，DB `users=0 / entitlements=0` 级联干净）。云存档按设计仍是付费档专属（free/试用只看得到闸门文案）。
  - **本轮回测暴露并修复的 3 个客户端缺陷**：
    1. **试用不生效**：后端试用期 `tier` 保持 `free`、只写 `trial_start`，客户端 `Entitlement` 却只看 `tier` → 真机显示"免费用户"且广告不去。修：新增 `trialActive`，`free + 未过期 trial_start` 归一成 `MembershipTier.trial`（`isAdFree`/`effectiveTier` 走它），并修正设置页"试用解锁云存档"的错误文案（付费档才有）。
    2. **试用剩余天数差 1**：`inDays` 向下取整导致刚开启显示"剩余 6 天"。修：按分钟向上取整。
    3. **access token 15 分钟过期后全 401**：客户端只存 `access_token`、丢弃 `refresh_token`，用着用着改密/注销就 `请求失败（401）`。修：新增 `kAccountRefreshToken` 持久化；`_json()` 遇 401 先 `POST /api/auth/refresh` 换新 token 再重试一次（`retried` 防死循环），登出/注销一并清除。
  - 验证刷新链路的方法：临时把 `.env.production` 的 `JWT_ACCESS_TOKEN_EXPIRE_MINUTES` 改成 1 并 `up -d --force-recreate app`，登录等 80s 再改密 → Caddy 日志出现 `change-password 401 → refresh 200 → change-password 200`；测完改回 15 重建。
- [x] **H5 性能与稳定性（首轮基线）**｜前置：H2 ✅ 2026-11-05
  - 连续 20 次请求 `/healthz` 记录延迟/失败率；`docker stats` 观察内存；3M 带宽下上传 1MB `.sav` 计时（云存档需付费档，留待有真实权益的账号）。
  - **实测基线（工作时段，PC → 深圳 ECS）**：20 次 `/healthz` 全成功，min 22ms / avg 27.8ms / max 68ms；`docker stats`：app 141.8MiB、db 34.85MiB、caddy 10.64MiB，主机 available 1.0Gi、swap 已用 84MiB、`dmesg` 无 OOM 记录。
  - **仍待做**：晚高峰复测、`swap` 长期是否持续增长、1MB `.sav` 上传计时（与 H4 一起做）。

#### Phase I — 切换与回滚（用户 + 助手）

- [ ] **I1 切 DNS**｜前置：B4、H1~H5 全绿
  - Cloudflare DNS：删除 `api.gamepouch.cn` 的 CNAME → `<tunnel-id>.cfargotunnel.com`，新增 **A 记录 → `<ECS 公网 IP>`**，代理状态改为 **「仅 DNS / 灰云」**（关键！橙云会继续绕 Cloudflare 边缘）；TTL 调低到 1~5 分钟便于回滚。
  - 保留 Tunnel 进程运行 ≥7 天。
  - **验收**：多地 `nslookup api.gamepouch.cn` 返回 ECS IP；`curl -v https://api.gamepouch.cn/healthz` 直连 ECS、无 `cf-ray` 头。
- [ ] **I2 客户端验证无需发版**｜前置：I1
  - 用**未改任何配置**的正式包跑账号/云存档/CMS 全流程，确认 `kDefaultBackendUrl` 直接命中 ECS。
  - **验收**：App 端 0 改动、0 报错。
- [ ] **I3 回滚预案（随时可执行）**｜前置：I1
  - 异常时把 Cloudflare 记录改回 CNAME Tunnel（本地 PC 保持 boot.bat 运行）→ 5 分钟内恢复线上；`deploy.ps1 -Action stop` 停 ECS；`pg_dump` 快照可回灌。
  - **验收**：演练一次回滚（可在低峰期改记录再改回），确认 RTO < 10 分钟。
- [ ] **I4 观察期收尾**｜前置：I1 后 7 天
  - 无故障 → 停 `boot.bat` / `stop.bat`，下线 cloudflared（staging 复用 80，无 8080 临时规则需要删）；更新 `docs/skills.md` 与本文「部署架构」图（去掉 Cloudflare Tunnel 主链路描述）。
  - **验收**：文档架构图与真实链路一致。

#### Phase J — 日常运维（长期）

- [x] **J1 数据库备份** ✅ 2026-11-05：`scripts/backup-db.sh`（`deploy.ps1 -Action setup` 会上传并安装 `15 3 * * *` 的 root crontab，日志 `/var/log/gp-backup.log`），产物 `/opt/backups/db-YYYY-MM-DD.sql.gz` 保留 7 天。已实测执行一次：12K dump、`gunzip -t` 通过。每月仍建议拉一份回本地。
- [ ] **J2 证书与更新**：Caddy 自动续期（`/data` 卷已持久化）；代码更新走 `deploy.ps1 -Action update`（会重建 app 并 `alembic upgrade head`），更新前先 `pg_dump`。
- [x] **J3 监控告警（基础版）** ✅ 2026-11-05
  - `scripts/healthcheck.sh`：cron `*/10 * * * *` 探测 `http://127.0.0.1/healthz`，成功只在整点记一条 `ok`，失败记 `FAIL code=xxx` 到 `/var/log/gp-health.log`（不自动重启，交回 `restart: always`）。已实测两条路径（成功不落日志、坏 URL → `FAIL code=000`）。
  - 容器日志轮转：`docker-compose.prod.yml` 加 `x-logging` 锚点（`json-file` + `max-size 10m` + `max-file 3`），三个服务都挂上，避免 Caddy 每请求一条 JSON 把盘写满；已 `docker inspect` 确认生效。
  - 每周日 04:30 `docker system prune -af --filter until=168h`（清 7 天前的悬空镜像/构建缓存），日志 `/var/log/gp-docker-prune.log`。
  - 仍建议：阿里云云监控配 CPU / 内存 / 带宽 / 磁盘阈值告警（控制台操作）；`deploy.ps1 -Action logs app` 排障；关注 `ADMIN_WEB_PASSWORD` 登录失败与 `admin_audit_logs`。
- [x] **J2b 备份恢复演练** ✅ 2026-11-05：`migrate-db.sh --restore-drill /opt/backups/db-YYYY-MM-DD.sql.gz` 把快照恢复进临时库 `gp_migrate_test` 并逐表比行数——实测 9 张表与生产完全一致（users 9 / entitlements 9 / billing 4 / blob 1 / pairings 2 / consent 30 / configs 10 / cms 4 / audit 0），演练后 `--cleanup` 删库。**结论：备份确实可恢复，不只是"有文件"。**
- [x] **J5 云存档产品化（上传 / 恢复 / 冲突决策）** ✅ 2026-11-05：`cloud_save_sync.dart` 接管真实存档（`<CRC>.sav` / `.state` / `.slotN.state` / 缩略图 `.thumb.dat`），稳定 `client_key` 覆盖同一 blob；恢复走 `.part` → 校验 → `.bak-<ts>` → `rename` 原子替换，失败不毁本地；`diff` 五态 + 30s 容差 + 恢复后 mtime 对齐消除假冲突；账号页支持批量/单条上传与恢复。测试：Dart 20 项 + 真实后端端到端。
- [ ] **J4 到期与合规**：日历提醒 ECS 与域名续费（**到期前 30 天核实 99 元续费条款是否仍有效**）；备案信息变更及时更新；`docs/release-plan.md` 的 `filing_number` 由后台 AppConfig 回填。

### 3. 执行顺序速查

```
A1 → A2 → A3 → A4 → A5
              ├─→ B1 → B2 →（初审 1~2 天 + 管局 ≤20 工作日）→ B4 ─────┐
              ├─→ C1 → C2 → C3 → C4（本地 Docker 全链路演练）        │
              ├─→ D1 → D2 → D3 → D4                                  │
              ├─→ E1 → E2 → E3 → E4 → F1 → F2 → F3                   │
              └─→ G1 → G2 → G3 → H1 → H2 → H3 → H4 → H5 ─────────────┴→ I1 → I2 → I3 → I4 → J1~J4
```

### 4. 最终验收清单（全部打勾才算上线完成）

- [ ] ECS 99 已购买、Ubuntu 24.04 LTS、备案通过、`gamepouch.cn` 备案号回填后台
- [ ] 第 1 节 P0-1 ~ P0-8 全部修复并本地演练通过
- [ ] `.env.production` 无 `CHANGE_ME`，`.gitignore` 生效，强口令已设置
- [ ] 三容器 healthy，`/healthz` 返回 `"env":"prod"`，生产 mock 防线返回 503
- [ ] Alembic `0002_admin_management` 已应用，schema 自愈校验通过
- [ ] 本地 9 个用户 + 权益 + 云存档 + 审计数据迁移完成，抽样登录成功
- [ ] 公开 API / 账号 / 会员 / 配对 / 云存档 / ConsentGate / Admin 11 页全绿
- [ ] `api.gamepouch.cn` A 记录指向 ECS 且灰云直连，App **零改动**
- [ ] Cloudflare Tunnel 保留 7 天，回滚演练通过
- [ ] 每日 `pg_dump`、云监控告警、续费提醒已配置

### 5. 记录表（执行时填写）

| 项 | 值 | 填写日期 |
|---|---|---|
| ECS 公网 IP | **留空**，只存本地密码管理器 | — |
| 实例 ID / 地域 | | |
| 到期日 / 续费价核实 | 2027-11-04 23:59:59 / 续费价待核实 | 2026-11-04 |
| 备案服务码 / 备案号 | | |
| DNS 切换时间 | | |
| 回滚演练时间 | | |
| 首次 `pg_dump` 备份路径 | | |
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
