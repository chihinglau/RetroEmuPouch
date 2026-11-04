# 设计方案：账号会话 × 会员权益 × 去广告（权威契约 v0.2）

> 本文档为**方案文档，不含任何代码实现**。它**修订并取代** `design-account-cloud-ads-membership.md` 中"账号会话 / 会员权益 / 去广告"相关条目（原 §一.3、§二.4–§二.7、§二.9）里**与代码事实背离**的部分。
> 合规红线（不自托管 ROM 分发）沿用原文档，不在本文重复。
>
> **撰写缘由（2026-11-02）**：联调中暴露出"退出登录广告不恢复""未登录仍提示购买"等"测一个补一个"的表象，根因是**会员权益与账号会话完全解耦、且存在双账号体系与本地兜底授予**。本文先固化方案，再据此做代码设计。

| 项 | 值 |
|---|---|
| 版本 | v0.2（修订版，已定稿） |
| 日期 | 2026-11-02 |
| 范围 | 账号会话模型、会员权益归属与生命周期、去广告门控、购买安全 |
| 状态 | 方案已定稿，代码已实现并通过联调验证（2026-11-02） |

---

## 0. 总原则（不可妥协）

1. **服务端是权益唯一真相源**。客户端只缓存/反映服务端结论，**绝不自行决定"我有没有会员"**。
2. **权益与账号绑定**。无账号 = 免费；换账号 = 换权益；登出 = 权益回落免费。
3. **购买必须发生在已登录会话内**，且以服务端校验通过为前提；**release 构建下客户端永不本地授予**。
4. **失败/离线安全默认**：宁可显示广告、绝不锁死 App，也绝不"离线白嫖"。

---

## 1. 现状核对（as-is，已与代码逐条比对）

| 维度 | 代码实际 | 与方案背离点 |
|---|---|---|
| 账号体系 | `AccountBackend`（`createAccountBackend()` → `HttpAccountService` / `MockAccountService`）是**唯一在跑**的认证；`AccountService`（本地优先，`account.userId`）是**死代码**，无任何调用方 | 旧文档 §一.3 把两者并列，且 §6 称"本地桩 `MockAccountService`"——实际是按 `kAccountBaseUrl` 切换 Http/Mock |
| 会话信号 | 登录写 `kAccountToken` / `kAccountUserId` / `kAccountUserName`；登出 `remove(kAccountToken)`（用户态清了，但权益没清） | 权益未订阅该信号 |
| 权益存储 | `EntitlementService` 存 `entitlement.tier` 等**设备级全局 key**，不带 user_id | 多账号会串；登出不回落 |
| 试用 | `ensureTrialStarted()` 仅本地写 `trialStart`；**从未调用** `POST /api/billing/trial/start` | 旧文档 §二.4/§二.6 称"服务端权威"，实际未接 |
| 购买 | `BillingService.buy`：`pal.purchase → verifier.verifyPurchase`；**verifier 返回 null 时本地 `grant()` 兜底** | 旧文档 §二.5/§二.7 称"仅缓存、不下发真相"——实际有本地兜底授予（生产隐患） |
| 去广告 | `AdService` 按 `blocksInterstitialAds` / `isAdFree` 门控——逻辑正确 | 但喂给它的是**设备级全局**权益，不是"当前账号"的 |
| 自动刷新 | 仅在 `account_page` 登录时手动 `restore()` 一次；**无 App 回到前台刷新、无定时刷新** | 旧文档 §二.7 称"启动时+回到前台刷新"，实际未做 |
| 多账号 | 不支持（设备级单份） | — |

后端（已正确，无需改或仅需小补）：`Entitlement` 按 `user_id` 唯一；`verify_purchase`（带 `X-Dev-Mock` 可跳过真实商店验真）授予；`start_trial` 服务端单用判定；`GET /api/billing/entitlement` 回读当前用户权益。**需确认该接口返回体含 `trial_start` 与派生标志**，否则客户端无法算试用窗。

