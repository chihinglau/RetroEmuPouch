# 趣玩匣 Android 端 UI 设计规范（1:1 复刻手册）

> 目标：让开发者**不打开 Android 源码**也能在 鸿蒙 ArkTS / iOS SwiftUI 等其它系统上，
> 逐像素、逐状态地复刻「趣玩匣」模拟器页与虚拟手柄的视觉与交互。
>
> 数据来源（全部为代码事实，行号可回溯）：
> - `app/android/app/src/main/kotlin/com/gamepouch/app/EmulatorActivity.kt`（2769 行）
> - `app/android/app/src/main/kotlin/com/gamepouch/app/VirtualPadView.kt`（1748 行）
> - `app/android/app/src/main/kotlin/com/gamepouch/app/SpecialMovesStore.kt`
> - `app/android/app/src/main/kotlin/com/gamepouch/app/CheatStore.kt`
> - `app/android/app/src/main/{AndroidManifest.xml, res/values/styles.xml, res/values-night/styles.xml}`
>
> 说明：本文档分两部分。**原生绘制部分**（模拟器页 EmulatorActivity + 虚拟手柄
> VirtualPadView + 顶部工具栏 + HUD + 原生对话框）见 §0–§14。**Flutter/Dart 应用层**
> （文件库 / 设置 / 账号云 / 伙伴联机 / 招式编辑 / 法律）见 §15，业务流（导入 / 备份恢复 /
> 更新 / 联机 / 设置持久化 / 原生桥）见 §16，业务测试验收清单见 §17。Flutter 代码跨端共用，
> 1:1 复刻时整段搬运即可。

---

## 0. 度量体系（复刻的换算根基）

Android 侧**不使用 dp**，也不使用固定 px：所有原生尺寸都是**屏幕百分比**，派生于三个函数
（`EmulatorActivity.kt` L73–87）：

```kotlin
class Sizing(wPx, hPx) {
    val w = wPx; val h = hPx
    val min = minOf(w, h)              // 短边
    fun wp(p) = (w   * p + 0.5).toInt() // 水平量（边距 / 间距 / 按钮宽）
    fun hp(p) = (h   * p + 0.5).toInt() // 垂直量（topMargin / 按钮高）
    fun sp(p) = (min * p + 0.5).toInt() // 控件本体尺寸（短边基准）
}
```

虚拟手柄侧使用同一套思想的两个量（`VirtualPadView.onSizeChanged` L589–628）：

| 量 | 定义 | 说明 |
|---|---|---|
| `ref` | `min(w, h)` | 短边像素，手柄的“基准尺” |
| `baseR` | `ref * 0.190 * padScale` | 摇杆底盘半径，所有手柄控件的基准半径 |
| `edgeGap` | `ref * 0.05` | 控件与屏幕边缘的安全间距基准 |

**换算速查（横屏，min = 短边）**

| 量 | 公式 | 2400×1080（min=1080） | 2844×1260（min=1260） |
|---|---|---|---|
| 手柄基准半径 `baseR` | `0.190·ref` | 205.2 px | 239.4 px |
| 圆形功能键半径 `faceR` | `0.50·baseR` | 102.6 px | 119.7 px |
| 药丸键 宽×高 | `1.42·baseR × 0.55·baseR` | 291×113 | 340×132 |
| 描边宽（常态/按下） | `0.0056·ref / 0.0072·ref` | 6 / 7.8 | 7 / 9.1 |
| 字号（手柄+工具栏） | `0.042·ref` | 45.4 px | 52.9 px |
| 按下内缩 `pressInset` | `0.0069·ref` | 7.5 px | 8.7 px |
| 药丸圆角 | `0.05·ref` | 54 px | 63 px |

> 设计基准注释（L822-827、L594-628）：这些百分比在参考机 **HBN-AL00 横屏 640×360dp**
> 上复刻了旧的 `36dp 图标 / 6dp 边距 / 4dp 间距 / 20dp 面板圆角 / 15dp 按钮圆角 /
> 52×32dp 按钮 / 1dp 描边 / 2dp 水平 padding`。
> 另一参考比例：`62dp / 360dp = 0.172`，现行 `0.190` 是用户要求“更大更好抓”后的取值。

---

## 1. 页面清单与层级关系

### 1.1 页面总览

| 页面 | 承载技术 | 方向 | 是否原生 UI |
|---|---|---|---|
| 启动 / 文件库 / 设置 / 金手指编辑 | Flutter（Dart，跨端共用） | 跟随系统 | 否 |
| **模拟器页 EmulatorActivity** | 原生 Kotlin | `sensorLandscape`（双向横屏） | **是（本文档主体）** |

- `MainActivity` = 纯 `FlutterActivity`，**零原生视图、零状态栏染色、零 EdgeToEdge**
  （`MainActivity.kt` L22，导入中无 `android.view.*`）。
- `AndroidManifest.xml`：
  - EmulatorActivity：`screenOrientation="sensorLandscape"`、`launchMode="singleTop"`、
    `hardwareAccelerated="true"`、`theme="@style/NormalTheme"`、
    `configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"`
  - 主题 `NormalTheme` 仅声明 `windowBackground`，父主题 `Theme.Light.NoTitleBar`
    （夜间 `Theme.Black.NoTitleBar`）。**没有** `statusBarColor` / `navigationBarColor` /
    `windowFullscreen` —— 状态栏与导航栏颜色完全交给系统默认。

### 1.2 模拟器页视图树（Z 序：后添加者在上）

```
FrameLayout root                       ← 背景纯黑 Color.BLACK（防首帧白闪）
├─ 1  GLSurfaceView glView             ← MATCH_PARENT，EGL 2，RENDERMODE_CONTINUOUSLY
├─ 2  TextView hud                     ← FPS/xruns 读数
├─ 3  VirtualPadView pad               ← MATCH_PARENT，半透明覆盖层（摇杆/十字键/功能键）
├─ 4  TextView npOverlay（仅联机）     ← MATCH_PARENT，居中遮罩
├─ 5  TextView npStat  （仅联机）      ← 顶部居中的联机统计
└─ 6  chrome：功能 pill / ✕ / 命令面板 ← 由 installChrome() 延迟添加，位于最上层
```

要点：
- chrome **不在 onCreate 中添加**，而是在 `root.addOnLayoutChangeListener` 拿到真实尺寸后
  `installChrome(w, h)`（L493–507、L536）；旋转/窗口变化时走 `onChromeSizeChanged`。
- HUD 位于 pad **之下**（先添加），因此手柄不会遮挡它，反之 HUD 也不会吃掉手柄的触摸。
- 原生对话框（金手指 / 读档 / 重开确认）位于 Activity 之上，由系统 AlertDialog 呈现。

### 1.3 画面区（stage）与 safe inset

- 画面由 GL 渲染，四边 safe inset 取自
  `statusBars() | navigationBars() | displayCutout()`（L470–491 → `renderer.setSystemInsets`）。
- `applySafeInsets`（L2345–2383）：
  - 横屏：`safeLeft/Right = max(核心 letterbox, sysInsetL/R)`，`safeTop/Bottom = sysInsetT/B`
  - 竖屏：`safeLeft/Right = sysInsetL/R`，`safeTop/Bottom = max(核心 letterbox, sysInsetT/B)`
- 手柄与工具栏是**半透明覆盖层**，不预留黑边（`LEFT_INSET_FRAC = 0f` 等，VirtualPadView L147–150）。
- 各平台核心宽高比（`coreDar`，L162–176）：
  NES `256/240×8/7 = 1.219`、GB `1.111`、GBA `1.500`、A2600/SMS/MD/MAME/NEOGEO `1.333`、GG `1.111`。
  核心实际上报的 aspect 优先于该常量。

---

## 2. 虚拟手柄（VirtualPadView）总体布局

横屏分区（所有坐标为**相对屏幕宽 w / 可用高 availH** 的比例，原点左上）：

```
┌──────────────────────────────────────────────────────────────────┐
│ 功能pill                                            菜单pill ✕  │ ← 顶部 chrome 行
│                         （画面区 4:3 居中）                       │
│                                                    SELECT pill   │ ← 右上立柱 0.92w
│                                                    START  pill   │
│                                                                  │
│   ◇ 十字键 / 摇杆                                       B        │ ← 0.85w, 0.79h
│   （0.13w, 0.66h）                                A              │ ← 0.93w, 0.71h
└──────────────────────────────────────────────────────────────────┘
```

- 左下：**摇杆**（默认 `stickMode = DPAD8`）或**十字键**（`useDpadUi = true` 时）。
- 右侧：圆形功能键（B/A 斜向排列）+ 药丸立柱（SELECT/START、L/R）。
- 街机 profile 额外在**右侧信箱黑边**内排布 6 键 / 4 键面板与「招式」面板。

### 2.1 通用视觉语言（所有手柄控件共用）

| 属性 | 常态 | 按下 / 激活 |
|---|---|---|
| 填充 | `#FFFFFF` @22%（`argb(56,255,255,255)`） | 琥珀 `#FFC907` @80%（`argb(205,255,193,7)`） |
| 描边 | `#FFFFFF` @59%（`argb(150,255,255,255)`），宽 `0.0056·ref` | `#FFEBAA` @96%（`argb(245,255,235,170)`），宽 `0.0072·ref` |
| 文字 | `#FFFFFF` | `#2D2000`（`rgb(45,32,0)`）+ 伪粗体 |
| 字号 | `0.042·ref` | 同 |
| 圆角 | 药丸：`0.05·ref`（> 半高 → 全圆头）；圆形：半径整除 | 同 |
| 按下反馈 | 控件整体**内缩** `pressInset = 0.0069·ref` 后重绘 | — |
| 抗锯齿 | 全部开启 | 同 |

> 摇杆另有两色：`knobPaint = argb(120,255,255,255)`（静止旋钮）、
> `knobStrokePaint = argb(190,255,255,255)`；方向提示箭头 `argb(105,255,255,255)`；
> 2P 加入提示底 `argb(150,20,20,24)`。

### 2.2 摇杆（StickMode，默认 DPAD8）

几何（`layoutStick` L700–736、`onSizeChanged` L626–628）：

| 项 | 公式 |
|---|---|
| 底盘半径 | `baseR = 0.190·ref·padScale` |
| 旋钮半径 | `knobR = 0.44·baseR` |
| 行程 | `travel = baseR − knobR` |
| 抓取半径（命中区） | `grabR = 1.35·baseR`（比可见盘大一圈，容错） |
| 圆心 X | 横屏 `0.13·w`，竖屏 `0.22·w` |
| 圆心 Y | `clamp(0.66·h, baseR+edgeGap, h − bottomInset − 0.06·ref − baseR − edgeGap)` |
| 死区 | `dz = travel × deadzone`（默认 `0.18`） |

绘制（`drawStick` / `drawStickBase` L1577–1638）：
1. 静止：底盘圆（填充+描边）+ 内圈 `0.62·baseR` 描边 + 中心旋钮圆（knob 填充+描边）+
   四个方向箭头（等边三角形，半宽 `0.13·baseR`、高 `0.17·baseR`，位于 `0.78·baseR` 处）。
2. 拖动：底盘保持在**固定圆心**（不跟随手指漂移，这是格斗指令可重复性的前提）+
   从圆心到旋钮画一条激活色连线 + 旋钮用激活填充/描边。

方向量化：
- `DPAD8`（默认）：`dx < −dz → ←`，`dx > dz → →`，`dy < −dz → ↑`，`dy > dz → ↓`（可组合成斜向）。
- `DPAD4`：按 45° 楔形吸附到最近基数方向（22.5/67.5/112.5/157.5 分界）。
- `STICK`：模拟量（仅供核心消费），量化规则同上但保留 8 向。

### 2.3 十字键（`useDpadUi = true`）

几何（`layoutDpad` L660–698，全部以 `baseR` 为单位）：

| 项 | 公式 | 说明 |
|---|---|---|
| 臂心距 `r` | `0.78·baseR` | **已发布包实测 ≈0.84·baseR，见 §12 注 1** |
| 臂圆半径 `buttonR` | `0.46·baseR` | |
| 十字条厚度 `armW` | `0.40·baseR` | |
| 触摸判定半径 `outerR` | `r + buttonR` | 一个整圆 |
| 中心死点 `deadR` | `0.045·baseR` | 防抖 |
| 滞回环 `holdR` | `0.18·(r + buttonR)` | 过中心时保持原方向 |

绘制（`drawDpad` L1709–1731，顺序固定）：
1. 竖向圆角矩形：宽 `armW`、高 `2r`，圆角 `armW/2`，**只填充不描边**；
2. 横向圆角矩形：宽 `2r`、高 `armW`，同上；
3. 四个臂圆：直径 `2·buttonR`，位于 `(cx, cy±r)`、`(cx±r, cy)`，标签 `↑ ↓ ← →`；
4. 中心盖：实心圆，半径 `armW/2`，填充 + 描边（表示“中间也是活的”）。

触摸判定（`hitDpad` L1693–1706，**不是**按四个矩形判）：

```
dist = hypot(dx, dy)
dist > outerR  → 无方向           （滑出盘外，释放）
dist < deadR   → 按下时无方向；移动时保持上一方向（↑→↓ 连滑不断）
否则：ang = atan2(dy, dx)
  [−45°, 45°) → →   [45°,135°) → ↓   [135°,180°]∪[−180°,−135°) → ←   其余 → ↑
移动且 dist < holdR 且已有方向 → 保持原方向（滞回）
```
设计意图注释（L683–697）：四象限楔形消除了旧方案的“45° 死区”和“中心大块死区”。

### 2.4 圆形功能键（A / B / C / 1 / 2 / FIRE…）

- 半径 `faceR = 0.50·baseR`，圆内居中显示标签。
- 位置（`buildButtons` L761–779）：

| 方向 | 键 | 圆心 |
|---|---|---|
| 横屏 | A | `(0.93·w, 0.71·availH)` |
| 横屏 | B | `(0.85·w, 0.79·availH)` |
| 竖屏 | A | `(0.82·w, 0.75·availH)` |
| 竖屏 | B | `(0.66·w, 0.85·availH)` |

- 按下时整体内缩 `pressInset` 后重绘（L1640–1648）。

### 2.5 药丸键（SELECT / START / L / R / PAUSE / RESET…）

尺寸：

| profile | 宽 | 高 |
|---|---|---|
| 通用 | `1.42·baseR` | `0.55·baseR` |
| GBA（SELECT/START） | `1.22·baseR` | `0.48·baseR` |

- 圆角 `0.05·ref`（全圆头），描边/填充/文字同 §2.1。
- 立柱 X：`ssCx = 0.92·w`（横屏）/ `0.82·w`（竖屏）。
- 首选 Y（屏幕高度比例）：`shoulderY = 0.180h`、`selectY = 0.244h`、`startY = 0.350h`、
  `gbaSelY = 0.282h`、`gbaStartY = 0.380h`。

**自适应重排 `stackRows()`（L792–831）——复刻必做**：

```
topLimit    = max(0.16·ref, chrome 行下沿(局部) + 0.012·ref)
bottomLimit = A 圆心Y − faceR − 0.028·ref
gapMin      = 0.011·ref
若首选行满足 [topLimit, bottomLimit] 且行间距 ≥ gapMin → 使用首选位置
否则：region = bottomLimit − topLimit
      scale = clamp(region / (总高 + gapMin·(n−1)), 0.6, 1.0)
      行高×scale，行间距 gap = max(gapMin, (region − 总高)/(n−1))
      从 topLimit 起依次堆叠
```
即：**行会撑满 chrome 行与 A 键之间的空白区**（实测 OXF 上 SELECT 在 31% 高、START 在 59% 高）。

### 2.6 各 profile 的按键编排

| Profile | 圆键 | 药丸 |
|---|---|---|
| NES / GB | B(0.85w,0.79h)、A(0.93w,0.71h) | SELECT、START |
| GBA | B、A（同上） | L(0.07w) / R(同列) 顶行 + SELECT / START（GBA 尺寸） |
| A2600 | FIRE（A 位） | SELECT、RESET |
| SMS / GG | 1、2 | PAUSE |
| MD | A=Y 位、B、C=A 位（`bx−0.85·baseR, by+0.55·baseR` / `bx,by` / `ax,ay`） | START |
| **MAME**（CPS 六键） | 见下 | 开始 / 投币 / 1P-2P（菜单展开时） |
| **NEOGEO**（四键） | 见下 | 菜单 pill + 招式面板 |

