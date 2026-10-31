# 设计方案：账号云服务（连接 PC 端服务器）＋ 广告与会员体系

> 本文档为**方案文档，不含任何代码实现**。状态列用于决策与跟踪。
> 约束前提：**发布版不带任何 ROM**（用户须使用自己合法持有的 ROM）。

## 文档信息

| 项 | 值 |
|---|---|
| 版本 | v0.1（初稿，待决策） |
| 日期 | 2026-10-31 |
| 范围 | 账号/云服务架构、广告接入、会员/计费体系 |
| 状态 | 待决策 |

**状态取值说明**：`待决策` / `已采纳-未开始` / `进行中` / `已完成` / `暂缓`

---

## 总览与决策状态

| 模块 | 核心结论 | 决策状态 | 备注 |
|---|---|---|---|
| 一、账号与云服务（连接 PC 端服务器） | PC=用户自托管；云只存用户数据与权益，不分发 ROM | 待决策 | 合规红线：不得变为 ROM 分发渠道 |
| 二、广告 + 会员（7天试用→月/年/终身免广告） | 分平台接入广告与计费；服务端校验权益 | 待决策 | OHOS 必须用华为广告/华为 IAP，非 AdMob |
| 三、落地顺序 | 分三期：账号同步 → 广告 → 会员计费 | 待决策 | 每期独立可交付、可审核 |

---

## 一、账号与云服务（连接 PC 端服务器）设计

### 1. 合规前提（最重要）
发布版不带 ROM，App 定位为"前端播放器 + 个人内容中枢"。**绝不能把"账号云"做成 ROM 分发渠道**，否则重新引入版权风险。
- **PC 服务器 = 用户自己的电脑（自托管）**，不是运营的中心 ROM 库；
- **云端只存"用户数据 + 权益"**，不存、不分发任何 ROM 二进制；
- 商店口径统一为："本应用不提供任何游戏资源，用户须使用自己合法持有的 ROM"。

### 2. 总体架构

```
[Phone App]
 ├─ AccountPage / CloudLibraryPage
 ├─ AccountService ──HTTPS/WS(token)──► [Account Backend 你运营]
 │                                     ├─ 用户认证
 │                                     ├─ 会员权益(entitlement)
 │                                     └─ pairing 注册表(用户↔自己的PC)
 └─ PairingService ──LAN(mDNS/WS)────► [PC Server 用户自托管]
       ├─ ROM 索引(仅元数据/封面，不含ROM本体)
       ├─ 存档/金手指/设置 同步(用户数据)
       └─ (可选)远程中继 relay，用于异地访问自己的PC
```

### 3. 组件职责
- **AccountService（Dart）**：登录、token 管理、拉取 `entitlement`、配对注册。
- **PairingService（Dart + 平台通道）**：LAN 内 mDNS 发现 PC；配对交换一次性 token；之后用账号 token 持久绑定"我的 PC"。
- **PC Server 扩展（`tools/library`）**：在现有局域网服务上加 `/pair`、`/sync/save`、`/sync/settings`、`/library/meta` 等认证端点；ROM 仍只在局域网按需推送到手机，不出公网、不进云。
- **Account Backend（轻量，Node/Python + DB）**：只管用户、配对关系、会员状态，不碰 ROM。

### 4. 连接/发现策略
- **同 LAN**：mDNS 自动发现 + 手动 IP 兜底（沿用现有"手机同步"思路）。
- **异地**：提供**可选中继**（用户开启后，PC↔云只转发该用户自身流量，仍不存 ROM）。默认关闭、需用户同意。

### 5. 云端同步白名单

| 可同步 ✅ | 绝不经云端 ❌ |
|---|---|
| 存档(save states)、设置、金手指库(用户编写) | ROM / BIOS 二进制本体 |
| 播放列表/收藏、元数据索引(标题/封面) | 任何受版权保护内容 |
| 配对关系、会员权益 | |