---

## 2. 已暴露的漏洞（用户痛点 → 根因）

| # | 表象（用户原话） | 根因 | 性质 |
|---|---|---|---|
| G1 | 退出登录，广告功能没恢复 | 权益设备级全局，登出只清用户态、不动权益 | 设计漏洞 |
| G2 | 未登录还提示"购买终身会员免广告" | 购买入口未与登录态绑定（UI 与 `BillingService` 两层都未强制） | 设计漏洞 |
| G3 | 双账号体系并存（`AccountService` vs `AccountBackend`） | 历史演进遗留，未收敛 | 架构债务 |
| G4 | 试用本地化、服务端无记录 | 客户端从未调 `trial/start` | 设计漏洞 |
| G5 | 权益不随登录态自动联动 | 无"会话↔权益"订阅关系，`account_page` 的 reset/restore 是补丁 | 设计漏洞 |
| G6 | 无 App 回前台 / 定时刷新 → 服务端过期/吊销不感知 | 缺少刷新触发 | 设计漏洞 |
| G7 | `BillingService.buy` 本地兜底授予 | release 下可在无后端时本地发会员 | 安全漏洞 |
| G8 | 多账号串权益（同设备两账号共享一份） | 设备级存储 | 设计漏洞 |

> 注：G1/G2/G5 此前以"登出重置 + 登录恢复 + UI 登录门槛"三处补丁临时缓解，但**根因（设备级全局、无订阅）未消除**，仍有 G3/G4/G6/G7/G8 未覆盖。本文一次性根除。

---

## 3. 目标方案（to-be，权威契约）

### 3.1 账号与会话模型 —— 单一真相源

- **弃用并删除 `AccountService`（本地优先，已确认无任何调用方，属死代码）**。认证只走 `AccountBackend`；其下 `HttpAccountService` / `MockAccountService` 实现不变。
- **会话 = `{userId, token, displayName}`**，持久化键沿用 `kAccountUserId` / `kAccountToken` / `kAccountUserName`。`token` 非空即"已登录"。
- **`AccountBackend` 暴露 `authStateChanges` 流**（登录用户 ↔ null）。登录 / 注册 / 登出 / 注销均 `emit` 新状态。UI 与会员模块订阅此流，不再各自轮询。
- 新增轻量 `AuthSession` 数据类封装上述三元组，取代散落的 `current` 字段。

### 3.2 权益模型 —— 服务端权威 + 客户端按 user_id 缓存

- **客户端缓存 key 改为按用户**：`entitlement.<userId>.tier` / `.expiry_at` / `.is_lifetime` / `.trial_start`。原 `entitlement.*`（设备级扁平键）废弃；**首次启用新方案时清除遗留扁平键**，避免与按用户键混淆（决策 5）。
- `EntitlementService` 内部维护"按 userId 的缓存表 + 一个 `activeUserId`"；对外读取**永远取当前 `activeUserId` 的缓存**，无 active 用户即 `free`。
- **派生规则（纯函数，沿用现有，不改语义）**：`isAdFree`（超级 VIP / 终身 / 试用窗内，完全去广告）、`isVipActive`（普通 VIP 生效中，仅去插屏）、`blocksInterstitialAds`（前两者并集，插屏门控）、`cloudSaveEnabled`（付费档）。横幅单独按 `isAdFree` 显示（普通 VIP 仍见横幅）。
- 服务端字段与客户端 `MembershipTier` 严格对齐（已有 `SKU_MAP` + `tier` 枚举对齐）。

### 3.3 权益生命周期状态机

