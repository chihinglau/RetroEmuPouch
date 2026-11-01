package com.retroemupouch.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.graphics.drawable.Drawable
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.retroemupouch.app.netplay.NetplaySessionCfg
import com.retroemupouch.app.netplay.NpLog
import com.retroemupouch.app.netplay.PlayBootstrapClient
import com.retroemupouch.app.netplay.PlayBootstrapClient.SramResult
import com.retroemupouch.app.netplay.PlayBootstrapServer
import com.retroemupouch.app.netplay.atomicWriteWithBackup
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.CRC32
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Screen-relative layout helper. Converts percentage values (0..1) to
 * pixel values based on the device's current screen dimensions.
 *
 * Used by [EmulatorActivity] (and any future view that wants the same
 * behaviour) so the in-game UI scales identically across phones — a 5"
 * device, the HBN-AL00 reference, or a tablet all render the same
 * proportions without per-device tuning. Captured once in
 * [EmulatorActivity.onCreate] from `resources.displayMetrics`.
 *
 * Conventions:
 *  - [wp] horizontal dimensions (margins, gaps, button widths).
 *  - [hp] vertical dimensions (top margins, panel paddings, button
 *    heights).
 *  - [sp] control sizes (icons, knobs) — the shorter of width/height so
 *    a landscape phone and a portrait phone get the same visual size.
 *
 * Every input is expected in 0..1; values outside that range are passed
 * through as-is, so callers can also express "0.5dp above safeTopPx" by
 * mixing fractions and pixel offsets at the call site.
 */
private class Sizing(wPx: Int, hPx: Int) {
    /** Current screen width in raw pixels. */
    val w: Float = wPx.toFloat()
    /** Current screen height in raw pixels. */
    val h: Float = hPx.toFloat()
    /** Shorter of [w] / [h] — the "short side" used for control sizing. */
    val min: Float = minOf(w, h)

    /** Pixel value equal to [pct] (0..1) of the current screen width. */
    fun wp(pct: Float): Int = (w * pct + 0.5f).toInt()
    /** Pixel value equal to [pct] (0..1) of the current screen height. */
    fun hp(pct: Float): Int = (h * pct + 0.5f).toInt()
    /** Pixel value equal to [pct] (0..1) of the shorter screen dimension. */
    fun sp(pct: Float): Int = (min * pct + 0.5f).toInt()
}

/**
 * Full-screen native emulation screen.
 *
 * Pacing: a dedicated high-priority native thread steps the core on an absolute
 * CLOCK_MONOTONIC timeline at the libretro AV rate (NES NTSC ~60.0988 fps),
 * independent of the GL/display refresh (60/90/120 Hz) so a 120 Hz panel does
 * not run the game at 2x speed and GL-driver jitter cannot drop an emulated
 * frame. The GL thread only pumps the latest published frame and presents it.
 *
 * Benchmark mode (bench_* intent extras): virtual pad is scripted, overlay hidden;
 * after warm-up + sample windows the runner writes filesDir/bench/<id>.json and the
 * activity finishes automatically. logcat is unavailable on the HarmonyOS 4.2 AOSP
 * compat layer, so all evidence lives in files (bench/ + logs/).
 */
class EmulatorActivity : Activity() {

    private lateinit var glView: GLSurfaceView
    private lateinit var pad: VirtualPadView
    private lateinit var hud: TextView
    private var handle = 0L
    private var benchMode = false
    // Set by 重开: recreate() pauses the old instance first, whose onPause
    // must not re-snapshot the state we are about to delete.
    private var restarting = false
    // Decrypted ROM cache file (lives in filesDir/rom_cache). Non-null
    // only when the launched ROM was an MGS1-locked ZIP. Deleted in
    // onDestroy so the plaintext is gone as soon as the activity tears
    // down.
    private var plainRom: java.io.File? = null
    private var speedButton: Button? = null
    private val speedSteps = intArrayOf(1, 2, 4, 6, 8)
    private var speedIndex = 0
    // Corner toolbar (≡ top-left, ✕ top-right, expanding pill panel).
    // Stored as fields so the WindowInsets listener (see onCreate) can
    // re-anchor them below the status bar — a fixed 6dp topMargin sinks
    // them behind the system bar on phones with a tall bar or punch-hole
    // (e.g. Xiaomi / MIUI).
    private var menuIconLp: FrameLayout.LayoutParams? = null
    private var exitIconLp: FrameLayout.LayoutParams? = null
    private var menuPanelLp: FrameLayout.LayoutParams? = null
    private var menuIcon: View? = null
    private var exitIcon: View? = null
    private var menuPanel: View? = null

    // Root view + deferred-chrome bookkeeping. The corner toolbar is built
    // only after the first real layout pass (not from onCreate's
    // displayMetrics): Android VM containers (Zhuoyitong on HarmonyOS NEXT,
    // etc.) may report portrait metrics at create time and rotate the
    // window afterwards, while configChanges means onCreate never re-runs.
    // Sizing from the laid-out view — plus re-flow on size changes — keeps
    // the chrome anchored in every container rotation.
    private lateinit var root: FrameLayout
    private var chromeInstalled = false
    private var chromeW = 0
    private var chromeH = 0
    private var chromeInsetTop = 0

