# 街机链路兼容性验证记录

> 日期：2026-11-06
> 设备 A：HarmonyOS Pura70（SN `2MN0224730027764`，`hdc` 联调，签名 debug HAP，bundle `com.retroemupouch.app`）
> 设备 B：Android Honor OXF-AN10（SN `66B0219C18003002`，`adb` + `run-as` + `EmulatorActivity` bench，
> store debug APK，含 `libgs_mame.so`）
> 构建/联调链路严格按 `docs/skills.md` §2.6 / §3 / §4 / §6 / §1377。
>
> 本文件只记录**本地兼容性验证**。所用商业街机 ROM 与官方 BIOS 仅存在于设备私有目录，
> 按 `NOTICE.md` §4 明确排除，不进入仓库、安装包、演示或软著鉴别材料。
> 所有生成的测试 zip、控制文件都在 `build/bios_probe/`（`**/build/` 被 `.gitignore` 排除）；
> 10 份真机原始报告另已归档到 `docs/freeroms/evidence/` 随仓库留存，便于审计复现。

## 复现方式

```powershell
# 1) 生成测试用 neogeo.zip（PrivaBIOS 替换 sp-s2.sp1）与 A/B 场景
python scripts\ohos\prepare-bios-probe.py

# 2) Pura70：逐场景「构建带探针 HAP → hdc install -r → 冷启动 → 读报告」
.\scripts\ohos\run-bios-probe.ps1 -Scenario A-baseline
.\scripts\ohos\run-bios-probe.ps1 -Scenario B-no-qsound
.\scripts\ohos\run-bios-probe.ps1 -Scenario C-no-qsound-ffight
.\scripts\ohos\run-bios-probe.ps1 -Scenario D-no-qsound-1944
.\scripts\ohos\run-bios-probe.ps1 -Scenario F-restore          # 还原设备 BIOS
.\scripts\ohos\run-bios-probe.ps1 -Scenario G-no-qsound-hle
.\scripts\ohos\run-bios-probe.ps1 -Scenario F-restore          # 再次还原
.\scripts\ohos\run-bios-probe.ps1 -Scenario H-priva-baseline-ohos  # OHOS 原版 BIOS 基线
.\scripts\ohos\run-bios-probe.ps1 -Scenario E-privabios-ohos        # OHOS PrivaBIOS
.\scripts\ohos\run-bios-probe.ps1 -Scenario F-restore          # 还原

# 3) Android OXF：原版 BIOS 基线 + PrivaBIOS 对照（自动备份/还原）
.\scripts\mame\verify-privabios.ps1 -UseOriginalBios
.\scripts\mame\verify-privabios.ps1
```

> **真机坑**：`aa start` 在屏幕锁定时返回 `10106102 The device screen is locked …
> unlock screen failed`（开发者模式不允许自动解锁），且输出被吞后会静默读到上一轮
> `bios_probe.txt` 造成误判。`run-bios-probe.ps1` 已在每次冷启动前
> `uitest uiInput swipe 600 2200 600 500 600` 解锁，并检查 `aa start` 输出与报告的
> `cmd=` 是否与本场景一致，不一致直接报错。

鸿蒙探针说明：`hdc file send` / `cat >` 无法写 App 沙盒，且 Flutter 进程看不到
`/data/local/tmp`（`Directory('/data/local/tmp').existsSync() == false`，SELinux），
因此场景经 `--dart-define=GP_BIOS_CMD=...` 编进 HAP，由 App 自己在沙盒内完成可还原的文件变更；
`GamePouchPlugin` 的 `gs/emulator` 通道暴露只读 NAPI `getLoadError` / `isCoreReady` / `getFps`，
报告写入 `<filesDir>/bios_probe.txt`，用
`hdc shell -b com.retroemupouch.app cat /data/app/el2/100/base/com.retroemupouch.app/files/bios_probe.txt` 读取。
`backup` 生成 `.gpbak`，`drop` 改名为 `.gpoff`，`restore` 场景完整还原。

## 验证项 A：移除 `qsound.zip` / `qsound_hle.zip` 后 CPS1 是否仍可运行（MAME HLE）