| 事件 | 行为 |
|---|---|
| **登录 / 注册成功 / 启动自动加载已登录** | `authStateChanges` 收到用户 → `setActiveUser(userId)` → 拉 `GET /api/billing/entitlement` 写入该用户缓存并设为 active（解决"重新登录 → 会员回来"） |
| **登出 / 注销** | `remove(kAccountToken)` + `clearActive()`：内存 active 置 free，**不删除**该用户磁盘缓存（供离线/快速恢复），但 active 立即为免费 |
| **购买成功**（服务端 `verify` 通过） | 用返回体更新当前用户缓存 + active |
| **App 回到前台（resumed）/ 仅前台定时（应用在**前台**时周期刷新；**禁止后台轮询**，规避偷流量嫌疑）/ 网络恢复** | 对 active 用户重新 `GET /api/billing/entitlement`；服务端过期/吊销会自动让 `isAdFree` 翻转为 false → 广告自行恢复（根治 G1/G6） |
| **首次登录** | 调 `POST /api/billing/trial/start`（服务端单用判定，**开启试用**；若登录时离线则延后重试，下次在线刷新即反映），用返回体反映试用窗；**客户端不再以本地 `ensureTrialStarted` 作为授予依据**（根治 G4） |
| **离线 / 拉取失败** | 保留上次缓存（付费用户不被锁死）；标记 `stale` 并安排重试；连续失败超过宽限 → 安全回落显示广告，**绝不本地授予**（根治 G7） |

### 3.4 去广告门控规则

- `AdService` 门控逻辑**保持不变**，但其注入的 `EntitlementService` 必须是"当前 active 用户"的那一份（已由 3.2 保证）。
- 插屏：`!blocksInterstitialAds` 才显示；频控 `每日≤3 + 冷却 1min` 保留。
- 横幅：`!isAdFree` 才显示（普通 VIP 留横幅）。`NoOpAdPal` 占位条仍始终显示以便布局走查（既有规则）。
- 服务端过期 → 3.3 自动刷新翻转 `isAdFree` → 广告自动恢复，无需手动。

### 3.5 购买与收据校验安全规则

- **`BillingService.buy` / `restore` 入口加会话守卫**：未登录直接 return false 并提示"请先登录"（G2 在逻辑层根除，不止 UI）。
- **release 构建**：`ReceiptVerifier` 走真实商店 + 服务端验真；**成功后权益来自服务端返回，客户端绝不本地 `grant`**。删除现有的"verifier 返回 null → 本地兜底授予"分支（G7）。
- **debug + 真实后端（联调）**：`DebugSuccessBillingPal`（模拟商店成功）+ `HttpReceiptVerifier`（`X-Dev-Mock: 1`，返回服务端权威权益）。此组合**仅在 `kDebugMode` 下启用**，release 不可达。
- 终身档按非消耗型/一次性 SKU 处理（既有 `is_lifetime`）。

### 3.6 多账号隔离

- 缓存按 `userId` 分桶（3.2）。即便未来支持切换账号，加载的是该账号自己的缓存，互不串（根治 G8）。

### 3.7 离线 / 失败容错

- 拉取失败：保缓存、标 stale、重试；超宽限回落广告，不锁死。
- 任何异常路径都不调用本地 `grant` 发权益。

---

## 4. 与旧文档冲突点的修订声明

| 旧文档条目 | 原表述 | 本文修订 |
|---|---|---|
| §一.3 / §6 | `AccountService` 与 `AccountBackend` 并列；称"本地桩 `MockAccountService`" | 认证唯一走 `AccountBackend`；`AccountService` 死代码，弃用并删除（G3） |
| §二.4 / §二.6 | 试用"服务端权威、首次登录落库" | 客户端当前**未调** `trial/start`；本文 3.3 明确必须调（G4） |
| §二.5 / §二.7 | "服务端校验收据；本地只缓存结果，不下发真相" | 当前 `BillingService.buy` 有本地兜底授予；本文 3.5 删除该分支（G7） |
| §二.7 | "启动时 + App 回到前台刷新" | 当前未实现；本文 3.3 补刷新触发（G6） |
| §二（隐含） | 权益设备本地 | 改为按 user_id 缓存 + active 选择（G1/G5/G8） |

