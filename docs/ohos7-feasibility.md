# 趣玩匣（GamePouch）鸿蒙 7（OpenHarmony API 26）构建可行性评估报告

> **评估日期**：2026-10-19
> **评估对象**：从当前 Android 源码构建 HarmonyOS NEXT / OpenHarmony 7 版本应用
> **硬性约束**：新增鸿蒙构建流程**不得对现有 Android 版本的编译、构建、调试产生任何影响**
> **本地环境**：DevEco Studio `DS-261.23567.138.36.2600851`（`D:\HuaWei\DevEco-Studio`），
> SDK 位于 `D:\HuaWei\Sdk`（含 `12` 与 `26.0.0` 两套），真机 **Pura 70（HBN-AL00）** 已通过 hdc 连接。
> **文档定位**：评估结论与架构设计，**不含逐步编码教程**。

---

## 0. 结论速览

| 维度 | 结论 |
|---|---|
| **总体可行性** | ❌ **当前不可"直接构建"**；✅ **架构可支撑"移植"** |
| **项目定性** | 这不是"加一套构建配置"，而是**一次完整的新平台移植**（new platform porting） |
| **纯 Dart 业务层** | ✅ **高度可复用（约 90%+）**——库管理、资源包、金手指、存档、联机协议、搜索、设置模型均平台无关 |
| **架构设计** | ✅ `PlatformPal` 抽象层设计正确，是本次移植最关键的既有资产 |
| **工具链** | 🟠 **可解决断层**：已装 flutter_ohos = Flutter 3.22.0 / Dart 3.4（OpenHarmony 官方 fork，非 Google 原版，故**不能**直接换成 Android 侧 3.47.5）；但上游 fork 已有 **3.27.5 / 3.35.8 / 3.41.10（稳定）与 3.44.9（canary）**，需换新版 fork 并按其真实 Dart 下限放宽 `pubspec` 的 `sdk:` 约束 |
| **原生能力** | 🟠 **缺口**：API 26 的 Native 工具链（llvm/sysroot/cmake）**已安装**（`Sdk\26.0.0\native`），核心可交叉编译；7174 行 Kotlin 需重写 |
| **推荐决策** | **先做 P0 工具链可行性验证（Go/No-Go）**，验证通过再立项；不建议在现有工具链上直接开工 |
| **工期粗估** | P0–P2（最小可玩）4–8 周；完整到可上架 3–5 个月（单人，含 OHOS 学习曲线） |

---

## 1. 可行性结论

### 1.1 有利因素（架构层面已具备移植基础）

| # | 既有资产 | 对移植的价值 |
|---|---|---|
| 1 | **`PlatformPal` 抽象接口**（`app/lib/pal/platform_pal.dart`，44 个接口成员） | ⭐⭐⭐⭐⭐ 最关键的资产。平台差异已被收敛到单一接口，新增 `OhosPal` 即可，业务层零改动 |
| 2 | **纯 Dart 业务层** | ROM 库索引、资源包打包/解包（`archive`）、金手指、存档扫描、联机 Dart 信令、多人白名单、搜索、设置模型——全部平台无关 |
| 3 | **原生核心为平台无关 C/C++** | `third_party/` 五个 libretro 核心 + MAME 源码本身与 OS 无关，只需替换交叉编译工具链 |
| 4 | **`AppChannel`（store / community）渠道抽象** | 上架合规维度可直接扩展到鸿蒙渠道 |
| 5 | **`use-env.ps1 -Ohos` 开关已存在** | 环境隔离的雏形已有（独立 `PUB_CACHE`、`DEVECO_SDK_HOME`），扩展成本低 |
| 6 | **不内置 ROM/BIOS 的合规设计** | 鸿蒙应用市场同样敏感，既有合规策略可直接复用 |

### 1.2 阻断因素（必须先解除，否则无法开工）

