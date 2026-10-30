package com.retroemupouch.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.util.AttributeSet
import android.os.Build
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import java.lang.reflect.Method
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Multitouch virtual gamepad with per-platform button profiles.
 * Layout always keeps the D-pad bottom-left; the right cluster (face
 * buttons, shoulders, select/start) is built from [Profile]. Reports the
 * current RETRO pad bitmask.
 */
class VirtualPadView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    companion object {
        // RETRO_DEVICE_ID_JOYPAD_* (see libretro.h): bit = 1 shl id.
        const val BUTTON_B = 1 shl 0
        const val BUTTON_Y = 1 shl 1
        const val BUTTON_SELECT = 1 shl 2
        const val BUTTON_START = 1 shl 3
        const val BUTTON_UP = 1 shl 4
        const val BUTTON_DOWN = 1 shl 5
        const val BUTTON_LEFT = 1 shl 6
        const val BUTTON_RIGHT = 1 shl 7
        const val BUTTON_A = 1 shl 8
        const val BUTTON_X = 1 shl 9
        const val BUTTON_L = 1 shl 10
        const val BUTTON_R = 1 shl 11
        const val BUTTON_L2 = 1 shl 12
        const val BUTTON_R2 = 1 shl 13
    }

    /** Button geometry/meaning for one platform. */
    enum class Profile {
        // NES / Famicom: B, A + SELECT/START
        NES,
        // Game Boy / Game Boy Color: B, A + Select/Start
        GB,
        // Game Boy Advance: B, A + L/R shoulders + Select/Start
        GBA,
        // Atari 2600 joystick: single Fire (+ Select/Reset)
        A2600,
        // Sega Master System: 1, 2 + Pause
        SMS,
        // Sega Game Gear: 1, 2 + Start(pause)
        GG,
        // Sega Genesis / Mega Drive 3-button: A, B, C + Start
        MD,
        // M6 arcade — Capcom CPS1/CPS2 (and generic MAME) 6-button panel:
        // X Y Z over A B C, matching the real Capcom cabinet silk screen.
        // fbalpha2012 (Classic retropad) maps 3-punch/3-kick fighters to
        // Y/X/L over B/A/R; generic arcade fire1..6 maps to B/A/Y/X/R/L.
        MAME,
        // M6 arcade — SNK NeoGeo MVS/AES: the hardware panel is FIXED to
        // four candy buttons A(light punch)/B(light kick)/C(heavy punch)/
        // D(heavy kick). fbalpha2012 generic mapping puts fire1..4 on
        // retropad B/A/Y/X. Rendered 2x2 (NEOGEO mini style): A B / C D.
        NEOGEO;

        companion object {
            /**
             * Resolve the on-screen control panel.
             *
             * The panel is driven by the authoritative [platform] id
             * (`PlatformKind.name` from Dart) — that is what selects the core
             * in the first place, so it must also select the matching pad.
             * Driving the panel from the core-id string was brittle: a core
             * rename or a new core repinned to an existing platform silently
             * collapsed every arcade game to the NES 2-button layout (the
             * kof97 "looks like GBA" bug). The core id is only a tie-breaker
             * for the one core that serves several platforms (picodrive:
             * SMS/GG/MD), disambiguated by the rom file extension, and as a
             * fallback for legacy/unknown platform strings.
             */
            fun from(coreId: String?, platform: String?, romName: String): Profile {
                when (val p = platform?.lowercase()) {
                    "nes" -> return NES
                    "gameboy" -> return GB
                    "gba" -> return GBA
                    "atari2600" -> return A2600
                    "mastersystem" -> return if (romName.endsWith(".gg", ignoreCase = true)) GG else SMS
                    "genesis" -> return MD
                    "neogeo" -> return NEOGEO
                    "mame" -> return MAME
                }
                // Fallback for unrecognised / legacy platform strings: resolve
                // by core id. Unknown cores now log a warning instead of
                // silently collapsing to the NES 2-button layout.
                return when (coreId) {
                    "fceumm" -> NES
                    "gambatte" -> GB
                    "mgba" -> GBA
                    "stella2014" -> A2600
                    "picodrive" -> when {
                        romName.endsWith(".sms", ignoreCase = true) -> SMS
                        romName.endsWith(".gg", ignoreCase = true) -> GG
                        else -> MD
                    }
                    "fbalpha2012", "fbalpha", "fbneo", "mame" ->
                        if (platform?.equals("neogeo", ignoreCase = true) == true) NEOGEO else MAME
                    else -> {
                        Log.w("VirtualPadView",
                            "Unmapped control profile: core=$coreId platform=$platform rom=$romName — defaulting to NES")
                        NES
                    }
                }
            }

        /**
         * Per-edge reservation used by the GL renderer. The goal is
         * "fill the screen as much as possible, equally for every core,
         * minimal free area on all four sides" — so we floor every side
         * at 0 and let the per-core aspect letterbox inside
         * [EmulatorActivity.updateGameQuad] decide how much black bar to
         * leave. The virtual pad, SELECT/START pills and corner toolbar
         * are transparent overlays so the picture is still visible behind
         * them; they don't need any dedicated bar reservation.
         *
         * Concretely, on the OXF-AN10 reference (800dp landscape, 360dp
         * tall), the picture stage is:
         *   - NES landscape: 55% wide × 100% tall  (aspect 1.219)
         *   - GB  landscape: 50% wide × 100% tall  (aspect 1.111)
         *   - GBA landscape: 67.5% wide × 100% tall (aspect 1.5)
         *   - MD  landscape: 65% wide × 100% tall  (aspect 1.333)
         *   - SMS/GG/A2600 landscape: per-core aspect, same idea
         * Portrait (360×800) gives NES 100%×37%, GBA 100%×30% — these
         * tall black bars are the unavoidable consequence of fitting a
         * wide-screen core onto a tall phone; to push past this without
         * distorting the picture would require cropping gameplay, which
         * we explicitly avoid.
         */
        const val LEFT_INSET_FRAC: Float = 0f
        fun rightInsetFrac(p: Profile): Float = 0f
        fun topInsetFrac(p: Profile): Float = 0f
        const val BOTTOM_INSET_FRAC: Float = 0f

        /**
         * Canonical display aspect ratio for each platform's natural pixel
         * grid (no PAR), so [EmulatorActivity.applySafeInsets] can reserve
         * a stage matching the core's own shape instead of forcing every
         * game onto the NES 8:7 footprint. Cores report an aspect via
         * libretro ([coreAspect]) which is preferred at the GL layer; this
         * constant is the fallback that lets the stage still fit when the
         * core hasn't reported one (early frames, stella, mgba before first
         * frame, etc.).
         */
        fun coreDar(p: Profile): Float = when (p) {
            Profile.NES -> 256f / 240f * (8f / 7f) // 1.219 (NES NTSC 8:7 PAR)
            Profile.GB -> 160f / 144f                // 1.111
            Profile.GBA -> 240f / 160f              // 1.500
            Profile.A2600 -> 4f / 3f                // 1.333 (NTSC 4:3)
            Profile.SMS -> 256f / 192f              // 1.333
            Profile.GG -> 160f / 144f               // 1.111 (handheld rotated)
            Profile.MD -> 4f / 3f                   // 1.333 (NTSC 4:3)
            // M6: CPS1/CPS2/NeoGeo arcade panels are natively 4:3 — using
            // 1.333 here matches the typical CRT for which these games
            // were authored and is also the safety letterbox used by
            // libretro's retro_get_system_av_info when the core has no
            // per-game aspect override.
            Profile.MAME, Profile.NEOGEO -> 4f / 3f // 1.333
        }
    }
}

    private enum class Shape { CIRCLE, PILL }

    private class Btn(
        val mask: Int,
        val label: String,
        val shape: Shape,
        val rect: RectF
    )

    /** One-button special-move trigger: plays [seq] (one RETRO mask per frame). */
    private class MacroBtn(
        val rect: RectF,
        val label: String,
        val seq: IntArray
    )

    /**
     * @param mask  current RETRO pad bitmask (driven player only)
     * @param port  libretro pad port the pad drives: 0 = 1P, 1 = 2P
     *              (arcade profiles only; other profiles always send 0)
     */
    fun interface OnButtonsChanged { fun onChanged(mask: Int, port: Int) }

    var listener: OnButtonsChanged? = null

    /**
     * One-button special moves. A macro button queues a frame-by-frame input
     * sequence straight to the native runner (bypassing the per-frame bitmask
     * the virtual pad normally emits); a macro plays its full queued sequence
     * once triggered regardless of hold length (the native queue drains on its
     * own), so [onClear] is only used for hard stops (e.g. backgrounding).
     */
    interface OnMacro {
        fun onMacro(seq: IntArray)
        fun onClear()
    }

    var macroListener: OnMacro? = null

    /**
     * Direction input style.
     * - [STICK]  free analog feel for action / platformer titles (large dead zone).
     * - [DPAD8]  low-dead-zone 8-way pad tuned for fighting-game motion inputs
     *            (quarter-circles, half-circles, charge motions).
     * - [DPAD4]  4-way snap — every touch resolves to a single cardinal
     *            direction. Best for side-scrollers / platformers that don't
     *            understand diagonal input.
     */
    enum class StickMode { STICK, DPAD8, DPAD4 }

    var stickMode: StickMode = StickMode.DPAD8
        set(value) {
            if (field != value) {
                field = value
                if (width > 0 && height > 0) buildButtons(width, height)
                invalidate()
            }
        }

    /**
     * User-tunable dead-zone fraction (of the knob's max travel). Below this
     * offset the stick reads as centre; above it the corresponding d-pad bit
     * is asserted. Default 0.18 is a comfortable middle ground — light flicks
     * register but centre jitter doesn't.
     */
    var deadzone: Float = 0.18f
        set(value) {
            val clamped = value.coerceIn(0f, 0.45f)
            if (field != clamped) {
                field = clamped
                invalidate()
            }
        }

    /**
     * When true, render a 4-button + centre virtual d-pad UI in place of
     * the round analog stick. Each cardinal is a large tappable circle; the
     * centre is inert. Designed for action / platformer titles that want
     * crisp single-direction input without fighting a floating knob.
     */
    var useDpadUi: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                if (width > 0 && height > 0) buildButtons(width, height)
                invalidate()
            }
        }

    // D-pad geometry (re-computed in onSizeChanged). The four arm rects are
    // what gets DRAWN; the live touch area is the disc they sit on, split
    // into four 45° wedges — see hitDpad(). Making the hit area one disc is
    // what removes the dead diagonals and the inert centre blob that used to
    // drop the direction bit while a thumb slid between two arms.
    private val dpadCenter = RectF()
    private val dpadUp = RectF()
    private val dpadDown = RectF()
    private val dpadLeft = RectF()
    private val dpadRight = RectF()
    // Shared by layoutDpad() and drawDpad() so the drawn cross and the arm
    // rects can never drift apart (they used to be duplicate literals).
    private var dpadR = 0f        // centre -> arm-centre distance
    private var dpadArmR = 0f     // drawn arm disc radius
    private var dpadArmW = 0f     // cross thickness
    private var dpadOuterR = 0f   // live touch disc radius
    private var dpadDeadR = 0f    // small centre dead spot (anti-jitter)
    private var dpadHoldR = 0f    // hysteresis ring: see hitDpad notes

    private val macroButtons = ArrayList<MacroBtn>()
    private var macroPointer = -1

    /**
     * User-configurable fight-assist palette. Each entry is `(label, seq)`
     * — the seq is the per-frame retropad mask sequence that the native
     * runner drains when the slot is tapped. Default = the KOF97 specials
     * baked into this view historically, so a brand-new install (with no
     * `library/moves.json` yet) still renders the familiar six-pill
     * palette until the user opens the settings editor and saves a
     * custom layout.
     */
    private var macros: List<Pair<String, IntArray>> = defaultMacros()

    /**
     * Replace the assist palette. The view re-flows on the next layout
     * pass; callers (EmulatorActivity) typically invoke this once right
     * after construction with the loaded config and rely on the existing
     * `buildButtons` to apply it.
     */
    fun setMacros(items: List<Pair<String, IntArray>>) {
        macros = items
        if (width > 0 && height > 0) buildButtons(width, height)
        invalidate()
    }

    /**
     * Bakes the historical KOF97 specials (波/升/旋/超 + 避/滚) into a
     * `List<Pair<String, IntArray>>` using the same 3-frame cadence the
     * editor now uses, so the default behaviour is preserved when no user
     * config has been written yet. All masks are built straight from the
     * companion constants so we don't depend on any local aliases that
     * may disappear with future refactors.
     */
    private fun defaultMacros(): List<Pair<String, IntArray>> = listOf(
        "波" to two(BUTTON_DOWN, BUTTON_DOWN or BUTTON_RIGHT, BUTTON_RIGHT,
            BUTTON_RIGHT or BUTTON_B),
        "升" to two(BUTTON_RIGHT, BUTTON_RIGHT, BUTTON_DOWN,
            BUTTON_DOWN or BUTTON_RIGHT, BUTTON_RIGHT, BUTTON_RIGHT or BUTTON_B),
        "旋" to two(BUTTON_DOWN, BUTTON_DOWN or BUTTON_LEFT, BUTTON_LEFT,
            BUTTON_LEFT or BUTTON_X),
        "超" to two(BUTTON_DOWN, BUTTON_DOWN or BUTTON_RIGHT, BUTTON_RIGHT,
            BUTTON_RIGHT or BUTTON_DOWN, BUTTON_DOWN,
            BUTTON_DOWN or BUTTON_RIGHT, BUTTON_RIGHT,
            BUTTON_RIGHT or (BUTTON_B or BUTTON_Y)),
        "避" to two(BUTTON_RIGHT, BUTTON_RIGHT, BUTTON_RIGHT,
            BUTTON_RIGHT, BUTTON_RIGHT, BUTTON_RIGHT),
        "滚" to two(BUTTON_LEFT, BUTTON_LEFT, BUTTON_LEFT,
            BUTTON_LEFT, BUTTON_LEFT, BUTTON_LEFT)
    )

    /**
     * Replicates the 3-frame cadence of the original `two()` local: each
     * direction / press is held for 3 frames (~50 ms) so the core's
     * motion buffer latches it. Kept as a class member so the default
     * macro list above and [ScriptCompiler]-generated IntArrays both
     * share the same timing contract.
     */
    private fun two(vararg steps: Int): IntArray {
        val o = ArrayList<Int>()
        for (s in steps) repeat(3) { o.add(s) }
        return o.toIntArray()
    }

    /**
     * Currently driven arcade player port: 0 = 1P, 1 = 2P. Selected by the
     * 1P/2P pill on the arcade profile; never changes on the other pads.
     */
    var playerPort: Int = 0
        private set

    /**
     * Netplay: the driven port is fixed by the session role, so the
     * arcade 1P/2P toggle pill is neither drawn nor touchable.
     */
    var portLocked: Boolean = false
        set(value) {
            if (field != value) {
                field = value
                if (width > 0 && height > 0) buildButtons(width, height)
                invalidate()
            }
        }

    /**
     * Netplay guest (2P) join hint for arcade cabinets: the guest sees the
     * same lockstep picture immediately, but on coin-op hardware 2P only
     * spawns after a coin insert + START. The line stays until the guest
     * inserts the first coin (SELECT), then removes itself.
     */
    var joinHint: String? = null

    var profile: Profile = Profile.NES
        set(value) {
            if (field != value) {
                field = value
                buildButtons(width, height)
                invalidate()
            }
        }

    /**
     * Shorter screen dimension in pixels, refreshed every time
     * [onSizeChanged] fires. Every pad dimension below is a fraction of
     * this value (instead of a fixed dp) so the joystick / face buttons /
     * SELECT·START stack scale with the device — same visual proportions
     * on every phone, no per-device tuning.
     *
     * Initial value is a reasonable placeholder for the period between
     * view construction and the first layout pass; [onSizeChanged]
     * overwrites it before the view is ever drawn.
     */
    private var ref: Float = 1080f

    // Joystick geometry (set in onSizeChanged): a compact circular analog
    // stick replaces the old cross. The knob offset is mapped to the digital
    // d-pad bits per axis (with a dead zone), so diagonals work as well.
    // FIXED position (not a floating pad): the pivot never moves, which is what
    // makes fighting-game motion inputs repeatable.
    private var stickCx = 0f; private var stickCy = 0f
    // Idle centre of the stick; [stickCx]/[stickCy] simply mirror it.
    private var stickHomeCx = 0f; private var stickHomeCy = 0f
    private var baseR = 0f; private var knobR = 0f
    // Minimum clearance kept between the stick disc and every screen edge, so
    // the idle ring stays off the bezel (and out of the system back-gesture
    // strip) instead of hugging it.
    private var edgeGap = 0f
    private var stickPointer = -1

    // 用户可配置的虚拟手柄整体布局: 以默认大小/位置为基准的「整体缩放 + 整体平移」。
    // padScale=1 表示默认大小; padOffsetX/Y 是相对屏幕尺寸的比例(约 -0.4..+0.4),
    // 由 Dart 端 AppSettings(padScale/padOffsetX/padOffsetY)经 FlutterSharedPreferences
    // 传入。onSizeChanged 中把比例换算成像素偏移再叠加到所有控件上。
    var padScale: Float = 1.0f
    var padOffsetX: Float = 0f
    var padOffsetY: Float = 0f
    private var padOffX = 0f   // 像素偏移(= padOffsetX * width), onSizeChanged 计算
    private var padOffY = 0f
    private var stickDx = 0f; private var stickDy = 0f
    // DIAGNOSTIC only: last mask handed to emit()'s log line.
    private var lastLoggedMask = Int.MIN_VALUE
    private val buttons = ArrayList<Btn>()

    // Arcade-only 1P/2P selector: a tap-to-toggle pill (not a held button).
    // [toggleRect] is null on profiles without the selector; [togglePointer]
    // is the pointer currently pressing it (a release inside the rect flips
    // [playerPort]).
    private var toggleRect: RectF? = null
    private var togglePointer = -1

    // Arcade profiles (MAME/NEOGEO) collapsible action menu: 1P/2P · 投币 ·
    // 开始 live behind one small pill parked on the top-right row, level
    // with the native exit "✕" icon. Collapsed, the pill is the only
    // control there and the whole lower-right area is free for the attack
    // discs; expanded, the three actions fan out to the pill's left.
    private var menuRect: RectF? = null
    private var menuPointer = -1
    private var menuExpanded = false
    // Fighting-game assist palette (NEOGEO): the six one-button specials sit in
    // the empty letterbox band on the RIGHT of the picture, hidden behind a
    // collapsible pill the same way the arcade action row is. Collapsed they are
    // off-screen entirely, so neither the strip nor its pills can ever overlap
    // (and steal taps from) the arcade menu above it.
    private var assistRect: RectF? = null
    private var assistPointer = -1
    private var assistExpanded = false
    private var topInsetPx = 0
    // Bottom system inset (gesture nav bar / cutout). The arcade fire
    // buttons sit near the bottom edge; edge-to-edge layouts (Android 15,
    // Zhuoyitong on HarmonyOS NEXT) float the gesture bar over this
    // full-screen view and would otherwise clip the bottom row.
    private var bottomInsetPx = 0

    // Window-Y of the bottom edge of the native top chrome row (the 功能
    // opener pill and the round exit ✕ share one row). The right-column
    // shoulder / SELECT / START stack must stay below it. Pushed by
    // EmulatorActivity once the chrome is laid out. -1 = unknown; the
    // legacy ref*0.16 floor is then used on its own. This explicit channel
    // is required on Android VM containers (Zhuoyitong on HarmonyOS NEXT)
    // which place this full-screen view at window-Y 0 while still applying
    // the status-bar inset to the chrome: the old fixed floor let the R
    // pill collide with the ✕ there.
    private var topChromeBottomWindow = -1f

    /** See [topChromeBottomWindow]. Safe to call before first layout. */
    fun setTopChromeBottom(windowBottomY: Float) {
        if (windowBottomY == topChromeBottomWindow) return
        topChromeBottomWindow = windowBottomY
        if (width > 0 && height > 0) {
            buildButtons(width, height)
            invalidate()
        }
    }

    private val held = HashMap<Int, Int>() // pointerId -> button bit

    init {
        // Track the status-bar / cutout inset so the collapsible menu pill
        // can be centred vertically on the exit icon (whose own top margin
        // is inset + 1.7% of the screen height, see EmulatorActivity).
        setOnApplyWindowInsetsListener { _, insets ->
            val t: Int; val b: Int
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val sb = insets.getInsets(
                    WindowInsets.Type.statusBars()
                        or WindowInsets.Type.navigationBars()
                        or WindowInsets.Type.displayCutout()
                )
                t = sb.top; b = sb.bottom
            } else {
                @Suppress("DEPRECATION")
                run { t = insets.systemWindowInsetTop; b = insets.systemWindowInsetBottom }
            }
            if (t != topInsetPx || b != bottomInsetPx) {
                topInsetPx = t
                bottomInsetPx = b
                if (width > 0 && height > 0) {
                    layoutStick(width, height)
                    buildButtons(width, height)
                    // Re-anchor the edge-gesture exclusion bands: the bottom
                    // gesture strip moves when the nav bar shows/hides.
                    applySystemGestureExclusion(width, height)
                    invalidate()
                }
            }
            insets
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        requestApplyInsets()
        // Window coordinates are valid only after attach; if the chrome edge
        // was already pushed in, re-flow the rows against it now.
        if (topChromeBottomWindow >= 0f && width > 0 && height > 0) {
            buildButtons(width, height)
            invalidate()
        }
    }

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(56, 255, 255, 255)
        style = Paint.Style.FILL
    }
    private val fillActivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(205, 255, 193, 7)
        style = Paint.Style.FILL
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(150, 255, 255, 255)
        style = Paint.Style.STROKE
        // strokeWidth set in onSizeChanged (proportional to ref).
        strokeWidth = 1f
    }
    private val strokeActivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(245, 255, 235, 170)
        style = Paint.Style.STROKE
        // strokeWidth set in onSizeChanged (proportional to ref).
        strokeWidth = 1f
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        // textSize set in onSizeChanged (proportional to ref).
        textSize = 15f
        textAlign = Paint.Align.CENTER
    }
    private val textActivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(45, 32, 0)
        // textSize set in onSizeChanged (proportional to ref).
        textSize = 15f
        textAlign = Paint.Align.CENTER
        isFakeBoldText = true
    }
    // Stick direction chevrons (faint hints near the disc rim).
    private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(105, 255, 255, 255)
        style = Paint.Style.FILL
    }
    // Guest 2P join coach mark: dark translucent pill so white text stays
    // legible over any game scene behind it.
    private val hintFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(150, 20, 20, 24)
        style = Paint.Style.FILL
    }
    // Joystick knob at rest: brighter than the base disc so it reads as a
    // movable part; turns amber (fillActivePaint) while grabbed.
    private val knobPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(120, 255, 255, 255)
        style = Paint.Style.FILL
    }
    private val knobStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(190, 255, 255, 255)
        style = Paint.Style.STROKE
        // strokeWidth set in onSizeChanged (proportional to ref).
        strokeWidth = 1f
    }

    // Visual press feedback: inset + arrow size in px. Updated in
    // onSizeChanged (proportional to ref).
    private var pressInset: Float = 1f

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w <= 0 || h <= 0) return
        val landscape = w >= h

        // Geometry scales with the smaller screen dimension (so the pad
        // keeps a comfortable size on small phones) and grows linearly
        // with it on tablets — the whole view is now screen-relative, no
        // per-density / per-device dp() values. Coefficient matches the
        // prior dp(62f) on the 360dp-min reference device (62/360 =
        // 0.140f) so the disc keeps the same visual size on a 5" phone
        // while scaling gracefully on bigger ones.
        ref = minOf(w, h).toFloat()

        // 用户布局: 比例偏移 -> 像素偏移(相对屏幕宽/高), 后续叠加到所有控件。
        padOffX = padOffsetX * w.toFloat()
        padOffY = padOffsetY * h.toFloat()

        // Update paint / press dimensions that were left as placeholders
        // at construction (ref was 0 then). Percentages match the prior
        // dp() values on a 360dp-min reference and scale linearly with
        // ref on every other screen.
        strokePaint.strokeWidth = ref * 0.0056f
        strokeActivePaint.strokeWidth = ref * 0.0072f
        textPaint.textSize = ref * 0.042f
        textActivePaint.textSize = ref * 0.042f
        knobStrokePaint.strokeWidth = ref * 0.0056f
        pressInset = ref * 0.0069f

        // Compact disc that overlays the picture's left corner (D-pad is a
        // semi-transparent overlay, not a reserved black bar — see
        // [Profile.LEFT_INSET_FRAC] = 0f). Tuned so the disc ends up
        // ~50dp on the 360dp-min reference, matching the prior dp(62f)
        // baseline scaled to a smaller reference device.
        // Bumped 0.140 -> 0.17 -> 0.19 per user request for an even larger,
        // easier-to-grab disc (radius now ~+36%, area ~+85% vs the 0.14 base).
        // padScale 整体缩放(以默认大小为基准): 1.0 = 默认, 0.5..2.0 允许用户按需缩放。
        baseR = ref * 0.190f * padScale
        knobR = baseR * 0.44f
        edgeGap = ref * 0.05f

        // Position: stick lands at the same relative coordinates as the
        // original HBN-AL00 layout (~10% from the left edge, ~22% up from
        // the bottom). Portrait fallback mirrors horizontally so the stick
        // never crowds the face-button cluster. Y is measured against the
        // height ABOVE the bottom system inset so edge-to-edge containers
        // (floating gesture bar) lift the disc instead of clipping it.
        layoutStick(w, h)
        stickPointer = -1; stickDx = 0f; stickDy = 0f
        layoutDpad(w, h)
        buildButtons(w, h)
        // 用户布局: 把方向键/十字键(沿用已偏移的 stick 中心)之外的右侧按钮及菜单/
        // 招式/1P-2P 等浮层整体平移 padOffX/padOffY。
        applyPadOffset()
        applySystemGestureExclusion(w, h)
    }

    /** 把右侧按钮集群与各类浮层整体平移用户设定的偏移量(像素)。 */
    private fun applyPadOffset() {
        if (padOffX == 0f && padOffY == 0f) return
        for (b in buttons) b.rect.offset(padOffX, padOffY)
        menuRect?.offset(padOffX, padOffY)
        assistRect?.offset(padOffX, padOffY)
        toggleRect?.offset(padOffX, padOffY)
    }

    /**
     * Compute the 4 cardinal disc rects for the virtual d-pad UI. Reuses
     * the same centre / radius space as the analog stick, so a layout that
     * looks good for the stick also looks good for the d-pad and vice versa.
     */
    private fun layoutDpad(w: Int, h: Int) {
        val cx = stickHomeCx
        val cy = stickHomeCy
        // Compact layout. The old spread (r = 1.05·baseR) made the cross about
        // 3.2·baseR across, which parked the left arm's rim only ~140px from
        // the screen edge — swipes starting there were claimed by the system
        // back gesture, because the static exclusion band only honours the
        // ~200dp nearest the edge and never reaches the arm's outer half.
        // 0.78·baseR shrinks the whole control ~23% and moves its rim clear of
        // the gesture zone; the arm discs shrink only slightly so they stay
        // easy to hit.
        val r = baseR * 0.78f
        val buttonR = baseR * 0.46f
        dpadR = r
        dpadArmR = buttonR
        dpadArmW = baseR * 0.40f
        dpadCenter.set(cx - buttonR, cy - buttonR, cx + buttonR, cy + buttonR)
        dpadUp.set(cx - buttonR, cy - r - buttonR, cx + buttonR, cy - r + buttonR)
        dpadDown.set(cx - buttonR, cy + r - buttonR, cx + buttonR, cy + r + buttonR)
        dpadLeft.set(cx - r - buttonR, cy - buttonR, cx - r + buttonR, cy + buttonR)
        dpadRight.set(cx + r - buttonR, cy - buttonR, cx + r + buttonR, cy + buttonR)
        // Live touch area = the disc the four arms sit on (see hitDpad).
        dpadOuterR = r + buttonR
        // Four wedges meet at a point, so a thumb parked dead centre would
        // flip direction on every jitter — keep a *small* dead spot. The old
        // inert centre was a full arm-sized square (~197px across); this is
        // ~8px, just enough to stop a resting thumb from flickering between
        // the four arms. Crossing it no longer drops the input: a finger
        // already moving keeps its direction across the dot (see the
        // ACTION_MOVE branch), so ↑→↓ and ←→→ reversals stay continuous.
        dpadDeadR = baseR * 0.045f
        // Hysteresis ring. Right at the centre both dx and dy approach 0, so
        // the wedge angle is pure noise — a 1px lateral wobble swings atan2
        // by 180°, which made a straight ↑→↓ drag flicker through ← on its
        // way across. Once a direction is held it is therefore kept inside
        // this ring and only re-decided once the finger is far enough out
        // for the angle to mean something again.
        dpadHoldR = (r + buttonR) * 0.18f
    }

    /** Place the stick disc; shared by size and inset changes. */
    private fun layoutStick(w: Int, h: Int) {
        val landscape = w >= h
        // Resting (idle) position of the FIXED stick — it does not move. Anchored
        // from the BOTTOM by a fixed clearance rather than a percentage of the
        // height: 0.78*availH put the disc low enough that its rim sat in the
        // bottom gesture strip on short screens (OXF landscape is only 945px).
        // Clearance = bottom system inset (nav/gesture bar) + an allowance for
        // the floating gesture bar (which does NOT report an inset on
        // edge-to-edge containers) + the edge gap + one disc radius.
        // Horizontal: 13% (landscape) / 22% (portrait) from the left edge. The
        // disc grew again, and its right rim was reaching the game viewport's left
        // edge, so it is shifted left to keep the whole disc clear of the picture.
        stickHomeCx = if (landscape) w * 0.13f else w * 0.22f
        // Move the disc UP: anchor its centre at 66% of the height (the old
        // bottom-clearance formula put it near the bottom, where the rim sat in
        // the gesture strip). The centre is then clamped so the WHOLE disc stays
        // clear of the floating home/recents bar and the bottom edge, and clear
        // of the top edge too. Reported [bottomInsetPx] is 0 on edge-to-edge
        // containers (the gesture bar floats OVER this view), so a fixed 6% of
        // the short side is added on top of the inset/gap/radius as allowance.
        val gestureBarAllowance = ref * 0.06f
        val topLimit = baseR + edgeGap
        // 用户把整体缩放调得很大时 baseR 可能接近甚至超过半屏高度, 使
        // bottomLimit 掉到 topLimit 之下; coerceIn 要求 min<=max, 否则抛
        // IllegalArgumentException 崩溃。这里把 bottomLimit 兜底到不小于
        // topLimit(此时盘面溢出但居中偏上, 不至于崩)。
        val bottomLimit = (h - bottomInsetPx - gestureBarAllowance - baseR - edgeGap)
            .coerceAtLeast(topLimit)
        val desiredCy = h * 0.66f
        stickHomeCy = desiredCy.coerceIn(topLimit, bottomLimit)
        // 用户布局: 整体平移(在默认位置基础上叠加, 允许移出屏幕边界由用户自担)。
        stickHomeCx += padOffX
        stickHomeCy += padOffY
        stickCx = stickHomeCx
        stickCy = stickHomeCy
    }

    /** (Re)build the right-side button cluster for the active profile. */
    private fun buildButtons(w: Int, h: Int) {
        buttons.clear()
        toggleRect = null
        menuRect = null
        assistRect = null
        if (w == 0 || h == 0) return
        val landscape = w >= h

        // Face button / touch disc size scales with the stick disc so every
        // finger target keeps the same relative weight on any phone.
        val faceR = baseR * 0.50f
        val rad = faceR
        // Pill geometry (responsive to baseR).
        val pillW = baseR * 1.42f  // matches the original dp(88) on OXF-AN00: 88f / 62f = 1.42
        val pillH = baseR * 0.55f  // matches the original dp(34): 34f / 62f = 0.55
        val gbaPillW = baseR * 1.22f  // dp(76)
        val gbaPillH = baseR * 0.48f  // dp(30)

        // Face-button anchor + SELECT/START column position. Proportional to
        // the surface, reproducing the original HBN-AL00 percentages so the
        // reference phone looks identical while a 5" or 7" screen scales
        // gracefully. Portrait shifts B/A down a touch and tightens the gap.
        val ax: Float; val ay: Float
        val bx: Float; val by: Float
        val ssCx: Float
        // Vertical anchors are fractions of the height ABOVE the bottom
        // system inset (gesture/nav bar): identical pixels on inset-free
        // phones, lifted clear of the floating bar on edge-to-edge
        // containers (Android 15 / Zhuoyitong on HarmonyOS NEXT).
        val availH = (h - bottomInsetPx).coerceAtLeast(1).toFloat()
        if (landscape) {
            // A: 7% from right, 29% from bottom; B: 15% from right, 21% from
            // bottom; SELECT/START column: 8% from right.
            ax = w * 0.93f; ay = availH * 0.71f
            bx = w * 0.85f; by = availH * 0.79f
            ssCx = w * 0.92f
        } else {
            ax = w * 0.82f; ay = availH * 0.75f
            bx = w * 0.66f; by = availH * 0.85f
            ssCx = w * 0.82f
        }

        fun circle(bit: Int, label: String, x: Float, y: Float) =
            buttons.add(Btn(bit, label, Shape.CIRCLE, RectF(x - rad, y - rad, x + rad, y + rad)))
        fun pill(bit: Int, label: String, cxp: Float, yp: Float, pw: Float, ph: Float) =
            buttons.add(Btn(bit, label, Shape.PILL, RectF(cxp - pw / 2, yp - ph / 2, cxp + pw / 2, yp + ph / 2)))

        // Adaptive right-column stack. The usable vertical space changes per
        // phone (status bar / cutout on landscape OXF is only ~411dp tall);
        // rows keep their preferred y while they fit between the floating menu
        // bar above and the top of the A circle below (with 10dp clearance),
        // otherwise they re-space (and shrink slightly as a last resort).
        // Operates in PIXELS now so positions track the proportional layout.
        class Row(val bit: Int, val label: String,
                  val wPx: Float, val hPx: Float, val prefYPx: Float)
        fun stackRows(rows: List<Row>): Pair<List<Float>, Float> {
            // Floor below the floating top-right menu bar (~58dp on
            // 360dp-min), raised when the real chrome row (功能/✕) sits
            // lower — the inset-driven chrome can extend past this floor on
            // tall screens / inside Android VM containers. The chrome edge
            // arrives in window coordinates; convert into this view's local
            // coordinates (some containers offset the full-screen pad view,
            // real devices with a pushed decor do too) and add a small gap.
            var topLimitPx = ref * 0.16f
            if (topChromeBottomWindow >= 0f) {
                val loc = IntArray(2)
                getLocationInWindow(loc)
                val chromeLocal = topChromeBottomWindow - loc[1] + ref * 0.012f
                if (chromeLocal > topLimitPx) topLimitPx = chromeLocal
            }
            val faceRPx = rad         // face button radius in pixels
            val bottomLimitPx = ay - faceRPx - ref * 0.028f  // above A circle top (~10dp on 360dp-min)
            val gapMinPx = ref * 0.011f  // ~4dp on 360dp-min
            val regionPx = (bottomLimitPx - topLimitPx).coerceAtLeast(0f)
            val fitsAsIs = regionPx > 0 &&
                rows.first().prefYPx - rows.first().hPx / 2 >= topLimitPx &&
                rows.last().prefYPx + rows.last().hPx / 2 <= bottomLimitPx &&
                rows.zipWithNext().all { (a, b) ->
                    b.prefYPx - b.hPx / 2 - (a.prefYPx + a.hPx / 2) >= gapMinPx
                }
            if (fitsAsIs) return Pair(rows.map { it.prefYPx }, 1f)
            val needed = rows.sumOf { it.hPx.toDouble() }.toFloat() +
                gapMinPx * (rows.size - 1)
            var scale = 1f
            if (regionPx < needed) scale = (regionPx / needed).coerceIn(0.6f, 1f)
            val heights = rows.map { it.hPx * scale }
            val gap = if (rows.size > 1)
                ((regionPx - heights.sum()) / (rows.size - 1)).coerceAtLeast(gapMinPx) else 0f
            val centres = ArrayList<Float>(rows.size)
            var edge = topLimitPx
            for (hh in heights) { edge += hh / 2f; centres.add(edge); edge += hh / 2f + gap }
            return Pair(centres, scale)
        }

        // Preferred row y, expressed as a fraction of the screen height (top
        // origin). Sourced from the original dp positions on HBN-AL00
        // (411dp landscape): 100dp ≈ 24.3%, 144dp ≈ 35.0%, 74dp ≈ 18.0%,
        // 116dp ≈ 28.2%, 156dp ≈ 37.9%. On a 360dp-tall surface the rows
        // land in the same relative location; the stackRows budget gives the
        // final spacing.
        val selectY = h * 0.244f
        val startY  = h * 0.350f
        val shoulderY = h * 0.180f
        val gbaSelY  = h * 0.282f
        val gbaStartY = h * 0.380f

        when (profile) {
            Profile.NES, Profile.GB -> {
                circle(BUTTON_B, "B", bx, by)
                circle(BUTTON_A, "A", ax, ay)
                val rows = listOf(
                    Row(BUTTON_SELECT, "SELECT", pillW, pillH, selectY),
                    Row(BUTTON_START,  "START",  pillW, pillH, startY))
                val (ys, scale) = stackRows(rows)
                rows.forEachIndexed { i, r ->
                    pill(r.bit, r.label, ssCx, ys[i], r.wPx, r.hPx * scale)
                }
            }
            Profile.GBA -> {
                // L/R shoulders share the top row; SELECT/START stack below.
                // All rows are fitted by [stackRows] so they clear both the
                // floating menu bar above and the A circle below on every
                // screen height.
                val rows = listOf(
                    Row(BUTTON_R, "R",      pillW,    pillH,    shoulderY),
                    Row(BUTTON_SELECT, "SELECT", gbaPillW, gbaPillH, gbaSelY),
                    Row(BUTTON_START,  "START",  gbaPillW, gbaPillH, gbaStartY))
                val (ys, scale) = stackRows(rows)
                rows.forEachIndexed { i, r ->
                    if (r.bit == BUTTON_R)
                        pill(BUTTON_L, "L", w * 0.07f, ys[i], r.wPx, r.hPx * scale)
                    pill(r.bit, r.label, ssCx, ys[i], r.wPx, r.hPx * scale)
                }
                circle(BUTTON_B, "B", bx, by)
                circle(BUTTON_A, "A", ax, ay)
            }
            Profile.A2600 -> {
                circle(BUTTON_B, "FIRE", ax, ay)
                val rows = listOf(
                    Row(BUTTON_SELECT, "SELECT", pillW, pillH, selectY),
                    Row(BUTTON_START,  "RESET",  pillW, pillH, startY))
                val (ys, scale) = stackRows(rows)
                rows.forEachIndexed { i, r ->
                    pill(r.bit, r.label, ssCx, ys[i], r.wPx, r.hPx * scale)
                }
            }
            Profile.SMS, Profile.GG -> {
                // picodrive: RETRO B = button 1, RETRO A = button 2.
                circle(BUTTON_B, "1", bx, by)
                circle(BUTTON_A, "2", ax, ay)
                val rows = listOf(Row(BUTTON_START, "PAUSE", pillW, pillH, startY))
                val (ys, scale) = stackRows(rows)
                pill(BUTTON_START, "PAUSE", ssCx, ys[0], rows[0].wPx, rows[0].hPx * scale)
            }
            Profile.MD -> {
                // picodrive: RETRO Y=A, B=B, A=C in a diagonal row. The outer
                // A circle stays within the reserved right bar.
                val yOff = baseR * 0.55f
                val xOff = baseR * 0.85f
                circle(BUTTON_Y, "A", bx - xOff, by + yOff)
                circle(BUTTON_B, "B", bx, by)
                circle(BUTTON_A, "C", ax, ay)
                val rows = listOf(Row(BUTTON_START, "START", pillW, pillH, startY))
                val (ys, scale) = stackRows(rows)
                pill(BUTTON_START, "START", ssCx, ys[0], rows[0].wPx, rows[0].hPx * scale)
            }
            Profile.MAME -> {
                // Capcom 6-button panel in the classic cabinet arrangement
                // (weak->strong left to right), exactly the silk screen of
                // a real CPS cabinet:
                //   X  Y  Z   -> retropad Y, X, L  (punches LP/MP/HP)
                //   A  B  C   -> retropad B, A, R  (kicks   LK/MK/HK)
                // fbalpha2012 puts Street-Fighter-layout 6-button fighters
                // on Y/X/L over B/A/R (verified against the v0.2.97.29
                // source shipped inside libgs_fbalpha2012.so); other CPS
                // games (1941, Commandos…) use generic fire1..6 = B,A,Y,X,
                // all of which are present on this panel.
                //
                // All six discs live INSIDE the right letterbox bar (the
                // black margin the core draws beside the playfield), so
                // they never cover the game picture. Measured on the Honor
                // 2400x1080 the picture ends at ~0.790w; discs are laid out
                // between 0.794w and 0.992w, right edge flush to the screen.
                val barFrom = w * 0.794f
                val barTo = w * 0.992f
                val barW = barTo - barFrom
                val edgeGap = w * 0.008f
                // Largest radius that fits three discs + two gaps in the bar.
                val aR = minOf(ref * 0.072f, (barW - 2 * edgeGap) / 6f)
                val colGap = 2f * aR + (barW - 6f * aR) / 2f
                val rowGap = aR * 2.5f
                val cxR = barTo - aR
                // Bottom row clears the floating gesture/nav bar: its bottom
                // edge sits one radius above (system inset + 3% ref gap).
                // Equals the old h*0.89 anchor on inset-free devices.
                val cyBot = h - bottomInsetPx - ref * 0.03f - aR
                val cyTop = cyBot - rowGap
                fun acircle(bit: Int, label: String, x: Float, y: Float) =
                    buttons.add(Btn(bit, label, Shape.CIRCLE,
                        RectF(x - aR, y - aR, x + aR, y + aR)))
                // Top row: X Y Z
                acircle(BUTTON_Y, "X", cxR - colGap * 2, cyTop)
                acircle(BUTTON_X, "Y", cxR - colGap,     cyTop)
                acircle(BUTTON_L, "Z", cxR,               cyTop)
                // Bottom row: A B C
                acircle(BUTTON_B, "A", cxR - colGap * 2, cyBot)
                acircle(BUTTON_A, "B", cxR - colGap,     cyBot)
                acircle(BUTTON_R, "C", cxR,               cyBot)
            }
            Profile.NEOGEO -> {
                // SNK NeoGeo fixed 4-button panel (A/B/C/D candy buttons),
                // rendered 2x2 like the NEOGEO mini hardware:
                //   A  B   -> retropad B, A   (light punch / light kick)
                //   C  D   -> retropad Y, X   (heavy punch / heavy kick)
                // With only two discs per row (instead of three) each disc
                // grows ~45% larger, which matters for KOF/SS combos that
                // need simultaneous A+B (dodge), C+D (heavy) presses.
                // Games using fewer buttons (Metal Slug: A shoot / B jump /
                // C bomb) simply leave the unused discs idle.
                val barFrom = w * 0.794f
                val barTo = w * 0.992f
                val barW = barTo - barFrom
                val edgeGap = w * 0.008f
                // Radius: ref*0.088 keeps the candy-button feel while the
                // older ref*0.100 discs overpowered the tall 2.26:1 Pura
                // screen (bottom row nearly clipped the screen edge). The
                // bar-width cap still protects narrow letterbox bars.
                val aR = minOf(ref * 0.088f, (barW - edgeGap) / 4.5f)
                // Compact candy-cabinet spacing: 0.5-diameter horizontal
                // gap, 0.3-diameter vertical gap, whole cluster right-
                // aligned inside the bar instead of splaying both discs
                // flush to the bar edges.
                val colGap = aR * 2.5f
                val rowGap = aR * 2.3f
                val cxR = barTo - edgeGap - aR
                val cxL = cxR - colGap
                // Same inset-aware bottom anchor as the MAME six-key panel.
                val cyBot = h - bottomInsetPx - ref * 0.03f - aR
                val cyTop = cyBot - rowGap
                fun acircle(bit: Int, label: String, x: Float, y: Float) =
                    buttons.add(Btn(bit, label, Shape.CIRCLE,
                        RectF(x - aR, y - aR, x + aR, y + aR)))
                // Top row: A B
                acircle(BUTTON_B, "A", cxL, cyTop)
                acircle(BUTTON_A, "B", cxR, cyTop)
                // Bottom row: C D
                acircle(BUTTON_Y, "C", cxL, cyBot)
                acircle(BUTTON_X, "D", cxR, cyBot)
            }
        }

        // Fighting-game assist row (KOF etc.): one-button specials +
        // AC/BC chords. NEOGEO only for now (its candy mapping is fixed).
        // (outside the when{} — an `if` as a when branch entry is a syntax error)
        if (profile == Profile.NEOGEO) buildFightAssist(w, h)

        // DIAGNOSTIC: dump the resolved geometry so a logcat capture gives the
        // exact hit-test rectangles for scripted input tests.
        run {
            val sb = StringBuilder("layout w=$w h=$h ref=$ref profile=$profile " +
                "stickC=(${stickCx.toInt()},${stickCy.toInt()}) baseR=${baseR.toInt()} " +
                "knobR=${knobR.toInt()} grabR=${(baseR * 1.35f).toInt()}")
            for (b in buttons) {
                sb.append(" | ${b.label}=${b.rect.left.toInt()},${b.rect.top.toInt()}-" +
                    "${b.rect.right.toInt()},${b.rect.bottom.toInt()} c=${b.rect.centerX().toInt()},${b.rect.centerY().toInt()}")
            }
            Log.i("VirtualPadView", sb.toString())
        }

        // Collapsible arcade action menu, shared by the MAME and NEOGEO
        // profiles. Its pill is level with the native round exit button
        // (ref*0.077 square): the exit button's centre Y is inset + 1.7%
        // margin + the shared row nudge + ref*0.0385, which simplifies to
        // the same inset + 1.7% + ref*0.05 centre used here. It sits
        // immediately to the exit button's left.
        if (profile == Profile.MAME || profile == Profile.NEOGEO) {
            val menuY = topInsetPx + h * 0.017f + ref * 0.05f
            val exitLeft = w - w * 0.017f - ref * 0.077f
            val hGap = w * 0.012f
            val menuCx = exitLeft - hGap - pillW / 2f
            menuRect = RectF(menuCx - pillW / 2f, menuY - pillH / 2f,
                             menuCx + pillW / 2f, menuY + pillH / 2f)
            if (menuExpanded) {
                // Fan out leftward: 开始 · 投币 · 1P/2P, all on the
                // same row as the menu pill. Safe now that the assist palette
                // moved off the top strip into the right-hand letterbox band.
                var px = menuCx - (pillW + hGap)
                pill(BUTTON_START, "开始", px, menuY, pillW, pillH)
                px -= pillW + hGap
                pill(BUTTON_SELECT, "投币", px, menuY, pillW, pillH)
                px -= pillW + hGap
                if (!portLocked) {
                    toggleRect = RectF(px - pillW / 2f, menuY - pillH / 2f,
                                       px + pillW / 2f, menuY + pillH / 2f)
                }
            }
        }
    }

    /**
     * Fighting-game assist palette for the NEOGEO panel (KOF / SamSho …):
     * one-button special macros (波/升/旋/超) sent straight to the native
     * runner, plus AC (dodge) / BC (roll) chord buttons. NeoGeo candy mapping:
     * A轻拳=B, B轻踢=A, C重拳=Y, D重踢=X.
     *
     * The keys are laid out in the empty letterbox band to the RIGHT of the
     * picture (the same black column the A/B/C/D discs occupy) instead of as a
     * row over the artwork, and are folded behind a pill exactly like the arcade
     * action row. While collapsed nothing is laid out at all, so the palette can
     * never overlap — and steal taps from — the controls around it.
     */
    private fun buildFightAssist(w: Int, h: Int) {
        macroButtons.clear()
        assistRect = null
        if (w == 0 || h == 0) return
        // The default KOF97 specials come from `defaultMacros()`; users can
        // override them via `setMacros(...)` from the settings editor (see
        // SpecialMovesStore + ScriptCompiler for the schema).
        //   波  ↓↘→ + A       (fireball / 百式)
        //   升  →↓↘ + A       (dragon punch / 鮫刃)
        //   旋  ↓↙← + D       (half-circle kick / 琴月陽・八咫薙)
        //   超  ↓↘→↓↘→ + AC   (Desperation — needs health < 1/3)
        //   避  →→            (forward dash / 前転回避)
        //   滚  ←←            (back dash / 後転回避)
        // ---- placement: the black letterbox column right of the picture ----
        val barFrom = w * 0.794f
        val barTo = w * 0.992f
        val barW = barTo - barFrom
        val barPad = w * 0.008f
        // Top of the A/B/C/D cluster (same maths as the NEOGEO branch), so the
        // palette never reaches down onto the discs the thumb actually rests on.
        val faceR = minOf(ref * 0.088f, (barW - barPad) / 4.5f)
        val clusterTop = h - bottomInsetPx - ref * 0.03f - faceR - faceR * 2.3f - faceR
        val cxAssist = (barFrom + barTo) / 2f
        val pillW = baseR * 1.42f
        val pillH = baseR * 0.55f
        // Clear of the arcade row above it (centred on inset + 1.7% + ref*0.05).
        val pillTop = topInsetPx + h * 0.017f + ref * 0.05f +
            pillH / 2f + ref * 0.022f
        assistRect = RectF(cxAssist - pillW / 2f, pillTop,
            cxAssist + pillW / 2f, pillTop + pillH)
        if (!assistExpanded) return
        // Expanded: a 2 x 3 grid filling the band between pill and cluster.
        val gridTop = pillTop + pillH + ref * 0.022f
        val gridBottom = clusterTop - ref * 0.022f
        if (gridBottom <= gridTop) return
        val cols = 2
        val rows = (macros.size + cols - 1) / cols
        val gapX = ref * 0.018f
        val gapY = ref * 0.014f
        val cellW = ((barW - barPad * 2f) - (cols - 1) * gapX) / cols
        val cellH = ((gridBottom - gridTop) - (rows - 1) * gapY) / rows
        val gridW = cols * cellW + (cols - 1) * gapX
        val startX = cxAssist - gridW / 2f
        macros.forEachIndexed { i, item ->
            val col = i % cols
            val row = i / cols
            val left = startX + col * (cellW + gapX)
            val top = gridTop + row * (cellH + gapY)
            val rc = RectF(left, top, left + cellW, top + cellH)
            macroButtons.add(MacroBtn(rc, item.first, item.second))
            Log.w("VirtualPadView",
                "assist ${item.first} cx=${rc.centerX().toInt()} cy=${rc.centerY().toInt()}")
        }
    }

    /**
     * Is (x, y) on the FIXED stick disc? The grab radius is the visible ring
     * plus a thumb-tolerance margin so a slightly-off press still registers —
     * but unlike a floating pad the pivot stays at [stickCx]/[stickCy], which is
     * the whole point: fighting-game commands need a stationary reference.
     * A MOBA-style "the stick jumps to wherever you touched" pad is unusable for
     * quarter-circles, because ↓↘→ becomes a different physical gesture on every
     * grab and the muscle memory never forms.
     */
    private fun hitStick(x: Float, y: Float): Boolean {
        val grabR = baseR * 1.35f
        val dx = x - stickCx
        val dy = y - stickCy
        return dx * dx + dy * dy <= grabR * grabR
    }

    /**
     * Stop Android's edge gestures from stealing pad input.
     *
     * Swiping in from the left/right/bottom edge is "back" / "recents" at the
     * system level. A thumb that starts near the edge to flick the floating
     * stick therefore threw the app out of the foreground mid-move. Declaring
     * the pad's own touch regions as gesture-exclusion rects hands those
     * gestures back to the game: back/recents still work from the top strip and
     * from the (now small) uncovered middle, but never from the controls.
     *
     * Android caps the total excluded length per edge (200dp) and only honours
     * the part of a rect nearest that edge, so each rect is a thin band hugging
     * its edge rather than the whole control block.
     */
    private fun applySystemGestureExclusion(w: Int, h: Int) {
        if (Build.VERSION.SDK_INT < 29) return
        // Two hard constraints from the platform:
        //  1. Only ~200dp of exclusion is honoured per edge, and only the part
        //     of a rect NEAREST that edge — so a full-height band silently loses
        //     its far half (this bit us: the stick lives in the lower half).
        //  2. A rect only counts if it actually TOUCHES the edge it is declared
        //     for; an interior rectangle excludes nothing.
        // So each rect is a thin band anchored on an edge, sized to overlap the
        // controls that sit against that edge. The stick is lifted clear of the
        // bottom strip by layoutStick, but the left/right columns still need
        // cover because a thumb resting there sweeps horizontally.
        val dens = resources.displayMetrics.density.coerceAtLeast(1f)
        val cap = (200f * dens).toInt().coerceAtLeast(1)
        // Depth into the screen, capped by the per-edge budget.
        val depth = (ref * 0.16f).coerceAtLeast(1f).toInt().coerceAtMost(cap)
        val rects = ArrayList<android.graphics.Rect>(3)
        // Left edge, lower two-thirds: the stick's column.
        rects.add(android.graphics.Rect(0, h - cap, depth, h))
        // Right edge, lower two-thirds: the A/B/C/D cluster.
        rects.add(android.graphics.Rect(w - depth, h - cap, w, h))
        // Bottom edge: a capped strip under the stick column (recents / home).
        rects.add(android.graphics.Rect(0, h - depth, cap, h))
        // The top edge stays un-excluded on purpose so the status-bar
        // pull-down and the system back gesture from the top keep working.
        systemGestureExclusionRects = rects
        Log.w("VirtualPadView",
            "stick-layout w=$w h=$h dens=$dens cap=$cap depth=$depth " +
                "homeCx=${stickHomeCx.toInt()} homeCy=${stickHomeCy.toInt()} " +
                "baseR=${baseR.toInt()} gap=${edgeGap.toInt()} rects=${rects.size}")
    }

    /**
     * Ask the system to stop interpreting the current touch as an edge gesture.
     *
     * [View.setSystemGestureExclusionRects] only protects the rectangle that
     * actually overlaps an edge, and the platform caps that at 200dp per edge —
     * so a thumb that starts on the stick (well inside the screen) and sweeps
     * outward still gets claimed by the back/recents gesture. `requestDisallow-
     * SystemGesture()` is the framework's per-touch override for exactly this,
     * but it is @hide, so it is reached by reflection. The resolved [Method] is
     * cached (and a failure is remembered) so the hot touch path pays for the
     * lookup at most once.
     */
    private val disallowGestureMethod: Method? by lazy {
        try {
            View::class.java.getMethod("requestDisallowSystemGesture")
                .also { it.isAccessible = true }
        } catch (_: Throwable) { null }
    }

    private fun claimSystemGesture() {
        try {
            disallowGestureMethod?.invoke(this)
        } catch (_: Throwable) { /* OEM build without the API — rects still apply */ }
    }

    private fun updateStick(x: Float, y: Float) {
        var dx = x - stickCx
        var dy = y - stickCy
        val travel = (baseR - knobR).coerceAtLeast(1f)
        val mag = hypot(dx, dy)
        if (mag > travel) { dx = dx / mag * travel; dy = dy / mag * travel }
        stickDx = dx; stickDy = dy
    }

    /** Map the current knob offset to digital d-pad bits.
     *  - STICK  : large dead-zone, 8-way per-axis (diagonals are the
     *             natural intersection of two cardinals that both pass
     *             their threshold).
     *  - DPAD8  : small dead-zone, 8-way per-axis (same output, tighter
     *             centre so fighting-game motion inputs are reproducible).
     *  - DPAD4  : 4-way snap. The knob angle (atan2) is quantised to the
     *             nearest cardinal with a 45° wedge, so only ONE direction
     *             bit is ever asserted — side-scrollers / platformers that
     *             don't understand diagonal input get the response they
     *             expect from a real NES d-pad. */
    private fun stickMask(): Int {
        if (stickPointer < 0) return 0
        val travel = (baseR - knobR).coerceAtLeast(1f)
        val dz = travel * deadzone
        val mag = hypot(stickDx, stickDy)
        if (mag < dz) return 0
        if (stickMode == StickMode.DPAD4) {
            // 4-way snap: pick the cardinal whose axis the angle is closest
            // to. 45° wedge so a perfectly diagonal press still resolves to
            // its "closer" cardinal. This is what makes the stick usable
            // for action games that only have 4 directional states.
            val ang = Math.toDegrees(kotlin.math.atan2(stickDy.toDouble(), stickDx.toDouble()))
            // Normalise to (-180, 180]; atan2 already is.
            val a = if (ang < -157.5) ang + 360 else ang
            return when {
                a in -22.5..22.5 -> BUTTON_RIGHT
                a in 22.5..67.5 -> BUTTON_DOWN or BUTTON_RIGHT      // dead zone, won't normally fire
                a in 67.5..112.5 -> BUTTON_DOWN
                a in 112.5..157.5 -> BUTTON_DOWN or BUTTON_LEFT      // dead zone
                a in 157.5..180.0 || a in -180.0..-157.5 -> BUTTON_LEFT
                a in -157.5..-112.5 -> BUTTON_UP or BUTTON_LEFT      // dead zone
                a in -112.5..-67.5 -> BUTTON_UP
                else -> BUTTON_UP or BUTTON_RIGHT                    // -67.5..-22.5 dead zone
            }
        }
        var m = 0
        if (stickDx < -dz) m = m or BUTTON_LEFT
        else if (stickDx > dz) m = m or BUTTON_RIGHT
        if (stickDy < -dz) m = m or BUTTON_UP
        else if (stickDy > dz) m = m or BUTTON_DOWN
        return m
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        // Virtual d-pad mode (useDpadUi OR stickMode == DPAD4) is deliberately NOT a separate
        // dispatch path. The four cardinals are hit-tested in the
        // ACTION_DOWN branch below, in the same slot the analog stick
        // occupies, so the right-hand face buttons, the 1P/2P pill, the 招式
        // assist palette and the menu all stay live while the d-pad is
        // showing. Short-circuiting to a d-pad-only handler here is exactly
        // what used to make the whole right side of the pad stop reacting.
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val i = event.actionIndex
                val id = event.getPointerId(i)
                val x = event.getX(i); val y = event.getY(i)
                val b = hit(x, y)
                when {
                    togglePointer < 0 && toggleRect?.contains(x, y) == true -> {
                        // Press on the 1P/2P selector — the flip happens on
                        // release (only when the finger lifts on the pill).
                        togglePointer = id
                        invalidate()
                    }
                    menuPointer < 0 && menuRect?.contains(x, y) == true -> {
                        // Collapsible action menu — expand/collapse on release.
                        menuPointer = id
                        invalidate()
                    }
                    assistPointer < 0 && assistRect?.contains(x, y) == true -> {
                        // Assist palette pill — expand/collapse on release.
                        assistPointer = id
                        invalidate()
                    }
                    // A macro (one-button special) hit plays its frame sequence
                    // immediately; releasing cancels it (no loop).
                    macroPointer < 0 && hitMacro(x, y) != null -> {
                        macroPointer = id
                        hitMacro(x, y)?.let {
                            Log.w("VirtualPadView", "macro play ${it.label} size=${it.seq.size}")
                            macroListener?.onMacro(it.seq)
                        }
                        invalidate()
                    }
                    // A real button hit wins over the stick (so the GBA "L"
                    // pill, also on the left edge, still works).
                    b != 0 -> held[id] = b
                    // Virtual d-pad mode: the four cardinals take the analog
                    // stick's slot, hit-tested AFTER the real buttons so the
                    // right-hand cluster stays pressable. The decorative
                    // centre disc resolves to 0 (a deliberate no-op), which
                    // keeps stray taps in the dead space from asserting a
                    // direction.
                    useDpadUi || stickMode == StickMode.DPAD4 -> held[id] = hitDpad(x, y)
                    // The stick is a FIXED disc, not a floating one: a press must
                    // land on the resting disc (a generous radius — the visible
                    // ring plus a margin for sloppy thumbs) to grab it. This is
                    // what makes fighting-game motion inputs reproducible: the
                    // pivot never moves under the finger, so ↓↘→ is the same
                    // physical gesture every time instead of depending on where
                    // the thumb happened to land. A MOBA-style "stick jumps to
                    // the finger" pad is unusable for quarter-circles.
                    hitStick(x, y) -> {
                        stickPointer = id
                        updateStick(x, y)
                    }
                    else -> held[id] = 0
                }
                // Claim the system gestures for the duration of this touch.
                // The static exclusion rects only cover the parts of the edge
                // that overlap the controls; asking the system to hand the
                // gesture to the app while a finger is down is what actually
                // stops an edge swipe from tearing the app away. Called via
                // reflection because it is a @hide framework API — harmless
                // no-op if the OEM build does not expose it.
                claimSystemGesture()
                emit()
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.pointerCount) {
                    val id = event.getPointerId(i)
                    when (id) {
                        stickPointer -> updateStick(event.getX(i), event.getY(i))
                        togglePointer -> { /* selector ignores drag */ }
                        menuPointer -> { /* menu ignores drag */ }
                        else -> {
                            val px = event.getX(i); val py = event.getY(i)
                            // D-pad mode: hit() only knows the face-button
                            // rects, so a finger held on the pad would be
                            // zeroed the moment it moved. Inside the disc the
                            // wedge decides; ON the tiny centre dot the finger
                            // keeps the direction it already had, so sliding
                            // straight across the middle (↑→↓, ←→→) does not
                            // drop the input for the few pixels it takes to
                            // cross centre — the way a physical pad rocks
                            // instead of briefly releasing. Leaving the disc
                            // falls through to hit(), which both releases the
                            // direction and still lets a thumb slide onto a
                            // face button.
                            if ((useDpadUi || stickMode == StickMode.DPAD4) && insideDpadDisc(px, py)) {
                                val db = hitDpad(px, py)
                                val prev = (held[id] ?: 0) and dirMask
                                held[id] = when {
                                    // Centre dot: keep going the way we were.
                                    db == 0 -> prev
                                    // Noise ring: once committed to a
                                    // direction, hold it until the finger is
                                    // out far enough for the angle to be
                                    // meaningful.
                                    prev != 0 && nearDpadCentre(px, py) -> prev
                                    else -> db
                                }
                            } else {
                                held[id] = hit(px, py)
                            }
                        }
                    }
                }
                emit()
            }
            MotionEvent.ACTION_POINTER_UP -> {
                val i = event.actionIndex
                val id = event.getPointerId(i)
                when (id) {
                    stickPointer -> {
                        stickPointer = -1; stickDx = 0f; stickDy = 0f
                    }
                    togglePointer -> {
                        // Tap (release still on the pill) flips 1P <-> 2P.
                        val onPill = toggleRect?.contains(event.getX(i), event.getY(i)) == true
                        togglePointer = -1
                        if (onPill) {
                            playerPort = if (playerPort == 0) 1 else 0
                        }
                    }
                    menuPointer -> flipMenu(event.getX(i), event.getY(i))
                    assistPointer -> flipAssist(event.getX(i), event.getY(i))
                    // A macro plays its full queued sequence once it is triggered,
                    // independent of how long the finger stays down — clearing it
                    // here would wipe the in-flight frames on a quick tap (the
                    // 8–14 frame motion never completes, so the special never
                    // fires). Just free the pointer slot; the native queue drains
                    // on its own and macroMask_ returns to 0 when it empties.
                    macroPointer -> { macroPointer = -1 }
                    else -> held.remove(id)
                }
                emit()
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                // A plain tap lifts as ACTION_UP (the final pointer), not
                // ACTION_POINTER_UP — handle the selector flip here too,
                // otherwise a single-finger tap on 1P/2P never toggles.
                if (event.actionMasked == MotionEvent.ACTION_UP &&
                    togglePointer == event.getPointerId(0)) {
                    val onPill = toggleRect?.contains(event.getX(0), event.getY(0)) == true
                    if (onPill) playerPort = if (playerPort == 0) 1 else 0
                }
                if (event.actionMasked == MotionEvent.ACTION_UP &&
                    menuPointer == event.getPointerId(0)) {
                    flipMenu(event.getX(0), event.getY(0))
                }
                if (event.actionMasked == MotionEvent.ACTION_UP &&
                    assistPointer == event.getPointerId(0)) {
                    flipAssist(event.getX(0), event.getY(0))
                }
                held.clear()
                stickPointer = -1; stickDx = 0f; stickDy = 0f
                togglePointer = -1
                menuPointer = -1
                assistPointer = -1
                // Leave any in-flight macro running (see POINTER_UP note) — just
                // free the slot instead of cancelling.
                if (macroPointer >= 0) macroPointer = -1
                emit()
            }
        }
        return true
    }

    private fun hit(x: Float, y: Float): Int {
        for (b in buttons) if (b.rect.contains(x, y)) return b.mask
        return 0
    }

    private fun hitMacro(x: Float, y: Float): MacroBtn? =
        macroButtons.firstOrNull { it.rect.contains(x, y) }

    /** Expand/collapse the arcade action menu when the pill is tapped. */
    private fun flipMenu(x: Float, y: Float) {
        val inside = menuRect?.contains(x, y) == true
        menuPointer = -1
        if (inside) {
            menuExpanded = !menuExpanded
            // Actions disappear while collapsing — drop any stale press.
            held.clear()
            if (width > 0 && height > 0) buildButtons(width, height)
        }
        emit()
    }

    /** Expand/collapse the NEOGEO assist palette when its pill is tapped. */
    private fun flipAssist(x: Float, y: Float) {
        val inside = assistRect?.contains(x, y) == true
        assistPointer = -1
        if (inside) {
            assistExpanded = !assistExpanded
            // Keys vanish on collapse, so a press left "held" on one of them
            // would never receive its release again.
            if (!assistExpanded) macroPointer = -1
            if (width > 0 && height > 0) buildButtons(width, height)
        }
        emit()
    }

    private fun emit() {
        var mask = stickMask()
        for (b in held.values) mask = mask or b
        if (mask and BUTTON_SELECT != 0 && joinHint != null) joinHint = null
        // DIAGNOSTIC: log the mask actually pushed to the runner on every
        // change, so a logcat trace shows whether the direction bits survive
        // alongside the attack buttons (combo debugging).
        if (mask != lastLoggedMask) {
            lastLoggedMask = mask
            Log.i("VirtualPadView", "pad mask=0x${mask.toString(16)} port=$playerPort " +
                "stickPtr=$stickPointer stickDx=${"%.1f".format(stickDx)} stickDy=${"%.1f".format(stickDy)} " +
                "held=${held.values.joinToString(",") { "0x" + it.toString(16) }}")
        }
        listener?.onChanged(mask, playerPort)
        // The pressed visuals are driven from `held`; a plain View does not
        // redraw on touch by itself, so request the repaint explicitly.
        invalidate()
    }

    /** Drop every held button (e.g. on backgrounding when no UP will arrive). */
    fun releaseAll() {
        val hadMacro = macroPointer >= 0
        val hadAssist = assistPointer >= 0
        if (hadMacro) { macroListener?.onClear(); macroPointer = -1 }
        if (held.isNotEmpty() || togglePointer >= 0 || menuPointer >= 0 ||
            hadAssist || hadMacro) {
            held.clear()
            togglePointer = -1
            menuPointer = -1
            assistPointer = -1
            emit()
        }
    }

    private fun active(mask: Int) = held.containsValue(mask)

    // 0=up 1=down 2=left 3=right
    private val arrowPath = Path()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (useDpadUi || stickMode == StickMode.DPAD4) drawDpad(canvas) else drawStick(canvas)
        for (b in buttons) {
            when (b.shape) {
                Shape.CIRCLE -> drawCircle(canvas, b.rect, b.mask, b.label)
                Shape.PILL -> drawPill(canvas, b.rect, b.mask, b.label)
            }
        }
        for (mb in macroButtons) drawMacroBtn(canvas, mb)
        toggleRect?.let { drawPlayerToggle(canvas, it) }
        menuRect?.let { drawMenuPill(canvas, it) }
        assistRect?.let { drawAssistPill(canvas, it) }
        if (joinHint != null &&
            (profile == Profile.MAME || profile == Profile.NEOGEO)) {
            drawJoinHint(canvas, joinHint!!)
        }
    }

    /**
     * Guest 2P one-line join coach mark (arcade netplay). A translucent pill
     * parked just under the top action row; disappears on the first coin.
     */
    private fun drawJoinHint(c: Canvas, text: String) {
        val padX = ref * 0.05f
        val halfH = ref * 0.045f
        val cx = width / 2f
        val cy = topInsetPx + height * 0.017f + ref * 0.05f + ref * 0.12f
        val halfW = (textPaint.measureText(text) / 2f) + padX
        val rc = RectF(cx - halfW, cy - halfH, cx + halfW, cy + halfH)
        c.drawRoundRect(rc, halfH, halfH, hintFillPaint)
        c.drawRoundRect(rc, halfH, halfH, strokePaint)
        drawLabel(c, rc, text, false)
    }

    /**
     * Collapsible action-menu pill (arcade profiles). Shows "菜单" while
     * collapsed and "收起" while expanded; amber outline marks the open
     * state so it is obvious one more tap hides the row again.
     */
    private fun drawMenuPill(c: Canvas, rc: RectF) {
        val pressed = menuPointer >= 0
        val pr = if (pressed) RectF(rc).apply { inset(pressInset, pressInset) } else rc
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
                        if (pressed) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
                        if (menuExpanded || pressed) strokeActivePaint else strokePaint)
        drawLabel(c, pr, if (menuExpanded) "收起" else "菜单", pressed)
    }

    /**
     * Assist-palette pill (NEOGEO). Shows "招式" collapsed and "收起" expanded;
     * the amber outline marks the open state so one more tap obviously hides the
     * palette again.
     */
    private fun drawAssistPill(c: Canvas, rc: RectF) {
        val pressed = assistPointer >= 0
        val pr = if (pressed) RectF(rc).apply { inset(pressInset, pressInset) } else rc
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
            if (pressed) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
            if (assistExpanded || pressed) strokeActivePaint else strokePaint)
        drawLabel(c, pr, if (assistExpanded) "收起" else "招式", pressed)
    }

    /**
     * Draw the arcade 1P/2P selector pill. The current choice is the label
     * ("1P"/"2P"); the pill is amber-filled while 2P is selected so the mode
     * is obvious at rest, and gets the press inset while a finger is on it.
     */
    private fun drawPlayerToggle(c: Canvas, rc: RectF) {
        val pressed = togglePointer >= 0
        val pr = if (pressed) RectF(rc).apply { inset(pressInset, pressInset) } else rc
        val twoP = playerPort == 1
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
                        if (twoP) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f,
                        if (twoP || pressed) strokeActivePaint else strokePaint)
        drawLabel(c, pr, if (twoP) "2P" else "1P", twoP)
    }

    private fun drawStick(c: Canvas) {
        if (stickPointer < 0) {
            // Idle: the resting disc shows the fixed pivot the thumb will find
            // (it never moves — a moving pivot breaks fighting-game inputs).
            drawStickBase(c, stickHomeCx, stickHomeCy, false)
            c.drawCircle(stickHomeCx, stickHomeCy, knobR, knobPaint)
            c.drawCircle(stickHomeCx, stickHomeCy, knobR, knobStrokePaint)
        } else {
            // Active: the base stays at the fixed centre; a direction line +
            // knob visualise the live steering angle (the bitmask itself stays
            // 8-way, which is what these digital retro pads consume).
            drawStickBase(c, stickCx, stickCy, true)
            val kx = stickCx + stickDx; val ky = stickCy + stickDy
            c.drawLine(stickCx, stickCy, kx, ky, strokeActivePaint)
            c.drawCircle(kx, ky, knobR, fillActivePaint)
            c.drawCircle(kx, ky, knobR, strokeActivePaint)
        }
    }

    private fun drawStickBase(c: Canvas, cx: Float, cy: Float, active: Boolean) {
        val stroke = if (active) strokeActivePaint else strokePaint
        c.drawCircle(cx, cy, baseR, fillPaint)
        c.drawCircle(cx, cy, baseR, stroke)
        c.drawCircle(cx, cy, baseR * 0.62f, stroke)
        // Faint chevrons at the four cardinals — diagonals are equally
        // reachable (the mask is 8-way); the chevrons are just a nudge.
        val rr = baseR * 0.78f
        drawChevron(c, cx, cy - rr, 0)
        drawChevron(c, cx, cy + rr, 1)
        drawChevron(c, cx - rr, cy, 2)
        drawChevron(c, cx + rr, cy, 3)
    }

    private fun drawChevron(c: Canvas, mx: Float, my: Float, dir: Int) {
        val aw = baseR * 0.13f // triangle half-width
        val ah = baseR * 0.17f // triangle height
        arrowPath.rewind()
        when (dir) {
            0 -> { // up
                arrowPath.moveTo(mx, my - ah / 2)
                arrowPath.lineTo(mx - aw, my + ah / 2)
                arrowPath.lineTo(mx + aw, my + ah / 2)
            }
            1 -> { // down
                arrowPath.moveTo(mx, my + ah / 2)
                arrowPath.lineTo(mx - aw, my - ah / 2)
                arrowPath.lineTo(mx + aw, my - ah / 2)
            }
            2 -> { // left
                arrowPath.moveTo(mx - ah / 2, my)
                arrowPath.lineTo(mx + ah / 2, my - aw)
                arrowPath.lineTo(mx + ah / 2, my + aw)
            }
            else -> { // right
                arrowPath.moveTo(mx + ah / 2, my)
                arrowPath.lineTo(mx - ah / 2, my - aw)
                arrowPath.lineTo(mx - ah / 2, my + aw)
            }
        }
        arrowPath.close()
        c.drawPath(arrowPath, arrowPaint)
    }

    private fun drawCircle(c: Canvas, rc: RectF, bit: Int, label: String) {
        val on = active(bit)
        val rad = abs(rc.width()) / 2 - (if (on) pressInset else 0f)
        c.drawCircle(rc.centerX(), rc.centerY(), rad,
                     if (on) fillActivePaint else fillPaint)
        c.drawCircle(rc.centerX(), rc.centerY(), rad,
                     if (on) strokeActivePaint else strokePaint)
        drawLabel(c, rc, label, on)
    }

    private fun drawPill(c: Canvas, rc: RectF, bit: Int, label: String) {
        val on = active(bit)
        val pr = if (on) RectF(rc).apply { inset(pressInset, pressInset) } else rc
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f, if (on) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f, if (on) strokeActivePaint else strokePaint)
        drawLabel(c, pr, label, on)
    }

    /** One-button special-move pill; amber while its macro is playing. */
    private fun drawMacroBtn(c: Canvas, mb: MacroBtn) {
        val on = macroPointer >= 0
        val pr = if (on) RectF(mb.rect).apply { inset(pressInset, pressInset) } else mb.rect
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f, if (on) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, ref * 0.05f, ref * 0.05f, if (on) strokeActivePaint else strokePaint)
        drawLabel(c, pr, mb.label, on)
    }

    // ---------- Virtual d-pad UI mode (useDpadUi = true) ----------

    /** The four direction bits — lets a carried direction be told apart
     *  from a face-button mask riding in the same `held` slot. */
    private val dirMask = BUTTON_UP or BUTTON_DOWN or BUTTON_LEFT or BUTTON_RIGHT

    /** Is the point on the d-pad's live disc (wedges + centre dot)? */
    private fun insideDpadDisc(x: Float, y: Float): Boolean {
        if (dpadOuterR <= 0f) return false
        return hypot(x - stickHomeCx, y - stickHomeCy) <= dpadOuterR
    }

    /** Inside the hysteresis ring, where the wedge angle is noise-dominated. */
    private fun nearDpadCentre(x: Float, y: Float): Boolean =
        hypot(x - stickHomeCx, y - stickHomeCy) < dpadHoldR

    /**
     * Which cardinal the given point maps to.
     *
     * The drawn arm rects are deliberately NOT the hit area. Four separate
     * squares left the diagonals — and the whole centre — dead, so a thumb
     * sliding ↑ → → dropped the direction bit mid-turn and the walk stopped.
     * Instead the disc the arms sit on is split into four 45° wedges, the
     * same quantisation [stickMask] uses for its DPAD4 mode, so the entire
     * control is live and the direction tracks the thumb continuously.
     */
    private fun hitDpad(x: Float, y: Float): Int {
        if (dpadOuterR <= 0f) return 0
        val dx = x - stickHomeCx
        val dy = y - stickHomeCy
        val dist = hypot(dx, dy)
        if (dist > dpadOuterR || dist < dpadDeadR) return 0
        val ang = Math.toDegrees(kotlin.math.atan2(dy.toDouble(), dx.toDouble()))
        return when {
            ang >= -45.0 && ang < 45.0 -> BUTTON_RIGHT
            ang >= 45.0 && ang < 135.0 -> BUTTON_DOWN
            ang >= 135.0 || ang < -135.0 -> BUTTON_LEFT
            else -> BUTTON_UP
        }
    }

    /** Render the 4-cardinal + centre d-pad. The analog stick is hidden. */
    private fun drawDpad(c: Canvas) {
        val cx = stickHomeCx
        val cy = stickHomeCy
        // Connecting crosshair so the four buttons read as ONE control. The
        // geometry comes from layoutDpad() (dpadR / dpadArmW) so the drawn
        // cross and the arm rects cannot drift apart.
        val r = dpadR
        val armW = dpadArmW
        val cross = RectF(cx - armW / 2, cy - r, cx + armW / 2, cy + r)
        c.drawRoundRect(cross, armW / 2, armW / 2, fillPaint)
        val crossH = RectF(cx - r, cy - armW / 2, cx + r, cy + armW / 2)
        c.drawRoundRect(crossH, armW / 2, armW / 2, fillPaint)
        drawDpadBtn(c, dpadUp,    "↑", held.containsValue(BUTTON_UP))
        drawDpadBtn(c, dpadDown,  "↓", held.containsValue(BUTTON_DOWN))
        drawDpadBtn(c, dpadLeft,  "←", held.containsValue(BUTTON_LEFT))
        drawDpadBtn(c, dpadRight, "→", held.containsValue(BUTTON_RIGHT))
        // Centre cap. The whole disc is LIVE (see hitDpad) apart from a tiny
        // anti-jitter dot, so this stays filled: a hollow centre reads as
        // "don't press here" and hides the fact that sliding across the
        // middle keeps the direction held the whole way.
        c.drawCircle(cx, cy, armW / 2, fillPaint)
        c.drawCircle(cx, cy, armW / 2, strokePaint)
    }

    private fun drawDpadBtn(c: Canvas, rc: RectF, glyph: String, pressed: Boolean) {
        val pr = if (pressed) RectF(rc).apply { inset(pressInset, pressInset) } else rc
        c.drawRoundRect(pr, pr.width() / 2, pr.width() / 2,
            if (pressed) fillActivePaint else fillPaint)
        c.drawRoundRect(pr, pr.width() / 2, pr.width() / 2,
            if (pressed) strokeActivePaint else strokePaint)
        drawLabel(c, pr, glyph, pressed)
    }

    private fun drawLabel(c: Canvas, rc: RectF, label: String, on: Boolean) {
        val p = if (on) textActivePaint else textPaint
        val baseline = rc.centerY() - (p.descent() + p.ascent()) / 2
        c.drawText(label, rc.centerX(), baseline, p)
    }
}