### 6. 账号页 / 云库页 UI 重塑建议
- **账号页**：身份卡片 + "我的 PC"配对卡（在线/离线、最后同步时间）+ 同步开关 + 会员状态。
- **云库页**：展示**用户自己 PC** 的库（只读浏览 → 一键推送到手机），而非中心 ROM 仓库；离线显示本地缓存的元数据/封面。
- 保留"云"体验（存档/设置随身、PC 库随时可浏览），同时不触碰 ROM 分发红线。

### 7. 与现有代码结构映射
- `OhosPal`/`AndroidPal` 旁新增 `PairingPal`（LAN 发现/WS 收发），平台差异只在这一层。
- `AccountPage` 现有"登录/云库/同步/发现伙伴/OTA"四块，把"云库"从"订阅服务器游戏"改为"我的 PC 库"。
- `tools/library` 现有 `phone_sync.py`/`library_manager.py` 加认证与同步端点即可，无需重写。

### 8. 风控
- 任何 ROM 二进制不得离开用户局域网进入你运营的云端；
- 服务端日志不记录 ROM 路径以外的敏感内容；
- 中继仅转发用户自身加密流量，运营方不可读。

### 模块一 跟踪表

| 子项 | 说明 | 状态 | 备注 |
|---|---|---|---|
| 1 合规前提 | 确立"不自托管 ROM 分发"红线 | 待决策 | |
| 2 总体架构 | 上述拓扑 | 待决策 | |
| 3 AccountService | 登录/token/entitlement | 未开始 | |
| 4 PairingService | mDNS+配对 | 未开始 | |
| 5 PC Server 认证端点 | `/pair` `/sync/*` `/library/meta` | 未开始 | |
| 6 Account Backend | 用户/配对/会员 | 未开始 | |
| 7 UI 重塑 | 账号页/云库页 | 未开始 | |
| 8 风控 | 流量/日志约束 | 未开始 | |

---

## 二、广告 + 会员（7天试用 → 月/年/终身免广告）设计

### 1. 总体架构

```
[Flutter UI]
 ├─ AdService(Dart)
 │    ├─ isAdFree = EntitlementService.isAdFree()
 │    └─ AdPal(接口)
 │         ├─ Android → google_mobile_ads (AdMob)
 │         └─ OHOS    → 华为广告(Petals/HUAWEI Ads) 平台通道
 └─ BillingService(Dart)
      └─ BillingPal(接口)
           ├─ Android → Google Play Billing
           └─ OHOS    → 华为 IAP (IapKit)
      → 服务端校验收据 → 授予 entitlement
```

### 2. 广告接入（必须分平台，关键！）
- **Android**：`google_mobile_ads`（AdMob）——标准。
- **HarmonyOS NEXT**：**没有 GMS**，AdMob 不可用，必须用**华为广告（HUAWEI Ads / Petals Ads）**经平台通道接入。复用现有 `OhosPal`/`AndroidPal` 抽象模式：新增 `AdPal` 接口，两套实现。

### 3. 广告位与频控（体验底线）
- **Banner**：库页底部/列表间隙，常驻但不遮挡操作。
- **Interstitial**：只在**安全断点**触发——退出游戏回库页、完成一次同步后；**绝不在模拟运行中插广告**（性能+体验）。
- **频控**：每会话/每日上限（如 ≤3 次），冷却时间，避免骚扰。
- **Rewarded（可选）**：用于临时解锁某项增强（如额外云存档位），纯自愿。

### 4. 会员/权益模型
- 免费用户：看广告。
- 注册会员：**首次登录起 7 天试用 Premium（免广告）**。
- 试用后：月付 / 年付 / **终身**（一次性，无到期）三档，均免广告，可叠加增值（更多同步位、更大存档备份、远程中继带宽等）。

### 5. 计费与收据校验（分平台）
- Android → **Play Billing**；OHOS → **华为 IAP**。统一包成 `BillingPal`。
- **服务端校验收据**（防作弊）：客户端拿到 purchaseToken/receipt → 发后端验真 → 才写 `entitlement`。本地只缓存结果，不下发权益真相。
- 终身档作为**非消耗型/一次性** SKU 处理。