**MAME 六键面板**（L905–947，全部落在右侧信箱黑边 `0.794w ~ 0.992w` 内）：

```
edgeGap = 0.008·w
aR      = min(0.072·ref, (barW − 2·edgeGap)/6)
colGap  = 2·aR + (barW − 6·aR)/2
rowGap  = 2.5·aR
cxR     = barTo − aR
cyBot   = h − bottomInset − 0.03·ref − aR
cyTop   = cyBot − rowGap
上排：X(retro Y)  Y(retro X)  Z(retro L)
下排：A(retro B)  B(retro A)  C(retro R)
```

**NEOGEO 四键面板**（L948–987，2×2，NEOGEO mini 风格）：

```
aR     = min(0.088·ref, (barW − edgeGap)/4.5)
colGap = 2.5·aR        rowGap = 2.3·aR
cxR    = barTo − edgeGap − aR      cxL = cxR − colGap
cyBot  = h − bottomInset − 0.03·ref − aR     cyTop = cyBot − rowGap
上排：A(retro B)  B(retro A)      下排：C(retro Y)  D(retro X)
```

### 2.7 招式面板（NEOGEO 专属，折叠式）

- 折叠态：一个药丸，宽 `1.42·baseR` × 高 `0.55·baseR`，标签 `招式`；展开后标签变 `收起`
  （描边转琥珀）。位置（L1076–1079）：
  `pillTop = topInset + 0.017·h + 0.05·ref + pillH/2 + 0.022·ref`，X 居中于信箱区。
- 展开态：药丸下方 `2×3` 网格（`gapX = 0.018·ref`、`gapY = 0.014·ref`，
  网格顶 `pillTop + pillH + 0.022·ref`，网格底 `簇顶 − 0.022·ref`），单元格即招式键，
  样式同药丸（按下/播放中变琥珀）。
- 数据：固定 **6 槽**（`label + script`），默认 profile `kof97`：
  `波 236+P`、`升 623+P`、`旋 214+K`、`超 236236+PK`、`避 66`、`滚 44`
  （`assets/moves_presets.json`）。脚本语法见 `SpecialMovesStore.ScriptCompiler`：
  小键盘方向 `7↖ 8↑ 9↗ / 4← 5中 / 1↙ 2↓ 3↘`，`,` 分步，`+` 接按键 `P/H/L/K`，每步 3 帧。

### 2.8 菜单 pill 与 1P/2P 切换（街机专属）

```
menuY   = topInset + 0.017·h + 0.05·ref        （与本机 ✕ 圆心同高）
exitLeft= w − 0.017·w − 0.077·ref
hGap    = 0.012·w
menuCx  = exitLeft − hGap − pillW/2
```
- 折叠标签 `菜单`，展开 `收起`（描边转琥珀并 `held.clear()`）。
- 展开后向左依次扇形排开：`开始`(START)、`投币`(SELECT)、`1P/2P`（`portLocked` 时隐藏）。
- `1P/2P`：当前值即标签；选中 2P 时**静止态就是琥珀填充**（`drawPlayerToggle` L1566–1575）。

### 2.9 2P 加入提示（joinHint）

`drawJoinHint`（L1519–1529）：屏幕水平居中，`cy = topInset + 0.017·h + 0.05·ref + 0.12·ref`；
胶囊高度 `2×0.045·ref`，宽度 = 文字宽 + `2×0.05·ref`；底 `argb(150,20,20,24)` + 常态描边 +
白色文字。仅在 MAME/NEOGEO 且存在提示时显示。

### 2.10 手势排除区（Android 特有，其它平台对应处理）

`applySystemGestureExclusion`（L1135–1160）：左右边缘下三分之二 + 底部一条，深度
`min(0.16·ref, 200dp)`，把系统「返回 / 最近任务」手势还给游戏；**顶部边故意不排除**，
以保留下拉状态栏与顶部返回。
> 鸿蒙/iOS 复刻：需确认本平台的边缘返回手势是否会抢走手柄输入，必要时做同等处理
> （鸿蒙可用 `setWindowGestureExclusion` 之类的等价能力或让控件离边缘 ≥ 该距离）。

---

## 3. 顶部工具栏（Chrome）与命令面板

### 3.1 尺寸与位置（`installChrome` L536–594、`buildMenuBar` L820–953）

| 量 | 公式 |
|---|---|
| `pillW` | `0.1988·ref` |
| `pillH` | `0.077·ref` |
| 圆角 | `0.05·ref` |
| 描边 | 常态 `0.0056·ref`，按下 `0.0072·ref` |
| 字号 | `0.042·ref`（**px** 单位） |
| 垂直边距 `marginV` | `0.017·h` |
| 水平边距 `marginH` | `0.017·w` |
| 面板与功能键间距 `panelGap` | `0.012·w` |
| 面板内 pill 左右 margin | `0.006·w`（合计 1.2% 屏宽的节奏） |
| `rowNudge` | `(0.10·ref − pillH)/2`（旧版圆形图标是 `0.10·ref`，药丸更矮，整行下移差值之半） |
| **topMargin（含状态栏）** | `insetTop + 0.017·h + (0.10·ref − 0.077·ref)/2` |

三个控件：

| 控件 | 尺寸 | 位置 |
|---|---|---|
| `功能` pill | `pillW × pillH` | 左上：`x = marginH`，`y = topMargin` |
| `✕` 退出 | `pillH × pillH`（正方形 → 全圆） | 右上：`x = w − marginH − pillH`，`y = topMargin` |
| 命令面板 | `WRAP_CONTENT`（内含 5 个 pill） | `x = marginH + pillW + panelGap − 0.006·w`，`y = topMargin` |

- `功能` 与面板的 accent 为白色 `Color.WHITE`；`✕` 为 `rgb(239,154,154)`（`#EF9A9A`），
  描边 alpha 210（非白色 accent 时的取值），文字同色；无障碍描述分别为
  「功能菜单」/「退出到文件库」。
- 面板**无底板、无 padding**（`background = null`），5 个命令是自由浮动的独立药丸。
- `chrome 行下沿 = topMargin + 0.077·ref`，通过 `notifyPadChromeBottom` 传给手柄，
  作为 SELECT/START 立柱的上边界（见 §2.5）。

### 3.2 命令面板内容

非联机（左→右，固定顺序，标签两汉字）：

| # | 标签 | 行为 |
|---|---|---|
| 1 | `加速` | `cycleSpeed()`：档位 `1 → 2 → 4 → 6 → 8 → 1`；按钮文案变 `加速×N`；Toast「已恢复常速」/「游戏加速 ×N（音效已静音以保证稳定性）」/「游戏加速 ×N（音效同步加快）」 |
| 2 | `重开` | `confirmRestart()`：AlertDialog 标题「重新开始」，正文「将清除自动存档并回到游戏开头。\n手动保存的存档位与游戏内电池存档不受影响。」，按钮 `取消` / `重新开始` |
| 3 | `金手` | `openCheatsDialog()`（见 §5.1） |
| 4 | `存档` | 立即保存到下一个槽位（无弹窗），Toast 反馈 |
| 5 | `读档` | `openLoadDialog()`（见 §5.2） |

联机会话：**只有** `暂停` 一个 pill（快进/金手指/存档/重开会破坏 determinism，全部移除）。

### 3.3 面板的三种收起方式

1. 再次点击 `功能` pill（`visibility` 取反）；
2. 点击面板空白处（`ACTION_UP` 时对子按钮做矩形命中测试，未命中则 `GONE`）；
3. 点击任一命令按钮执行动作后（`重开` 需二次确认，确认后收起）。

面板初始 `visibility = GONE`。

---

## 4. 覆盖层：HUD / 联机统计 / 联机遮罩

### 4.1 FPS HUD

| 属性 | 值 |
|---|---|
| 文字色 | `Color.YELLOW`（`#FFFF00`） |
| 字号 | `10.5sp`（与短边无关的唯二 sp 之一） |
| 行距 | `setLineSpacing(add = 2px, mult = 1.0)` |
| 背景 | `argb(90,0,0,0)`（黑 35%） |
| 内边距 | 左 10 / 上 6 / 右 10 / 下 6（px） |
| 内容 | `"FPS %.1f%s\nxruns %d"`；非 1× 时在 FPS 后追加两个空格 + `×N` |
| 定位 | 水平居中于**画面轴**：`marginStart = picCx − 宽/2`，其中 `picCx = (父宽 + safeLeft − safeRight)/2`；`topMargin = safeTopPx + 0.011·h` |
| 刷新 | **2 Hz**（`now − hudLastNs ≥ 500ms`），每次刷新都重排一次 |
| 可见性 | `flutter.showFpsHud`（默认 **true**），隐藏时 `layoutHud()` 直接 return |

> 复刻提示：HUD 在手柄层之下；`xruns` 需原生音频丢帧计数（无此能力时可只渲染 FPS 行）。

### 4.2 联机统计行 npStat

- `Color.WHITE`、`11sp`、背景 `argb(120,0,0,0)`、padding 左右 14 / 上下 5；
- `Gravity.TOP | CENTER_HORIZONTAL`，`topMargin = 0.045·h`；初始 GONE，联机开始后 VISIBLE；
- 文案 `"RTT %.0f ms · D %d · 帧 %d%s"`，卡顿追加 `" · 等待…"`；**4 Hz** 刷新。

### 4.3 联机遮罩 npOverlay

- `MATCH_PARENT`，`Gravity.CENTER`，白字 `Color.WHITE`，背景 `argb(210,0,0,0)`；
- 初始文案「正在建立联机…」；倒计时 `3 / 2 / 1 / 开始！` 每步 `550ms`；
- 其它状态文案：「等待伙伴网络…」、「伙伴已暂停，稍候…」。

---

## 5. 原生对话框与 Toast

统一使用 `ContextThemeWrapper(this, android.R.style.Theme_Material_Light_Dialog_Alert)`
→ **浅色 Material 对话框 + 深色文字**（L1044–1051）。

### 5.1 金手指对话框

- 标题「金手指」，正向按钮「关闭」；窗口 **高度上限 = 0.62·h**（`MATCH_PARENT × 0.62h`）。
- 容器内距 `padPx = 0.033·ref`（左/右 `padPx`，上 `padPx/2`，下 0）。
- 空态文案（13sp，上下各 `padPx/2`）：
  「暂无金手指命令。\n\n请在电脑端文件库为本游戏添加命令（如「无限生命」开关、「武力值」选 10/50/100、「装备」选 剑/枪），同步后即可在此直接开关。」
- `Switch` 行：`CheckBox`，15sp，文案 = 命令名，勾选态持久化。
- `Choice` 行：横向布局，名称 TextView 15sp（占满剩余宽），右侧取值 Button 13sp，
  `minimumWidth = 0.267·w`；未选中显示「关」；点击弹单选列表 `["关闭"] + options.labels`，
  选中索引 `which − 1`（−1 = 关闭）。
- 索引缺失：`Toast.LENGTH_LONG`「未找到该游戏的索引记录，无法关联金手指」。
- 数据结构（`CheatStore`）：`Switch{name, code, enabled}` /
  `Choice{name, options[{label, code}], selected}`，存于 `library/cheats.json` 的
  `byCrc[CRC32 大写 8 位 HEX]`。

### 5.2 读档对话框

- 加载中：`FrameLayout` + 居中 `ProgressBar`，上下 padding `0.03·h`；标题「读取存档」，负向「取消」。
- 空态：正文「还没有手动存档。\n游戏中点菜单「存档」即可保存当前进度，最近 3 个存档会自动保留。」，按钮「知道了」。
- 列表项（ScrollView，高度上限 `0.58·h`，窗口宽 `0.82·w`）：
  - 行：横向 `CENTER_VERTICAL`，padding 左右 `0.028·w` / 上下 `0.022·h`，背景 `?selectableItemBackground`
  - 缩略图：`0.267·w × 0.20·h`，`CENTER_CROP`，圆角 `0.0167·ref`，占位色 `rgb(24,27,38)`，右间距 `0.039·w`
  - 主文案：`"存档 N · 槽位 M"`，`rgb(0x1F,0x23,0x29)`，15sp，加粗
  - 副文案：时间（`今天 HH:mm` / `昨天 HH:mm` / `M月d日 HH:mm`），`rgb(0x5F,0x66,0x70)`，12.5sp，上间距 `0.0083·h`
  - 「删除」按钮：`rgb(0xC6,0x28,0x28)`，13.5sp，padding `0.039w/0.028h/0.0167w/0.028h`；
    二次确认「删除该存档？」→ 删除后重新打开本对话框
  - 分隔线（非末行）：1px，`argb(30,0,0,0)`，左右 margin `0.033·w`
- 槽位 `SLOT_COUNT = 3`，按修改时间倒序；点击行即读取。

### 5.3 Toast

- 短提示：`Toast.LENGTH_SHORT`（加速、存档结果）；
- 长提示：`Toast.LENGTH_LONG`（金手指索引缺失）。

---

## 6. 虚拟按键处理逻辑（逐键、逐事件）

> 本章对应源码：`VirtualPadView.onTouchEvent()` L1246–1420、`hit()/hitStick()/hitDpad()/hitMacro()`
> L1114–1119 / 1674–1706 / 1422–1428、`emit()` L1457–1474、`releaseAll()` L1477–1489、
> 绘制 `drawCircle/drawPill/drawDpadBtn/drawStick/drawMenuPill/drawAssistPill/drawPlayerToggle/drawMacroBtn`、
> 以及 `EmulatorActivity` 的回调接线 L384–400 与命令面板 §3.2。

### 6.0 数据模型与状态变量

```kotlin
// VirtualPadView.Btn (L182) —— 手柄上的每一个“键”
class Btn(val mask: Int, val label: String, val shape: CIRCLE|PILL, val rect: RectF)
// VirtualPadView.MacroBtn (L190) —— 一键招式：seq 为“逐帧一个 RETRO 掩码”
class MacroBtn(val rect: RectF, val label: String, val seq: IntArray)

// 回调（L201）
fun interface OnButtonsChanged { fun onChanged(mask: Int, port: Int) }  // port: 0=1P, 1=2P
```

| 变量 | 含义 | 初值 |
|---|---|---|
| `held: MutableMap<Int,Int>` | `pointerId → 该手指按住的掩码` | 空 |
| `stickPointer` | 摇杆的专属指针槽 | `-1` |
| `togglePointer` | 1P/2P 药丸的指针槽 | `-1` |
| `menuPointer` | 菜单药丸的指针槽 | `-1` |
| `assistPointer` | 招式药丸的指针槽 | `-1` |
| `macroPointer` | 招式键的指针槽（**不持有掩码**） | `-1` |
| `stickDx / stickDy` | 旋钮相对圆心的偏移（已限幅） | `0` |
| `playerPort` | 0=1P，1=2P | `0` |
| `menuExpanded / assistExpanded` | 菜单 / 招式面板展开标志 | `false` |
| `portLocked` | 联机会话锁定端口（隐藏 1P/2P） | `false` |
| `joinHint` | 2P 加入提示文案（`null` = 不显示） | `null` |

**键位掩码（RETRO 位序，跨端必须一致）**

```
B=1<<0  Y=1<<1  SELECT=1<<2  START=1<<3
UP=1<<4 DOWN=1<<5 LEFT=1<<6  RIGHT=1<<7
A=1<<8  X=1<<9  L=1<<10  R=1<<11  L2=1<<12  R2=1<<13
```

**“是否按下”的判定（关键细节）**

```kotlin
private fun active(mask: Int) = held.containsValue(mask)   // 按掩码全等匹配，不是按位
```
即：只有 `held` 中**存在完全等于**该键掩码的值，该键才被认为是按下态。
（方向键因此用 `dirMask = UP|DOWN|LEFT|RIGHT` 做与/或运算来区分“携带方向”和“功能键掩码”。）

**最终输出**

```kotlin
private fun emit() {
    var mask = stickMask()                       // 摇杆/十字键贡献（d-pad 模式来自 held）
    for (b in held.values) mask = mask or b      // 其余按键叠加
    if (mask and BUTTON_SELECT != 0 && joinHint != null) joinHint = null   // 投币后收起提示
    listener?.onChanged(mask, playerPort)        // → renderer.buttonMask / playerPort
    invalidate()                                 // 自绘 View 必须显式请求重绘
}
```

---

### 6.1 事件分发总流程（`onTouchEvent`）

