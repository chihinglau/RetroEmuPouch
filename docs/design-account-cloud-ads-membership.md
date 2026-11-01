# 设计方案：账号云服务（连接 PC 端服务器）＋ 广告与会员体系

> 本文档为**方案文档，不含任何代码实现**。状态列用于决策与跟踪。
> 约束前提：**发布版不带任何 ROM**（用户须使用自己合法持有的 ROM）。

## 文档信息

| 项 | 值 |
|---|---|
| 版本 | v0.1（初稿，待决策） |
| 日期 | 2026-10-31 |
| 范围 | 账号/云服务架构、广告接入、会员/计费体系 |
| 状态 | 已采纳-进行中（骨架） |

**状态取值说明**：`待决策` / `已采纳-未开始` / `进行中` / `已完成` / `暂缓`

---

## 总览与决策状态

| 模块 | 核心结论 | 决策状态 | 备注 |
|---|---|---|---|
| 一、账号与云服务（连接 PC 端服务器） | PC=用户自托管；云只存用户数据与权益，不分发 ROM | 已采纳-进行中（骨架） | 合规红线：不得变为 ROM 分发渠道 |
| 二、广告 + 会员（7天试用→月/年/终身免广告） | 分平台接入广告与计费；服务端校验权益 | 已采纳-进行中（骨架） | OHOS 必须用华为广告/华为 IAP，非 AdMob |
| 三、落地顺序 | 分三期：账号同步 → 广告 → 会员计费 | 已采纳-进行中（骨架） | 每期独立可交付、可审核 |

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
| 1 合规前提 | 确立"不自托管 ROM 分发"红线 | 已采纳-进行中（骨架） | |
| 2 总体架构 | 上述拓扑 | 已采纳-进行中（骨架） | |
| 3 AccountService | 登录/token/entitlement | 未开始 | |
| 4 PairingService | mDNS+配对 | 已采纳-进行中（骨架 + mDNS 已接） | 配对已有；mDNS 走纯 Dart `multicast_dns`（`_retroemupouch._tcp.local`），UDP 广播作兜底 |
| 5 PC Server 认证端点 | `/pair` `/sync/save` `/sync/settings` `/library/meta` | 已完成（骨架） | 已加 /pair、/sync/save、/sync/settings；PC 端新增 mDNS 广播（zeroconf，缺依赖自动降级为仅 UDP） |
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
| 1 总体架构 | 上述拓扑 | 已采纳-进行中（骨架） | |
| 2 AdPal 分平台 | Android AdMob / OHOS 华为广告 | 进行中（Android AdMob 测试ID已接 + **Android APK 已构建验证**；OHOS 待 HMS 签名+广告位ID） | **OHOS 不可用 AdMob**，走华为/Petals Ads（原生通道，待接入） |
| 3 广告位与频控 | Banner/Interstitial/Rewarded + 频控 | 进行中（Interstitial+退出游戏断点已接；Banner 已接；频控=每日≤3+冷却1min；Rewarded 未做） | 不在模拟运行中插广告 |
| 4 会员模型 | 免费/7天试用/月/年/终身 | 已完成（骨架：`Entitlement`+`EntitlementService` 本地持久化、7天试用 `ensureTrialStarted`、`isAdFree`/`effectiveTier` 判定、新增 `cloudSaveEnabled` 云存档权益） | 真实权益由后端下发（Phase 3） |
| 5 BillingPal 分平台 | Play Billing / 华为 IAP | 进行中（接口 `BillingPal`+`BillingService`+SKU 映射+本地授予已接；`createBillingPal()` 已标注 Android/OHOS 真实实现接入点） | **真实 Play Billing/华为 IAP 待商店配置 + 凭证（Phase 3）** |
| 6 收据服务端校验 | 防作弊 | 已接（骨架：`ReceiptVerifier` 接口 + `NoOpReceiptVerifier` seam，`BillingService` 先校验后授予、无后端时本地兜底） | 真实后端校验端点待 Phase 3 |
| 7 试用/过期/终身逻辑 | trialStart 权威 | 已完成（`Entitlement.isAdFree`：终身/有效订阅/7天试用窗内均免广告；过窗降级 free；终身无到期） | |
| 8 entitlement 容错 | 失败回退显示广告 | 已接（AdService 按 isAdFree 门控 + 失败默认显示广告不锁死；后端校验待 Phase 3） | 不锁死 App |
| 9 隐私与商店合规 | 隐私政策/同意/非个性化 | 暂缓（非个性化默认/同意 UI 待 Phase 3，与真实 AdMob/HMS 广告一起） | |
| 10 UI 与代码映射 | AccountPage/exitToLibrary 接入 | 已完成（`MembershipSection` 已嵌入 `AccountPage`：状态/7天试用/月年终身购买/云存档权益展示） | |

