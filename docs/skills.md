# GamePouch 本地开发 Skill 手册

> 目标：把「编译 / 调试 / 真机连接」的标准动作固化下来，新终端、换机、复现 bug 时照做即可。
> 所有工具链都在项目 `.tools/` 下（flutter / jdk / android-sdk / gradle / pub 缓存），对系统**零污染**。

---

## 0. 一句话总览

每个新终端先点源环境脚本，再干活：

```powershell
cd D:\ai\prj\trae\HuaWei\RetroEmuPouch
. .\scripts\use-env.ps1            # Android / Flutter
# 鸿蒙 NEXT 用： . .\scripts\use-env.ps1 -Ohos
```

`use-env.ps1` 会注入 `JAVA_HOME / ANDROID_HOME / PUB_CACHE / GRADLE_USER_HOME / flutter 镜像源`，
并把 `flutter`、`adb`、`keytool` 加入 `PATH`。之后直接用 `flutter` / `adb` 即可。

> ⚠️ 不要用系统自带的 `flutter`：系统 PATH 里的 Dart 是 3.4，项目要求 `>=3.13`，必须用 `.tools\flutter`。

---

## 1. 环境初始化（首次 / 换机）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-env.ps1
```

- 复用兄弟项目 **MyLangLean** 的共享工具链，通过 **junction** 挂到本仓库 `.tools/`，
  不重复下载（jdk17 / android-sdk / flutter / flutter_ohos / caches）。
- ⚠️ **`jdk21` 是实体目录，不是 junction**：Gradle 9.8 + JDK21 可避开 JDK17 冷启动的
  Kotlin-DSL 报错，而它的历史来源是同级的 MyGameSim 项目（**该项目已移除**）。
  `setup-env.ps1` 现在按 `-Jdk21Source` → `.tools\jdk21` → **Android Studio 自带 JBR**
  → `JAVA_HOME_21`/`JAVA21_HOME` 的顺序探测，命中就 `robocopy` 成本地实体副本。
  **换机器 clone 本仓库即可自包含构建**，不需要旁边还有别的项目。
- 幂等，可重复跑。
- 结束后它会提示你：新终端先 `. .\scripts\use-env.ps1`。

---

## 2. 编译 APK

用项目自带的构建脚本（它会自动设好所有环境变量，**不要**直接 `flutter build apk`）：

```powershell
# Release（默认产物）
powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store

# Debug（迭代更快，签名用 debug keystore）
powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store -DebugBuild