返回值**恒为 true**（消费所有触点，否则后续 MOVE/UP 收不到）。
坐标均为 View 局部坐标；多点用 `event.actionIndex` / `event.getPointerId(i)`。

#### 6.1.1 ACTION_DOWN / ACTION_POINTER_DOWN —— 按下（严格按以下优先级短路）

| 顺序 | 判定 | 命中后动作 | 说明 |
|---|---|---|---|
| 1 | `togglePointer < 0 && toggleRect.contains(x,y)` | `togglePointer = id` | 1P/2P 选择，翻转在**抬起**时发生 |
| 2 | `menuPointer < 0 && menuRect.contains(x,y)` | `menuPointer = id` | 街机菜单药丸，展开/收起在抬起时发生 |
| 3 | `assistPointer < 0 && assistRect.contains(x,y)` | `assistPointer = id` | 招式药丸，展开/收起在抬起时发生 |
| 4 | `macroPointer < 0 && hitMacro(x,y) != null` | `macroPointer = id` + **立刻** `macroListener.onMacro(seq)` | 招式键：按下即播放整段，不等抬起 |
| 5 | `hit(x,y) != 0` | `held[id] = 掩码` | **真实按钮优先于摇杆/十字键**（保证同在左侧的 GBA “L” 药丸可用） |
| 6 | `useDpadUi` | `held[id] = hitDpad(x,y)` | 十字键模式，走第 5 步之后 |
| 7 | `hitStick(x,y)` | `stickPointer = id` + `updateStick(x,y)` | 摇杆：必须落在**静止盘**上才能抓取 |
| 8 | 其它 | `held[id] = 0` | 空点：记录“这根手指没按任何键”，防止它后续被误判 |

按下后统一执行：`claimSystemGesture()`（反射调用隐藏 API 抢回边缘手势）→ `emit()` → `invalidate()`。

> **注意**：第 5 步之前**不会**走 d-pad，因此右侧功能键永远可点；把 d-pad 单独做成
> 一个「只处理十字键」的分发层，会让整个右侧失效（源码注释里明确记录了这个坑）。

#### 6.1.2 ACTION_MOVE —— 移动

对每个指针 `i` 分别处理：

| 指针身份 | 处理 |
|---|---|
| `stickPointer` | `updateStick(x,y)`：重新计算旋钮偏移（不重新抓取） |
| `togglePointer` | **忽略拖动**（只有抬起时判定） |
| `menuPointer` | **忽略拖动** |
| 其它（含 d-pad/普通键） | 见 6.2 / 6.4 的“滑动换键”规则 |

处理完统一 `emit()`。

#### 6.1.3 ACTION_POINTER_UP —— 多指中的一根抬起

| 指针身份 | 处理 |
|---|---|
| `stickPointer` | `stickPointer = -1; stickDx = 0; stickDy = 0` |
| `togglePointer` | 抬起点仍在药丸内 → `playerPort = if (==0) 1 else 0`；否则不翻转 |
| `menuPointer` | `flipMenu(x,y)`（见 6.8） |
| `assistPointer` | `flipAssist(x,y)`（见 6.10） |
| `macroPointer` | **仅释放槽位** `macroPointer = -1`（**不打断在途招式**） |
| 其它 | `held.remove(id)` |

#### 6.1.4 ACTION_UP / ACTION_CANCEL —— 最后一根手指离开

- 最后一根手指抬起时 Android 发的是 **ACTION_UP 而不是 POINTER_UP**，所以
  `toggle / menu / assist` 的判定必须在这里**再写一遍**，否则单指点击永不生效；
- 随后清空全部状态：`held.clear()`、`stickPointer=-1`、`stickDx/Dy=0`、
  `togglePointer=-1`、`menuPointer=-1`、`assistPointer=-1`、`macroPointer=-1`；
- `emit()`。

#### 6.1.5 `releaseAll()` —— 切后台等收不到 UP 的场景

```kotlin
val hadMacro = macroPointer >= 0
if (hadMacro) { macroListener?.onClear(); macroPointer = -1 }   // 唯一会取消招式的地方
if (held 非空 || togglePointer>=0 || menuPointer>=0 || assistPointer>=0 || hadMacro) {
    held.clear(); togglePointer=-1; menuPointer=-1; assistPointer=-1; emit()
}
```

---

### 6.2 通用按钮（圆形功能键 / 药丸键）

**按键清单与掩码**

| Profile | 圆键（CIRCLE） | 药丸键（PILL） |
|---|---|---|
| NES / GB | `B`=B、`A`=A | `SELECT`=SELECT、`START`=START |
| GBA | `B`=B、`A`=A | `L`=L、`R`=R、`SELECT`=SELECT、`START`=START |
| A2600 | `FIRE`=B | `SELECT`=SELECT、`RESET`=START |
| SMS / GG | `1`=B、`2`=A | `PAUSE`=START |
| MD | `A`=Y、`B`=B、`C`=A | `START`=START |
| MAME | 6 键面板（见 6.6） | `开始`=START、`投币`=SELECT（菜单展开时） |
| NEOGEO | 4 键面板（见 6.6） | 同上 + 招式面板（6.7） |

**处理流程**

1. **DOWN**：`hit(x,y)` 按 `buttons` 的插入顺序遍历 `rect.contains(x,y)`，**第一个命中**即返回其 `mask`，
   写入 `held[pointerId]`；同时命中多个时以**先插入者为准**（所以 L 药丸必须先于摇杆判定，
   而摇杆判定又排在第 5 步之后）。
2. **MOVE**：`held[id] = hit(px,py)` —— 手指滑到另一个键上会**直接换键**（旧键自动释放，
   不会同时按住），滑到空白处变 `0`。
3. **UP / CANCEL**：`held.remove(id)`；ACTION_UP 时整表清空。
4. **输出**：`emit()` 把所有 `held` 值 `or` 起来后回调 `onChanged(mask, port)`。
5. **执行**：`EmulatorActivity` 中 `renderer.buttonMask = mask`、`renderer.playerPort = port`
   （联机会话改为走 `nativeNetplayLocalMask`）。

**视觉反馈**

| 状态 | 表现 |
|---|---|
| 常态 | 填充 `argb(56,255,255,255)`、描边 `argb(150,255,255,255)`（`0.0056·ref`）、白字 |
| 按下 `active(mask)==true` | 填充 `argb(205,255,193,7)`、描边 `argb(245,255,235,170)`（`0.0072·ref`）、文字 `#2D2000` 伪粗；**整体内缩 `pressInset = 0.0069·ref`**（圆键为半径减小，药丸为矩形四周内缩） |
| 禁用 | 本 Pad 无禁用态；联机时是直接**不生成**该按键（如金手指/存档相关面板命令） |

**边界情况**

- 多指同时按不同键：`held` 按 `pointerId` 分别记录 → 可真正同时按下（如 A+B）。
- 同一键被两根手指按住：`held` 两个条目值相同，`or` 之后掩码不变；抬起其一后仍按下。
- 手指滑出屏幕：由 ACTION_MOVE 的 `hit()` 返回 0 → 该键释放（不会“粘键”）。
- 收不到 UP（如被系统手势打断）：`ACTION_CANCEL` 或 `releaseAll()` 兜底清空。

---

### 6.3 虚拟摇杆（`useDpadUi == false`）

**几何**

```
baseR = 0.190·ref·padScale      knobR = 0.44·baseR
travel = max(baseR − knobR, 1)  grabR = 1.35·baseR    // 命中半径比可见盘大一圈
```

**处理流程**

1. **抓取（DOWN，第 7 优先级）**：`hitStick(x,y)` = `(x−stickCx)² + (y−stickCy)² ≤ grabR²`。
   - 落在范围外**不会**吸附（这是刻意设计：底盘固定在静止圆心上，指令输入才可重复）。
   - 注释明确反对“MOBA 式跟随手指的浮动摇杆”。
2. **移动**：`updateStick(x,y)`
   ```
   dx = x − stickCx; dy = y − stickCy; mag = hypot(dx,dy)
   if (mag > travel) { dx = dx/mag*travel; dy = dy/mag*travel }   // 限幅到行程半径
   stickDx = dx; stickDy = dy
   ```
3. **量化 `stickMask()`**
   ```
   dz = travel * deadzone            // 默认 deadzone = 0.18
   if (stickPointer < 0) return 0
   if (hypot(dx,dy) < dz) return 0
   DPAD4：按 atan2 角度量化（22.5/67.5/112.5/157.5 分界）
       [-22.5,22.5)->→   [22.5,67.5)->↓→   [67.5,112.5)->↓   [112.5,157.5)->↓←
       [157.5,180]∪[-180,-157.5)->←   [-157.5,-112.5)->↑←   [-112.5,-67.5)->↑   其余->↑→
       （45° 楔形；源码注释把斜向分支标为 “dead zone，一般不会命中”）
   STICK / DPAD8：按轴独立判定（可组合成斜向）
       dx < −dz → ← ;  dx >  dz → →
       dy < −dz → ↑ ;  dy >  dz → ↓
   ```
4. **释放（POINTER_UP/UP/CANCEL）**：`stickPointer=-1; stickDx=stickDy=0` → 掩码归零。
5. **输出**：`emit()` 用 `stickMask()` 作为**初值**，再 `or` 其它 `held`。

**视觉反馈**

| 状态 | 表现 |
|---|---|
| 静止 | 底盘圆（填充+描边）+ 内圈 `0.62·baseR` 描边 + 中心旋钮（`argb(120,…)` 填充 + `argb(190,…)` 描边）+ 四个方向箭头（三角半宽 `0.13·baseR`、高 `0.17·baseR`，位于 `0.78·baseR`，色 `argb(105,255,255,255)`） |
| 拖动 | 底盘**仍在静止圆心**（不跟随手指）+ 圆心→旋钮的激活色连线 + 旋钮用琥珀填充/描边 |
| 无“禁用”态 | — |

---

### 6.4 十字键（`useDpadUi == true`，本工程默认外观）

**几何（`layoutDpad` L660–698）**

```
r        = 0.78·baseR          // 臂心距（发布包实测 ≈0.84·baseR，见 §12.2 注 1）
buttonR  = 0.46·baseR          // 臂圆半径
armW     = 0.40·baseR          // 十字条厚度 / 中心盖直径
outerR   = r + buttonR         // 触摸判定半径（一个整圆）
deadR    = 0.045·baseR         // 中心防抖死点
holdR    = (r + buttonR)*0.18  // 滞回环
```

**关键点：绘制矩形 ≠ 命中区**

四个臂是 4 个 `2·buttonR` 的**方形 rect**，但命中判定是把整块圆盘切成 4 个 45° 楔形：

```kotlin
private fun hitDpad(x, y): Int {
    if (outerR <= 0f) return 0
    val dist = hypot(x − stickHomeCx, y − stickHomeCy)
    if (dist > outerR || dist < deadR) return 0
    val ang = atan2(dy, dx) 的度数
    return when {
        ang >= -45  && ang <  45 -> BUTTON_RIGHT
        ang >=  45  && ang < 135 -> BUTTON_DOWN
        ang >= 135  || ang < -135 -> BUTTON_LEFT
        else -> BUTTON_UP
    }
}
```

**DOWN 分支（第 6 优先级）**

```
held[id] = hitDpad(x, y)
```
落在中心死点 → `0`（故意的 no-op，避免静止拇指乱跳）；落在盘外（未命中任何按钮）→ 走第 8 步 `held[id]=0`。

**MOVE 分支（与普通键不同！）**

```kotlin
if (useDpadUi && insideDpadDisc(px, py)) {      // dist <= outerR
    val db   = hitDpad(px, py)
    val prev = (held[id] ?: 0) and dirMask
    held[id] = when {
        db == 0                        -> prev   // 中心死点：保持原方向（↑→↓ 不断）
        prev != 0 && nearDpadCentre()  -> prev   // 滞回环：已锁定方向就不再摆动
        else                           -> db
    }
} else {
    held[id] = hit(px, py)                      // 滑出盘：释放方向，且仍可滑到功能键上
}
```

**UP/CANCEL**：随 `held.clear()` 释放。

**视觉反馈（与 §2.3 一致）**

- 十字条：竖向 `armW × 2r`、横向 `2r × armW`，圆角 `armW/2`，**只填充不描边**；
- 四臂：直径 `2·buttonR` 的圆，标签 `↑ ↓ ← →`，`drawDpadBtn(..., pressed = active(BUTTON_UP/DOWN/LEFT/RIGHT))`；
- 中心盖：半径 `armW/2` 的实心圆（填充+描边），表示“中间也是活的”；
- 按下臂：琥珀填充 + 琥珀描边 + 深色字 + 内缩 `pressInset`。

**边界情况**

- 斜向按压：楔形保证 45° 附近也归属某一基数方向，**不会丢输入**；
- `↑→↓` 连续滑动：经过中心死点时保持前一方向；
- 从十字键滑到 A 键：离开圆盘后走 `hit()`，方向释放、功能键按下；
- 中心静态点击：断言 0（不产生任何方向）。

---

### 6.5 肩键 L / R 与 SELECT / START 立柱

- 与普通按钮**完全同规则**（§6.2），只是形状为 PILL、位置在 `0.92·w` 立柱 / GBA 的 `0.07·w`（L）。
- L/R 只在 GBA profile 出现；`START` 在 MD / SMS / GG 上被复用为 `START` / `PAUSE`；
  A2600 的 `RESET` 复用的也是 `START` 位。
- **特殊副作用**：`emit()` 中若 `mask & SELECT != 0 && joinHint != null` → `joinHint = null`
  （街机联机时“投币”后，右上角的 2P 加入提示消失）。

### 6.6 街机键面板（MAME 六键 / NEOGEO 四键）

| Profile | 上排（左→右） | 下排（左→右） |
|---|---|---|
| MAME | `X`=Y、`Y`=X、`Z`=L | `A`=B、`B`=A、`C`=R |
| NEOGEO | `A`=B、`B`=A | `C`=Y、`D`=X |

- 这些键**就是普通圆键**，走 §6.2 的完整流程（DOWN 命中 → `held` → `emit`）。
- 与菜单/招式药丸的关系见 6.8 / 6.10。

### 6.7 招式键（宏，NEOGEO 展开后出现）

**触发方式：单击（按下即触发，与按住时长无关）**

1. **DOWN 第 4 优先级**：`hitMacro(x,y)` 命中 →
   ```
   macroPointer = id
   macroListener.onMacro(seq)      // IntArray：逐帧掩码序列
   ```
   → `EmulatorActivity`：`if (handle != 0L && npCfg == null) NativeBridge.nativePlayMacro(handle, seq)`
   （**联机会话禁用**，lockstep 必须确定性）。
2. **播放时长**：序列 8–14 帧（每步 3 帧），≈135–230 ms，由原生队列自行排空。
3. **UP / POINTER_UP**：**只释放 `macroPointer` 槽位，不调用 `onClear()`**
   —— 否则快速点击时 8–14 帧的运动永远播不完，招式发不出来。
4. **唯一取消路径**：`releaseAll()`（切后台）→ `macroListener.onClear()` → `nativeClearMacro()`。
5. **视觉**：`drawMacroBtn` 的 `on = (macroPointer >= 0)` → 手指按住期间为琥珀填充 + 激活描边 + 内缩
   （注释写的是 “amber while its macro is playing”，实际绑定的是指针槽）。
6. **默认 6 槽**（`assets/moves_presets.json` / `library/moves.json`，profile `kof97`）：
   `波 236+P`、`升 623+P`、`旋 214+K`、`超 236236+PK`、`避 66`、`滚 44`。

### 6.8 街机菜单药丸（标签「菜单」/「收起」）

**触发方式：单击（抬起时生效，且抬起点必须在药丸内）**

```kotlin
private fun flipMenu(x, y) {
    val inside = menuRect?.contains(x, y) == true
    menuPointer = -1
    if (inside) {
        menuExpanded = !menuExpanded
        held.clear()                       // 收起时动作键消失 → 丢弃可能残留的按压
        buildButtons(width, height)        // 重建 开始/投币/1P-2P 的矩形
    }
    emit()
}
```

- ACTION_POINTER_UP → `flipMenu`；单指抬起是 ACTION_UP → 在 UP 分支**再调用一次**。
- 展开后向左依次排开：`开始`(START)、`投币`(SELECT)、`1P/2P`（`portLocked` 时隐藏）。
- **视觉**：`pressed = menuPointer >= 0`；描边在 `menuExpanded || pressed` 时为激活琥珀；
  标签展开时是「收起」、折叠时是「菜单」。

