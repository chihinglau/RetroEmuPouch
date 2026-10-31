# GamePouch（趣玩匣）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Version](https://img.shields.io/badge/version-1.8.4%2B49-blue.svg)](./app/pubspec.yaml)
[![Platform](https://img.shields.io/badge/platform-Android%20arm64--v8a-3ddc84.svg)](#-技术栈)
[![Platform](https://img.shields.io/badge/platform-HarmonyOS%20NEXT%20arm64-FF5A00.svg)](#-openharmony--harmonyos-next-支持)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.13-02569B.svg?logo=flutter)](#-技术栈)

> Flutter + Kotlin + NDK 的多平台复古游戏模拟器 Android 端，并提供 **OpenHarmony / HarmonyOS NEXT** 同构移植（ArkTS + NAPI 原生宿主）。
> 让历史更安心 —— 家庭主机、街机的 ROM 与存档都装在 App 私有目录里，可单文件备份、可在局域网内与伙伴互导。

Dart package: `gamepouch` · Android applicationId: `com.retroemupouch.app` · HarmonyOS bundleName: `com.gamepouch.gamepouch`

---

## ⚠️ 合规声明（必读）

**本仓库不包含、不分发任何 BIOS 或游戏 ROM**。用户必须从自己合法拥有的副本中导入：

| 类别 | 文件 | 用于 | 不入库原因 |
|------|------|------|------------|
| BIOS | `neogeo.zip` | NeoGeo 全家（kof97 / mslug / samsho2 / …） | SNK 版权 |
| BIOS | `qsound.zip`（含 `dl-1425.bin`） | Capcom CPS-1/CPS-2 Q-Sound（1944 / sf2ce / samsho2 / msh） | Capcom 版权 |
| ROM | 单 zip 或资源包 | 各游戏 | 各自版权方 |

应用内提供三种导入通道（详见 [「系统文件（BIOS）管理」](#-系统文件bios管理) 与 [「伙伴导入」](#-伙伴导入peer-sync)）：

1. **SAF 批量导入** — 系统文件管理器多选
2. **伙伴导入** — 同 Wi-Fi 互传（白名单限定 `neogeo.zip` / `qsound.zip`）
3. **手动 push** — `adb push` 到 app 私有目录

CI 通过 `scripts/check-apk-content.ps1` 门禁强制保证 APK 内零 BIOS/ROM。

---

## ✨ 功能特性

| 能力 | 简介 |
|------|------|
| 🕹️ **多核模拟** | FC / GB / GBA / MD / 32X / 2600 / 街机（**store 用 mame**，community 用 fbalpha2012） |
| 🎮 **自定义按键** | 6 槽位招式脚本（波动拳/升龙/旋风腿等），可导入导出 |
| 🎛️ **虚拟手柄布局** | 摇杆/十字键 + 右侧 ABXY 支持整体缩放与上下左右平移，适配屏幕与握持习惯；配置可导入导出 |
| 💾 **存档管理** | 电池档 / 即时存档 / 倒带；多槽位缩略图 |
| 🌐 **局域网联机** | 同 Wi-Fi 双人锁步对战，HMAC 防伪，**严格不猜输入**（详见 [netplay](#-局域网联机netplay)） |
| 👥 **伙伴导入** | 同 Wi-Fi 一键导入伙伴游戏库 + 所需 BIOS（白名单限定） |
| 📦 **资源包导出** | 多选 ROM + 存档 + 金手指 + **BIOS** 打成单 zip，跨设备离线分享（街机开箱即用） |
| 🎨 **深色主题** | Material 3 配色自适应 |
| 🇨🇳 **完全中文化** | 设置/帮助/联机大厅全中文 |

### 系统文件（BIOS）管理

设置页 → 「系统文件（BIOS）」卡片提供生命周期管理：

- **批量导入** — 一次 SAF 即可拉入 `neogeo.zip` + `qsound.zip`（支持多选）
- **导出全部** — 当前 BIOS 打成单 zip 到用户选的位置（换机时一键还原）
- **单文件删除** — 不需要的 BIOS 单独移除
- **三段分组展示** — 已安装（n）/ 缺失（n）/ 其他（n）

启动时若缺失核心所需 BIOS，会弹 `MissingBiosDialog`（同样走批量通道，一次补齐）。

> 💡 导出「游戏资源包」时也能**直接把已安装的 BIOS 一起打包**（导出对话框里的「BIOS 系统文件」多选），对端导入资源包即自动还原 BIOS，无需再手动去本页导入。

> ⚠️ **多 BIOS 列表 lockstep**：`SystemFiles.requiredBios`（Dart）↔ `LockedRom.ARCADE_BIOS_NAMES`（Kotlin）必须**同时**维护，新增 BIOS 时三处必改（详见 [`docs/skills.md` §2.5](./docs/skills.md)）。**漏一处**会复现「UI 显示已装但启动仍报缺」或反之的诡异现象。

### 局域网联机（netplay）

已完整落地的同 Wi-Fi 双人锁步对战：

- **三段通道**：Dart 信令（HTTP + bearer）→ Kotlin 启动引导（电池档 + 帧0 serialize 对齐）→ native UDP 帧数据
- **严格锁步**：任一帧 K 仅在双方该帧输入都到齐时才推进，**绝不猜输入**（任意检查点双方状态逐字节一致）
- **HMAC-SHA256 防伪**：每 UDP 帧带 256-bit 会话密钥截断 tag
- **自适应 D ∈ {1,2}**：依 RTT/lead-time 统计自动降 D，格斗可锁 D=1
- **确定性护栏**：双方 `versionCode` / `coreId` / `ROM CRC32` / `netplayProto` 必须全等，不符在邀请阶段拒绝
- **门禁链**：`not_paired` → `version_mismatch` → `rom_not_local` → `core_unsupported` → `not_multiplayer`

同 Wi-Fi RTT 中位 ≈7ms、p99 ≈21ms、0 丢包，D=1 常态零冻结。

### 伙伴导入（peer sync）

「伙伴」是同 Wi-Fi 已配对的另一台 GamePouch 设备。可互导：

- **ROM 库**（多选游戏 + 自动跳过本机已有）
- **封面**（对等库卡片直接显示伙伴游戏封面图）
- **金手指**
- **存档**（运行锁：游戏运行中存档区置灰 + 提示；存档互传为手机↔手机特性）
- **BIOS**（仅白名单 `neogeo.zip` / `qsound.zip`，服务端 400 非法名防路径穿越）

浏览伙伴游戏库时，平台筛选标签会显示各类型当前数量（`全部 (N)` / `GBA (n)` / `MAME (n)` …），
并优先展示中文名（若伙伴提供）。

详见 [`docs/skills.md` §10](./docs/skills.md) 与 [§14](./docs/skills.md)。

### PC 端库管理工具（`tools/`）

随仓库附带的 Python 桌面工具（Tkinter GUI，`python tools/library/library_manager.py` 启动），
面向开发者/进阶用户，**不含任何 BIOS/ROM**：

- **本地库管理**：ROM / 金手指 / BIOS / 关联报告 / 联网检索金手指 / 手机同步 六个页签；
  游戏库表格含 **中文名** 与 **游戏图标（封面）** 两列——从仓库内置的元数据索引
  （按 CRC32 优先、平台+英文名次之）自动补全，缺失项留空可另行网络检索。
- **局域网 peer 服务端**（`tools/library/peer_host.py` + `run_peer_server.py`）：手机端零改动，
  PC 直接实现伙伴协议服务端（UDP 43801 发现 + HTTP 随机端口），下发 ROM / 封面 / 金手指 / BIOS，
  供手机「发现伙伴」导入。

详见 [`docs/skills.md` §13–§14](./docs/skills.md)。

---

## 📱 OpenHarmony / HarmonyOS NEXT 支持

GamePouch 的鸿蒙版与 Android 版**共享同一套 Flutter UI 与 libretro 抽象**，差异仅在原生层：Android 走 Kotlin/NDK，鸿蒙走 ArkTS + NAPI 原生宿主 `gpretro`（见 `app/ohos/entry/src/main/cpp/gpretro.cpp`），二者对核心暴露的 `retro_*` 接口、输入位（bit0..15）、以及虚拟手柄布局都保持 **1:1** 一致。

### 关键能力

- **多核同源**：libretro 抽象下 fceumm / gambatte / mgba / picodrive / stella2014 / mame 直接复用，无需重写核心适配。
- **MAME 街机核已落地**：`libgs_mame.so`（MAME 0.289，aarch64，musl）在 Linux 原生 OHOS SDK（`clang-15`）下交叉编译成功，含完整 NeoGeo/CPS 支持；详见 [`docs/ohos-libretro-port.md`](./docs/ohos-libretro-port.md) 与 [`docs/skills.md` §2.7](./docs/skills.md)。
- **虚拟手柄 1:1 移植**：
  - 单屏手柄只驱动被选中端口（`setPlayerPort`），避免 1P/2P 同时误触发街机服务菜单；
  - NEOGEO 四键面板 + 「格斗辅助键」招式面板（`波/升/旋/超/避/滚`，脚本语法与 Android `ScriptCompiler` 对齐：数字 1-9 小键盘方向 + `P/H/L/K` 按键，超级杀 `+PK` 和弦）。
  - **功能菜单「摇杆」切换（双端一致）**：安卓 `EmulatorActivity` 功能面板新增「摇杆」按钮，循环 模拟摇杆 → 十字键(八向) → 十字键(四向)，与鸿蒙 `EmulatorSpike` 行为一致；`VirtualPadView` 的屏上控件与触摸命中同步按 `stickMode` 切换。
  - **退出稳定性**：鸿蒙端进 neogeo/mame 游戏后点 ✕ 可平稳返回游戏库（已修复 `libgs_mame.so` 退出时 `dlclose` 导致的整 app 崩溃）；启动图标已同步安卓 `ic_launcher` 设计。
- **真机联调**：`hdc` 取代 `adb`，`scripts/build-hap.ps1` 一键构建签名 HAP，`hilog` 抓核日志。

### 构建与运行

```powershell
# 1) 准备 Linux 原生 OHOS SDK（推荐，取代 Windows clang 封装，详见 docs/skills.md §2.7）
#    unzip 时必须用 'command-line-tools/sdk/default/openharmony/native/*' 才能递归解压

# 2) 构建并安装 HAP 到真机
powershell -ExecutionPolicy Bypass -File scripts\build-hap.ps1
hdc -t <device-sn> install -r app\build\ohos\hap\entry-default-signed.hap
hdc -t <device-sn> shell aa start -a EntryAbility -b com.gamepouch.gamepouch

# 3) 抓核心日志（GPRETRO / CORE: 前缀）
hdc shell hilog > hilog.txt
```

> ⚠️ 预编译核心 `libgs_mame.so`（~190MB）与 `cores/` 下的 MAME 源码树**不入库**（与 `third_party/` 内核一致，由 `docs/skills.md` §2.7 本地自编译）；仓库仅含构建脚本与移植文档。

### 目录差异

```
app/
├── android/   # Kotlin/NDK 宿主（MainActivity / EmulatorActivity / LockedRom + cpp/runner）
└── ohos/      # ArkTS + NAPI 宿主
    └── entry/src/main/
        ├── ets/pages/EmulatorSpike.ets   # 虚拟手柄覆盖层（1P/2P + MAME6键 + NEOGEO招式）
        ├── ets/plugins/GamePouchPlugin.ets # MethodChannel 桥（launch/import/updater/netplay）
        ├── cpp/gpretro.cpp                # libretro 运行时宿主（dlopen libgs_*.so）
        └── cpp/types/libgpretro/          # NAPI 类型声明
docs/
├── ohos-libretro-port.md   # 鸿蒙 libretro 移植总览
├── ohos7-feasibility.md    # HarmonyOS 7 可行性评估
└── android-ui-spec.md       # Android 虚拟手柄位定义（1:1 移植基准）
```

---

## 🚀 快速开始

### 1. 克隆 & 准备工具链

```powershell
git clone <repo>
cd GamePouch

# 首次：建立本地工具链（junction 共享 SDK/Flutter/JDK，零系统污染）
powershell -ExecutionPolicy Bypass -File scripts\setup-env.ps1
```

### 2. 每个新终端：点源环境脚本

```powershell
. .\scripts\use-env.ps1
```

> ⚠️ 不要用系统自带的 `flutter`：系统 PATH 里的 Dart 是 3.4，项目要求 `>=3.13`，必须用 `.tools\flutter`。
> ⚠️ **点号 + 空格**（`. .\use-env.ps1`）不是 `&` —— `&` 不会注入环境到当前 shell。

### 3. 构建

```powershell
# 方式 A：一键脚本（推荐）
.\build.bat store                 # store + release（上架包）
.\build.bat debug                 # community + debug（自测）
.\build.bat install store         # 构建并 adb 安装到设备

# 方式 B：直调
powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store
```

### 4. 安装到真机

```powershell
adb install -r -t app\build\app\outputs\flutter-apk\app-store-release.apk
```

---

## 📦 构建变体（flavor）

| flavor | 用途 | 能力差异 |
|--------|------|----------|
| `store` | 华为/小米/Google Play 上架 | **禁止**自更新 / ROM 云端下发 / 全局禁明文 / 关闭备份导出 |
| `community` | 自签 sideload / 局域网自建 | 保留 OTA 自装（`REQUEST_INSTALL_PACKAGES` + `GsApkProvider`） |

Dart 侧通过 `--dart-define=CHANNEL=<flavor>` 注入开关，缺省为 `store`（最严格）。

| flavor | 街机核心 | 联机白名单 |
|--------|----------|-----------|
| `store` | `mame`（交叉编译自 WSL 克隆，见 §2.5） | `assets/data/multiplayer.json` 的 `mame` 段 |
| `community` | `fbalpha2012`（预编译二进制，非商业授权） | `assets/data/multiplayer.json` 的 `fbalpha2012` 段 |

> 社区版 `fbalpha2012` 核心因非商业授权问题**不**包含在 `store` 包中；上架请用 `store` flavor。

---

## 📁 项目结构

```
GamePouch\
├── build.bat                          # 一键构建入口（双击即可）
├── .gitignore                         # 排除 .tools / build / keystore / 调试产物
├── LICENSE                            # MIT
├── scripts\
│   ├── setup-env.ps1                  # 首次：junction 工具链
│   ├── use-env.ps1                    # 会话：注入环境变量
│   ├── build-apk.ps1                  # pub get + flutter build apk
│   ├── build-hap.ps1                  # 鸿蒙：flutter build hap + hdc 签名安装
│   ├── make-release-keystore.ps1      # 生成 .jks + keystore.properties
│   ├── check-apk-content.ps1          # CI 门禁：APK 零 ROM/BIOS
│   ├── mame\
│   │   ├── build-mame.ps1             # WSL 交叉编译 store 街机核心
│   │   └── refresh-roms.ps1           # 真机街机一键刷新（BIOS + ROM 部署 + 验证）
│   └── mame-ohos\                     # 鸿蒙 MAME 交叉编译（Linux 原生 SDK）
│       ├── build-mame-ohos.ps1        # 驱动 WSL 内 clang-15 编译 libgs_mame.so
│       └── *.sh                       # 包装器 / 资源占位 / 诊断脚本
├── app\
│   ├── pubspec.yaml                   # 1.8.4+49
│   ├── lib\
│   │   ├── system_files.dart          # requiredBios 单一来源（Dart 侧）
│   │   ├── pal/platform_pal.dart      # SAF 通道（Dart 侧）
│   │   ├── features\
│   │   │   ├── library/
│   │   │   │   ├── library_page.dart          # 库页面
│   │   │   │   └── missing_bios_dialog.dart   # 启动缺 BIOS 弹框
│   │   │   ├── settings/
│   │   │   │   ├── settings_sheet.dart        # 设置页（_BiosManagerCard）
│   │   │   │   └── special_moves_editor.dart  # 6 槽招式编辑器
│   │   │   └── play/                          # 联机大厅 / 邀请
│   │   ├── data\
│   │   │   ├── peer/                  # 伙伴 peer + 同步
│   │   │   └── play/                  # netplayCapability + multiplayerCatalog
│   │   └── config/app_channel.dart    # flavor 编译期开关
│   ├── android\app\src\main\
│   │   ├── kotlin\com\gamepouch\app\
│   │   │   ├── MainActivity.kt        # 平台通道（import/export SAF）
│   │   │   ├── EmulatorActivity.kt    # 启动引导
│   │   │   └── LockedRom.kt           # ARCADE_BIOS_NAMES + 启动镜像
│   │   ├── cpp\netplay\               # native 锁步（UDP/HMAC/自适应 D）
│   │   └── jniLibs\arm64-v8a\         # 预编译 .so（libgs_*）
│   └── assets\
│       ├── data\multiplayer.json      # 联机白名单（FC CRC / 街机 driver）
│       └── OSS_LICENSES.md            # 内核 license 摘要
├── third_party\
│   ├── fceumm\ gambatte\ mgba\ picodrive\ stella2014\   # 完整 git 克隆（被 .gitignore 排除，仅 CORE_PINS.txt 入库）
│   └── CORE_PINS.txt                  # 内核 commit 锁定
├── docs\
│   ├── skills.md                      # 本地开发 Skill 手册（开发者必读）
│   ├── ohos-libretro-port.md          # 鸿蒙 libretro 移植总览（核心/宿主/输入）
│   ├── ohos7-feasibility.md           # HarmonyOS 7 可行性评估
│   ├── android-ui-spec.md             # Android 虚拟手柄位定义（1:1 移植基准）
│   └── skill_github_repo_access.md    # 无 gh CLI 推 GitHub 流程
├── tools\                             # PC 端库管理工具（Python/Tkinter，不含 BIOS/ROM）
│   ├── library\
│   │   ├── library_manager.py         # GUI 主程序（中文名/图标/金手指/BIOS/peer 服务端）
│   │   ├── library_meta.py            # 内置元数据索引：中文名 + 封面补全
│   │   ├── peer_host.py               # 局域网 peer 协议服务端（手机零改动）
│   │   ├── run_peer_server.py         # 无界面启动 peer 服务端（真机联调用）
│   │   └── phone_sync.py              # adb 部署到真机
│   └── chatsync\sync_cheats.py        # 金手指关联/导出
└── keystore.properties.template       # release 签名配置模板（实际 .properties 已 gitignore）
```

---

## 🛠️ 技术栈

| 层 | 选型 |
|----|------|
| UI | Flutter `>=3.13` / Dart `>=3.13.4` / Material 3 |
| 平台 | Android `minSdk=26`（AAudio 需 API 26）/ arm64-v8a / `compileSdk=36` |
| 原生 | Kotlin `jvmTarget=17` / C++17 / CMake `3.22.1` / NDK `28.2.13676358` |
| 构建 | Gradle `9.8.0`（Kotlin DSL，腾讯镜像）/ JDK 21 |
| 联机 | Dart `HttpServer`（信令）+ Kotlin 极简 HTTP（启动引导）+ native UDP（帧数据） |
| 模拟器 | libretro 抽象 + fceumm / gambatte / mgba / picodrive / stella2014 / mame / fbalpha2012 |
| 工具链 | `.tools\` 下 junction 共享 SDK/Flutter/JDK，**零系统污染**（无注册表、无环境变量、无系统级 SDK） |
| OHOS 原生 | ArkTS / eTS + NAPI 宿主（`gpretro`）+ C++17 / CMake（OHOS SDK `clang-15` 原生工具链，非 Windows 封装） |

---

## 🔐 发布签名

release 构建**不再使用 debug keystore**（否则无法接入 Play App Signing / 华为签名，密钥泄露即失控）。

```powershell
# 生成本地开发钥匙（落入 .tools/signing/，已 gitignore）
powershell -ExecutionPolicy Bypass -File scripts\make-release-keystore.ps1
```

- 本地：`keystore.properties`（已 gitignore）
- CI：环境变量 `GP_KS_FILE` / `GP_KS_PWD` / `GP_KEY_ALIAS` / `GP_KEY_PWD`

> ⚠️ 该脚本产出的是**本地开发密钥**。**真正签名商店包**的密钥必须由密管 / HSM 托管，并接入 Play App Signing 或华为 AppGallery 签名服务；`.jks` 与口令**绝不入库、绝不进 CI 日志**。
> ⚠️ **配对关系**：`.jks` 和 `keystore.properties` 必须配对。若 `keystore.properties` 丢失，旧 `.jks` 即成「死钥匙」（密码未知无法复用）——务必同时备份这两个文件。

---

## 🛠️ 开发者文档

| 文档 | 适合谁 | 内容 |
|------|--------|------|
| [`docs/skills.md`](./docs/skills.md) | 贡献者 | 编译 / 真机 / 调试 / 联调 / 坑速查 / netplay 协议 / 质量门 |
| [`docs/ohos-libretro-port.md`](./docs/ohos-libretro-port.md) | 鸿蒙贡献者 | 鸿蒙 libretro 宿主 / MAME 核 / 输入位 / 虚拟手柄移植 |
| [`docs/ohos7-feasibility.md`](./docs/ohos7-feasibility.md) | 架构 | HarmonyOS 7 可行性评估 |
| [`docs/android-ui-spec.md`](./docs/android-ui-spec.md) | UI 移植 | Android 虚拟手柄位定义（1:1 基准） |
| [`docs/skill_github_repo_access.md`](./docs/skill_github_repo_access.md) | 仓库维护者 | 无 gh CLI 推 GitHub 流程 + .gitignore 规则 |
| [`app/assets/OSS_LICENSES.md`](./app/assets/OSS_LICENSES.md) | 法务 | 内嵌内核的许可证摘要 |
| [`third_party/CORE_PINS.txt`](./third_party/CORE_PINS.txt) | 升级者 | 内核 commit 锁定（升级前必看） |

---

## 📝 更新日志 / Changelog

- **OHOS netplay 对端退出自动返回（2026-10-31）**：修复联机中对端（如安卓主机）退出/掉线后，鸿蒙端卡死在游戏界面不返回的问题。原生 `NativeNetplayStop`（`app/ohos/entry/src/main/cpp/gpretro.cpp`）改为先停渲染线程再释放 netplay 对象，消除 use-after-free SIGSEGV；`EmulatorSpike.ets` 的退出路径改为 `netplay.stop()` 先执行、`exitToLibrary()` 守卫标志由函数自身置位，确保退出能真正 `router.back()` 回游戏库。详见 [`docs/skills.md`](./docs/skills.md)「已知问题与修复记录」。

---

## 📜 License

[MIT](./LICENSE) © 2026 GamePouch / 趣玩匣 contributors

子项目 / 内核各自许可（BSD / GPL / Zlib 等）见 [`app/assets/OSS_LICENSES.md`](./app/assets/OSS_LICENSES.md)。
