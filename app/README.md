# gamepouch — 趣玩匣 GamePouch Android App

Flutter + Kotlin + NDK 多平台复古游戏模拟器手机端（应用显示名「趣玩匣」）。

- Dart package：`gamepouch`
- Android applicationId / namespace：`com.retroemupouch.app`
- Kotlin 源码：`android/app/src/main/kotlin/com/gamepouch/app/`
- JNI：原生侧导出符号统一为 `Java_com_gamepouch_app_NativeBridge_*`（见 `src/main/cpp/jni_bridge.cpp`），改名时包名与 JNI 前缀必须同步
- 云服务：局域网发现标识 `GamePouch Cloud`、magic `GP-PING`/`GP-PONG`（UDP 43801），HTTP 默认 8848；常量与 PC 端 `tools/library` 必须一致
- 服务器换 IP 免手工改地址：PC 端 DHCP 换网段/换 Wi-Fi 后，App 请求遇传输层失败会自动重新 UDP+TCP 探测（30s 冷却、并发共享同一次探测），成功后保留登录态并重放原请求；账号页另有「重新探测服务器」手动入口（force，绕冷却）。OTA 下载链接的主机随 check 请求实际走通的 baseUrl 归一，忽略服务端宣告中的过期主机

## 构建

```powershell
# 仓库根目录先注入工具链（JDK / Android SDK / Flutter）
. ..\scripts\use-env.ps1
flutter pub get
flutter build apk --debug --target-platform android-arm64     # 调试
flutter build apk --release                                   # 发版（OTA 必须 release）
```

产物：`build/app/outputs/flutter-apk/app-<debug|release>.apk`（arm64-v8a 单 ABI）。

街机核心 `libgs_fbalpha2012.so` 为预构建产物，需放在
`android/app/src/main/jniLibs/arm64-v8a/`（不入 git）；其余核心由
`scripts/sync-cores.ps1` 拉取源码后经 CMake 构建。