### 6.9 1P / 2P 切换药丸

**触发方式：单击（抬起时且在药丸内才翻转）**

```kotlin
// POINTER_UP：
val onPill = toggleRect?.contains(x, y) == true
togglePointer = -1
if (onPill) playerPort = if (playerPort == 0) 1 else 0
// ACTION_UP（最后一根手指）同样再判定一次
```

- 拖动**不生效**（MOVE 分支对 `togglePointer` 明确忽略）。
- 翻转后 `emit()` 把新的 `port` 一并送出 → `renderer.playerPort = port`。
- **视觉**：`twoP = playerPort == 1` → 2P 时**静止即为琥珀填充**（区别于其它键只在按下时琥珀）；
  描边 `twoP || pressed`；标签 `2P` / `1P`；标签颜色随 `twoP` 走激活色。
- **禁用**：`portLocked = true`（联机会话由角色固定端口）时**不生成该矩形**。

### 6.10 招式药丸（NEOGEO，标签「招式」/「收起」）

```kotlin
private fun flipAssist(x, y) {
    val inside = assistRect?.contains(x, y) == true
    assistPointer = -1
    if (inside) {
        assistExpanded = !assistExpanded
        if (!assistExpanded) macroPointer = -1   // 网格消失 → 释放可能残留的招式指针
        buildButtons(width, height)
    }
    emit()
}
```
- 展开后在其下方生成 **2×3 招式网格**；折叠时不清除在途宏（与 `flipMenu` 的 `held.clear()` 不同）。
- **视觉**：同菜单药丸（`assistExpanded || pressed` → 激活描边）。

### 6.11 顶部命令面板与退出（Activity 层，非 Pad）

| 键 | 交互 | 处理流程 | 反馈 |
|---|---|---|---|
| `功能` | 单击 | 取反面板 `visibility` | 无按压态（普通 Button + StateListDrawable 按下变色） |
| `加速` | 单击（可连点循环） | `steps=[1,2,4,6,8]` → `idx=(indexOf(cur)+1)%5` → `setSpeed(n)` → Toast「已恢复常速」/「游戏加速 ×N（音效同步加快）」 | **面板保持展开**；标签变 `加速×N` |
| `重开` | 单击 → 二次确认 | `AlertDialog(重新开始 / 取消)` → 确认后 `renderer.resetRom()` | 面板收起 |
| `金手` | 单击 | `openCheatsDialog()`（无索引时 `Toast.LENGTH_LONG`「未找到该游戏的索引记录…」） | 面板收起 |
| `存档` | 单击 | 立即写入下一个槽位（无弹窗）→ Toast | 面板收起 |
| `读档` | 单击 | `openLoadDialog()`：空态 / 列表（最多 3 项，按时间倒序）→ 点行读取、点「删除」二次确认 | 面板收起 |
| `✕` | 单击 | `exitToLibrary()` | 退出页面 |
| `暂停` | 单击（仅联机） | 暂停会话 | 联机时**只有这一个**命令 |
| 面板空白处 | 单击 | `ACTION_UP` 时对 5 个子按钮做矩形命中测试，未命中 → 面板 `GONE` | 收起 |

### 6.12 状态 → 反馈对照总表

| 状态 | 判定来源 | 视觉 | 功能 |
|---|---|---|---|
| 常态 | — | 白 22% 填充 / 白 59% 描边 / 白字 | 掩码不含该位 |
| 按下 | `held.containsValue(mask)`（圆键/药丸）、`menuPointer>=0`、`assistPointer>=0`、`macroPointer>=0`、`togglePointer>=0` | 琥珀 80% 填充 / 琥珀 96% 描边 / `#2D2000` 伪粗字 / 内缩 `0.0069·ref` | 掩码置位 |
| 激活（非按压） | `playerPort==1`（1P/2P）、`menuExpanded`、`assistExpanded` | 琥珀填充或激活描边（无内缩） | 状态保持 |
| 空点 | `held[id]=0` | 无 | 不产生任何位 |
| 释放 | `held.remove(id)` / `held.clear()` | 回到常态 | 掩码清位 |
| 取消（CANCEL/后台） | `ACTION_CANCEL` / `releaseAll()` | 回到常态 | 清位；**仅 `releaseAll()` 会 `onClear()` 取消在途招式** |
| 禁用 | 不生成该控件（联机/非街机 profile/portLocked） | 不可见 | 不可触达 |

### 6.13 冲突与边界规则汇总

1. **优先级**：1P/2P > 菜单 > 招式药丸 > 招式键 > 普通按钮 > 十字键 > 摇杆 > 空点。
2. **普通按钮永远优先于摇杆/十字键**——否则左侧的 GBA “L” 药丸会被摇杆吞掉。
3. **摇杆是固定盘**：只在静止盘（+35% 容错）上抓取，绝不吸附到手指。
4. **十字键命中区是整圆楔形**，不是四个矩形；中心死点 + 滞回环保证连续滑动不断输入。
5. **招式宏触发即播完**：UP 只释放槽位不取消；只有 `releaseAll()` 取消。
6. **菜单收起必须 `held.clear()`**（动作键已消失，否则永远收不到抬起）；招式面板收起只需释放 `macroPointer`。
7. **单指抬头发的是 ACTION_UP**，因此 toggle/menu/assist 的翻转逻辑在 UP 分支重复实现一次。
8. **多指**：每指独立一条 `held` 记录，掩码 `or` 合并 → 支持真正的多键同按（A+B、斜向+攻击）。
9. **联机会话**：`portLocked=true`（无 1P/2P）、命令面板只剩「暂停」、宏被禁用（确定性要求）。
10. **切后台 / 手势打断**：`ACTION_CANCEL` 与 `releaseAll()` 双保险清空，避免“粘键”。

### 6.14 复刻清单（伪代码骨架）

```
onTouch(down, id, x, y):
    if toggleRect?.hit(x,y) and togglePointer<0: togglePointer = id
    elif menuRect?.hit(x,y)   and menuPointer<0:   menuPointer   = id
    elif assistRect?.hit(x,y) and assistPointer<0: assistPointer = id
    elif macroPointer<0 and hitMacro(x,y):        macroPointer = id; playMacro(seq)
    elif b = hit(x,y):                            held[id] = b
    elif useDpadUi:                               held[id] = hitDpad(x,y)
    elif hitStick(x,y):                           stickPointer = id; updateStick(x,y)
    else:                                         held[id] = 0
    emit()

onTouch(move, id, x, y):
    if id == stickPointer:      updateStick(x,y)
    elif id == togglePointer or id == menuPointer: pass          # 拖动无效
    elif useDpadUi and insideDpadDisc(x,y):
        db = hitDpad(x,y); prev = held[id] & dirMask
        held[id] = (db==0) ? prev : ((prev!=0 && nearCentre(x,y)) ? prev : db)
    else:                       held[id] = hit(x,y)
    emit()

onTouch(up, id, x, y):
    if id == stickPointer:  stickPointer=-1; stickDx=stickDy=0
    elif id == togglePointer: togglePointer=-1; if hit(toggleRect,x,y): port ^= 1
    elif id == menuPointer:   flipMenu(x,y)
    elif id == assistPointer: flipAssist(x,y)
    elif id == macroPointer:  macroPointer=-1                    # 不取消在途招式
    else:                     held.remove(id)
    emit()

onTouch(lastUp or cancel):
    # 单指抬起会走到这里：toggle / menu / assist 的翻转逻辑重复一次
    held.clear(); stickPointer=-1; stickDx=stickDy=0
    togglePointer=menuPointer=assistPointer=macroPointer=-1
    emit()

emit():
    mask = stickMask()
    mask |= all held values
    if mask & SELECT and joinHint: joinHint = null
    onChanged(mask, playerPort); repaint()
```

---

## 7. 配色规范总表

| 用途 | 色值 | 透明度 |
|---|---|---|
| 页面 / 窗口背景 | `#000000` | 100% |
| 控件填充（常态） | `#FFFFFF` | 22%（56/255） |
| 控件填充（激活/按下/2P/宏播放） | `#FFC907`（255,193,7） | 80%（205/255） |
| 控件描边（常态） | `#FFFFFF` | 59%（150/255） |
| 控件描边（激活） | `#FFEBAA`（255,235,170） | 96%（245/255） |
| 文字（常态） | `#FFFFFF` | 100% |
| 文字（激活） | `#2D2000`（45,32,0） | 100% |
| 摇杆旋钮填充 / 描边 | `#FFFFFF` | 47% / 74.5%（120 / 190） |
| 方向箭头 | `#FFFFFF` | 41%（105） |
| 2P 提示底 | `#141418`（20,20,24） | 59%（150） |
| 退出 ✕ accent | `#EF9A9A`（239,154,154） | 文字 100%，描边 82%（210） |
| HUD 文字 / 底 | `#FFFF00` / `#000000` | 100% / 35%（90） |
| 联机统计 文字 / 底 | `#FFFFFF` / `#000000` | 100% / 47%（120） |
| 联机遮罩 文字 / 底 | `#FFFFFF` / `#000000` | 100% / 82%（210） |
| 存档主文字 / 副文字 | `#1F2329` / `#5F6670` | 100% |
| 删除按钮 | `#C62828` | 100% |
| 缩略图占位 | `#181B26`（24,27,38） | 100% |
| 分隔线 | `#000000` | 12%（30） |

> 复刻时请统一使用**线性 sRGB 上同值**：Android 的 `Color.argb` 是 8 位 sRGB 分量，
> 鸿蒙 `rgba()` / iOS `Color(srgbRed:)` 直接填 0–255 分量 + 0–1 alpha 即可。

---

## 8. 字体规范

| 场景 | 字号 | 字重 | 颜色 |
|---|---|---|---|
| 手柄所有标签（↑↓←→ / A B / SELECT / 招式 / 菜单 / 1P2P） | `0.042·ref` px | 常规（激活时伪粗） | 白 / `#2D2000` |
| 顶部工具栏 pill | `0.042·ref` px | 常规 | 白（✕ 为 `#EF9A9A`） |
| HUD | 10.5 sp | 常规 | 黄 |
| 联机统计 | 11 sp | 常规 | 白 |
| 对话框标题/正文 | 系统 AlertDialog 默认 | — | 深色（浅色主题） |
| 金手指 开关 / 选项名 | 15 sp | 常规 | 深色 |
| 金手指 取值按钮 | 13 sp | 常规 | 深色 |
| 金手指 空态 | 13 sp | 常规 | 深色 |
| 存档 标题 / 时间 / 删除 | 15 sp 加粗 / 12.5 sp / 13.5 sp | — | `#1F2329` / `#5F6670` / `#C62828` |

- 字体族：系统默认（`Typeface.DEFAULT`），中文优先系统黑体；按钮**关闭全大写**
  （`isAllCaps = false`）与 `includeFontPadding = false`。

---

## 9. 间距与节奏

| 场景 | 值 |
|---|---|
| 屏幕边缘水平 / 垂直边距 | `0.017·w` / `0.017·h` |
| 工具栏 → 面板 | `0.012·w` |
| 面板内 pill 左右 margin | `0.006·w`（相邻 pill 间距 1.2% 屏宽） |
| 手柄与屏幕边 | `edgeGap = 0.05·ref` |
| 药丸立柱底部保护 | `0.03·ref` |
| 招式网格 gapX / gapY | `0.018·ref` / `0.014·ref` |
| 招式药丸与网格间距 | `0.022·ref` |
| 药丸立柱行最小间距 | `0.011·ref` |
| 摇杆行程死区 | `travel × 0.18` |
| HUD 顶部余量 | `safeTop + 0.011·h` |

**视觉节奏原则**：所有间隙都是屏幕百分比；`0.006·w` 的“半拍”构成 pill 之间
`0.012·w` 的“整拍”，工具栏与手柄使用同一套数值。

---

## 10. 响应式与适配要求（硬性）

1. **短边驱动**：`ref = min(w, h)`；横竖屏 90° 互换时控件视觉尺寸**不变**（`onChromeSizeChanged`
   只重算 margin/间距，不重建 pill 尺寸）。
2. **状态栏/挖孔 inset**：chrome 行 `topMargin` 必须叠加 `insetTop`；
   手柄立柱上边界取 `max(0.16·ref, chrome 下沿 + 0.012·ref)`；
   摇杆/街机面板底部锚点必须减去 `bottomInset` 与 `0.03·ref` 保护量。
3. **底部手势条**：Android edge-to-edge 容器不报告 inset，代码额外加 `0.06·ref` 余量
   （`gestureBarAllowance`）；其它平台若有悬浮 Home 条需等效处理。
4. **小屏/矮屏**：`stackRows` 会自动压缩行高（下限 0.6×）并重排；竖屏摇杆 X 移到 `0.22·w`
   以避开右侧键簇；街机面板底部行不得超出屏幕底边（`aR` 受 `barW` 上限约束）。
5. **超大屏/平板**：所有量随 `ref` 线性增长，**不做上限截断**（代码注释明确 tablet 场景）。
6. **用户可调**：`padScale ∈ [0.5, 2.5]`（默认 1.0，直接乘进 `baseR`）；
   `padOffsetX/Y ∈ [−0.45, 0.45]`（相对屏宽/高的比例，叠加到摇杆圆心与**按钮**（不含十字键））。
7. **高刷**：优先选择同分辨率下刷新率最高的显示模式（尽力而为，失败静默）。
8. **手势冲突**：边缘返回手势需为左右下三边做排除（见 §2.10）。

---

## 11. 配置与持久化

统一存于 `SharedPreferences("FlutterSharedPreferences")`，键带 `flutter.` 前缀
（Flutter `shared_preferences` 命名）：

| key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `flutter.showFpsHud` | Boolean | `true` | HUD 可见性唯一真源 |
| `flutter.stickMode` | String | `"DPAD8"` | `STICK` / `DPAD4` / 其它→`DPAD8` |
| `flutter.stickDeadzone` | **String** | `"0.18"` | 必须按字符串读（Dart `setDouble` 写 base64） |
| `flutter.useDpadUi` | Boolean | `false` | true → 十字键，false → 摇杆 |
| `flutter.padScale` | String | `"1.0"` | clamp `[0.5, 2.5]` |
| `flutter.padOffsetX` / `Y` | String | `"0.0"` | clamp `[−0.45, 0.45]` |
| `flutter.fastForwardAudio` | Boolean | `true` | ×>1 时是否静音 |
| `flutter.lastSaveSlot` | Int | `-1` | 0..2 生效 |

`onResume` 会重新拉取（从设置页返回即生效）并 `pad.requestLayout()`。

---

## 12. 跨端复刻对照与已知差异

### 12.1 控件 → 端能力映射

| Android | 鸿蒙 ArkTS | iOS SwiftUI |
|---|---|---|
| `FrameLayout` 根 | `Stack` | `ZStack` |
| `GLSurfaceView` | `XComponent(type: SURFACE)` + EGL | `MTKView` / `CAEAGLLayer` |
| `View.onDraw(Canvas)` 自绘 | `Stack` + `Column/Button/Text` 组合（无 Canvas 语义）或 `Canvas` 组件 | `Canvas` / `Shape` |
| `FrameLayout.LayoutParams + position` | `.position({x, y})` | `.position(x:y:)` / `.offset` |
| `Paint(STROKE)` | `.border({width, color})` | `.strokeBorder` / `.overlay(RoundedRectangle.stroke)` |
| `GradientDrawable(cornerRadius)` | `.borderRadius()` | `.clipShape(RoundedRectangle)` |
| `StateListDrawable(pressed)` | `@State` + `onTouch` 自管 | `ButtonStyle` |
| `MotionEvent` 多点 | `TouchEvent` `touches[].id/x/y` | `DragGesture` / `UIResponder` |
| `Toast` | `promptAction.showToast` | 自定义 Toast |

### 12.2 已知差异 / 复刻时的取舍（务必知悉）

1. **十字键臂心距**：当前源码 `r = 0.78·baseR`；但参考机 OXF-AN10 上**已安装发布包实测
   ≈ 0.84·baseR**（截图量得臂心间距 144.4px、臂直径 158px、`ref≈905`）。
   若以“手机上的样子”为准 → 用 **0.84**；若以“当前源码”为准 → 用 **0.78**。
   两者仅影响十字键张开约 8%，需与验收截图口径统一后再定。
