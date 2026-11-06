# 第三方开源 / 自由素材清单与合规说明（RetroEmuPouch 软著 & 上架用）

> 生成日期：2026-11-06　｜　适用：软件著作权登记鉴别材料、功能演示、上架法务审阅
> **本清单仅收录作者明确允许再分发且允许商业使用的作品**（CC0 / CC-BY / MIT / Zlib / BSD 类 / GPL）。
> **明确不适用**：这些素材**不打入 App 安装包 / HAP / APK，不随产品分发**，仅作本地演示与授权留痕。

## 0. 目录约定与隔离管控（本项目特别说明）

本项目 `/.tools/` 是指向 `GamePouch/.tools` 的 **Junction（共享目录）**，因此刻意**不**复用其中的 `freeroms/`，
避免与另一项目共享、无法独立管控。本项目采用**独立集中目录**：

| 目录 | 内容 | 是否入库 | 说明 |
|---|---|---|---|
| `freeroms/nes`、`freeroms/gba`、`freeroms/bios` | 素材本体 **17 项**（已逐一校验格式、字节数与 SHA256） | **否** | 由 `.gitignore` 的 `/freeroms/` 排除；不入库、不进包、可整体删除隔离 |
| `freeroms/_licenses/` | 18 份许可证原文 | **否** | 同上 |
| `docs/freeroms/` | `NOTICE.md` + `manifest.json` + `SHA256SUMS.txt` + `licenses/` | **是** | 审阅/留痕用，随仓库入库 |

隔离管控要点：
1. 二进制本体**全部集中在单一目录 `freeroms/`**，与源码、软著材料、App 资产物理分离；
2. `.gitignore` 一行 `/freeroms/` 即可保证任何 `git add -A` 都不会误提交二进制；
3. 构建脚本/打包流程只需排除 `freeroms/`，即可保证不进入 HAP/APK；
4. 需要彻底移除时删除该目录即可，不影响工程其余部分；
5. 复现方式：`py scripts/import_freeroms.py`（从来源项目复制并校验 SHA256），或按 `manifest.json` 的 `source` 链接自行下载后用 `SHA256SUMS.txt` 核验。

## 1. 选型原则

1. 只收录**作者明确允许再分发**且**允许商业使用**的作品。
2. 每项记录：作品名、作者、许可证、上游仓库、SHA256、字节数、获取日期（见 `manifest.json`）。
3. 每项许可证原文置于 `licenses/`，作为对外交付时的授权凭证。
4. 商业游戏 ROM / 街机 dump / 授权不明的改版 ROM **一律不进本清单**（见第 4 节）。

## 2. 收录清单（17 项，许可明确、允许商用再分发）

### 2.1 NES（12）

| 文件 | 作品 | 作者 | 许可 | 可商用 | 署名/义务 |
|---|---|---|---|---|---|
| `nes/anxiety-32kb.nes` | Adventures with Anxiety (NES 移植) | Nickey Case / Nikowoo | CC0-1.0 | 是 | 无（建议致谢） |
| `nes/cybercoaster.nes` | Cybercoaster | Fizzer & noby | CC-BY-4.0 | 是 | 必须署名 |
| `nes/falling.nes` | Falling | xram64 | MIT | 是 | 必须署名 |
| `nes/table_tennis_v1.0.nes` | 8bit Table Tennis | mike42 | MIT | 是 | 必须署名 |
| `nes/famidash.nes` | FamiDash | tfdsoft | MIT | 是 | 必须署名 |
| `nes/ruder.nes` | Zap Ruder | Damian Yerrick (pinobatch) | Zlib | 是 | 保留版权声明 |
| `nes/rhde.nes` | RHDE: Furniture Fight | Damian Yerrick (pinobatch) | BSD 类（homebrew-db 标注 FSFAP） | 是 | 保留版权声明 |
| `nes/croom.nes` | Concentration Room | Damian Yerrick (pinobatch) | GPL-3.0-or-later | 是 | 附 GPL 全文 + 源码链接 |
| `nes/thwaite128.nes` | Thwaite | Damian Yerrick (pinobatch) | GPL-3.0-or-later | 是 | 附 GPL 全文 + 源码链接 |
| `nes/cocobattleroyale221106.nes` | Coco Battle Royale II | psywave-games | GPL-3.0 | 是 | 附 GPL 全文 + 源码链接 |
| `nes/kokobatoru221106.nes` | Kokobatoru 2 | psywave-games | GPL-3.0 | 是 | 附 GPL 全文 + 源码链接 |
| `nes/240pee.nes` | 240p Test Suite | Damian Yerrick (pinobatch) | GPL-2.0-or-later | 是 | 附 GPL 全文 + 源码链接 |

### 2.2 GBA（3）

| 文件 | 作品 | 作者 | 许可 | 可商用 | 署名/义务 |
|---|---|---|---|---|---|
| `gba/minicraft.gba` | Minicraft for GBA | Vulcalien | GPL-3.0 | 是 | 附 GPL 全文 + 源码链接 |
| `gba/Google-Dino-Advance.gba` | Google Dino for GBA | fritzem | MIT | 是 | 必须署名（另含 Chromium 第三方声明） |
| `gba/doom2d.0.2.0-d2265bc.gba` | Doom2D for GBA | neparij | GPL-3.0 | 是 | 附 GPL 全文 + 源码链接 |

### 2.3 街机 BIOS 开源替代（1 组 / 2 个文件）