> **三份文档冲突裁决（2026-11-04 裁定）**：本文修订 `design-account-cloud-ads-membership.md` 的背离项；但若与 `design-account-backend.md`（**权威源**）冲突，以 `design-account-backend.md` 为准，且**文档与代码冲突以代码为最终裁定**。三份文档状态表以 `design-account-backend.md`「实施进度 / 客户端对接完成状态」一节（2026-11-04 真实落地）为同步依据。

---

## 5. 代码设计蓝图（仅设计，待确认后实现）

> 以下为改动点清单与职责，**不在此写实现代码**。

1. **`account_backend.dart` + `http_account.dart` + `mock_account.dart`**
   - 新增 `AuthSession { userId, token, displayName }`。
   - `AccountBackend` 增加 `Stream<AuthSession?> get authStateChanges`；`login/register/logout/deregister` 在状态变更后 `emit`。
   - `current` 改为由流驱动（或保留但作为流的最新值）。

2. **`entitlement_service.dart`**
   - 缓存 key 改 `entitlement.<userId>.*`；内部 `Map<userId, Entitlement>` + `String? _activeUserId`。
   - 新增 `setActiveUser(userId)` / `clearActive()` / `refreshFromServer()`（调 `GET /api/billing/entitlement`）。
   - `current` getter 返回 active 用户缓存或 `free`。
   - 本地 `grant()` 仅保留给 debug verifier 路径；生产购买路径改为"服务端返回 → 写入缓存"，不经 `grant` 兜底。
   - **迁移**：`_load` 时若发现遗留扁平键 `entitlement.tier`（无 userId）则清除。

3. **`membership.dart`**
   - `instance` 构造后**订阅 `authStateChanges`**：登录→`setActiveUser`+`refreshFromServer`；登出→`clearActive`。这是"会话↔权益"唯一接线点，取代 `account_page` 里的散装 reset/restore 补丁。

4. **`billing_service.dart`**
   - `buy()` / `restore()` 开头加 `if (session == null) return false`。
   - 删除 release 下的本地兜底 `grant` 分支；debug 路径由 `HttpReceiptVerifier` 返回服务端权益后写入缓存。

5. **`ad_service.dart`**
   - 逻辑不变；确保注入的是"active 用户"权益（3.2 已保证）。

6. **`account_page.dart`**
   - 移除先前临时加的 `_resetEntitlement` / `_restoreEntitlement`（由 `membership` 统一订阅取代，避免双份逻辑）。
   - 登录/登出仅操作 `AccountBackend`，权益联动交给订阅。

7. **`settings_sheet.dart` / `membership_card.dart`**
   - 保留"未登录显示登录提示、拦截购买/试用"的门槛；登录态改为订阅 `authStateChanges`（而非一次性读取），登出即时变提示、登录即时出按钮。

8. **`http_account.dart`**
   - 登录成功后调 `POST /api/billing/trial/start`（失败可重试/延后），用返回体刷新试用态。
   - 复用既有回环自签放行的 debug 逻辑。

9. **后端（小补，非必须）**
   - 确认 `GET /api/billing/entitlement` 响应含 `trial_start` 及派生标志，供客户端算试用窗。模型本身已 per-user，无需结构改动。

### 5.10 关键类型与数据流（代码设计细化）