---

## 三、两件事如何咬合 + 落地顺序

账号云与会员是**同一账户体系**：账号后端同时管"我的 PC 配对"和"会员权益"，`EntitlementService` 被广告、云同步增值、远程中继共用。

### 建议分期（每期独立可交付、可审核）

| 期 | 内容 | 状态 | 依赖 | 备注 |
|---|---|---|---|---|
| Phase 1 | 账号 + PC 配对 + 存档/设置同步（不含 ROM 分发） | 已采纳-进行中（骨架） | 无 | 先把"云"做扎实 |
| Phase 2 | 广告接入（AdPal 分平台 + 频控 + 退出游戏断点插广告） | 进行中（Android AdMob 测试ID+退出断点+频控已接；OHOS 待华为广告） | Phase 1 账号体系 | |
| Phase 3 | 会员/计费（BillingPal 分平台 + 7天试用 + 月/年/终身 + 服务端校验） | 已采纳-进行中（骨架） | Phase 1 + Phase 2 | |

---

## 实施进度（截至 2026-10-31）

已按方案落地**共享骨架**（全部以 `NoOp` 安全默认实现，应用仍可编译/运行，不依赖原生广告/计费 SDK 与后端）：

- **账号/配对骨架**：`AccountService`（本地登录态）、`PairingService`（本地已配对 PC 记录，自托管模型）。
- **会员/权益骨架**：`EntitlementService`（7 天试用、月/年/终身档、isAdFree 判定与本地持久化）、`MembershipTier` 枚举。
- **广告骨架**：`AdPal` 接口 + `AdService`（按 isAdFree 与每日上限频控门控）。
- **计费骨架**：`BillingPal` 接口 + `BillingService`（档位→SKU 映射，本地授予，待后端校验）。
- **UI 接入**：`AccountPage` 新增「会员 / 去广告」区块（`MembershipSection`），可触发试用/购买（当前 NoOp 返回 false，待接原生）。
- 编译验证：`flutter analyze` 0 错误（其余为既有 warning/info）。
- **Phase 1 存档/设置同步（2026-10-31）**：PC 服务端 `peer_host.py` 新增 `/api/peer/sync/save`（列表/上传/下载，仅用户存档、不含 ROM/BIOS，带路径穿越防护与 CRC 校验）与 `/api/peer/sync/settings`（GET/PUT JSON）；`peer_client.dart` 新增 `listSaves/uploadSave/downloadSaveFile/getSettings/putSettings` 及 PUT 辅助；配套 `test_peer_sync.py` 单测全绿。
- **Phase 1 UI 接入（2026-10-31，选项 B）**：`AccountPage` 新增「我的 PC（局域网存档/设置同步）」区块（`MyPcSection` + `MyPcService`，位于 `features/account/`）；从 `PeerStore` 读取已配对 PC，经 `PeerClient` 调用上一阶段的 `/sync/save`、`/sync/settings` 端点，提供「上传/下载设置」「上传/下载存档」四个按钮（凭据缺失时禁用并提示重新配对）；含 host 端单测 `my_pc_service_test.dart`（3/3 绿）。后端账号校验、原生广告/计费为后续阶段。
- **重命名 gamepouch→retroemupouch（2026-10-31）**：Dart 包名 `gamepouch`→`retroemupouch`（`pubspec` `name` + 全部 `package:gamepouch/` 导入共 5 处）、`oh-package.json5` 名称同步；应用显示名 `app_name` 本就为 `RetroEmuPouch`；OS `bundleName` 已改 `com.gamepouch.gamepouch`→`com.retroemupouch.app`（彻底对齐 Android），DevEco 自动签名证书绑定旧包名、需重签——**已重签完成**。真机 E2E（2026-10-31）：`build-hap.ps1` 用新证书出 `entry-default-signed.hap`（200MB）、`hdc uninstall com.gamepouch.gamepouch`（旧包名残留）+ `hdc install -r` 新 HAP（install=0）、`aa start -b com.retroemupouch.app` 启动成功，`aa dump` 确认 `com.retroemupouch.app:entry:EntryAbility` 前台运行、截图 168KB。注意换包名=全新沙盒，旧 ROM/存档/金手指需重新导入（PC `phone_sync.py`/peer 同步可快速灌回）。