# 按 ABI 拆分（可选）
powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store -SplitPerAbi
```

要点：

- `Flavor` 取值 `store | community`；脚本会自动传 `--dart-define CHANNEL=$Flavor`，
  必须和 `build.gradle.kts` 的 flavor 对应（store 街机用 **mame** 核心，community 用 **fbalpha2012**）。
- 产物：`app\build\app\outputs\flutter-apk\app-<flavor>-release.apk`（或 `-debug`）。
- 详细日志写在仓库根的 `build-apk.log`。
- `community` flavor 是含 FBA-2012（非商业授权）的版本；上架走 `store`。

## 2.5 编译 MAME 街机核心（libretro 交叉编译）

街机核心 `libgs_mame.so`（编译产物名 `mamegamepouch_libretro_android.so`）经 **WSL + NDK** 交叉编译，脚本 `scripts/build-mame.ps1`：

```powershell
# 完整流程：克隆 + 同步 build/mame-src → WSL 克隆 + genie 生成 + 编译，并把 newest 的 .so 装成 libgs_mame.so 进 jniLibs
powershell -ExecutionPolicy Bypass -File scripts\build-mame.ps1 -Subtarget gamepouch
# 跳过克隆（复用已有 WSL 克隆，更快）
powershell -ExecutionPolicy Bypass -File scripts\build-mame.ps1 -SkipClone -Subtarget gamepouch
```

产物装到 `app/android/app/src/store/jniLibs/arm64-v8a/libgs_mame.so`，随后 `build-apk.ps1` 打包进 APK。

⚠️ **构建源坑（必读，曾耗多轮排查）**：`-SkipClone` 会**同时跳过** `build/mame-src → ~/mame-build/mame` 的 `cp -a` 同步。
**实际编译的是 WSL 克隆 `~/mame-build/mame`**，不是 Windows 侧 `build/mame-src`。因此改 MAME 核心源码时：
- 改 `build/mame-src` 后必须**带同步**才进编译；最稳是直接编辑 WSL 克隆 `~/mame-build/mame/src/...`；
- 若给 `-SkipClone` 补同步步骤，注意**方向**为 `cp -a build/mame-src/* ~/mame-build/mame/`，别反向把 WSL 已落地的改动覆盖掉。

⚠️ **genie 生成坑**：genie 工具链探测要求 NDK 含 `linux-x86_64` 的 clang；本机 `.tools` 的 NDK 是 `windows-x86_64` 版，WSL 里跑 `genie` 会报 `Clang version 13 or later needed` 而失败。绕过：已有 genie Makefile 时直接用 `make config=libretro -jN`（目录 `~/mame-build/mame/build/projects/retro/mamegamepouch/gmake-android-arm64`），并 `export ANDROID_NDK_HOME/ANDROID_NDK_ROOT` 指向那个 `windows-x86_64` 目录——`clang.exe` 能经 WSL 互操作运行。`build-mame.ps1` 的 `.so` 选择用「按 mtime 取最新」（`find -printf '%T@' | sort -rn | head`），避免 `find | head` 命中陈旧 `.so`。

---

## 2.6 编译鸿蒙 HAP（HarmonyOS NEXT / API 26）

目标设备 Pura70 **同时可跑 HarmonyOS NEXT 与 OpenHarmony**（均为 API 26）。本工程以 **HarmonyOS NEXT**
为目标以对接华为应用市场（AppGallery）——`runtimeOS` 必须为 `"HarmonyOS"`（OpenHarmony 应用无法上架应用市场）。
HarmonyOS SDK（带 hms）位于 DevEco `D:\HuaWei\DevEco-Studio\sdk\default`。鸿蒙工具链在 `.tools\flutter_ohos`（fork 3.41.10 / Dart 3.11.5），
与 Android 的 `.tools\flutter` 在 `PATH`/`PUB_CACHE` 上互斥，必须点源 `-Ohos` 环境：

```powershell
cd D:\ai\prj\trae\HuaWei\RetroEmuPouch\app
. ..\scripts\use-env.ps1 -Ohos -HarmonyOS
```

`use-env.ps1 -Ohos -HarmonyOS` 关键注入（详见脚本）：
- 默认 `-Ohos`（不带 `-HarmonyOS`）指向 OpenHarmony SDK（`D:\HuaWei\OhosSdkForFlutter` junction）。
- 加 `-HarmonyOS` 后，`OHOS_SDK_HOME` / `OHOS_HOME` / `DEVECO_SDK_HOME` / `HOS_SDK_HOME` 全部切到
  DevEco 的 **HarmonyOS 26 SDK**（`D:\HuaWei\DevEco-Studio\sdk\default`，含 hms）；`build-hap.ps1` 现已默认带 `-HarmonyOS`。
- `OHOS_BASE_SDK_HOME` 指向 HarmonyOS SDK 根：hvigor 读其 `licenses/` 校验 SDK 许可，许可接受后 hvigor 才能过（见下）。

### 工程配置（app/ohos，已固化：目标 = HarmonyOS NEXT）

`runtimeOS` 必须为 `"HarmonyOS"`（AppGallery 硬性要求；OpenHarmony 应用无法上架应用市场）：

| 文件 | 字段 | 值 |
|---|---|---|
| `build-profile.json5`（app 级）+ `entry/build-profile.json5` | `runtimeOS` | `"HarmonyOS"` |
| 同上 | `compatibleSdkVersion` / `compileSdkVersion` / `targetSdkVersion` | `"26.0.0"`（**纯版本号**，不带 HarmonyOS 的 `(API)` 后缀，否则 `ApiVersion` 解析报 "api version parameter is illegal"） |
| `oh-package.json5` + `hvigor/hvigor-config.json5` | `modelVersion` | `"6.0.0"`（API ≥ 26 要求 ≥ 6.0.0） |
| `entry/src/main/module.json5` | `deviceTypes` | `["default"]`（HarmonyOS/OpenHarmony SDK 26 的 `device-define` 无 `phone`，否则 SyscapTransform 报 "intersection ... is empty"） |

> SDK 许可：HarmonyOS SDK（`D:\HuaWei\DevEco-Studio\sdk\default`）的 `licenses/` 需已接受许可
> （DevEco Studio → SDK Manager 的一次性接受步骤）。未接受会报 `SDK license agreement is not accepted`。

### 构建

```powershell
cd D:\ai\prj\trae\HuaWei\RetroEmuPouch\app
. ..\scripts\use-env.ps1 -Ohos -HarmonyOS

# 未签名 HAP（CI/集成用，不能装真机；本地真机调试需 DevEco 自动签名或 AGC 发布证书）
flutter build hap --debug --no-codesign
# 产物： build\ohos\hap\entry-default-unsigned.hap

# 签名版：需 DevEco 自动签名 material 或本地脚本（见下）
flutter build hap --debug
```

- `scripts/build-hap.ps1` 封装上述（点源 `use-env.ps1 -Ohos -HarmonyOS` 后调 `flutter build hap`）。
- 构建成功标志：`√ Built build\ohos\hap\entry-default-unsigned.hap.`，hvigor 任务全过；
  产物为 **HarmonyOS NEXT** HAP（可经 AppGallery 上架）。
- 包名（bundleName）：鸿蒙侧为 `com.gamepouch.gamepouch`（Android 是 `com.retroemupouch.app`），
  两端不同，互不影响。

### 签名（debug，本地可装）

未签名 HAP 用 `hdc install` 报 `no signature file`（code 9568320），**必须签名**。两条路：

1. **DevEco 一键（推荐，可装 HAP 的最短路径）**：DevEco 打开 `app/ohos` →
   File → Project Structure → Signing Configs → 勾选 **Automatically generate signature**。
   之后 `scripts/build-hap.ps1` 直接产出可 `hdc install` 的签名 HAP（工具链自身报错也如此提示）。

2. **本地脚本** `scripts/sign-ohos-hap.ps1`：用 `hap-sign-tool.jar`
   （`D:\HuaWei\Sdk\26.0.0\toolchains\lib`）生成自签 CA → app/profile 叶证书（**均须 ECC/NIST-P-256**，
   因 `sign-profile`/`sign-app` 只接受 ECDSA）→ 组装证书链（**无 BOM、base64 行无空格**）→
   注入 app 证书链 + 设备 udid + 刷新有效期的 debug profile 模板 → `sign-profile` 产出
   `debug.p7b` → `sign-app` 签 HAP。
   - ✅ **`sign-app` 已修复并跑通**（曾卡数月级 base64 报错，根因在 profile 模板的 `development-certificate`
     字段格式）：
     1. 该字段必须是**证书链**，不能是单叶证书（否则 `Profile cert must a cert chain`）；
     2. 且必须是 **base64url 编码的「两证书 DER 拼接」连续串**——先各自 PEM→DER、拼接字节、再整体
        base64url（`+`→`-`、`/`→`_`、去 `=`），**不能**带 `-----BEGIN/END-----` 头尾（含空格→`Illegal base64 character 20`）、
        **不能**换行（→`Illegal base64 character a`）、**不能**各自 base64 后拼接（→`Last unit does not have enough valid bits`）；
     3. `sign-app` 的 `-appCertFile` 也要传**链文件** `debug-app-chain.cer`（传单叶会报 `must a cert chain`）。
   - 结果：`flutter build hap --debug --no-codesign` 产出 unsigned.hap 后，脚本可产出
     `entry-default-signed.hap`（约 125 MB），`sign-app success`。

```powershell
# 本地签名（自签 CA；CLI 已跑通 sign-app，产出 entry-default-signed.hap）
powershell -ExecutionPolicy Bypass -File ..\scripts\sign-ohos-hap.ps1
```

### 安装到设备

```powershell
hdc list targets
hdc install build\ohos\hap\entry-default-signed.hap
# 覆盖： hdc install -r ...
# 卸载： hdc uninstall com.gamepouch.gamepouch
```

> ⚠️ **自签 CA 的设备信任问题**：本地脚本用**自签 CA** 签的 HAP，`hdc install` 会报
> `fail to verify pkcs7 file`（code **9568257**）——因为本机 pura70 只信任 **DevEco 自动签名**用的
> CA（参考项目 `MyApplication` 在 `C:\Users\liuzhixing\.ohos\config\default_MyApplication_*.{cer,p7b,p12}` 的材料，
> 设备已信任）。**在真机上装可运行 HAP 的可靠路径是 DevEco 自动签名**（见上「1. DevEco 一键」）：
> 它把受信任的调试 CA 装进设备，产出的 HAP 才能 `hdc install` 成功。纯 CLI 自签 pipeline 已跑通
> （`sign-app success` 产出 `entry-default-signed.hap`），仅差设备侧 CA 信任这一步。

### 真机联调速查（hdc：连接 / 日志 / 启动 / 截图 / UI 自动化）

鸿蒙用 **`hdc`**（OpenHarmony Device Connector，随 SDK 装好，命令行直接 `hdc`）而非 Android 的 `adb`。
下面是从连设备到抓日志、截图的完整联调链路；解锁/锁屏等前置坑见下「Pura70 调试前置要求」。

**1. 连接**
```powershell
hdc list targets                          # 看到 SN 即已连上（USB 直连自动识别）
hdc tconn 192.168.x.x:5555               # 无线调试：设备开「无线调试」后连 IP:端口
hdc -t <SN> <cmd>                        # 多设备时指定 SN（如 2MN0224730027764）
```

**2. 安装 / 卸载**（自签 CA 设备不信任，优先 DevEco 自动签名；详见上「安装到设备」）
```powershell
hdc install  build\ohos\hap\entry-default-signed.hap
hdc install -r build\ohos\hap\entry-default-signed.hap   # 覆盖安装
hdc uninstall com.gamepouch.gamepouch
```

**3. 启动 App**
```powershell
hdc shell aa start -a EntryAbility -b com.gamepouch.gamepouch
# 默认进 pages/EmulatorSpike（横屏）；回文件库点右上角 ✕（横屏 2844×1260 下约 (2742,186)）
```

**4. 抓日志（hilog）**——OHOS 等价 Android logcat：
```powershell
hdc shell hilog                              # 实时全部日志
hdc shell "hilog | grep GS-"                 # 过滤（GS-Main 是 MainActivity TAG；Dart/Flutter 框架日志也走 hilog）
hdc shell hilog > hilog.txt                  # 落盘
hdc shell hilog -r                           # 清屏
```
> ⚠️ 启动期 Dart 异常（如白屏根因）在 hilog 里**几乎没有 Dart 栈**，靠「启动依赖全部 try/catch 容错」兜底（见下白屏排查）。

**5. 截图 / UI 自动化（uitest）**
```powershell
hdc shell snapshot_display -f /data/local/tmp/x.jpeg     # 截图
hdc file recv /data/local/tmp/x.jpeg ./x.jpeg           # 取回本机
hdc shell "uitest uiInput click 2742 186"              # 坐标点按（用实际分辨率）
hdc shell "uitest uiInput swipe x1 y1 x2 y2 ms"
```
> Pura70 无 `input` 命令、`power-shell wakeup` 只点亮到锁屏页；解锁/防锁前置见下「Pura70 调试前置要求」。

#### 真机运行：首屏白屏排查（已踩坑）

`flutter build hap --debug`（DevEco 自动签名）装到 pura70 **能启动、首帧也画了，但整屏纯白**——
根因不在渲染，而在 `main()` 在 `runApp()` 之前就因异常中止：

1. **`shared_preferences` 在 OHOS 无原生 handler** → `SharedPreferences.getInstance()` 抛
   `MissingPluginException(No implementation found for method getAll on channel plugins.flutter.io/shared_preferences)`。
   `main.dart` 第 24 行 `await AppSettings.load()`（内部即 `getInstance()`）与第 39 行 consent 检查
   的 `getInstance()` 当时都没捕获 → 整个 `main()` 抛异常中止 → `runApp()` 从未执行 → 纯白屏。
   - 修复：`app/lib/features/settings/app_settings.dart` 的 `load()`/`save()` 用 `try/catch` 兜住，
     插件缺失时回退默认值（内存态）；`main.dart` 把 `checkMissing`/`loadAsset`/consent `getInstance()`
     全部包 `try/catch`，任一缺失就跳过、照样 `runApp(GamePouchApp())`。
   - **教训**：OHOS 上任何「无原生实现」的插件一旦在**启动关键路径**被 `await`，都会让 `main()`
     静默中止 → 白屏，且 hilog 里几乎看不到 Dart 栈。启动依赖务必容错。

2. **`OhosPal` 原 `on PlatformException` 抓不到 `MissingPluginException`**：`MissingPluginException`
   **不是** `PlatformException` 的子类（它 `implements Exception`），所以无原生 handler 时异常仍向上抛，
   被 `LibraryPage` 捕获成「初始化失败：MissingPluginException(No implementation found for method
   getFilesDir on channel gs/storage)」红屏。已全部改为 `catch (_)`（见 `app/lib/pal/ohos_pal.dart`），
   确保无原生 handler 时返回安全默认值而非崩溃。

#### 真机运行：Pura70 调试前置要求（锁屏 / 息屏，必读）

Pura70（SN `2MN0224730027764`）是**开发者模式 + 指纹/密码锁**。锁屏后 `aa start` 直接拒绝
（`Error Code:10106102 … screen locked … unlock screen failed`），而该机**没有 `input` 命令**、`uitest` 也绕不过
生物/密码、`power-shell wakeup` 只能点亮到锁屏页——所以只要一锁就必须人手动解锁。

##### 彻底免解锁（推荐，一次性设备设置，之后零手动解锁）

1. **去掉锁屏密码**：设置 → 生物识别和密码 → 关闭密码/无密码。去掉后唤醒不再要凭证，
   `aa start` / `uitest` / `snapshot_display` 任何时候都能直接跑（代价：设备无锁屏保护，仅用于开发机）。
2. **开启「充电时保持唤醒」**：设置 → 系统 → 开发人员选项 → **充电时保持唤醒**（或「保持唤醒 / 不锁定屏幕」）。
   hdc 走 USB，手机恒处充电态，屏幕常亮、**永不锁屏**。

两者都开后调试链路完全自动化：`power-shell wakeup`（可选）+ `aa start` 直接成功，全程无需碰手机。
只做第 2 条、保留密码也可以——USB 连接期间屏幕不睡、不会锁；唯一会锁是拔掉 USB。

##### 临时 / 兜底（必须保留密码时）

- **现象**：`aa start -a EntryAbility -b com.gamepouch.gamepouch` 报
  `Error Code:10106102 … The device screen is locked during the application launch, unlock screen failed`
  （开发者模式不会自动解锁）；约 **2 分钟**无操作自动息屏 → 再解锁前 `aa start` 一直失败。
- **该机无 `input` 命令**（`hdc shell input …` → `/bin/sh: input: inaccessible or not found`）。`uitest` 替代品：
  `hdc shell "uitest uiInput swipe x1 y1 x2 y2 ms"`、`uitest uiInput click x y`、`uitest uiInput keyEvent <code>`
  （坐标用**实际分辨率**：Pura70 竖 1260×2844 / 横 2844×1260）。
- **`power-shell wakeup` 只能点亮到锁屏页**；`power-shell timeout -o` 只能延长息屏、不能解锁。
- **一次性解锁 + 防再锁**：先由**人**用指纹/PIN 解锁，随后立即把息屏超时拉到 30 分钟并切 normal：

  ```powershell
  hdc -t 2MN0224730027764 shell "power-shell timeout -o 1800000"  # 息屏超时 30 分钟（ms）
  hdc -t 2MN0224730027764 shell "power-shell setmode 600"          # 600=normal / 601=power save / 602=performance / 603=extreme
  ```
  成功后分别返回 `Override screen off time to 1800000` 与 `Set Mode Success!`。此后**只要屏幕不熄灭就不会再自动锁**，
  后续 `aa start`、`uitest` 点按、`snapshot_display` 截图都能稳定进行（注意：30 分钟一到仍会锁，长会话请用上面的「充电时保持唤醒」）。
- **`aa start` 成功后的页面导航**：App 默认进入 `pages/EmulatorSpike`（横屏）。要回到**文件库**，点右上角 **✕**
  （`EmulatorSpike.ets` 中 `onClick(() => router.back())`）；Pura70 横向 2844×1260 下约在 `(2742, 186)`，
  可用 `uitest uiInput click 2742 186` 命中。库页是**竖屏** 1260×2844。
- **截图**：`hdc shell snapshot_display -f /data/local/tmp/x.jpeg` → `hdc file recv /data/local/tmp/x.jpeg ./x.jpeg`。

> 一句话：**推荐去掉锁屏密码 + 开启「充电时保持唤醒」→ 之后 `aa start` / `uitest` 全程免解锁**；
> 若必须保留密码，则「人解锁一次 + `power-shell timeout -o 1800000` + `setmode 600`」，但 30 分钟后仍会锁。

#### 签名与包名的硬约束（2026-10-28 真机回归发现，必读）

1. **`app/ohos/build-profile.json5` 的 `signingConfigs` 在分叉时曾丢失** → `flutter build hap`
   静默产出 **unsigned** HAP，flutter 工具报 `Hvigor build failed to produce an hap file`（产物只有
   `entry-default-unsigned.hap`）。修复 = 恢复两处：
   - `"app"` 下加 `signingConfigs`（材料在 `C:\Users\liuzhixing\.ohos\config\default_ohos_*.{cer,p12,p7b}`，密码为 DevEco 加密串，可参考 GamePouch 同名文件）；
   - `products[0]` 里必须显式 `"signingConfig": "default"`（只加 signingConfigs 不引用**无效**）。
2. **AGC 调试 profile 与 bundleName 绑定**：本机受信任的 `default_ohos_*.p7b` 绑定
   `com.gamepouch.gamepouch`（可解包 p7b 查 `bundle-name` 字段核对）。若 `AppScope/app.json5`
   的 `bundleName` 与 profile 不一致，hvigor `SignHap` 报
   `The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs`。
   本项目鸿蒙侧包名已固定回 `com.gamepouch.gamepouch`（与设备已装应用同包名，`hdc install -r`
   原地升级、用户数据保留）。**若未来要上架独立包名，需先在 AGC/DevEco 为新包名生成调试 profile（GUI 操作）**。
3. **hdc USB 半开恢复**：安装/启动过程中 USB 掉线后，`hdc list targets` 仍显示设备但所有命令报
   `need connect-key? please confirm a device`（`list targets -v` 状态 `Connected/unknown`）。
   依次试：`hdc kill` → `hdc start` → 重试；轮询 2 分钟；仍不行=设备端 hdcd 卡死，**需物理重插 USB**
   （设备无 input 命令，无法远程恢复）。
4. **鸿蒙功能自动化路径**：`uitest uiInput` 对 Flutter 内容无效（DOWN 到达、UP 丢失，hilog 可见
   `VoteTouchValue TOUCH_UP timeout`），点 ArkUI 覆盖层（模拟器 ✕、系统弹窗）有效。Flutter 层功能用
   `GP_OHOS_SELFTEST` 探针自动化（build-hap.ps1 -DartDefine），报告在
   `<filesDir>/selftest.txt`，用 `hdc shell -b com.gamepouch.gamepouch cat /data/app/el2/100/base/com.gamepouch.gamepouch/files/selftest.txt` 读取。

#### 已知问题与修复记录（netplay 对端退出卡死，2026-10-31）

**现象**：OHOS 客机联机中，安卓端（或任一对端）退出/掉线后，鸿蒙端**不闪退但卡死在游戏界面**（UI 线程冻结、按 ✕/返回也无反应，只能强杀进程）。日志里有 `netplay terminal (peer gone) → auto exitToLibrary` 与 `teardown(clean=false)`、且 Flutter 收到 `emitNetplayPlayEnded`，但页面始终不弹回文件库。

**根因（两层）**：
1. **原生 use-after-free 隐患**（`app/ohos/entry/src/main/cpp/gpretro.cpp` 的 `NativeNetplayStop`）：旧实现 `g_net->shutdown(); delete g_net;` 只 join 了 `gs-net` 接收线程，**没有先停渲染/步进线程** `g_renderThread`（OHOS 上显示为 `pouch.gamepouch`，每帧调 `g_net->beginFrame()/endFrame()`）。对端掉线后 `g_net` 被释放，该线程仍在 100ms 睡眠/步进后访问已释放对象 → SIGSEGV 闪退。
2. **ArkTS 逻辑 bug**（`app/ohos/entry/src/main/ets/pages/EmulatorSpike.ets`）：`onNetplayStatus` 在调用 `exitToLibrary()` **之前**就 `this.ending = true`，而 `exitToLibrary()` 第一行就是 `if (this.ending) return` —— 于是 `exitToLibrary()` 直接 no-op，`netplay.stop()` / `stopEmulator()` / `router.back()` 全不执行，**页面永远弹不掉**（这才是「卡死」主因；上面的 SIGSEGV 修复只是消除了崩溃，但 no-op 让页面卡住）。

**修复**：
- `NativeNetplayStop` 改为自洽顺序：`g_net->shutdown()`（置 `running_=false`、join 接收线程）→ `StopEmulator()`（置 `g_running=false`、join 渲染线程；因 `running_` 已 false，`beginFrame` 立即返回 `Dead`，join 不会卡到 10s 掉线计时）→ `delete g_net`。无论 ArkTS 调用顺序如何，原生 teardown 都先把线程 join 再释放，杜绝 use-after-free。
- `exitToLibrary()` 的调用顺序：`netplay.stop()`（内部走上面的 `NativeNetplayStop`）**先**跑，`stopEmulator()` 仅作兜底（netplay 已停时为 no-op），最后 `router.back()`。绝不能先 `stopEmulator()` 再 `netplay.stop()` —— 否则 `stopEmulator()` 的 join 会卡在 `beginFrame` 等已掉线对端，造成 UI 线程死锁。
- `onNetplayStatus` **不再**提前 `this.ending = true`，改由 `exitToLibrary()` 自己置位（否则守卫让函数变 no-op）。

**验证**：安卓主机选同一联机游戏发「联机玩」，鸿蒙客机接受 → 开始，安卓端退出 → 鸿蒙端自动返回文件库、无闪退/无卡死。日志应出现 `netplay terminal (peer gone) → auto exitToLibrary`，且 `teardown(clean=true)`（来自 `exitToLibrary` 的 `netplay.stop()`），**无 SIGSEGV / 无 JANK 卡死 / 进程正常回到库页**。

### P3：OHOS 原生 handler（ArkTS 插件）

`OhosPal` 的 4 个通道（`gs/storage`/`gs/emulator`/`gs/updater`/`gs/netplay`）由
`app/ohos/entry/src/main/ets/plugins/GamePouchPlugin.ets` 实现，并在
`EntryAbility.configureFlutterEngine` 里注册：

```ts
flutterEngine.getPlugins()?.add(new GamePouchPlugin(this.context))
```

（`GeneratedPluginRegistrant.ets` 是生成文件、勿改；自有插件直接挂在 EntryAbility。
`this.context` 是 UIAbilityContext，SAF picker 弹窗必须用它，ApplicationContext 不行。）

**ArkTS 严格模式的坑（都已踩过并固化）：**
- `FlutterPlugin` 接口**必须实现** `getUniqueClassName(): string`，否则 `add()` 报类型不匹配。
- `MethodCall` 的参数属性是 **`call.argument`**（单数），不是 `arguments`。
- `setMethodCallHandler` 可直接传对象字面量 `{ onMethodCall: (call, result) => ... }`（无需类实现 `MethodCallHandler`）；按通道区分时用闭包捕获通道名。
- **禁止内联对象类型**做返回类型（`arkts-no-obj-literals-as-types`）→ 声明具名 `interface`（`RomInfo`/`PkgInfo`/`CallArgs` 等）。
- **禁止 `any`/`unknown`**（`arkts-no-any-unknown`）→ 不要用 `ESObject` 作参数类型，改用具名 interface。
- `@ohos.file.statvfs` 默认导入是**命名空间**且各版本 API 形态不一（`statfs`/`statvfsSync`），当前 `getAvailableBytes` 直接返回 0 规避。
- `@ohos.file.fileuri` 在该 SDK **没有** `getFileNameByUri` 导出 → 从 URI 末段解析文件名。
- `DocumentViewPicker.save` 该版本**不接受** `suggestedName`/`pickerMode` → 传 `{}`。

**已实现行为：**

| 通道/方法 | 实现 |
|---|---|
| `gs/storage.getFilesDir` | `appCtx.filesDir`（真机验证库页正常） |
| `getDeviceModel` / `deleteBios` | `deviceInfo.productModel` / 删 `system/<name>` 及 per-core 镜像 |
| SAF 导入 | `importRomViaSaf`（拷贝到 `roms/` + 分块 CRC32）、`importPackageViaSaf`、`importBiosViaSaf`、`importBiosBatchViaSaf`、`importMoves/PadConfigViaSaf` |
| SAF 导出 | `exportPackage/MovesConfig/PadConfigViaSaf`（`DocumentViewPicker.save` + 拷贝）；`exportBiosZipViaSaf` 用 `zlib.zipFile` 打包 `system/` 后经 SAF 保存 |
| `getAvailableBytes` | `statfs.getFreeSize`（真机 selfTest 验证 ~97.4GB） |
| `gs/updater.getVersion` | `bundleManager` 读 `versionCode/versionName` |
| `gs/emulator.launch` | 见 `docs/ohos-libretro-port.md`（设计完成，实现待排期 M0–M4）；当前占位返回 false |
| `gs/netplay` | 通道已注册，原生回调节点待未来 emulator |

**P4（2026-10-19）**：`exportBiosZipViaSaf` 已用 `zlib.zipFile` 实现（编译通过 + 装机）；`getAvailableBytes` 已改用 `statfs.getFreeSize`（真机 selfTest 返回 ~97.4GB）。**OHOS libretro core runtime 未做**——需移植 RetroArch/libretro（原生 `.so` core + 渲染接入），属跨平台大型工程，`launchEmulator` 暂保持返回 false。SAF 导入导出仍需真机人工点选系统文件选择器验证（`DocumentViewPicker` 无法用 hdc 驱动）。

### Android 回归闸门（每次 OHOS 改动后必跑）

```powershell
cd D:\ai\prj\trae\HuaWei\RetroEmuPouch
powershell -ExecutionPolicy Bypass -File scripts\build-apk.ps1 -Flavor store -DebugBuild
```
P2 全程只改 `app/ohos/*` 与 `scripts/*`，**未触碰 `app/android` 与 `pubspec.yaml`**，
Android 构建零影响（`build OK in 33s`，产出 `app-store-debug.apk` 270.5 MB）。

---

## 2.7 编译鸿蒙 MAME 街机核心（libretro 交叉编译，aarch64）

> 目标：产出 OpenHarmony aarch64 的街机核心 `libgs_mame.so`，装入鸿蒙 App 的 `cores/ohos/build/`。
> 与 2.5 的 **Android** MAME 核心不同：这里用 **OHOS SDK 自带的 clang**（不是 NDK），目标 `aarch64-linux-ohos`。
>
> **工具链有两条路，现以 Linux 原生为默认**：
> - **Linux 原生（推荐）**：SDK 里的 clang 是 **ELF 原生二进制**，在 WSL 里直接跑，**无 Windows 互操作**
>   → 无路径翻译、无 `.d` 改写、无执行位抖动。详见下方「Linux 原生 OHOS SDK」小节。
> - **Windows `clang.exe`（旧路，已不推荐）**：靠 **WSL 互操作** 驱动，是下面坑 **#1 / #3 / #5** 的唯一来源。

脚本 `scripts/build-mame-ohos.ps1` 封装全流程（克隆/同步 → genie 生成 → 编译 → 装 `.so`）：

```powershell
# 完整流程（首次 / 换机）
powershell -ExecutionPolicy Bypass -File scripts\build-mame-ohos.ps1
# 复用已有 build/mame-ohos-src（增量；不重拷源码，更快）
powershell -ExecutionPolicy Bypass -File scripts\build-mame-ohos.ps1 -SkipClone
```

产物：`cores/ohos/build/libgs_mame.so`（脚本用 `find *libretro*.so` 取最新并拷入）。

### 架构与隔离

- **源码隔离**：`build/mame-src` 是上游只读副本，脚本 `robocopy /MIR` 到隔离副本 `build/mame-ohos-src` 后再 patch；**绝不改 `build/mame-src`**。
  ⚠️ `robocopy /MIR` 只在「`Makefile` 不存在」（首次）时执行；复用副本时**不会删 `build/` 产物**，故重跑脚本是**增量且安全**的。
- **包装器（Linux 原生，现默认在 `~/ohos-sdk/ohos-tc-linux/`）**：`ohos-arm64-gcc/g++/ld/ar/ranlib/strip/nm`
  是极薄 `exec` shim，把 SDK 的目标编译器包成 `gcc` 形态给 genie/MAME 的 `$(CC)` 用。
  `--target` / `--sysroot` / `-D__MUSL__` **由 SDK 自带的目标包装器** `aarch64-unknown-linux-ohos-clang` 注入，我们无需再传。
  （旧版在 `build/mame-ohos-src/ohos-tc/`，包的是 Windows `clang.exe` 并注入 `D:\HuaWei\Sdk\...` 路径，**已弃用**。）

### Linux 原生 OHOS SDK（推荐，取代 Windows clang 封装）

`tools/commandline-tools-linux-x64-26.0.0.851.zip`（约 2.3GB）里**内置了完整的 Linux 原生 OHOS SDK**，
与 `D:\HuaWei\Sdk\26.0.0`（Windows SDK）是**同版本 26.0.0 的孪生版**。只需解出 `native` 子树
（**2.75GB / 29865 文件**；其余 4GB+ 是 ets/js/hvigor/ohpm，编译 C/C++ 用不到）：

```bash
# ⚠️ unzip 的参数是「精确匹配」：必须写成 dir/* 才会递归解出该目录下的文件
#    （写成 'dir/' 只会解出那条目录条目本身，返回成功但目录是空的 —— 已踩过）
mkdir -p ~/ohos-sdk
unzip -o tools/commandline-tools-linux-x64-26.0.0.851.zip \
      'command-line-tools/sdk/default/openharmony/native/*' -d ~/ohos-sdk
```

关键内容（均已实测，路径相对 `~/ohos-sdk/command-line-tools/sdk/default/openharmony/native`）：

| 路径 | 说明 |
|---|---|
| `llvm/bin/clang-15` | 139MB **ELF** 真二进制（`clang` 是指向它的符号链接）；`--version` = OHOS clang **15.0.4** |
| `llvm/bin/aarch64-unknown-linux-ohos-clang(++)` | 目标包装器脚本，已注入 `-target aarch64-linux-ohos --sysroot=$SRC/../../sysroot -D__MUSL__` |
| `llvm/bin/ld.lld`、`llvm-ar/ranlib/strip/nm/objcopy` | LLVM binutils 齐全 |
| `sysroot/` | 完整 musl sysroot（2893 文件，`/usr/include` 齐全）；`sysroot_lite` 仅 61 个，不够用 |

**必须解到 WSL 原生 FS（`~/ohos-sdk`）而不是 `/mnt/d`**：符号链接与 Unix 权限位在 9p/DrvFS 上不可靠，
原生 FS 下 `clang -> clang-15` 符号链接、`+x` 位才能正确保留。

**为什么它根治了「WSL/Windows 频繁切目录」**：clang 是纯 Linux 进程，`/mnt/d/...` 路径 make 与 clang **双方都原生认**，
于是坑 **#1（argv 路径翻译）、#3（`.d` 里 `d:/` 回写）、#5（包装器丢 `+x`）全部不再存在**。

#### 换用原生链后必须知道的两个差异（否则会踩）

1. **`-dumpfullversion` 是 GCC 专有选项**：MAME `makefile` 用它探测编译器版本（第 1026/1028 行），
   clang **不实现**（`-dumpversion` 可用并输出 `15.0.4`；`-dumpfullversion` 报 `no input files` 且**无输出**）
   → `GCC_VERSION` 为空 → genie 报 `GCC version 11 or later needed`（Error 255）。
   → 包装器内特判：见到 `-dumpfullversion`/`-dumpversion` 就 `exec clang -dumpversion`。
2. **`__MUSL__` 不是预定义的**：只有 SDK 目标包装器显式 `-D__MUSL__` 时才有；而**旧 Windows 包装器没传这个宏**。
   → 切换工具链后**旧 `.o` 必须全部丢弃**（头文件语义不同，混编有 ABI/ODR 风险），需全量重编：
     ```bash
     find build -name '*.o' -delete; find build -name '*.d' -delete
     ```

### ⚠️ 必读构建坑（曾耗多轮排查）

> 其中 **#1 / #3 / #5 只存在于 Windows `clang.exe` 那条旧路**，改用上方 Linux 原生 SDK 后**不存在**；
> **#2（libc++ 严格度）、#4（flavor 注册）、#6（源码树缺 PNG 资源）与工具链无关**，两条路都要。

1. **（Windows clang 路）WSL 互操作只翻译 cwd + 主输入文件**：argv 里 `-I`/`-L`/`-include`/`-MF` 中的 `/mnt/d/...` 绝对路径**不会被翻译**，
   Windows clang 找不到头文件（报 `retroprefix.h file not found`）。
   → 所有包装器必须把 `/mnt/<盘符>/...` 改写成 `<盘符>:/...`（**合并形式** `-I/mnt/d/...` 也要处理），再交给 clang。

2. **OHOS libc++ 15 对 `std::make_signed_t<std::string>` 硬报错**：MAME `src/lib/util/strformat.h` 的
   `apply_signed`/`apply_unsigned` 的 `requires` 子句实例化 `make_unsigned_t<std::string>`，OHOS libc++ 不是 SFINAE 失败而是**直接编译错误**，
   任何用 `std::string` 做格式化参数的 TU（cps2 / leland_* / …）整片崩。
   → 在隔离副本 `build/mame-ohos-src/src/lib/util/strformat.h` 加安全别名 `safe_make_signed_t`/`safe_make_unsigned_t`，
   条件为 `std::is_integral_v<U> && !std::is_same_v<U, bool>`（非整型 **以及 `bool`** 都回退为该类型自身），
   并把这两个函数的 `requires` 与 `if constexpr` 全部走 safe 别名。
   ⚠️ **`bool` 同样会被拒**：`is_integral_v<bool>` 为 true，但 OHOS libc++ 的 `__make_signed<bool, true>` **没有 `type` 成员**，
   只按「是否整型」分流会在 `format_output<..., bool>` 上硬报错 —— **原生 clang 与 Windows clang 都会踩**。
   ⚠️ 此 patch 在**隔离副本**里、且 `-Clean` 全量重拷会被冲掉；需要 `-Clean` 重建时要加进脚本 Step 2.5。

3. **`.d` 依赖文件含 `d:/...` 让 make 解析失败**：包装器把 `-I` 翻成 `d:/...` 给 clang 找头文件，clang 也会把这些
   `d:/...` 写进生成的 `.d`；GNU make（跑在 WSL/Linux）**无法解析带盘符冒号的路径**，报 `multiple target patterns`。
   → 包装器在 clang 跑完后对生成的 `.d` 做后置 `sed`：`s!\([dD]\):/!/mnt/d/!g`，把 `d:/...` 写回 `/mnt/d/...`（clang 仍靠 `d:/...` 找到文件，make 读到 POSIX 路径）。
   MAME 用 `-MMD -MP`（无 `-MF`），`.d` 由 `-o` 推导（`${orig_out%.o}.d`）。
   ⚠️ **改了包装器后必须删掉旧 `.d`**：`find build -name '*.d' -delete`（约上千个），否则 make 立刻又崩在旧 `.d` 上。
   已编好的 `.o` 可保留（整型 `T` 代码与修复前逐字节一致；失败 TU 无 `.o` 会重编）。

4. **x86-64 目标错配（早期坑，已固化在脚本）**：genie 的 `--gcc=<flavor>` 决定 `CC`；`ohos-arm64` 不是已知 flavor 会回退宿主 gcc 产出 x86-64。
   → `scripts/toolchain.lua` 把 `ohos-arm64` 加入允许列表并分支设 `cc/cxx/ar=ohos-arm64-*`；
   `makefile` 新增 `ohos-arm64` 目标（`--targetos=linux` 必须放在 `$(TARGET_PARAMS)` **之后**以覆盖其默认的 `--targetos=ohos-arm64`）；
   `Makefile.libretro` 的 ohos-arm64 块：`TARGETOS=ohos-arm64 gcc=ohos-arm64 PLATFORM=arm64 ARCHITECTURE=`
   （**空 `ARCHITECTURE` 必须有**，否则 `all:` 解析成带后缀的无效目标）+ `OVERRIDE_CC/CXX/AR`。

5. **包装器丢失可执行位（metadata drvfs 挂载）**：若 `/mnt/d` 是**开启 per-drive metadata** 的 drvfs 挂载（真实权限），脚本/重跑重写的 `ohos-tc/ohos-arm64-*` 包装器**不会自动带 `+x`**，make 会报
   `/bin/sh: ohos-arm64-g++: Permission denied`（Error 127，文件明明存在）。
   → 脚本已在写完包装器后 `chmod +x ohos-tc/ohos-arm64-*`（已固化）；手动补救：`chmod +x ohos-tc/ohos-arm64-*`。
   ⚠️ 改过包装器或重跑脚本后突然开始报 Permission denied，第一反应查这条。

6. **源码树缺 PNG 资源 + `png2bdc.py` 缺 PyPNG（资源被剥离的源码树必踩）**：
   本仓库这份 MAME 源码**剥离了二进制资源** —— `src/frontend/mame/ui/` 下只有 `uicmd14.md`（93 字节的 license 存根），
   **整个 `src/` 下没有任何 `.png`**；而 genie 生成的规则要求用 `uicmd14.png` 产出 `generated/emu/ui/uicmd14.fh` →
   报 `No rule to make target '../../../../../src/frontend/mame/ui/uicmd14.png' ... Stop.`，
   连带 `make[2]: *** [Makefile:74: emu] Error 2`。
   ⚠️ **此失败在切换 Linux 原生工具链之前就存在，与走哪条工具链路无关**（#1/#3/#5 才是 Windows 路独有）。
   想走正规路（`png2bdc.py` 读 PNG → BDC）**在本机走不通**：该脚本 `import png`（PyPNG），
   而本机 **PyPNG 未安装、`pip` 本身也没有**（`No module named pip`）、且**离线**无法安装。
   → 变通（已固化）：
     1. 在**两棵**源码树放占位 `src/frontend/mame/ui/uicmd14.png`（`build/mame-src` **也要放**，
        否则 `robocopy /MIR` 会把隔离副本里的那份删掉）；
     2. 用**纯 Python** 的 `file2str.py` 把仓库里现成的**合法 BDC 字体**
        `src/osd/libretro/libretro-internal/ui.bdc` 转成 `.fh`（变量 `font_uicmd14`，类型 `uint8_t`）：
        ```bash
        python3 scripts/build/file2str.py \
            src/osd/libretro/libretro-internal/ui.bdc \
            build/generated/emu/ui/uicmd14.fh font_uicmd14 uint8_t
        ```
     3. **`touch` 该 `.fh` 使其 mtime 晚于 `.png`** → make 判定最新，**跳过**那条跑不动的 python 规则。
   ⚠️ 内嵌字形实际是 `ui.bdc` 的字形（仍是合法 BDC，运行时可正常解析），而非真正的命令图标 ——
   对 libretro 核心无影响（不走 MAME 内部 UI）。
   ⚠️ `.fh` 落在 `build/generated/`、占位 PNG 落在源码树：执行 `-Clean` 全量重拷后**需重放此补丁**（同坑 #2，必要时加进脚本 Step 2.5）。

### 手动跑（单一入口，免切目录）

完整构建数小时；本工具 WSL 桥接里 `wsl.exe` 退出即回收前台 make，且 **PowerShell 外层重定向会把 `/mnt` 路径截断**（日志错乱）。
已将整套交互收口为**单一入口**，无需手动在 WSL/Windows 间切目录：

- **Windows 侧（推荐，一条命令）**：`scripts/build-mame-ohos-wsl.ps1`
  ```powershell
  pwsh -ExecutionPolicy Bypass -File scripts\build-mame-ohos-wsl.ps1            # 完整增量构建
  pwsh -ExecutionPolicy Bypass -File scripts\build-mame-ohos-wsl.ps1 -ClearD     # 清旧 .d（换工具链要连 .o 一起清，见上）
  pwsh -ExecutionPolicy Bypass -File scripts\build-mame-ohos-wsl.ps1 -Jobs 4     # 限并发（原生链无互操作，仅用于控 CPU 占用）
  ```
- **WSL 侧直接跑**：`bash build/mame-ohos-src/run_build.sh [build|precompile]`
  （脚本自行 `cd` + 把 `~/ohos-sdk/ohos-tc-linux` 加入 `PATH` + `unset ANDROID_*` + `tee` 同时落盘 `build_run.txt` 并回显；
  支持 `OHOS_JOBS` / `OHOS_CLEAR_D=1`。**不再需要 `chmod`**：包装器在 WSL 原生 FS，权限位稳定。）
  ⚠️ 数小时构建建议**在持久 WSL 会话里跑**；本工具的 `wsl.exe` 每次调用结束会回收前台 make
  （被截断时日志里会出现 `Error 2`，那是**强杀假象**而非编译错误 —— 判据：日志里没有 `: error:` 行）。

> ⚠️ **tmux 实测不能跨本工具调用存活**：每次 `wsl.exe` 退出后 `tmux new-session` 起的会话会消失（曾实测 `mb` 会话在 `wsl.exe` 退出后即不在 `tmux ls` 中）。
> 故别指望靠本工具的 tmux 跑完数小时构建；要么反复调用上面的单入口（make 增量，断点续编），要么你**自己在持久 WSL/tmux 会话**里跑 `run_build.sh`。

- `NOWERROR=1`：把 OHOS clang 不认识的告警选项（`-Werror=stringop-truncation` 等）留在 warning 而非 error。
- 验证：`ocore_retro.make` 里 `CC = ohos-arm64-gcc`；用包装器编个小 `.c`，`readelf -h` 应见 `Machine: AArch64`。
- **进度现状（截至本次整理）：✅ 已完整构建成功（rc=0）**。切到 **Linux 原生 SDK** 后全量重编：
  `: error:` **0**、`undefined reference` **0**，产出 **4320 个 `.o` / 133 个 `.a`**；
  坑 #6（缺 `uicmd14.png`）按上面方式绕过；**最终链接阶段（lld + musl sysroot）顺利通过** —— 这是最后一个未知关卡。
- **产物验证（已实测）**：`build/mame-ohos-src/mamearcade_libretro.so`，约 **189MB**：
  ```bash
  file mamearcade_libretro.so              # ELF 64-bit LSB shared object, ARM aarch64
  readelf -d mamearcade_libretro.so | grep NEEDED   # 仅 [libc.so]（musl）
                                           # -static-libstdc++ 已把 libc++ 静态链入，无需额外 .so
  nm -D --defined-only mamearcade_libretro.so | grep retro_
                                           # retro_init/run/load_game/get_system_info/... 均已导出
  ```
  （链接期唯一告警：`argument unused during compilation: '-static-libgcc'`，clang 无害告警，可忽略。）
- **下一步**：把 `.so` 装进 `cores/ohos/build/libgs_mame.so`（`scripts/build-mame-ohos.ps1` 用 `find *libretro*.so` 自动取最新拷入）。

### 核心回退（arcade ↔ gamepouch 备份约定）

`cores/ohos/build/libgs_mame.so` 可能被「精选核心」覆盖。为保证可逆，**安装新核心前会把被替换的 arcade 全量核心备份为同目录的 `libgs_mame.so.arcade.bak`**（约 189.5MB）。

**仅回退 .so（不动构建脚本）**：
```powershell
# GamePouch 仓库根目录执行
Copy-Item -Force cores\ohos\build\libgs_mame.so.arcade.bak cores\ohos\build\libgs_mame.so
# 验证 ≈ 189.5 MB
[math]::Round((Get-Item cores\ohos\build\libgs_mame.so).Length/1MB, 2)
```
> 之后重编 HAP（`scripts/build-hap.ps1`，见 2.6）即包含 189MB arcade 核心。

**完整回退到 arcade 构建链**（顺带让 `run_build.sh` 默认编 arcade）：
1. 按上一步恢复 `libgs_mame.so`；
2. 把 `build/mame-ohos-src/run_build.sh` 的 `SUBTARGET=gamepouch` 改回 `SUBTARGET=arcade`；
3. （可选）删除派生文件 `src/mame/gamepouch.lst` 与 `scripts/target/mame/gamepouch.lua`（不影响 arcade 构建）。

> 已构建的 gamepouch 产物仍保留在 `build/mame-ohos-src/mamegamepouch_libretro.so`（约 54.6MB），
> 想再切回精选核心直接把它拷进 `cores/ohos/build/libgs_mame.so` 即可，无需重编。

> 注：**运行时宿主其实已经存在**（`app/ohos/entry/src/main/cpp/gpretro.cpp` → `libgpretro.so`）：
> XComponent + EGL/GLESv3 渲染 + OHAudio + NAPI，按 coreId **`dlopen("libgs_<coreId>.so")`** 加载核，
> 且**已内置 MAME 分支**（强制 `mame_media_type=rom`、按盘读 ROM、建 BIOS 目录、system/content/save 目录）。
>
> **接入链路**：Dart `launchEmulator` → `gs/emulator` MethodChannel → `GamePouchPlugin.ets`
> `onEmulator('launch')` → `setEmulatorTarget(rom,core)` → `router.pushUrl(pages/EmulatorSpike)` → 宿主 dlopen + run。
>
> **coreId 约定**：Dart `rom_entry.dart` 里 `PlatformKind.mame/neogeo` → 商店版 `'mame'`、社区版 `'fbalpha2012'`；
> OHOS 走商店版即 `'mame'`，正好对应 `libgs_mame.so`。ArkTS `coreForRom()` 兜底也已补 `.zip/.7z → mame`。
> ⚠️ `app/ohos/entry/src/main/cpp/CMakeLists.txt` 里打包核的 `file(GLOB ...)`
> **必须带 `CONFIGURE_DEPENDS`**，否则新产出的核（如 `libgs_mame.so`）不会被重新 glob、也就打不进 HAP（已修）。

---

## 3. 签名（Release 必需）

Release 构建需要 keystore，`build.gradle.kts` 会读取根目录的 `keystore.properties`（已被 gitignore）。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\make-release-keystore.ps1
```

- 生成 `.tools\signing\gamepouch.jks` 并写入 `keystore.properties`（含 storePassword / keyAlias / keyPassword）。
- 非交互（CI）可用：`-StorePass <pwd> -KeyPass <pwd>`。
- **⚠️ 本地开发钥匙**：正式上架请用密管 / HSM 的 upload key，并 enrol Play / 华为 App Signing。
- **⚠️ 配对关系**：`.jks` 和 `keystore.properties` 必须配对。若 `keystore.properties` 丢失，
  旧 `.jks` 即成「死钥匙」（密码未知无法复用）——务必同时备份这两个文件。
  重跑脚本会生成新钥匙，但此前用旧钥匙签的 release 包在用户侧需先卸载再装。

---

## 4. 真机连接（设备代号 oxf：Honor OXF-AN10，序列号 `66B0219C18003002`）

`adb` 在 `.tools\android-sdk\platform-tools\adb.exe`（已进 PATH，直接 `adb` 即可）。

### USB 连接
```powershell
adb devices -l
# 期望看到： 66B0219C18003002  device
```

### 无线调试（推荐，免线）
1. 手机：开发者选项 → 无线调试 → 开启，记下「IP 地址:端口」。
2. 先 USB 一次把 adb 切到 tcpip：
   ```powershell
   adb tcpip 5555
   ```
3. 拔线，连无线：
   ```powershell
   adb connect 192.168.x.x:5555
   adb devices
   ```
4. 断开：`adb disconnect`

### 安装 / 卸载
```powershell
# 签名不同（换 build 类型或换钥匙）时必须先在手机卸载旧包，否则 INSTALL_FAILED_UPDATE_INCOMPATIBLE
adb uninstall com.retroemupouch.app

# 安装
adb install app\build\app\outputs\flutter-apk\app-store-release.apk
# 覆盖安装（仅当签名一致）
adb install -r app\build\app\outputs\flutter-apk\app-store-debug.apk
```

包名固定为 `com.retroemupouch.app`。

---

## 5. 运行 / 调试

### 直接跑（热重载）
```powershell
flutter run -d 66B0219C18003002 --flavor store --dart-define CHANNEL=store
```

### 日志
```powershell
# 原生平台通道 + Flutter 框架日志（GS-Main 是 MainActivity 的 TAG）
adb logcat -s GS-Main flutter:* Dart:*

# 仅 Dart 侧
flutter logs

# 抓崩溃 / ANR
adb logcat -b crash -b system *:E > crash.log
# 过滤 FATAL EXCEPTION / AndroidRuntime
```

### Dart DevTools
```powershell
flutter pub global activate devtools
flutter devtools        # 浏览器打开提示的地址
```

### 复现「闪退」类问题
1. 先 `adb logcat -c` 清日志。
2. 在手机上复现操作。
3. `adb logcat -b crash -b system *:E > crash.log` 抓取 `FATAL EXCEPTION` 栈。
4. 同时用 `adb logcat -s GS-Main` 看原生通道报错。

---

## 6. ROM / 资源部署

### 街机一键刷新（推荐）：`scripts\mame\refresh-roms.ps1`
一条命令完成「归拢 BIOS → 用完整 MAME 0.289 dump 替换设备 ROM → 部署 BIOS 到 MAME rompath → 真机验证」，换机 / 复现照做即可。
- 完整 ROM 库：`G:\software\game\mame\`（`MAME 0.289 ROMs (split)` = 42723 款全集；`MAME 0.289 ROMs (bios-devices)` = BIOS 设备集）。
- BIOS 集中目录：`.tools\gstest\bios\`（`neogeo.zip` + `qsound.zip`），已被 `.gitignore` 的 `/.tools/` 覆盖，**不入 git / 不进 APK**；商用零 ROM/BIOS 由 `ci.ps1` 的 `check-apk-content.ps1` 门禁强制保证。

```powershell
# 全流程：归拢 BIOS + 替换 NeoGeo/Cps1/Cps2 ROM + 部署 + 验证（约 15 分钟）
powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1
# 换机后只快速部署（复用已暂存资源，秒级恢复）
powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1 -NoRefreshBios -NoRefreshRoms -SkipVerify
# 只刷某类 / 跳过验证
powershell -ExecutionPolicy Bypass -File scripts\mame\refresh-roms.ps1 -Dirs NeoGeo -SkipVerify
```

参数：`-Dirs`（默认 `NeoGeo,Cps1,Cps2`）、`-SplitSet` / `-BiosSet`、`-NoRefreshBios` / `-NoRefreshRoms` / `-SkipVerify`、`-BenchSeconds`。
> MAME 核心从 `<system>/mame/roms`（即 `files/system/mame/roms`）与内容目录 `rom_cache/mame` 查找 ROM/BIOS；app 侧 `LockedRom.kt` 启动时会把 `system/neogeo.zip` 自动分发到这两处，NeoGeo 与 CPS2（qsound）BIOS 均以此就位。逐款结果写入 `build/verify_<Dir>.csv`。

> ⚠️ **多 BIOS 列表（必读，2026-10 改造）**：`SystemFiles.requiredBios`（Dart 侧）和 `LockedRom.ARCADE_BIOS_NAMES`（Kotlin 侧）**必须 lockstep**。当前为 `neogeo.zip` + `qsound.zip`，分别给 NeoGeo / CPS-1&2（Q-Sound）。新增 BIOS 时**同时**改这三处：
> 1. `app/lib/system_files.dart` 的 `requiredBios`（缺失对话框、设置页管理 UI 的 `_knownBios` 都从这里读）
> 2. `app/android/app/src/main/kotlin/com/gamepouch/app/LockedRom.kt` 的 `ARCADE_BIOS_NAMES`（启动时 `stageOneArcadeBios` 走这里）
> 3. `scripts/mame/refresh-roms.ps1` 的 `-Dirs` 收集规则（同步源到设备）
> 漏一处会出现「UI 显示已装但启动仍报缺」或反之的诡异现象。

> 诊断关键词对照（Kotlin `LockedRom` 日志、MAME 启动 stderr）：
> - `Failed to find archive: neogeo` / `missing sm1.sm1` → 缺 `neogeo.zip`
> - `dl-1425.bin NOT FOUND (tried in qsound_hle qsound <game>)` → 缺 `qsound.zip`（CPS-1/CPS-2 全部，含 1944/sf2ce/samsho2/msh）

测试 ROM 与脚本在 `.tools\gstest/`：

- 街机：`kof97.zip`、`mslug.zip`、`samsho2.zip`、`ffight.zip`、`sf2ce.zip`、`sfa2.zip`、`19xx.zip`
- NES：`smb.nes`、`contra.nes`、`adventure1.nes`
- 部署脚本：`install.sh`（ROM 平铺）、`install_bios.sh`（BIOS，如 `neogeo.zip`）、`rom_index.json`

### 方式 A：脚本推到 app 私有目录（需要 run-as）
app 的 ROM 目录是 `/data/data/com.retroemupouch.app/files`，普通 shell 不可写，需用 `run-as`：

```powershell
adb push .tools\gstest /data/local/tmp/gstest
adb push .tools\gstest\install.sh /data/local/tmp/
adb shell run-as com.retroemupouch.app sh /data/local/tmp/install.sh
```

`install.sh` 会把 ROM 按 `roms/nes`、`roms/cps1`、`roms/cps2`、`roms/neogeo` 平铺到 files 目录，
并写入 `rom_index.json`。BIOS（`install_bios.sh`）放到 `system/`，供街机核心查找。

### 方式 B：App 内 SAF 导入（用户视角，推荐自测）
库页面右上角菜单 →
- 「导入 ROM（单文件）」→ 选单个 ROM；
- 「导入游戏资源包 / ZIP（自动识别）」→ 选 zip（gamepouch 资源包或普通 ROM zip 都能识别）；
- 「选择游戏并导出资源包」→ 进入多选，勾选后导出 ZIP 到用户指定位置（离线分享用）；
  导出对话框除 ROM/金手指/存档/封面外，还有 **BIOS 系统文件** 多选（默认勾选本机已安装的
  `neogeo.zip`/`qsound.zip`），打包进 zip 的 `system/<name>`，让对端街机游戏开箱即用，
  不必再去 设置 → 系统文件（BIOS）。

### 方式 C：BIOS（系统文件）管理（2026-10 新增）
设置页 → 「系统文件（BIOS）」卡片是给用户用的 BIOS 生命周期管理，三件套：
- **批量导入**：调 `importBiosBatchViaSaf`，SAF 多选 picker 一次性拉入 `neogeo.zip` + `qsound.zip` + …；import 后调 `SystemFiles.syncAll(pal)` 触发镜像。
- **导出全部**：调 `exportBiosZipViaSaf`，`MainActivity` 把 `<filesDir>/system/` 根目录的所有文件打成 zip 写进用户选的目标；导出包**只含根级文件**（不含 per-core 副本），可被 `importBiosBatchViaSaf` 整包再导入，天然支持换机。
- **单文件删除**：调 `deleteBios(name)`，同步清掉 `<filesDir>/system/<name>` 与 `<filesDir>/system/mame/roms/<name>` 副本；下次启动 `LockedRom` 镜像因源文件不在而自动跳过。

UI 三个分组（`_BiosManagerCard`，`app/lib/features/settings/settings_sheet.dart`）：
- **已安装 (n)**：从 `SystemFiles.requiredBios` 推断已知 BIOS 列表，与磁盘交叉得「在 `<filesDir>/system/` 根目录 **或** `<filesDir>/system/mame/roms/`，且文件名属于 known BIOS」的项。
- **缺失 (n)**：known BIOS 减去已安装。
- **其他 (n)**：只统计 `<filesDir>/system/` 根目录的**非 known BIOS 文件**（如用户手 push 的 `1944.zip`）。**不**扫 `system/mame/roms/` 避免把 per-game ROM 误报成 BIOS（历史坑：mame/roms 路径用户可写，曾经把 `1944.zip` 显示成"其他已装 BIOS"）。

启动失败的 `MissingBiosDialog`（`app/lib/features/library/missing_bios_dialog.dart`）走**同一条** `importBiosBatchViaSaf` 通道，一次 SAF 即可补齐所有缺失 BIOS；不再逐个弹。

#### ⚠️ BIOS/ROM 状态刷新：外部变更要能及时反映（2026-10 修）
历史坑：`LibraryPage` 是**根路由**，`initState`/`_scanBios()` 只在冷启动跑一次；而
`didChangeAppLifecycleState(resumed)` 当时**只刷 `_scanSaves()`、不刷 BIOS**，又没有
`RouteAware`。于是**经 PC「手机同步」(adb) 推入 BIOS 后切回文件库，"缺少系统文件" 横幅仍
显示**（游戏其实能跑），新推的 ROM 也不见——直到冷重启才更新。
修复（`app/lib/features/library/library_page.dart` + `app/lib/main.dart`）：
- `main.dart` 注册全局 `appRouteObserver`（`MaterialApp.navigatorObservers`）；
- `_LibraryPageState` 混入 `RouteAware`，`didChangeDependencies` 订阅自身路由、`dispose`
  退订；`didPopNext()`（设置/账号/发现·伙伴/模拟器等上层路由被 pop 回本页）与
  `didChangeAppLifecycleState(resumed)` 都调用 `_refreshOnVisible()`；
- `_refreshOnVisible()` 重读 `rom_index.json` + `_scanSaves()` + `_scanBios()`（`_scanBios`
  内含 `SystemFiles.syncAll` 镜像），任何磁盘侧 BIOS/ROM 变更在"切回本页/回前台"时即刻反映。
- ⚠️ 仍有一角无事件可用：**始终停在本页、零导航**时外部 adb 推送不会触发刷新（Flutter 无
  文件监听）；真机回归即用"切后台再回前台"或"进设置再返回"来触发。

#### 资源包内置 BIOS（2026-10 新增，导出/导入均带 BIOS）
游戏资源包（`lib/data/package/game_package.dart`）的 manifest `schemaVersion` 升到 **2**，
新增顶层 `bios: ['system/<name>', ...]`：
- **导出**：`PackageOptions` 加 `includeBios` + `biosNames`；`buildPackage` 用
  `SystemFiles.biosFilePath(<filesDir>/system, name)`（**在 system 根或 mame/roms 任一位置
  都能找到**已安装 BIOS）流式打进 zip 的 `system/<name>`，避免整块进内存。
- **导入**：`importPackage` 按 manifest.bios 解出到 `<filesDir>/system/<name>`，随后库页面
  `_scanBios()` 的 `SystemFiles.syncAll` 把根级 BIOS 镜像进 `mame/roms` 等 per-core 目录；
  `PackageImportResult.biosCount` 计数，SnackBar 形如「已导入资源包：1 个游戏 / 金手指 0 /
  存档 1 / **BIOS 2**」。
- **UI**：`library_page._exportSelected` 对话框在封面后多一组「BIOS 系统文件」主开关 +
  已安装 BIOS 子勾选（无已安装时提示去设置页导入）；主开关取消即隐藏子列表。
- 自测：`test/game_package_test.dart` 增「package round-trip bundles + restores BIOS blobs」
  （BIOS 只放 mame/roms 也能被找到并还原）；真机往返已验证（导出含 1.86MB neogeo.zip +
  2.68KB qsound.zip → 移开本机 BIOS → 导入 → 还原 + 镜像 + SnackBar BIOS 2）。

---

## 7. 测试

```powershell
# 跑指定测试
flutter test test\data\play\multiplayer_catalog_test.dart
# 全量
flutter test
```

> store flavor 的街机联机白名单依赖 `app/assets/data/multiplayer.json` 的 `mame` 段（镜像自
> `fbalpha2012`，driver 名校对待办）；community flavor 走 `fbalpha2012` 段。

---

## 8. 常见问题速查

| 现象 | 原因 / 处理 |
|------|------------|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名变了（换 build 类型 / 换钥匙）。手机先 `adb uninstall com.retroemupouch.app` 再装。 |
| `keystore.properties` 丢失导致 release 构建失败 | 旧 `.jks` 密码未知；重跑 `make-release-keystore.ps1`（生成新钥匙，旧 release 包需重发）。 |
| `flutter` 报 Dart SDK 版本过低 | 用的是系统 flutter。确认 PATH 里是 `.tools\flutter`（先 `use-env.ps1`）。 |
| Gradle Kotlin DSL 冷启动 `NoSuchMethodError` | 用 jdk21（setup-env 已处理 jdk21 junction）。 |
| 街机联机入口不显示（store 包） | store 用 `mame` 核心，需 `multiplayer.json` 的 `mame` 段；若缺则 `modeFor` 走 default 返回 null。 |
| 导出资源包闪退 | 见第 5 节抓 `FATAL EXCEPTION`；原生 `onActivityResult(REQ_EXPORT)` 有 try/catch 会回传 error，硬崩多为 Dart 侧未覆盖路径或 OOM。 |
| 改了 Kotlin/native 代码，但真机 UI 没变化 / 像没更新 | **增量编译复用了旧 dex/native 缓存**（甚至会把语法错误一起掩盖，直到某次全量编译才报）。先 `flutter clean` 再跑 `build-apk.ps1`；装包前先 `adb shell am force-stop com.retroemupouch.app`——运行中的旧进程不会加载新代码。验证 APK 是否含新符号可解包 dex `strings` 查方法名。 |
| 改了 MAME 核心源码（store 街机），但联机/存档行为无变化 | 实际编译的是 **WSL 克隆** `~/mame-build/mame`，不是 `build/mame-src`；`build-mame.ps1 -SkipClone` 跳过同步，编辑 `build/mame-src` 无效。直接改 WSL 克隆，或给 `-SkipClone` 补 `cp -a build/mame-src/* ~/mame-build/mame/`（注意别反向覆盖）。见 §2.5。 |
| MAME 启动报 `dl-1425.bin NOT FOUND (tried in qsound_hle qsound <game>)`（CPS-1/CPS-2：1944 / sf2ce / samsho2 / msh / …） | 缺 `qsound.zip`（Q-Sound BIOS）。走「设置 → 系统文件（BIOS）→ 批量导入」或 `MissingBiosDialog` 的批量按钮补齐；补完**无需**重装游戏，**无需**重启 app——下次启动 `LockedRom` 镜像会把它放到 `system/mame/roms/qsound.zip`。 |
| BIOS 管理卡片「已安装」少一项 / 「缺失」多一项 | 两端名单不同步：见 §2.5 末尾"多 BIOS 列表"——`SystemFiles.requiredBios`（Dart）与 `LockedRom.ARCADE_BIOS_NAMES`（Kotlin）必须 lockstep；用户视角是 Dart 列表，但启动镜像走 Kotlin，缺一就会一致错配。 |
| 启动/导入一个 ROM 到 system/mame/roms/，BIOS 管理「其他」出现游戏 zip | 误报（已修）。`system/mame/roms/` 是 per-core **BIOS** 镜像位置（不是 game ROM 位置），不扫 root files；ROM 应在 `<filesDir>/roms/<name>.zip`（用 importRomViaSaf）或 `<filesDir>/rom_cache/mame/<name>.zip`（`passThroughPlainZip` 路径）。手动 push 过去能跑但 MAME 优先读 `rom_cache/mame`，属污染目录。 |
| `importBiosBatchViaSaf` 在部分华为/EMUI 文件管理器只回单文件 URI | 已知。`MainActivity.collectSafUris` 同时支持 `EXTRA_ALLOW_MULTIPLE` 的 `clipData` 与单 `data.data` 两种 shape，不影响正确性。 |

---

## 9. 关键路径速记

```
仓库根/
  scripts/
    setup-env.ps1        首次初始化（junction 共享工具链）
    use-env.ps1          每终端点源（注入环境变量 + PATH）
    build-apk.ps1        编译（ -Flavor store|community, -DebugBuild, -SplitPerAbi ）
    make-release-keystore.ps1   生成 release keystore + keystore.properties
  .tools/
    flutter/bin/flutter.bat       项目专用 flutter（Dart >=3.13）
    jdk21 / jdk17                Gradle 用 jdk21
    android-sdk/platform-tools/adb.exe
    signing/gamepouch.jks        release 钥匙
    gstest/                      测试 ROM + install.sh / install_bios.sh / rom_index.json
  keystore.properties            release 签名配置（gitignore）
  build-apk.log                  最近一次构建日志
  app/
    android/app/src/main/kotlin/.../MainActivity.kt   平台通道（import/export SAF）
    lib/data/play/multiplayer_catalog.dart            联机白名单核心
    assets/data/multiplayer.json                      白名单数据（fceumm / fbalpha2012 / mame）
    lib/data/package/game_package.dart                资源包导出/导入实现
    lib/features/library/library_page.dart            库页面（导出入口 _exportSelected）
    lib/data/peer/peer_server.dart                    伙伴 peer 服务（含 /api/peer/bios）
    lib/data/peer/peer_sync.dart                      伙伴导入执行器（含 BIOS 落地/镜像）
    lib/features/library/missing_bios_dialog.dart     启动缺 BIOS 弹框（走批量 SAF）
    lib/features/settings/settings_sheet.dart         设置页（_BiosManagerCard：批量导入/导出/单删）
    lib/system_files.dart                             requiredBios 单一来源（Dart 侧）
    lib/pal/platform_pal.dart                         importBiosBatchViaSaf / exportBiosZipViaSaf / deleteBios
    android/app/src/main/kotlin/.../MainActivity.kt   平台通道（REQ_IMPORT_BIOS_MULTI=0x4759 / REQ_EXPORT_BIOS=0x475A）
    android/app/src/main/kotlin/.../LockedRom.kt      ARCADE_BIOS_NAMES + stageOneArcadeBios（启动镜像）
    lib/data/play/play_session.dart                   联机会话/邀请信令状态机（handleInvite）
    lib/data/play/netplay_capability.dart             联机门禁表（核心白名单/拒绝码）
    lib/features/play/                                大厅/邀请框等联机 UI
    android/app/src/main/cpp/netplay/gs_netplay.*     native 锁步（UDP 帧/HMAC/自适应 D）
    android/app/src/main/kotlin/.../netplay/          启动引导（SRAM/帧0对齐）配置
```

## 10. 伙伴导入：BIOS 同步（新增）

在「导入伙伴文件库」流程里，**自动**为所需 BIOS 增加同步选项：按已勾选 ROM 的核心推断需要哪些 BIOS
（街机 neogeo/mame → `mame` 核心 → `neogeo.zip` + `qsound.zip`），只列出伙伴端确实拥有、且**本机缺失**的项并默认勾选，
本机已有的显示"本机已有，将自动跳过"。随游戏一起导入并落到 `system/`，按 `SystemFiles.syncToNeededLocations`
镜像到各核心读取位置（store 的 `mame` 核心读 `system/mame/roms`），确保导入即可玩。

- 端点（均需 Peer token，复用现有鉴权）：`GET /api/peer/bios`（列表 name+size）、`GET /api/peer/bios/<name>`
  （下载）。服务端**只放行 `SystemFiles.biosNames()` 内的已知 BIOS 名**（当前为 `{neogeo.zip, qsound.zip}`），
  其余一律 400，天然防路径穿越。
- 客户端：`PeerClient.biosList()` / `downloadBios(name, dest)`。
- 执行器：`PeerImporter.buildPlan(..., biosToSync: {name: size})` 追加 `PeerResourceKind.bios` 项；`execute`
  经 `_landBios` 下载到 `system/<name>` 后调用镜像。受 `appChannel.canPeerRom` 约束（store 允许）。
- 合规：BIOS 与 ROM 同理，必须为用户合法拥有的副本；导入弹窗文案已扩展为"游戏 ROM / BIOS 等系统文件"。
- 测试：`test/peer/peer_sync_test.dart`（TR-6.5 落地+镜像）、`test/peer/peer_server_test.dart`（TR-4.6 端点+非法名 400）。
- BIOS 集中目录仍为 `.tools\gstest\bios\`（`neogeo.zip`/`qsound.zip`），不入 git / 不进 APK，见第 6 节。

## 11. 同 Wi-Fi 双人联机（netplay）架构与协议

已完整落地（联机协议自包含在本仓库，无需参考任何外部文档）：Dart 信令 + Kotlin 启动引导 + native 锁步三段。核心约束：**严格锁步、绝不猜输入**，任一帧 K 只在「双方该帧输入都到齐」才推进，因此任意检查点双方状态逐字节一致。

- **角色**：邀请方=主机（host，libretro port0，帧时钟权威），被邀方=客机（guest，port1）。MVP 硬限 2P；不做换位/重连/观战/rollback（delay-based）。
- **三段通道**：
  1. **信令**（Dart `HttpServer`，`peer_server.dart` 加 `/api/peer/play/*`：invite/accept/decline/cancel/ping）：bearer=配对 token；交换 UDP 端口、256-bit 会话密钥（主机 `Random.secure()` 生成）、roomId、slot、初始 D、coreId、ROM CRC、versionCode、netplayProto。
  2. **启动引导**（Kotlin 极简 HTTP，仅对局开始前，`netplay/`；鸿蒙侧由 `netplay_session.ets` 用同一契约实现）：客机在核心加载**前**拉主机电池档（`/sram`）写本机 save → 加载后拉主机帧 0 serialize（`/state0`）`nativeLoadState`；ready/start 双向确认后同开帧。路径固定（`/sram` `/state0` `/ready` `/start` `/sram-final`），`Authorization: Bearer <sessionKey>`，禁路径穿越，结束即关。

### 跨端联机（Android ↔ 鸿蒙）契约与踩坑（2026-10-29 修复）

两端 bootstrap 必须**逐字段同构**，否则「安卓主机 + 鸿蒙客机」必失败。曾踩的三个坑（kof97/MAME 必现）：

1. **`Authorization: Bearer <sessionKey>` 是强制的**：Android `PlayBootstrapServer` 对每个请求校验 bearer，缺失即 401 + 空 body。
   旧版鸿蒙 `tcpRequest()` 只发 request line + Host，**没有 Authorization** → `/sram` `/state0` 全 401 → 客机拿到空 state0 → `no state0` → 立刻 teardown；
   同时主机侧 `awaitGuestReady()` 干等 30s → UI 报「伙伴未在 30 秒内准备好」。
2. **MAME 核心走冷启动、不发 state0**：Android `coldBoot = (coreId == "mame")`（MAME serialize 有损），主机 `publishState0(空)`、客机跳过 `/state0`。
   旧版鸿蒙**无条件**要求 `/state0` 非空 → 即使补上认证头，MAME 对局仍会在「no state0」处失败。
   现按 `NetplayCfg.coreId` 判定 `coldBoot`；`/state0` 返回 200 + 空 body 也按冷启动处理（不再报错）。
3. **方法/状态码语义**：`/ready` 是 **POST**（鸿蒙旧版用 GET → 主机 404）；`/sram` 无存档返回 **204**（不是 200+空 body，否则安卓客机会把空电池档写进本机）；`/sram-final` 无内容返回 **503**（200+空 body 会让安卓客机把存档清零）。

4. **鸿蒙 `TCPSocket.connect()` 是非阻塞的，回调先报 `EINPROGRESS`(HarmonyOS 码 2301115 / POSIX 115)**：`netplay_session.ets` 的 `tcpRequest()` 旧版在 `connect` 回调里 `if (err) finish(null)` —— 把 EINPROGRESS 当致命错误，**连接还没握手完就被关掉**，于是 `/sram` `/ready` 全返回 `null`，客机永远连不上主机（现象：安卓发起时安卓卡「等待伙伴响应」、鸿蒙进游戏黑屏/不收敛）。修复：只在**非** EINPROGRESS 的错误上失败，并把请求发送推迟到 `'connect'` 事件真正就绪后；同时兼容旧版「回调即成功信号」写法，加 8s 连接超时兜底。
   - 复现/排障 hilog：`[netplay] tcp connect FAILED code=2301115 msg=Operation in progress` 即命中此坑；修复后应见 `[netplay] guest /sram -> 200/204`、`guest POST /ready -> 200`、`guest /start -> 200`。

修复后两侧对称：主机 = 起服务 →（非 MAME）capture state0 → `netplayStart` → 等 `/ready`(30s) → `notifyStart` → 开 `/start` 门；客机 = `/sram` →（非 MAME）`/state0` → `netplayStart` → POST `/ready` → 等 `/start`。
排障看 hilog：`[netplay] guest /sram -> <code> <len>`、`[netplay] host GET /state0 -> <code>`、`... -> 401 (bearer mismatch)`。
  3. **帧数据**（native UDP 独立高端口，`cpp/netplay/`）：定长输入帧（帧号 + 16-bit retropad mask + HMAC-SHA256 截断 tag + 序号）+ pause/resume/bye 控制帧；主机每帧冗余带最近 N=D+2 帧，客机 ack 最后连续帧号、主机对缺口重发。
- **帧闸门**：pacing 线程帧 K 仅在双方 frame(K-D) 的 mask 入环后才 `retro_run`，缺则冻结等待（停音频）；本地手柄只写本机槽位；主机包流同时是客机帧时钟。
- **自适应 D ∈ {1,2}**：依 RTT/lead-time 统计（native 侧），主机经控制帧对称宣布；默认 D=2 起步、稳定后降 D=1，格斗可锁 D=1。Phase 0 实测同 Wi-Fi RTT 中位 ≈7ms、p99 ≈21ms、0 丢包，D=1 常态零冻结。
- **冻结/断线/暂停**：缺输入只等不猜；连续 10s 无对端有效帧→弹框退出；任一方暂停（含 App onPause/来电/锁屏）发 pause 双方冻结、双方都 resume 后主机宣布恢复；任一方持续暂停 >15s 会话结束。所有退出路径停线程、关 socket、释放 WifiLock。
- **确定性护栏**：双方 versionCode、coreId、ROM CRC32、netplayProto 必须全等（不符在邀请阶段拒绝）；核心选项固定；金手指清空；同区由 ROM 决定。检查点用 `retro_serialize` 哈希对比（native 输出 GS-Netplay 日志）。
- **会话策略**：联机态强制金手指为空、速度锁 x1、隐藏金手指/倍速/存读档/端口切换入口；即使经 intent/channel 直调也被 native 拒绝。
- **结束收敛**：正常结束主机 `flushBatteryRam`，客机经引导通道回拉最新电池档**原子替换**；异常掉线不回写（避免旧档覆盖）。
- **安全**：每 UDP 帧带 256-bit 会话密钥的 HMAC-SHA256 截断 tag（≥8B）；tag 不符/长度错/magic 版本错/重放窗口外一律静默丢弃；会话密钥只存内存、不进日志/不写盘。

### 多人门槛与门禁链
- **多人清单** `assets/data/multiplayer.json`：`{version, fceumm:{CRC:mode}, fbalpha2012:{driver:mode}, mame:{driver:mode}}`，mode ∈ `coop`/`versus`/`turn`。FC 按 CRC（8 位十六进制大写）匹配；街机按 MAME/FBA 驱动名（zip 去扩展名，大小写不敏感）匹配。由 `tools/gen_multiplayer_manifest.py` 生成（FC 取 cartridge DB/LaunchBox、街机取 MAME listxml），键须与双机 `rom_index` 交叉校验命中。**未知即单人，`MultiplayerCatalog` 加载失败 fail-closed**（main() 预载）。
- **UI 门槛**（FR-27）：清单外游戏不渲染「联机玩」胶囊、无徽标；清单内显示中文徽标（双人合作/双人对战/轮流上场）。轮流制（超级马里奥/马戏团等）标注「轮流上场」。
- **服务端强制**（FR-28）：`PlaySessionManager.handleInvite` 异步多人闸门——FC 直查 CRC；街机由客机本机 `rom_index` 反查驱动名再查清单；核心不支持/本机无 ROM/清单未命中一律 400 `not_multiplayer`，curl 直邀绕不过。
- **拒绝码链**（`NetplayCapability.rejectReason`，按序）：`not_paired` → `version_mismatch` → `rom_not_local` → `core_unsupported` → `not_multiplayer`。**store 版街机核心=`mame`，community=`fbalpha2012`**；`peers_controller.multiplayerAllowed` 闭包必须同时放行 `mame` 与 `fbalpha2012`（曾漏 `mame` 致 store 街机联机 400，已修）。

## 12. 双机 peer 联调清单（真机回归）

双机：OXF-AN10 + EBG-AN00，全程 PowerShell 中文汇报；未经明确要求不 git commit/push、不发 OTA。改码后先过质量门再装机。

### 设备事实（固定值，勿重猜）
- OXF-AN10 SN `66B0219C18003002`：竖 1080×2400、横 2400×1080；release 走华为安全安装；锁屏 PIN `001225`；大库。
- EBG-AN00 SN `2NSDU20423005421`：竖 1080×2340、横 2340×1080；`adb install -r` 无拦截；小库。
- 典型 IP 以发现页显示为准；**PeerClient 每伙伴独立实例，对端 HTTP 端口随机、重开页面即变，切勿缓存旧端口**。
- 每条 Shell 先 `. ..\scripts\use-env.ps1 | Out-Null`；adb 用 `$env:ANDROID_HOME\platform-tools\adb.exe`。
- 启动 app：`adb shell monkey -p com.retroemupouch.app -c android.intent.category.LAUNCHER 1`。版本号以 `adb shell dumpsys package com.retroemupouch.app | Select-String versionName` 为准（设置页文案是硬编码，不可信）。

### 铁律 / 高频坑
1. **发现页双方都要停留**才互见；离页即停 UDP/HTTP 服务。
2. 截图只 `screencap -p /sdcard/x.png` 再 `pull`（PowerShell 重定向会坏图）；偶发 0 字节坏 PNG，换文件名重截。
3. UI 判定优先 `uiautomator dump /sdcard/ui.xml` 后读 XML（PowerShell `[xml]` + XPath 取 text/bounds）。
4. 弹框类验证必须**截图后读图确认**，勿只凭 tap 成功推断；点击前先截图确认当前界面与坐标（不同机型/键盘弹出会漂移）。
5. `am start -n com.retroemupouch.app/.EmulatorActivity`（无 extras）在 taskAffinity 空串且实例在后台栈时**拉不起**前台；回游戏用最近任务卡片或游戏内 X 重开。
6. **华为安全安装**（OXF，系统弹安装器时）：风险页「继续安装」→ 应用市场页勾风险框 →「继续安装」→ coauth 点密码框 → `input text 001225` → 等「安装成功」并用 dumpsys 核对版本。
7. **`uiautomator dump` 陈旧缓存陷阱**：界面在动画/ Surface 合成中时 dump 报 `ERROR: could not get idle state`，但 `/sdcard/ui.xml` 仍是**上一次成功 dump 的旧内容**，读它会误判页面。凡 stderr 出现 idle 错误，该次 dump 作废，改用截图判页。
8. **模拟器覆盖层按钮（功能/菜单/✕）对 `input tap` 合成点击无响应**（BACK 键有效）——真机点 ✕ 退出对局用手点，自动化用 `KEYCODE_BACK`。`uiautomator` 对 EmulatorActivity 也常常 dump 不了。
9. **运行锁自动化构造法**（联调项 5）：`runningSaveKey` 是 EmulatorActivity 的 companion 静态变量、onDestroy 才清空。所以：启动游戏 → `KEYCODE_HOME` → `am start -n com.retroemupouch.app/.MainActivity`（模拟器**后台存活**、MainActivity 盖在上面）→ 即可在 Flutter 里正常导航去伙伴库导入页看到红字锁定。`force-stop` 杀进程后红字消失。
10. **多机 adb 一切命令都要 `-s <serial>`**，包括 `push`/`pull`（无 `-s` 直接报 `more than one device`）。
11. **`adb push <目录> <目标>/` 会把目录塞进目标的同名子目录**（`bios/*` 落到 `gstest/bios/`）；要平铺就逐文件 push。

### 联调项与顺序
- **0 装机就位**：`scripts\build-apk.ps1 -Flavor store -DebugBuild`（或 release）→ OXF 走安全流程 / EBG `install -r` → 双机启动进发现页 → 互见在线卡片。
- **1 生命周期**：任一方反复 返回→重进发现页并刷新；期望互见恢复、配对不丢、HTTP 端口换新。
- **2 配对/重配**：一方「配对连接」→ 双机截图核对 6 位码一致 → 双方确认 → 变「已配对」并自动打开对方库。**stale 重配回归**：A 解除后 B 保留旧记录，由 A 重发，B 的邀请框必须稳定不秒关（watchdog 曾被 stale 记录误判成功）。
- **3 解除与 401**：A 解除后 B 点该伙伴「文件库」→ 期望「伙伴凭据已失效」页带「解除本地伙伴记录」→ 确认后回发现页变未配对。
- **4 大库首拉**：小库机打开大库机库，loading 后正常列出、无 20s 超时；可搜索验证角标（金手指/存档/本机已有）。
- **5 运行锁导入**：一端启动游戏后回 Flutter 进伙伴库勾该游戏进导入页 → 期望存档区红字「正在运行…请先退出」、自动快照+手动槽位置灰，ROM/金手指仍可选；`force-stop` 后重走红字消失、存档恢复可选。
- **6 冷启动读档弹框**：`force-stop` → `logcat -c` → 启动立即继续游戏 → 展开功能条立刻点「读档」，应列出 `.slotN.state`（含缩略图/时间），不得误报「还没有手动存档」。
- **7 跨重启 state restore**：`logcat -d | Select-String 'GS-runner.*state restore|primed'`，期望 `savestate size primed: N bytes` 紧接 `state restore: ok`（街机 serialize 26 万 B 量级），FAILED 即回归。
- **8 联机对局（netplay）**：见第 11 节；双机同 CRC 游戏 → 伙伴库「联机玩」→ 邀请/接受 → 大厅 → 开始；对局中核对双机检查点 serialize 哈希一致、无串键；断线/暂停按第 11 节语义验收。

### 本轮（2026-10-28）双机回归结论（store-debug v1.8.4+49，OXF+EBG）
- **0/2/4/8/5 全部通过**：互见配对（6 位码一致）、伙伴库首拉（10 游戏、平台页签、搜索框、联机玩/双人合作/本机已有徽标）、**netplay 全流程**（邀请→接受→准备→开始，双机 ~57-59 fps，RTT 6-7ms，D=2）。- **检查点哈希一致性（核心验收）**：f=600 `181d278967c4f164`、f=1200 `680a9ce13773ba07`、f=1800 `dfef69b4fa1d4cae` **双机逐字节一致**，dUp=0 dDown=0 rejTag=0 foreign=0，无串键。
- **断线语义**：主机 ✕/BACK 退出 → `session dead at frame N; emulation parked` + `np session ended: cleanBye=true`，客机弹「连接中断 — 主机已结束联机」→ 返回文件库，双机均无崩溃。
- **6/7 未自动化**：模拟器覆盖层按钮不吃合成点击（铁律 8），无法自动写 `.slotN.state`。替代证据：netplay 客机启动引导即 host state0 → `nativeLoadState`，检查点哈希一致已证明跨端 serialize/unserialize 正确；`files/saves/24D7C9E0.state` 双机同为 1029356 字节（kof97 检查点确定性旁证）。
- **坑：19xx.zip 是不完整 dump**（缺 `19xx.key`/`19xe.0*b`，核心报 `Fatal error: Required files are missing`）——街机联机测试用 kof97/mslug/sf2ce 等完整集。
- **坑：BIOS 不齐会导致 netplay「核心启动超时」**：`.tools/gstest/install_bios.sh` 旧版只装 neogeo 且用 `cd + 相对路径`（CRLF 下 cd 静默失败）。已重写为**绝对路径 + 全部 4 个 BIOS**（neogeo/qsound/qsound_hle/pgm → `files/system/`，启动时 LockedRom 镜像步骤自动分发给 `system/mame/roms/`）。报错特征：模拟器错误卡「缺少或不完整的 Q-Sound 系统 BIOS」+ 联机弹「核心启动超时」。

### 本轮（2026-10-28 晚）鸿蒙 Pura70 回归结论（v1.8.4+49，2MN0224730027764）
- **恢复签名链路后装机成功**（见上「签名与包名的硬约束」），`hdc install -r` 原地升级、105 游戏数据保留。
- **GP_OHOS_SELFTEST 全绿**：AppSettings 经 `app_prefs.json` 存读往返 ok、`clearLastSaveSlot` ok、
  `launchEmulator(roms/yx.nes, fceumm)=true`、`settings.json` 9 字段与 AppSettings 完全一致、
  `runningSaveKey(after)=0BE9B81B`、结束后自动恢复默认值。
- **hilog 链路**：`GamePouchPlugin router.pushUrl(EmulatorSpike)` → `loadSettings dir=/data/storage/el2/base/files`
  → `loadMoves profile=selftest n=1` → 高刷 no-op 提示，全部按预期。
- **NES 全链路**：模拟器实跑（三國演義标题画面，虚拟手柄渲染正常）→ ✕（uitest dumpLayout 定位
  `[2163,336][2205,411]`）退回文件库，进程存活、无 SIGSEGV——退出崩溃修复回归通过。
- **MAME 街机探针轮未完成**：HAP 已构建（GP_PROBE_ROM=roms/kof97.zip, CORE=mame, PLATFORM=mame），
  安装时遇 USB 半开（见铁律 3），**待重插后 `hdc install -r app\ohos\entry\build\default\outputs\default\entry-default-signed.hap` + `aa start` 重跑**。
- **BIOS 门控前提已满足**：`files/system/` 有 neogeo/qsound/qsound_hle/pgm 全集（2026-10-22 部署）。

### KOF97（NeoGeo）操作注意
- 投币：约 1.2–1.3s 间隔重复点投币持续 ~40s 才够币；START 常被吞，用长按 `input swipe x y x y 500`；先截图确认坐标再 tap/swipe，勿盲操作。

### 质量门（cwd=app）
- `flutter analyze lib/data/peer lib/features/peer lib/data/play` 0 issue；`flutter test` 全绿（本仓库目前仅 `test/features/settings/app_settings_persistence_test.dart`，§12 旧清单里的 `test/peer`、`test/data/play` 目录在 RetroEmuPouch 分叉中不存在，勿照抄）。
- flutter 命令前先把 `D:\nodejs` 加入 PATH（否则 hvigor installHvigorPlugin 找不到 npm 崩）。
- **`flutter test` 报 `Building assets for package:objective_c failed` / `Can't load Kernel binary: Invalid kernel binary format version (expected 138, found 127)`**：native-assets hook 缓存与 Dart SDK 版本错位，删 `app\.dart_tool\hooks_runner\` 重跑即可。

## 13. 本地资源：金手指关联 + 库管理工具（PC 端）

两套 **Python 3（标准库 + tkinter，零第三方依赖）** 工具，管理 `.tools/gstest` 下的
ROM / BIOS / 金手指。设计上与手机端完全同构：**ROM 的 CRC32（整个文件的
IEEE 802.3，不剥 NES 头）是元数据与金手指的关联键**，与 `RomEntry.crcKey` 一致。

### 金手指关联：`tools/chatsync/sync_cheats.py`
把元数据索引里的金手指搬到 `.tools/gstest/chats`，以 `roms/` 里的真实游戏为基准关联。

```powershell
python tools\chatsync\sync_cheats.py            # 实际执行
python tools\chatsync\sync_cheats.py --dry-run  # 只统计不写盘
python tools\chatsync\verify_cheats.py          # 产出校验报告
```

两个来源格式截然不同，必须分别处理：
- **街机（CPS1/CPS2/NeoGeo）**：内联在索引条目里，以**街机 zip 名
  （MAME 驱动名）**为键 —— 与 GamePouch 街机 ROM 同名，**直接主干匹配**，命中率约 150/159。
- **GBA/NES**：`library/cache/cheat_db_cht/**/*.cht`（RetroArch 文本，需自备），文件名是**英文全称**
  （`CT Special Forces (USA, Europe) (Code Breaker).cht`），而 GamePouch 的 ROM 是**中文名**
  （`CT特种部队.gba`），字面匹配必然为 0。
  → GBA 通过读 ROM 内部 12 字节 ASCII 标题（偏移 `0xA0`，如 `CT SPECIAL F`）做规范化前缀匹配
  桥接到英文金手指名。NES 无内部名源，中文名侧无法映射，属「确实无对应游戏」。

产物：
- `chats/<ROM 主干>.cht` —— 与 `roms/` 一一对应（RetroArch 文本格式）
- `chats/cheats.json` —— GamePouch 原生 `{"version":1,"byCrc":{<8位大写CRC32>:[...]}}`，
  可直接 push 到手机 `library/cheats.json` 使用
- `chats/report.json` —— matched / missing / orphan 清单
- `chats/_orphans/` —— **无对应游戏的金手指保留在此，绝不静默丢弃**

> 现状（626 游戏 / 47 个 .cht + 153 条街机内联）：命中 174（cps1 28、cps2 35、neogeo 87、
> gba 24），孤立 26。GBA 未命中的 5 个（Mortal Kombat Advance、Konami Krazy Racers、
> Shrek、Klonoa G2、LOTR）经核实**ROM 库里确实没有这些游戏**，是正确的孤立项而非匹配缺陷。

### 库管理工具：`tools/library/library_manager.py`
桌面 GUI（tkinter/ttk），双击 `tools\library\run.bat` 启动。

```powershell
python tools\library\library_manager.py
```

六个标签页：**文件库 / 金手指 / BIOS / 关联报告 / 联网检索金手指 / 手机同步**。

**界面配色（模块一眼可辨）**
- 顶部深色品牌条 + **六张统计卡片**（游戏总数 / 有金手指 / 缺金手指 / 命令数 / BIOS /
  孤立金手指），每张左侧一条主色竖条，数字用该主色；
- **平台各有主色**（`PLATFORM_COLOR`）：GBA 紫 `#6d28d9`、NES 红 `#b91c1c`、
  NeoGeo 青 `#0e7490`、CPS1 橙 `#c2410c`、CPS2 琥珀 `#a16207`、街机灰。
  列表行 **文字色 = 平台色**，行 **底色 = 有没有金手指**（绿 `#e7f8ee` / 浅红 `#fdecec`），
  右上角有平台色例；