    // ------------------------------------------------------------ netplay
    private var npCfg: NetplaySessionCfg? = null
    private var npServer: PlayBootstrapServer? = null
    private var npClient: PlayBootstrapClient? = null
    private var npOverlay: TextView? = null
    private var npStat: TextView? = null
    private var npWifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private val npExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "np-ctl").apply { isDaemon = true }
    }
    /** Guest counts this after the pre-init SRAM sync; host counts it at once. */
    private val npGateInit = CountDownLatch(1)
    /** GL thread counts this after core init + the geometry probe frame. */
    private val npCoreReady = CountDownLatch(1)
    @Volatile private var npEnded = false
    @Volatile private var npRunning = false
    @Volatile private var npPaused = false
    private var npPausedTotalMs = 0L
    private var npPausedSinceMs = 0L

    // Netplay-safe one-button special moves: the macro is replayed frame by
    // frame into the SAME local-mask channel the pad uses (renderer.buttonMask,
    // pushed per frame via nativeNetplayLocalMask), so the sequence is just
    // ordinary local input and cannot desync the pair — unlike
    // nativePlayMacro, which bypasses the per-frame bitmask.
    @Volatile private var npPadMask = 0
    @Volatile private var npMacroMask = 0
    private val npMacroHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var npMacroPending: Runnable? = null
    // Wall-clock start of the peer's current negotiated pause (0 = not
    // paused); drives the 15 s remote-pause watchdog in onNetplayStats.
    private var npRemotePausedSinceMs = 0L
    private var npLastFrames = -1L
    private var npStallPolls = 0
    private var npDroppedHandled = false
    private var npFailFinished = false
    // Bootstrap failed before the core was created: release the GL gate so it
    // does not burn its own 40 s timeout and stack a second error dialog.
    private val npBootAborted = java.util.concurrent.atomic.AtomicBoolean(false)
    // Guest gate wait runs from the frame loop (never inside
    // onSurfaceCreated): buffers swapped during that callback are not shown
    // and the system keeps the white starting window up, so the parked guest
    // would stare at a blank white screen for the whole SRAM sync.
    @Volatile private var npBootDeferred = false
    @Volatile private var npBootDeadlineNs = 0L

    /**
     * Screen-relative layout helper for the corner toolbar / panel /
     * HUD. Initialised at the top of [onCreate] from
     * `resources.displayMetrics` so every dimension (icon size, margin,
     * panel button size, HUD gap) is a fraction of the screen and stays
     * in proportion on every phone — no per-device tuning required.
     */
    private lateinit var sizing: Sizing

    // Cheat commands (null in bench mode / when the ROM has no index entry).
    private var romRelPath: String? = null
    private var cheats: MutableList<CheatCommand>? = null
    private val cheatLock = Any()
    // Per-game storage key (CRC32 hex when indexed, else ROM file base).
    private lateinit var saveKey: String

    private val renderer = EmuRenderer()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The theme (shared NormalTheme) is light and paints a white window;
        // the emulator surface is black, so never flash white behind it.
        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.BLACK))
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Capture screen dimensions *once* per onCreate. Resources.displayMetrics
        // is updated by Android on rotation / fold / multi-window before onCreate
        // fires, so the values already reflect the current orientation; every
        // later percentage (icon size, corner margin, panel button, HUD gap, …)
        // is a fraction of these pixels and stays in proportion on every phone.
        sizing = Sizing(
            resources.displayMetrics.widthPixels,
            resources.displayMetrics.heightPixels
        )

        val romExtra = intent.getStringExtra("rom")
        val benchRom = intent.getStringExtra("bench_rom")
        benchMode = benchRom != null
        val romRel = benchRom ?: romExtra
        if (romRel == null) { finish(); return }
        val romFile = File(filesDir, romRel)
        // Locked-ROM path: the on-disk file is a single-entry .zip whose
        // payload is the MGS1-encrypted ROM. Materialise the plaintext in
        // the app-private cache and pass *that* to the native runner; we
        // never expose the cipher bytes or the decrypted bytes past the
        // session. `plainRom` is deleted in onDestroy.
        plainRom = if (romFile.name.endsWith(".zip", ignoreCase = true) ||
                        isLikelyMgs1(romFile) ||
                        isLikelyZip(romFile)) {
            val coreForLaunch = (intent.getStringExtra("core")
                ?: intent.getStringExtra("bench_core"))
                ?.takeIf { it.isNotBlank() } ?: "fceumm"
            try { LockedRom.materialize(filesDir, romFile, coreForLaunch) } catch (e: Throwable) {
                Log.e("GS-Rom", "decrypt failed: ${e.message}"); finish(); return
            }
        } else null
        val saveDir = File(filesDir, "saves").apply { mkdirs() }.absolutePath
        val sysDir = File(filesDir, "system").apply { mkdirs() }.absolutePath
        val logDir = File(filesDir, "logs").apply { mkdirs() }
        val logPath = File(logDir, "run-${System.currentTimeMillis()}.log").absolutePath
        NpLog.init(logDir)
        NpLog.log("EmulatorActivity onCreate pid=${android.os.Process.myPid()}")

        glView = GLSurfaceView(this).apply {
            setEGLContextClientVersion(2)
            // Keep the EGL context across background/foreground when the
            // driver allows it; the renderer also tolerates full recreation
            // (core state lives in the native runner, not in GL objects).
            preserveEGLContextOnPause = true
            setRenderer(renderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        // Battery saves and quick-save states are keyed by the ROM's stable
        // CRC32 so different games can never share a save file; fall back to
        // the file base name for unindexed ROMs (benchmark / sideloaded).
        val crcKey = CheatStore.crcKey(filesDir, romRel)
        val baseName = romFile.nameWithoutExtension
        saveKey = crcKey ?: baseName
        // Netplay sessions always key saves by the signaling CRC. A malformed
        // config is rejected before touching the runner.
        npCfg = NetplaySessionCfg.from(intent)
        if (npCfg == null) {
            NpLog.log("netplay cfg absent (intent has np_* extras? " +
                "role=${intent.getIntExtra("np_role", -1)} " +
                "peer=${intent.getStringExtra("np_peer_ip")}:" +
                "${intent.getIntExtra("np_bootstrap_port", -1)} " +
                "room=${intent.getIntExtra("np_room_id", 0)})")
        } else {
            NpLog.log("netplay cfg role=${npCfg!!.role} peer=${npCfg!!.peerIp} " +
                "peerPort=${npCfg!!.peerUdpPort} localPort=${npCfg!!.localUdpPort} " +
                "bootPort=${npCfg!!.bootstrapPort} room=${npCfg!!.roomId} " +
                "D=${npCfg!!.initialD} keyLen=${npCfg!!.sessionKey.length} save=${npCfg!!.saveKey}")
        }
        npCfg?.let { saveKey = it.saveKey }
        runningSaveKey = saveKey
        // When the input is locked, point the runner at the plaintext
        // materialised above; otherwise at the file as-is. Saves / quick-
        // state still key off the locked file's name so they stay valid
        // across launches.
        val runnerRom = plainRom?.absolutePath ?: romFile.absolutePath
        renderer.romPath = runnerRom
        renderer.saveDir = saveDir
        renderer.systemDir = sysDir
        renderer.logPath = logPath
        renderer.saveKey = saveKey
        renderer.coreId = (intent.getStringExtra("core")
            ?: intent.getStringExtra("bench_core"))
            ?.takeIf { it.isNotBlank() } ?: "fceumm"
        renderer.benchSeconds = intent.getIntExtra("bench_seconds", 0)
        renderer.netCfg = npCfg
        // Load local / cloud-synced cheats before the GL thread inits the
        // core; the renderer seeds them right after retro_load_game().
        // Netplay forbids cheats entirely (determinism): the list stays null.
        if (!benchMode && npCfg == null) {
            romRelPath = romRel
            cheats = CheatStore.load(filesDir, romRel)
        }
        // Safe insets are derived from the surface size in onSurfaceChanged():
        // every platform plays on the same reserved "stage" (at least the NES
        // 8:7 side bars, enlarged where a profile's controls need more room),
        // so the picture never slides under the pad / corner menu. Benchmark
        // mode keeps a full-screen surface.
        renderer.onBenchDone = { finish() }
        renderer.onFatal = { msg -> runOnUiThread {
            // A plain Toast disappears before the user can read it (the
            // activity finishes immediately), which reads as a silent crash.
            // Keep a modal dialog up so the concrete reason is visible.
            AlertDialog.Builder(this)
                .setTitle("游戏无法启动")
                .setMessage(msg)
                .setCancelable(false)
                .setPositiveButton("返回文件库") { _, _ -> finish() }
                .show()
        } }

        root = FrameLayout(this)
        // Black backdrop: while the guest parks the GL thread on the
        // bootstrap gate, no frame can be drawn — without this the window
        // shows the default white background behind "正在同步存档…".
        root.setBackgroundColor(Color.BLACK)
        root.addView(glView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
        ))

        hud = TextView(this).apply {
            setTextColor(Color.YELLOW)
            textSize = 10.5f
            setLineSpacing(2f, 1f)
            setBackgroundColor(Color.argb(90, 0, 0, 0))
            setPadding(10, 6, 10, 6)
            visibility = if (benchMode) View.INVISIBLE else View.VISIBLE
        }
        root.addView(hud, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START
        ).apply {
            // Initial placement is short-lived — [layoutHud] re-anchors
            // against safeTopPx after the first GL frame arrives. Small
            // percentages keep the HUD inside the play field until then
            // without relying on per-device tuning.
            topMargin = sizing.hp(0.04f)
            marginStart = sizing.wp(0.04f)
        })

        if (!benchMode) {
            pad = VirtualPadView(this)
            // Load the user-editable fight-assist palette (波/升/旋/超 …)
            // before any layout pass, so the very first draw already uses
            // the configured scripts. Falls back to the KOF97 defaults
            // shipped in `assets/moves_presets.json` when the on-disk
            // `library/moves.json` is missing / corrupt, so a brand-new
            // install still renders the familiar palette.
            try {
                val cfg = SpecialMovesStore.load(filesDir, applicationContext)
                pad.setMacros(cfg.activeProfile().moves.map {
                    it.label to runCatching { ScriptCompiler.compile(it.script) }
                        .getOrElse { IntArray(0) }
                })
                Log.i("GS-Emu",
                    "moves loaded active=${cfg.activeProfileId} " +
                    "moves=${cfg.activeProfile().moves.size}")
            } catch (t: Throwable) {
                Log.w("GS-Emu", "moves load failed: ${t.message}")
            }
            pad.profile = VirtualPadView.Profile.from(
                intent.getStringExtra("core"),
                intent.getStringExtra("platform"),
                romFile.name)
            // Netplay: the driven port is fixed by the session role, so the
            // arcade 1P/2P toggle is hidden; the mask still routes through
            // renderer.buttonMask but is pushed via nativeNetplayLocalMask.
            if (npCfg != null) {
                pad.portLocked = true
                // Coin-op guest sees the same picture at once but only spawns
                // as 2P after coin+START — surface that instead of letting it
                // look like the second pad "does nothing".
                if (npCfg!!.role == 1 &&
                    (pad.profile == VirtualPadView.Profile.MAME ||
                     pad.profile == VirtualPadView.Profile.NEOGEO)) {
                    pad.joinHint = "你是 2P：右上「菜单」→ 投币 → 开始 加入游戏"
                }
            }
            pad.listener = VirtualPadView.OnButtonsChanged { mask, port ->
                npPadMask = mask
                renderer.buttonMask = mask or npMacroMask
                renderer.playerPort = port
            }
            // One-button special moves (fighting games). The compiled per-frame
            // mask sequence is replayed through the SAME 50 ms/step channel the
            // on-screen pad uses (renderer.buttonMask, OR-ed over the live pad),
            // for BOTH solo and netplay. This mirrors the HarmonyOS JS replay
            // exactly: it releases on every step change and emits a final release
            // frame, so combos latch AND the buttons always let go — unlike the
            // old native nativePlayMacro path, which held the last frame and left
            // the input stuck ("组合按键释放不出来"). Netplay stays desync-free
            // because each step is just ordinary local input the lockstep gate
            // already transmits.
            pad.macroListener = object : VirtualPadView.OnMacro {
                override fun onMacro(seq: IntArray) {
                    if (handle == 0L) return
                    startNpMacro(seq)
                }
                override fun onClear() {
                    cancelNpMacro()
                }
            }
            root.addView(pad, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
            ))
            // Corner toolbar (功能/✕/pop-out panel) is installed lazily by
            // installChrome() once the root view reports real pixels — see
            // the layout listener registered after setContentView.
        } else {
            pad = VirtualPadView(this) // unused, keeps renderer contract simple
        }

        // Netplay phase overlay + live session HUD.
        npCfg?.let { cfg ->
            npOverlay = TextView(this).apply {
                text = "正在建立联机…"
                setTextColor(Color.WHITE)
                textSize = 16f
                gravity = Gravity.CENTER
                setBackgroundColor(Color.argb(210, 0, 0, 0))
                visibility = View.VISIBLE
            }
            root.addView(npOverlay, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            npStat = TextView(this).apply {
                setTextColor(Color.WHITE)
                textSize = 11f
                setBackgroundColor(Color.argb(120, 0, 0, 0))
                setPadding(14, 5, 14, 5)
                visibility = View.GONE
            }
            root.addView(npStat, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            ).apply { topMargin = sizing.hp(0.045f).toInt() })
            acquireNetplayWifiLock()
            // Host's core boot has no precondition; the guest waits until its
            // SRAM pull finishes so the core loads the host's battery save.
            if (cfg.isHost) npGateInit.countDown()
            NpLog.log("np-ctl dispatch isHost=${cfg.isHost}")
            npExecutor.execute {
                try {
                    if (cfg.isHost) hostBootstrap(cfg) else guestBootstrap(cfg)
                } catch (t: Throwable) {
                    NpLog.log("bootstrap FAILED ${t.javaClass.name}: ${t.message} | " +
                        (t.stackTrace.take(3).joinToString(" < ") {
                            "${it.fileName}:${it.lineNumber} ${it.methodName}" }))
                    Log.e("GS-Netplay", "bootstrap failed", t)
                    netplayFail("联机启动失败：${t.message ?: "网络错误"}")
                }
            }
        }

        renderer.onStageChanged = { runOnUiThread { layoutHud() } }

        // ----- apply persisted settings (see AppSettings on the Dart side) -----
        applyPersistedSettings()

        setContentView(root)
        hud.post { layoutHud() }
        preferHighRefreshMode()

        // Re-anchor the corner toolbar under the system status bar /
        // display cutout. On Honor with a translucent bar a fixed 6dp
        // margin is fine; on Xiaomi/MIUI the bar is opaque and taller
        // (≈96px on most 2025-era Redmi/K phones, more on devices with
        // a centred punch-hole), which would hide the ≡ / ✕ icons.
        // The listener survives rotation and is also the source of truth
        // when a VM container reports its insets late; applyChromeTopInset
        // re-anchors the lazily-installed toolbar (or just remembers the
        // value until installChrome runs).
        root.setOnApplyWindowInsetsListener { _, insets ->
            // Chrome row only needs the top (status bar / cutout).
            val statusBar = insets.getInsets(
                android.view.WindowInsets.Type.statusBars()
                    or android.view.WindowInsets.Type.displayCutout()
            )
            applyChromeTopInset(statusBar.top)
            // The GL stage needs every edge: on edge-to-edge layouts
            // (Android 15, Zhuoyitong on HarmonyOS NEXT) the surface runs
            // under the floating status/navigation bars and the picture
            // would otherwise be painted beneath them (looks cropped).
            if (!benchMode) {
                val bars = insets.getInsets(
                    android.view.WindowInsets.Type.statusBars()
                        or android.view.WindowInsets.Type.navigationBars()
                        or android.view.WindowInsets.Type.displayCutout()
                )
                renderer.setSystemInsets(bars.left, bars.top, bars.right, bars.bottom)
            }
            // Don't consume — let GL surface still get insets if it wants.
            insets
        }

        // Install the corner toolbar from the *real laid-out pixels* (not
        // onCreate's displayMetrics), and re-flow it whenever the window
        // changes size — covers VM containers that create the activity in
        // portrait metrics and rotate it into landscape afterwards without
        // recreating it (configChanges).
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            if (benchMode) return@addOnLayoutChangeListener
            val w = root.width
            val h = root.height
            if (w <= 0 || h <= 0) return@addOnLayoutChangeListener
            root.post {
                if (!chromeInstalled) installChrome(w, h)
                else onChromeSizeChanged(w, h)
            }
        }
        // Initial dispatch in case the view tree was already laid out
        // before the listener was attached (some OEMs fire insets twice).
        root.requestApplyInsets()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // configChanges keeps this activity alive across the container's
        // rotation; the layout listener normally re-flows everything, give
        // it one more nudge after resources have settled.
        if (::root.isInitialized) root.post {
            val w = root.width
            val h = root.height
            if (w > 0 && h > 0) {
                if (!chromeInstalled) installChrome(w, h)
                else onChromeSizeChanged(w, h)
            }
        }
    }

    /**
     * Build and attach the corner toolbar (功能 opener · ✕ exit · pop-out
     * panel) sized from the window's real laid-out pixels [w]×[h]. Runs
     * exactly once, on the first valid layout pass. Pill pixel sizes only
     * depend on the short side, which is identical before/after a
     * portrait<->landscape swap of a fullscreen window, so later swaps are
     * handled by [onChromeSizeChanged] without rebuilding the pills.
     */
    private fun installChrome(w: Int, h: Int) {
        if (chromeInstalled || benchMode || w <= 0 || h <= 0) return
        chromeInstalled = true
        chromeW = w
        chromeH = h
        sizing = Sizing(w, h)

        val menu = buildMenuBar(sizing, netplay = npCfg != null)
        val marginV  = sizing.hp(0.017f)   // ~6dp on 360dp-tall
        val marginH  = sizing.wp(0.017f)   // ~6dp on 360dp-wide
        val panelGap = sizing.wp(0.012f)   // matches pad inter-pill gap
        val pillW    = sizing.sp(0.1988f)
        val pillH    = sizing.sp(0.077f)
        // Pills are shorter than the legacy circular icon; nudge the whole
        // top row down by half the difference so the row stays centred on
        // the same band it used to occupy.
        val rowNudge = (sizing.sp(0.10f) - pillH) / 2

        // Top-left: "功能" opener pill.
        val menuLp = FrameLayout.LayoutParams(
            pillW, pillH, Gravity.TOP or Gravity.START
        ).apply { topMargin = marginV + rowNudge; marginStart = marginH }
        root.addView(menu.first, menuLp)

        // Top-right: compact round exit "✕".
        val exitLp = FrameLayout.LayoutParams(
            pillH, pillH, Gravity.TOP or Gravity.END
        ).apply { topMargin = marginV + rowNudge; marginEnd = marginH }
        root.addView(menu.second, exitLp)

        // Pop-out panel level with the opener, extending to its right.
        menuPanelLp = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.START
        ).apply {
            topMargin = marginV + rowNudge
            // Subtract the first pill's own start margin (wp 0.006) so the
            // opener->first-pill gap equals one panelGap, exactly like the
            // pad's expanded row.
            marginStart = marginH + pillW + panelGap - sizing.wp(0.006f)
        }
        root.addView(menu.third, menuPanelLp)

        menuIconLp = menuLp
        exitIconLp = exitLp
        menuIcon = menu.first
        exitIcon = menu.second
        menuPanel = menu.third

        applyChromeTopInset(chromeInsetTop)
        // Netplay live-stats row uses a height-fraction top margin too.
        npStat?.let {
            val lp = it.layoutParams as FrameLayout.LayoutParams
            lp.topMargin = sizing.hp(0.045f)
            it.layoutParams = lp
        }
        root.requestApplyInsets()
        layoutHud()
    }

    /**
     * Re-flow toolbar margins after an orientation / window-size swap.
     * Short-side is unchanged by a 90° swap, so pill sizes stay valid;
     * only width/height-fraction margins and the inter-pill gaps move.
     */
    private fun onChromeSizeChanged(w: Int, h: Int) {
        if (!chromeInstalled || w <= 0 || h <= 0) return
        if (w == chromeW && h == chromeH) return
        chromeW = w
        chromeH = h
        sizing = Sizing(w, h)

        val marginH  = sizing.wp(0.017f)
        val panelGap = sizing.wp(0.012f)
        val pillW    = sizing.sp(0.1988f)
        menuIconLp?.let {
            it.marginStart = marginH
            menuIcon?.layoutParams = it
        }
        exitIconLp?.let {
            it.marginEnd = marginH
            exitIcon?.layoutParams = it
        }
        menuPanelLp?.let {
            it.marginStart = marginH + pillW + panelGap - sizing.wp(0.006f)
            menuPanel?.layoutParams = it
        }
        // Inter-pill gaps inside the pop-out panel are width fractions.
        (menuPanel as? LinearLayout)?.let { ll ->
            for (i in 0 until ll.childCount) {
                (ll.getChildAt(i).layoutParams as? LinearLayout.LayoutParams)?.let { clp ->
                    clp.marginStart = sizing.wp(0.006f)
                    clp.marginEnd = sizing.wp(0.006f)
                }
            }
        }
        applyChromeTopInset(chromeInsetTop)
        npStat?.let {
            val lp = it.layoutParams as FrameLayout.LayoutParams
            lp.topMargin = sizing.hp(0.045f)
            it.layoutParams = lp
        }
        layoutHud()
    }

    /**
     * Push the chrome row's bottom edge (window coordinates) to the virtual
     * pad so its R/L / SELECT / START stack clears the 功能/✕ row on every
     * device — including VM containers that don't push the full-screen pad
     * view down by the status-bar inset.
     */
    private fun notifyPadChromeBottom() {
        if (benchMode || !chromeInstalled || !::pad.isInitialized) return
        val top = chromeInsetTop + sizing.hp(0.017f) +
            (sizing.sp(0.10f) - sizing.sp(0.077f)) / 2f
        // root is fullscreen at window-Y 0, so local Y == window Y here.
        pad.setTopChromeBottom(top + sizing.sp(0.077f))
    }

    /**
     * Sit every corner control [insetTop] pixels below the system bar /
     * display cutout (plus the screen-relative 1.7% floor). Remembers the
     * latest inset even before the toolbar is installed.
     */
    private fun applyChromeTopInset(insetTop: Int) {
        chromeInsetTop = insetTop
        if (!chromeInstalled) return
        val topMargin = insetTop + sizing.hp(0.017f) +
            (sizing.sp(0.10f) - sizing.sp(0.077f)) / 2
        menuIconLp?.let { it.topMargin = topMargin; menuIcon?.layoutParams = it }
        exitIconLp?.let { it.topMargin = topMargin; exitIcon?.layoutParams = it }
        menuPanelLp?.let { it.topMargin = topMargin; menuPanel?.layoutParams = it }
        notifyPadChromeBottom()
    }

    /**
     * Read settings the user picked in the Flutter Settings sheet (which
     * persists via shared_preferences) and reflect them in this native
     * activity. SharedPreferences from `flutter` and Kotlin share the
     * same backing file under the standard app user data directory.
     *
     * Modern shared_preferences (≥ 2.x) writes its entries to a file
     * named `FlutterSharedPreferences.xml` under the app's shared_prefs
     * directory; older releases used `flutter.0.xml` / `flutter.1.xml`.
     * We open the modern file directly to stay compatible with the
     * version bundled in pubspec.
     */
    private fun applyPersistedSettings() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        // FPS HUD overlay — visibility is the single source of truth.
        val showHud = prefs.getBoolean("flutter.showFpsHud", true)
        if (::hud.isInitialized) hud.visibility = if (showHud) View.VISIBLE else View.GONE

        // Virtual pad mode (stickMode / deadzone / useDpadUi) — only
        // applied when the pad is in use; the bench-mode placeholder has
        // no surface to update. Read stickDeadzone as String (NOT getFloat)
        // because `shared_preferences.setDouble` writes base64-encoded bytes
        // which throw ClassCastException on getFloat — the Flutter app writes
        // the human-readable form ("0.18") via setString + toString().
        if (::pad.isInitialized) {
            val mode = prefs.getString("flutter.stickMode", "DPAD8")
            pad.stickMode = when (mode) {
                "STICK" -> VirtualPadView.StickMode.STICK
                "DPAD4" -> VirtualPadView.StickMode.DPAD4
                else -> VirtualPadView.StickMode.DPAD8
            }
            val dz = prefs.getString("flutter.stickDeadzone", "0.18")
                ?.toFloatOrNull() ?: 0.18f
            pad.deadzone = dz
            pad.useDpadUi = prefs.getBoolean("flutter.useDpadUi", false)
            // 用户可配置布局: 整体缩放(默认 1.0) + 整体平移(相对屏幕宽/高的比例)。
            pad.padScale = prefs.getString("flutter.padScale", "1.0")
                ?.toFloatOrNull()?.coerceIn(0.5f, 2.5f) ?: 1.0f
            pad.padOffsetX = prefs.getString("flutter.padOffsetX", "0.0")
                ?.toFloatOrNull()?.coerceIn(-0.45f, 0.45f) ?: 0.0f
            pad.padOffsetY = prefs.getString("flutter.padOffsetY", "0.0")
                ?.toFloatOrNull()?.coerceIn(-0.45f, 0.45f) ?: 0.0f
            // 布局变化需要重算几何, 否则下一帧 onSizeChanged 才会生效。
            pad.requestLayout()
        }

        // "Fast-forward audio when ×N" — when off, we override the per-
        // frame audio rate so the audio buffer is silenced during fast-
        // forward; when on, audio speeds up proportionally with the
        // emulation rate (current default behaviour). We mark it here so
        // cycleSpeed() can check the pref when toggling the rate.
        fastForwardAudioPref = prefs.getBoolean("flutter.fastForwardAudio", true)

        // "Remember last game" — restore the last save slot the user was
        // playing so 「继续游戏」 lands on the exact last frame.
        rememberLastGamePref = prefs.getBoolean("flutter.rememberLastGame", true)
        if (rememberLastGamePref) {
            val slot = prefs.getInt("flutter.lastSaveSlot", -1)
            if (slot in 0..SLOT_COUNT - 1) {
                val f = slotStateFile(slot)
                if (f.exists()) renderer.loadSlot(f)
            }
        }
    }

    /**
     * In-memory mirror of the Flutter-side preferences. Mutated by
     * [applyPersistedSettings] at activity create; consulted by the
     * menu actions (cycleSpeed, saveToSlot, …) when they need to honour
     * the user's settings live.
     */
    private var fastForwardAudioPref: Boolean = true
    private var rememberLastGamePref: Boolean = true

    /**
     * Place the FPS/xruns readout in the free side bar, hugging the game
     * frame's left edge. It sits two rows ([HUD_LIFT_DP]) above vertical
     * centre, so it never overlaps the L shoulder or the stick; clamped to
     * stay below the top-left menu bar. In portrait (no side bar) it falls
     * back to the top strip under the shoulder row.
     */
    private fun layoutHud() {
        if (!::hud.isInitialized || hud.visibility != View.VISIBLE) return
        hud.post {
            val parentW = (hud.parent as? View)?.width ?: 0
            val parentH = (hud.parent as? View)?.height ?: 0
            if (hud.measuredWidth <= 0 || parentW <= 0 || parentH <= 0) return@post
            val lp = hud.layoutParams as FrameLayout.LayoutParams
            lp.gravity = Gravity.TOP or Gravity.START
            // Top-center of the picture area. We sit a screen-relative
            // fraction below safeTopPx (the top of the picture) so the
            // readout doesn't hug the status-bar inset; we horizontally
            // centre on the picture axis so it stays clear of both
            // corner buttons. Reading is a quick glance up rather than
            // obstructing the playfield.
            val picCx = (parentW + renderer.safeLeftPx - renderer.safeRightPx) / 2f
            lp.topMargin = (renderer.safeTopPx + sizing.hp(0.011f)).toInt()
            lp.marginStart = (picCx - hud.measuredWidth / 2f).toInt()
            hud.layoutParams = lp
        }
    }

    /**
     * Ask the panel for its highest refresh mode (120 Hz when available). The
     * emulated Dendy/PAL core produces 50 fps: at 60 Hz each frame is held for
     * 1 or 2 vsyncs (16.7/33.3 ms) while at 120 Hz it is held for 2 or 3
     * (16.7/25 ms), so the duplicated-frame judder during horizontal scroll is
     * roughly halved. Falls back silently when the platform refuses the mode.
     */
    @Suppress("DEPRECATION")
    private fun preferHighRefreshMode() {
        try {
            val display = windowManager.defaultDisplay
            val best = display.supportedModes
                .filter { it.physicalWidth == display.mode.physicalWidth &&
                          it.physicalHeight == display.mode.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: return
            // Ask every way the platform understands; some vendors honour only
            // one of mode id / float rate, and HarmonyOS may clamp app requests
            // entirely, in which case we silently stay at 60 Hz.
            val lp = window.attributes
            lp.preferredDisplayModeId = best.modeId
            lp.preferredRefreshRate = best.refreshRate
            window.attributes = lp
        } catch (_: Throwable) { }
    }

    /**
     * Build the floating corner toolbar as two corner icons + one
     * horizontal popup panel.
     *
     *  - Top-left: a single 36dp "≡" circle icon. Tapping expands a pill
     *  panel to the **right** of the icon (same Y, no second row below)
     *  containing five commands: 加速 · 重开 · 金手 · 存档 · 读档.
     *  - Top-right: a dedicated "✕" exit circle icon, always on, with a
     *  red accent so it reads as "back to library". Hoisted out of the
     *  panel because users frequently want to leave the game and the
     *  exit command is the single most-common transition.
     *  - Tapping the left icon again, tapping the panel background, or
     *  tapping a panel button (which fires its action) collapses the
     *  panel.
     *
     * Geometry is in screen-percentage terms (icons at the top corners,
     *  panel anchored to the icon's right edge) so the layout scales
     * identically on every phone size.
     *
     * @return Triple(menuIcon, exitIcon, panel) — both icons are always
     *   visible; the panel starts hidden.
     */
    private fun buildMenuBar(sizing: Sizing, netplay: Boolean = false): Triple<View, View, View> {
        // Every panel / button / icon dimension is a fraction of the
        // current screen (see [Sizing]). Reference: HBN-AL00 landscape
        // (~640×360dp, 411dp tall playfield). The percentages reproduce
        // the prior 36dp icon / 6dp margin / 4dp gap / 20dp panel radius
        // / 15dp button radius / 52×32dp button / 1dp stroke / 2dp
        // horizontal padding on that device; on any other phone the
        // proportions stay the same so the toolbar still looks correct.

        // ---------- panel + button factories (same look as before) ----------

        fun panel() = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            // No backing plate and no padding: like the virtual pad's
            // expanded action row, the five commands are free-floating
            // individual pills. The opener-to-panel gap (below) compensates
            // for the first child's start margin so spacing matches the
            // pad's 1.2%-of-width inter-pill rhythm exactly.
            setPadding(0, 0, 0, 0)
            background = null
            // Tapping the panel background (outside any button) collapses
            // the panel — gives users a way to dismiss without finding the
            // corner icon again. LinearLayout's setOnClickListener doesn't
            // catch taps that don't land on a child button, so we use a
            // touch listener with explicit hit-testing on the gaps.
            isClickable = true
            isFocusable = true
            setOnTouchListener { v, ev ->
                if (ev.actionMasked == android.view.MotionEvent.ACTION_UP) {
                    val hitBtn = (0 until childCount).any { i ->
                        getChildAt(i).let { c ->
                            ev.x >= c.left && ev.x <= c.right &&
                            ev.y >= c.top && ev.y <= c.bottom
                        }
                    }
                    if (!hitBtn) v.visibility = View.GONE
                }
                false
            }
        }

        // All corner controls share ONE visual language with the virtual
        // pad's collapsible pills (VirtualPadView pillW/pillH =
        // ref*0.1988 x ref*0.077, corner radius ref*0.05, translucent
        // white fill + white hairline, amber fill while pressed) so the
        // native toolbar and the touch overlay read as one UI.
        val pillWpx = sizing.sp(0.1988f)
        val pillHpx = sizing.sp(0.077f)

        fun pillDrawable(accent: Int, pressed: Boolean): Drawable =
            GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                // Radius exceeds half the pill height -> fully rounded caps.
                cornerRadius = sizing.sp(0.05f).toFloat()
                if (pressed) {
                    setColor(Color.argb(205, 255, 193, 7))
                    setStroke(sizing.sp(0.0072f), Color.argb(245, 255, 235, 170))
                } else {
                    setColor(Color.argb(56, 255, 255, 255))
                    val strokeA = if (accent == Color.WHITE) 150 else 210
                    setStroke(sizing.sp(0.0056f),
                              Color.argb(strokeA, Color.red(accent),
                                         Color.green(accent), Color.blue(accent)))
                }
            }

        fun pill(label: String, accent: Int, action: () -> Unit): Button =
            Button(this).apply {
                text = label
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX,
                            sizing.sp(0.042f).toFloat())
                setTextColor(android.content.res.ColorStateList(
                    arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf()),
                    intArrayOf(Color.rgb(45, 32, 0), accent)
                ))
                typeface = android.graphics.Typeface.DEFAULT
                minWidth = 0; minimumWidth = 0
                minHeight = 0; minimumHeight = 0
                stateListAnimator = null
                setPadding(0, 0, 0, 0)
                isAllCaps = false
                includeFontPadding = false
                background = StateListDrawable().apply {
                    addState(intArrayOf(android.R.attr.state_pressed), pillDrawable(accent, true))
                    addState(intArrayOf(), pillDrawable(accent, false))
                }
                setOnClickListener { action() }
            }

        fun LinearLayout.addBtn(v: Button) {
            // Each popped-out command is one pad pill; 0.6% side margins
            // reproduce the overlay's 1.2%-of-width inter-pill gap.
            addView(v, LinearLayout.LayoutParams(pillWpx, pillHpx).apply {
                marginStart = sizing.wp(0.006f); marginEnd = sizing.wp(0.006f)
            })
        }

        // Single panel containing five commands (exit moved to its own
        // top-right corner icon). Labels stay two Chinese characters so
        // all five pills fit the compact button row.
        val panel = panel()
        if (netplay) {
            // Lockstep session: cheats / fast-forward / save slots / restart
            // would all break determinism — only pause negotiation remains.
            panel.addBtn(pill("暂停", Color.WHITE) { toggleNetplayPause() })
        } else {
            speedButton = pill("加速", Color.WHITE) { cycleSpeed() }
            panel.addBtn(speedButton!!)
            panel.addBtn(pill("摇杆", Color.WHITE) { cycleStickMode() })
            panel.addBtn(pill("重开", Color.WHITE) { confirmRestart() })
            panel.addBtn(pill("金手", Color.WHITE) { openCheatsDialog() })
            panel.addBtn(pill("存档", Color.WHITE) { renderer.saveToSlot() })
            panel.addBtn(pill("读档", Color.WHITE) { openLoadDialog() })
        }

        // ---------- collapsed corner controls (always on) ----------

        // Top-left opener: a pill identical to the pad's "菜单" pill.
        val menuIcon = pill("功能", Color.WHITE) {
            panel.visibility = if (panel.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        }
        menuIcon.layoutParams = android.widget.FrameLayout.LayoutParams(pillWpx, pillHpx)

        // Top-right "✕" exit — a compact round button just big enough for
        // the glyph: square pillH x pillH with fully rounded corners, same
        // fill/stroke family as the pills. Red accent keeps the "back to
        // library" affordance distinct from the neutral controls.
        val exitIcon = pill("✕", Color.rgb(0xEF, 0x9A, 0x9A)) { exitToLibrary() }
        exitIcon.layoutParams = android.widget.FrameLayout.LayoutParams(pillHpx, pillHpx)
        exitIcon.contentDescription = "退出到文件库"
        menuIcon.contentDescription = "功能菜单"

        panel.visibility = View.GONE
        return Triple(menuIcon, exitIcon, panel)
    }

    /** Cycles normal -> x2 -> x4 -> x6 -> x8 -> normal. */
    private fun cycleSpeed() {
        if (handle == 0L) return
        speedIndex = (speedIndex + 1) % speedSteps.size
        val mult = speedSteps[speedIndex]
        NativeBridge.nativeSetSpeed(handle, mult)
        // Honour the "fast-forward audio" setting: when off, pause the
        // audio stream entirely while running at >×1 (otherwise the
        // accelerated audio artefacts are more jarring than silence).
        val audioPaused = mult > 1 && !fastForwardAudioPref
        NativeBridge.nativeSetAudioPaused(handle, audioPaused)
        speedButton?.text = "加速×$mult"
        Toast.makeText(
            this,
            when {
                mult == 1 -> "已恢复常速"
                audioPaused -> "游戏加速 ×$mult（音效已静音以保证稳定性）"
                else -> "游戏加速 ×$mult（音效同步加快）"
            },
            Toast.LENGTH_SHORT
        ).show()
    }

    /**
     * Cycles the virtual pad's stick mode STICK -> DPAD8 -> DPAD4 -> STICK and
     * persists it, mirroring the OHOS function-menu "摇杆" command
     * (EmulatorSpike.onCommand). STICK = analog knob (8-way digital),
     * DPAD8 = low-dead-zone 8-way pad, DPAD4 = 4-way cross. The new mode is
     * applied live (VirtualPadView.StickMode's setter rebuilds + redraws) and
     * written to the shared-prefs key the Flutter SettingsSheet and
     * [applyPersistedSettings] read, so a later launch / settings open reflects
     * it.
     */
    private fun cycleStickMode() {
        if (!::pad.isInitialized) return
        val order = arrayOf(
            VirtualPadView.StickMode.STICK,
            VirtualPadView.StickMode.DPAD8,
            VirtualPadView.StickMode.DPAD4
        )
        val idx = (order.indexOf(pad.stickMode) + 1) % order.size
        val next = order[idx]
        pad.stickMode = next
        // Persist so the Flutter SettingsSheet and applyPersistedSettings stay
        // in lockstep with this in-emulator toggle.
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .edit().putString("flutter.stickMode", next.name).apply()
        val name = when (next) {
            VirtualPadView.StickMode.STICK -> "模拟摇杆"
            VirtualPadView.StickMode.DPAD8 -> "十字键(八向)"
            VirtualPadView.StickMode.DPAD4 -> "十字键(四向)"
        }
        Toast.makeText(this, "摇杆模式：$name", Toast.LENGTH_SHORT).show()
    }

    // ------------------------------------------------------------- cheats UI

    // ------------------------------------------------- save slots / load UI

    /** Automatic background snapshot; distinct CRC keys isolate games. */
    private fun stateFile() = File(filesDir, "saves/$saveKey.state")

    /** Manual save slots: up to three, rotated oldest-first. */
    private fun slotStateFile(i: Int) = File(filesDir, "saves/$saveKey.slot$i.state")
    private fun slotThumbFile(i: Int) = File(filesDir, "saves/$saveKey.slot$i.jpg")

    private data class Slot(val index: Int, val state: File, val thumb: File, val time: Long)

    /**
     * Existing slots, newest first. Enumerates the saves directory once and
     * matches the saveKey prefix (rather than probing three fixed paths), so
     * the picker reflects whatever is actually on disk.
     */
    private fun listSlots(): List<Slot> {
        val dir = File(filesDir, "saves")
        val kids = dir.listFiles() ?: return emptyList()
        val pattern = Regex(
            "^" + Regex.escape(saveKey) + "\\.slot(\\d+)\\.state$")
        return kids.mapNotNull { f ->
            val i = pattern.find(f.name)?.groupValues?.get(1)?.toIntOrNull()
                ?: return@mapNotNull null
            if (i !in 0 until SLOT_COUNT) return@mapNotNull null
            Slot(i, f, slotThumbFile(i), f.lastModified())
        }.sortedByDescending { it.time }
    }

    /**
     * Slot to write next: the first free index, otherwise the oldest of the
     * three (so the newest three saves are always kept).
     */
    private fun nextSlotIndex(): Int {
        val existing = listSlots()
        if (existing.size < SLOT_COUNT) {
            val used = existing.map { it.index }.toSet()
            return (0 until SLOT_COUNT).first { it !in used }
        }
        return existing.minByOrNull { it.time }!!.index
    }

    private fun fmtSlotTime(t: Long): String {
        val hm = SimpleDateFormat("HH:mm", Locale.getDefault())
        val md = SimpleDateFormat("M月d日", Locale.getDefault())
        val now = Calendar.getInstance()
        val then = Calendar.getInstance().apply { timeInMillis = t }
        val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
            now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
        val yest = (now.get(Calendar.YEAR) == then.get(Calendar.YEAR)) &&
            now.get(Calendar.DAY_OF_YEAR) - then.get(Calendar.DAY_OF_YEAR) == 1
        return when {
            sameDay -> "今天 ${hm.format(t)}"
            yest -> "昨天 ${hm.format(t)}"
            else -> "${md.format(t)} ${hm.format(t)}"
        }
    }

    /**
     * Deterministic light dialog context. The activity runs a legacy
     * Theme.Black/Theme.Light theme (dark window for the emulator), and EMUI
     * renders AlertDialog surfaces light while views inflated with the activity
     * context keep a white-ish textColorPrimary in dark mode — producing
     * invisible labels. Building both the dialog and its custom content views
     * from this context guarantees dark text on the light Material dialog.
     */
    private val dialogCtx: android.content.Context by lazy {
        android.view.ContextThemeWrapper(
            this, android.R.style.Theme_Material_Light_Dialog_Alert)
    }
    private fun dialogBuilder(): AlertDialog.Builder =
        AlertDialog.Builder(dialogCtx, android.R.style.Theme_Material_Light_Dialog_Alert)

    /** Load picker: thumbnail + time per slot, tap to load, long row to delete. */
    private fun openLoadDialog() {
        // Rescan on a background thread immediately before showing the
        // picker. Right after a cold launch the very first probe used to
        // race disk settling and wrongly reported "no manual saves"; scan
        // the live directory (rechecking once if empty) so that message
        // only appears when no .slotN.state file is really there.
        val holder = FrameLayout(dialogCtx).apply {
            val pb = android.widget.ProgressBar(dialogCtx)
            addView(pb, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER))
            setPadding(0, sizing.hp(0.03f).toInt(), 0, sizing.hp(0.03f).toInt())
        }
        val loading = dialogBuilder()
            .setTitle("读取存档")
            .setView(holder)
            .setNegativeButton("取消", null)
            .create()
        loading.show()
        Thread {
            var slots = listSlots()
            if (slots.isEmpty()) {
                try { Thread.sleep(300) } catch (_: InterruptedException) {}
                slots = listSlots()
            }
            val snapshot = slots
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                loading.dismiss()
                renderLoadDialog(snapshot)
            }
        }.start()
    }

    private fun renderLoadDialog(slots: List<Slot>) {
        val ctx = dialogCtx
        if (slots.isEmpty()) {
            dialogBuilder()
                .setTitle("读取存档")
                .setMessage("还没有手动存档。\n游戏中点菜单「存档」即可保存当前进度，最近 3 个存档会自动保留。")
                .setPositiveButton("知道了", null)
                .show()
            return
        }

        // All dialog dimensions are screen-relative percentages of the
        // activity's captured `sizing` (see [Sizing]). Reference: HBN-AL00
        // 360dp-wide landscape; percentages reproduce the prior dp values
        // on that device and scale with the screen elsewhere.
        val list = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(
                sizing.wp(0.022f), sizing.hp(0.011f),
                sizing.wp(0.022f), sizing.hp(0.011f)
            )
        }
        val scroll = ScrollView(ctx).apply { addView(list) }

        val dialog = dialogBuilder()
            .setTitle("读取存档（${slots.size}/$SLOT_COUNT）")
            .setView(scroll)
            .setNegativeButton("取消", null)
            .create()

        slots.forEachIndexed { ordinal, slot ->
            val row = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(
                    sizing.wp(0.028f), sizing.hp(0.022f),
                    sizing.wp(0.028f), sizing.hp(0.022f)
                )
                isClickable = true
                val outValue = android.util.TypedValue()
                context.theme.resolveAttribute(
                    android.R.attr.selectableItemBackground, outValue, true)
                setBackgroundResource(outValue.resourceId)
            }

            val thumb = ImageView(ctx).apply {
                scaleType = ImageView.ScaleType.CENTER_CROP
                if (slot.thumb.exists()) setImageBitmap(BitmapFactory.decodeFile(slot.thumb.path))
                val radius = sizing.sp(0.0167f).toFloat()
                outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(view: View, outline: android.graphics.Outline) {
                        outline.setRoundRect(0, 0, view.width, view.height, radius)
                    }
                }
                clipToOutline = true
                background = GradientDrawable().apply {
                    cornerRadius = radius
                    setColor(Color.rgb(24, 27, 38))
                }
            }
            row.addView(thumb, LinearLayout.LayoutParams(
                sizing.wp(0.267f), sizing.hp(0.20f)
            ).apply {
                marginEnd = sizing.wp(0.039f)
            })

            val texts = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
            }
            texts.addView(TextView(ctx).apply {
                text = "存档 ${ordinal + 1} · 槽位 ${slot.index + 1}"
                setTextColor(Color.rgb(0x1F, 0x23, 0x29))
                textSize = 15f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
            })
            texts.addView(TextView(ctx).apply {
                text = fmtSlotTime(slot.time)
                setTextColor(Color.rgb(0x5F, 0x66, 0x70))
                textSize = 12.5f
                setPadding(0, sizing.hp(0.0083f), 0, 0)
            })
            row.addView(texts, LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

            val del = TextView(ctx).apply {
                text = "删除"
                setTextColor(Color.rgb(0xC6, 0x28, 0x28))
                textSize = 13.5f
                setPadding(
                    sizing.wp(0.039f), sizing.hp(0.028f),
                    sizing.wp(0.0167f), sizing.hp(0.028f)
                )
                isClickable = true
                val outValue = android.util.TypedValue()
                context.theme.resolveAttribute(
                    android.R.attr.selectableItemBackground, outValue, true)
                setBackgroundResource(outValue.resourceId)
                setOnClickListener {
                    dialogBuilder()
                        .setTitle("删除该存档？")
                        .setMessage(fmtSlotTime(slot.time) + " 的存档将被删除，此操作不可撤销。")
                        .setNegativeButton("取消", null)
                        .setPositiveButton("删除") { _, _ ->
                            slot.state.delete()
                            slot.thumb.delete()
                            dialog.dismiss()
                            openLoadDialog()
                        }
                        .show()
                }
            }
            row.addView(del)

            row.setOnClickListener {
                dialog.dismiss()
                renderer.loadSlot(slot.state)
            }
            list.addView(row)

            if (ordinal != slots.lastIndex) {
                list.addView(View(ctx).apply {
                    setBackgroundColor(Color.argb(30, 0, 0, 0))
                }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply {
                    marginStart = sizing.wp(0.033f); marginEnd = sizing.wp(0.033f)
                })
            }
        }

        dialog.show()
        dialog.window?.setLayout(
            (sizing.w * 0.82f).toInt(),
            ViewGroup.LayoutParams.WRAP_CONTENT)
        // Three rows + title + button can exceed the screen height; cap the
        // scroll area at 58% so the action button is always reachable.
        scroll.post {
            val maxH = (sizing.h * 0.58f).toInt()
            if (list.height > maxH) {
                scroll.layoutParams = scroll.layoutParams.apply { height = maxH }
            }
        }
    }

    /** Restart from the title screen: drop the auto snapshot so restore skips. */
    private fun confirmRestart() {
        dialogBuilder()
            .setTitle("重新开始")
            .setMessage("将清除自动存档并回到游戏开头。\n手动保存的存档位与游戏内电池存档不受影响。")
            .setNegativeButton("取消", null)
            .setPositiveButton("重新开始") { _, _ ->
                restarting = true
                try { stateFile().delete() } catch (_: Throwable) { }
                recreate()
            }
            .show()
    }

    /** Active codes in core syntax; called on the GL thread during init. */
    private fun activeCheatCodes(): Array<String> = synchronized(cheatLock) {
        cheats?.let { CheatStore.activeCodes(it).toTypedArray() } ?: emptyArray()
    }

    /** Pushes the current command state to the core (thread-safe via GL queue). */
    private fun applyCheats() {
        if (handle == 0L) return
        val codes = activeCheatCodes()
        glView.queueEvent {
            if (handle != 0L) NativeBridge.nativeSetCheats(handle, codes)
        }
    }

    private fun persistCheats() {
        val rel = romRelPath ?: return
        val list = cheats ?: return
        try {
            CheatStore.save(filesDir, rel, list)
        } catch (e: Exception) {
            Toast.makeText(this, "金手指保存失败：${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Command-style cheat panel: players only flip named switches (无限生命)
     * and pick named values/equipment (武力值=100, 装备=剑). Codes are authored
     * on the PC manager and synced; there is deliberately no code entry here.
     */
    private fun openCheatsDialog() {
        val ctx = dialogCtx
        val list = cheats
        if (list == null) {
            Toast.makeText(this, "未找到该游戏的索引记录，无法关联金手指", Toast.LENGTH_LONG).show()
            return
        }
        // Screen-relative pad: ~12dp on the 360dp-min reference device
        // (12 / 360 = 0.033). Scaling with the screen keeps the dialog
        // rows looking the same on every phone.
        val padPx = sizing.sp(0.033f).toInt()
        val listBox = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padPx, padPx / 2, padPx, 0)
        }

        fun rerender() {
            listBox.removeAllViews()
            if (list.isEmpty()) {
                listBox.addView(TextView(ctx).apply {
                    text = "暂无金手指命令。\n\n" +
                        "请在电脑端文件库为本游戏添加命令（如「无限生命」开关、" +
                        "「武力值」选 10/50/100、「装备」选 剑/枪），同步后即可在此直接开关。"
                    textSize = 13f
                    setPadding(0, padPx / 2, 0, padPx / 2)
                })
            }
            synchronized(cheatLock) {
                list.forEach { c ->
                    when (c) {
                        is CheatCommand.Switch -> {
                            val cb = CheckBox(ctx).apply {
                                text = c.name
                                textSize = 15f
                                isChecked = c.enabled
                                setOnCheckedChangeListener { _, checked ->
                                    synchronized(cheatLock) { c.enabled = checked }
                                    persistCheats()
                                    applyCheats()
                                }
                            }
                            listBox.addView(cb)
                        }
                        is CheatCommand.Choice -> {
                            val row = LinearLayout(ctx).apply {
                                orientation = LinearLayout.HORIZONTAL
                                gravity = Gravity.CENTER_VERTICAL
                                setPadding(0, padPx / 3, 0, padPx / 3)
                            }
                            val name = TextView(ctx).apply {
                                text = c.name
                                textSize = 15f
                                layoutParams = LinearLayout.LayoutParams(
                                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                            }
                            val current = c.options.getOrNull(c.selected)?.label ?: "关"
                            val pick = Button(ctx).apply {
                                text = current
                                textSize = 13f
                                minWidth = 0
                                minimumWidth = sizing.wp(0.267f)
                                setOnClickListener {
                                    val labels =
                                        listOf("关闭") + c.options.map { it.label }
                                    val checked = intArrayOf(c.selected + 1)
                                    dialogBuilder()
                                        .setTitle(c.name)
                                        .setSingleChoiceItems(
                                            labels.toTypedArray(), checked[0]
                                        ) { dlg, which ->
                                            synchronized(cheatLock) { c.selected = which - 1 }
                                            persistCheats()
                                            applyCheats()
                                            dlg.dismiss()
                                            rerender()
                                        }
                                        .setNegativeButton("取消", null)
                                        .show()
                                }
                            }
                            row.addView(name)
                            row.addView(pick)
                            listBox.addView(row)
                        }
                    }
                }
            }
        }
        rerender()

        val scroll = ScrollView(ctx).apply { addView(listBox) }
        val dialog = dialogBuilder()
            .setTitle("金手指")
            .setView(scroll)
            .setPositiveButton("关闭", null)
            .create()
        dialog.show()
        // Keep the list area compact in landscape (dialog grows to content by
        // default; cap height to 62% of the screen).
        dialog.window?.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (sizing.h * 0.62f).toInt())
    }

    /**
     * Leave the emulator for the Flutter library. Both activities now share
     * one task (taskAffinity=""), so finish() normally lands on
     * MainActivity — but aggressive background-task cleanup (EMUI memory
     * pressure, recents swipe, installer hand-off) can leave nothing below
     * this activity, in which case plain finish() drops the user onto the
     * launcher. Routing back with CLEAR_TOP/SINGLE_TOP (re)creates the
     * library instead. Bench runs (adb-driven) finish cleanly to the shell.
     */
    private fun exitToLibrary() {
        if (benchMode) {
            finish()
            return
        }
        // Clean netplay teardown (BYE + host SRAM flush) is async; it calls
        // exitToLibrary again on the UI thread once done.
        if (npCfg != null && !npEnded) {
            endNetplay(clean = true)
            return
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        startActivity(intent)
        finish()
    }

    @Deprecated("Deprecated in Java; back must return to the library, never the launcher")
    override fun onBackPressed() {
        exitToLibrary()
    }

    // ----------------------------------------------------- netplay lifecycle

    private fun npSramFile(cfg: NetplaySessionCfg) =
        File(filesDir, "saves/${cfg.saveKey}.sav")

    private fun acquireNetplayWifiLock() {
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            val lock = wifi.createWifiLock(
                android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "GamePouch-netplay")
            lock.setReferenceCounted(false)
            lock.acquire()
            npWifiLock = lock
        } catch (t: Throwable) {
            Log.w("GS-Netplay", "wifi lock unavailable: ${t.message}")
        }
    }

    private fun releaseNetplayWifiLock() {
        try { if (npWifiLock?.isHeld == true) npWifiLock?.release() } catch (_: Throwable) {}
        npWifiLock = null
    }

    /** Run [action] on the GL thread and wait for it (native core calls). */
    private fun runOnGlBlocking(action: () -> Unit) {
        val latch = CountDownLatch(1)
        var err: Throwable? = null
        glView.queueEvent {
            try { action() } catch (t: Throwable) { err = t } finally { latch.countDown() }
        }
        if (!latch.await(15, TimeUnit.SECONDS)) {
            throw com.retroemupouch.app.netplay.BootstrapException("native timeout")
        }
        err?.let { throw it }
    }

    /**
     * Netplay-safe macro playback: pump the compiled per-frame mask sequence
     * into [renderer.buttonMask] (OR-ed over the live pad mask) on the same
     * ~50 ms/step cadance VirtualPadView uses (3 frames @ 60 fps). The GL
     * loop pushes buttonMask into nativeNetplayLocalMask every frame, so each
     * step reaches the lockstep gate exactly like a finger press — no
     * bypass, no desync.
     */
    /**
     * Netplay-safe macro playback: pump the compiled per-frame mask sequence
     * into [renderer.buttonMask] (OR-ed over the live pad mask) so the move is
     * just ordinary local input and cannot desync the pair. Cadence: every
     * [ScriptCompiler.framesPerStep] entries (one logical direction) is held for
     * 50 ms — the same "~3 frames @ 60fps" the HarmonyOS JS replay uses, so a
     * quarter-circle / dragon-punch latches on both platforms and the buttons
     * ALWAYS release (the trailing tick emits a zero mask, matching OHOS
     * cancelMacro). Used for BOTH solo and netplay now that the old native
     * nativePlayMacro path (which held the last frame and stuck the input —
     * "组合按键释放不出来") is gone.
     */
    private fun startNpMacro(seq: IntArray) {
        cancelNpMacro()
        val stepMs = 50L
        val stepFrames = ScriptCompiler.framesPerStep
        var i = 0
        val tick = object : Runnable {
            override fun run() {
                npMacroPending = null
                if (npEnded) {
                    npMacroMask = 0
                    renderer.buttonMask = npPadMask
                    return
                }
                if (i >= seq.size) {
                    // Trailing release frame: let every button go (matches
                    // HarmonyOS playMove — the move fires, then the input
                    // releases so the next press isn't stuck).
                    npMacroMask = 0
                    renderer.buttonMask = npPadMask
                    return
                }
                // Collapse framesPerStep entries into one logical step so each
                // direction is held ~stepMs — identical to the HarmonyOS replay.
                var m = 0
                repeat(stepFrames) { if (i < seq.size) m = seq[i++] }
                npMacroMask = m
                renderer.buttonMask = npPadMask or npMacroMask
                npMacroPending = this
                npMacroHandler.postDelayed(this, stepMs)
            }
        }
        tick.run()
    }

    private fun cancelNpMacro() {
        npMacroPending?.let { npMacroHandler.removeCallbacks(it) }
        npMacroPending = null
        if (npMacroMask != 0) {
            npMacroMask = 0
            renderer.buttonMask = npPadMask
        }
    }

    private fun setNpOverlay(text: String?) {
        runOnUiThread {
            val v = npOverlay ?: return@runOnUiThread
            if (text == null) {
                v.visibility = View.GONE
            } else {
                v.text = text
                v.visibility = View.VISIBLE
            }
        }
    }

    /** Host boot sequence on the np-ctl thread. */
    private fun hostBootstrap(cfg: NetplaySessionCfg) {
        NpLog.log("host bootstrap start, binding ${cfg.bootstrapPort}")
        val sram = npSramFile(cfg)
        val srv = PlayBootstrapServer(cfg.bootstrapPort, cfg.sessionKey, sram)
        npServer = srv
        srv.start()
        NpLog.log("host server bound, sram exists=${sram.exists()} size=${if (sram.exists()) sram.length() else -1}")
        setNpOverlay("正在启动核心…")
        if (!npCoreReady.await(35, TimeUnit.SECONDS)) {
            NpLog.log("host core ready timeout")
            netplayFail("核心启动超时，请返回后重试"); return
        }
        // MAME's retro_serialize/unserialize is not a complete/deterministic
        // state capture, so transferring frame-0 desyncs the two sides (the
        // guest's unserialize leaves un-captured regions different from the
        // host's live state). For mame we skip state0 entirely and rely on
        // cold-boot alignment: both devices boot the same ROM (with the
        // /sram-converged battery) to an identical frame-0, then lockstep on
        // inputs — the RetroArch/MAME-netplay style. fbalpha2012/fceumm keep
        // the state0 transfer (their serialize round-trips exactly).
        val coldBoot = renderer.coreId == "mame"
        NpLog.log(if (coldBoot) "host core ready, cold-boot align (skip state0)"
            else "host core ready, capturing state0")
        var state0: ByteArray? = null
        if (!coldBoot) {
            runOnGlBlocking {
                state0 = NativeBridge.nativeSaveState(handle)
            }
            if (state0 == null) { netplayFail("无法生成开局状态"); return }
        }
        runOnGlBlocking {
            if (!NativeBridge.nativeNetplayStart(handle, cfg.toCfgJson())) {
                throw com.retroemupouch.app.netplay.BootstrapException("UDP session start failed")
            }
            NativeBridge.nativeStartPacing(handle)
        }
        srv.publishState0(state0 ?: ByteArray(0))
        NpLog.log("host state0 published (${state0?.size ?: 0} bytes, coldBoot=$coldBoot), awaiting guest ready")
        Log.i("GS-Netplay", "host state0 published (${state0?.size ?: 0} bytes, coldBoot=$coldBoot)")
        setNpOverlay("等待伙伴准备…")
        if (!srv.awaitGuestReady()) {
            NpLog.log("host await guest ready timeout (120s)")
            netplayFail("伙伴未在 120 秒内准备好"); return
        }
        NpLog.log("host guest ready, opening start gate")
        runOnGlBlocking { NativeBridge.nativeNetplayNotifyStart(handle) }
        srv.publishStart()
        NpLog.log("host start gate published")
        onNetplayRunning()
    }

    /** Guest boot sequence on the np-ctl thread. */
    private fun guestBootstrap(cfg: NetplaySessionCfg) {
        NpLog.log("guest bootstrap start -> http://${cfg.peerIp}:${cfg.bootstrapPort}")
        setNpOverlay("正在同步存档…")
        val client = PlayBootstrapClient(cfg.peerIp, cfg.bootstrapPort, cfg.sessionKey)
        npClient = client
        val sram = npSramFile(cfg)
        // Before core init: host battery save wins; absent host SRAM means the
        // guest must also boot without one (park its own save as .preplay).
        when (val r = client.fetchSram()) {
            is SramResult.Present -> {
                NpLog.log("guest sram present ${r.data.size} bytes, writing ${sram.name}")
                atomicWriteWithBackup(sram, r.data)
            }
            is SramResult.Absent -> {
                NpLog.log("guest sram absent on host; local exists=${sram.exists()}")
                if (sram.exists()) {
                    val bak = File(sram.absolutePath + ".preplay")
                    if (!bak.exists()) sram.renameTo(bak) else sram.delete()
                }
            }
        }
        NpLog.log("guest gate(countDown init), core loading")
        npGateInit.countDown()
        if (!npCoreReady.await(35, TimeUnit.SECONDS)) {
            NpLog.log("guest core ready timeout")
            netplayFail("核心启动超时，请返回后重试"); return
        }
        // Cold-boot alignment for mame: skip the frame-0 state transfer (its
        // serialize round-trip is lossy) and boot straight from the ROM; the
        // /sram convergence above already aligned battery state. See hostBootstrap.
        val coldBoot = renderer.coreId == "mame"
        NpLog.log(if (coldBoot) "guest core ready, cold-boot align (skip state0)"
            else "guest core ready, fetching state0")
        setNpOverlay(if (coldBoot) "正在启动核心…" else "正在同步开局状态…")
        val state0 = if (coldBoot) ByteArray(0) else client.fetchState0()
        NpLog.log("guest state0 received ${state0.size} bytes (coldBoot=$coldBoot)")
        runOnGlBlocking {
            if (!coldBoot && !NativeBridge.nativeLoadState(handle, state0)) {
                throw com.retroemupouch.app.netplay.BootstrapException("state0 load failed")
            }
            if (!NativeBridge.nativeNetplayStart(handle, cfg.toCfgJson())) {
                throw com.retroemupouch.app.netplay.BootstrapException("UDP session start failed")
            }
            NativeBridge.nativeStartPacing(handle)
        }
        NpLog.log(if (coldBoot) "guest cold-boot aligned + UDP started, posting ready"
            else "guest state0 loaded + UDP started, posting ready")
        client.postReady()
        setNpOverlay("已连接，等待主机开始…")
        // The native START gate (CTRL_START over UDP) is what actually unparks
        // the emulator; the HTTP /start long-poll below is only a UI signal.
        // Run it off the critical path: a slow or dropped /start (a flaky Wi-Fi
        // long-poll can reset mid-wait) must never strand the "waiting" overlay
        // over an already-running game. Once postReady() has succeeded the core
        // is frozen at frame 0 behind the native gate, which opens the instant
        // the host starts — so dismissing the overlay here is always safe.
        npExecutor.submit {
            try {
                client.awaitStart()
                NpLog.log("guest start gate confirmed via HTTP")
            } catch (t: Throwable) {
                NpLog.log("guest awaitStart ignored (native gate drives start): ${t.message}")
            }
        }
        onNetplayRunning()
    }

    private fun onNetplayRunning() {
        npRunning = true
        runOnUiThread {
            npStat?.visibility = View.VISIBLE
            val ov = npOverlay ?: return@runOnUiThread
            val ticks = listOf("3", "2", "1", "开始！")
            var i = 0
            fun tick() {
                if (npEnded || isFinishing || isDestroyed) return
                if (i < ticks.size) {
                    ov.text = ticks[i]
                    ov.visibility = View.VISIBLE
                    i++
                    ov.postDelayed({ tick() }, 550)
                } else {
                    ov.visibility = View.GONE
                }
            }
            tick()
        }
    }

    /** Called from the GL thread at 4 Hz once the session is running. */
    private fun onNetplayStats(st: NetplayStats) {
        if (npEnded) return
        if (st.isDropped || st.isPeerBye) {
            // STATE_ENDED is the peer's CTRL_BYE (clean leave): only then may
            // the guest converge SRAM. STATE_DROPPED (10 s timeout / kill /
            // network loss) must leave the guest's old save untouched (AC-9).
            onNetplayDropped(cleanBye = st.isPeerBye)
            return
        }
        // Pause budget (spec AC-7: cumulative pause past 15 s ends the
        // session). This runs on BOTH sides: the paused side watches its own
        // cumulative time, the other side watches the peer's pause interval,
        // so a side that never taps "继续" (or stays backgrounded) can not
        // hang the partner forever waiting for a resume.
        val nowMs = android.os.SystemClock.elapsedRealtime()
        if (npPaused) {
            val liveMs = npPausedTotalMs + (nowMs - npPausedSinceMs)
            if (liveMs >= 15_000L) {
                NpLog.log("np local pause budget exhausted: ${liveMs}ms")
                onNetplayDropped("累计暂停超过 15 秒，联机结束。")
                return
            }
        } else if (st.isPaused) {
            if (npRemotePausedSinceMs == 0L) npRemotePausedSinceMs = nowMs
            if (nowMs - npRemotePausedSinceMs >= 15_000L) {
                NpLog.log("np remote pause exceeded 15s")
                onNetplayDropped("伙伴暂停超过 15 秒，联机结束。")
                return
            }
        } else {
            npRemotePausedSinceMs = 0L
        }
        val stalled = if (st.framesAdvanced == npLastFrames) {
            npStallPolls++
            true
        } else {
            npStallPolls = 0
            npLastFrames = st.framesAdvanced
            false
        }
        val stalledNow = stalled && npStallPolls >= 2
        runOnUiThread {
            npStat?.text = "RTT %.0f ms · D %d · 帧 %d%s".format(
                st.rttP50Ms, st.d, st.framesAdvanced,
                if (stalledNow) " · 等待…" else "")
            if (!npPaused && !st.isPaused) {
                setNpOverlay(if (stalledNow) "等待伙伴网络…" else null)
            } else if (!npPaused && st.isPaused) {
                setNpOverlay("伙伴已暂停，稍候…")
            }
        }
    }

    private fun onNetplayDropped(reason: String? = null, cleanBye: Boolean = false) {
        if (npDroppedHandled) return
        npDroppedHandled = true
        val cfg = npCfg ?: return
        NpLog.log("np session ended: cleanBye=$cleanBye isHost=${cfg.isHost} reason=${reason ?: "peer-state"}")
        val msg = reason
            ?: if (cfg.isHost) "客机已离开，联机结束。" else "主机已结束联机。"
        runOnUiThread {
            AlertDialog.Builder(this)
                .setTitle("连接中断")
                .setMessage(msg)
                .setCancelable(false)
                .setPositiveButton("返回文件库") { _, _ ->
                    // Pull the host's converged SRAM only after a clean BYE;
                    // timeout / force-kill / network loss keep the guest's old
                    // save per spec AC-9.
                    endNetplay(clean = false, pullFinal = cleanBye && !cfg.isHost)
                }
                .show()
        }
    }

    private fun netplayFail(msg: String) {
        if (npFailFinished || npEnded) return
        npFailFinished = true
        // Unblock a GL thread parked on the pre-init gate; it checks the flag
        // and exits silently, so only this one error dialog is shown.
        npBootAborted.set(true)
        npGateInit.countDown()
        runOnUiThread {
            AlertDialog.Builder(this)
                .setTitle("联机无法开始")
                .setMessage(msg)
                .setCancelable(false)
                .setPositiveButton("返回文件库") { _, _ -> endNetplay(clean = false) }
                .show()
        }
    }

    /** Menu 暂停 / 继续 toggle. */
    private fun toggleNetplayPause() {
        if (npEnded || handle == 0L) return
        if (!npPaused) {
            npPaused = true
            npPausedSinceMs = android.os.SystemClock.elapsedRealtime()
            NativeBridge.nativeNetplayNotifyPaused(handle, true)
            NativeBridge.nativeSetAudioPaused(handle, true)
            setNpOverlay("你已暂停，伙伴在等你\n点功能面板「继续」恢复")
        } else {
            resumeNetplay()
        }
    }

    private fun resumeNetplay() {
        if (!npPaused) return
        npPausedTotalMs += android.os.SystemClock.elapsedRealtime() - npPausedSinceMs
        if (npPausedTotalMs >= 15_000L) {
            netplayFail("累计暂停超过 15 秒，联机结束。")
            return
        }
        npPaused = false
        if (handle != 0L) {
            NativeBridge.nativeNetplayNotifyPaused(handle, false)
            NativeBridge.nativeSetAudioPaused(handle, false)
        }
        setNpOverlay(null)
    }

    /**
     * Unified teardown. [clean] distinguishes a normal exit (host flushes +
     * serves final SRAM) from aborts/drops. Guest with [pullFinal] fetches
     * the host's converged SRAM. Always safe to call once; runs off the UI
     * thread because it does socket IO.
     */
    private fun endNetplay(clean: Boolean, pullFinal: Boolean = false, finish: Boolean = true) {
        if (npEnded) return
        npEnded = true
        npRunning = false
        val cfg = npCfg ?: return
        // Tell the Dart isolate its PlaySession is over so it reaches a
        // terminal state and the next invite is not blocked by a stale
        // "session in progress" (Task 9). Best effort: if the engine is not
        // cached (process restarted straight into this activity) there is no
        // live Dart session to reset anyway.
        notifyDartPlayEnded(cfg, clean)
        npExecutor.execute {
            try {
                if (cfg.isHost) {
                    val srv = npServer
                    if (clean && handle != 0L) {
                        runCatching {
                            NativeBridge.nativeNetplayFlushSram(handle)
                            val f = npSramFile(cfg)
                            if (f.exists()) srv?.publishSramFinal(f.readBytes())
                        }
                    }
                    if (handle != 0L) NativeBridge.nativeNetplayStop(handle)
                    if (clean && srv != null) {
                        // Grace window for the guest's sram-final pull after BYE.
                        // The guest only pulls after the user taps "返回文件库"
                        // on the drop dialog: a slow reader can take well over
                        // 30 s, so keep the tiny server for 90 s, and close the
                        // moment the final SRAM has actually been delivered.
                        Thread {
                            val deadline = android.os.SystemClock.elapsedRealtime() + 90_000L
                            try {
                                while (android.os.SystemClock.elapsedRealtime() < deadline) {
                                    Thread.sleep(1_000)
                                    if (srv.finalSramServed()) break
                                }
                            } catch (_: Throwable) {}
                            NpLog.log("np bootstrap grace over, closing server")
                            srv.close()
                        }.start()
                    } else {
                        srv?.close()
                    }
                } else {
                    if (handle != 0L) NativeBridge.nativeNetplayStop(handle)
                    if (pullFinal) {
                        try {
                            val b = npClient?.fetchSramFinal()
                            if (b != null) atomicWriteWithBackup(npSramFile(cfg), b)
                        } catch (t: Throwable) {
                            Log.w("GS-Netplay", "sram-final pull failed: ${t.message}")
                        }
                    }
                }
            } catch (t: Throwable) {
                Log.w("GS-Netplay", "teardown error: ${t.message}")
            } finally {
                releaseNetplayWifiLock()
                if (finish) runOnUiThread { if (!isFinishing && !isDestroyed) exitToLibrary() }
            }
        }
    }

    /**
     * Push a "playEnded" call into the Dart isolate over the cached engine
     * of [MainActivity]. Terminates the local PlaySession for [cfg]'s room;
     * [clean] maps to finished vs cancelled. No-op when no engine is cached.
     */
    private fun notifyDartPlayEnded(cfg: NetplaySessionCfg, clean: Boolean) {
        runCatching {
            val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_MAIN)
                ?: return@runCatching
            MethodChannel(engine.dartExecutor.binaryMessenger, "gs/netplay")
                .invokeMethod(
                    "playEnded",
                    mapOf("roomId" to cfg.roomId, "clean" to clean),
                )
        }.onFailure { Log.w("GS-Netplay", "playEnded callback failed: ${it.message}") }
    }

    override fun onPause() {
        super.onPause()
        // A finger still on a pad button when we background never receives its
        // UP event, which would leave the NES key stuck down on resume.
        if (::pad.isInitialized) pad.releaseAll()
        if (npCfg != null) {
            // Backgrounding is a negotiated pause; no quick-save snapshot in
            // lockstep (state convergence lives on the host).
            if (!npEnded && handle != 0L && !npPaused) {
                npPaused = true
                npPausedSinceMs = android.os.SystemClock.elapsedRealtime()
                NativeBridge.nativeNetplayNotifyPaused(handle, true)
                NativeBridge.nativeSetAudioPaused(handle, true)
                setNpOverlay("你已切到后台，伙伴在等你\n回到本页自动继续")
            }
            glView.onPause()
            return
        }
        // Snapshot the live core before the GL thread stops: if Android kills
        // the process while backgrounded, the next launch auto-restores here.
        if (handle != 0L && !benchMode && !restarting && ::saveKey.isInitialized) {
            renderer.autoSaveStateBlocking()
        }
        glView.onPause()
        if (handle != 0L) NativeBridge.nativeSetPaused(handle, true)
    }

    override fun onResume() {
        super.onResume()
        glView.onResume()
        // 从系统设置页返回时重新拉取手柄布局配置(缩放/平移)。
        applyPersistedSettings()
        if (npCfg != null) {
            if (npPaused && !npEnded && handle != 0L) resumeNetplay()
            return
        }
        if (handle != 0L) NativeBridge.nativeSetPaused(handle, false)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (npCfg != null) {
            // The normal back path already ran endNetplay() (async on
            // npExecutor); this branch covers abnormal destruction so no UDP
            // socket / bootstrap server / WifiLock survives. nativeNetplayStop
            // only flips the session to a dead state (the runner is disposed
            // by the GL event below), so it is safe off the GL thread.
            if (!npEnded) {
                if (handle != 0L) runCatching { NativeBridge.nativeNetplayStop(handle) }
                runCatching { npServer?.close() }
                releaseNetplayWifiLock()
                npCfg?.let { notifyDartPlayEnded(it, false) }
                npEnded = true
            }
            // Close sockets before interrupting so blocked accept/read unwind.
            npExecutor.shutdownNow()
        }
        // glView is `lateinit`: if onCreate bailed out early (no extras,
        // missing rom, LockedRom throw), it's never been initialised and
        // touching it from onDestroy crashes with UninitializedPropertyAccess.
        if (::glView.isInitialized) {
            glView.queueEvent {
                if (handle != 0L) {
                    NativeBridge.nativeDispose(handle)
                    handle = 0L
                }
            }
        } else if (handle != 0L) {
            // Same-loop fallback: the runner wasn't bound to a GL thread, so
            // dispose synchronously to release the lockfile handle.
            NativeBridge.nativeDispose(handle)
            handle = 0L
        }
        // Drop the decrypted ROM cache as soon as the activity tears down.
        LockedRom.release(plainRom)
        plainRom = null
        runningSaveKey = null
    }

    /**
     * Best-effort sniff for raw MGS1 bytes — checks that the first four
     * bytes equal `MGS1`. We use this so a misnamed file (no `.zip`
     * extension but still an MGS1 blob) is still treated as encrypted.
     */
    private fun isLikelyMgs1(f: java.io.File): Boolean = try {
        if (f.length() < 24) false else f.inputStream().use { ins ->
            val head = ByteArray(4)
            ins.read(head) == 4 && head[0] == 'M'.code.toByte() &&
                    head[1] == 'G'.code.toByte() && head[2] == 'S'.code.toByte() &&
                    head[3] == '1'.code.toByte()
        }
    } catch (_: Throwable) { false }

    /**
     * Detects a single-entry STORE-method ZIP container (`PK\x03\x04`). The
     * cloud sync (see app/lib/data/cloud/cloud_sync.dart) downloads the
     * encrypted ROM as `<title>.<platform ext>.zip` and writes it under
     * `roms/cloud/<title>.<platform ext>` — i.e. **without** the `.zip`
     * extension — so a misnamed file (no `.zip` but still wrapped in PK)
     * must still be peeled through [LockedRom.materialize].
     */
    private fun isLikelyZip(f: java.io.File): Boolean = try {
        if (f.length() < 4) false else f.inputStream().use { ins ->
            val head = ByteArray(4)
            ins.read(head) == 4 && head[0] == 0x50.toByte() &&
                    head[1] == 0x4B.toByte() && head[2] == 0x03.toByte() &&
                    head[3] == 0x04.toByte()
        }
    } catch (_: Throwable) { false }

    // ------------------------------------------------------------------ renderer

    private inner class EmuRenderer : GLSurfaceView.Renderer {
        lateinit var romPath: String
        lateinit var saveDir: String
        lateinit var systemDir: String
        lateinit var logPath: String
        lateinit var saveKey: String
        /** libretro core id ("fceumm"/"gambatte"/"mgba"/"picodrive"/"stella2014"). */
        var coreId: String = "fceumm"
        /** Core-reported display aspect ratio; 0 = unspecified (square px). */
        var coreAspect: Float = 0f
        var benchSeconds: Int = 0
        /**
         * True when the renderer is sampling the libretro frame rotated
         * 90° on screen (vertical cabinet + landscape display). When set,
         * `nativeSetButtons` is called with a remapped D-pad mask so the
         * on-screen direction matches what the game expects.
         */
        @Volatile var inputRotated90: Boolean = false
        var onBenchDone: (() -> Unit)? = null
        var onFatal: ((String) -> Unit)? = null
        /** Invoked (GL thread) after safe insets change; used to place the HUD. */
        var onStageChanged: (() -> Unit)? = null
        /** Non-null only for a lockstep session; drives the whole net branch. */
        var netCfg: NetplaySessionCfg? = null

        /**
         * Turn the just-written runner log into a user-facing Chinese reason
         * for a failed core boot.
         *
         * Diagnostics are ASCII lines in files/logs. FB Alpha 2012 (community)
         * and MAME (store) phrase failures differently, so both vocabularies
         * are matched:
         *  - "Failed to find archive: neogeo" / missing sm1.sm1 · sfix.sfx …
         *    → the NeoGeo system BIOS is absent or an incomplete old subset;
         *  - "qsound.zip NOT FOUND" / "dl-1425.bin" … → the Q-Sound BIOS
         *    (qsound.zip / qsound_hle.zip) is absent or a stale truncated copy;
         *  - "pgm.zip NOT FOUND" … → the IGS PGM base BIOS (pgm.zip) is missing;
         *  - "Cannot find driver" / "Cannot load this game" / "is required" /
         *    "not found" / "missing" / "could not load" / "required files" …
         *    → the ROM dump CRCs don't match the core's database, OR a clone
         *    is missing its parent set (e.g. 1943j needs 1943.zip next to it).
         * BIOS diagnostics take priority because a NeoGeo set logs both the
         * missing BIOS members and "Cannot load this game" at once.
         *
         * The concrete offending line(s) are appended so a failure is never a
         * silent generic message — the user (and a remote logcat capture) can
         * see exactly which file MAME/FBA says is required.
         */
        private fun classifyCoreFailure(): String {
            val text = try {
                val f = File(logPath)
                if (f.exists()) f.readText() else ""
            } catch (_: Throwable) {
                ""
            }
            val tail = text.takeLast(2500).lowercase()
            val isArcade = coreId == "fbalpha2012" ||
                coreId == "fbneo" || coreId == "mame"
            // Only concrete BIOS member names count. "Archive: neogeo" is
            // logged on every NeoGeo boot even when the BIOS loads fine, so
            // matching it would mislabel a ROM-CRC mismatch as a BIOS fault.
            val missingBios = tail.contains("sm1.") || tail.contains("sfix.") ||
                tail.contains("sp-s2") || tail.contains("000-lo") ||
                tail.contains("asia-s3")
            // Q-Sound BIOS (CPS-1/2): MAME logs "qsound.zip NOT FOUND" /
            // "dl-1425.bin ... not found" when qsound.zip / qsound_hle.zip is
            // absent, or a stale truncated copy was staged instead of the real
            // one. Mirror the OHOS EmulatorSpike diagnosis for these BIOSes.
            val missingQsound = tail.contains("qsound") || tail.contains("dl-1425")
            // IGS PolyGame Master: MAME logs "pgm.zip NOT FOUND" (or a pgm
            // member) when the PGM base BIOS is missing.
            val missingPgm = tail.contains("pgm")
            // Broadened beyond FBA-2012 to cover the store MAME core, whose
            // clone/parent-missing errors ("1943.zip is required",
            // "rom 1943j not found", "required files are missing") previously
            // fell through to the generic "核心初始化失败" and hid the cause.
            val romMismatch = tail.contains("cannot find driver") ||
                tail.contains("cannot load this game") ||
                tail.contains("is required") ||
                tail.contains("not found") ||
                tail.contains("missing") ||
                tail.contains("could not load") ||
                tail.contains("required files") ||
                tail.contains("no such file") ||
                tail.contains("error reading")
            // Concrete offending line(s) for the dialog, so the cause is
            // visible even when the paraphrase is imperfect.
            val detail = text.lineSequence()
                .map { it.trim() }
                .filter { ln ->
                    val l = ln.lowercase()
                    l.contains("required") || l.contains("not found") ||
                    l.contains("missing") || l.contains("cannot find driver") ||
                    l.contains("cannot load this game") ||
                    l.contains("could not load") || l.contains("no such file") ||
                    l.contains("error reading")
                }
                .toList().takeLast(3)
                .joinToString("\n")
                .take(400)
            return when {
                isArcade && missingQsound ->
                    "缺少或不完整的 Q-Sound 系统 BIOS（qsound.zip / qsound_hle.zip），\n" +
                    (if (detail.isNotBlank()) "核心日志：$detail\n" else "") +
                    "游戏因此无法启动，请从合法备份导入完整的 Q-Sound BIOS 后重试。"
                isArcade && missingPgm ->
                    "缺少 IGS PGM 基板 BIOS（pgm.zip），\n" +
                    (if (detail.isNotBlank()) "核心日志：$detail\n" else "") +
                    "PGM 街机游戏（knights、oriental、kov 等）需要 pgm.zip 才能启动，" +
                    "请从合法备份导入后重试。"
                isArcade && missingBios ->
                    "缺少或不完整的 NeoGeo 系统 BIOS（neogeo.zip），\n" +
                    "游戏因此无法启动，请更新应用内置的系统文件后重试。"
                isArcade && romMismatch ->
                    "该街机游戏的 ROM 与模拟器核心不兼容，或缺少父级 ROM 集。\n" +
                    (if (detail.isNotBlank()) "核心日志：$detail\n" else "") +
                    "若是克隆版（如 1943j 之于 1943），请把父级 ROM 集（1943.zip）" +
                    "一并放入同一游戏目录后重试。"
                else -> if (detail.isNotBlank())
                    "模拟器核心初始化失败：\n$detail\n\n（详情见应用日志文件）"
                else
                    "模拟器核心初始化失败，详情见应用日志文件。"
            }
        }

        // Paddings (px) reserved for the virtual pad / menu bar; the game
        // frame is fit (8:7 PAR) into the remaining rectangle. Zero in bench.
        var safeLeftPx = 0f
        var safeTopPx = 0f
        var safeRightPx = 0f
        var safeBottomPx = 0f

        // System-bar / cutout insets pushed from the UI thread. Needed since
        // Android 15 (API 35) edge-to-edge — and Android VM containers such
        // as Zhuoyitong on HarmonyOS NEXT — lay our surface out UNDER the
        // status/navigation bars: without these the emulated frame's top is
        // painted beneath the floating bar and looks cropped. On the legacy
        // decor-fits-system-windows path (Honor phones) the view starts below
        // the bars, so these arrive as 0 and the layout is unchanged.
        @Volatile private var sysInsetLeft = 0f
        @Volatile private var sysInsetTop = 0f
        @Volatile private var sysInsetRight = 0f
        @Volatile private var sysInsetBottom = 0f

        fun setSystemInsets(left: Int, top: Int, right: Int, bottom: Int) {
            val l = left.toFloat(); val t = top.toFloat()
            val r = right.toFloat(); val b = bottom.toFloat()
            if (l == sysInsetLeft && t == sysInsetTop &&
                r == sysInsetRight && b == sysInsetBottom) return
            sysInsetLeft = l; sysInsetTop = t
            sysInsetRight = r; sysInsetBottom = b
            refreshInsets()
        }

        @Volatile var buttonMask: Int = 0
        /** Driven libretro pad port (arcade 1P/2P selector): 0 = 1P, 1 = 2P. */
        @Volatile var playerPort: Int = 0
        /** Last port pushed to native; -1 forces a push on the first frame. */
        private var sentPlayerPort: Int = -1

        private var pixels: ByteBuffer? = null
        private var texId = 0
        private var texW = 0
        private var texH = 0
        private var frameW = 256
        private var frameH = 240
        private var framePitch = 256 * 4

        // fullscreen quad
        private var program = 0
        private var posHandle = 0
        private var uvHandle = 0
        private var texHandle = 0
        // x, y, u, v per vertex; positions are recomputed for the safe rect
        private val quadVerts = FloatArray(16)
        private val quadBuf: ByteBuffer by lazy {
            ByteBuffer.allocateDirect(quadVerts.size * 4).order(ByteOrder.nativeOrder())
        }
        private val quadFb: java.nio.FloatBuffer by lazy { quadBuf.asFloatBuffer() }
        private val uvBuf: java.nio.Buffer by lazy { quadBuf.duplicate().apply { position(8) } }

        /**
         * Remap a D-pad bitmask for a game whose libretro frame is sampled
         * 90° CW on screen. With the screen rotate 90° CW the original
         * UP direction (where the player plane lives for arcade shooters)
         * ends up on the right side of the landscape view, so what the
         * user presses as on-screen UP has to reach the game as the
         * LEFT button, and similarly for the other three directions.
         *
         * Non-D-pad bits (B / SELECT / START / A / L / R / X / Y) are
         * passed through unchanged — those controls aren't directional.
         */
        private fun remapDpadForCwRotation(mask: Int): Int {
            val passthrough = mask and (VirtualPadView.BUTTON_B or
                    VirtualPadView.BUTTON_SELECT or
                    VirtualPadView.BUTTON_START or
                    VirtualPadView.BUTTON_A or
                    VirtualPadView.BUTTON_L or
                    VirtualPadView.BUTTON_R or
                    VirtualPadView.BUTTON_X or
                    VirtualPadView.BUTTON_Y)
            var dpad = 0
            if ((mask and VirtualPadView.BUTTON_UP) != 0)    dpad = dpad or VirtualPadView.BUTTON_LEFT
            if ((mask and VirtualPadView.BUTTON_DOWN) != 0)  dpad = dpad or VirtualPadView.BUTTON_RIGHT
            if ((mask and VirtualPadView.BUTTON_LEFT) != 0)  dpad = dpad or VirtualPadView.BUTTON_DOWN
            if ((mask and VirtualPadView.BUTTON_RIGHT) != 0) dpad = dpad or VirtualPadView.BUTTON_UP
            return passthrough or dpad
        }

        private var surfW = 1
        private var surfH = 1

        // Frame production is owned by the native pacing thread; the GL thread
        // only pumps the latest frame and uploads it at display vsync.

        // hud fps
        private var hudLastNs = 0L
        private var hudFrames = 0
        private var npStatLastNs = 0L

        // bench bookkeeping
        private var benchFinished = false

        /** Recompute the stage + fitted quad after a safe-area inset change. */
        fun refreshInsets() {
            glView.queueEvent {
                if (surfW > 1 && surfH > 1) applySafeInsets(surfW, surfH)
                updateGameQuad()
                onStageChanged?.invoke()
            }
        }

        /**
         * Fit the emulated frame into the common reserved stage (see
         * applySafeInsets). NES NTSC pixels use the legacy 8:7 PAR; the other
         * cores report a display aspect via libretro and letterbox inside the
         * same stage; bench mode stretches to fill the screen.
         *
         * Vertical arcade games (1941, kof97, etc.) are reported by FBA-2012
         * with `base_w < base_h` and `aspect_ratio < 1.0`, but **without**
         * an internal framebuffer rotation — i.e. the texture is 224x384 and
         * the core draws the cabinet's vertical orientation directly. On a
         * landscape phone that leaves the picture letterboxed into a tall
         * thin column with bars on both sides, which is the opposite of what
         * the user wants. We detect that case (aspect < 1, and not the
         * intentional NES portrait-orientation swap) and render the texture
         * rotated 90° so it fills the landscape stage.
         */
        private fun updateGameQuad() {
            val availW = (surfW - safeLeftPx - safeRightPx).coerceAtLeast(1f)
            val availH = (surfH - safeTopPx - safeBottomPx).coerceAtLeast(1f)
            // Rotate the texture only when the core reports a portrait frame
            // and isn't a horizontally-known platform. fceumm always reports
            // 256x240; GB/GBA/GBC and PSX cores never report aspect < 1 for
            // their stock landscape titles, so the heuristic is safe.
            val rotatePortrait = !benchMode &&
                    coreId != "fceumm" &&
                    coreAspect > 0f && coreAspect < 1f &&
                    frameW.toFloat() / frameH < 1f
            // Tell the input layer to remap D-pad bits so on-screen UP/DOWN/
            // LEFT/RIGHT match what the rotated game expects.
            inputRotated90 = rotatePortrait
            val targetDar = when {
                benchMode -> availW / availH
                // FBA-2012 reports aspect_ratio=0.75 for cabinet-vertical
                // games like 1941, but the picture inside the 224×384 buffer
                // is actually a 90°-rotated landscape scene (the player
                // plane flies horizontally, the world scrolls vertically).
                // The visual DAR after rotating the texture is therefore
                // frameH/frameW (e.g. 384/224=1.714), not 1/coreAspect.
                rotatePortrait -> frameH.toFloat() / frameW
                coreId == "fceumm" -> frameW.toFloat() / frameH * (8f / 7f)
                coreAspect > 0f -> coreAspect
                else -> frameW.toFloat() / frameH
            }
            var gw = availW
            var gh = availH
            if (gw / gh > targetDar) gw = gh * targetDar else gh = gw / targetDar
            val gx = safeLeftPx + (availW - gw) / 2f
            val gy = safeTopPx + (availH - gh) / 2f

            val x0 = gx / surfW * 2f - 1f
            val x1 = (gx + gw) / surfW * 2f - 1f
            val y0 = 1f - (gy + gh) / surfH * 2f
            val y1 = 1f - gy / surfH * 2f
            if (rotatePortrait) {
                // 90° CW rotation of the texture (top of the cabinet
                // becomes the right side of the screen — the MAME default
                // for "Rotate Screen Right" — matches what most arcade
                // cabinets expect: title marquee on the right, gameplay
                // horizon running left-to-right). Mapping original UVs
                // onto the screen quad [BL, BR, TL, TR]:
                //   screen BL ← original BL = (0, 1)
                //   screen BR ← original TL = (0, 0)
                //   screen TL ← original BR = (1, 1)
                //   screen TR ← original TR = (1, 0)
                quadFb.put(floatArrayOf(
                    x0, y0, 0f, 1f,
                    x1, y0, 0f, 0f,
                    x0, y1, 1f, 1f,
                    x1, y1, 1f, 0f
                )).position(0)
            } else {
                // Standard pass-through; positions match, UVs stay full-frame.
                // BL, BR, TL, TR
                quadFb.put(floatArrayOf(
                    x0, y0, 0f, 1f,
                    x1, y0, 1f, 1f,
                    x0, y1, 0f, 0f,
                    x1, y1, 1f, 0f
                )).position(0)
            }
        }

        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            try {
                // The GL thread is also the audio producer; give it display-urgent
                // scheduling so occasional background work cannot skip a vsync and
                // starve the (prefilled) audio ring.
                android.os.Process.setThreadPriority(
                    android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY)
                // The native runner outlives EGL contexts: backgrounding the app
                // recreates this surface, but the core keeps its memory state.
                // Boot the core only on the first surface.
                val freshCore = handle == 0L
                val cfg0 = netCfg
                if (freshCore && cfg0 != null && !cfg0.isHost) {
                    // Guest: do NOT block this callback on the bootstrap gate.
                    // Buffers swapped inside onSurfaceCreated are never
                    // presented, and the system keeps the theme's white
                    // starting window up until the normal frame loop queues a
                    // buffer — a blocking wait therefore shows a white blank
                    // for the whole SRAM sync. onDrawFrame performs the gated
                    // boot and keeps swapping black frames until the gate
                    // opens.
                    npBootDeadlineNs = System.nanoTime() + 40_000_000_000L
                    npBootDeferred = true
                    NpLog.log("GL guest boot deferred to frame loop")
                    return
                }
                if (freshCore && !bootCore()) return
                createSurfaceGlObjects()
            } catch (t: Throwable) {
                Log.e(TAG, "surface create failed", t)
                onFatal?.invoke("Fatal: ${t.message}")
            }
        }

        /**
         * Create the native runner, run the geometry probe frame and (for
         * solo play) hand over to the pacing thread. Runs on the GL thread:
         * from onSurfaceCreated for host/solo cold starts, or from
         * onDrawFrame for a netplay guest once its bootstrap gate opens.
         * @return false when a fatal dialog was posted; caller must stop.
         */
        private fun bootCore(): Boolean {
            val t0 = System.currentTimeMillis()
            handle = NativeBridge.nativeInit(
                coreId, romPath, saveDir, systemDir, logPath, saveKey,
                netplayColdBoot = npCfg != null)
            if (handle == 0L) {
                NpLog.log("GL nativeInit returned 0")
                // Machine-readable failure record: the UI only shows the
                // reason in a dialog, but automated batches (and support cases)
                // need it in logcat too.
                val reason = classifyCoreFailure()
                Log.e(
                    TAG,
                    "GS-CORE-FAIL core=$coreId rom=${File(romPath).name} " +
                        "reason=${reason.replace('\n', ' ')}"
                )
                onFatal?.invoke(reason); return false
            }
            NpLog.log("GL nativeInit ok in ${System.currentTimeMillis() - t0}ms")
            // A freshly created runner is at 1x; keep UI state in sync.
            speedIndex = 0
            runOnUiThread { speedButton?.text = "加速 ×1" }
            pixels = ByteBuffer.allocateDirect(1024 * 1024 * 4)
                .order(ByteOrder.nativeOrder())
            NativeBridge.nativeAttachPixels(handle, pixels!!)

            if (benchSeconds > 0) {
                NativeBridge.nativeBenchStart(handle, 10, benchSeconds)
            }

            // Seed any persisted / PC-synced commands before the first
            // frame (the core applies RAM writes every frame and ROM
            // read patches immediately). Empty set is a no-op reset.
            NativeBridge.nativeSetCheats(handle, activeCheatCodes())

            // one synchronous frame to learn geometry/pitch, then hand
            // frame production to the dedicated native pacing thread
            val info = NativeBridge.nativeRunFrame(handle)
            if (info == null) {
                onFatal?.invoke("模拟器核心运行首帧失败，详情见应用日志。"); return false
            }
            framePitch = info[2]; frameW = info[0]; frameH = info[1]
            coreAspect = NativeBridge.nativeAspect(handle)
            if (netCfg != null) {
                // The np-ctl thread attaches the UDP session, loads
                // state0 (guest) and then calls nativeStartPacing.
                NpLog.log("GL first frame ok, countDown npCoreReady")
                npCoreReady.countDown()
            } else {
                NativeBridge.nativeStartPacing(handle)
                // Continue exactly where the last session stopped.
                if (!benchMode) autoRestoreState()
            }
            return true
        }

        /**
         * Per-surface GL objects (texture/program). Rebuilt on every
         * surface creation; the pixel buffer and core geometry live with
         * the activity and survive EGL context loss.
         */
        private fun createSurfaceGlObjects() {
            // GL objects belong to the (possibly new) context: rebuild them
            // on every surface creation; pixels/geometry persist with us.
            val tex = IntArray(1)
            GLES20.glGenTextures(1, tex, 0)
            texId = tex[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, frameW, frameH, 0,
                GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
            )
            texW = frameW; texH = frameH
            program = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)
            posHandle = GLES20.glGetAttribLocation(program, "aPos")
            uvHandle = GLES20.glGetAttribLocation(program, "aUV")
            texHandle = GLES20.glGetUniformLocation(program, "uTex")
            hudLastNs = System.nanoTime()
        }

        /**
         * Reserve a play "stage" sized to *this* profile, not NES:
         *   - landscape: side bars wide enough for the D-pad / face buttons,
         *     but the stage aspect follows the core's own DAR (see
         *     [VirtualPadView.Profile.coreDar]) so a wide game like GBA
         *     (1.5) no longer gets letterboxed 40dp top/bottom just because
         *     the surface used to be sized for NES 8:7.
         *   - portrait: top/bottom bars sized for the same reason.
         * Every core then fits its reported aspect inside the stage, so the
         * picture fills full height on every landscape platform.
         *
         * The 130dp / 16–22% min-side floor matches the actual D-pad /
         * face-button extent (the 184dp corner menu bar lives *over* the
         * picture in its 45×42 dp corner envelope, which is hidden
         * underneath the opaque menu bar — visually a no-op).
         */
        fun applySafeInsets(w: Int, h: Int) {
            if (benchMode) {
                safeLeftPx = 0f; safeTopPx = 0f
                safeRightPx = 0f; safeBottomPx = 0f
                return
            }
            val targetDar = VirtualPadView.Profile.coreDar(pad.profile)
            if (w >= h) {
                val naturalSide = ((w - h * targetDar) / 2f).coerceAtLeast(0f)
                // Side insets are fractions of the screen width, reproducing
                // the prior 198dp (left) / 160dp (right, except MD 220dp)
                // fixed-DP constants on the 800dp-wide reference. With
                // these fractions `naturalSide` wins on a few tall-NES
                // surfaces and `needSide` wins everywhere else — same as
                // before, no extra 0.30f floor that used to over-shrink
                // the picture.
                val needSide = maxOf(
                    w * VirtualPadView.Profile.LEFT_INSET_FRAC,
                    w * VirtualPadView.Profile.rightInsetFrac(pad.profile))
                val side = maxOf(naturalSide, needSide)
                // System bars/cutout are added on top: edge-to-edge layouts
                // (Android 15, Zhuoyitong container) float the status bar
                // over the surface, so keep both the stage sides and its
                // top/bottom clear of them.
                safeLeftPx = maxOf(side, sysInsetLeft)
                safeRightPx = maxOf(side, sysInsetRight)
                safeTopPx = sysInsetTop
                safeBottomPx = sysInsetBottom
            } else {
                val naturalTb = ((h - w / targetDar) / 2f).coerceAtLeast(0f)
                val tb = maxOf(
                    naturalTb,
                    h * VirtualPadView.Profile.topInsetFrac(pad.profile),
                    h * VirtualPadView.Profile.BOTTOM_INSET_FRAC)
                safeLeftPx = sysInsetLeft; safeRightPx = sysInsetRight
                safeTopPx = maxOf(tb, sysInsetTop)
                safeBottomPx = maxOf(tb, sysInsetBottom)
            }
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            surfW = width
            surfH = height
            GLES20.glViewport(0, 0, width, height)
            applySafeInsets(width, height)
            // If the core has already reported geometry (warm start), recompute
            // the quad immediately.  For cold starts the quad will be updated
            // once the first frame arrives and frameW/frameH are known.
            if (frameW != 256 || frameH != 240 || coreAspect != 0f) {
                updateGameQuad()
            }
            onStageChanged?.invoke()
        }

        override fun onDrawFrame(gl: GL10?) {
            if (npBootDeferred) {
                // Parked guest: drive the gate from the frame loop so real
                // buffers get presented every wait tick (that is also what
                // lets the system dismiss the white starting window), then
                // boot the core here.
                val gateOpen = npGateInit.await(200, TimeUnit.MILLISECONDS)
                when {
                    npBootAborted.get() -> {
                        NpLog.log("GL gate released by bootstrap abort — skip init")
                        npBootDeferred = false
                        GLES20.glClearColor(0f, 0f, 0f, 1f)
                        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                        return
                    }
                    !gateOpen && System.nanoTime() >= npBootDeadlineNs -> {
                        npBootDeferred = false
                        NpLog.log("GL npGateInit TIMEOUT 40s")
                        onFatal?.invoke("联机存档同步超时，请返回后重试")
                        return
                    }
                    !gateOpen -> {
                        GLES20.glClearColor(0f, 0f, 0f, 1f)
                        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                        return
                    }
                    else -> {
                        npBootDeferred = false
                        NpLog.log("GL npGateInit passed, nativeInit (frame loop)")
                        if (!bootCore()) return
                        createSurfaceGlObjects()
                        // onSurfaceChanged ran before the core existed, so its
                        // quad build was skipped; build it for the real size.
                        updateGameQuad()
                        return
                    }
                }
            }
            if (handle == 0L) {
                // Pre-init: keep the surface black instead of flashing EGL's
                // default white behind any failure / transition state.
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                return
            }
            val now = System.nanoTime()

            // scripted input in benchmark mode; touch pad otherwise
            if (benchMode) injectBenchInput(now)
            // Rotate the D-pad bits when the renderer is sampling the
            // libretro framebuffer rotated 90° on screen — otherwise the
            // on-screen "up" presses DOWN in the rotated game, etc.
            val sentMask = if (inputRotated90) remapDpadForCwRotation(buttonMask) else buttonMask
            if (netCfg != null) {
                // Lockstep: mask feeds this role's fixed retropad slot; the
                // runner swaps lm/rm by role and never touches playerPort.
                NativeBridge.nativeNetplayLocalMask(handle, sentMask)
            } else {
                NativeBridge.nativeSetButtons(handle, sentMask)
                // Arcade 1P/2P selector — only cross the JNI boundary when the
                // chosen port actually changes.
                if (playerPort != sentPlayerPort) {
                    NativeBridge.nativeSetPlayerPort(handle, playerPort)
                    sentPlayerPort = playerPort
                }
            }

            // Emulation runs on the native pacing thread at 50 fps while the
            // panel vsyncs at 60/120 Hz, so some vsyncs have no new frame. We
            // must still render and swap EVERY vsync: leaving the back buffer
            // untouched and swapping cycles through the surface's multiple
            // swapchain buffers whose stale contents (older frames) periodically
            // flash on screen as a "ghost" image during scrolling.
            val info = NativeBridge.nativePumpFrame(handle)
            var newFrame = false
            if (info != null) {
                val nw = info[0]; val nh = info[1]
                if (nw != frameW || nh != frameH) { frameW = nw; frameH = nh; updateGameQuad() }
                framePitch = info[2]
                newFrame = true
                hudFrames++
            }
            drawFrame(newFrame)

            // HUD
            if (!benchMode && now - hudLastNs >= 500_000_000L) {
                val fps = hudFrames / ((now - hudLastNs) / 1e9)
                val xruns = NativeBridge.nativeAudioXruns(handle)
                val ff = if (speedIndex > 0) "  ×%d".format(speedSteps[speedIndex]) else ""
                // Two stacked lines so the block stays narrow enough to live
                // in the side bar next to the game frame (see layoutHud).
                runOnUiThread {
                    hud.text = "FPS %.1f%s\nxruns %d".format(fps, ff, xruns)
                    layoutHud()
                }
                hudFrames = 0; hudLastNs = now
            }

            // Netplay session HUD (4 Hz): RTT / D / frame count + freeze and
            // drop watchdogs. Stats calls are cheap mutex-guarded snapshots.
            if (netCfg != null && npRunning && now - npStatLastNs >= 250_000_000L) {
                npStatLastNs = now
                val st = NetplayStats.fromVector(NativeBridge.nativeNetplayStats(handle))
                if (st != null) onNetplayStats(st)
            }

            // bench completion
            if (benchMode && !benchFinished) {
                val phase = NativeBridge.nativeBenchPhase(handle)
                if (phase == 3) {
                    benchFinished = true
                    finishBench()
                }
            }
        }

        private fun drawFrame(uploadTexture: Boolean) {
            val buf = pixels ?: return
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            buf.position(0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
            // Re-upload only when a freshly published emu frame arrived; the
            // texture keeps its contents on the GL context across vsyncs.
            if (uploadTexture) {
                // tightly packed RGBA rows are produced by the runner regardless of core pitch
                GLES20.glTexSubImage2D(
                    GLES20.GL_TEXTURE_2D, 0, 0, 0, texW, texH,
                    GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf
                )
            }
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glUniform1i(texHandle, 0)
            GLES20.glEnableVertexAttribArray(posHandle)
            GLES20.glEnableVertexAttribArray(uvHandle)
            GLES20.glVertexAttribPointer(posHandle, 2, GLES20.GL_FLOAT, false, 16, quadBuf)
            GLES20.glVertexAttribPointer(uvHandle, 2, GLES20.GL_FLOAT, false, 16, uvBuf)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glDisableVertexAttribArray(posHandle)
            GLES20.glDisableVertexAttribArray(uvHandle)
        }

        private var benchStartNs = 0L
        private fun injectBenchInput(nowNs: Long) {
            if (benchStartNs == 0L) benchStartNs = nowNs
            val t = ((nowNs - benchStartNs) / 1e6).toInt() // ms since surface
            // deterministic 2000ms script loop
            var mask = 0
            when ((t % 2000)) {
                in 0..400 -> mask = VirtualPadView.BUTTON_RIGHT
                in 500..900 -> mask = VirtualPadView.BUTTON_LEFT
                in 1000..1200 -> mask = VirtualPadView.BUTTON_DOWN
                in 1300..1450 -> mask = VirtualPadView.BUTTON_A
                in 1550..1700 -> mask = VirtualPadView.BUTTON_B
                in 1800..1900 -> mask = VirtualPadView.BUTTON_START
            }
            buttonMask = mask
            NativeBridge.nativeSetButtons(handle, mask)
        }

        private fun finishBench() {
            try {
                val rom = File(romPath)
                val crc = CRC32()
                crc.update(rom.readBytes())
                val benchDir = File(filesDir, "bench").apply { mkdirs() }
                val benchId = intent.getStringExtra("bench_id") ?: "NES-yx"
                val out = File(benchDir, "$benchId.json").absolutePath
                val sha = BuildConfig.GS_CORE_PINS.split(';')
                    .firstOrNull { it.startsWith("$coreId ") }
                    ?.substringAfter(' ')?.trim().orEmpty()
                val coreRef = if (sha.isNotEmpty()) "$coreId@$sha" else coreId
                val ok = NativeBridge.nativeBenchFinish(
                    handle, out, benchId,
                    coreRef, "debug/${android.os.Build.VERSION.SDK_INT}",
                    "%08x".format(crc.value), rom.length(),
                    "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                    android.os.Build.VERSION.RELEASE ?: ""
                )
                Log.i(TAG, "bench written: $ok -> $out")
            } catch (t: Throwable) {
                Log.e(TAG, "finishBench failed", t)
            } finally {
                onBenchDone?.invoke()
            }
        }

        /**
         * Snapshot the current emulated frame into a small JPEG thumbnail.
         * The runner publishes tightly-packed RGBA (frameW*frameH*4) at the
         * start of [pixels]; call on the GL thread.
         */
        private fun grabThumbnail(): Bitmap? {
            val buf = pixels ?: return null
            val w = frameW; val h = frameH
            if (w <= 0 || h <= 0) return null
            return try {
                val raw = ByteArray(w * h * 4)
                buf.position(0)
                buf.get(raw, 0, raw.size)
                val px = IntArray(w * h)
                for (i in 0 until w * h) {
                    val r = raw[i * 4].toInt() and 0xFF
                    val g = raw[i * 4 + 1].toInt() and 0xFF
                    val b = raw[i * 4 + 2].toInt() and 0xFF
                    val a = raw[i * 4 + 3].toInt() and 0xFF
                    px[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
                }
                val full = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                full.setPixels(px, 0, w, 0, 0, w, h)
                Bitmap.createScaledBitmap(full, (w / 2).coerceAtLeast(1),
                    (h / 2).coerceAtLeast(1), true)
            } catch (_: Throwable) { null }
        }

        /**
         * Manual save: write into the next rotating slot (first free slot,
         * else overwrite the oldest) together with a JPEG thumbnail.
         */
        fun saveToSlot() {
            glView.queueEvent {
                val data = NativeBridge.nativeSaveState(handle)
                var slotIndex = -1
                var slotTime = 0L
                var replaced = false
                if (data != null) {
                    try {
                        val i = nextSlotIndex()
                        val f = slotStateFile(i)
                        replaced = f.exists()
                        f.parentFile?.mkdirs()
                        f.writeBytes(data)
                        grabThumbnail()?.let { bmp ->
                            val t = slotThumbFile(i)
                            t.outputStream().use {
                                bmp.compress(Bitmap.CompressFormat.JPEG, 85, it)
                            }
                        }
                        slotIndex = i
                        slotTime = f.lastModified()
                    } catch (_: Throwable) { }
                }
                runOnUiThread {
                    val msg = when {
                        slotIndex < 0 -> "存档失败"
                        replaced -> "已存入槽位 ${slotIndex + 1}（覆盖最旧存档）"
                        else -> "已存档到槽位 ${slotIndex + 1}"
                    }
                    if (slotIndex >= 0) {
                        // Mirror the most-recent slot to SharedPreferences so
                        // "remember last game" can auto-load it on the next
                        // entry into this activity. File name must match
                        // what the Flutter `shared_preferences` plugin
                        // reads/writes — `FlutterSharedPreferences.xml`.
                        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                            .edit()
                            .putInt("flutter.lastSaveSlot", slotIndex)
                            .apply()
                        Toast.makeText(this@EmulatorActivity,
                            "$msg · ${fmtSlotTime(slotTime)}", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@EmulatorActivity, msg, Toast.LENGTH_SHORT).show()
                    }
                }
            }
        }

        /** Load a slot chosen in the picker (runs on the GL thread). */
        fun loadSlot(f: File) {
            glView.queueEvent {
                val exists = f.exists()
                var ok = false
                if (exists) {
                    try {
                        ok = NativeBridge.nativeLoadState(handle, f.readBytes())
                    } catch (_: Throwable) { ok = false }
                }
                runOnUiThread {
                    Toast.makeText(this@EmulatorActivity,
                        when {
                            !exists -> "存档不存在"
                            ok -> "读档成功"
                            else -> "读档失败"
                        },
                        Toast.LENGTH_SHORT).show()
                }
            }
        }

        /**
         * Restore the per-game quick-save once right after boot so 「继续游戏」
         * lands on the exact last frame. Runs on the GL thread during init.
         */
        fun autoRestoreState() {
            val f = stateFile()
            if (!f.exists()) return
            val ok = try {
                NativeBridge.nativeLoadState(handle, f.readBytes())
            } catch (_: Throwable) { false }
            if (ok) {
                runOnUiThread {
                    Toast.makeText(this@EmulatorActivity,
                        "已恢复上次进度（菜单「重开」可从头开始）",
                        Toast.LENGTH_SHORT).show()
                }
            }
        }

        /**
         * Synchronously snapshot the core from onPause, before the GL thread
         * is torn down. Bounded wait: serialization is a small memcpy under
         * the core mutex, so this is normally a few ms.
         */
        fun autoSaveStateBlocking() {
            val done = java.util.concurrent.CountDownLatch(1)
            glView.queueEvent {
                try {
                    val data = NativeBridge.nativeSaveState(handle)
                    if (data != null) {
                        val f = stateFile()
                        f.parentFile?.mkdirs()
                        f.writeBytes(data)
                    }
                } catch (_: Throwable) { }
                done.countDown()
            }
            try { done.await(800, java.util.concurrent.TimeUnit.MILLISECONDS) }
            catch (_: InterruptedException) { }
        }
    }

    private fun buildProgram(vs: String, fs: String): Int {
        fun shader(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val st = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, st, 0)
            if (st[0] == 0) throw RuntimeException("shader: " + GLES20.glGetShaderInfoLog(s))
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, shader(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, shader(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        val st = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, st, 0)
        if (st[0] == 0) throw RuntimeException("link: " + GLES20.glGetProgramInfoLog(p))
        return p
    }

    companion object {
        private const val TAG = "GS-Emu"
        private const val SLOT_COUNT = 3

        /// CRC saveKey of the currently running game (8-hex, or the ROM
        /// base name for sideloads). The 「发现伙伴」 import engine refuses to
        /// overwrite saves for this CRC while the core is live, since it
        /// writes them back on exit. Null when no emulator is running.
        @Volatile
        var runningSaveKey: String? = null
            internal set
        private const val VERTEX_SHADER =
            "attribute vec4 aPos; attribute vec2 aUV; varying vec2 vUV; " +
            "void main(){ vUV=aUV; gl_Position=aPos; }"
        private const val FRAGMENT_SHADER =
            "precision mediump float; varying vec2 vUV; uniform sampler2D uTex; " +
            "void main(){ gl_FragColor=texture2D(uTex,vUV); }"
    }
}