**结论：否。原「MAME 走 HLE 不需要 `dl-1425.bin`」的前提不成立，不能整体移除。**
但两份 zip 内容完全相同，其中 `qsound_hle.zip` 是冗余副本，已验证可安全移除。

### Pura70 真机 A/B（原始报告已归档在 `docs/freeroms/evidence/*.txt`）

| 场景 | 设备 BIOS 状态 | ROM / 机型 | `getLoadError` | `isCoreReady` | `getFps` | 结果 |
|---|---|---|---|---|---|---|
| A-baseline | qsound + qsound_hle 齐全 | `dino.zip` / CPS1 QSound | `""` | true | 60.39 | 通过 |
| B-no-qsound | 6 个 rompath 中的两份 qsound 全部移除 | `dino.zip` / CPS1 QSound | `{"reason":"load_game","missing":["dl-1425.bin"],"detail":"… dl-1425.bin NOT FOUND (tried in qsound_hle qsound dino) \| Fatal error: Required files are missing, the machine cannot be run."}` | false | 0 | **失败** |
| C-no-qsound-ffight | 同上 | `ffight.zip` / CPS1 无 QSound 硬件 | `""` | true | 60.75 | 通过（对照） |
| D-no-qsound-1944 | 同上 | `1944.zip` / CPS2 QSound | `{"reason":"load_game","missing":["dl-1425.bin"],"detail":"… dl-1425.bin NOT FOUND (tried in qsound_hle qsound 1944) …"}` | false | 0 | **失败** |
| G-no-qsound-hle | 保留 `qsound.zip`，仅移除 `qsound_hle.zip` | `dino.zip` / CPS1 QSound | `""` | true | 59.99 | 通过 |

> B/C 的差别说明依赖是**按机型**的：不带 QSound 硬件的 CPS1 游戏不需要该 ROM，
> 而 CPS1/CPS2 的 QSound 机型必须由用户提供 `qsound.zip`。

### 静态源码佐证（与真机一致）

- `build/mame-src/src/devices/sound/qsoundhle.cpp:44-49`：`ROM_START(qsound_hle)` 中
  `ROM_LOAD16_WORD("dl-1425.bin", 0x0000, 0x2000, CRC(d6cf5ef5) …)` 无 `OPTIONAL`；
  `qsound_hle_device::parent_rom_device_type()` 返回 `&QSOUND`。
- `build/mame-src/src/mame/capcom/cps1.cpp:3986-4015`：`cps_state::qsound()` 使用 `QSOUND(config, m_qsound)`；
  `GAME(1993, dino, …)` 指定 `qsound` machine config。
- 已构建的 `cores/ohos/build/libgs_mame.so` 与 Android `libgs_mame.so` 内均可检索到 `dl-1425.bin` 字符串。
- `qsound.zip` 与 `qsound_hle.zip` 均为 2676 字节，内含同一份 24576 字节 `dl-1425.bin`
  （MD5 `108b113a596e800a02fece73f784eeb0`），故 MAME 经父 ROM 集 `qsound` 即可命中。

### 据此实施的项目改动

1. `SystemFiles.supportedBios` / `requiredBios['mame']`、`LockedRom.ARCADE_BIOS_NAMES`、
   `gpretro.cpp kBios[]` 四处 lockstep 删除 `qsound_hle.zip`；
   两端错误提示（`settings_sheet.dart`、`EmulatorSpike.ets`、`EmulatorActivity.kt`）同步。
2. 保留 `qsound.zip` **作为用户自行导入的 BIOS 文件名**。其二进制从未进入仓库（本地素材在
   `/.tools/`，被 `.gitignore` 排除）或安装包（`check-apk-content.ps1` / `check-hap-content.ps1` 硬校验）。