- 金手指页「孤立」项用橙底；BIOS 页用橙底；关联报告用彩色 tag（绿=已有、红=缺失、
  橙=BIOS/孤立、平台色=分平台行）；日志区用深色终端配色（绿✔ / 红✘ / 黄!）。

**文件库页**
- 任选根目录扫描，自动识别 `roms/`（含 GBA/NES/NeoGeo/CPS1/CPS2 子目录或扁平目录）、
  `bios/`、`chats/`；
- 游戏列表列：名称 / 平台 / 分类 / 大小 / CRC32 / 金手指数 / **内部标题**（GBA 英文原名，
  是中文名↔英文金手指名的桥梁）/ 依赖 BIOS（NeoGeo←`neogeo.zip`，CPS1&2←`qsound.zip`）；
- 检索：名称+内部标题模糊搜索、平台/分类筛选、表头排序、
  「仅显示有金手指」/「**仅显示缺金手指**」；
- 双击游戏看详情（基本信息 + 该游戏的全部金手指命令）；
- 整理：打开所在文件夹、导出清单 CSV/JSON、一键重跑 `sync_cheats.py` 重建关联。

> 6 GB ROM 的全量 CRC 约 5 秒，且**按 (路径, 大小, mtime) 缓存**到
> `tools/library/.crc_cache.json`（已 gitignore），再次扫描瞬时完成；扫描在后台线程，
> UI 始终可响应。可用的自检脚本：`smoke_test.py`（UI + 采集）、
> `test_scan_path.py`（小规模端到端，验证线程/缓存）、`prime_cache.py`（真实目录全量预热）、
> `test_new_features.py`（配色 + 联网 + adb + 局域网 四个新功能）、
> `test_peer_flow.py`（模拟手机端完整走一遍伙伴协议）、`test_cheat_editor.py`（金手指编辑器 + 经局域网下发）。