2. **工具栏药丸高度**：源码 `pillH = 0.077·ref`；发布包实测 `≈0.069·ref`（62px / ref≈900）。
   同属“源码 vs 发布包”差异，按验收口径选择其一。
3. **半透明描边宽度**：不要用 1px，必须是 `0.0056·ref`（常态）/ `0.0072·ref`（激活），
   否则在 3x 屏上会明显偏细。
4. **@Builder 按值传参不会自动重排（鸿蒙特有坑）**：几何必须由 `@State` 驱动并
   **一次性构建**（窗口尺寸确定后再渲染），否则旋转后部分控件会用旧坐标。
5. **窗口尺寸读取时机**：旋转后立刻读 `windowRect` 会拿到旋转前的值，
   必须监听尺寸变化事件并在拿到横屏尺寸后再布局。
6. **状态栏**：Android 侧**没有**自定义状态栏颜色、也没有 EdgeToEdge；
   是否显示横屏状态栏由系统/容器决定（Honor 上会显示，鸿蒙真机横屏通常不显示）。
   若目标平台不显示横屏状态栏，则 `insetTop = 0`，chrome 行退化为
   `0.017·h + rowNudge`；**不要**为了“对齐”而人为预留一条空白。
7. **HUD 层级**：Android 中 HUD 在手柄之下；若复刻时把 HUD 放在手柄之上，
   需确保它 `hitTestBehavior = None`，避免吃掉触摸。

### 12.3 实现顺序建议

1. 建立 `Sizing`（wp/hp/sp + `ref`）与配色常量表；
2. 铺满屏 GL 画面 + 黑底 + 强制横屏；
3. 十字键（几何 + 楔形判定 + 滞回）；
4. 右侧圆键 / 药丸立柱（含 `stackRows` 重排）；
5. 顶部 chrome（功能 / ✕ / 命令面板，三种收起）；
6. HUD（2 Hz）；
7. 摇杆（STICK/DPAD8/DPAD4 三模式）+ 设置项；
8. 街机 profile（MAME 六键 / NEOGEO 四键 / 招式面板 / 菜单 pill / 1P2P）；
9. 对话框与 Toast；
10. 手势排除与 inset 适配。

---

## 13. 验收清单（截图比对项）

- [ ] 横屏：**无 ActionBar**，页面底色纯黑，画面 4:3（或核心比例）居中、上下无黑边（横屏时）。
- [ ] 状态栏：**黑底白字**（`statusBarColor=#000000`、`statusBarContentColor=#FFFFFF`），
      与纯黑页面背景连成一体；**底部不保留导航栏**，画面一直铺到屏幕最下沿（Android 行为）。
- [ ] 左上 `功能` 药丸：距左边缘 `0.017·w`，距顶 `insetTop + 0.017·h + rowNudge`，
      尺寸 `0.1988·ref × 0.077·ref`，圆角全圆头，白字居中。
- [ ] 右上 `✕`：圆形，直径 `= pillH`，描边与文字 `#EF9A9A`。
- [ ] 点 `功能` → 同一行右侧依次排开 `加速 / 重开 / 金手 / 存档 / 读档`，
      间距 1.2% 屏宽；点空白收起。
- [ ] 点 `加速` → 标签变 `加速×2 → ×4 → ×6 → ×8 → 加速`，并弹 Toast。
- [ ] 左下十字键：四臂圆 + 十字条 + 中心实心盖，标签 `↑ ↓ ← →`；
      按下时该臂内缩并变琥珀（字变深色）。
- [ ] 十字键斜向按压不丢方向；`↑→↓` 连续滑动不中断。
- [ ] 右侧 B（下左）、A（上右）圆键，直径 `= baseR`；SELECT/START 药丸立柱在 `0.92·w`，
      两行撑满 chrome 行与 A 键之间的空间。
- [ ] HUD：黄字、黑 35% 底、水平居中于画面轴、`safeTop + 1.1%h`，2 Hz 刷新。
- [ ] 全部控件描边粗细随屏幕缩放（`0.0056·ref`），而非恒定 1px。
- [ ] 旋转/切后台返回后布局不错位；设置里改 `padScale` / 偏移后立即生效。

---

## 14. 鸿蒙（ArkTS）实现要点与踩坑记录

> 本节记录 `app/ohos/entry/src/main/ets/pages/EmulatorSpike.ets` 实际落地时踩到的坑，
> 供后续维护与其它端复刻参考。

### 14.1 单位：ArkUI 的纯数字 Length = vp

- `width(100)` / `padding({left: 8})` / `border({width: 2})` / `borderRadius(24)`
  **全部按 vp 解释**（本机 1vp ≈ 3.25px）。
- 期望“像素级”尺寸时必须写成字符串 `'100px'`；否则描边会粗 3 倍、字号会大 3 倍。
- 百分比也可用：`borderRadius('50%')` 表示“圆/胶囊”。

### 14.2 `Button` 会覆盖自定义圆角

`Button(label).borderRadius('50%')` 在鸿蒙上仍按默认约 20vp 的圆角渲染，
无法画出精确的圆/胶囊。**结论：手柄键与工具栏药丸一律用 `Stack(){ Text(...) }`**
（无默认背景/内边距/圆角），按下态自己用 `onTouch` + `@State` 维护。

### 14.3 `@Builder` 按值传参不会刷新

`@Builder foo(x: number)` 中的 `x` 变化**不会**触发重排；只有 `this.xxx` 状态
变化才会。几何因此必须：
1. 预计算成 `@State` 数组（`padCircles` / `padPills`）+ `ForEach` 渲染；
2. 或在 builder 内直接读 `this.winW / this.ref()` 这类状态。

### 14.4 窗口尺寸与系统栏

- 旋转刚完成时读 `windowRect` 会拿到**旋转前**的尺寸 → 必须监听 `windowSizeChange`
  或延迟复读。
- 需要“横屏也有状态栏”必须同时：
  `setWindowLayoutFullScreen(false)` + `setWindowSystemBarEnable(['status'])`。
- 之后 `page` 的 `onAreaChange` 尺寸会小于 `windowRect`（页面已被系统内缩），
  此时控件原点为 `(0,0)`；若平台不做内缩（沉浸式），则必须自己叠加
  `getWindowAvoidArea(TYPE_SYSTEM)` 的 `topRect.height / leftRect.width`。
  实现里用「page 尺寸 vs windowRect 尺寸」自动判定这两种情况。

#### 系统栏配色与底部铺满（对齐 Android）

Android 端窗口背景纯黑、状态栏保持可见但不着色，**底部完全不预留导航栏**，
游戏画面一直画到屏幕最后一行像素。鸿蒙端需三段配置：

```ts
// 1) 状态栏：黑底 + 白字（默认是白色半透明底 + 深色字，在纯黑页面上几乎看不清）
await win.setWindowSystemBarProperties({
  statusBarColor: '#000000',
  statusBarContentColor: '#FFFFFF'
});
// 2) 只显示状态栏 → 同时隐藏导航栏
await win.setWindowSystemBarEnable(['status']);
// 3) 隐藏底部那条手势提示细线，把最后 94px 也让给画面
await win.setSpecificSystemBarEnabled('navigationIndicator', false);
```

- 仅仅 `setWindowSystemBarEnable(['status'])` **不会**收回底部空间：
  非沉浸式下 `page` 仍会比 `windowRect` 矮 ~94px（导航条避让区）。
- 正确做法是给**根 Stack 与 XComponent 都加**
  `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])`；
  注意 `SafeAreaType / SafeAreaEdge` 是**全局环境枚举**，从 `@kit.ArkUI` 导入会编译报错。
- 校验指标：`surface changed 2844x1132`（= 1260 − 128 状态栏），
  且 `page` 的 `onAreaChange` 高度同步为 1132；此时画面上下无黑边。

### 14.5 原生渲染

- 画面比例不能直接用 `texW/texH`：NES 需要 `256/240 × 8/7 = 1.219`，
  GB/GG `10:9`、GBA `3:2`、其余 `4:3`（`gpretro.cpp: CoreAspect()`）。
- `eglSwapBuffers` 前必须 `eglMakeCurrent`；surface 尺寸变化要同步 `g_winW/g_winH`，
  否则 letterbox 会按旧尺寸计算。
- FPS 用原生计数器（每 0.5s 采样）回传给 ArkTS，`setInterval(500)` 刷新 HUD。
- 注意：本工程 `roms/yx.nes` 是 **Dendy(PAL) ROM，原生 50Hz**，HUD 显示 ~50.0 属正常，
  不是掉帧（帧耗时可拆成 `run + draw+swap + sleep ≈ 19.6ms`）。

### 14.6 对话框

Android 用 `Theme_Material_Light_Dialog_Alert`（浅底深字）。
鸿蒙直接用 `AlertDialog.show({ title, message, primaryButton, secondaryButton })`，
默认即浅色卡片 + 蓝色主按钮；把危险按钮显式设为 `#C62828` 即与 Android 一致。

### 14.7 当前鸿蒙端完成度（对照本文档）

| 能力 | 状态 |
|---|---|
| 画面/音频/输入链路（fceumm） | ✅ |
| 十字键（几何 + 楔形判定 + 滞回 + 按下内缩/琥珀） | ✅ |
| 圆键 B/A、药丸 SELECT/START（含 `stackRows`） | ✅ |
| 顶部 功能 / ✕ / 五命令面板（三种收起） | ✅ |
| FPS HUD（2 Hz，单行） | ✅（`xruns` 行未做） |
| 加速档位 + Toast、重开确认、金手指空态 | ✅ |
| 摇杆三模式（STICK/DPAD4/DPAD8）与设置项 | ✅（`设置项` 持久化到 `settings.json`，面板按钮循环切换 + Toast） |
| 3 存档位 + 读档列表对话框（含缩略图） | ✅（原生 `saveStateSlot/loadStateSlot/listSaves` 三槽 + 缩略图，对话框含时间/删除/读档；`flutter build hap` 通过） |
| 金手指数据（cheats.json → Switch/Choice 列表） | ✅（原生 `getCheats` 按 ROM CRC 取数组 + `setCheats` 经 `retro_set_cheat` 下发；对话框每招 Switch 开关、多选招式 Choice 药丸；`flutter build hap` 通过） |
| 街机 profile（MAME 六键 / NEOGEO 四键 / 招式 / 菜单 / 1P2P） | ⏳（依赖 OHOS libretro 主机支持街机核心；当前 `EmulatorSpike` 仅 fceumm/NES 实跑，profile 仅驱动按键布局，街机核心未接入） |
| 手势排除区、联机统计与遮罩 | 手势排除 ✅（OpenHarmony 26 无「逐区域排除」API，改用 `setGestureBackEnabled(false)` 关闭窗口返回手势，Pura70 日志确认 `SetGestureBackEnabled ... enable 0`）；联机统计/遮罩 ⏳（无 netplay 数据源） |
| 文件库中文名乱码（OHOS SAF 导入） | ✅（根因：ArkTS `fileNameFromUri` 未对 SAF document URI 末段做 URL 解码，中文名以 `%E6%8B%B3…` 落库。已在 `GamePouchPlugin.ets` 加 `decodeURIComponent` 解码；并在 `RomEntry.displayTitle` 增加显示期百分号解码，治愈历史已落库的乱码条目（幂等）。自测：`flutter test test/rom_library_test.dart` 11/11 绿；`build-hap.ps1` 签名构建通过；Pura70 `hdc install -r` 成功） |

> 进度核对方式：在仓库根执行
> `powershell -ExecutionPolicy Bypass -File scripts\build-hap.ps1 -NoCodesign`
> （脚本会先 `. .\scripts\use-env.ps1 -Ohos` 注入 flutter_ohos 自带 node/npm，再 `flutter build hap`）。

> **Pura70 真机验证（2026-10-20）**：按 `skills.md` §2.6 流程执行
> `powershell -ExecutionPolicy Bypass -File scripts\build-hap.ps1`（默认 DevEco 自动签名，产出
> `entry-default-signed.hap` 约 146 MB）→ `hdc install -r ...` 成功 → `aa start -a EntryAbility -b com.gamepouch.gamepouch`
> → 进入 `pages/EmulatorSpike`，`libgpretro.so` 加载、`dlopen(libgs_fceumm.so)` 成功、`core=FCEUmm`、
> `emu_xcSurface` 上树、音频路由就绪、`SetGestureBackEnabled enable 0`；截图确认 NES 画面实时渲染、
> 虚拟手柄（摇杆 + SELECT/START/B/A + 顶部工具栏）正常，无白屏/崩溃。
> 1–3 项均已通过编译（产物 `app/build/ohos/debug/entry-default-unsigned.hap`）；
> 真机可装版本需 DevEco 自动签名（或 `build-hap.ps1` 不带 `-NoCodesign`），因本机自签 CA 设备不信任。
> 4–5 项功能需先在 OHOS 主机侧接入街机核心 / netplay，属更大的跨模块工程，非单文件可完成。

---

# 第二部分：Flutter / Dart 应用层（文件库 · 设置 · 账号云 · 伙伴联机 · 招式 · 法律）

> 数据来源（全部为代码事实，行号可回溯）：
> - `app/lib/main.dart`（路由 / 主题 / 同意门）
> - `app/lib/features/library/library_page.dart`（文件库首页 + 详情 + 导入/导出/删除）
> - `app/lib/features/library/missing_bios_dialog.dart`
> - `app/lib/features/settings/settings_sheet.dart`、`special_moves_editor.dart`
> - `app/lib/features/account/account_page.dart`
> - `app/lib/features/cloud/cloud_library_page.dart`、`cloud_actions.dart`
> - `app/lib/features/peer/peers_page.dart`、`peer_library_page.dart`、`pair_dialog.dart`
> - `app/lib/features/play/play_lobby_page.dart`、`play_invite_dialog.dart`
> - `app/lib/features/legal/{consent_gate,privacy_policy_page,eula_page}.dart`
> - `app/lib/domain/rom_entry.dart`、`app/lib/data/rom_library.dart` 等数据层
>
> 关键事实：**本应用没有任何底部导航栏 / Drawer / TabBar / Splash / Onboarding /
> 命名路由**。所有页面通过 `MaterialPageRoute` 匿名 `push/pop`、`showDialog`、
> `showModalBottomSheet` 完成。模拟器本身是**原生 Activity**（经 `pal.launchEmulator`
> 平台通道启动，不属于 Flutter 屏幕）。复刻时整段搬运这些 Dart 文件即可。

---

## 15. Flutter 应用层全页规范

### 15.1 应用级事实（主题 / 路由 / 渠道）

| 项 | 值 | 备注 |
|---|---|---|
| `MaterialApp.title` | `趣玩匣` | `main.dart:120` |
| 显示名 | `趣玩匣 GamePouch` | 设置卡 / 同意门 / 账号页页脚 |
| 主题 | `ThemeData(useMaterial3:true, brightness, colorSchemeSeed:0xFF4FC3F7, visualDensity.standard)` | `main.dart:122-127`，主色种子浅蓝 |
| 默认亮度 | 深色（`AppSettings.darkTheme` 默认 `true`） | 运行时 `GamePouchAppState.setBrightness` 实时切换（`main.dart:100-115`） |
| 首页 `home` | `LibraryPage(pal: widget.pal)` | `main.dart:128`，无 `routes`/`onGenerateRoute` |
| 分发渠道 `app_channel` | `store`（默认：禁自更新 / 禁云 ROM 下载）/ `community`（允许） | `canSelfUpdate`/`canCloudRom`/`canPeerRom=true` |
| 同意门 | `consent_given` 为 false → `ConsentGate`；OHOS 无 prefs 时默认视为已同意 | `main.dart:50-63` |
| 字体 | 系统默认；仅代码/CRC 用内联 `fontFamily:'monospace'` | — |

### 15.2 页面总览