3. `NOTICE.md` §2.5 / §4 中原先「MAME HLE 无需该 ROM」的错误表述已按上述证据修正。
4. 已按用户要求从工作区**删除两份本地 BIOS 本体** `.tools/gstest/bios/qsound.zip` 与
   `.tools/gstest/bios/qsound_hle.zip`。`.tools` 是指向 GamePouch 的 Junction，删除同时作用于
   两个项目的本地测试素材；该目录被 `/.tools/` 排除，两份文件从来**不在仓库、不在安装包**。
   `scripts/mame/refresh-roms.ps1` 已改为「本地没有用户自备的 `qsound.zip` 时跳过部署并记日志」，
   不再硬失败。因此工作区内已不存在任何 `dl-1425.bin` 字节；`qsound.zip` 在产品里只剩一个
   「用户自行导入」的 BIOS 文件名，需要本地回归 QSound 机型时由测试者自行提供合法副本。

## 验证项 B：PrivaBIOS 替换 `neogeo.zip` 内 `sp-s2.sp1` 后街机游戏是否可运行

**结论：通过。** 在 Android OXF-AN10 真机上，`kof97.zip` 以约 56.6 FPS 正常跑完 3 秒 bench。

### 方法

- `scripts/ohos/prepare-bios-probe.py` 从用户本地 `neogeo.zip`（1,859,335 字节）复制全部成员，
  仅把默认 BIOS（MAME `ROM_SYSTEM_BIOS(0, "euro", …)` = `sp-s2.sp1`）替换为
  `freeroms/bios/privabios-0.1.0-beta.3.rom`（131072 字节，MAME 字节序，已与原始 `sp-s2.sp1`
  头部及 `-byteswapped.bin` 交叉核对）。生成 `build/bios_probe/neogeo_privabios.zip`
  （1,876,963 字节，SHA256 `40079c976ace506f9470acce207ec8d3a2bde68fca92275f661b25348f33922f`）。
- `kof97.zip` 为 split 集（13 个成员，内部不含任何 BIOS 文件），故只需替换 `neogeo.zip`，
  不存在「非合并包内还要逐包替换 `sp-s2.sp1`」的情况。
- `scripts/mame/verify-privabios.ps1` 按 `skills.md` §6 先 `adb push` 到 `/data/local/tmp`，
  再 `run-as com.retroemupouch.app cp` 到 `files/system/neogeo.zip`、
  `files/system/mame/roms/neogeo.zip`、`files/rom_cache/mame/neogeo.zip` 三个 rompath，
  然后 `am start -n …/.EmulatorActivity --es bench_rom roms/peer/kof97.zip --es bench_core mame
  --ei bench_seconds 3 --es bench_id privabios_kof97`，最后自动从 `.gpbak` 还原。
- 前置：设备原装的 community debug APK 不含 `libgs_mame.so`，已 `adb install -r`
  `app/build/app/outputs/flutter-apk/app-store-debug.apk`（含 81,595,024 字节 `libgs_mame.so`）。

### 结果（原始报告已归档在 `docs/freeroms/evidence/*.txt`）

| 场景 | BIOS | bench 结果 | 关键核心日志 |
|---|---|---|---|
| baseline-android | 设备原版 `neogeo.zip` | **PASS** 250f / 4.285s / 58.35 fps | 无校验告警 |
| priva-android | PrivaBIOS 替换 `sp-s2.sp1` | **PASS** 250f / 4.419s / 56.57 fps | `[core] sp-s2.sp1 WRONG CHECKSUMS:` |

`WRONG CHECKSUMS` 正是 PrivaBIOS 被真正加载的预期信号（上游 README 已说明），
帧率与基线基本一致，未出现 `NOT FOUND` / `GS-CORE-FAIL`。测试结束后原版 BIOS 已还原。

### 合规边界

- 测试 zip 只在 `build/`（gitignored）和测试设备私有目录，**未进仓库、未进 APK/HAP、未用于软著材料**。
- PrivaBIOS 本体（GPL-3.0）在 `freeroms/bios/`（不入库），授权原文在 `docs/freeroms/licenses/`。
- 该 BIOS 只用于本地兼容性验证，不随产品分发；产品仍要求用户自行导入合法 BIOS。

## 验证项 C：PrivaBIOS 在鸿蒙（OHOS / Pura70）版本是否可用