### 金手指编辑器（PC 端「金手指」页）
PC 端支持 **新增 / 编辑 / 删除命令**，手机 App 端只做 **逐项开启/关闭**（`CheatInfo.enabled`）。
入口在「金手指」页下方「金手指命令」区的按钮条：

- 选中左侧某个游戏（或孤立金手指）→ 右侧列出它的全部命令（名称 / 代码）；
- **新增命令**：弹窗填名称 + 代码（可多行，RetroArch 一个 cheat 多条 code 会拆成
  `cheatN_code`/`cheatN_code2`…）+ 是否默认启用；
- **编辑命令 / 删除命令**：选中右侧一条命令后操作；
- **保存修改**：同时写两处，保证两端一致——
  1. `chats/<主干>.cht`（RetroArch 文本，`to_cht_text`）；
  2. `chats/cheats.json` 的 `byCrc[CRC32]`（GamePouch `CheatInfo` 结构
     `{name, code, enabled, options, selected}`，手机端 LAN/USB 同步读的就是它）。
- 数据模型与手机端 `RomEntry.CheatInfo` 完全对齐：PC 写入的每条命令都能被 App
  `CheatInfo.fromJson` 解析，同步过去后即可在 App 里逐项开关。

### 一键联网补全金手指：`tools/library/online_cheats.py`
本地那份索引金手指只覆盖了 174/626，其余 452 个 ROM 没有。这个模块**一键**上网补齐，
入口在「联网检索金手指」页的 **一键检索并适配** 按钮（也可从「联网」菜单触发）。