- **导出游戏资源包：OOM 闪退 + 中文乱码修复（2026-10-31）**：根因为 `archive` 3.6.1 的 `ZipEncoder.addFile` 会把整份 ROM `bytes.toUint8List()` + `Deflate().getBytes()` **全量读入内存**，大 ROM 直接 OOM 被系统杀进程（闪退）；原代码注释误称"流式"并不成立。改为自研真正流式 ZIP 写出（`_streamZip`，位于 `data/package/game_package.dart`）：分块读源文件、增量算 CRC32、`ZLibCodec(raw:true)` 分块原始 deflate 直接落盘，峰值内存≈一个 chunk（~64KB），与 ROM 大小无关；ZIP 条目名/内容均 UTF-8 且置 UTF-8 标志位，避免中文乱码（同类 Latin-1-over-UTF-8 在导入侧用 `repairJsonMojibake` 兜底）。新增 `test/features/library/game_package_test.dart`（2MB 中文名 ROM+存档 导出→导入 往返，断言无乱码、可解包、字节一致）绿；`flutter analyze` 无新增 issue，原 8/8 单测仍绿。端到端实测：服务端同步逻辑 + Dart 客户端解析/就绪判定均绿，App 真机启动正常；应用内「我的PC」同步按钮需在手机「发现伙伴」与该 PC 配对后手动点按（hdc 无法可靠点 Flutter，步骤见下）。

- **Phase 1 收尾：LAN mDNS 发现（2026-11-01）**：在 `tools/library/peer_host.py` 的 `PeerHost` 新增 mDNS 广播（`_retroemupouch._tcp.local`，zeroconf，缺依赖自动降级为仅 UDP），并加 `run_peer_server.py --no-mdns` 开关；App 侧新建 `lib/pal/pairing_pal.dart`（`PairingPal` 接口 + `MdnsPairingPal` 纯 Dart 实现 + `NoOpPairingPal`），在 `PeersController.refresh()` 合并 mDNS 发现的 PC（与现有 UDP 广播并存，互为兜底）；新增依赖 `multicast_dns`。设备端 E2E 需在手机「发现伙伴」连同一 Wi-Fi 的真机验证（当前设备离线，未跑）。
- **Phase 2 广告接入：Android AdMob（2026-11-01）**：`lib/pal/ad_pal.dart` 新增 `GoogleMobileAdsAdPal`（`google_mobile_ads`，默认 **Google 测试广告位 ID**，真实 ID 待发布时替换），`createAdPal()` 按 `Platform.operatingSystem` 在 Android 走 AdMob、OHOS 走 `NoOpAdPal`（华为/Petals Ads 待 HMS 签名+广告位 ID）；`AdService` 频控升级为「每日≤3 + 冷却 1min + 跨会话按日重置」。`LibraryPage` 接入**安全断点**：退出游戏回库页（`didChangeAppLifecycleState.resumed`）经 `AdService.maybeShowInterstitial()` 弹插屏（绝不在模拟运行中插广告），并在库页底部挂载 `bannerWidget()` 横幅。新增依赖 `google_mobile_ads`；AndroidManifest 加 AdMob APP_ID（测试 ID）。OHOS 因 NoOp 对该平台完全无副作用；真机 E2E（Android 调试 + OHOS 华为广告）待凭证与设备。
- **Phase 2 验证：Android APK 构建打通（2026-11-01）**：此前卡在 Gradle 配置阶段，根因有二——(1) `gradle.properties` 设 `android.builtInKotlin=false`（AGP 9.x 不再内置 Kotlin），但 `app/android/app/build.gradle.kts` 的 `plugins{}` 漏 apply `org.jetbrains.kotlin.android`，导致 `kotlin { compilerOptions { jvmTarget } }` 解析失败（`Unresolved reference: compilerOptions/jvmTarget`）；补上后通过。(2) `google_mobile_ads 5.3.1` 的 `android/build.gradle` 用了 `configurations.all` 属性访问（Gradle 9.x 已移除该 API，报 `Could not get unknown property 'all'`）；升级到 `^9.2.0`（Flutter 3.41.10 满足其 SDK 约束，`flutter analyze` 0 error、Dart 侧 API 无破坏）后插件脚本兼容 Gradle 9。`flutter build apk --debug --flavor store` 现已成功产出 `app-store-debug.apk`（约 250MB，含全部原生内核），并 `adb install` 到已连接 Android 设备（OXF AN10，Android 12 arm64）成功。构建链路打通，后续改动可用该命令做 Android 侧回归。