```dart
// account_backend.dart
class AuthSession {
  final AccountUser user;
  final String token;          // = kAccountToken，登录态唯一信号
  AuthSession(this.user, this.token);
}

abstract class AccountBackend {
  AuthSession? get session;
  Stream<AuthSession?> get authStateChanges;   // 登录/登出/注销/加载后 emit
  Future<AccountUser> login(...);
  Future<AccountUser> register(...);
  Future<void> logout();
  Future<void> deregister();
}

// entitlement_service.dart
class EntitlementService {
  // 内部：Map<String, Entitlement> _byUser + String? _activeUserId
  Entitlement get current;        // _activeUserId==null ? free : _byUser[_activeUserId]
  Future<void> setActiveUser(String userId);   // 切到该用户缓存并 emit
  Future<void> clearActive();                  // active=null（登出→免费）并 emit
  Future<void> refreshFromServer();            // GET /api/billing/entitlement → 写 _byUser[active]
  Future<void> applyServer(Entitlement e);     // 购买/试用成功后写当前用户并 emit
  // 遗留扁平键迁移：_load 时若发现 entitlement.tier（无 userId）则 remove
}

// membership.dart（会话↔权益唯一接线点）
// await _svc.authStateChanges.listen((s) {
//   if (s == null) { entitlement.clearActive(); }
//   else { entitlement.setActiveUser(s.user.id); entitlement.refreshFromServer(); }
// });
// AppLifecycleState.resumed / 前台 Timer → entitlement.refreshFromServer()  // 仅前台
```

**数据流**：登录 → `authStateChanges` 发射 → `Membership` 订阅 → `setActiveUser` + `refreshFromServer` → `AdService`/会员页经 `entitlement.changes` 自动刷新。登出 → `clearActive` → `free` → 广告恢复（根治 G1）。购买 → `billing.buy`（会话守卫）→ 后端 `verify` → `applyServer` → 即时反映（根治 G2/G7）。回前台 → `refreshFromServer` → 服务端过期自动恢复广告（根治 G6）。

---

## 6. 落地分期（每期可独立验证）

| 期 | 内容 | 解决漏洞 |
|---|---|---|
| P1 | 收敛账号体系：`AuthSession` + `authStateChanges`；弃用并删除 `AccountService` | G3 |
| P2 | 权益按 user_id 缓存 + active 选择 + 订阅联动（登录取/登出清/回前台刷新） | G1/G5/G6/G8 |
| P3 | 试用接入 `trial/start`；购买会话守卫 + 删除 release 本地兜底授予 | G2/G4/G7 |
| P4 | UI 门槛改订阅驱动；联调回归（debug 后端走通各档） | 全 |

---

## 7. 决策记录（2026-11-02 用户拍板）

| # | 问题 | 决策 |
|---|---|---|
| 1 | `AccountService` 删还是弃用 | **弃用并删除**（无调用方，死代码） |
| 2 | 按 user_id 缓存策略 | **保留磁盘缓存作离线兜底**（付费用户离线不被锁死） |
| 3 | 首次登录 `trial/start` 若离线 | **开启试用**；离线则延后重试，下次在线刷新即反映 |
| 4 | 自动刷新节奏 | **仅前台刷新**（回前台 + 前台定时）；**禁止后台轮询**，规避偷流量嫌疑 |
| 5 | 旧设备级 `entitlement.*` | **升级时清除**遗留扁平键 |

---

## 8. 跟踪表

| 子项 | 说明 | 状态 | 对应漏洞 |
|---|---|---|---|
| 1 会话模型单一化 | `AuthSession` + `authStateChanges`；弃 `AccountService` | 已实现 | G3 |
| 2 权益按 user_id 缓存 | key 改 `entitlement.<userId>.*` + active 选择 | 已实现 | G1/G5/G8 |
| 3 会话↔权益订阅 | `Membership` 订阅登录/登出/刷新 | 已实现 | G5/G6 |
| 4 试用服务端化 | 登录调 `trial/start` | 已实现 | G4 |
| 5 购买安全 | 会话守卫 + 删 release 本地兜底授予 | 已实现 | G2/G7 |
| 6 自动刷新 | 回前台拉 `entitlement`（仅前台，无后台轮询） | 已实现 | G6 |
| 7 UI 门槛订阅化 | 登录态驱动购买/试用入口 | 已实现 | G2 |

---

*本文件为方案文档，未改动任何源码。状态随决策与实施进度更新。*