数据源：`libretro/libretro-database` 仓库的 `cht/` 目录
- 索引：`https://api.github.com/repos/libretro/libretro-database/contents/cht/<平台目录>`
- 原始：`https://raw.githubusercontent.com/libretro/libretro-database/master/cht/<路径>`
- 平台目录映射：GBA→`Nintendo - Game Boy Advance`，NES→`Nintendo - Nintendo
  Entertainment System`（+ Family Computer Disk System），街机/CPS/NeoGeo→`FBNeo - Arcade
  Games`（+ Neo Geo Pocket）。
- 未认证 GitHub API 限 60 次/小时，故**每个平台目录只请求一次并缓存 7 天**
  （`tools/library/.cht_index/*.json`，已 gitignore）；原始文件下载不走 API 限额。

匹配算法（`score_pair`，0~100）
1. `title_norm`：去扩展名、去 `(USA)`/`[!]` 括号尾巴、去 `- 副标题`、只留字母数字并大写；
   候选侧再经 `cht_base_name` 取主干。
2. 打分：全等 100；**短名（≤8 字符）只认全等**——街机 `samsho5`/`samsho`、GBA
   `METROID`/`METROIDZERO` 只差一两个字符，模糊比对必然把续作配到前作；
   长名前缀命中 82~98；否则 `difflib` 相似度×100。GBA 内部标题命中额外 +3（标题常被
   12 字节截断）。
3. 阈值：默认 **84**（页面可调 60~100），低于 70 的候选直接丢弃。
4. **冲突放弃**：同一个在线文件被多个 ROM 争抢（如「口袋妖怪叶绿/绿宝石」内部标题都只
   解析出 `Pokemon`）时**全部放弃**，宁缺勿错。

产物（与本地那份同构）
- `chats/<ROM 主干>.cht`（RetroArch 文本）+ 合并进 `chats/cheats.json` 的 `byCrc[CRC32]`；
- `chats/_online_report.json` 记录 `{stem: {crc, count, source, at}}`，
  支持 **撤销联网适配** 按钮一键回退（删 .cht + 摘掉 byCrc 条目，不动本地原有金手指）；