| # | 阻断项 | 证据 | 严重度 |
|---|---|---|---|
| **B1** | **Flutter OHOS SDK 版本断层（可解决）** | 本机 `flutter_ohos` = **Flutter 3.22.0 / Dart 3.4.0**（来自 `atomgit.com/openharmony-tpc/flutter_flutter.git`，OpenHarmony 官方 fork；`0.0.0-unknown` 只是其 `version` 文件占位串，实际是 3.22.0）；而 Android 侧为 **Flutter 3.47.5**，项目 `pubspec.yaml` 要求 **`sdk: ^3.13.4`**。⚠️ **不能**把 flutter_ohos 直接换成 Android 的 3.47.5——那是 Google 原版，无 `ohos` 构建目标。但上游 fork 已发布更高版本：**3.27.5 / 3.35.8 / 3.41.10（稳定）/ 3.44.9（canary）**。 | 🟠 **可解决**（换新版 fork + 放宽 `sdk:` 约束） |
| **B2** | **项目自身已记录该断层** | `docs/skills.md:592`：「需要 Dart SDK ≥3.13（Flutter ≥3.27）才能编译；本机只有 OpenHarmony 版 Flutter 3.22（Dart 3.4），**无法在此重编**，代码已就绪待合适 SDK 构建」——该记录在旧 fork(3.22/Dart 3.4) 下成立；换到新 fork 后需复核。 | 🟠 已确认（随 B1 缓解） |
| **B3** | **API 26 Native 工具链（已解决 ✅）** | 目标设备为 **OpenHarmony 7.0.0.105 / API 26**；`D:\HuaWei\Sdk\26.0.0\native` 已含 **llvm / sysroot / build-tools/cmake**（2026-10 复核确认），MAME / libretro 核心可面向 API 26 交叉编译。 | ✅ 已解决 |
| **B4** | **无鸿蒙工程、无 `OhosPal`** | 仓库内不存在 `ohos/` 目录；`app/lib/pal/` 下**只有 `platform_pal.dart` 一个文件**，其中仅有 `AndroidPal` 一个实现类 | 🔴 需从零新建 |
| **B5** | **7174 行 Kotlin 平台代码需重写** | 见 §2.2 | 🟠 工作量主力 |
| **B6** | **插件生态需 OHOS 适配版** | `shared_preferences`（^2.3.0）、`flutter_secure_storage`（^11.2.0）均含平台实现；`archive`/`path` 为纯 Dart 无碍 | 🟠 |

> **B1 的直接后果（针对已装的 3.22 fork）**：以 Dart 3.4 的 SDK 执行 `flutter pub get` 会因 `environment: sdk: ^3.13.4` 约束**直接失败**——不是"编译报错"，而是**依赖解析阶段就通不过**。因此"直接构建"在**当前已装的**工具链下不成立；换成新 fork + 放宽 `sdk:` 后可解除。

---

## 2. 需要调整或重构的模块清单

### 2.1 可复用（无需改动）

| 模块 | 路径 | 说明 |
|---|---|---|
| ROM 库索引与扫描 | `app/lib/data/rom_library.dart` | 纯 Dart + `dart:io` |
| 资源包打包/导入 | `app/lib/data/package/game_package.dart` | `archive` 纯 Dart |
| 金手指 / 招式 | `app/lib/data/cheat/*` | 纯 Dart |
| 存档扫描 | `app/lib/data/play/library_search.dart` | 纯 Dart |
| 联机 Dart 信令层 | `app/lib/data/peer/*` | 纯 Dart（HTTP + 锁步协议） |
| 多人白名单 | `app/lib/data/play/multiplayer_catalog.dart` + `assets/data/multiplayer.json` | 离线资产 |
| 设置模型 | `app/lib/features/settings/app_settings.dart` | 纯 Dart |
| 全部 UI 页面 | `app/lib/features/**` | Flutter Widget，理论可复用（需验证 OHOS Flutter 的 Material3/渲染兼容） |
| 渠道抽象 | `app/lib/config/app_channel.dart` | 纯 Dart |
| 原生核心源码 | `third_party/*`（95.7 MB） | 平台无关 C/C++ |

### 2.2 需新建 / 重写（平台层，工作量主力）

| 模块 | 现状（Android） | 鸿蒙侧对应 | 工作量 |
|---|---|---|---|
| **PAL 实现** | `AndroidPal`（25 个 MethodChannel 调用点，4 个通道：`gs/storage`、`gs/emulator`、`gs/updater`、`gs/netplay`） | 新建 `OhosPal`，基于 **NAPI** 重写全部 44 个接口成员 | 大 |
| **模拟器宿主 Activity** | `EmulatorActivity.kt`（**2769 行**：GL 渲染、核心生命周期、联机会话、手柄注入、快进/存档） | ArkTS 宿主 + **XComponent** 渲染 + NAPI 桥接 | **极大** |
| **虚拟手柄** | `VirtualPadView.kt`（**1747 行**：自绘摇杆/十字键/ABXY、缩放平移、多点触控） | ArkTS 自绘组件或 NAPI 自绘（需重写触控与绘制） | 大 |
| **文件选择器** | `MainActivity.kt`（**824 行**：SAF `ACTION_OPEN_DOCUMENT/CREATE_DOCUMENT` 导入导出 ROM/资源包/BIOS/手柄配置） | OHOS **系统文件选择器（FilePicker / DocumentViewPicker）** 语义与 SAF 不同，需重写交互与结果解析 | 中 |
| **BIOS 镜像管理** | `LockedRom.kt`（551 行） | 需 NAPI 等价实现（文件路径与权限模型不同） | 中 |
| **招式存储** | `SpecialMovesStore.kt`（276 行）、`CheatStore.kt`（178 行） | NAPI + 文件读写 | 小 |
| **JNI 桥** | `NativeBridge.kt`（229 行） | NAPI 重写 | 小 |
| **联机引导服务** | `PlayBootstrapServer.kt`（225）/ `PlayBootstrapClient.kt`（207） | OHOS Socket 权限与 API 不同（组播锁机制差异） | 中 |
| **APK 提供/自更新** | `GsApkProvider.kt`（63）、`gs/updater` 通道 | 鸿蒙为 HAP/AppGallery 更新机制，语义完全不同；**store 渠道建议直接关闭自更新** | 小 |
| **原生核心交叉编译** | `app/android/app/src/main/cpp/CMakeLists.txt`（编出 5 个 `libgs_*.so`）+ `scripts/build-mame.ps1`（MAME ~78 MB） | 需为 **OHOS(arm64-v8a)** 重新交叉编译（B3 已解决，SDK 26 native 可用）；**MAME 目前依赖 WSL 交叉编译链**，需评估能否产出 OHOS 目标，或首发先用非街机平台 | **极大** |
| **平台插件** | `shared_preferences`、`flutter_secure_storage` | 需 OHOS 适配版本（或自行实现 NAPI 版） | 中 |