- **Phase 3 会员/计费客户端骨架（2026-11-01）**：无需外部凭证即可落地的纯客户端骨架已补齐并接线。既有骨架（`EntitlementService`/`BillingService`/`AdService`/`Membership` 单例/`MembershipSection` 已嵌入 `AccountPage`）经核验已完整接线。`Entitlement` 新增 `cloudSaveEnabled`（付费档解锁云存档权益，免费/试用仅本地 LAN 同步）；新增 `ReceiptVerifier` 接口 + `NoOpReceiptVerifier`（后端收据校验接入点 seam），`BillingService` 改「先 `BillingPal` 购买 → 再 `ReceiptVerifier` 校验 → 授予 entitlement」，无后端时本地兜底（标 TODO(server)）；`createBillingPal()` 标注 Android `PlayBillingPal` / OHOS `HuaweiIapPal` 真实实现接入点；`MembershipSection` 展示云存档权益状态。新增单测 `test/features/membership/entitlement_test.dart`（10/10 绿，覆盖 isAdFree/cloudSaveEnabled/effectiveTier/试用窗）；`flutter analyze` 0 error，无新增依赖。

**待办（下一阶段）**：OHOS 华为/Petals 广告原生通道、Play Billing / 华为 IAP（商店配置+凭证）、后端账号与收据校验（会员/计费客户端骨架已完成，真实计费与后端校验待 Phase 3 凭证）。

## 决策记录（供跟踪）

| 日期 | 决策人 | 结论 | 变更说明 |
|---|---|---|---|
| 2026-10-31 | 实施者 | 已采纳并开始实施 | 方案采纳；账号/广告/会员骨架已实现（NoOp 默认，待接原生广告/计费与后端校验） |
| 2026-11-01 | 实施者 | Phase 1 收尾：LAN mDNS 发现 | 新增 PC 端 mDNS 广播 + App 侧 `PairingPal`(multicast_dns)；自托管配对闭环打通（UDP/mDNS 双通道） |
| 2026-11-01 | 实施者 | Phase 2 广告接入：Android AdMob | `google_mobile_ads` + Google 测试广告位 ID 接 Android 插屏/横幅；`createAdPal()` 按平台分流，OHOS 暂 NoOp（华为广告待 HMS）；退出游戏断点 + 频控（每日≤3+冷却1min） |
| 2026-11-01 | 实施者 | Bug 修复：OHOS 金手指无法启用 | `gpretro.cpp` `GetCheats` 原读 `g_filesDir(=appRoot/roms)/library/cheats.json`（路径错，应为 `g_appDir(=appRoot)/library/`），且只读 `cheats.json` 不读 `cloud_cheats.json`；PC 下载的金手指落在 `cloud_cheats.json` 故永远「本游戏暂无金手指」。改为用 `g_appDir` 并合并 `cloud_cheats.json` 兜底（Android `CheatStore.load` 同语义）。Switch/Choice 两类均经此路径修复。 |
| 2026-11-01 | 实施者 | Phase 2 验证：Android APK 构建打通 | 卡点二修复：`build.gradle.kts` 漏 apply `org.jetbrains.kotlin.android`（配 `android.builtInKotlin=false` 必现 DSL 解析失败）；`google_mobile_ads` 5.3.1→9.2.0（Gradle 9 移除 `configurations.all` 属性访问致插件脚本报错）。`flutter build apk --debug --flavor store` 产出 `app-store-debug.apk`（~250MB）并 `adb install` 到 OXF AN10 成功。 |

---

*本文件为方案文档，未改动任何源码。状态列随决策与实施进度更新。*