- 并发写入用 `_SAVE_LOCK` 串行，避免多线程「读-改-写」丢条目 / 临时文件互相踩踏。

命令行也可单独跑（不依赖 GUI）：
```powershell
python tools\library\online_cheats.py --dry-run --limit 45          # 只看命中
python tools\library\online_cheats.py --platform gba --limit 20      # 实际写入
python tools\library\probe_coverage.py                               # 全库命中率评估
```

> 实测（626 游戏 / 452 缺失）：可安全适配 **51 个**（GBA 55 次打分命中去重后），
> 街机因 `FBNeo - Arcade Games` 只有 71 个 .cht、NES 因 ROM 是中文名而无内部名源，
> 命中很少——这是数据源的客观上限，不是匹配缺陷。

## 14. PC 文件库：中文名 + 游戏图标（内置元数据索引补全）；手机端库标签计数

> ⚠️ **数据源已内联进仓库**：历史数据源是同级的 MyGameSim 项目（已移除），索引现已
> 随仓库分发在 `tools/library/metadata/game_index.json`（1002 条，1.7MB）。
> `library_meta.py` 不再硬编码任何外部项目绝对路径，定位顺序为
> `GAMEPOUCH_META_DIR`(显式) → **仓库内置 `tools/library/metadata`** → `MYGAMESIM_DIR`(遗留兼容)。
> 封面图(`covers/*.png`)属第三方版权图片，**未随仓库分发**，故默认布局下 `icon` 为空；
> 需要封面时自备 `covers/` 并用 `GAMEPOUCH_META_DIR` 指向该目录。

### PC 端「文件库」表格新增两列（`tools/library`）
- **中文名**：`library_meta.py` 从内置索引（1002 条，含中文 `title` 与 `cover`）补全。
  匹配：**CRC32（精确）优先，`(平台, 英文名)` 次之**
  （`_norm` 去非字母数字后小写比对，能救回 CRC 因 dump 不同而不一致的同名游戏）。
  实测 gstest 626 游戏：**550 个拿到 name_cn（其中 403 个是汉字标题，NeoGeo 多为英文/罗马字标题）**。
- **游戏图标**：取索引条目 `cover` 字段（相对路径，指向 `library/covers/*.png`）。
  历史实测 **142 个**有封面（均为 NeoGeo）。`cover` 字段是权威路径——封面文件名里那段 hex 与
  `crcFull` 不同，**别去按 CRC 猜文件名**，直接读 `cover` 字段拼路径。
  `cover_path()` 有 `isfile` 兜底：文件不存在就返回 `None`，不会崩。
- 集成：`library_manager` 扫描算完 CRC 后 `self.meta.enrich(games)` 就地补 `name_cn`/`icon`；
  详情页多一行「中文名」+ 右侧封面预览（PIL 缩到 110×110）；表格按中文名可排序；搜索框也匹配中文名。
  索引缺失时扫描线程会 `put(('warn', ...))`，状态栏显示"未找到游戏元数据索引…"而不是静默留空。
- 索引缺失的（主要是 CPS1/CPS2 不同 dump 219 个）留空，按需另走网络检索补全。
- **⚠️ Tk 大坑**：`ttk.Treeview.insert(..., image=None)` 会让 Tcl 把后面的 `values` 当成
  非法选项报 `TclError: unknown option "…"`。**无图标时绝不传 `image`**（见 `refresh_table`
  的 `if img is not None:` 分支）。
- **⚠️ 图标列做法**：ttk 的 `image` 只能挂在树列 `#0` 上，所以用 `show=('tree','headings')` 把
  `#0` 当「图标」列（`tv.column('#0', width=34, stretch=False)`），数据列才放名称/中文名等；
  若仍用 `show='headings'` 图标不会显示。
- 头less 服务端 `run_peer_server.py` 同样 `meta.enrich(games)`，让局域网下发的库也带中文名/封面。

### peer 服务同步中文名与封面（`peer_host.build_library`）
- 每条 entry 增加 `name_cn` 与 `hasCover`；`covers` 字典填 `{CRC: 封面绝对路径}`，
  `GET /api/peer/cover/{crc}` 据此下发 PNG（`_send_cover`），路径穿越仍被挡（实测 `../` 404）。

### 手机端「伙伴文件库」（`peer_library_page.dart`）
- **筛选标签带数量**：`全部 (N)` + `GBA (n)` / `MAME (n)` / `NEOGEO (n)`…；
  数量按**搜索后**的结果算（新增 `_searchFiltered` getter，只按搜索词过滤、不按平台）。
- **显示中文名**：`RemoteGame.nameCn`（读 `raw['name_cn']`），`title` getter 改为优先中文名；
  搜索框 `hay` 也纳入 `nameCn`，可用中文名检索。
- ⚠️ 这两处 + `peer_sync.dart` 改动**需要 Dart SDK ≥3.13（Flutter ≥3.27）** 才能编译；
  本机只有 OpenHarmony 版 Flutter 3.22（Dart 3.4），**无法在此重编 APK**，代码已就绪待合适 SDK 构建。

### 真机回归（OXF-AN10，现有 APK + 新版 PC 服务）
- **封面 ✅**：对等库卡片 `Image.network('.../api/peer/cover/{crc}')`（`game.hasCover` 时）；
  实测 `2020bb` 卡片直接显示封面大图；PC 端 `/api/peer/cover/{crc}` 返 200 PNG（~53 KB）。
- **BIOS ✅**：`GET /api/peer/bios` 返 `neogeo.zip`(1.8 MB)/`qsound.zip`(2.6 KB)；
  `GET /api/peer/bios/{name}` 下载返 200 ZIP，`../` 穿越 404；手机 `files/system/` 已有
  `neogeo.zip`/`qsound.zip` 且按 `SystemFiles.syncToNeededLocations` 镜像到 `files/system/mame/roms/`。
  本机已有时「BIOS 同步区」自动不显示（设计如此，只列缺失项）。
- **存档 ⚠️ 非 PC→手机场景**：PC 是「文件库」peer，本身没有存档文件，`peer_host` **无 save 端点**，
  故 PC→手机不下发存档；存档互传是**手机↔手机**特性（两端各自有 `saves/`）。手机端对 PC 游戏
  不显示「存档」徽标（payload 无 `hasBattery/hasAuto/slots`），UI 不破。

#### ⚠️ NES / 中文名游戏的金手指关联（曾遗漏，已修）
上游索引把大量金手指**内联**在条目的 `cheats[]` 里
（例如 NES 的「吞食天地II·诸葛孔明传」就有 18 条），而几乎没有对应的 RetroArch
`.cht` 文本文件。原 `sync_cheats.py` 只从 `cheat_db_cht/*.cht` 按文件名匹配
NES/GBA，**中文名 NES ROM 必然落空**——于是这类游戏在手机端永远关联不上金手指。

修复（`tools/chatsync/sync_cheats.py` 的 `load_inline_cheats`）：额外从索引
提取所有非街机平台的内联 `cheats[]`，并在 `main` 里按两级键匹配：
1. **CRC 精确匹配**（`crcFull`，要求 ROM 字节完全一致）；
2. **规范化标题匹配**（ROM 文件名主干 vs 索引 `title`，如
   `吞食天地II·诸葛孔明传`），再放宽成「主干是标题的前缀/后缀」（仅唯一命中时采纳，
   避免误配）——这样即使 dump 不同、只要游戏名一致也能关联。

> 实测：NES 内联条目（如上述 吞食天地II、以及 FLAME/Scroll/Snow/Square/Triangle
> 等英文 hack 名）现在都能关联。注意：**吞食天地1中文版本身在索引里 `cheats:[]`
> 为空**，所以它确实没有金手指可取——这类游戏需在「金手指」页用**新增命令**手动加。
> 关联的「为什么没金手指」诊断提示也加到了 PC 端金手指页：选中游戏若未关联，会显示
> `chats/<主干>.cht 未找到且 cheats.json 无匹配`，引导用户去重新关联或手动新增。

> 自测 `test_phone_assoc.py` 用合成元数据索引 + 合成 ROM，跑通
> `sync_cheats 关联 → PC library 标记 hasCheats → 局域网拉取 cheats → 写入
> cloud_cheats.json → App 的 _cheatLayer/_applyCheats(精确复刻) 算出非空 RomEntry`
> 全链路，并验证 CRC 键对齐（手机端 crcKey 直接采用 PC 下发的 CRC，必一致）。

### 手机同步：把 ROM / 金手指 / BIOS 送到手机 App
手机端 **不会扫描目录**，文件库只认 `files/rom_index.json`（顶层 JSON **数组**，字段见
`RomEntry.toJson`：`name/originalName/relativePath/size/crc32/platform/...`，`crc32`
为无符号 32 位整数），金手指认 `files/library/cheats.json`（`byCrc[8位大写CRC]`），
BIOS 认 `files/system/`（`neogeo.zip` / `qsound.zip`，`system/mame/roms/` 由 App 自己镜像）。
所以同步必须同时写这三处。

#### 方式一：USB 直推（adb）—— `tools/library/phone_sync.py`
`/data/data/<pkg>` 对 `adb shell` 不可写，走「暂存 + run-as」两步：
```
adb push <暂存目录>          /data/local/tmp/gpsync_<ts>/
adb shell run-as com.retroemupouch.app sh /data/local/tmp/gpsync_<ts>/install.sh
```
`install.sh` 里用 `files/...` 相对路径（`run-as` 的 cwd 就是包目录），先
`mkdir -p` 再 `cp`，`rom_index.json` 写入前先备份为 `.bak`。

- 设备：`adb devices -l` 解析 serial / model / product；adb 路径自动探测
  `ANDROID_HOME` → 仓库 `.tools/android-sdk` → PATH，也可手工选。
- 去重：先 `run-as cat files/rom_index.json` 读出已有条目，按 **CRC32** 跳过手机已有的 ROM。
- 金手指：拉旧 → 合并 `byCrc`（默认不覆盖手机已有条目，可勾选「覆盖同名金手指」）→ 回写。
- 勾选推送范围 = **「文件库」页当前的筛选结果**，可先按平台/搜索筛好再推。
- ⚠️ `run-as` 只在 **debuggable** 包上可用；release 包会失败并提示改用方式二。

#### ⚠️ 手机文件库中文名变下划线（`safe_name` 乱码）已修（2026-10）
历史坑：`phone_sync.safe_name` 曾把**所有非 ASCII 字符（含中文）**一律替换成 `_`，
于是 `CT特种部队.gba` 落盘成 `CT____.gba`、索引 `name`/`originalName` 同样被抹掉，
手机文件库满屏 `__.gba` / `____ .nes`；且不同中文名会碰撞到同一目标名，后者
`cp -f` 静默覆盖前者（索引按 `relativePath` 去重还会**丢条目**）。真机实测 OXF
367 条里 142 条中招。
- 修复：`safe_name` 改为**只替换 Android 文件系统非法字符**（`\ / : * ? " < > |`
  与控制字符），中文等 Unicode 原样保留——与 App 端 Kotlin `sanitize` 同策略；
  `SyncItem` 增加 `display_name`（写进索引 `originalName`，展示用），`name` 只做
  落盘消毒；`build_plan` 对同平台目录内重名追加 ` (n)` 去重（同 App `uniqueName`）。
- 存量修复：`PhoneSync.repair_names(games)` 按 **CRC32** 把手机索引里被改成下划线的
  名字/文件名修复回本地库真实中文名——设备端 `mv` 重命名文件 + 回写 `rom_index.json`
  （写前备份 `.bak`）；纯决策逻辑在 `phone_sync.plan_repairs(remote_index, local_by_crc)`，
  可离线单测。GUI「手机同步」页与 CLI `--repair` 均提供入口。
- 自测：`test_phone_sync.py` 有离线单测（`safe_name` / `build_plan` / `plan_repairs`）
  + 真机中文名推送回归；真机 `repair_names` 已对 OXF 跑通（0 乱码残留）。EBG 的 6 条
  本就显示正常中文（`拳皇97.zip` 等），无需修复。

#### 虚拟手柄布局（App 端：可整体缩放 + 上下左右平移 + 导入导出）
需求：把左侧摇杆/十字键与右侧 ABXY 做成可按屏幕大小、握持习惯整体缩放与平移，配置放
系统设置页，支持导入导出。实现（Kotlin `VirtualPadView` + Dart `AppSettings` + SAF）：
- **数据**：`AppSettings` 增 `padScale`(默认 1.0) / `padOffsetX` / `padOffsetY`（后两者是
  相对屏幕宽/高的比例，约 -0.45..+0.45），存 `shared_preferences` → `flutter.padScale`
  等键；`EmulatorActivity.applyPersistedSettings()` 读取并下发到 `VirtualPadView`，
  `onResume` 也重取（从设置页返回即生效）。
- **几何**：`onSizeChanged` 里 `baseR = ref*0.19f*padScale`（整体缩放），`padOffX/Y =
  padOffsetX/Y * w/h`（比例转像素偏移）；`layoutStick` 把偏移叠加到摇杆/十字键中心，
  `applyPadOffset()` 再把右侧按钮与菜单/招式/1P-2P 浮层整体平移。
  ⚠️ **坑**：缩放调很大时 `baseR` 接近半屏高，`layoutStick` 的
  `desiredCy.coerceIn(topLimit, bottomLimit)` 会因 `topLimit > bottomLimit` 抛
  `IllegalArgumentException` 崩溃（真机抓到的 FATAL）。已把 `bottomLimit`
  `coerceAtLeast(topLimit)` 兜底，任何缩放都不崩。
- **设置页**：`settings_sheet._PadLayoutCard`——三个 Slider（缩放 / 水平 / 垂直）+
  「恢复默认」+「导入配置 / 导出配置」（SAF，JSON 含 `scale/offsetX/offsetY`，
  经 `platform_pal.importPadConfigViaSaf/exportPadConfigViaSaf` → `MainActivity`
  `importPadConfig/exportToFile`）。
- 自测：`flutter analyze` 零 error；真机（OXF store-debug）验证卡片渲染、滑块实时改并
  持久化、`padScale=2.35/offsetX=-0.39` 进模拟器不崩、恢复默认复位。