### 6. 试用 / 过期 / 终身逻辑
- `trialStart` 在首次登录时落库（服务端权威）。
- 判定：`now < trialStart+7d` → 免广告；否则需有效订阅或终身标志。
- 终身：`isLifetime=true`，无 expiry。
- 提供"恢复购买"（restore）。

### 7. entitlement 校验与容错
- `EntitlementService` 持有 `tier / expiry / isLifetime`；**启动时 + App 回到前台时**刷新；
- 校验失败/离线时**默认回退到"显示广告"**，但**绝不锁死 App**（避免误伤付费用户也避免把免费用户卡住）。

### 8. 隐私与商店合规（必做）
- 两个商店都要求**隐私政策 + 广告 SDK 同意**；未成年人用**非个性化广告**或拿同意。
- 订阅需清晰标价、可取消说明、无虚假紧迫感（华为 AppGallery 与 Google Play 均有细则）。
- 模拟器 + 广告属敏感组合，建议默认非个性化，并显著提供退出个性化选项。

### 9. 与现有结构映射
- `lib/pal/` 下新增 `ad_pal.dart`(`AdPal` 接口) + `billing_pal.dart`(`BillingPal` 接口)，实现挂在 `OhosPal`/`AndroidPal` 同体系。
- 新增 `lib/features/membership/`：`entitlement_service.dart`、`ad_service.dart`、`billing_service.dart`。
- `AccountPage` 增加"会员/试用状态/购买"区块；退出游戏的 `exitToLibrary` 流程里接入"到库页时按频控弹 Interstitial"。

### 模块二 跟踪表

| 子项 | 说明 | 状态 | 备注 |
|---|---|---|---|
| 1 总体架构 | 上述拓扑 | 待决策 | |
| 2 AdPal 分平台 | Android AdMob / OHOS 华为广告 | 未开始 | **OHOS 不可用 AdMob** |
| 3 广告位与频控 | Banner/Interstitial/Rewarded + 频控 | 未开始 | 不在模拟中插广告 |
| 4 会员模型 | 免费/7天试用/月/年/终身 | 未开始 | |
| 5 BillingPal 分平台 | Play Billing / 华为 IAP | 未开始 | |
| 6 收据服务端校验 | 防作弊 | 未开始 | |
| 7 试用/过期/终身逻辑 | trialStart 权威 | 未开始 | |
| 8 entitlement 容错 | 失败回退显示广告 | 未开始 | 不锁死 App |
| 9 隐私与商店合规 | 隐私政策/同意/非个性化 | 未开始 | |
| 10 UI 与代码映射 | AccountPage/exitToLibrary 接入 | 未开始 | |

---

## 三、两件事如何咬合 + 落地顺序

账号云与会员是**同一账户体系**：账号后端同时管"我的 PC 配对"和"会员权益"，`EntitlementService` 被广告、云同步增值、远程中继共用。

### 建议分期（每期独立可交付、可审核）

| 期 | 内容 | 状态 | 依赖 | 备注 |
|---|---|---|---|---|
| Phase 1 | 账号 + PC 配对 + 存档/设置同步（不含 ROM 分发） | 待决策 | 无 | 先把"云"做扎实 |
| Phase 2 | 广告接入（AdPal 分平台 + 频控 + 退出游戏断点插广告） | 待决策 | Phase 1 账号体系 | |
| Phase 3 | 会员/计费（BillingPal 分平台 + 7天试用 + 月/年/终身 + 服务端校验） | 待决策 | Phase 1 + Phase 2 | |

---

## 决策记录（供跟踪）

| 日期 | 决策人 | 结论 | 变更说明 |
|---|---|---|---|
| 2026-10-31 | — | 待决策 | 初稿已生成，等待评审 |

---

*本文件为方案文档，未改动任何源码。状态列随决策与实施进度更新。*