### 2.3 需验证（可能存在隐性不兼容）

| 项 | 风险点 |
|---|---|
| 中文 IME 搜索 | 项目对华为/搜狗/百度 IME 的 composing 区域做了特殊处理（`_onSearchChanged`），OHOS 输入法行为需重新验证 |
| 高刷新率 / 低延迟音频 | `highRefreshRate`（Android `setFrameRate`）、AAudio 低延迟音频在 OHOS 的对应能力 |
| 网络组播锁 | `CHANGE_WIFI_MULTICAST_STATE`（Android 权限）→ OHOS 无对应权限，局域网发现机制可能受影响 |
| 安全存储 | `flutter_secure_storage` 在 OHOS 的 Keystore/HUKS 对应实现 |
| 文件 URI 语义 | SAF `content://` → OHOS `fileUri`/`fd`，`MainActivity.collectSafUris` 的多选逻辑需重写 |

---

## 3. 安卓与鸿蒙 7 双版本构建配置的隔离方案

**设计原则**：**Android 侧零改动**；鸿蒙侧全部为**新增目录 + 新增脚本**；两者通过**独立 SDK、独立缓存、独立工程**实现物理隔离。

### 3.1 隔离边界总览

```
GamePouch/
├── app/
│   ├── android/            【A】Android 专属，鸿蒙侧完全不触碰
│   ├── lib/                【共享】Dart 业务层（平台无关部分）
│   │   └── pal/
│   │       ├── platform_pal.dart   【共享接口】已存在
│   │       ├── android_pal.dart    【A】建议从 platform_pal.dart 拆出
│   │       └── ohos_pal.dart       【H】新增
│   └── ohos/               【H】新增鸿蒙工程（entry/ + hvigor），Android 构建完全不感知
├── third_party/            【共享】C/C++ 核心源码（编译产物按平台分目录）
├── build/
│   └── ohos/               【H】鸿蒙原生编译产物（与 android 产物分离）
├── scripts/
│   ├── build-apk.ps1       【A】不修改
│   ├── build-hap.ps1       【H】新增，与 build-apk.ps1 无任何共享可变状态
│   └── use-env.ps1         【共享】已有 -Ohos 开关；默认（无参）路径必须与今日完全一致
└── .tools/
    ├── flutter             【A】Flutter 3.47.5（Android）
    ├── flutter_ohos        【H】独立 OHOS Flutter SDK（不共用、不覆盖）
    └── caches/
        ├── pub-cache                 【A】
        └── pub-cache-official        【H】已有分离
```

### 3.2 五条隔离硬规则

| # | 规则 | 落地方式 | 保障 |
|---|---|---|---|
| **R1** | **Flutter SDK 物理分离** | Android 用 `.tools\flutter`（3.47.5）；鸿蒙用独立的 OHOS Flutter SDK **独立目录**，绝不复用同一份 | 避免版本互相污染；`use-env.ps1` 按开关注入不同 `PATH` |
| **R2** | **依赖缓存分离** | `PUB_CACHE` 按开关切换（`caches\pub-cache` vs `caches\pub-cache-official`）——**已实现** | 避免 `pub get` 产物互相覆盖 |
| **R3** | **工程目录分离** | 鸿蒙工程置于 `app/ohos/`，Android Gradle 的 `sourceSets` 不包含该路径 | Android 构建**根本不扫描**鸿蒙文件 |
| **R4** | **构建脚本零共享可变状态** | 新增 `scripts/build-hap.ps1`，**不修改** `build-apk.ps1` / `ci.ps1` 的 Android 路径 | 鸿蒙构建失败不影响 Android |
| **R5** | **默认行为不变** | `use-env.ps1` **无参时必须与今日行为完全一致**（JAVA_HOME→jdk21、ANDROID_HOME、Flutter 3.47.5）；`-Ohos` 才切换 | 现有 Android 编译/调试**零感知** |

### 3.3 Dart 侧平台代码组织（关键架构决策）

**推荐方案：条件导入 + PAL 工厂**（**不复制整个 `lib/`**）

