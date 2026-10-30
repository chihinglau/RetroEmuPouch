# OHOS libretro 移植：可行性 / 接口设计文档

> 关联：`docs/ohos7-feasibility.md` §5.2（P4-①）、`docs/skills.md` §2.6（`gs/emulator.launch`）。
> 状态：**设计完成，进入实现阶段待排期**。本文件不实际移植，只把架构、接口契约、构建体系、风险点写清。

---

## 0. 结论（TL;DR）

- **可行**。OHOS NEXT（API 19/SDK 26）已提供构建 libretro 运行时所需的全部原生能力：
  XComponent 原生窗口、`EGL`/`GLES3` 渲染、`OHAudio`（及 `OpenSLES` 兜底）音频、原生线程与 `CLOCK_MONOTONIC` 时钟。
- **工作量**：数周级，必须分阶段。建议从 **NES（`fceumm` core）最小闭环** 起步，再横向扩 core。
- 当前 app 已具备完整的 Dart 契约 `launchEmulator(relativePath, coreId, platform, netplay?)` → `gs/emulator.launch` MethodChannel；原生侧只需新增一个**原生渲染宿主**（现有 `GamePouchPlugin.onEmulator('launch')` 直接返回 `false` 是占位，不改 Dart）。

---

## 1. 现状盘点（为什么现在能做）

| 层 | 现状 | 移植含义 |
|---|---|---|
| Dart 契约 | `PlatformPal.launchEmulator(...)` → `_emulator.invokeMethod('launch', {rom, core, platform, netplay})`；OHOS 侧 `onEmulator` 现直接 `false` | 契约已定，原生实现零 Dart 改动 |
| Android 事实标准 | `EmulatorActivity.kt`（~130KB Kotlin/JNI）：GL 线程驱动 libretro core，含 `systemDir`/`saveDir`/`saveKey`、竖屏街机 90° 旋转、netplay 帧同步(state0)、cheats | 移植要**复刻契约与行为**，不是 UI |
| OHOS 工程 | `app/ohos/entry/src/main` 仅 `ets/`、`resources/`，**无 `cpp/`**，无 `externalNativeOptions` | 需新增 native 构建配置 |
| SDK 26 sysroot | 具备 `ace/xcomponent`、`GLES3`、`SLES/OpenSLES.h`、`ohaudio/`、`libc`/pthread | 原生三件套齐备 |

`launchEmulator` 的 Dart 签名（来自 `lib/pal/platform_pal.dart`）：

```dart
Future<bool> launchEmulator({
  required String relativePath,  // 相对 filesDir/roms/ 的路径
  required String coreId,        // 如 fceumm / gambatte / mgba / fbneo / mame
  required String platform,
  Map<String, dynamic>? netplay, // 单机关键路径可忽略
});
```

`gs/emulator.launch` 实际入参映射（`ohos_pal.dart` / `android_pal.dart` 一致）：

```json
{ "rom": "<relativePath>", "core": "<coreId>", "platform": "<platform>", "netplay": {…} | null }
```

---

## 2. 目标架构（三层）

```
┌──────────────────────────────────────────────────────────┐
│ Dart: EmulatorPage（全屏路由）                              │
│   ├─ 原生 PlatformView（XComponent）→ 模拟器画面            │
│   └─ Flutter 叠层：虚拟手柄 / netplay 状态 / 退出按钮        │
└───────────────┬──────────────────────────┬───────────────┘
                │ XComponent 原生视图        │ gs/emulator.* (MethodChannel)
                ▼                            ▼
┌──────────────────────────┐   ┌──────────────────────────────┐
│ ArkTS 胶水（ets）          │   │ ArkTS MethodCallHandler        │
│ - 注册 XComponent          │   │ - launch(rom,core,platform)    │
│ - 把 OH_NativeXComponent*  │   │ - setInputState(mask,port)     │
│   交给 native 宿主         │   │ - exit()                       │
└───────────────┬──────────┘   └──────────────┬───────────────┘
                │                              │
                └──────────┬───────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────┐
│ 原生宿主 libgpretro.so（C/C++）                            │
│  - dlopen(<core>_libretro_ohos.so)                        │
│  - 实现 libretro 回调：                                   │
│      video  → EGL/GLES3 渲染到 OHNativeWindow             │
│      audio  → OHAudio 播放 retro_audio_sample_batch_t      │
│      input  → 返回来自 MethodChannel 的按钮掩码            │
│  - 独立线程按 libretro AV 速率（NES NTSC 60.0988fps）步进   │
└──────────────────────────────────────────────────────────┘
```

要点：复用 Android「**独立步进线程 + GL 仅 present**」的 pacing 架构（核心以 `CLOCK_MONOTONIC` 绝对时间线步进，与显示刷新 60/90/120Hz 解耦，避免 120Hz 屏 2× 速、GL jitter 丢帧）。

