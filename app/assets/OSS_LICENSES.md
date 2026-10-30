# 开源软件许可（Open Source Notices）

本应用内嵌以下开源模拟器核心。NES / GB / GBA / MD / Atari 等核心源码随项目仓库
`third_party/` 目录提供；MAME 等大体量街机核心以对应的上游仓库 commit 形式见下方
「街机核心」章节（未随仓库打包完整源码）。上游仓库见各条目。请遵守对应许可证。

| 组件 | 用途 | 许可证 | 版本（commit） | 源码位置 |
| --- | --- | --- | --- | --- |
| FCEUmm（libretro-fceumm） | NES / FC | GPL-2.0-or-later | `7a542dab1e87679921962a9f056186eca425c0c2` | `third_party/fceumm` · github.com/libretro/libretro-fceumm |
| Gambatte（libretro-gambatte） | GB / GBC | GPL-2.0-or-later | `d9d6cd06382d1ced30de34d56d3609452323dab1` | `third_party/gambatte` · github.com/libretro/gambatte-libretro |
| mGBA（libretro-mgba） | GBA | MPL-2.0 | `7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6` | `third_party/mgba` · github.com/libretro/mgba |
| PicoDrive（libretro-picodrive） | MD / Genesis / SMS | MIT（含部分 GPL-2.0 组件） | `1890c2932234c9d30f4cd3851d02228baae8f09e` | `third_party/picodrive` · github.com/libretro/picodrive |
| Stella2014（libretro-stella2014） | Atari 2600 | GPL-2.0-or-later | `7d1361e407e63f29e52892655069e5fb4096e691` | `third_party/stella2014` · github.com/libretro/stella2014-libretro |

## 街机核心

街机（NeoGeo / CPS1 / CPS2）核心分两类：**FBA-2012**（`libgs_fbalpha2012.so`）**仅随
`community` 渠道分发**（许可禁止商用，商店渠道不包含）；**MAME**（`libgs_mame.so`）为
**商店渠道街机核心**（采用 BSD-3-Clause 分支，可商用）。

| 组件 | 许可证 | 可否商用 | 说明 |
| --- | --- | --- | --- |
| FBA-2012（预编译 `libgs_fbalpha2012.so`） | FB Alpha / FinalBurn Neo 许可 | **否** | 许可明确禁止用于商业产品与商业活动（含带广告或内购的免费应用）。仅在 `community`（自签分发）版本提供。 |
| MAME（**商店渠道街机核心**，libretro 封装） | **BSD-3-Clause + GPL-2.0-or-later 双许可**（0.197 起） | **是** | 0.172 起改为 GPL-2.0-or-later，0.197 起增加 BSD-3-Clause 选项；走 BSD 分支仅需保留版权声明。源码（对应本构建）：github.com/libretro/mame @ `5f5a07748ce5c239c4118463ce8e6473743d4859`（master；上游 github.com/mamedev/mame）。由 `scripts/build-mame.ps1` 以 `platform=android-arm64` 构建，构建 ref 由脚本 `-Ref` 参数决定并记录于上方 commit。 |

> 说明：MAME 0.172–0.196 仅 GPL-2.0-or-later（可商用但须提供对应源码）；
> 0.197 起可选择 BSD-3-Clause。libretro 的 mame2000 / mame2003 / mame2010 /
> mame2015 等老核心沿用**旧版 MAME 非商业许可**，同样不可商用。

## 说明

- FCEUmm / Gambatte / Stella2014 采用 **GPL-2.0-or-later**；mGBA 采用 **MPL-2.0**；
  PicoDrive 主体为 **MIT**，但内嵌的 68000 / SH2 等模拟组件部分为 **GPL-2.0**。
  完整许可证文本见各目录下的 `Copying` / `COPYING` 文件。
- 本应用自身代码（Dart / Kotlin / C++ 脚手架）以 **MIT** 许可证发布，见仓库根
  `LICENSE`。
- 本应用与任何游戏机厂商、游戏发行商均无关联，亦未内置任何受版权保护的
  ROM / BIOS 文件。街机 BIOS（如 `neogeo.zip`）须由用户自备合法副本。

如需获取任一核心的对应源码，请联系开发者或访问上述上游仓库对应 commit。