```
app/lib/pal/
  platform_pal.dart     // 接口 + 工厂：按平台返回 AndroidPal / OhosPal
  android_pal.dart      // 现有实现（从 platform_pal.dart 拆出，逻辑零改动）
  ohos_pal.dart         // 新增
```

- 工厂通过**条件导入**（`dart.library.io` + 平台探测）或显式注入选择实现；
- **共享的 `lib/` 主体不做任何 fork**，杜绝双份维护；
- Android 侧唯一改动是**把 `AndroidPal` 移到新文件**（纯搬移，行为不变，风险极低，可用 `flutter analyze` + 既有测试兜底）。

> ⚠️ **若采用条件导入，需注意**：Dart 的条件导入基于 `dart.library.*`，无法可靠区分 Android/OHOS；因此更稳妥的是**工厂显式注入**——由 `main()` 根据平台常量（编译期 `--dart-define` 或平台探测）选择 PAL 实现。这与现有 `AppChannel`（`--dart-define CHANNEL=`）模式一致。

### 3.4 CI 双轨

| 轨道 | 触发 | 门禁 |
|---|---|---|
| Android | 每次提交 | `ci.ps1` 现有门禁（含 `check-apk-content.ps1` ROM/BIOS 校验） |
| 鸿蒙 | 新增独立 workflow | 独立门禁；**鸿蒙轨道失败不阻塞 Android 轨道** |

---

## 4. 主要兼容性风险与规避建议

| # | 风险 | 影响 | 规避建议 |
|---|---|---|---|
| **1** | **Flutter OHOS SDK 版本断层**（Dart 3.4 vs 需 ≥3.13） | 🟠 可解决 | 已装 fork 为 3.22.0/Dart 3.4；上游 `openharmony-tpc/flutter_flutter` 已有 **3.27.5 / 3.35.8 / 3.41.10（稳定）/ 3.44.9（canary）**。**P0 动作**：换装最新稳定 fork → 读其真实 Dart（`flutter --version`）→ 若仍 <3.13.4，将 `pubspec.yaml` 的 `sdk:` 放宽到该 fork 的 Dart 下限（一行改动，Android 侧 3.13 仍满足）。**切勿**用 Android 的 3.47.5 覆盖（会丢 `ohos` 目标） |
| **2** | **API 26 Native 工具链** | ✅ 已解决 | 2026-10 复核 `Sdk\26.0.0\native` 已含 llvm/sysroot/cmake，核心可交叉编译 |
| **3** | **7174 行 Kotlin 重写** | 🟠 工期主力 | **分阶段**：先做 OhosPal 骨架 + 纯 Dart 业务跑通（不含模拟器），再攻原生渲染；优先保证"库管理/资源包/设置"可用 |
| **4** | **渲染管线差异**（Android GLSurfaceView → OHOS XComponent） | 🟠 高 | 需重写渲染宿主；建议先做**单核心（如 NES/FCEUmm）跑通**验证管线，再扩展其余核心 |
| **5** | **MAME 核心体量与构建方式** | 🟠 高（~78 MB .so，当前依赖 WSL 交叉编译） | 评估 OHOS LLVM 能否承接；若不可行，**鸿蒙版首发可用 fbalpha2012 或仅非街机平台** |
| **6** | **SAF 语义差异** | 🟠 中 | 抽象出"文件选择"能力接口，Android 走 SAF、鸿蒙走系统 Picker；**交互与结果解析分别实现** |
| **7** | **插件生态缺口** | 🟠 中 | `shared_preferences` / `flutter_secure_storage` 若无匹配的 OHOS 适配版，需自行实现 NAPI 版（工作量可控） |
| **8** | **中文 IME / 高刷 / 低延迟音频** | 🟡 中 | 列入鸿蒙专项回归清单；IME 处理逻辑已有注释，可针对性验证 |
| **9** | **局域网联机组播** | 🟡 中 | OHOS 无 `CHANGE_WIFI_MULTICAST_STATE`；需调研 OHOS 组播权限，必要时改为**直连/Bonjour 替代** |
| **10** | **合规与上架** | 🟡 中 | 软著/备案需新增鸿蒙包名条目；**"不内置 ROM/BIOS"策略必须同步到鸿蒙版本描述**（已有 `docs/release-plan.md` 可复用） |
| **11** | **误改 Android 配置**（本次评估的硬性约束） | 🟠 高 | 严格执行 §3.2 五条规则；**每次鸿蒙改动后用 `build-apk.ps1 -Flavor store` 回归一次 Android 构建**作为闸门 |

---

## 5. 建议路线图（分阶段，含 Go/No-Go 决策点）