---

## 3. 集成契约（与现有 Dart 对齐，零 Dart 改动）

`gs/emulator.launch` 入参解析（native 宿主侧）：

| 字段 | 解析 |
|---|---|
| `rom` | `<filesDir>/roms/<rom>`（`filesDir` 即 `appCtx.filesDir`，P3 已实现并真机验证） |
| `core` | coreId → core `.so` 名，如 `fceumm` → `libfceumm_libretro_ohos.so` |
| `platform` | 仅用于 UI/日志，不影响宿主 |
| `netplay` | 单机关键路径**必须 byte-identical**；首版可忽略，M4 再接 |

路径约定（对齐 Android `EmulatorActivity` 的 `renderer.*Dir`）：
- `systemDir` = `<filesDir>/system`（BIOS / 机器文件）
- `saveDir`  = `<filesDir>/saves`
- `saveKey`   = ROM 主干名（SRAM/state 落盘键）
- `core` `.so` 存放：优先 `libs/arm64-v8a/`，或从 `assets/core/` 运行时解压到 `<filesDir>/core/` 后 `dlopen`

返回值：`bool` — `true` = 已启动并进入渲染；`false` = core 缺失 / 启动超时 / 加载失败。

输入桥（新增 `gs/emulator.setInputState`）：Flutter 虚拟手柄 → `buttonMask:int` + `playerPort:int`（街机 1P/2P）→ ArkTS → native 写入 `volatile int`；复用 Android 的 `buttonMask`/`playerPort`/`inputRotated90` 重映射语义（`inputRotated90` 时 D-pad 掩码旋转 90° CW）。

生命周期（对齐 Android）：`launch` **立即返回**，宿主在后台/退出时落盘 SRAM；Dart 侧在 `AppLifecycleState.resumed` 回读存档（见 `library_page.dart` already does this）。

---

## 4. libretro.h 适配要点

libretro 是纯 C 接口（`retro_init`/`retro_deinit`/`retro_load_game`/`retro_run`/`retro_set_*_callback`/`retro_get_system_av_info` …），跨平台，基本无需改。平台相关点：

| 关注点 | 处理 |
|---|---|
| 线程 | core 内若用 `pthread` → OHOS 提供 POSIX 线程，一般可直用 |
| 文件 I/O | core 经 `retro_get_system_info.need_fullpath` 决定；多数用标准 `stdio`，在应用沙箱内可用（注意用 `filesDir` 沙箱路径，勿用绝对 `/data`） |
| 计时 | `retro_run` 由宿主驱动；用 `clock_gettime(CLOCK_MONOTONIC)` 做 AV 级 pacing（同 Android） |
| 内存/对齐 | OHOS 为 ELF aarch64，对齐规则同 Linux |
| 像素格式 | 处理 `RETRO_PIXEL_FORMAT_0RGB1555 / RGB565 / XRGB8888 / RGB565`（宿主做纹理上传） |

---

## 5. Core 构建（最小闭环先 fceumm / NES）

1. 取自 `libretro-fceumm`（或 `libretro-super` 单 core）。
2. 用 OHOS NDK CMake 工具链（clang，`aarch64-linux-ohos`）产出 `libfceumm_libretro_ohos.so`。
3. 各 core 的 `Makefile`/`libretro-common` 基本 POSIX，需补一个 `toolchain-ohos.cmake`：
   - `CMAKE_SYSTEM_NAME=OHOS`
   - `CMAKE_SYSROOT=<Sdk>/26.0.0/native/sysroot`
   - `CMAKE_C_COMPILER=/.../llvm/bin/clang` + `-target aarch64-linux-ohos`
   - `OHOS_STL=c++_shared`
4. 打包：core `.so` 进 HAP `libs/arm64-v8a/`，或运行时从 `assets/core/` 解压到 `<filesDir>/core/` 后 `dlopen`。
5. **风险**：FBNeo / MAME 体量大、依赖多，放 M2+；首版**只 fceumm（NES）** 即可验证整条链路。

---

## 6. 渲染（XComponent + EGL / GLES3）

- ArkTS：`<XComponent type="surface" id="emu">`；native 侧 `OH_NativeXComponent_RegisterCallback` 注册：

```c
static void OnSurfaceCreated(void* component, void* window) {
    // window 即 OHNativeWindow*，可直接用于 EGL
    OHNativeWindow* nativeWindow = (OHNativeWindow*)window;
    egl_surface = eglCreateWindowSurface(egl_display, egl_config,
                                         (EGLNativeWindowType)nativeWindow, nullptr);
}
OH_NativeXComponent_Callback cb = { OnSurfaceCreated, OnSurfaceChanged, DispatchTouchEvent };
OH_NativeXComponent_RegisterCallback(xcomponent, &cb);
```