| 页面 | 文件 | 打开方式 | 用途 |
|---|---|---|---|
| LibraryPage 文件库 | `features/library/library_page.dart` | 首页 | ROM 网格 / 搜索筛选排序 / 选择导出 / 详情 / 导入 / 启动 |
| MissingBiosDialog | `features/library/missing_bios_dialog.dart` | 启动街机前 BIOS 缺失 | 提示缺 BIOS + 批量导入 |
| SettingsSheet 设置 | `features/settings/settings_sheet.dart` | 文件库右上「设置」→ 半屏底部弹层 | 关于 / 体验 / 控制 / BIOS / 应用 |
| SpecialMovesEditorPage | `features/settings/special_moves_editor.dart` | 设置内「招式按键」→ push | 6 槽格斗招式脚本编辑 |
| AccountPage 账号云 | `features/account/account_page.dart` | 文件库右上云图标 → push | 登录 / 云库 / 同步 / 发现伙伴 / OTA |
| CloudSync 弹窗 | `features/cloud/cloud_actions.dart` | 账号页「立即网络同步」 | 同步进度 |
| CloudLibraryPage 云文件库 | `features/cloud/cloud_library_page.dart` | 账号页 → push | 浏览/订阅服务端游戏 |
| PeersPage 发现伙伴 | `features/peer/peers_page.dart` | 账号页「发现伙伴」→ push | 局域网发现/配对/联机邀请 |
| PairDialog 配对 | `features/peer/pair_dialog.dart` | PeersPage 配对 | 6 位分组码确认配对 |
| PeerLibraryPage 伙伴库 | `features/peer/peer_library_page.dart` | PeersPage 点「文件库」→ push | 浏览对方库 + 4 步导入 |
| PlayInviteDialog 联机邀请 | `features/play/play_invite_dialog.dart` | 收到邀请 | 接受/拒绝（60s TTL） |
| PlayLobbyPage 联机大厅 | `features/play/play_lobby_page.dart` | 接受邀请 / 发起主机 | 双人槽位 / RTT 探测 / 开始 |
| ConsentGate 同意门 | `features/legal/consent_gate.dart` | 首次启动 | 隐私政策 + 用户协议 |
| PrivacyPolicyPage / EulaPage | `features/legal/*` | 同意门 / 设置内 | 模板正文 |

### 15.3 LibraryPage（文件库首页）

**文件**：`features/library/library_page.dart:19-1202`

**AppBar（`677-730`）**

| 状态 | 标题 | leading | actions |
|---|---|---|---|
| 非选择 | `趣玩匣文件库` | `null` | ① 云图标（`tooltip 账号 / 云服务 / 升级`）→ push AccountPage；② `more_vert` 弹出菜单（见下）；③ 设置图标（`tooltip 设置`）→ `SettingsSheet.show` |
| 选择 | `已选 ${_selected.length} 个` | `close` 图标（`tooltip 退出选择`） | `select_all` 图标（`tooltip 全选 / 取消全选`） |

- 弹出菜单项：`导入 ROM（单文件）` / `导入游戏资源包 / ZIP（自动识别）` / `选择游戏并导出资源包`（`702-723`）。
- **设计要求**：AppBar 背景随主题；图标按钮 tooltip 必须齐全（1:1 无障碍/验收）。

**正文（`_buildBody 742-925`）**

- 搜索 `TextField`：`hint 搜索名称 / 双人 / 金手指 / 存档…`，前缀 `search` 图标，清空 `cancel_outlined`。
- 计数：`${visible}/${_entries}` 或 `共 ${visible}/${_entries} 个游戏`。
- 排序 `_SortMenu`（`sort` 图标，`tooltip 排序`）：`按名称排序` / `按发行日期排序` / `按文件大小排序` / `按最近游玩排序`（`1206-1228`）。
- 平台筛选 `_PlatformChipBar`（`1245-1290`）：`全部平台` ChoiceChip + 各平台 ChoiceChip（label `${p.label} ${counts}`）。
- 类型/分类筛选：`category_outlined` / `folder_outlined` 两个下拉。
- 「继续游戏」卡片 `_ContinueCard`（`1577-1659`）：`继续游戏` + `上次游玩 … · 进入即恢复进度` → `_launch`。
- 游戏网格 `_GameCard`（`1406-1494`）/ 横屏行 `_GameRow`（`1662-1759`）：点按 → `_openDetail`。
- 空状态 `_buildEmptyState`（`1010-1057`）：`文件库为空` + `导入 ROM（单文件）`/`导入资源包 / ZIP` 按钮 + 提示「也可在 PC 端文件库管理器一键同步游戏到手机」。

**选择态 FAB**：`FloatingActionButton.extended`（`archive_outlined`，`导出资源包（${_selected.length}）`）→ `_exportSelected`（`731-737`）。

**缺失 BIOS 横幅 `_biosBanner`（`930-1006`）**：标题 `缺少系统文件（BIOS）` + 缺失文件名列表 + `FilledButton.icon`（`file_upload_outlined`，`导入 BIOS 文件`）→ `_importBios`。

**弹窗 / 底部弹层**

- 详情：竖屏 `showModalBottomSheet`（`_DetailContent`，`showDragHandle`，`1178-1194`）；横屏 `Dialog`（`1155-1175`）。
  - `_DetailContent`（`1762-1923`）：kv 行 `平台 / 开发商 / 发行商 / 发行日期 / 游戏人数 / 文件大小 / CRC32 / 最近游玩`；`金手指命令（x/y 生效）` 段 `_CheatSection`；`FilledButton.icon`（`play_arrow`，`开始游戏`）→ `onLaunch`→`_launch`；`IconButton.outlined`（`delete_outline`，`tooltip 删除`）→ `onDelete`→`_confirmDelete`。
- 导出选项 `AlertDialog`（`319-385`，标题 `导出游戏资源包`）：`CheckboxListTile` `ROM 游戏文件（必含）`/`金手指`/`存档`/`封面`/`BIOS 系统文件`（已装 BIOS 可逐项勾选）；按钮 `取消`/`导出`。
- 导出进度 `AlertDialog`（`407-422`，`正在导出资源包`）：`LinearProgressIndicator` + `正在准备…`/`打包完成，请在系统弹窗中选择保存位置…`。
- 删除确认 `AlertDialog`（`582-589`，`删除游戏`）：`将同时删除游戏文件与索引记录：\n${title}`；按钮 `取消`/`删除`。
- 启动前 BIOS 缺失 → `MissingBiosDialog`（见 §15.4）。

**业务流程 `_launch`（`534-576`）**
```
用户点「开始游戏」/「继续游戏」
  → SystemFiles.syncAll + missingForCore 做 BIOS 门禁
  → 若缺 BIOS：showDialog(MissingBiosDialog) 并 return（barrierDismissible:false）
  → 否则 widget.pal.launchEmulator(relativePath, coreId, platform: entry.platform.name)
```
**设计要求**：网格列数随屏宽响应式（竖屏多列 / 横屏行）；卡片需显示封面、标题、徽章（双人/金手指/存档）；`继续游戏` 卡片仅在存在「上次游戏」且「记住上次游戏」开启时出现。订阅 `appRouteObserver` 在 pop 上层页后刷新（`didPopNext`，`131-133`）。

### 15.4 MissingBiosDialog（缺失系统文件）

**文件**：`features/library/missing_bios_dialog.dart:11-140`
- `barrierDismissible:false`；标题 `缺少系统文件（BIOS）`（`83`）。
- 正文：`运行「${gameTitle}」需要以下系统/BIOS 文件…本应用不内置任何受版权保护的文件…` + 缺失文件名列表（warning 图标，`89-92`）。
- actions：`TextButton`(`取消`)（`120-123`）；`FilledButton.icon`(`file_open`，`批量选择`) → `pal.importBiosBatchViaSaf`（`124-136`）。
- **设计要求**：必须阻断启动；批量选择后回到文件库应刷新 BIOS 横幅。

### 15.5 SettingsSheet（设置 · 半屏底部弹层）

**文件**：`features/settings/settings_sheet.dart:22-325`
- 打开：`SettingsSheet.show` → `showModalBottomSheet(isScrollControlled, showDragHandle)`（`25-32`）。标题 `设置`（`127`）。

| 区块 | 控件（精确标签） | 行为 |
|---|---|---|
| 关于卡 | `趣玩匣 GamePouch` + 版本 `${versionName} (${versionCode})`（`146-159`）；`本应用不内置任何游戏 ROM 或 BIOS…`；内核说明（`173`） | 只读 |
| 游戏体验（`190-210`） | `SwitchListTile`：`显示 FPS / xruns 浮窗`（`在游戏画面正中央叠加性能指示器`）/ `高刷新率（120 Hz）`（`支持时优先使用最高刷新率以降低拖影`）/ `加速时同步音频`（`关闭后加速时静音，换取更稳定的帧率`） | 实时写 `AppSettings` |
| 控制 | `_StickSettingsCard`（`692-805`）：`SegmentedButton` 三段 `全向`/`8 向`/`4 向`；`死区` `Slider(0.0–0.45)`；`SwitchListTile` `使用虚拟十字键（替代摇杆）` | 映射原生 `stickMode`/`stickDeadzone`/`useDpadUi` |
| 控制·布局 | `_PadLayoutCard`（`809-1003`）：`虚拟手柄布局`；`恢复默认`；3 个 `Slider`：`整体缩放 0.5–2.5` / `水平平移 -0.45–0.45` / `垂直平移 -0.45–0.45`；`导入配置`/`导出配置` | 映射 `padScale`/`padOffsetX/Y` |
| 控制·招式 | `ListTile`(`bolt_outlined`，`招式按键（格斗游戏一键大招）`，`配置 6 个槽位的招式脚本…`，`chevron_right`) → push `SpecialMovesEditorPage`（`242-256`） | — |
| 系统文件(BIOS) | `_BiosManagerCard`（`362-613`）：`刷新`；`批量导入`(`file_open`)/`导出全部`(`ios_share`)；已装/缺失/其他 三段；单项删除 `_deleteOne` → `AlertDialog` `删除 ${name}？`（`469-481`） | — |
| 应用（`273-309`） | `SwitchListTile` `记住上次游戏`/`深色主题`；`ListTile`(`description_outlined`，`开源许可`)→ `AlertDialog` `开源许可`(SelectableText)；`ListTile`(`privacy_tip_outlined`，`隐私政策 / 用户协议`)→ push `PrivacyPolicyPage` | — |
| 页脚 | `趣玩匣 GamePouch · 让历史更安心`（`313-317`） | — |

**设计要求**：设置项与 §11 原生持久化 key 必须一一对应（否则原生读不到）；开关文案、Slider 范围、默认值须 1:1。

### 15.6 SpecialMovesEditorPage（招式按键编辑器）

**文件**：`features/settings/special_moves_editor.dart:17-610`
- **用途**：6 槽位格斗招式脚本编辑 / 导入导出 / 重置。
- **AppBar（`421-448`）** 标题 `招式按键`；actions：`file_download_outlined`(`tooltip 导入`)→`_importFromSaf`；`file_upload_outlined`(`tooltip 导出`)→`_exportToSaf`；`restart_alt_outlined`(`tooltip 恢复默认`)→`_resetToDefault`；`FilledButton.icon`(`save_outlined`，`保存`/`已保存`)→`_save`（`442-445`）。
- 正文：「当前预设」卡 `DropdownButtonFormField`（label `${p.label} (${p.moves.length} 个按键)`，`'当前预设'`）；新增预设 `TextField`(`新增预设名称`) + `FilledButton.tonalIcon`(`add`,`添加`)；`TextButton.icon`(`delete_outline`,`删除当前预设`)。「预设名称」卡 `TextFormField`；「招式槽（6 个）」卡：语法说明 `脚本语法：方向用数字 1-9…` + `_DirectionKeyMap`（`720-778`，3×3 小键盘参考）；6 个 `_SlotEditor`（`612-713`）：每槽 `TextFormField`(maxLength 2, 标签) + `TextFormField`(hint `例：236+P`, errorText)。
- 弹窗：`_exportToSaf` 若 dirty → `AlertDialog` `尚未保存`（`先保存再导出吗？`，`取消`/`保存并导出`，`303-318`）；`_resetToDefault` → `AlertDialog` `重置为默认`（`将覆盖当前所有自定义预设…`，`取消`/`重置`，`392-403`）。
- **设计要求**：语法与 Android `SpecialMovesStore.ScriptCompiler` 一致（小键盘 1-9 方向 + `,` 分步 + `+` 接按键 `P/H/L/K`，每步 3 帧）；默认预设 `kof97`（波 236+P / 升 623+P / 旋 214+K / 超 236236+PK / 避 66 / 滚 44）。详情见原生 §2.7。

### 15.7 AccountPage（账号与云服务）

**文件**：`features/account/account_page.dart:17-847`
- **AppBar（`502`）** 标题 `账号与云服务`。
- 未登录 `_buildLogin`（`728-846`）：`TextField`(`服务器地址`, hint `http://192.168.1.10:8848`, `dns_outlined`, 后缀 `travel_explore` 探测)；`TextButton.icon`(`travel_explore`,`不知道地址？自动探测`)；`SegmentedButton` `登录`/`注册`；`TextField`(`用户名`,`person_outline`)/`密码（6~64 位）`(obscure)；`OutlinedButton.icon`(`connect_without_contact`,`发现伙伴：手机面对面互传游戏`)→`_openPeers`；`FilledButton.icon`(`login`,`登录`/`注册并登录`)→`_submitAuth`；编辑服务器 `TextButton` `仅保存服务器地址`；hint `adb reverse tcp:8848…`。
- 已登录 `_buildProfile`（`533-709`）5 个 section 卡：
  1. **当前账号**：头像 + 用户名 + `管理员`/`普通用户` chip + 服务器 URL chip。
  2. **云文件库**（`573-603`）：`浏览 / 订阅文件库`(`video_library_outlined`)→ push `CloudLibraryPage`；`立即网络同步`(`cloud_sync`)→ `_doSync`(CloudSync 弹窗)；`上次同步目录版本：r${lastRevision}`。
  3. **发现伙伴**（`604-620`）：`发现伙伴`(`connect_without_contact`)→ `_openPeers`。
  4. **应用升级（OTA）**（`621-659`）：`ChoiceChip` `稳定版`/`测试版`；`canSelfUpdate` 时 `检查更新`(`download_outlined`)→ `_checkUpdate`，否则 `前往应用商店`(`store_outlined`)→ `_openStorePage`。
  5. **服务器与登录**（`661-702`）：`重新探测服务器`/`更换服务器地址`/`修改密码`(`key_outlined`)→ `_changePassword`/`退出登录`(`logout`)。
- 弹窗：改密码 `AlertDialog` `修改密码`（3 个 obscure `TextField` `当前密码`/`新密码（6~64 位）`/`确认新密码`，`取消`/`确定`，`149-180`）；检查更新 `AlertDialog` `发现新版本 v${versionName}`（版本/渠道/大小/notes/强制标记，`稍后`/`立即更新`，`345-369`）→ 下载 `Dialog`（进度条，失败 `下载失败：…`/`关闭`，`406-487`）→ `pal.installApk`；页脚 `趣玩匣 GamePouch · 局域网私有云服务`（`705`）。
- **业务流程**：账号页是「云 ROM 下载 + 设备间同步 + OTA + 伙伴入口」的中枢。

### 15.8 CloudSync 进度弹窗 / 15.9 CloudLibraryPage

- `cloud_actions.runCloudSync`（`cloud_actions.dart:9-96`）：`showDialog(barrierDismissible:false)`，`Dialog` 标题 `网络同步`（`cloud_sync`），`Text(stage)`(`准备中…`) + `LinearProgressIndicator`；失败 `同步失败：$error` + `关闭`（`72-85`）。
- `CloudLibraryPage`（`cloud_library_page.dart:10-294`）：AppBar 标题 `云文件库`，actions `cloud_sync`(`保存订阅并立即同步`, 仅 dirty) / `refresh`；FAB `bookmark_added`(`保存订阅（${_pending.length}）`)；搜索 `搜索云文件库 / 双人 / 金手指 / 存档…`；计数 `共 ${items} 款，已订阅 ${_pending} 款`；`CheckboxListTile`(`videogame_asset_outlined`)：title=游戏名，subtitle=`平台 · 类型 · 发行日期 · 金手指 n`；空态 `服务器还没有发布任何游戏…`；保存后 `SnackBar` `订阅已保存（${crcs} 款游戏）`（`88-90`）。
- **设计要求**：订阅是「元数据 + 按需同步」模型；勾选订阅后由 `CloudSyncer.sync()` 落地到 `filesDir`。

### 15.10 PeersPage（发现伙伴）/ 15.11 PairDialog