| 阶段 | 目标 | 产出 | 决策点 |
|---|---|---|---|
| **P0 工具链可行性验证** | 解除 B1 / 复核 B3 | ① 换装最新稳定 fork（3.41.10 或 3.44 canary），确认其真实 Dart ② 放宽 `pubspec` `sdk:` 约束到该 Dart 下限 ③ 跑通 `flutter_ohos pub get` + 空壳 HAP 构建 | ✅ **已完成（Go）**：3.41.10-ohos / Dart 3.11.5 + `sdk:` 放宽至 `^3.11.0` + `pub get` 通过；Android 零影响 |
| **P1 工程骨架** | 建立隔离工程 | `app/ohos/` 空壳工程 + `OhosPal` 骨架 + `build-hap.ps1` + `use-env.ps1 -Ohos` 完善；**Android 构建回归通过** | ✅ **已完成（隔离方案验收）**：见 §5.1 |
| **P2 业务层跑通** | 纯 Dart 业务上线 | ROM 库/搜索/设置/资源包导入导出可用（**不含模拟器**） | ✅ **HAP 全链路构建跑通**：`app/ohos` 重指向 OpenHarmony/API 26，`flutter build hap` 产出 HAP；CLI 签名差最后一步，可安装 HAP 走 DevEco 自动签名。见 §5.2 |
| **P3 原生核心 + 渲染** | 打通运行链路 | 单核心（FCEUmm）经 XComponent 渲染跑通 | 性能与渲染验收 |
| **P4 手柄 / 存档 / 资源包** | 完整体验 | VirtualPad 等价实现、存档、BIOS 管理 | — |
| **P5 联机 / 上架** | 全功能 + 合规 | 联机适配、软著/备案增项、鸿蒙应用市场上架 | — |

### 5.1 P1 完成记录（2026-10-19）

**目标：建立与 Android 物理隔离的鸿蒙工程骨架，并证明 Android 构建不受任何影响。**

#### 已完成项

| 项 | 结果 |
|---|---|
| `app/ohos/` 空壳工程 | ✅ 用 `flutter_ohos create --platforms ohos .` 生成（AppScope / entry / hvigor / `oh-package.json5` / `EntryAbility.ets` / `Index.ets` 等齐全），`flutter_ohos pub get` 已跑通。`.metadata` 已登记 `platforms: root, android, ohos` |
| `OhosPal` 骨架 | ✅ `app/lib/pal/ohos_pal.dart` 实现 `PlatformPal` 全 25 方法，**镜像 `AndroidPal` 的 4 个 MethodChannel 契约**（`gs/storage`、`gs/emulator`、`gs/updater`、`gs/netplay`，通道/方法名完全一致）；原生 NAPI handler 实现留作 **P2**。`flutter analyze` 仅 1 条本文件自有的未用导入警告（已修） |
| `build-hap.ps1` | ✅ 点源 `use-env.ps1 -Ohos` 后用隔离工具链调 `flutter build hap --debug` / `--release` / `--no-codesign` |
| `use-env.ps1 -Ohos` 完善 | ✅ 补 `OHOS_SDK_HOME` / `OHOS_HOME`（flutter_ohos 的 `OhosSdk` 只认这两个，不认 `DEVECO_SDK_HOME`）；保留 `DEVECO_SDK_HOME` 供 `HmosSdk` 校验；新增中立根 `D:\HuaWei\OhosSdkForFlutter`（junction `26`→`26.0.0`、`12`→`12`）让 API 26 被识别且 hdc 可定位 |
| **Android 构建回归（闸门）** | ✅ 按 `docs/skills.md` §2 用 `scripts/build-apk.ps1 -Flavor store -DebugBuild` 构建：`flutter pub get` → `Got dependencies!`，`flutter build apk --flavor store --dart-define CHANNEL=store` → **build OK in 27s**，产出 `app-store-debug.apk` (270.5 MB)。**Android 侧 `flutter` 仍为 3.47.5，`pubspec sdk: ^3.11.0` 仍满足，零影响** |

> ⚠️ **构建 APK 必须用项目脚本**：项目用 product flavors（`store`/`community`），直接 `flutter build apk` 不带 `--flavor` 会因 Gradle 产物路径与 Flutter 预期不符而报 "couldn't find apk"。一律走 `scripts/build-apk.ps1`。

#### HAP 构建实测（揭示 P2 缺口，非 P1 阻塞）

`flutter build hap --debug --no-codesign` 已**越过工具链硬校验**（`HmosSdk` 经 `HOS_SDK_HOME` 指向 `D:\HuaWei\Sdk` 内含的 API 12 HarmonyOS SDK 后找到），hvigor 启动后失败于：

> `hvigor ERROR 00303312 Configuration Error: Cannot find the corresponding SDK version under the specified SDK path. SDK path: D:/HuaWei/Sdk.`

**根因**：`flutter create` 生成的 `app/ohos/build-profile.json5` 默认指向 **HarmonyOS** 目标（`runtimeOS: "HarmonyOS"`，`compatibleSdkVersion: "5.1.0(18)"` = API 18），但本机仅有 **HarmonyOS API 12**（`5.0.0.71`）与 **OpenHarmony API 26**（`7.0.0.105`）。**目标设备是 OpenHarmony 7.0 / API 26**，故需把 OHOS 模块**重新指向 OpenHarmony**：