| 文件 | 说明 | 作者 | 许可 | 可商用 |
|---|---|---|---|---|
| `bios/privabios-0.1.0-beta.3.rom` | Sprix BIOS：从零实现的 Neo Geo MVS 开源 BIOS（含软 DIP / 作弊码 / 内存卡管理） | lid-labs | GPL-3.0 | 是（附 GPL 全文 + 源码链接） |
| `bios/privabios-0.1.0-beta.3-byteswapped.bin` | 同上，作者提供的字节序交换版本 | lid-labs | GPL-3.0 | 是 |

上游声明：**未复制或反汇编任何 SNK / UniBIOS 代码**，属洁净室实现，GPL-3.0 授权链条清晰。

### 2.4 PrivaBIOS 接入 MAME 的方法（上游 README 要点）

1. `privabios-0.1.0-beta.3.rom` 为 128 KiB、MAME 字节序的 Neo Geo MVS BIOS，对应 `neogeo.zip` 中 `sp-s2.sp1` 的位置。
2. 放入 `neogeo.zip` **替换 `sp-s2.sp1`**；若使用非合并（non-merged）游戏包，**每个游戏 zip 内部的 `sp-s2.sp1` 也必须一并替换**，否则 MAME 仍优先读取原版 BIOS。
3. MAME 报 `WRONG CHECKSUMS` 属正常，说明 PrivaBIOS 已被真正启用。
4. 上游实测 164 个 MAME 集合中 162 个可运行（基于 MAME 画面，非真机验证）；本项目另做真机验证，结论见 `docs/freeroms/VALIDATION.md`。
5. 该 BIOS 仅用于**本地兼容性验证**，不随产品分发。

### 2.5 CPS1 QSound 的合规结论

MAME 源码自带 **CPS1 QSound 的 HLE 实现**（GPL-2.0+），运行时**不需要** `dl-1425.bin` 这份受版权保护的音频 ROM。
因此 `qsound.zip` / `qsound_hle.zip`（内含同一份 Capcom `dl-1425.bin`，MD5 `108b113a596e800a02fece73f784eeb0`）
对本项目没有授权基础，应从商用链路彻底移除；移除后 CPS1 仍应可运行，验证结论见 `docs/freeroms/VALIDATION.md`。

## 3. 使用与署名清单（对外交付时随附）

1. MIT / CC-BY / BSD 类：交付材料注明「作品名 — 作者 — 许可证」，并附 `licenses/` 中对应文本。
2. GPL-3.0 / GPL-2.0：除附 GPL 全文外，给出上游源码仓库地址（`manifest.json` 的 `source` 已记录）。
3. CC0-1.0：无强制义务，建议在致谢中列出作者。
4. 演示 / 录屏：画面若出现上述作品，在片尾或说明页展示本 NOTICE。
5. **软著鉴别材料**：以**自有界面截图**（文件库、设置、个性化、手柄布局、使用教程、关于页）为主图；
   第三方游戏画面仅作辅助示意并单独注明来源与授权。本项目当前提交的用户操作手册**未使用任何第三方游戏画面**。

## 4. 明确排除（不引入本项目 / 不用于演示 / 不进软著 / 不进任何交付）

- **UniBIOS 15 个文件**（`uni-bios_1_0` ~ `uni-bios_4_0`）：免费软件但**授权文本未取得**，仅来源项目本地测试，本项目不引入、不分发。
- **`minicraft-gba_2.0.zip`**：`license=unknown`，授权无法核验，不引入。
- **全部商业 / 街机 ROM dump**（来源项目 `.tools/gstest/roms/**`，NES 106 + GBA 309 + NeoGeo 154 + CPS1 29 + CPS2 36 等）：著作权归各权利人，不可商用、不可再分发。
- **`qsound.zip` / `qsound_hle.zip`**：内含 Capcom `dl-1425.bin`，受版权保护；MAME HLE 无需该 ROM。
- **`pgm.zip`**（IGS PGM）、**`neogeo.zip` 中的 SNK 官方 BIOS**（`sp-s2.sp1` / `sp1-u4` / `sm1.sp1` / `sfix.sfix` 等）：受版权保护，不可整包分发。
- **MAME 官网「ROMs for Free Download」**（Gridlee / Alien Arena / Exidy 系列等）：官方明文「仅获准在 MAME 官网分发」，不得再分发，故不收录。
- **Micro Mages**（官网下线，条款取不到）、**Alter Ego / Shiru**（站点不可访问，第三方仓库与商业 ROM 混放）：授权无法核验，不收录。
- **中文改版 / HACK ROM**（如「by 小粽子」「BY 疾风之狼」等）：玩家个人改编，授权状态不明，不可商用。

## 5. 校验与复现

- `manifest.json`：17 项的路径、作者、许可证、上游仓库、字节数、SHA256、获取日期，以及排除项说明。
- `SHA256SUMS.txt`：可直接用 `sha256sum -c` 或 PowerShell `Get-FileHash` 核验。
- 复现命令：

```powershell
py scripts/import_freeroms.py
Get-Content freeroms\SHA256SUMS.txt
(Get-FileHash -Algorithm SHA256 freeroms\nes\240pee.nes).Hash
```

## 6. 与软著/上架材料的关系

- 本项目《源程序鉴别材料》采样范围已排除 `third_party/` 第三方内核与 `freeroms/` 素材本体。
- 《用户操作手册》使用的 5 张截图均为**自有 UI 真机截图**，不含任何游戏 ROM 名称、画面或 BIOS 内容。
- 关于页内置声明「本应用不内置任何游戏 ROM 或 BIOS，请自行导入合法副本」，与本清单口径一致。