- 渲染：`eglGetDisplay(EGL_DEFAULT_DISPLAY)` → `eglCreateWindowSurface` → GLES3 把 libretro 帧纹理贴到全屏 quad。
- 复用 Android 已有的画面适配逻辑：NES NTSC 8:7 PAR、竖屏街机 90° 旋转 letterbox、`coreAspect` 取 `retro_system_av_info.geometry.aspect_ratio`。
- 与 Flutter 集成：**推荐 `PlatformView`（OHOSView）** 整屏铺 XComponent，虚拟手柄等用 Flutter 叠层（贴合 Android「native surface + Flutter overlay」模式）。备选 `Texture`（外接纹理），优先级低。

---

## 7. 音频（OHAudio，OpenSLES 兜底）

- 用 `OH_AudioStreamBuilder` + `OH_AudioRenderer`（头文件 `ohaudio/native_audio_stream_manager.h`、`ohaudio/native_audiorenderer.h`，sysroot 已带 `libohaudio.so`）。
- 采样率取 `retro_system_av_info.timing.sample_rate`（通常 44100 / 48000）。
- 在 `retro_audio_sample_batch_t` 回调里把 int16 批写入 AudioStream 的环形 `write` 缓冲。
- `<SLES/OpenSLES.h>` 同样存在于 sysroot，可作为兜底；但 OHAudio 是 API 10+ 主推，优先。

---

## 8. 输入桥

- Flutter 虚拟手柄 → `gs/emulator.setInputState`(`buttonMask`, `playerPort`) → ArkTS → native 写入 `volatile int buttonMask` / `playerPort`。
- 实现 `retro_set_input_state_t`：按 `port` / `device` / `index` / `id` 返回当前掩码（逐位映射到 libretro `RETRO_DEVICE_JOYPAD_*`）。
- 竖屏 90° 旋转的 D-pad 重映射逻辑直接搬运 Android `EmulatorActivity` 的 `inputRotated90` 分支。

---

## 9. 构建系统改动（entry 模块）

新增 `app/ohos/entry/src/main/cpp/`：

```
cpp/
  CMakeLists.txt
  gpretro_host.cpp / .h     # libretro 宿主 + libretro.h
  third_party/<core>/...    # core 源码（或预编译 .so）
```

`build-profile.json5` 增加（当前**缺失**，需补）：

```json5
"externalNativeOptions": {
  "path": "./src/main/cpp/CMakeLists.txt",
  "arguments": "-DOHOS_STL=c++_shared",
  "cppFlags": "-std=c++17 -fstack-protector-strong",
  "abiFilters": ["arm64-v8a"]
}
```

`CMakeLists.txt` 链接：`libEGL.so`、`libGLESv3.so`、`libohaudio.so`（sysroot 已含）、`libdl`（dlopen）、`libpthread`。

---

## 10. 风险 / 开放问题

| 项 | 说明 |
|---|---|
| XComponent × Flutter PlatformView | 需验证 `PlatformViewLink`/`OHOSView` 能否把 `OH_NativeXComponent*` 交给 native；若不行则改 `Texture` 外接纹理 |
| core 源码兼容 | 个别 core 用 GNU 扩展/内联汇编，需少量 shim（首版 fceumm 风险最低） |
| 性能 | EGL 线程 vs Flutter vs 输入延迟；复用 Android「独立步进线程 + GL 仅 present」 |
| netplay 帧同步 | M4 级；依赖 UDP 多播锁（已在 `gs/storage` 标注 OHOS 暂无公开等价 API） |
| 签名/权限 | native `.so` 须与 HAP 同签名；音频/图形权限默认具备 |

---

## 11. 里程碑（建议）

| 阶段 | 周期 | 交付 |
|---|---|---|
| **M0 spike** | 1–2 天 | 空 XComponent + EGL 清屏 + OHAudio 正弦音，验证原生窗口/音频链路 |
| **M1 NES 可玩** | 1–2 周 | `fceumm` core 跑通 NES ROM：画面 + 声音 + 按键；单机关键路径对齐 `launchEmulator` 契约 |
| **M2 扩 core** | 2–3 周 | `gambatte`(GB/GBC)/`mgba`(GBA) 加入；`toolchain-ohos.cmake` + core 自动打包固化 |
| **M3 体验** | 1–2 周 | 输入重映射 / 竖屏旋转 / `saveKey` 落盘 / cheats 接入 |
| **M4 街机+联机** | 2–4 周 | `fbneo`/`mame` 街机（大 core）、netplay 帧同步（state0 对齐） |

---

## 12. 与既有文档的关系

- `docs/skills.md` §2.6 的 `gs/emulator.launch` 行：从「OHOS 暂无 libretro core runtime → 返回 false」改为「见 `docs/ohos-libretro-port.md`，设计完成，实现待排期」。
- `docs/ohos7-feasibility.md` §5.2 P4-①：标记「设计完成，进入实现阶段（M0–M4）」。