- `PeersPage`（`peers_page.dart:20-574`）：AppBar 标题 `发现伙伴`，`refresh`(`重新扫描`)。「本机」卡 `_selfCard`（`本机：${selfName}` + 状态 + `edit_outlined` 改名）；端口占用警告横幅；在线 `在线伙伴（n）`/离线 `已配对 · 当前离线（n）`；`_peerTile`：已配对 → `TextButton` `文件库`→ push `PeerLibraryPage` + `PopupMenuButton` `解除伙伴`；未配对 → `FilledButton` `配对连接`→ `InitiatorPairDialog`；`_offlineTile` `解除`。弹窗：`解除伙伴` `AlertDialog` `解除伙伴`；`修改本机设备名` `AlertDialog` `修改本机设备名`(`maxLength 24`)；收到配对 → `ResponderPairDialog.show`；发起 → `InitiatorPairDialog.show`；收到联机邀请 → `PlayInviteDialog.show` → 接受 push `PlayLobbyPage`。
- `PairDialog`（`pair_dialog.dart:42-444`）：
  - **Initiator（A）**：`Dialog`(`PopScope(canPop:false)`) 标题 `与「${peerName}」配对`；阶段 starting/error/code/waiting；code 阶段：`请与对方核对两台手机上的 6 位数字完全一致：` + 大号分组码 `${_groupCode(code)}`（如 `042 917`）+ `FilledButton.icon`(`check_circle_outline`,`码一致，确认连接`) + `OutlinedButton` `取消`；waiting 阶段转圈 + `正在等待对方确认…`；错误 `对方取消了配对`/`配对已超时，请重新发起`/`错误次数过多…`/`配对失败（${code}）`/`等待对方确认超时，请靠近后重试`。
  - **Responder（B）**：标题 `${initiatorName} 请求配对`；`FilledButton.icon`(`check_circle_outline`,`码一致，确认连接`) / `OutlinedButton` `拒绝`；waiting `已确认，正在等待对方点击确认…`。
- **业务流程**：局域网 UDP 广播发现（`GP-PEER-PING`/`GP-PEER-PONG`，端口 43801）→ HTTP 配对（6 位分组码）→ 配对成功后进入对方库导入。

### 15.12 PeerLibraryPage + _ImportFlowPage（4 步导入）

**文件**：`features/peer/peer_library_page.dart:24-683`（+ 内嵌 `_ImportFlowPage 969-1916`）
- AppBar 标题 `${peerName} 的文件库`；actions `TextButton` `全选`/`清除选择`。
- 正文：`正在读取伙伴的文件库…`；凭据失效 `_hint`(`no_encryption_outlined`,`伙伴凭据已失效`) + `解除本地伙伴记录`；空态；搜索 `搜索对方游戏名 / 双人 / 金手指 / 存档…`；平台 `ChoiceChip`；网格 `_RemoteGameCard`：封面/标题/徽章（`双人合作`/`双人对战`/`轮流上场`/`金手指`/`存档`/`本机已有`）+ 联机 chip（`联机玩`/`暂不可联机`+ Tooltip）；点卡片切换选择。
- `bottomNavigationBar`：`导入所选（${n}）`(`download_outlined`)→ push `_ImportFlowPage`。
- **`_ImportFlowPage` 4 阶段（`_Stage`=configure/conflicts/progress/summary）**：
  - **configure**：合规提示条；`街机 BIOS 同步` 卡（`CheckboxListTile`，本机已有显示 `本机已有，将自动跳过`）；每游戏 `_gameConfigCard`：`CheckboxListTile` `ROM（本机已有相同游戏）`/`ROM（含封面与游戏资料）`/`金手指`/`电池存档（.sav）`/`自动快照`/`手动槽位 n（含缩略图）`（运行中游戏显示 `该游戏正在模拟器中运行，请先退出游戏后才能导入存档`）；底部 `已选 n 款游戏 · 预计 xxx（另保留 16MB 安全余量）`。
  - **conflicts**：分段 `新增内容（n）`/`ROM（本机已有，n）`/`金手指冲突（n）`/`存档冲突（n）`/`已拦截（n）`；`SwitchListTile` `对全部金手指冲突选择「覆盖」`/`对全部存档冲突选择「覆盖」（危险）`；存档冲突红警 `⚠ 覆盖存档会永久丢失本机对应进度…`；`RadioGroup` `跳过（默认）`/`覆盖`；底部 `待传输约 xxx（另保留 16MB 余量）`。
  - **progress**：`Dialog`式居中 `游戏 ${p.gameIndex}/${p.gameCount}` + 字节/速率 + `停止（已完成的项目会保留）`；失败 `空间不足…`/`导入出错…`。
  - **summary**：`导入结束` + 行 `新增/覆盖/跳过/失败/传输字节` + 失败项列表 + `重试失败项` + `完成`。
  - 合规风险提示 `_confirmCompliance` `AlertDialog` `合规风险提示`（传输前必确认一次）。
- **设计要求**：导入是拉取式（导入方经 HTTP 从对方 `/api/peer/rom/$crc` 等下载）；CRC32 + 大小完整性门禁；已传过不重传；冲突默认跳过（非覆盖）。

### 15.13 PlayInviteDialog / 15.14 PlayLobbyPage

- `PlayInviteDialog`（`play_invite_dialog.dart:12-98`）：`showDialog(barrierDismissible:false)`，`AlertDialog`(`sports_esports`,`联机游戏邀请`)；`${romName}`/`来自：${fromName}`/`街机 · 你将作为 2P 加入`/`NES / FC · 你将作为 2P 加入`/`邀请 ${seconds} 秒后自动过期`（每秒倒数，超时 `pop(timeout)`）；actions `TextButton` `拒绝` / `FilledButton` `接受`。
- `PlayLobbyPage`（`play_lobby_page.dart:17-651`）：AppBar 标题 `联机大厅`（`automaticallyImplyLeading:false`，`取消` TextButton）；`PopScope(canPop:!_launching)`；`_gameHeader`（封面 + `${romName}` + `${_coreLabel()} · 双人联机`，`街机（FBA）`/`街机（MAME）`/`NES / FC`）；`_slotCard` `P1`/`P2` + `主机`/`对方`/`客机` + ready；`_networkCard` `直连网络探测`：`RTT 中位`/`RTT P95`/`建议延迟 D`（`D = 每方额外等待的帧数…`）；`_statusLine` 多种文案（`正在等待 ${peerName} 接受邀请（60 秒内有效）…`/`客机已准备，可以开始游戏`/`请点「准备」…`/`正在同步存档并启动…`/`对局进行中`）；操作区：主机 `开始游戏`(`play_arrow`)→`_hostStart`；客机 `准备`(`check`/`sports_esports`)→`_guestReady`；starting `正在启动模拟器…`；底部说明 `请双方连接同一 Wi-Fi…数据仅两台手机直连…`；结束遮罩 `_terminalOverlay`（按 `endReason` 显示 `对方拒绝了邀请`/`邀请已超时`/`会话已取消`/`对方已结束会话`/`对局已结束`/`会话异常结束：…` + `即将返回…`，1.8s 后 `maybePop`）。
- **业务流程**：邀请 → 接受 → 大厅 → RTT 探测 → 主机「开始游戏」/ 客机「准备」→ `pal.launchEmulator` 并带 `netplay` 参数（`role/peerIp/peerPort/localPort/sessionKey/roomId/initialD/bootstrapPort/saveKey`）→ 原生 `EmulatorActivity` 解析 `np_*` extras 启动 netplay 会话。
- **设计要求**：联机确定性要求——禁用金手指与宏；单台设备只能为单端口；大厅状态文案需 1:1。

### 15.15 法律 / 协议与同意门

- `ConsentGate`（`consent_gate.dart:11-100`）：独立 `MaterialApp`（theme 同）；标题 `欢迎使用 趣玩匣 GamePouch`；正文 `本应用为复古游戏模拟器，不内置任何游戏、ROM 或 BIOS 文件…` + `· 隐私政策…` `· 用户协议…` + `点击「同意并继续」即表示…`；`TextButton` `查看隐私政策`/`查看用户协议` → push；`OutlinedButton` `不同意并退出`→`SystemNavigator.pop()`；`FilledButton` `同意并继续`→ 写 `consent_given` 后 `onAccept`→`runApp(GamePouchApp)`。
- `PrivacyPolicyPage`（`privacy_policy_page.dart:4-47`）：AppBar `隐私政策`，`SelectableText` 模板（1–6 章）。
- `EulaPage`（`eula_page.dart:4-39`）：AppBar `用户协议`，`SelectableText` 模板。
- **设计要求**：首次启动必须过同意门；复刻时隐私/协议正文可引用同一模板。

### 15.16 导航总览（全部匿名 push/pop）

| 源 | 目标 | 方式 |
|---|---|---|
| home | `LibraryPage` | `MaterialApp.home` |
| `LibraryPage` | `AccountPage` | push（回调 `_reload`） |
| `LibraryPage` | `SettingsSheet` | 半屏底部弹层 |
| `LibraryPage` | `MissingBiosDialog` | showDialog |
| `LibraryPage` | 详情 | 竖屏 bottomSheet / 横屏 Dialog |
| `SettingsSheet` | `SpecialMovesEditorPage` | push |
| `SettingsSheet` | `PrivacyPolicyPage` | push |
| `SettingsSheet` | 开源许可 / BIOS 删除 | AlertDialog |
| `AccountPage` | `CloudLibraryPage` | push |
| `AccountPage` | `PeersPage` | push |
| `AccountPage` | 同步 / 改密 / 更新 | Dialog / AlertDialog |
| `CloudLibraryPage` | （pop true → AccountPage 触发同步） | pop |
| `PeersPage` | `PeerLibraryPage` | push |
| `PeersPage` | `PlayLobbyPage` | push（受邀） |
| `PeersPage` | 配对/解除/改名 | showDialog / AlertDialog |
| `PeerLibraryPage` | `_ImportFlowPage` | push |
| `PeerLibraryPage` | `PlayLobbyPage` | push（发起主机） |
| `_ImportFlowPage` | （pop bool → PeerLibraryPage） | pop |
| 任何 | 模拟器 | 原生 Activity（`pal.launchEmulator`） |

---

## 16. 业务流（数据层 / 持久化 / 原生桥）

### 16.1 ROM 库模型与导入

**`RomEntry`（`domain/rom_entry.dart:206-337`）**
- 必填：`name`/`originalName`/`relativePath`/`size`/`crc32`/`importedAt`/`platform:PlatformKind`。
- 可选元数据（PC/云同步而来）：`genre`/`developer`/`publisher`/`releaseDate`/`region`/`players`/`description`/`category`/`coverRelative`。
- 瞬态：`cheats`（永不写回）。方法：`crcKey`（8 位大写 hex CRC32，元数据 key）、`displayTitle`（渲染期解码百分号转义）、`toJson`/`fromJson`。
- `enum PlatformKind`（`5-72`）：`coreId` getter → nes=`fceumm`、gameBoy=`gambatte`、gba=`mgba`、atari2600=`stella2014`、masterSystem/genesis=`picodrive`、mame/neogeo=`appChannel.isStore ? 'mame' : 'fbalpha2012'`。`platformFromExtension`（按 zip 父目录段识别 CPS1/CPS2→mame、neogeo→neogeo；纯 `.zip` 默认 neogeo）。

**持久化（`data/rom_library.dart`）**：库索引是**单个 JSON 文件** `rom_index.json`（`$filesDir/rom_index.json`）；快照 `library/metadata.json`（PC ADB）、`library/cloud_metadata.json`、`library/cheats.json`、`library/cloud_cheats.json`。`load()` 损坏时复制 `.corrupt-<ts>.json` 回退空库；`_applyMetadata()` 按 `crcKey` 合并（索引优先，cloud 次之）；`upsert()` 按 `relativePath` 幂等去重+排序；`remove()` 删实体文件。**无目录自动扫描**——库完全由 `rom_index.json` 驱动。

**三种导入路径**
1. **SAF 单 ROM**：`library_page._import()` → `pal.importRomViaSaf()` → `gs/storage "importRomViaSaf"` → `MainActivity` → 流式算 CRC32 + NES 头检测 → 落地 `filesDir/roms/<safeName>`，`relativePath="roms/<safeName>"`。
2. **ZIP / 资源包**：`_importPackage()` → `importPackageViaSaf` → `importZipPackage` 写 `import_cache` → `GamePackage.importPackage` 自动识别「gamepouch 资源包」vs「纯 ROM zip」。
3. **云同步**：`cloud_sync.CloudSyncer.sync()` 从服务器拉取 rom/cover/cheats 落地。

**ROM 物理位置**：`filesDir`（应用私有 `getFilesDir()`）；ROM 在 `filesDir/roms/`；存档每核心 `saveDir`（`<saveDir>/<saveKey>.sav`）；BIOS 在 `filesDir/system/`。

### 16.2 设备间传输（LAN 备份/恢复）

**Wi-Fi LAN（非 Direct）**：UDP 广播发现 + 配对 + HTTP 文件传输。
- 发现（`data/peer/peer_discovery.dart`）：`PeerResponder` 绑 **43801**，应答 `GP-PEER-PONG`；`PeerScanner.scan()` 每 700ms 广播 `GP-PEER-PING`；仅 `wlan*` 接口；多播锁经 `gs/storage acquireMulticastLock` 在伙伴页打开时持有。
- 配对（`data/peer/peer_client.dart`）：`PeerClient` 封装 `Authorization: Peer <token>`；`startPair`/`confirmPair`(长轮询)/`cancelPair`。
- 传输（导入方发起 HTTP 拉取）：`downloadRom('/api/peer/rom/$crc')`、`downloadCover`/`downloadCheats`/`downloadSave('/api/peer/save/$crc?kind=')`/`biosList`/`downloadBios`；`PeerImporter.execute()` 逐个下载，`_verifyCrc`+`_verifySize` 完整性门禁，已传不重传。服务端 `peer_server.dart` `HttpServer.bind(anyIPv4,0)`，路由 `/api/peer/{info,library,rom/$crc,cover/$crc,cheats/$crc,save/$crc?kind=,bios,bios/$name}`，`/play/*` 复用为联机信令。
- **离线导出**：`library_page._exportSelected()` → `GamePackage.buildPackage` → `exportPackageViaSaf` 让用户存盘（USB/蓝牙/微信等）。
- **UI 入口**：`peers_page`（发现）、`peer_library_page`（从伙伴库导入）、设置内 BIOS/招式/手柄布局的导入导出。

### 16.3 更新器（OTA）

- 触发：`account_page._checkUpdate()` 手动触发（`store` 渠道走 `_openStorePage`→`pal.openStore`）。
- 流程：`_client.checkUpdate(versionCode, _channel)` → 有更新弹 `AlertDialog`(`发现新版本 v${versionName}`，含版本/渠道/大小/notes/`r.mandatory` 强制) → `_downloadAndInstall` → 下载 `Dialog`（进度条）；落盘 **`$filesDir/updates/update-v<versionCode>.apk`**；**SHA256 校验**（无则取消）；**禁止降级**；完成 `pal.installApk(path)`。
- 原生 `gs/updater`：`getVersion`(`packageManager.getPackageInfo`) / `installApk`(经 `GsApkProvider` FileProvider 调系统安装器) / `openStore`(`market://details?id=` 或回退 `appgallery.huawei.com`)。

### 16.4 联机（Netplay）

- **协议**：**输入广播 + 帧锁定（lockstep），非 rollback**。原生 JNI `NativeBridge.nativeNetplayStart(cfgJson)` 接收 `{role, peerIp, peerPort, localPort, sessionKeyHex, roomId, initialD, framePeriodSec, adaptive}`；`nativeNetplayLocalMask` 广播本机 retropad；`nativeNetplayStateHash`(FNV-1a64 确定性检查点)；`nativeNetplayFlushSram`（主机写盘）。`PlayProtocol.initialDelay=2`，`adaptive` 可降到 1；**netplay 下禁用金手指与宏**（确定性）。
- 信令复用 peer HTTP：`/api/peer/play/{invite,accept,decline,cancel,ready,start,bye}`。
- 大厅/邀请：`PlayInviteDialog`（guest 接受/拒绝/超时 60s TTL）；`PlayLobbyPage._hostStart()` 取 `bootstrapPort=42000+Random(20000)` → 启动信令 + `_launchHost`；`_extras()` 组装联机 map：`role,peerIp,peerPort,localPort,sessionKey,roomId,initialD,adaptive,bootstrapPort,saveKey(=romCrc)`。
- 交给原生：`launchEmulator` → `gs/emulator "launch"` 带 `netplay` extras → `MainActivity` 填 intent `np_*` → `EmulatorActivity.NetplaySessionCfg.from(intent)` → `hostBootstrap()` 起 `PlayBootstrapServer` 交换开局状态 `state0` → `nativeNetplayStart`；guest 用 `PlayBootstrapClient` 拉取。会话结束 `notifyDartPlayEnded`(`gs/netplay "playEnded"`) → `PlaySessionManager.notifyNativePlayEnded`。