#### 方式二：局域网「伙伴」由手机主动拉取 —— `tools/library/peer_host.py`
手机端 `peer_server` **只支持手机主动拉取，没有任何上传接口**（`_handle` 只有 4 个 POST
分支：pair/start、pair/confirm、pair/cancel、play/*）。所以 PC 侧直接**实现协议的服务端**，
手机零改动：

- UDP 43801 应答 `GP-PEER-PING` → 单播回
  `GP-PEER-PONG {"service":"GamePouch Peer","deviceId","name","httpPort","protocolVersion":1}`
  （IP 以 UDP 源地址为准，报文里不带 IP）；
- HTTP（随机端口，填进 `httpPort`）实现 `/api/peer/info`、`/api/peer/pair/start|confirm|cancel`、
  `/api/peer/library`、`/api/peer/rom/{crc8}`、`/api/peer/cheats/{crc8}`、
  `/api/peer/cover/{crc8}`、`/api/peer/bios`、`/api/peer/bios/{name}`；
- 鉴权 `Authorization: Peer <token>`；配对流程：手机 POST `/api/peer/pair/start`
  （自带 6 位 code 与 tokenA）→ PC 页面「待确认的配对请求」里出现该请求（**每 1.5 s 自动
  刷新**，不必手点「检查配对请求」）→ 核对 6 位码后点「确认配对」→ 手机轮询
  `/api/peer/pair/confirm`，未确认返回 **202 `responder_pending`**，确认后 PC 签发 tokenB 回传；
  手机随后用自己的 tokenA（`PeerView.outboundToken`）访问受保护接口，PC 端校验时
  **同时匹配 `token` 与 `outboundToken`**，无论哪端方向都不会 401。

> ⚠️ 曾经的坑：PC 端只靠手点「检查配对请求」才能看到配对请求，用户来不及确认，
> 手机的长轮询（~25 s）超时后就报配对失败 —— 症状正是「手机能发现 PC 但没法配对」。
> 改成自动轮询 + 保留已选中行后即恢复。服务端协议本身（202 `responder_pending` /
> token / 路由）经 `test_peer_flow.py` 用 Python 模拟手机端全流程验证通过。

> ⚠️ 真机联调抓到的两个服务端 bug（均已修，2026-10）：
> 1. **POST body 读不到 → 一切配对 400**。Dart `HttpClientRequest.write()` 在未显式
>    设置 `contentLength` 时走 **`Transfer-Encoding: chunked`**（没有 Content-Length 头），
>    而 `peer_host._read_body` 只按 Content-Length 读 → 所有 POST（pair/start 等）
>    body 全空 → `bad_request`。症状：手机能发现 PC，点「配对连接」弹
>    `无法把配对请求发给对方: PeerApi(400, bad_request)`。修复：`_read_body` 支持
>    chunked 解码（逐块读长度+数据+尾随 CRLF）。
> 2. **PC device_id 每次重启随机重生成** → 手机端保存的配对全部变「已配对·离线」，
>    PC 每次重启都成「全新未配对设备」，必须重配。修复：deviceId 持久化到
>    `tools/library/.peer_self.json`，跨重启不变。
> 另：`_pair_start` 校验失败时会把「哪个字段没过 + 收到的 body 摘要」写进日志，
> 便于下次直接定位。

> 真机回归脚本：`python tools/library/run_peer_server.py`（headless 起 PC 服务端，
> 扫描 `.tools/gstest` 626 个游戏 + 金手指 + BIOS，自动确认配对，日志在
> `tools/library/peer_server.log`）。手机端全程截图 + `input tap` 驱动：
> 我的 → 发现伙伴 → 刷新 → 配对连接 → 码一致确认连接 → 勾 ROM/金手指 →
> 下一步：检查冲突 → （合规提示）我已知悉风险并继续 → 开始导入。
> 实测 OXF-AN10：配对 OK、库 626 列出、`19xx.zip` 7.5MB 覆盖下载成功落到
> `files/roms/peer/19xx.zip`、金手指写入 `cloud_cheats.json`（A3DDB605→23 条）、
> 汇总「覆盖 2 / 失败 0 / 传输 7.5MB」，logcat 无异常。

用法：手机与电脑同 Wi-Fi → 手机「我的 → 发现伙伴」→ 列表里出现本机 → 配对 → 导入。
release 包也能用；配对记录存 `tools/library/.peer_devices.json`（已 gitignore）。

> 注意：手机端 HTTP 服务只在「发现伙伴」页面打开时存活，导入时不要把页面切走。

**手机端金手指关联链路**（排查「文件库没关联上金手指」时的依据）
1. App 读 `files/library/cheats.json` 与 `files/library/cloud_cheats.json` 两层，
   取 `byCrc[e.crcKey]`，字段为 `CheatInfo`（`name/code/enabled`，choice 型
   `options/selected`）；`hasCheats` 只要求列表非空，不要求有已启用的项。
2. LAN 导入时手机把拉到的金手指写进 `cloud_cheats.json`（**不覆盖**本机
   `cheats.json` 里用户自己的开关状态）；USB 直推则合并进 `cheats.json`。
3. 键是 **整个 ROM 文件的 zlib CRC32**（8 位大写 hex），App 与 PC 算法一致
   （NES 也不剥 iNES 头），因此只要金手指真的送达，就一定关联得上——
   关联不上的根因几乎都是「没送达」（局域网配对没完成 / USB 没勾金手指）。

## 15. 近期修复与已知坑（2026-10）

### 15.1 OHOS 退出到文件库崩溃（街机核心 `dlclose`）

- **现象**：进 neogeo / mame 街机游戏后点右上 ✕ → **直接退出整个 app**（不回文件库）；NES/GBA 正常。
- **根因**：`app/ohos/entry/src/main/cpp/gpretro.cpp` 的 `EmuLoop` 退出序列
  `retro_unload_game → retro_deinit → StopAudio → dlclose(g_coreLib)` 中，
  `dlclose(libgs_mame.so)` 在**渲染线程**触发 MAME 海量全局静态析构 → `SIGSEGV`
  杀死渲染线程 → 整进程退出。NES/GBA 核心极小、`dlclose` 干净，故不崩。
- **修复**：移除 `dlclose`，仅保留 `g_coreLib = nullptr` 复位变量。不卸载核心句柄是
  **无害泄漏**——下次启动会 re-`dlopen` 同一个引用计数对象并重解 `dlsym` 符号
  （RetroArch 等前端同做法）；对所有核心（含 NES/GBA）**无回归**。
- **配套防御**：`stopEmulator()` NAPI（idempotent：`g_running=false` → `join` 渲染线程
  → egl 拆除 → `g_coreReady=false`）+ `OnSurfaceDestroyed` 复用；`desc[]` 新增导出
  `"stopEmulator"`（数量 28→29）；`EmulatorSpike.ets` 在 ✕ `onClick`（`stopEmulator();
  router.back()`）与 `aboutToDisappear` 首行调用，确保 XComponent surface 销毁前线程已停。

### 15.2 OHOS 图标同步安卓设计

- 安卓 `app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` 覆盖拷贝到
  `app/ohos/entry/src/main/resources/base/media/icon.png`（`module.json5` 用 `$media:icon`）。
- ⚠️ 安卓 xxxhdpi 仅 192px，OHOS 会放大显示略糊；若有 1024 主图替换 `media/icon.png` 更清晰。

### 15.3 Android 功能菜单「摇杆 / 十字键」切换（从 OHOS 同步）

- 鸿蒙 `EmulatorSpike` 功能菜单有「摇杆」命令循环 `STICK → DPAD8 → DPAD4`；安卓原本
  **只有**从 Flutter 设置读 `flutter.stickMode` 应用（`applyPersistedSettings`），功能菜单无切换。
- **修复**（`app/android/.../kotlin/.../EmulatorActivity.kt` + `VirtualPadView.kt`）：
  - `buildMenuBar` 面板新增「摇杆」按钮 → `cycleStickMode()`：循环三态、写回
    `FlutterSharedPreferences` 的 `flutter.stickMode`（与设置页 / `applyPersistedSettings`
    锁步）、`Toast` 提示「摇杆模式：模拟摇杆 / 十字键(八向) / 十字键(四向)」。
  - `VirtualPadView` 的**绘制**与**触摸派发**从「仅 `useDpadUi`」改为
    「`useDpadUi || stickMode == DPAD4`」，使切换真正改变屏上十字键/摇杆外观与命中。
  - `layoutDpad()` 本就在 `layoutButtons` 中无条件执行，切到 DPAD4 时几何已就绪。

---

## 16. 安卓包名重命名 + 华为应用市场（AppGallery Connect）接入（2026-10）

> 本项目（RetroEmuPouch）是 GamePouch 的**重命名派生项目**。Android 包名已从
> `com.gamepouch.app` 改为 **`com.retroemupouch.app`**（与 `agconnect-services.json`
> 的 `package_name` 一致）。⚠️ **OHOS bundleName 仍是 `com.gamepouch.gamepouch`**（未改名）。

### 16.1 包名重命名的完整清单（漏一处就运行时崩）

改名不是只改 `applicationId`，必须同步这几处：

| 位置 | 改动 |
|---|---|
| `app/android/app/build.gradle.kts` | `namespace` 与 `applicationId` → `com.retroemupouch.app` |
| 12 个 Kotlin 文件 | `package` / `import` / 全限定引用（`com.gamepouch.app` → `com.retroemupouch.app`，`netplay` 子包同理） |
| **`app/android/app/src/main/cpp/jni_bridge.cpp`** | **35 处 JNI 符号** `Java_com_gamepouch_app_NativeBridge_*` → `Java_com_retroemupouch_app_NativeBridge_*` |
| `tools/library/phone_sync.py`、`scripts/mame/*.ps1` | adb `run-as` 用的包名 → `com.retroemupouch.app` |

> ⚠️ **最容易漏、也最致命的是 JNI 符号**：JNI 函数名是 `Java_<包名下划线>_<类名>_<方法名>`。
> 只改 Kotlin 不改 `jni_bridge.cpp`，**编译能过、APK 也能装**，但一启动就
> `java.lang.UnsatisfiedLinkError: No implementation found for ...nativeInit()`。
> 验证（对 `libgsrunner.so`）：`com_retroemupouch_app` 有命中，且 `com_gamepouch_app` **无**命中。

- **Kotlin 源码目录可以不跟着改**：Kotlin 不强制「目录 = 包名」，文件留在
  `.../kotlin/com/gamepouch/app/` 而声明 `package com.retroemupouch.app` 能正常编译运行
  （当前即是此状态，纯观感问题，之后可用 `Move-Item` 整理成 `com/retroemupouch/app/`）。
- 清单里 `android:authorities="${applicationId}.apkprovider"` 与 `MainActivity` 的
  `"$packageName.apkprovider"` 都是**占位符 / 运行时取值**，无需手改。

### 16.2 华为 AppGallery Connect（AGC）SDK 接入 —— 正确姿势

AGC 的 gradle 插件坐标是 **`com.huawei.agconnect:agcp`**，且**没有** Gradle plugin-marker 产物，
因此**不能**用 `plugins { id("com.huawei.agconnect") }` DSL（会报
`Plugin [id: 'com.huawei.agconnect'] was not found`），必须走 `buildscript` classpath + `apply plugin`。
另外华为仓是 **`https://developer.huawei.com/repo/`**（不是 `repo.huaweicloud.com/repository/maven/`——
后者只镜像 SDK 如 `agconnect-core`，**不含 agcp 插件**）。

**项目级 `app/android/build.gradle.kts`**（本项目是 `.kts`，华为文档的 Groovy 需转换）：

```kotlin
buildscript {
    repositories {
        maven { url = uri("https://developer.huawei.com/repo/") }
        // agcp 的传递依赖（如 com.google.code.gson:gson）不在华为仓，必须保留常规仓
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google(); mavenCentral()
    }
    dependencies {
        // ⚠️ AGP 必须写在 agcp 之前，原因见下方坑 3
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("com.huawei.agconnect:agcp:1.9.6.300")
    }
}
allprojects {
    repositories {
        google(); mavenCentral()
        maven { url = uri("https://developer.huawei.com/repo/") }
    }
}
```

**模块级 `app/android/app/build.gradle.kts`**：

```kotlin
dependencies {
    implementation("com.huawei.agconnect:agconnect-core:1.9.6.300")
}
// 华为要求写在文件末尾
apply(plugin = "com.huawei.agconnect")
```

`agconnect-services.json` 放在 **app 模块根目录**（`app/android/app/agconnect-services.json`），
其 `package_name` 必须与 `applicationId` 完全一致，否则插件校验不过。

#### 三个必踩的坑（按实际报错顺序）

1. **`Could not find com.google.code.gson:gson:2.8.0`**
   → `buildscript.repositories` 里只有华为仓。华为仓不托管 gson，补上 google/mavenCentral（或阿里云镜像）。
2. **`com.android.tools.build:gradle is no set in the build.gradle file`**
   → 旧版 agcp（如华为文档里的 `1.5.2.300`）要求 AGP 走传统 `buildscript` classpath 声明；
   本项目 AGP 9.1 是在 `settings.gradle.kts` 用 `plugins { ... apply false }` 声明的。
   解决：升到 `1.9.6.300`，并**把 AGP 也写进 `buildscript` classpath**。
3. **模块 `android { }` 的 Kotlin DSL 编译不过**（`minSdk` / `targetSdk` / `signingConfig` / `release` 全 Unresolved）
   → agcp 自带的类把 AGP 9.1 的类挤掉了。Gradle 按**声明顺序**解析 buildscript classpath，
   因此 **`classpath("com.android.tools.build:gradle")` 必须排在 `agcp` 之前**。

#### 验证接入成功

- 构建通过（store 版 debug APK，体积比接入前增加约 SDK 大小）。
- `aapt dump badging` → `package: name='com.retroemupouch.app'`。
- `aapt dump resources` 出现 `com.retroemupouch.app:string/agc_<hash>` 资源
  → 说明插件**确实处理了** `agconnect-services.json`（这是插件的核心职责）。

> ⚠️ **踩坑（已修复，修复文件务必保留）**：AGC 配置在 **debug** 产物里注入成功，但在
> **release** 产物里**曾被静默丢弃**。现象与证据：
> - debug `resources.arsc` 344 KB，含 `agc_`；release 108 KB，**不含** `agc_`。
> - 两个 APK 都**不**把 `agconnect-services.json` 当 asset 打包（只有 `agconnect-core.properties`），
>   配置**只**以 `agc_*` 字符串资源存在——丢了就彻底没了，而且**编译、安装都不报错**。
> - 中间产物 `generated/res/agc/store/release/values/values.xml` 与 `packaged_res/storeRelease`
>   **都含** `agc_`，但 `shrunk_resources_binary_format`（127 KB）与 `optimized_processed_res`
>   （108 KB）**都不含** → 是被发布期资源管线裁掉的：这些资源**只**被 AGC SDK 通过
>   `getIdentifier` 动态访问，代码里没有任何静态引用。
>
> **修复（已验证）**：新增 `app/android/app/src/main/res/raw/keep.xml`：
>
> ```xml
> <resources xmlns:tools="http://schemas.android.com/tools"
>     tools:keep="@string/agc_*" />
> ```
>
> 修复后 release `resources.arsc` 108 KB → **123 KB**，`aapt dump resources` 出现
> **132 个 `string/agc_*`**（与 debug 完全一致）。
>
> ⚠️ **别删这个文件**：删掉后 release 包会静默丢失全部 AGC 配置，上架后 AGC 服务起不来，
> 而构建不会有任何报错。复验方法：对 release 的 `resources.arsc` 做**字节级**搜索 `agc_`
> （ASCII 与 UTF-16 两种编码都试；`findstr` 搜二进制不可靠，会漏报）。

### 16.3 构建环境要点

- **`app/android/local.properties` 的 `flutter.sdk` 必须指向 Android 版 Flutter**
  （`.tools\flutter`）。曾误指向 `flutter_ohos`（鸿蒙 fork），会导致 Android 构建异常。
- 工具链由 `scripts/setup-env.ps1` 以 **junction** 方式从兄弟项目 **`MyLangLean\.tools`**
  挂载（android-sdk / flutter / flutter_ohos / caches / jdk17）；`jdk21` 是实体目录。
- release 签名：`keystore.properties` 的 `storeFile` 指向本项目自己的
  `.tools\signing\gamepouch_dev.jks`（已用 keytool 验证 alias `gamepouch` 可用）。

### 16.4 与 GamePouch 的独立性（GamePouch 将被清理）

已把对 `D:\ai\prj\trae\HuaWei\GamePouch` 的**引用**全部改到本项目路径：
`keystore.properties`、`app/ohos/.../cpp/CMakeLists.txt`（3 处）、`scripts/_setup-ndk.ps1`、
`scripts/check_mame_tree.sh`、`scripts/build-mame-ohos-wsl.ps1`、`scripts/mame/*.ps1`、
`tools/library/phone_sync.py`、`docs/*`。

已**复制**到本项目的资产（否则删除后会丢）：
`cores/ohos/build/libgs_*.so` 六个鸿蒙核心（约 70 MB）。

> ⚠️ 仍未本地化（删除 GamePouch 后这些功能需重新获取，但**不影响 APK 构建**）：
> - `build/mame-src`、`build/mame-ohos-src`（MAME 源码树，仅「重编街机核心」用，脚本可从上游重新克隆）
> - `build/android-ndk-r28c-linux.zip`（`_setup-ndk.ps1` 用，可重新下载）
>
> `.dart_tool/`、`.cxx/`、`.hvigor/` 里仍残留旧路径痕迹，都是**可再生的构建缓存**，
> 不影响独立性（必要时 `flutter clean` / 删除 `.cxx` 即可）。
>
> 工具链仍依赖兄弟项目 **MyLangLean**（见 16.3），它不在本次清理范围内；
> 若要完全自包含，需把 `MyLangLean\.tools` 实体化到本项目 `.tools`。

---

## 17. OHOS ↔ Android Netplay 确定性修复（2026-10-30，C++ 层）

跨平台联机「安卓主机 + 鸿蒙客机」运行时，两侧同是 KOF97 但检查点哈希逐帧偏移。根因有三，
全部固化到 C++ 代码（`gs_netplay.cpp` 被 Android + OHOS **共同编译**，`gpretro.cpp` 仅 OHOS）：

### 17.1 OHOS EmuLoop 预跑 solo 帧 → `retro_reset()` 同步

- **根因**：Android 的 pace 线程**在 `netplayStart` 之后才 spawn**，帧 0 从「刚 `retro_load_game` 的 pristine state」出发；
  OHOS 的 `EmuLoop` 从 `OnSurfaceCreated` 就启动 `while(g_coreReady) retro_run()` solo 帧，
  ArkTS 稍后才调 `netplayStart` → 此时 OHOS 核心已经**跑了 N 帧（KOF97 吸引模式、投币计数等）**，
  与 Android 起点不一致 → lockstep frame 0 起状态逐帧偏移，检查点对不上。
- **修复**（`gpretro.cpp` 的 `NativeNetplayStart`，约 L1734-1740）：
  成功 attach `np::GsNetplay` 后，在 `g_coreMtx` 锁内调一次 `g_core.retro_reset()`，
  把 OHOS 核心 rewind 回**与 Android 完全相同的 post-load_game state**。
- **SRAM 顺序**：OHOS guest 的 `netplayLoadSram` 在 `retro_reset` **之前**注入（reset 清内存档），
  但 Android 的 MAME 冷启动（`skip state0`）也是 reset 后自然进入，
  两侧 SRAM 等效——**暂不需 re-inject SRAM**；若后续非 MAME 核心出现 SRAM 丢失，
  才需要把 `netplayLoadSram` 移到 pace 线程 reset 之后。
- **诊断日志**：`GPRETRO_INFO("core retro_reset() for netplay determinism")`
  （hilog 上 `<private>` 会屏蔽数值/字符串，靠常量串过滤 `GPRETRO: core retro_reset`）。

### 17.2 Host 预设 `started_=true` → 10 s 客机 bootstrap 超时

- **根因**：`gs_netplay.cpp` 旧版 `started_` 对 host 初始化为 `true`，host pace 线程立刻进入
  `beginFrame` 闸门。若客机 bootstrap（拉 `/sram`、写本地 save、冷启动 MAME）超过 10 s，
  host 的 `beginFrame` timeout 直接 **park forever**，客机永远进不了锁步。
- **修复**：`started_` 对**两端**都初始化为 `false`。host 开闸门的唯一路径是 `notifyStart()`
  （在 guest POST `/ready` **之后**由 Dart 调用）；guest 在收到 CTRL_START 后开闸门。
- **影响范围**：`gs_netplay.cpp` 被 Android + OHOS 共同编译（`libgsrunner.so` + `libgpretro.so`），
  一处改动两端同步生效，无需分别改。

### 17.3 EmuLoop 外层持有 `g_coreMtx` → 递归锁死

- **根因**：OHOS `EmuLoop` pace 循环外层持有 `std::lock_guard<std::mutex> lk(g_coreMtx)`，
  之后同一线程的 `OhosNetCheckpoint()` 内部也要 `lock(g_coreMtx)` → 非递归 `std::mutex` 递归
  re-lock → **死锁**，表现为某个检查点帧后画面冻结。
- **修复**：pace 循环外层**完全不持锁**；只有单次 `retro_run()` 调用被 `lock_guard` 包围；
  `OhosNetCheckpoint()` 在内部自己加锁。`GsRunner`（Android）同构结构——
  外层 loop 不持锁、`runFrame()` 内加锁。

### 锁结构对照表（两端必须 lockstep）

| 组件 | Android GsRunner | OHOS gpretro.cpp |
|------|------------------|-------------------|
| Pace loop 外层 | **不持锁** | **不持锁** |
| `runFrame()` / `retro_run()` | `coreMtx_` 内加锁 | `lock_guard<g_coreMtx>` |
| `beginFrame` / `endFrame` | lock-free | lock-free |
| checkpoint | 内部自行加锁 | 内部自行加锁 |
| `notifyStart` | lock-free | lock-free |

---

## 18. 联机一键招式（Netplay-Safe Macro，2026-10-30）

### 问题

格斗游戏的「一键连招」(macro) 在 **solo 模式**走 `nativePlayMacro`——
它让 native runner 按帧序列直接写核心按键位，**绕过** Flutter 层的 `buttonMask`。
netplay 下这是**致命的确定性行为破坏**：macro 输入不走 per-frame bitmask、
不进 HMAC、不跟对端同步 → 对端没按同样的键、画面必 desync。
旧版用 `npCfg != null` **直接禁用** macro，联机时连招完全失效。

### 修复（`EmulatorActivity.kt`）

netplay 下把 macro **改走同一条 lockstep 通道**：
- `startNpMacro(seq)` 按 50 ms/步（VirtualPadView 约 3 帧 @ 60 fps 节奏）
  把预编译的 per-frame mask 序列写到 `npMacroMask`；
- `renderer.buttonMask = npPadMask or npMacroMask` —— 与 solo 模式**同一字段**，
  GL 渲染线程每帧调 `nativeNetplayLocalMask(buttonMask)`，mask 进 HMAC、到对端、完全确定；
- `cancelNpMacro()` / `npEnded` 时自动清除，不泄漏 mask。

### 安全保证

| 场景 | 通道 | 确定性 |
|------|------|--------|
| Solo 一键连招 | `nativePlayMacro`（native macro player） | ✓ |
| Netplay 一键连招 | `nativeNetplayLocalMask`（lockstep bitmask） | ✓ |
| Netplay 手指操作 | 同 `nativeNetplayLocalMask` | ✓ |

---

## 19. 伙伴 Endpoint 自愈（hostIp/hostHttpPort 随邀请携带，2026-10-30）

### 问题

Wi-Fi 环境下 DHCP 重分配 IP / 用户换路由器后，配对记录里的 `lastIp` + `lastHttpPort`
变 stale：发现页扫到的是新 IP，但旧记录没更新 → 伙伴列表显示离线，**邀请发得出去
但 accept/decline 回不来**（对端用旧地址回）。

### 修复（Dart 信令层）

1. **邀请携带 host 实时 endpoint**（`PlayInvite` 增 `hostIp` / `hostHttpPort`）：
   - `hostIp` = 邀请 TCP 连接的 source IP（**host 刚刚证明可达的那条路径**）；
   - `hostHttpPort` = host 的信令服务器**当前监听端口**（`PeerServer.port`，
     由 `PeersController.start()` 后发布到 `PlaySessionManager.localHttpPort`）。
2. **guest 优先用邀请里的 endpoint**（`hostBaseUrl` getter），
   对端（`accept` / `decline` / `play` 入口）走这条 proven 路径，**不再信任**
   自己的 stale pairing record。老 peer 没带这两个字段时回退到已扫 `PeerView.baseUrl`。
3. **host 侧自愈 caller 的 endpoint**：`PeerServer._handle` 的
   `invite` 分支，成功发邀请后把 `caller.deviceId` 的 `lastIp`/`lastHttpPort`
   更新为 TCP 连接源地址 + host 自报端口（`peer_store.touch`）。

### 涉及文件

| 文件 | 改动 |
|------|------|
| `app/lib/data/play/play_session.dart` | `PlayInvite` 增 `hostIp/hostHttpPort/hostBaseUrl`；`PlaySessionManager.localHttpPort` |
| `app/lib/data/peer/peers_controller.dart` | `srv.start()` 后发布 `playManager.localHttpPort` |
| `app/lib/data/peer/peer_server.dart` | `invite` 分支自更新 caller endpoint |
| `app/lib/features/peer/peers_page.dart` | 邀请携带 live endpoint |
| `app/lib/features/peer/peer_library_page.dart` | 用 `hostBaseUrl` 回 accept |
| `app/ohos/.../EmulatorSpike.ets` | 鸿蒙侧同步 invite endpoint 字段 |

---

## 20. 仓库结构速记（RetroEmuPouch 分叉后）

### 顶层目录

| 目录 | 说明 |
|------|------|
| `app/` | Flutter 壳 + Android / OHOS 原生层（核心代码，git track） |
| `app/lib/` | Dart 业务层（`data/play/` 联机信令，`data/peer/` 伙伴发现与同步，`features/` UI 页面，`pal/` 平台抽象） |
| `app/android/` | Android 原生（Kotlin + C++ netplay） |
| `app/ohos/` | HarmonyOS NEXT 原生（ArkTS + `gpretro.cpp` NAPI + libretro host） |
| `scripts/` | 构建/签名/部署脚本（PowerShell + bash） |
| `tools/library/` | PC 端 Python 工具（文件库管理 + 局域网服务 + 手机同步） |
| `tools/chatsync/` | Python 金手指关联（索引 ↔ ROM CRC32） |
| `docs/` | 开发文档（本 skills.md、鸿蒙 libretro 移植、UI 规格等） |
| `third_party/CORE_PINS.txt` | 5 个 libretro core 的 commit pin（不入仓的内核源码定位） |
| `.tools/` | junction 到兄弟项目共享 SDK（gitignore，体积数 GB） |
| `cores/` | 预编译核心 `.so` 工作树（gitignore，本地构建产出） |
| `build/` | MAME 源码克隆 + OHOS SDK 解包（gitignore） |

### C++ netplay 层（Android + OHOS 共享）

| 文件 | 说明 |
|------|------|
| `app/android/app/src/main/cpp/netplay/gs_netplay.h` | 主类 `np::GsNetplay`：UDP 帧/HMAC/锁步闸门/CTRL 包 |
| `app/android/app/src/main/cpp/netplay/gs_netplay.cpp` | 实现：`start/stop/notifyStart/beginFrame/endFrame` + 自适应 D |
| `app/android/app/src/main/cpp/netplay/gs_np_ring.{h,cpp}` | 输入环（每帧 D+2 冗余、ack 缺口重发） |
| `app/android/app/src/main/cpp/netplay/gs_np_codec.{h,cpp}` | 帧编解码 + HMAC-SHA256 截断 tag |
| `app/android/app/src/main/cpp/netplay/gs_np_delay.{h,cpp}` | 自适应 RTT/lead 统计 + D 切换 |
| `app/android/app/src/main/cpp/netplay/gs_np_sha256.{h,c}` | SHA-256（纯 C，无第三方依赖） |
| `app/android/app/src/main/cpp/netplay/gs_np_replay.{h,cpp}` | 重放窗口（rollback 预留，当前 delay-based 未启用） |

> ⚠️ `gs_netplay.*` 同时被 `libgsrunner.so`（Android）和 `libgpretro.so`（OHOS）编译，
> 一处改动两端 lockstep 生效；任何 netplay 协议改动必须**两端同步编译部署**。

### OHOS 原生宿主（`app/ohos/entry/src/main/cpp/gpretro.cpp`）

| 模块 | 说明 |
|------|------|
| NAPI 导出 | `StartEmulator` / `SetEmulatorTarget` / `SetInput` / `ResetEmulator` |
| Netplay NAPI | `NativeNetplayStart`（含 `retro_reset()` 确定性修复）/ `Stop` / `LocalMask` / `NotifyStart` / `NotifyPaused` / `Stats` / `StateHash` / `LoadSram` |
| EmuLoop | 主循环；netplay 模式每帧调 `beginFrame/endFrame`，外层**不持锁**、仅 `retro_run()` 内部 `lock_guard<g_coreMtx>` |
| Checkpoint | `OhosNetCheckpoint()`（早期帧诊断）+ `NativeNetplayStateHash()`（FNV-1a64 哈希） |
| GPRETRO 日志域 | `0xD001234`，tag `GPRETRO`；hilog 变量值被 `<private>` 屏蔽，靠常量串过滤 |

### Android 原生层（`app/android/app/src/main/cpp/runner/`）

| 文件 | 说明 |
|------|------|
| `gs_runner.{h,cpp}` | `GsRunner`（pace 线程、frame gate、`retro_run` lockstep） |
| `gs_core.{h,cpp}` | `GsCore`（retro 符号装载 + env_callbacks + SRAM / serialize） |
| `jni_bridge.cpp` | 全部 JNI 符号（**包名已改 `com.retroemupouch.app`，勿漏**） |

### Dart 业务层关键模块

| 路径 | 说明 |
|------|------|
| `data/play/play_session.dart` | `PlaySessionManager`：邀请/接受/拒绝状态机；含 `PlayInvite`（`hostIp/hostHttpPort` endpoint 自愈字段） |
| `data/play/play_session_impl.dart` | **实际运行时实现**（`PlaySession` 接口 + `InviteGate`）；`PlaySessionManager` 持有引用 |
| `data/play/netplay_capability.dart` | 联机门禁：`coreSupported` + `RejectReason` 链 |
| `data/play/multiplayer_catalog.dart` | `multiplayer.json` 白名单解析（mame/fbalpha2012/fceumm 段） |
| `data/peer/peer_server.dart` | **Android 端发现页存活**的 HTTP/UDP 服务端（配对 + invite/accept） |
| `data/peer/peer_client.dart` | 伙伴 HTTP 客户端（库、ROM、金手指、BIOS、封面拉取） |
| `data/peer/peer_discovery.dart` | UDP multicast `GP-PEER-PING/PONG` 发现 |
| `data/peer/peers_controller.dart` | 发现页状态管理；`srv.start()` 后发布 `localHttpPort` 让 invite 携带 |
| `data/peer/peer_store.dart` | 配对记录持久化（deviceId → lastIp/lastHttpPort） |
| `data/peer/peer_sync.dart` | 伙伴库导入执行器（含 BIOS 同步落地） |
| `data/peer/peer_crypto.dart` | `PeerToken`（HMAC-SHA256 配对信令鉴权） |
| `data/play/library_search.dart` | 文件库扫描 + `rom_index.json` 解析 |
| `data/package/game_package.dart` | 资源包导出/导入（manifest `schemaVersion` 2 + 顶层 `bios` 段） |
| `pal/platform_pal.dart` | 平台抽象（importBiosBatchViaSaf / exportBiosZipViaSaf / import/export PadConfig） |
| `pal/ohos_pal.dart` | OHOS 侧 `PlatformPal`（**所有缺失插件的 `catch (_)` 兜底**） |
| `features/library/library_page.dart` | 文件库（含 RouteAware `didPopNext` 刷 BIOS/ROM） |
| `features/library/missing_bios_dialog.dart` | 启动缺 BIOS 弹框（走批量 SAF import 一次补齐） |
| `features/play/play_lobby_page.dart` | 联机大厅（邀请/接受 → 进入游戏） |
| `features/play/play_invite_dialog.dart` | 邀请弹窗 |
| `features/peer/peers_page.dart` | 发现 + 配对 |
| `features/peer/peer_library_page.dart` | 伙伴文件库 |
| `features/settings/settings_sheet.dart` | 设置页（`_BiosManagerCard` + `_PadLayoutCard`） |
| `main.dart` | `main()`：**所有 `AppSettings.load()`/consent 检查必须 `try/catch`**（OHOS 插件缺失会抛） |

### 鸿蒙 ArkTS 层

| 文件 | 说明 |
|------|------|
| `entry/src/main/ets/plugins/GamePouchPlugin.ets` | 4 个 MethodChannel：`gs/storage` / `gs/emulator` / `gs/updater` / `gs/netplay` |
| `entry/src/main/ets/netplay_session.ets` | **Netplay bootstrap**（TCPSocketServer + HTTP 端点 + TCPSocket 客户端，契约与 Kotlin `PlayBootstrapServer` **逐字段同构**） |
| `entry/src/main/ets/pages/EmulatorSpike.ets` | 模拟器页（XComponent + EGL 渲染；`onEmulatorStart` 里调 `netplaySession.startHost/startGuest`） |
| `entry/src/main/ets/entryability/EntryAbility.ets` | `configureFlutterEngine` 注册 `GamePouchPlugin`；Netplay bootstrap 需在 `onForeground` 启动 |

### Android 原生层（Kotlin）

| 文件 | 说明 |
|------|------|
| `EmulatorActivity.kt` | 模拟器 Activity：EmuLoop pace 线程 + VirtualPadView 触摸 + Netplay 三状态（solo/host/guest） + Netplay-safe macro |
| `NativeBridge.kt` | JNI 封装（全部 `native*` 方法） |
| `VirtualPadView.kt` | 虚拟手柄（摇杆/十字键 + macro 序列录制） |
| `LockedRom.kt` | 启动 BIOS 镜像（`ARCADE_BIOS_NAMES` = `[neogeo.zip, qsound.zip]`，**必须与 Dart `SystemFiles.requiredBios` lockstep**） |
| `netplay/PlayBootstrapServer.kt` | HTTP bootstrap（`/sram` `/state0` `/ready` `/start` `/sram-final`，与鸿蒙 `netplay_session.ets` 同契约） |
| `netplay/PlayBootstrapClient.kt` | Guest bootstrap 客户端（拉 SRAM/state0、发 ready、轮询 start） |
| `netplay/NetplaySessionCfg.kt` | Netplay 启动配置（role/coreId/romCrc/sram/state0） |
| `netplay/NpLog.kt` | GS-Netplay / GS-NetBoot 日志工具 |

### 构建脚本（scripts/）

| 脚本 | 用途 |
|------|------|
| `use-env.ps1` | **每终端点源**（Android：默认；鸿蒙：`-Ohos -HarmonyOS`） |
| `setup-env.ps1` | 首次初始化（junction 共享工具链 + jdk21 实体化） |
| `build-apk.ps1` | Android APK（`-Flavor store|community -DebugBuild -SplitPerAbi`） |
| `build-hap.ps1` | OHOS HAP（自动走 `use-env -Ohos -HarmonyOS`） |
| `build-mame.ps1` | Android 街机核心（WSL + NDK 交叉编译，产出 `libgs_mame.so`） |
| `build-mame-ohos.ps1` | OHOS 街机核心（Linux 原生 OHOS SDK，产出 `cores/ohos/build/libgs_mame.so`） |
| `build-mame-ohos-wsl.ps1` | 单一入口：封装 WSL 原生链全流程（增量构建、清 `.d`、限并发） |
| `sign-ohos-hap.ps1` | CLI 自签 HAP（ECC P-256 CA + app/profile 证书链；与 DevEco 自动签名二选一） |
| `make-release-keystore.ps1` | Release keystore（JKS + `keystore.properties`） |
| `ci.ps1` | 构建门禁（check-apk-content / check-hap-content，确保零 ROM/BIOS 进产物） |
| `check-apk-content.ps1` | APK 合规扫描（零 BIOS/ROM） |
| `check-hap-content.ps1` | HAP 合规扫描 |
| `mame/refresh-roms.ps1` | 街机一键刷新（归拢 BIOS → 替换 ROM → 部署设备 → 验证） |
| `build.bat` | 顶层一键构建（Android + OHOS，供 CI / 新人） |

### PC 端 Python 工具（tools/）

| 工具 | 用途 |
|------|------|
| `library/library_manager.py` | tkinter 桌面 GUI（文件库 / 金手指 / BIOS / 关联报告 / 联网检索金手指 / 手机同步） |
| `library/phone_sync.py` | USB 直推手机文件库（`adb push` → `run-as` 安装，`safe_name` 已修中文） |
| `library/peer_host.py` | **Headless 伙伴服务端**（手机 `tools/library/run_peer_server.py` 启动，PC 模拟 peer 协议） |
| `library/online_cheats.py` | 一键联网补金手指（libretro-database 仓库，缓存 7 天，阈值 84 分） |
| `library/library_meta.py` | 元数据索引读取 + `name_cn`/`cover` 补全（CRC 精确匹配优先，`(平台,英文名)` 次之） |
| `chatsync/sync_cheats.py` | ROM CRC32 → 金手指关联（街机内联 + GBA RetroArch `.cht` + NES 内联三条路径） |

### 常见 gitignore 规则速查

| 规则 | 说明 |
|------|------|
| `/.tools/` | junction 共享工具链（数 GB） |
| `**/build/` | Android / OHOS / CMake 构建产物 |
| `**/.cxx/` / `**/.hvigor/` | CMake / Hvigor 缓存 |
| `**/oh_modules/` | OHOS npm 依赖 |
| `*.log` / `*.tmp` | 日志与临时 |
| `*.zip` | ROM 包 / SDK 压缩包 |
| `**/*.so` | 预编译原生库（用户本地构建） |
| `cores/` / `third_party/*` | 预编译核心 / 第三方 libretro 内核 |
| `keystore.properties` / `*.jks` | 签名材料 |
| `docs/GamePouch*.json` | 临时数据文件（曾 85MB 大文件） |
| `/ui*.xml` / `/ohos*.xml` | 根目录 UI dump / 调试导出 |
| `/android_log*.txt` / `/ohos_hilog*.txt` | 根目录临时日志 |

---

## 21. OHOS 导出 / 导入 SAF 修复（2026-10-31，真机验证）

资源包「导出资源包」在真机表现：打包（251MB 流式 ZIP）完整跑完，但最后系统保存框**没弹出来** → 直接弹「导出未保存 / 已取消」。根因是 OHOS 平台特有、与 Android 完全无关的三处坑，逐一记录以免重犯。

### 21.1 ⚠️ OHOS `MethodChannel` 不解码 Dart `Map` 参数（最高频坑）

- **现象**：Dart 用 `invokeMethod('exportPackageViaSaf', {'sourcePath': ..., 'suggestedName': ...})` 传 `Map`，原生 `call.argument` 取到的对象**读不到字段**（`.sourcePath` / `.suggestedName` / `.name` / `.mime` 全部为空）。结果原生拿到空 `sourcePath` → 提前 `return false` → 保存框压根没弹。
- **影响面**：所有用 `Map` 传参的存储通道调用都静默失效：`exportPackageViaSaf` / `importRomViaSaf` / `deleteBios` / `exportMovesConfigViaSaf` / `exportPadConfigViaSaf`。这就是为什么 App 内「导入 ROM / BIOS」一直点不出框（用户此前只能靠 PC/peer 同步灌 ROM）。
- **修复**：与本项目 `gs/emulator` 通道既有约定一致——**Dart 侧发 JSON 字符串，原生侧 `JSON.parse(call.args)`**：
  - Dart（`app/lib/pal/ohos_pal.dart`）：`invokeMethod('exportPackageViaSaf', jsonEncode({'sourcePath': sourcePath, 'suggestedName': suggestedName}))`
  - 原生（`GamePouchPlugin.ets` `onStorage`）：`const obj = rawArgs ? JSON.parse(rawArgs) : null; const sourcePath = obj?.sourcePath ?? '';`
  - `dispatch` 里用 `call.args as string` 取原始串（**不是** `call.argument`）。
- **铁律**：OHOS 侧 MethodChannel 传多字段，**一律用 `jsonEncode` 字符串 + `JSON.parse`**，不要直接传 `Map`。

### 21.2 ⚠️ `@ohos.file.picker` 必须 `UIAbilityContext`

- **现象**：`DocumentViewPicker.save()/select()` 要求 `UIAbilityContext`；插件 `onAttachedToEngine` 只给 `ApplicationContext`，导致 picker 静默失败、`if (!ctx) return false`。
- **修复**：`EntryAbility.configureFlutterEngine` 里 `GamePouchPlugin.setAbilityContext(this.context)` 把 ability context 存进**静态字段**；所有 picker 方法改用 `ctxForPicker()`（先 `uiCtx` 再静态 `abilityCtx`）解析，规避 Flutter 插件生命周期歧义。

### 21.3 ArkTS 编译期硬限制（会直接 build fail）

- `throw e;` —— catch 变量 `e` 是 arbitrary type，被 **`arkts-limited-throw`** 拒绝。改为 `throw new Error((e as Error).message)`。
- `ESObject` 受限用法会出 WARN，尽量用具体类型 / `Record<string, Object>`。
- `fs.copyFileSync(srcFd, destUriString)` —— 把 `file://` URI **当字符串**传给 copy 在 OpenHarmony 被拒。改为先 `fs.openSync(destUri, WRITE_ONLY|CREATE|TRUNC)` 取 fd，再 `fs.copyFileSync(srcFd, dstFd)`（fd→fd 拷贝）。

### 21.4 真机诊断：hilog 环形缓冲会被冲掉，改用落盘 trace

- 真机 `hilog -x` 缓冲小，导出 251MB 期间大量系统日志会把我们的 `[GamePouchPlugin]` 行冲掉，抓不到。
- **做法**：在 `exportFile` 各步骤把 `[时间戳] 步骤` 追加写进 `filesDir/export_cache/_export_trace.txt`，`hdc shell cat .../export_cache/_export_trace.txt` 直接读，绕过缓冲。
- 失败详情（异常+堆栈）同理落盘到 `export_cache/_export_error.txt`，由 `library_page.dart` 的 catch 写入。
- 临时包（成功分支才删）保留在 `export_cache/` 可 `hdc file recv` 拉回本地用 `python -c "import zipfile; zipfile.ZipFile(...).testzip()"` 验证 CRC，确认中文名无乱码、零损坏。

---

## 22. PC 端「我的电脑」伙伴服务启动（自托管同步，2026-11-01）

手机「发现伙伴 / 我的电脑」能把本地库拉进 App，靠的是局域网里一台**伙伴服务端**。PC 这端用纯 Python 实现（`tools/library/peer_host.py`），无需 GUI、无需 Flask，标准库即可跑；mDNS 广播（让手机在 AP 隔离 / 广播被过滤时也能发现）是可选依赖 `zeroconf`。与 `app/lib/data/peer/*.dart` 协议严格对齐（设计见 `docs/design-account-cloud-ads-membership.md`）。

### 22.1 启动命令

```powershell
cd D:\ai\prj\trae\HuaWei\RetroEmuPouch
# 最简：用仓库内置测试库 .tools/gstest
python tools/library/run_peer_server.py

# 用你自己的库（根目录下要有 roms/ chats/ bios/）
python tools/library/run_peer_server.py --root "D:\你的库路径" --name "客厅电脑"

# 关掉 mDNS，只走 UDP 43801 广播发现
python tools/library/run_peer_server.py --no-mdns
```

- 启动后：绑定 **UDP 43801** 应答发现广播；起 **HTTP 服务**（端口自动分配，控制台打印 `服务地址: http://<PC的IP>:<端口>`，PONG 里带 `httpPort`）；日志同时写 `tools/library/peer_server.log`。
- **自动确认**收到的配对请求（联调用，省得在 PC 上点确认）。`Ctrl+C` 停止。
- 依赖：仅 Python 3 + 标准库。mDNS 广播才需要 `pip install zeroconf`（没装会自动降级为仅 UDP 发现，不影响现有功能）。

### 22.1.1 一键启动（start_peer.bat）

仓库根目录已提供 `start_peer.bat`，**双击即可启动**：另开一个「GamePouch 伙伴服务」窗口常驻服务、本窗口立即返回；日志仍写 `tools/library/peer_server.log`。`start_peer.bat` 的参数会原样透传给 `run_peer_server.py`：

```powershell
# 双击 start_peer.bat 即用内置测试库；命令行也可带参：
start_peer.bat --root "D:\你的库路径" --name "客厅电脑"
start_peer.bat --no-mdns
```

- 停止：关闭「GamePouch 伙伴服务」窗口，或在该窗口按 `Ctrl+C`。
- 把 `start_peer.bat` 放在仓库根目录（`RetroEmuPouch\`）下双击才有效；脚本会先校验 `tools\library\run_peer_server.py` 是否存在。

### 22.2 手机端连法

1. **PC 与手机连同一 Wi-Fi**。
2. App：**我的 → 发现伙伴**（或「我的电脑」区块）→ 看到 PC（名默认 `GamePouch 库管理(PC)`，或 `--name` 设的名字）。
3. 点**配对**（PC 自动确认，秒过）→ 点**导入**库。

### 22.3 常见坑

- **Windows 防火墙**：放行 Python 入站（UDP 43801 + 那个 HTTP 端口），否则手机发现不了也连不上。
- **发现不到**：先查防火墙 / 是否同一网段（AP 隔离会让广播失效 → 装 `zeroconf` 走 mDNS 通常能救）；再看控制台和 `peer_server.log` 的 `服务地址` 行。
- PC 端能起、控制台打印出 `服务地址` 即视为服务正常；真机「发现伙伴」这一步需手机实际连上同一 Wi-Fi 后验证。