- `build-profile.json5`：`runtimeOS` → `"OpenHarmony"`，`compatibleSdkVersion` → 匹配 API 26 的版本串；
- `oh-package.json5` / `module.json5` 的 SDK 约束同步；
- `local.properties` 的 `sdk.dir` / `hwsdk.dir` 指向 OpenHarmony SDK（`D:\HuaWei\OhosSdkForFlutter`，含 26）。

此项属 **P2 工程配置**，不影响 P1「隔离骨架 + Android 回归」验收。另：`installApk` 在 OHOS 上语义不同（应改走系统安装器 `want/startAbility`），已在 `OhosPal` 注释标注。

#### 隔离方案验收结论

P1 达成「物理隔离」硬约束：

- 鸿蒙工具链在 `.tools/flutter_ohos`（fork 3.41.10/Dart 3.11.5），与 Android 的 `.tools/flutter`（3.47.5）`PATH` 互斥、各用独立 `PUB_CACHE`；
- `app/ohos/` 与 `app/android/` 完全分离，互不改动；
- `OhosPal` 是新增文件、未接入运行时（Android 仍走 `AndroidPal`），不触碰既有行为；
- 每次鸿蒙改动后仍可用 `build-apk.ps1 -Flavor store` 回归 Android 构建作为闸门（本次已验证通过）。

### 5.2 P2 完成记录（2026-10-19）

**目标：把 `app/ohos` 从 HarmonyOS 壳重指向 OpenHarmony / API 26，跑通 HAP 全链路构建，并复验 Android 不受影响。**

#### 已解决（配置项，全部实测通过）

`flutter create` 默认生成的是 **HarmonyOS NEXT** 目标，与真机（OpenHarmony 7.0.0.105 / API 26）不符。逐层修正后 `flutter build hap` 跑通：