**结论：可用。** 同一 libretro MAME 核心在鸿蒙侧与 Android 侧表现一致：
`kof97.zip` 正常启动（约 60 fps），核心日志出现 `sp-s2.sp1 WRONG CHECKSUMS`。
即「鸿蒙版本能不能用」答案是**能**，且不需要为 PrivaBIOS 额外导入别的 BIOS。

⚠️ 但这里**不是**「有了 PrivaBIOS 就不需要 `neogeo.zip`」：PrivaBIOS 只替换
`neogeo.zip` 里 `sp-s2.sp1` 一个成员，`sm1.sm1` / `000-lo.lo` / `sfix.sfix`
仍是必需且无开源替代（详见 `NOTICE.md` §2.4.1）。两轮验证都是把 PrivaBIOS
**打进** `neogeo.zip`，而不是删掉该包。

### 为什么需要单独验证

鸿蒙侧的 BIOS 分发链路与 Android 不同：`gpretro.cpp` 的 `StageArcadeContent()`
以 `system/<name>.zip` 为源，按 **size + CRC32** 刷新到
`system/mame/roms/` 和 `rom_cache/mame/` 两处 rompath。因此只要替换源头
`system/neogeo.zip`，启动时另两处会自动同步；PrivaBIOS 与 QSound 去重后的
`kBios[] = {neogeo.zip, qsound.zip, pgm.zip}` 也不冲突。

难点在于把测试 BIOS 送进沙盒：`hdc file send` 与 `hdc shell -b … cat >` 对
`/data/storage/el2/base/files/` 和物理路径 `/data/app/el2/100/base/…/files/`
都报 `Permission denied`，而 Flutter/Dart 进程看不到 `/data/local/tmp`
（`tmp.exists=false`，SELinux）。Android 的 `run-as` 在鸿蒙没有对应物。

### 采用的做法（合规优先）

`scripts/ohos/prepare-bios-probe.py` 只把 **128 KB 的 GPL-3.0 PrivaBIOS 本体**
复制到 `app/assets/probe/privabios.rom`（gitignored，构建完立即删除）。
`app/lib/probe/arcade_bios_probe.dart` 在 `priva=1` 场景里：

1. 用 `package:archive` 解码设备上用户自己的 `system/neogeo.zip.gpbak`（34 个成员）；
2. 仅把 `sp-s2.sp1`（131072 字节）替换成 asset 里的 PrivaBIOS，其余成员原样保留；
3. 重新编码并写回三个 rompath（`system/`、`system/mame/roms/`、`rom_cache/mame/`）；
4. 经正常 PAL 路径启动 `kof97.zip`，读取核心自己的诊断。

**因此 probe HAP 里没有任何受版权保护的 SNK BIOS 字节**——只有开源 PrivaBIOS；
正式 HAP 连这个 asset 也没有（`app/assets/probe/` 只提交 `.gitkeep`）。
为取证新增了只读 NAPI `getBiosWarnings`（`gpretro.cpp` 单独累积
`WRONG CHECKSUMS` / `WRONG LENGTH` / `NEEDS REDUMP`，避免被 24 行日志 tail 冲掉），
经 `GamePouchPlugin` 的 `gs/emulator` 通道暴露给探针。

### 结果（`docs/freeroms/evidence/*.txt`）

| 场景 | `system/neogeo.zip` | `getLoadError` | `isCoreReady` | `getFps` | `getBiosWarnings` | 结果 |
|---|---|---|---|---|---|---|
| H-priva-baseline-ohos | 1,859,335 B（原版） | `""` | true | 59.79 | `""` | 通过 |
| E-privabios-ohos | 1,991,765 B（重建） | `""` | true | 60.20 | `sp-s2.sp1 WRONG CHECKSUMS:` | **通过** |

E 场景报告关键行：`priva.asset.bytes=131072`、
`priva.sp-s2.sp1 oldBytes=131072 newBytes=131072 members=34`、
`priva.write system/neogeo.zip 1991765` 等三处写入。
`WRONG CHECKSUMS` 与 Android 侧 `priva-android` 完全一致，证明替换 BIOS 确实被加载，
而非误用了残留的原版副本。F-restore 已把三处全部还原为 1,859,335 字节原版。