### 16.5 设置持久化与手柄映射

**`AppSettings`（`features/settings/app_settings.dart`，shared_preferences）** key 常量（`179-189`）：`showFpsHud`/`highRefreshRate`/`fastForwardAudio`/`rememberLastGame`/`darkTheme`/`stickMode`/`stickDeadzone`/`useDpadUi`/`padScale`/`padOffsetX`/`padOffsetY`。注意 `stickDeadzone`/`padScale`/`padOffsetX/Y` 以**纯文本 String** 存（因 `setDouble` 会 base64 致原生 `getFloat` 崩溃，`_decodeDeadzone`/`_decodeFloat` 兼容）。`lastSaveSlot` 不在类内，直接读写 key `'flutter.lastSaveSlot'`。

**映射到原生（`EmulatorActivity.applyPersistedSettings()`）**：逐项读 `FlutterSharedPreferences.xml` → `hud.visibility` / `pad.stickMode`(STICK/DPAD4/DPAD8) / `pad.deadzone` / `pad.useDpadUi` / `pad.padScale`(clamp 0.5–2.5) / `pad.padOffsetX/Y`(clamp ±0.45) / `fastForwardAudioPref` / `rememberLastGame+lastSaveSlot → renderer.loadSlot`。详见原生 §11。

### 16.6 原生桥（MethodChannel / 平台通道）

**Flutter 侧通道名**（`platform_pal.dart:269-285`）：`gs/storage` / `gs/emulator` / `gs/updater` / `gs/netplay`（后者收 `playEnded`）。

| 通道 | Kotlin 端方法（`setMethodCallHandler`） |
|---|---|
| `gs/storage` | `getFilesDir`/`getDeviceModel`/`getAvailableBytes`/`acquireMulticastLock`/`releaseMulticastLock`/`getRunningSaveKey`/`importRomViaSaf`/`importPackageViaSaf`/`importBiosViaSaf`/`importBiosBatchViaSaf`/`exportBiosZipViaSaf`/`deleteBios`/`exportPackageViaSaf`/`importMovesConfigViaSaf`/`exportMovesConfigViaSaf`/`importPadConfigViaSaf`/`exportPadConfigViaSaf` |
| `gs/emulator` | 仅 `launch` |
| `gs/updater` | `getVersion`/`installApk`/`openStore` |
| `gs/netplay` | 仅原生→Dart `playEnded` |

- **启动模拟器**：`RomLibrary._launch` → BIOS 门禁 → `pal.launchEmulator(relativePath, coreId, platform)` → `gs/emulator "launch"` 参数 `{rom, core, platform, bench?, netplay?}` → `MainActivity` 转 Intent：`rom`/`core`(默认 `fceumm`)/`platform`；`bench{rom,id,seconds}`→`bench_*`；`netplay{...}`→`np_*`。
- **运行时控制**：**Flutter 侧没有运行时通道**（暂停/按键由原生 UI 处理）。运行时全走 JNI `NativeBridge` 绑定 `libgsrunner.so`：`nativeInit`/`nativeSetButtons`(retropad 位掩码)/`nativePlayMacro`/`nativeClearMacro`/`nativeSetPlayerPort`/`nativeRunFrame`/`nativeStartPacing`/`nativePumpFrame`/`nativeSetAudioPaused`/`nativeSetPaused`/`nativeSetSpeed`(×2/4/6/8)/`nativeSetCheats`/`nativeSaveState`/`nativeLoadState` 及 netplay 系列。
- **`EmulatorActivity` Intent extras**：基础 `rom`/`core`/`platform`/`bench_*`；联机 `np_role(0/1)`/`np_peer_ip`/`np_peer_port`/`np_local_port`/`np_session_key`(64 hex)/`np_room_id`/`np_initial_d`(默认2,clamp1–2)/`np_adaptive`/`np_bootstrap_port`/`np_save_key`（由 `NetplaySessionCfg.from` 读取校验）。

### 16.7 合规（R1）原则

应用**不内置任何游戏 ROM / BIOS / 受版权保护文件**（设置卡、同意门、缺失 BIOS 弹窗均明示）；所有 ROM/BIOS 由用户自合法备份经 SAF/云/伙伴导入；复刻须保留此合规边界（仓库 `.gitignore` 已排除 `*.so`/`third_party`/`cores/`）。

---

## 17. 业务测试验收清单

> 覆盖「功能正确性 + 1:1 复刻」双目标。每项给出触发路径与预期。

**文件库 / 导入**
- [ ] 冷启动进入 `趣玩匣文件库`；深色主题、浅蓝主色。
- [ ] 右上云图标→`账号与云服务`；`more_vert`→三项导入菜单文案精确。
- [ ] `导入 ROM（单文件）`→ SAF 选文件 → 网格出现新卡，CRC32 正确，落 `filesDir/roms/`。
- [ ] `导入游戏资源包 / ZIP`→ 自动识别 gamepouch 包 / 纯 ROM zip。
- [ ] 搜索 `双人`/`金手指`/`存档` 能按徽章/关键字过滤；排序 4 项、平台/分类筛选生效。
- [ ] 长按需 `选择游戏并导出资源包`→ FAB `导出资源包（n）`→ 选项勾选 → 系统存盘。
- [ ] 缺 BIOS 时启动街机 → `缺少系统文件（BIOS）` 阻断 + `批量选择` 可导入后刷新横幅。

**详情 / 启动**
- [ ] 点卡 → 竖屏 bottomSheet / 横屏 Dialog；kv 行 + 金手指段 + `开始游戏`/`删除`。
- [ ] `开始游戏`→ 经 `gs/emulator launch{rom,core,platform}` 进入原生模拟器；platform 决定面板（kof97→NEOGEO 四键+招式，CPS→MAME 六键）。

**设置**
- [ ] 设置弹层区块齐全：关于/体验(3 开关)/控制(摇杆分段+死区+十字键+布局3滑块+招式)/BIOS 管理/应用(记住上次/深色/许可/隐私)。
- [ ] 摇杆 `全向/8向/4向`、死区 0–0.45、布局缩放 0.5–2.5/平移 ±0.45 改动后原生手柄实时生效（对应 §11 key）。
- [ ] `招式按键`→ 6 槽编辑，语法提示、导入/导出/重置/保存 4 个弹窗文案精确；保存后 NEOGEO 招式面板数据更新。

**账号云 / 同步 / OTA**
- [ ] 未登录显示服务器地址 + 自动探测 + 登录/注册 + 发现伙伴。
- [ ] 登录后 5 段卡齐全；`浏览/订阅文件库`→ 勾选订阅→ `保存订阅`→ `立即网络同步` 进度条→ 库新增。
- [ ] `检查更新`→ 有更新弹 `发现新版本`(含强制标记)→ 下载进度→ `installApk`；`store` 渠道走应用商店。

**伙伴 / 联机**
- [ ] `发现伙伴`→ 局域网扫描出在线伙伴；`配对连接`→ 6 位分组码双端一致确认。
- [ ] 已配对→`文件库`→ 多选→ `_ImportFlowPage` 四阶段（configure 合规提示/conflicts 默认跳过/进度/summary）；CRC 校验、冲突不覆盖、已传不重传。
- [ ] 从伙伴库对联机游戏 `联机玩`→ 对方收 `联机游戏邀请`(60s TTL)→ 接受→ `联机大厅`（RTT 探测 + 槽位 + 准备/开始）→ `pal.launchEmulator(netplay)`；联机下金手指/宏禁用。

**法律**
- [ ] 首次启动过 `同意并继续`（隐私/协议可查看）；`consent_given` 后不再弹。

**原生桥回归**
- [ ] `gs/emulator launch` 的 `platform` 字段与 kof97 NEOGEO 面板一致；1P/2P 仅驱动选中端口（见原生 §6.9 + 本文档原生部分）。
- [ ] 切后台/返回不「粘键」；联机会话结束 `gs/netplay playEnded` 回传 Dart 并自动返回伙伴页。

---

## 18. 鸿蒙（OpenHarmony / HarmonyOS NEXT）移植对照与已知缺口

> 鸿蒙版**共享同一套 Flutter/Dart UI 与 libretro 抽象**（`app/lib` 跨端共用），差异仅在原生层：
> Flutter 侧经 `OhosPal`（`app/lib/pal/ohos_pal.dart`）调用与安卓同名的四个 MethodChannel
> （`gs/storage` / `gs/emulator` / `gs/updater` / `gs/netplay`），原生侧由 ArkTS 插件
> `GamePouchPlugin.ets` + NAPI 宿主 `gpretro.cpp`（XComponent 内跑 libretro）承接。
> 本节约以 §15–§17 为基准，列出已对齐项、本次补齐项与尚未实现项。

### 18.1 已对齐（原生桥已实现）

| 能力 | 安卓（Kotlin） | 鸿蒙（ArkTS/NAPI） | 位置 |
|---|---|---|---|
| 文件目录 | `MainActivity.getFilesDir` | `GamePouchPlugin.filesDir` | `GamePouchPlugin.ets:117` |
| ROM/资源包/BIOS 导入 | SAF | `@ohos.file.picker` 选文件 → 拷入 `filesDir` | `GamePouchPlugin.ets:351-416` |
| BIOS 批量导入 / 导出 zip / 删除单 BIOS | SAF | 同左 | `:196-208, 467-508, 438-463` |
| 招式/手柄布局 导入导出 | SAF JSON | 同左（写 `library/imports/`） | `:199-241` |
| 启动模拟器 | `gs/emulator launch` → Intent | `gs/emulator launch` → `router.pushUrl(EmulatorSpike)` + `setEmulatorTarget` | `:264-296` |
| 版本号 / OTA 查询 | `gs/updater getVersion` | `bundleManager.getBundleInfoForSelfSync` | `:301-312` |
| 虚拟手柄 | VirtualPadView（Kotlin 自绘） | EmulatorSpike.ets（ArkUI 自绘，位定义与安卓 1:1） | `EmulatorSpike.ets` |
| 平台→core 映射 | `RomEntry.coreId` | `GamePouchPlugin.coreForRom`（同算法） | `:230-241` |
| 存档/读档（3 槽）、倍速、复位、FPS HUD、金手指 | `EmulatorActivity` + JNI | `gpretro.cpp` NAPI：`saveStateSlot/loadStateSlot/getFps/setSpeed/resetEmu` + `GetCheats/SetCheats` | `gpretro.cpp:1495-1515` |
| NEOGEO 招式面板（波/升/旋/超/避/滚，1:1 移植） | `buildFightAssist` | `EmulatorSpike.movesPanel`（含 P/K 按键位修正） | `EmulatorSpike.ets` |

### 18.2 本次补齐（2026-10-21）

1. **金手指弹窗崩溃修复**：`gpretro.cpp` 原 `napi_define_properties(env, exports, 14, desc)` 只注册了 16 个导出中的 14 个，`getCheats`/`setCheats`（idx 14–15）未注册，导致金手指弹窗运行时抛 `is not a function`。改为注册 **16** 个。
2. **设置项真正生效（手柄配置桥）**：此前鸿蒙原生手柄只读自己的 `settings.json`（仅 `stickMode`/`padScale`），**忽略** Flutter `SettingsSheet` 写入的 `AppSettings`，因此「死区 / 虚拟十字键 / 手柄平移」对鸿蒙无效。本次在 `OhosPal.launchEmulator` 把 `AppSettings.current` 的 6 个手柄字段塞进 `launch` 载荷 → `GamePouchPlugin.writePadSettings` 写入 `settings.json` → `EmulatorSpike.loadSettings` 读取并应用（`stickDeadzone`、`useDpadUi` 强制十字键渲染、`padOffsetX/Y` 整体平移手柄）。新增字段默认值等于原硬编码值，**零回归**。对应安卓 `EmulatorActivity.applyPersistedSettings()`（§16.5）。
3. **`runningSaveKey` 上报当前 ROM CRC**：此前恒返回 null（peer 导入存档锁失效）。现经 `gpretro.getRomCrc()` 返回 8 位 hex CRC，使伙伴导入能锁定运行中的游戏存档（对应 §16.2）。
4. **游戏资源包导入失败修复（2026-10-21，Pura 70 真机复现）**：原 `GamePackage.importPackage` 用 `zip.readAsBytes()` + `ZipDecoder().decodeBytes(bytes)`，把整个 zip（含每个条目的压缩数据）一次性载入内存。70 个游戏的资源包体积数百 MB，在手机上被系统低内存杀手强杀 → 表现为「无法导入游戏资源包」。导出路径此前已改流式，导入漏改。修复：改用 `InputFileStream(zip.path)` + `ZipDecoder().decodeBuffer(input)` 流式解码（条目内容按需惰性解压，峰值内存只占用单个 ROM）。同时修复 OHOS 相对路径解析：`library_page._importPackage` 原用 `File(pkg.path)`（相对路径，仅安卓 CWD==filesDir 时可用），改为 `File('$_filesDir/${pkg.path}')` 绝对路径，消除鸿蒙侧解析不到文件的问题。真机验证：在沙箱内自建 150 MB zip 并走真实 `importPackage` 路径，`entries=30 wasPackage=false`，无 OOM / 无崩溃。对应 §16.1 导入三路径。

- **联机（Netplay）**：`gs/netplay` 的 Dart→原生调用仍 `notImplemented()`；`GamePouchPlugin.parseLaunch` 仍忽略 `netplay` 块，原生不会启动联机会话（无 `PlayBootstrapServer` / `nativeNetplayStart` / lockstep 集成）。但**反向通道已接通**：`GamePouchPlugin` 现持有 `gs/netplay` 通道并新增 `emitPlayEnded()`，`gs/emulator stop` 会触发它；Dart 侧 `OhosPal._playEnds` 此前已就位。完整联机会话启动仍需专项移植（详见 §16.4）。
- **OTA 安装**：`gs/updater installApk` 在鸿蒙返回 `false`（OHOS 装 `.hap` 而非 `.apk`）；`openStore` 无等价 intent。仅 `store` 渠道走应用市场，社区渠道自更新暂不可用。
- **Wi-Fi 多播锁**：`acquireMulticastLock`/`releaseMulticastLock` 现返回 `true`（OHOS 无公开等价 API，且 `INTERNET` 权限已允许广播/多播套接字）。注意「发现伙伴」用的是 **UDP 广播** `255.255.255.255` 而非多播组，故该锁对手机同步本就无关；仅作占位避免 Dart 侧误判失败。
- **原生→Dart 回调**：已接通（见联机条 `emitPlayEnded`）。另：FPS 仍由 ArkTS 侧 2Hz 轮询 `getFps()` 获取（§15 探索结论），此部分不变。
- **手机同步（PC 库管理 ↔ Pura70）验证状态（2026-10-21）**：PC 端 `peer_host.py` 已在真机网络验证——`run_peer_server.py` 正常启动并应答 `GP-PEER-PING`、HTTP `/api/peer/info` 返回 `200 {"service":"GamePouch Peer",...}`；同网段已有另一伙伴在主动发现（日志见 `192.168.0.5`）。**设备端阻塞**：Pura70 当前 `wlan0` 仅 `UP` 无 IPv4（不在 PC 的 `192.168.0.x` 子网），故无法做真机局域网发现验证。需将 Pura70 连到与 PC 同一 Wi-Fi 后，在手机「我的 → 发现伙伴」即可发现并拉取。设备端 `peers_page`/`PeerScanner` 为纯 Dart，且 `module.json5` 已声明 `ohos.permission.INTERNET`，代码侧已具备条件。

### 18.4 鸿蒙构建 / 联调

```powershell
# 构建并签名 HAP（需 Linux 原生 OHOS SDK 自编译 libgs_mame.so，见 README §OpenHarmony）
powershell -ExecutionPolicy Bypass -File scripts\build-hap.ps1
hdc -t <sn> install -r app\build\ohos\hap\entry-default-signed.hap
hdc -t <sn> shell aa start -a EntryAbility -b com.gamepouch.gamepouch
hdc shell hilog | findstr GamePouchPlugin GPRETRO
# 验证：冷启动若走 main.dart 的 M1 自动启动，则 2s 后进入 EmulatorSpike；
# 进 kof97 验证 NEOGEO 四键 + 招式面板；改 SettingsSheet 死区/平移后重开游戏应即时生效。
```