| 配置项 | 文件 | 改动 | 原因 |
|---|---|---|---|
| `runtimeOS` | `build-profile.json5`（app+entry） | `"HarmonyOS"` → `"OpenHarmony"` | 真机是 OpenHarmony，非 HarmonyOS NEXT |
| `compatibleSdkVersion` / `compileSdkVersion` / `targetSdkVersion` | `build-profile.json5` | → `"26.0.0"` | OpenHarmony 用**纯版本号**（匹配 SDK `platformVersion`），**不能**带 HarmonyOS 的 `(API)` 后缀（否则 `ApiVersion` 解析报 "api version parameter is illegal"） |
| `modelVersion` | `hvigor/hvigor-config.json5` + 项目级 `oh-package.json5` | `"5.1.0"` → `"6.0.0"` | API ≥ 26.0.0 要求 modelVersion ≥ 6.0.0 |
| `deviceTypes` | `entry/src/main/module.json5` | `["phone"]` → `["default"]` | OpenHarmony SDK 26 的 `device-define` 无 `phone`，只有 `default`（否则 SyscapTransform 报 "intersection ... is empty"） |
| SDK 根定位 | `scripts/use-env.ps1 -Ohos` | 新增 `OHOS_BASE_SDK_HOME=D:\HuaWei\Sdk` | flutter_tools 的 `updateLocalProperties` 不写 `sdk.dir`，hvigor 需从 `OHOS_BASE_SDK_HOME` 找 OpenHarmony SDK；且指向 DevEco 真实根才能读到 `D:\HuaWei\Sdk\licenses\`（OpenHarmony SDK 许可已接受） |

结果：`flutter build hap --debug --no-codesign` → **`√ Built build\ohos\hap\entry-default-unsigned.hap`（约 124 MB）**，hvigor 12 任务全过，设备正确识别为 `Ohos OpenHarmony-7.0.0.105 (API 26)`。

#### 签名（`scripts/sign-ohos-hap.ps1`）

未签名 HAP 报 `no signature file`（hdc code 9568320），无法安装。写了 `scripts/sign-ohos-hap.ps1` 做 OpenHarmony 本地 debug 签名：

- 已跑通：`generate-keypair`(ECC P-256) → `generate-cert` 自签根 CA + app/profile 叶证书 → 组装**证书链** → 动态生成 debug profile 模板（注入 app 证书链 + 设备 udid + 刷新有效期）→ **`sign-profile` 成功产出 `debug.p7b`**。
- 关键踩坑（已固化进脚本）：`sign-profile`/`sign-app` 只支持 **ECDSA**（profile 密钥也须 ECC）；证书链文件须为**无 BOM**、且 base64 行不能混入空格（`Set-Content -Encoding utf8` 的 BOM 与 cert 行包装空格都会导致 "Illegal base64 character / Illegal header"）。
- ✅ **`sign-app` 已修复并跑通**（2026-10-19）：根因在 profile 模板的 `development-certificate` 字段格式——必须是**证书链**、且为 **base64url 编码的「两证书 DER 拼接」连续串**（先各自 PEM→DER 拼接再整体 base64url，不能带头尾/换行/各自编码后拼接）；`sign-app` 的 `-appCertFile` 也要传链文件 `debug-app-chain.cer`。最终 `sign-app success`，产出 `entry-default-signed.hap`（约 125 MB）。

**真机安装（CA 信任）**：本地脚本用**自签 CA**，本机 pura70（OpenHarmony 7.0）只信任 **DevEco 自动签名**的 CA（参考 `MyApplication` 在 `C:\Users\liuzhixing\.ohos\config\default_MyApplication_*.{cer,p7b,p12}` 的材料）。故 `hdc install` 自签 HAP 报 `fail to verify pkcs7 file`（code 9568257）。
**在真机装可运行 HAP 的推荐路径**：DevEco Studio 打开 `app/ohos` → File → Project Structure → Signing Configs → 勾选 **Automatically generate signature**（工具链自身亦如此提示），它把受信任调试 CA 装进设备，`flutter build hap --debug` 即可产出可 `hdc install` 的 HAP。纯 CLI 自签 pipeline 已全程跑通，仅差设备侧 CA 信任这一步。

#### Android 回归（闸门）

P2 全程只改 `app/ohos/*` 与 `scripts/*`，未触碰 `app/android` 与 `pubspec.yaml`。复跑 `scripts/build-apk.ps1 -Flavor store -DebugBuild` → **build OK in 33s**，产出 `app-store-debug.apk`（270.5 MB）。**Android 零影响**。

#### 尚未完成（属后续 P2/P3）

- **`OhosPal` 运行时接入**：✅ 已完成并**已在 pura70 真机验证**（2026-10-19）。`pal_factory.dart` 的 `createPlatformPal()` 按 `Platform.operatingSystem == 'ohos'` 切换 `OhosPal`/`AndroidPal`（**刻意不用 `TargetPlatform.ohos`**，因其是 OHOS fork 专属枚举、Android 工具链 3.47 没有，会破坏 Android 编译）；`main.dart` 改用工厂。`OhosPal` 所有 MethodChannel 调用已用 `catch (_)` 兜底（**注意 `MissingPluginException` 不是 `PlatformException` 子类，原 `on PlatformException` 抓不到**），无原生 handler 时返回安全默认值（如 `filesDir()` 退回 `systemTemp`）。`flutter build hap --debug`（DevEco 自动签名）→ `hdc install` 装到 pura70 后，**纯 Dart UI 正常渲染**（深色主题「趣玩匣游戏库」首页 + 空库引导态 + 导入按钮），进程稳定无崩溃。
  - **真机首屏白屏的两处根因（已修复）**：① `shared_preferences` 在 OHOS 无原生 handler，`main()` 里 `AppSettings.load()`/consent 的 `SharedPreferences.getInstance()` 抛 `MissingPluginException`，导致 `main()` 在 `runApp()` 前中止 → 纯白屏；已在 `app_settings.dart` 的 `load()/save()` 与 `main.dart` 启动依赖处加 `try/catch` 兜底到默认值。② `OhosPal` 原 `on PlatformException` 漏抓 `MissingPluginException` → 改为 `catch (_)`。
- **原生 handler（P3，主体已完成）**：新增 `app/ohos/entry/src/main/ets/plugins/GamePouchPlugin.ets`（ArkTS 实现 `FlutterPlugin`），在 `EntryAbility.configureFlutterEngine` 注册 4 个 MethodChannel。`gs/storage` 已实现 `getFilesDir`（返回真实沙箱，**真机验证库页不再「初始化失败」**）、`getDeviceModel`、`deleteBios`、全部 SAF 导入导出（`@ohos.file.picker` + `fs` 拷贝，ROM 含分块 CRC32）；`gs/updater.getVersion` 走 `bundleManager`；`gs/emulator.launch` 因 OHOS 暂无 libretro core runtime 返回 false；`gs/netplay` 已注册。`getAvailableBytes` 因 `@ohos.file.statvfs` API 跨版本不一致暂返回 0。
- **后续（P4 进展，2026-10-19）**：② `exportBiosZipViaSaf` ✅ 已用 `zlib.zipFile` 打包 `system/` 并经 SAF 保存；④ `getAvailableBytes` ✅ 改用 `statfs.getFreeSize`（真机 selfTest 验证 ~97.4GB）。③ SAF 导入导出 ✅ 代码链路已通，真机人工点选系统文件选择器验证清单已给。**① OHOS libretro core runtime**：可行性/接口设计已完成 → `docs/ohos-libretro-port.md`（架构、libretro.h 适配、core 构建、XComponent+EGL 渲染、OHAudio、输入桥、`gs/emulator.launch` 集成契约、M0–M4 里程碑）。实际移植属跨平台大型工程（数周级），进入实现阶段待排期，`launchEmulator` 暂返回 false。
- P2/P3「可安装 + 可运行 + 原生存储/SAF 就绪」里程碑已达成：构建全通、DevEco 自动签名可装真机、纯 Dart UI 已实跑、`getFilesDir` 等原生通道已打通（库页正常、导入流程可交互）。

---

## 6. 评估结论（一句话）

> **P0 已验证通过（Go）**：① `flutter_ohos` 已换装 **3.41.10-ohos-1.0.1 / Dart 3.11.5**（OpenHarmony 官方 fork，非 Google 原版，故**不能**直接换成 Android 侧 3.47.5）；`app/pubspec.yaml` 的 `sdk:` 已由 `^3.13.4` 放宽至 `^3.11.0`（Android 的 3.13.4 仍满足）；`flutter_ohos pub get` 已跑通（`Got dependencies!`）。② 目标 API 26 的 Native 工具链（llvm/sysroot/cmake）**已确认安装**于 `Sdk\26.0.0\native`，核心可交叉编译。**Android 侧 `flutter` 仍为 3.47.5，全程零影响**。
> 但**架构层面完全具备移植条件**：`PlatformPal` 抽象层 + 90% 纯 Dart 业务层 + 平台无关的 C/C++ 核心，使得这成为一次**边界清晰、可隔离、可分期**的新平台移植，而非推倒重来。
> **建议先执行 P0（工具链验证）作为 Go/No-Go**，通过后再按 §3 的隔离方案与 §5 的路线图推进；整个过程 Android 侧保持零改动、可随时回归验证。

---

## 附录：本次评估核实的关键事实

| 项 | 实测值 |
|---|---|
| Android Flutter / Dart 要求 | Flutter **3.47.5**；`pubspec` 要求 `sdk: ^3.13.4` |
| 本机 OHOS Flutter（已装） | `flutter_ohos` 实为 **Flutter 3.22.0 / Dart 3.4.0**（来自 `atomgit.com/openharmony-tpc/flutter_flutter.git`；`version` 文件占位串 `0.0.0-unknown`，引擎 `f6344b75…`）。**非** Google 原版，无 `ohos` 目标，不能替换为 Android 侧 3.47.5 |
| 上游 OHOS fork 可用版本 | **3.27.5 / 3.35.8 / 3.41.10（稳定）/ 3.44.9（canary）**，均晚于已装的 3.22.0 |
| P0 已执行（2026-10-19） | ✅ 已将 `flutter_ohos` 切到 **3.41.10-ohos-1.0.1 / Dart 3.11.5**（stash 备份 `P0-upgrade-backup-202610190646`）；`app/pubspec.yaml` 的 `sdk:` 由 `^3.13.4` 放宽至 `^3.11.0`；`flutter_ohos pub get` → `Got dependencies!`（exit 0）。**Android 侧 `flutter` 仍为 3.47.5，确认零影响** |
| 项目既有结论 | `docs/skills.md:592` 记录"Dart 3.4 **无法重编**"（在旧 fork 3.22/Dart 3.4 下成立；换新版 fork 后需复核） |
| 目标设备 | Pura 70，**HBN-AL00**，**OpenHarmony 7.0.0.105**，**API 26**，`arm64-v8a`，hdc 已连接（`2MN0224730027764`） |
| DevEco Studio | `DS-261.23567.138.36.2600851`，SDK 根含 `12` 与 `26.0.0` |
| Native 工具链 | ✅ `Sdk\26.0.0\native` 已含 **llvm / sysroot / build-tools\cmake**（2026-10 复核），MAME / libretro 核心可面向 API 26 交叉编译 |
| 鸿蒙工程现状（P1 前） | 原**不存在** `ohos/` 目录；`app/lib/pal/` **仅有 `platform_pal.dart`**，仅 `AndroidPal` 一个实现 |
| 鸿蒙工程现状（P1 后，2026-10-19） | ✅ `app/ohos/` 空壳工程已生成；`app/lib/pal/ohos_pal.dart`（`OhosPal`）已实现 `PlatformPal` 全部 25 方法（镜像 `AndroidPal` 的 4 个 MethodChannel 契约，原生 NAPI 实现留 P2）；`build-hap.ps1` + 完善的 `use-env.ps1 -Ohos` 就位；Android 回归（`build-apk.ps1 -Flavor store -DebugBuild`）通过，隔离方案验收 |
| PAL 接口规模 | 44 个接口成员；`AndroidPal` 25 个 MethodChannel 调用点（`gs/storage`、`gs/emulator`、`gs/updater`、`gs/netplay`） |
| Kotlin 平台代码 | **7174 行**（EmulatorActivity 2769 / VirtualPadView 1747 / MainActivity 824 / LockedRom 551 / …） |
| 依赖 | `shared_preferences ^2.3.0`、`archive ^3.6.1`、`path ^1.9.0`、`flutter_secure_storage ^11.2.0`（前两者纯 Dart 无碍） |
| 原生核心 | `third_party/` 5 个 libretro 核心（95.7 MB，平台无关）+ MAME（~78 MB `.so`，当前经 WSL 交叉编译） |
