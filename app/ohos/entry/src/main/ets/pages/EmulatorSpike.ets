import { startEmulator, stopEmulator, setEmulatorTarget, setInput, setPlayerPort, resetEmu, setSpeed, setAudioMuted, getLoadError, saveState, loadState, getFps, getFilesDir, saveStateSlot, loadStateSlot, listSaves, getCheats, setCheats, isCoreReady, netplayFreeze } from 'libgpretro.so'
import { NetplaySession, NetplayCfg, NetplayStatus } from '../netplay_session'
import { GamePouchPlugin } from '../plugins/GamePouchPlugin'
import router from '@ohos.router';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// RETRO_DEVICE_ID_JOYPAD_* bit positions (see libretro.h).
const BTN_B = 0
const BTN_Y = 1
const BTN_SELECT = 2
const BTN_START = 3
const BTN_UP = 4
const BTN_DOWN = 5
const BTN_LEFT = 6
const BTN_RIGHT = 7
const BTN_A = 8
const BTN_X = 9
const BTN_L = 10
const BTN_R = 11
const DIR_MASK = (1 << BTN_UP) | (1 << BTN_DOWN) | (1 << BTN_LEFT) | (1 << BTN_RIGHT)

// Android VirtualPadView / buildMenuBar colours.
const C_FILL = 'rgba(255,255,255,0.22)'          // white alpha 56
const C_FILL_ACTIVE = 'rgba(255,193,7,0.80)'     // amber alpha 205
const C_STROKE = 'rgba(255,255,255,0.59)'        // white alpha 150
const C_STROKE_ACTIVE = 'rgba(255,235,170,0.96)' // alpha 245
const C_EXIT = '#EF9A9A'
const C_TEXT = '#FFFFFF'
const C_TEXT_ACTIVE = '#2D2000'

interface EmuParams { rom?: string; core?: string; platform?: string; netplay?: object; filesDir?: string }
interface PadCircleSpec { bit: number; label: string; cx: number; cy: number; r: number }
interface PadPillSpec { bit: number; label: string; cx: number; cy: number; w: number; h: number }
interface MovePreset { label: string; script: string }
/// Shape of libgpretro `getLoadError()` (empty string == booted fine).
interface LoadErrorInfo { reason?: string; missing?: string[]; detail?: string }

/// Files a MAME 0.289 `neogeo.zip` must provide (any one missing means the
/// imported BIOS bundle is incomplete / from another ROM-set revision).
const _neogeoBiosFiles: string[] = [
  'sp-s2.sp1', 'sp-s.sp1', 'sp-u2.sp1', 'sp-1v1_3db8c.bin',
  'sm1.sm1', 'sfix.sfix', '000-lo.lo', 'v2.bin'
];
interface MoveCellSpec { label: string; script: string; cx: number; cy: number; w: number; h: number }
// moves.json (written by the Flutter SpecialMovesEditor / SpecialMovesFile):
// { version, activeProfileId, profiles: { id: { label, gameHints, moves: [{label, script}] } } }.
interface MoveEntry { label?: string; script?: string }
interface MoveProfile { label?: string; moves?: MoveEntry[] }
interface MovesJson { activeProfileId?: string; profiles?: Record<string, MoveProfile> }
interface SaveSlotInfo { slot: number; exists: boolean; time: number; w: number; h: number; thumb?: image.PixelMap }

// Stick modes — see VirtualPadView.StickMode. DPAD4 snaps to 4 directions
// (cross d-pad), DPAD8/STICK give 8-way per-axis (analog knob visual).
type StickMode = 'STICK' | 'DPAD8' | 'DPAD4'
interface Settings {
  stickMode: string
  padScale: number
  stickDeadzone?: number
  useDpadUi?: boolean
  padOffsetX?: number
  padOffsetY?: number
  // App-level toggles mirrored from the Flutter SettingsSheet (AppSettings).
  showFpsHud?: boolean
  highRefreshRate?: boolean
  fastForwardAudio?: boolean
}

// cheats.json (PC tool sync_cheats.py): { version, byCrc: { <8-hex CRC>: CheatInfo[] } }.
interface CheatInfo {
  name: string
  code: string
  enabled: boolean
  options?: CheatOption[]
  selected?: number
}
interface CheatOption { label?: string; code?: string }
// Rendered row: a toggle (Switch) plus, for choice cheats, a Select of options.
interface CheatRow {
  name: string
  enabled: boolean
  hasChoice: boolean
  choiceLabels: string[]
  choiceCodes: string[]
  choiceSel: number
  // Effective code when enabled (already resolved for choice cheats).
  code: string
}

/// Faithful port of the Android emulator UI: a full-screen native game surface
/// with a transparent virtual-pad overlay (cross d-pad bottom-left + per-
/// platform face buttons / shoulders / SELECT-START on the right) and the
/// corner toolbar (功能 top-left, ✕ top-right, pop-out command panel). Geometry
/// mirrors VirtualPadView.layoutDpad()/drawDpad()/hitDpad() and
/// EmulatorActivity.buildMenuBar (fractions of the window's short side "ref").
@Entry
@Component
struct EmulatorSpike {
  private xcomponentId: string = 'emu_xc'
  // Content area of the window (system bars excluded — the Android activity is
  // NOT immersive either, its status bar stays visible in landscape).
  @State winW: number = 0
  @State winH: number = 0
  // Content origin inside the window (status bar / cutout insets).
  @State layX: number = 0
  @State layY: number = 0
  // True once winW/winH are the real landscape window size (overlay gate).
  @State laidOut: boolean = false
  @State core: string = 'fceumm'
  // Dart `PlatformKind.name`. Authoritative for the control panel (like Android):
  // several platforms share the 'mame' core id, so the core id alone collapses
  // Neogeo titles to the wrong pad.
  @State platform: string = ''
  // Authoritative files dir handed over by GamePouchPlugin (router params).
  // `getFilesDir()` from the NAPI host is a DIFFERENT directory on real devices,
  // so settings.json / library/moves.json must be read from this one.
  private cfgDir: string = ''
  // Content-box origin (px) — pad offset excluded; anchors non-pad overlays.
  private winX0: number = 0
  private winY0: number = 0
  @State rom: string = ''
  @State profile: string = 'NES'
  @State joypadMask: number = 0
  @State activeBits: number = 0
  @State panelOpen: boolean = false
  @State speedMult: number = 1
  @State toast: string = ''
  @State fpsText: string = ''
  @State netplayHud: string = ''
  @State padCircles: PadCircleSpec[] = []
  @State padPills: PadPillSpec[] = []
  // Stick: 3-mode selector (STICK / DPAD8 / DPAD4) persisted in settings.json.
  @State stickMode: StickMode = 'DPAD8'
  @State padScale: number = 1.0
  // Pad config mirrored from the Flutter SettingsSheet (AppSettings) at launch,
  // via GamePouchPlugin.writePadSettings -> settings.json. Defaults equal the
  // legacy hardcoded values so behaviour is unchanged until the user edits them.
  @State stickDeadzone: number = 0.18
  @State useDpadUi: boolean = false
  @State padOffsetX: number = 0.0
  @State padOffsetY: number = 0.0
  // App-level toggles mirrored from the Flutter SettingsSheet (AppSettings).
  @State showFpsHud: boolean = true
  @State highRefreshRate: boolean = true
  @State fastForwardAudio: boolean = true
  // Human-readable reason the current ROM failed to boot ('' == healthy).
  @State loadErrorMsg: string = ''
  private loadErrorRaw: string = ''
  // D-pad: which pointer owns it + the direction bit currently held.
  private dpadPointer: number = -1
  private dpadDir: number = 0
  // Analog-stick knob offset (px from the disc centre) + grab flag.
  @State knobX: number = 0
  @State knobY: number = 0
  @State stickPointer: number = -1
  // Save slots: which slot the next 存档 writes to + the load-dialog list.
  private saveSlot: number = 0
  // Netplay: lobby session config (forwarded from GamePouchPlugin) + the live
  // session object. Started after the core finishes loading (§16.4).
  private netplayParams?: Record<string, Object>
  private netplay?: NetplaySession
  // Set once a clean/auto teardown has been initiated (manual ✕ or peer-exit),
  // so the per-poll status callback does not fire exitToLibrary() repeatedly.
  private ending: boolean = false
  @State loadDialog: boolean = false
  @State saveList: SaveSlotInfo[] = []
  // Cheats: openCheatsDialog loads cheats.json by ROM CRC; rows mirror the
  // Switch/Choice dialog on Android (CheatInfo.enabled + options/selected).
  @State cheatsOpen: boolean = false
  @State cheatRows: CheatRow[] = []
  private fpsTimer: number = -1
  // JS-side macro replay (the OHOS host has no nativePlayMacro yet): the
  // timer id + the bit-mask currently held by an in-flight 招式 sequence.
  private macroTimer: number = -1
  private macroBits: number = 0
  // ---- arcade profile (MAME six-button / NEOGEO four-button) ----
  @State menuExpanded: boolean = false
  @State movesExpanded: boolean = false
  @State playerPort: number = 0
  // arcade overlay geometry (computed in layoutPad)
  @State arcMenuCx: number = 0
  @State arcMenuY: number = 0
  @State arcPillW: number = 0
  @State arcPillH: number = 0
  @State arcMenuGap: number = 0
  @State movesCx: number = 0
  @State movesPillTop: number = 0
  // Expanded 招式 grid cells — populated in layoutPad (1:1 with Android
  // buildFightAssist: 2 columns, sized to the right letterbox band and capped
  // above the A/B/C/D cluster). Driven by movesPresets so a different game's
  // preset set (e.g. kof98) just works.
  @State movesCells: MoveCellSpec[] = []
  // 招式预设：默认内置 6 个，启动时若 <filesDir>/library/moves.json 存在且包含
  // 当前激活 profile 的有效招式，则被 loadMoves() 覆盖（与 Android SpecialMovesStore
  // 一致，让设置页编辑器改过的招式在原生模拟器生效）。
  private movesPresets: MovePreset[] = [
    { label: '波', script: '236+P' },
    { label: '升', script: '623+P' },
    { label: '旋', script: '214+K' },
    { label: '超', script: '236236+PK' },
    { label: '避', script: '66' },
    { label: '滚', script: '44' },
  ]
  private win?: window.Window
  // Raw window metrics + system-bar insets (px) + the page's own measured box,
  // used to decide whether the ArkUI page already sits below the system bars
  // (non-immersive) or spans the whole window (immersive, Android-style manual
  // inset). Both cases must end up with the same on-screen geometry.
  private winPxW: number = 0
  private winPxH: number = 0
  private insetL: number = 0
  private insetT: number = 0
  private insetR: number = 0
  private insetB: number = 0
  private pageWpx: number = 0
  private pageHpx: number = 0
  // px/vp ratio: ArkUI TouchEvent.{x,y} are in vp (local to the component), but
  // the pad geometry below is computed in px. Multiply touches by this before
  // hit-testing, otherwise every tap maps to the wrong direction.
  private densityScale: number = 1

  // ---- geometry (px), fractions of ref = min(w,h) like the Android view ----
  private ref(): number { return Math.min(this.winW, this.winH) }
  private baseR(): number { return this.ref() * 0.19 }
  private toolPillW(): number { return this.ref() * 0.1988 }
  private toolPillH(): number { return this.ref() * 0.077 }
  private toolRadius(): number { return this.ref() * 0.05 }
  // VirtualPadView paints: strokeWidth = ref*0.0056, active = ref*0.0072.
  private strokeW(active: boolean): number { return this.ref() * (active ? 0.0072 : 0.0056) }
  // VirtualPadView.pressInset: a pressed key is redrawn 0.0069·ref smaller.
  private pressInset(): number { return this.ref() * 0.0069 }

  // Virtual d-pad geometry — port of VirtualPadView.layoutDpad():
  //   r = baseR*0.78, buttonR = baseR*0.46, armW = baseR*0.40
  // Matches the shipped Android build on the reference phone (the on-device
  // cross reads ~0.84·baseR between arm centres, current source says 0.78).
  private dpadR(): number { return this.baseR() * 0.84 }
  private dpadArmR(): number { return this.baseR() * 0.46 }
  private dpadArmW(): number { return this.baseR() * 0.40 }
  private dpadCx(): number { return this.layX + this.winW * 0.13 }
  private dpadCy(): number { return this.layY + this.winH * 0.66 }
  private dpadOuterR(): number { return this.dpadR() + this.dpadArmR() }
  private dpadHoldR(): number { return (this.dpadR() + this.dpadArmR()) * 0.18 }

  // Analog-stick geometry (port of VirtualPadView.layoutStick()): the knob rides
  // a baseR disc and is grabbed within 1.35·baseR of the centre. knobR = 0.44·baseR.
  private stickBaseR(): number { return this.baseR() * this.padScale }
  private knobR(): number { return this.baseR() * 0.44 * this.padScale }
  private stickTravel(): number { return Math.max(1, this.stickBaseR() - this.knobR()) }

  aboutToAppear(): void {
    this.setOrientation(window.Orientation.LANDSCAPE)
    const p = router.getParams() as EmuParams
    this.rom = (p && p.rom) ? p.rom : ''
    this.core = (p && p.core) ? p.core : 'fceumm'
    this.platform = (p && p.platform) ? p.platform : ''
    this.cfgDir = (p && p.filesDir) ? p.filesDir : ''
    this.netplayParams = (p && p.netplay) ? p.netplay as Record<string, Object> : undefined
    this.profile = this.computeProfile()
    console.info(`[EmulatorSpike] target rom=${this.rom} core=${this.core} platform=${this.platform} profile=${this.profile}`)
    if (this.netplayParams) {
      // Park the emulation from the very first rendered frame: Android runs
      // loadState + netplayStart + startPacing inside ONE GL-thread block, so
      // no retro_run() can happen between them. Here the bootstrap runs on the
      // ArkTS thread, so without this gate the core emulates (leaked) frames
      // while /sram + /state0 + netplayStart are in flight — those frames are
      // never undone for a cold-boot core (MAME) and desync the pair at frame 0.
      // netplay_session unfreezes once the session is attached (and on
      // teardown, so a failed bootstrap falls back to solo play).
      try { netplayFreeze(true) } catch (e) { console.error('[EmulatorSpike] netplayFreeze failed') }
    }
    if (this.rom) {
      // Third arg mirrors Android's nativeInit(netplayColdBoot = npCfg != null):
      // a netplay session cold-boots both peers independently, so the core must
      // ignore this device's NVRAM file or the two machines desync immediately.
      setEmulatorTarget(this.rom, this.core, this.netplayParams !== undefined)
    }
    this.loadSettings()
    // Apply the app-level toggles consumed natively (refresh rate + audio).
    this.applyDisplayRate()
    this.applyFastForwardAudio()
    // FPS HUD (EmulatorActivity hud TextView): yellow readout, 2 Hz.
    this.fpsTimer = setInterval(() => {
      const f = getFps()
      let s = 'FPS ' + f.toFixed(1)
      if (this.speedMult > 1) s += '  ×' + this.speedMult
      this.fpsText = s
      // Same tick: pick up a late core-load failure (MAME decides after ~1 s of
      // ROM verification, well after the surface is up).
      this.pollLoadError()
    }, 500)
  }

  aboutToDisappear(): void {
    console.warn('[EmulatorSpike] aboutToDisappear — netplay? ' + (this.netplay ? 'yes' : 'no'))
    // netplay.stop() FIRST (NativeNetplayStop sets running_=false then joins the
    // pace thread) — calling stopEmulator() before it deadlocks the UI thread on
    // a peer drop. stopEmulator() is only a fallback if netplay is already gone.
    if (this.netplay) {
      this.netplay.stop()
      this.netplay = undefined
      GamePouchPlugin.setNetplayRef(undefined)
    }
    stopEmulator()
    if (this.fpsTimer >= 0) {
      clearInterval(this.fpsTimer)
      this.fpsTimer = -1
    }
    this.cancelMacro()
    if (this.win) {
      this.win.off('windowSizeChange')
      this.win = undefined
    }
    this.setOrientation(window.Orientation.PORTRAIT)
  }

  // Intercepts both the on-screen ✕ button AND the system back gesture/
  // hardware back key. Returns `true` to consume the event so the router
  // does NOT pop this component before we've sent the netplay teardown.
  // Without this guard, a system-back swipe calls router.pop() BEFORE
  // aboutToDisappear even runs, leaving Dart PlaySession stuck in the
  // "对局已结束即将返回…" terminal overlay forever.
  onBackPress(): boolean {
    console.warn('[EmulatorSpike] onBackPress → exitToLibrary')
    this.exitToLibrary()
    return true
  }

  /// Mirror Android EmulatorActivity.exitToLibrary() for OHOS: the ArkUI
  /// router pushes EmulatorSpike ON TOP of the Flutter navigator, so
  /// router.back() pops the ArkUI component but Flutter's PlayLobbyPage
  /// (pushed before EmulatorSpike) is still active underneath.
  ///
  /// The netplay teardown MUST fire BEFORE router.back() because
  /// aboutToDisappear (ArkUI lifecycle) fires AFTER the pop — by then
  /// PlayLobbyPage may have already rendered its "对局已结束即将返回…"
  /// terminal overlay (it waits 1.8 s for the Dart PlaySession to end,
  /// but if emitPlayEnded hasn't reached Dart yet, the session never
  /// terminates and the overlay stays forever).
  ///
  /// Sequence (critical — DO NOT reorder):
  ///   1. netplay.stop()  → teardown() → emitNetplayPlayEnded().
  ///      This is synchronous (NAPI). NativeNetplayStop FIRST sets the netplay
  ///      `running_` flag false (so the emulator pace thread's beginFrame()
  ///      returns Dead immediately instead of blocking on the dropped peer),
  ///      THEN joins the pace thread, and only THEN frees g_net. This ordering
  ///      is what makes the teardown safe: the pace thread is dead before the
  ///      object is freed (no use-after-free SIGSEGV) and it is never joined
  ///      while still blocked waiting for the dead peer (no UI-thread deadlock).
  ///   2. stopEmulator()  — idempotent fallback. NativeNetplayStop already
  ///      stopped the emulator; this is a no-op unless netplay was absent.
  ///   3. router.back()    (pop ArkUI component, expose Flutter navigator)
  ///
  /// NOTE: calling stopEmulator() BEFORE netplay.stop() deadlocks the UI thread
  /// — stopEmulator() joins the pace thread while netplay is still "running" and
  /// that thread is blocked in beginFrame() waiting for the gone peer, so the
  /// join never returns until netplay.stop() runs (which it can't, because the
  /// UI thread is stuck in the join). Observed as a permanent freeze on peer exit.
  exitToLibrary(): void {
    if (this.ending) {
      // Already tearing down (manual ✕ and a peer-exit poll can race); only the
      // first call must actually dismiss the page.
      return
    }
    this.ending = true
    // 1) Tear netplay down FIRST — NativeNetplayStop stops the pace thread
    //    safely (see sequence note above). Do NOT call stopEmulator() before this.
    if (this.netplay) {
      this.netplay.stop()
      this.netplay = undefined
      GamePouchPlugin.setNetplayRef(undefined)
    }
    // 2) Fallback stop (no-op once netplay path already stopped the emulator).
    stopEmulator()
    try { router.back() } catch (e) { /* page may already be gone */ }
  }

  private async setOrientation(orient: window.Orientation): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const win = await window.getLastWindow(ctx)
      this.win = win
      // Not immersive: the landscape status bar stays visible, exactly like the
      // Android emulator activity (whose window also sits inside the bars).
      try {
        await win.setWindowLayoutFullScreen(false)
      } catch (e) {
        console.warn('[EmulatorSpike] layoutFullScreen(false) failed: ' + JSON.stringify(e))
      }
      // Keep the landscape status bar on screen, like the Android activity.
      try {
        await win.setWindowSystemBarEnable(['status'])
      } catch (e) {
        console.warn('[EmulatorSpike] show status bar failed: ' + JSON.stringify(e))
      }
      // Black bar with white icons: the page background is pure black, so a
      // light status bar made the clock/battery unreadable.
      try {
        await win.setWindowSystemBarProperties({
          statusBarColor: '#000000',
          statusBarContentColor: '#FFFFFF'
        })
      } catch (e) {
        console.warn('[EmulatorSpike] status bar properties failed: ' + JSON.stringify(e))
      }
      // Android draws the picture all the way to the bottom edge, so the thin
      // gesture hint is hidden as well.
      try {
        await win.setSpecificSystemBarEnabled('navigationIndicator', false)
      } catch (e) {
        console.warn('[EmulatorSpike] hide nav indicator failed: ' + JSON.stringify(e))
      }
      // windowRect still holds the pre-rotation size right after
      // setPreferredOrientation(), so the layout must follow the size events
      // instead of a single one-shot read (which left the pad laid out for
      // the portrait 1260x2844 window).
      win.on('windowSizeChange', (size: window.Size) => {
        this.measureWindow()
        console.info('[EmulatorSpike] size ' + size.width + 'x' + size.height)
      })
      await win.setPreferredOrientation(orient)
      this.measureWindow()
      setTimeout(() => { this.measureWindow() }, 400)
      // Never leave the player without controls if no landscape size arrives.
      setTimeout(() => {
        if (this.winW <= 0 || this.winH <= 0) {
          this.applyWindowSize(
            this.winPxW - this.insetL - this.insetR,
            this.winPxH - this.insetT - this.insetB,
            this.insetL, this.insetT)
        } else {
          this.layoutPad()
        }
        this.laidOut = true
      }, 1500)
    } catch (e) {
      console.error('[EmulatorSpike] setOrientation failed: ' + JSON.stringify(e))
    }
  }

  private async measureWindow(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      const win = await window.getLastWindow(ctx)
      const wp = win.getWindowProperties()
      const w = wp.windowRect.width
      const h = wp.windowRect.height
      // Content box = window minus the system bars / cutout, so the pad and the
      // chrome sit inside the same area the Android activity lays out in.
      let l = 0
      let t = 0
      let r = 0
      let b = 0
      try {
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
        t = sys.topRect.height
        l = sys.leftRect.width
        r = sys.rightRect.width
        b = sys.bottomRect.height
      } catch (e) {
        console.warn('[EmulatorSpike] avoidArea failed: ' + JSON.stringify(e))
      }
      this.winPxW = w
      this.winPxH = h
      this.insetL = l
      this.insetT = t
      this.insetR = r
      this.insetB = b
      this.densityScale = this.density()
      this.resolveLayout()
      console.info('[EmulatorSpike] measure win=' + w + 'x' + h +
        ' inset l=' + l + ' t=' + t + ' r=' + r + ' b=' + b +
        ' page=' + this.pageWpx + 'x' + this.pageHpx +
        ' content=' + this.winW + 'x' + this.winH + '@' + this.layX + ',' + this.layY)
    } catch (e) {
      console.error('[EmulatorSpike] measureWindow failed: ' + JSON.stringify(e))
    }
  }

  /** vp -> px for the values [onAreaChange] reports. */
  private density(): number {
    try {
      const d = display.getDefaultDisplaySync().densityPixels
      return d > 0 ? d : 1
    } catch (e) {
      return 1
    }
  }

  private onPageArea(wVp: number, hVp: number): void {
    const d = this.density()
    this.pageWpx = wVp * d
    this.pageHpx = hVp * d
    this.densityScale = d
    this.resolveLayout()
  }

  /**
   * Resolve the box the pad is laid out in. If the page already spans the
   * whole window the layout must inset itself (Android-style); if ArkUI has
   * already pushed the page below the bars, the origin is 0,0.
   */
  private resolveLayout(): void {
    if (this.winPxW <= 0 || this.winPxH <= 0) return
    let cw = 0
    let ch = 0
    let x0 = 0
    let y0 = 0
    if (this.pageWpx > 0 && this.pageHpx > 0 &&
        (this.pageWpx < this.winPxW - 2 || this.pageHpx < this.winPxH - 2)) {
      // Page is already inside the safe area.
      cw = this.pageWpx
      ch = this.pageHpx
    } else {
      x0 = this.insetL
      y0 = this.insetT
      cw = this.winPxW - this.insetL - this.insetR
      ch = this.winPxH - this.insetT - this.insetB
    }
    this.applyWindowSize(cw, ch, x0, y0)
  }

  private applyWindowSize(w: number, h: number, x0: number, y0: number): void {
    if (w <= 0 || h <= 0) return
    // Pad translate from the Flutter SettingsSheet (padOffsetX/Y are fractions of
    // the content-box width/height, matching Android's applyPersistedSettings).
    // Because layoutPad() adds layX/layY to every circle/pill/d-pad anchor, this
    // shifts the WHOLE pad (d-pad, face buttons, arcade & 招式 overlays) by one
    // offset — zero regression when both offsets are 0.
    // Content-box origin, WITHOUT the pad offset. Overlays that are not part of
    // the pad (FPS readout, netplay status, error card) anchor here, otherwise a
    // user-chosen pad offset drags them off-screen too.
    this.winX0 = x0
    this.winY0 = y0
    this.layX = x0 + this.padOffsetX * w
    this.layY = y0 + this.padOffsetY * h
    if (this.winW === w && this.winH === h) return
    this.winW = w
    this.winH = h
    // Only build the overlay for a landscape window; the first event carries
    // the pre-rotation portrait size.
    if (w >= h) {
      this.layoutPad()
      this.laidOut = true
      this.applyGestureExclusion()
    }
  }

  // Task 5 (doable part): stop the system edge back-swipe from swallowing
  // virtual-pad touches near the screen edges (Android's claimSystemGesture()).
  // OpenHarmony 26 has no per-region gesture-exclusion API, so we disable the
  // window's back gesture entirely; the in-app 退出 button handles exit.
  private applyGestureExclusion(): void {
    if (this.winPxW <= 0 || this.winPxH <= 0) return
    try {
      const ctx = getContext(this) as common.UIAbilityContext
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.setGestureBackEnabled(false).catch((e: Error) => {
          console.warn('[EmulatorSpike] setGestureBackEnabled failed: ' + JSON.stringify(e))
        })
      }).catch((e: Error) => {
        console.warn('[EmulatorSpike] getLastWindow (gesture) failed: ' + JSON.stringify(e))
      })
    } catch (e) {
      console.warn('[EmulatorSpike] gesture exclusion failed: ' + JSON.stringify(e))
    }
  }

  /**
   * 1:1 port of VirtualPadView.Profile.from(coreId, platform, romName).
   *
   * The panel is driven by the *platform* id (`PlatformKind.name` from Dart),
   * not by the core id: that is what selects the pad on Android, and driving it
   * from the core id collapses every arcade title (kof97 included — its core id
   * is 'mame' even though it is a Neogeo platform) to the wrong 6-button panel.
   * The core id is only a fallback for legacy/unknown platform strings.
   */
  private computeProfile(): string {
    const name = (this.rom.split('/').pop() ?? '').toLowerCase()
    switch (this.platform.toLowerCase()) {
      case 'nes': return 'NES'
      case 'gameboy': return 'GB'
      case 'gba': return 'GBA'
      case 'atari2600': return 'A2600'
      case 'mastersystem': return name.endsWith('.gg') ? 'GG' : 'SMS'
      case 'genesis': return 'MD'
      case 'neogeo': return 'NEOGEO'
      case 'mame': return 'MAME'
    }
    switch (this.core) {
      case 'fceumm': return 'NES'
      case 'gambatte': return 'GB'
      case 'mgba': return 'GBA'
      case 'stella2014': return 'A2600'
      case 'picodrive':
        if (name.endsWith('.sms')) return 'SMS'
        if (name.endsWith('.gg')) return 'GG'
        return 'MD'
      case 'fbalpha2012': case 'fbalpha': case 'fbneo': case 'mame':
        return this.platform.toLowerCase() === 'neogeo' ? 'NEOGEO' : 'MAME'
      default:
        console.warn(`[EmulatorSpike] unmapped control profile: core=${this.core} platform=${this.platform} rom=${name} - defaulting to NES`)
        return 'NES'
    }
  }

  // ---- input ----
  private press(bit: number): void {
    this.activeBits |= (1 << bit)
    this.joypadMask |= (1 << bit)
    setInput(this.joypadMask)
      this.netplay?.setLocalMask(this.joypadMask)
  }

  private release(bit: number): void {
    this.activeBits &= ~(1 << bit)
    this.joypadMask &= ~(1 << bit)
    setInput(this.joypadMask)
      this.netplay?.setLocalMask(this.joypadMask)
  }

  private isActive(bit: number): boolean {
    return ((this.activeBits >> bit) & 1) === 1
  }

  // ---- netplay (§16.4) ---------------------------------------------------
  // Core finished loading (onLoad). If a lobby session was forwarded, attach it.
  private onCoreReady(): void {
    if (!this.netplayParams) return
    // Android gates the entire bootstrap on npCoreReady.await(35s) BEFORE it
    // attaches netplay (host and guest alike), so every lockstep frame starts
    // from the pristine post-load_game state. startEmulator() here returns
    // immediately — LoadCore runs on the render thread — so wait for the core
    // to actually be live first. Without this gate, netplayStart()'s
    // determinism retro_reset() (guarded by g_coreReady) silently no-ops and
    // the guest enters lockstep from a state the Android host can never match.
    // 180 s, not Android's 35 s: the OHOS MAME boot is dramatically slower —
    // StageArcadeContent() first re-stages the whole arcade library into the
    // MAME rompath and MAME then indexes every zip in it (~50 s on a device
    // whose roms/ holds a large resource pack). Android's core is live in ~1 s.
    // A too-short gate aborts the bootstrap before the core ever comes up.
    this.waitForCoreThenAttach(Date.now() + 180000)
  }

  private waitForCoreThenAttach(deadline: number): void {
    let ready = false
    try { ready = isCoreReady() as boolean } catch (e) { ready = false }
    if (ready) {
      // Re-arm the gate now that the core is live: the host's frame-0 state
      // (served as /state0) is captured here, mirroring Android's
      // `runOnGlBlocking { state0 = nativeSaveState }` before netplayStart.
      // At aboutToAppear the core was not loaded yet, so the first call could
      // not capture anything.
      try { netplayFreeze(true) } catch (e) { /* ignore */ }
      this.attachNetplay()
      return
    }
    if (Date.now() > deadline) {
      console.error('[EmulatorSpike] netplay aborted: core not ready within 35s')
      return
    }
    setTimeout((): void => { this.waitForCoreThenAttach(deadline) }, 100)
  }

  private attachNetplay(): void {
    const f = this.netplayParams
    if (!f) return
    const num = (k: string, d: number): number => (typeof f[k] === 'number') ? (f[k] as number) : d
    const str = (k: string, d: string): string => (typeof f[k] === 'string') ? (f[k] as string) : d
    const filesDir: string = getFilesDir() as string
    const gpFilesDir: string = (typeof f['filesDir'] === 'string') ? (f['filesDir'] as string) : ''
    console.info(`[EmulatorSpike] onCoreReady getFilesDir(NAPI)=${filesDir} GamePouchPlugin.filesDir=${gpFilesDir} ` +
      `match=${filesDir === gpFilesDir}`)
    if (gpFilesDir.length > 0 && gpFilesDir !== filesDir) {
      console.warn(`[EmulatorSpike] filesDir MISMATCH! Using NAPI getFilesDir: ${filesDir}`)
    }
    const cfg: NetplayCfg = {
      role: num('role', 0),
      peerIp: str('peerIp', ''),
      peerPort: num('peerPort', 0),
      localPort: num('localPort', 0),
      sessionKey: str('sessionKey', ''),
      roomId: num('roomId', 0),
      initialD: num('initialD', 2),
      adaptive: (typeof f['adaptive'] === 'boolean') ? (f['adaptive'] as boolean) : true,
      bootstrapPort: num('bootstrapPort', 0),
      saveKey: str('saveKey', ''),
      framePeriodSec: (typeof f['framePeriodSec'] === 'number') ? (f['framePeriodSec'] as number) : 0,
      filesDir: filesDir,
      // Drives the cold-boot alignment decision (MAME must not transfer
      // frame 0) — mirrors Android EmulatorActivity's `renderer.coreId`.
      coreId: this.core
    }
    this.netplay = new NetplaySession(cfg, (s) => this.onNetplayStatus(s))
    GamePouchPlugin.setNetplayRef(this.netplay)
    console.info(`[EmulatorSpike] netplay cfg role=${cfg.role} peerIp=${cfg.peerIp} peerPort=${cfg.peerPort} ` +
      `localPort=${cfg.localPort} bootPort=${cfg.bootstrapPort} sessionKeyLen=${cfg.sessionKey.length} ` +
      `coreId=${cfg.coreId} coldBoot=${cfg.coreId === 'mame'}`)
    this.netplay.start().catch((e: Error) => {
      console.error('[EmulatorSpike] netplay start failed: ' + e.message)
    })
  }

  private onNetplayStatus(s: NetplayStatus): void {
    if (s.state === 4 || s.state === 5) {
      this.netplayHud = `NET ${s.text}`
    } else {
      this.netplayHud = `NET ${s.text} rtt=${s.rttMs.toFixed(0)}ms drop=${s.dropped}`
    }
    // Terminal (3=Dropped ≥10s no packet, 4=Ended/BYE): the peer — e.g. the
    // Android host/guest — exited/dropped, or the session ended for any reason.
    // The stats poll already tore the netplay session down (netplayStop +
    // emitPlayEnded), but the ArkUI emulator page is STILL on top of the Flutter
    // navigator and the native emulator is STILL rendering frames against the
    // now-freed netplay C++ lockstep buffers. Left alone it dereferences freed
    // state on the very next retro_run tick and force-closes the app (闪退).
    // Android's EmulatorActivity finishes itself on peer-disconnect; mirror that
    // here by programmatically returning to the library instead of waiting for a
    // ✕ tap that the user — mid-game, peer gone — may never press.
    if ((s.state === 3 || s.state === 4) && !this.ending) {
      console.warn('[EmulatorSpike] netplay terminal (peer gone) → auto exitToLibrary');
      // Do NOT set this.ending here: exitToLibrary() guards with
      // `if (this.ending) return` and sets it itself. Setting it first would make
      // exitToLibrary() a no-op, so netplay.stop()/stopEmulator()/router.back()
      // never run and the app freezes on the game screen (its ✕/back also dead).
      this.exitToLibrary()
    }
  }

  /**
   * Cross d-pad hit-test: the WHOLE disc is an 8-way pie (eight 45° wedges)
   * with NO central dead zone, so every touch inside the circle maps to one of
   * the eight directions (↑ ↗ → ↘ ↓ ↙ ← ↖) and the effective press area is the
   * full circle — far larger than the old 4-arm + dead-zone layout. A small
   * hysteresis ring only steadies the *release* (keeps the last direction while
   * lifting near the centre); it never blocks a fresh press, so the centre
   * stays live.
   */
  private applyDpad(x: number, y: number, isDown: boolean): void {
    const dx = x - this.dpadOuterR()
    const dy = y - this.dpadOuterR()
    const dist = Math.sqrt(dx * dx + dy * dy)
    if (dist > this.dpadOuterR()) {
      // Slid off the disc (or tapped outside it): no direction held.
      this.setDir(0)
      return
    }
    if (!isDown && this.dpadDir !== 0 && dist < this.dpadHoldR()) {
      // Release hysteresis: near the centre atan2 is noise, keep the old dir.
      return
    }
    // Angle → 8-way pie. Screen y grows downward, so +90° is "down".
    // idx 0..7: → ↘ ↓ ↙ ← ↖ ↑ ↗ (each wedge centred on its direction).
    const ang = Math.atan2(dy, dx) * 180 / Math.PI
    let idx = Math.round(ang / 45)
    idx = ((idx % 8) + 8) % 8
    const pie: number[] = [
      (1 << BTN_RIGHT),                         //  0: →
      (1 << BTN_DOWN) | (1 << BTN_RIGHT),       //  1: ↘
      (1 << BTN_DOWN),                          //  2: ↓
      (1 << BTN_DOWN) | (1 << BTN_LEFT),        //  3: ↙
      (1 << BTN_LEFT),                          //  4: ←
      (1 << BTN_UP) | (1 << BTN_LEFT),          //  5: ↖
      (1 << BTN_UP),                            //  6: ↑
      (1 << BTN_UP) | (1 << BTN_RIGHT),         //  7: ↗
    ]
    this.setDir(pie[idx])
  }

  private setDir(mask: number): void {
    if (this.dpadDir === mask) return
    this.dpadDir = mask
    this.joypadMask = (this.joypadMask & ~DIR_MASK) | mask
    this.activeBits = (this.activeBits & ~DIR_MASK) | mask
    setInput(this.joypadMask)
      this.netplay?.setLocalMask(this.joypadMask)
  }

  private releaseDpad(): void {
    this.dpadPointer = -1
    this.dpadDir = 0
    this.knobX = 0
    this.knobY = 0
    this.joypadMask &= ~DIR_MASK
    this.activeBits &= ~DIR_MASK
    setInput(this.joypadMask)
      this.netplay?.setLocalMask(this.joypadMask)
  }

  private stickActive(): boolean {
    return this.stickPointer >= 0
  }

  private releaseStick(): void {
    this.stickPointer = -1
    this.knobX = 0
    this.knobY = 0
    this.dpadDir = 0
    this.joypadMask &= ~DIR_MASK
    this.activeBits &= ~DIR_MASK
    setInput(this.joypadMask)
      this.netplay?.setLocalMask(this.joypadMask)
  }

  /**
   * STICK/DPAD8: per-axis 8-way (the NES joypad is digital, so this is the
   * 8-way digital mask, not a true analog axis). The knob offset is clamped to
   * the travel radius and drawn; a dead-zone of stickDeadzone()·travel keeps
   * the centre still. Touch coords are local to the stick Stack (centre =
   * stickBaseR), so we subtract that, not dpadCx.
   */
  private applyStick(x: number, y: number): void {
    let dx = x - this.stickBaseR()
    let dy = y - this.stickBaseR()
    const travel = this.stickTravel()
    const mag = Math.sqrt(dx * dx + dy * dy)
    if (mag > travel) {
      dx = dx / mag * travel
      dy = dy / mag * travel
    }
    this.knobX = dx
    this.knobY = dy
    const dz = travel * this.stickDeadzone
    let dir = 0
    if (dx < -dz) dir |= (1 << BTN_LEFT)
    else if (dx > dz) dir |= (1 << BTN_RIGHT)
    if (dy < -dz) dir |= (1 << BTN_UP)
    else if (dy > dz) dir |= (1 << BTN_DOWN)
    this.setDir(dir)
  }

  build() {
    Stack() {
      // Full-screen native game surface.
      XComponent({
        id: this.xcomponentId,
        type: XComponentType.SURFACE,
        libraryname: 'gpretro'
      })
        .onLoad((event?: object) => {
          console.info('[EmulatorSpike] onLoad')
          if (event) {
            startEmulator((event as XComponentLoadEvent).value)
            this.onCoreReady()
          }
        })
        .width('100%')
        .height('100%')
        // The surface must reach the bottom edge too, otherwise the GL
        // viewport stops 94 px short and the picture never fills the screen.
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      // The overlay is built ONCE the window has settled into its landscape
      // size: @Builder params are passed by value, so a builder laid out with
      // the pre-rotation 1260x2844 numbers would never be re-positioned.
      if (this.laidOut) {
        // Transparent virtual-pad overlay. DPAD4 (or the "use virtual d-pad"
        // setting) -> cross d-pad; STICK/DPAD8 -> analog knob (8-way). The
        // Android default depends on the profile/setting.
        if (this.useDpadUi || this.stickMode === 'DPAD4') {
          this.dpad()
        } else {
          this.analogStick()
        }
        this.faceAndPills()
        // Corner toolbar.
        this.cornerToolbar()
        // Arcade profile overlays (MAME six-button / NEOGEO four-button).
        if (this.profile === 'MAME' || this.profile === 'NEOGEO') {
          this.arcadeMenu()
        }
        if (this.profile === 'NEOGEO') {
          this.movesPanel()
        }
        // FPS HUD — top-centre of the picture, yellow on 35% black.
        if (this.showFpsHud && this.fpsText.length > 0) {
          Text(this.fpsText)
            .fontSize((this.ref() * 0.022) + 'px')
            .fontColor(Color.Yellow)
            .backgroundColor('rgba(0,0,0,0.35)')
            .padding({
              left: (this.ref() * 0.0093) + 'px',
              right: (this.ref() * 0.0093) + 'px',
              top: (this.ref() * 0.0056) + 'px',
              bottom: (this.ref() * 0.0056) + 'px'
            })
            .position({ x: (this.winX0 + this.winW / 2) + 'px', y: (this.winY0 + this.winH * 0.045) + 'px' })
            .translate({ x: '-50%' })
        }
        // Netplay session HUD — below the FPS readout.
        if (this.netplayHud.length > 0) {
          Text(this.netplayHud)
            .fontSize((this.ref() * 0.020) + 'px')
            .fontColor('#00FFFF')
            .backgroundColor('rgba(0,0,0,0.35)')
            .padding({
              left: (this.ref() * 0.0093) + 'px',
              right: (this.ref() * 0.0093) + 'px',
              top: (this.ref() * 0.0056) + 'px',
              bottom: (this.ref() * 0.0056) + 'px'
            })
            .position({ x: (this.winX0 + this.winW / 2) + 'px', y: (this.winY0 + this.winH * 0.085) + 'px' })
            .translate({ x: '-50%' })
        }
        // Boot-failure explanation. Without this an arcade ROM whose set does
        // not match MAME 0.289 only ever shows the blue fallback surface, so
        // "the game won't start" looked like a crash with no clue.
        // Single intrinsic-width Text (same pattern as the FPS HUD): a sized
        // Column + `translate('-50%')` mis-resolved against the parent here and
        // pushed the card off the left edge, so keep the sizing implicit and
        // cap it with constraintSize.
        if (this.loadErrorMsg.length > 0) {
          // A sized Column with an explicit (whole-number) px width: this SDK
          // silently drops fractional px lengths such as "2275.2px", which made
          // the Text measure unbounded — no wrapping, and a -50% translate that
          // pushed the whole card off the left edge.
          Column() {
            Text(this.loadErrorMsg)
              .width('100%')
              .fontSize(Math.round(this.ref() * 0.019) + 'px')
              .fontColor('#FFE0B2')
              .lineHeight(Math.round(this.ref() * 0.028) + 'px')
              .textAlign(TextAlign.Start)
          }
          .alignItems(HorizontalAlign.Start)
          .width(Math.round(this.winW * 0.76) + 'px')
          .padding(Math.round(this.ref() * 0.020) + 'px')
          .backgroundColor('rgba(0,0,0,0.90)')
          .borderRadius(Math.round(this.ref() * 0.016) + 'px')
          // Below the corner toolbar (菜单 / 招式 / ✕ live at ~13–24% height)
          // so the user can still leave the page while reading the reason.
          .position({
            x: Math.round(this.winX0 + this.winW * 0.12) + 'px',
            y: Math.round(this.winY0 + this.winH * 0.30) + 'px'
          })
        }
        // Pop-out command panel.
        if (this.panelOpen) {
          this.panel()
        }
        // Toast.
        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(14)
            .fontColor(C_TEXT)
            .backgroundColor('rgba(0,0,0,0.67)')
            .borderRadius(8)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .position({ x: (this.layX + this.winW / 2 - 60) + 'px', y: (this.layY + this.ref() * 0.10) + 'px' })
        }
        // 3-slot load dialog.
        if (this.loadDialog) {
          this.loadDialogView()
        }
        // Cheats dialog (Switch per cheat / Choice for multi-option cheats).
        if (this.cheatsOpen) {
          this.cheatsDialogView()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // The Android build is bottom edge-to-edge (no navigation bar is reserved,
    // the picture runs to the last pixel). Give that strip back to the game.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.onPageArea(Number(newArea.width), Number(newArea.height))
    })
  }

  // ---------- cross d-pad (bottom-left) — port of VirtualPadView.drawDpad ----------
  // Visual is the classic 4-arm cross; the hit-test in applyDpad() is an 8-way
  // pie with NO dead zone, so a diagonal touch lights the two adjacent arms
  // (e.g. ↗ → ↑ + →). See applyDpad().
  @Builder
  dpad() {
    Stack() {
      // Connecting crosshair so the four buttons read as ONE control.
      this.dpadBar(this.dpadArmW(), this.dpadR() * 2,
        this.dpadOuterR() - this.dpadArmW() / 2, this.dpadOuterR() - this.dpadR())
      this.dpadBar(this.dpadR() * 2, this.dpadArmW(),
        this.dpadOuterR() - this.dpadR(), this.dpadOuterR() - this.dpadArmW() / 2)
      // Four arm discs.
      this.dpadArm(BTN_UP, '↑', this.dpadOuterR(), this.dpadOuterR() - this.dpadR(), this.dpadArmR())
      this.dpadArm(BTN_DOWN, '↓', this.dpadOuterR(), this.dpadOuterR() + this.dpadR(), this.dpadArmR())
      this.dpadArm(BTN_LEFT, '←', this.dpadOuterR() - this.dpadR(), this.dpadOuterR(), this.dpadArmR())
      this.dpadArm(BTN_RIGHT, '→', this.dpadOuterR() + this.dpadR(), this.dpadOuterR(), this.dpadArmR())
      // Filled centre cap (the disc is live — see applyDpad).
      this.dpadCap(this.dpadOuterR(), this.dpadOuterR(), this.dpadArmW() / 2)
    }
    .width(this.dpadOuterR() * 2 + 'px')
    .height(this.dpadOuterR() * 2 + 'px')
    .position({
      x: (this.dpadCx() - this.dpadOuterR()) + 'px',
      y: (this.dpadCy() - this.dpadOuterR()) + 'px'
    })
    .onTouch((e: TouchEvent) => {
      const t = e.touches[0]
      if (!t) return
      const d = this.densityScale
      if (e.type === TouchType.Down) {
        this.dpadPointer = t.id
        this.applyDpad(t.x * d, t.y * d, true)
      } else if (e.type === TouchType.Move) {
        if (this.dpadPointer === t.id) this.applyDpad(t.x * d, t.y * d, false)
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.dpadPointer === t.id) this.releaseDpad()
      }
    })
  }

  @Builder
  dpadBar(w: number, h: number, x: number, y: number) {
    Column()
      .width(w + 'px')
      .height(h + 'px')
      .borderRadius('50%')
      .backgroundColor(C_FILL)
      .position({ x: x + 'px', y: y + 'px' })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  dpadCap(cx: number, cy: number, r: number) {
    Column()
      .width(r * 2 + 'px')
      .height(r * 2 + 'px')
      .borderRadius('50%')
      .backgroundColor(C_FILL)
      .border({ width: this.strokeW(false) + 'px', color: C_STROKE })
      .position({ x: (cx - r) + 'px', y: (cy - r) + 'px' })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  dpadArm(bit: number, label: string, cx: number, cy: number, r: number) {
    // Stack+Text instead of Button: ArkUI's Button keeps its own 20vp corner
    // radius, so a Button can never be drawn as an exact circle.
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.isActive(bit) ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((r - (this.isActive(bit) ? this.pressInset() : 0)) * 2 + 'px')
    .height((r - (this.isActive(bit) ? this.pressInset() : 0)) * 2 + 'px')
    .borderRadius('50%')
    .backgroundColor(this.isActive(bit) ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.isActive(bit)) + 'px', color: this.isActive(bit) ? C_STROKE_ACTIVE : C_STROKE })
    .position({
      x: (cx - r + (this.isActive(bit) ? this.pressInset() : 0)) + 'px',
      y: (cy - r + (this.isActive(bit) ? this.pressInset() : 0)) + 'px'
    })
    .hitTestBehavior(HitTestMode.None)
  }

  // ---------- analog stick (STICK / DPAD8) — port of VirtualPadView.layoutStick ----------
  @Builder
  analogStick() {
    Stack() {
      // Base disc — fixed pivot, never follows the finger (drawStickBase L1596).
      Column()
        .width((this.stickBaseR() * 2) + 'px')
        .height((this.stickBaseR() * 2) + 'px')
        .borderRadius('50%')
        .backgroundColor(C_FILL)
        .border({ width: this.strokeW(this.stickActive()) + 'px',
          color: this.stickActive() ? C_STROKE_ACTIVE : C_STROKE })
        .hitTestBehavior(HitTestMode.None)
      // Inner ring at 0.62·baseR (drawStickBase L1600).
      Column()
        .width((this.stickBaseR() * 1.24) + 'px')
        .height((this.stickBaseR() * 1.24) + 'px')
        .borderRadius('50%')
        .border({ width: this.strokeW(false) + 'px',
          color: this.stickActive() ? C_STROKE_ACTIVE : C_STROKE })
        .position({ x: (this.stickBaseR() * 0.38) + 'px', y: (this.stickBaseR() * 0.38) + 'px' })
        .hitTestBehavior(HitTestMode.None)
      // Direction chevrons: triangles at 0.78·baseR (drawChevron L1610).
      Path()
        .width((this.stickBaseR() * 2) + 'px')
        .height((this.stickBaseR() * 2) + 'px')
        .commands(this.chevronCmds(0))
        .fill('rgba(255,255,255,0.41)')
        .hitTestBehavior(HitTestMode.None)
      Path()
        .width((this.stickBaseR() * 2) + 'px')
        .height((this.stickBaseR() * 2) + 'px')
        .commands(this.chevronCmds(1))
        .fill('rgba(255,255,255,0.41)')
        .hitTestBehavior(HitTestMode.None)
      Path()
        .width((this.stickBaseR() * 2) + 'px')
        .height((this.stickBaseR() * 2) + 'px')
        .commands(this.chevronCmds(2))
        .fill('rgba(255,255,255,0.41)')
        .hitTestBehavior(HitTestMode.None)
      Path()
        .width((this.stickBaseR() * 2) + 'px')
        .height((this.stickBaseR() * 2) + 'px')
        .commands(this.chevronCmds(3))
        .fill('rgba(255,255,255,0.41)')
        .hitTestBehavior(HitTestMode.None)
      // Active steering line: centre -> knob (drawStick L1590).
      if (this.stickActive()) {
        Path()
          .width((this.stickBaseR() * 2) + 'px')
          .height((this.stickBaseR() * 2) + 'px')
          .commands('M ' + this.stickBaseR() + ' ' + this.stickBaseR() + ' L ' + (this.stickBaseR() + this.knobX) + ' ' + (this.stickBaseR() + this.knobY))
          .fill('none')
          .stroke(C_STROKE_ACTIVE)
          .strokeWidth(this.strokeW(true))
          .hitTestBehavior(HitTestMode.None)
      }
      // Knob (static fill argb(120,255,255,255); amber when grabbed).
      Column()
        .width((this.knobR() * 2) + 'px')
        .height((this.knobR() * 2) + 'px')
        .borderRadius('50%')
        .backgroundColor(this.stickActive() ? C_FILL_ACTIVE : 'rgba(255,255,255,0.47)')
        .border({ width: this.strokeW(this.stickActive()) + 'px',
          color: this.stickActive() ? C_STROKE_ACTIVE : 'rgba(255,255,255,0.75)' })
        .position({
          x: (this.stickBaseR() - this.knobR() + this.knobX) + 'px',
          y: (this.stickBaseR() - this.knobR() + this.knobY) + 'px'
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width((this.stickBaseR() * 2) + 'px')
    .height((this.stickBaseR() * 2) + 'px')
    .position({
      x: (this.dpadCx() - this.stickBaseR()) + 'px',
      y: (this.dpadCy() - this.stickBaseR()) + 'px'
    })
    .onTouch((e: TouchEvent) => {
      const t = e.touches[0]
      if (!t) return
      const d = this.densityScale
      if (e.type === TouchType.Down) {
        this.stickPointer = t.id
        this.applyStick(t.x * d, t.y * d)
      } else if (e.type === TouchType.Move) {
        if (this.stickPointer === t.id) this.applyStick(t.x * d, t.y * d)
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.stickPointer === t.id) this.releaseStick()
      }
    })
  }

  // Triangle chevron path in the 2·baseR box; mirrors drawChevron L1610 (half-width 0.13·baseR, height 0.17·baseR, at 0.78·baseR).
  private chevronCmds(dir: number): string {
    const b = this.stickBaseR()
    const rr = b * 0.78
    const aw = b * 0.13
    const ah = b * 0.17
    let mx = b
    let my = b
    if (dir === 0) my = b - rr
    else if (dir === 1) my = b + rr
    else if (dir === 2) mx = b - rr
    else mx = b + rr
    if (dir === 0) {
      return 'M ' + mx + ' ' + (my - ah / 2) + ' L ' + (mx - aw) + ' ' + (my + ah / 2) + ' L ' + (mx + aw) + ' ' + (my + ah / 2) + ' Z'
    } else if (dir === 1) {
      return 'M ' + mx + ' ' + (my + ah / 2) + ' L ' + (mx - aw) + ' ' + (my - ah / 2) + ' L ' + (mx + aw) + ' ' + (my - ah / 2) + ' Z'
    } else if (dir === 2) {
      return 'M ' + (mx - ah / 2) + ' ' + my + ' L ' + (mx + ah / 2) + ' ' + (my - aw) + ' L ' + (mx + ah / 2) + ' ' + (my + aw) + ' Z'
    } else {
      return 'M ' + (mx + ah / 2) + ' ' + my + ' L ' + (mx - ah / 2) + ' ' + (my - aw) + ' L ' + (mx - ah / 2) + ' ' + (my + aw) + ' Z'
    }
  }

  // ---------- face buttons + shoulders + SELECT/START (right) ----------
  /**
   * Port of VirtualPadView.buildButtons() (NES/GB + the 8/16-bit profiles the
   * OHOS port ships). Positions are pre-computed into two lists and rendered
   * with ForEach: @Builder by-value params never re-lay-out on their own, so
   * the geometry must come from @State that changes with the window size.
   */
  private layoutPad(): void {
    if (this.winW <= 0 || this.winH <= 0) return
    const w = this.winW
    const h = this.winH
    const ref = this.ref()
    const baseR = this.baseR()
    const faceR = baseR * 0.50
    const pillW = baseR * 1.42
    const pillH = baseR * 0.55
    const gbaPillW = baseR * 1.22
    const gbaPillH = baseR * 0.48
    // Landscape anchors (pad-local, offset by layX/layY after the switch):
    // A 7% from right / 71% down, B 15% / 79%, SELECT-START column at 92%.
    const ax = w * 0.93
    const ay = h * 0.71
    const bx = w * 0.85
    const by = h * 0.79
    const ssCx = w * 0.92
    const selectY = h * 0.244
    const startY = h * 0.350
    const shoulderY = h * 0.180
    const gbaSelY = h * 0.282
    const gbaStartY = h * 0.380

    const circles: PadCircleSpec[] = []
    const pills: PadPillSpec[] = []
    const addCircle = (bit: number, label: string, cx: number, cy: number, r: number = faceR): void => {
      circles.push({ bit: bit, label: label, cx: cx, cy: cy, r: r })
    }
    // stackRows(): keep the preferred rows when they clear the top chrome and
    // the A circle, otherwise re-space (and shrink no lower than 0.6x) them.
    const fit = (hs: number[], ys: number[]): number[][] => {
      // Top limit: the chrome row's bottom edge (+1.2% ref gap), exactly like
      // EmulatorActivity.notifyPadChromeBottom() -> setTopChromeBottom().
      const chromeBottom = h * 0.017 + (ref * 0.10 - this.toolPillH()) / 2 + this.toolPillH()
      const topLimit = Math.max(ref * 0.16, chromeBottom + ref * 0.012)
      const bottomLimit = ay - faceR - ref * 0.028
      const gapMin = ref * 0.011
      let ok = ys[0] - hs[0] / 2 >= topLimit &&
        ys[ys.length - 1] + hs[hs.length - 1] / 2 <= bottomLimit
      for (let i = 1; i < ys.length; i++) {
        if (ys[i] - hs[i] / 2 - (ys[i - 1] + hs[i - 1] / 2) < gapMin) ok = false
      }
      if (ok) return [ys, hs]
      const region = Math.max(0, bottomLimit - topLimit)
      let sum = 0
      for (const v of hs) sum += v
      const needed = sum + gapMin * (hs.length - 1)
      const scale = region < needed ? Math.min(1, Math.max(0.6, region / needed)) : 1
      const heights: number[] = hs.map((v: number) => v * scale)
      let hsum = 0
      for (const v of heights) hsum += v
      const gap = heights.length > 1 ? Math.max(gapMin, (region - hsum) / (heights.length - 1)) : 0
      const out: number[] = []
      let edge = topLimit
      for (const hh of heights) {
        edge += hh / 2
        out.push(edge)
        edge += hh / 2 + gap
      }
      return [out, heights]
    }

    switch (this.profile) {
      case 'GBA': {
        const f = fit([pillH, gbaPillH, gbaPillH], [shoulderY, gbaSelY, gbaStartY])
        pills.push({ bit: BTN_L, label: 'L', cx: w * 0.07, cy: f[0][0], w: pillW, h: f[1][0] })
        pills.push({ bit: BTN_R, label: 'R', cx: ssCx, cy: f[0][0], w: pillW, h: f[1][0] })
        pills.push({ bit: BTN_SELECT, label: 'SELECT', cx: ssCx, cy: f[0][1], w: gbaPillW, h: f[1][1] })
        pills.push({ bit: BTN_START, label: 'START', cx: ssCx, cy: f[0][2], w: gbaPillW, h: f[1][2] })
        addCircle(BTN_B, 'B', bx, by)
        addCircle(BTN_A, 'A', ax, ay)
        break
      }
      case 'A2600': {
        addCircle(BTN_B, 'FIRE', ax, ay)
        const f = fit([pillH, pillH], [selectY, startY])
        pills.push({ bit: BTN_SELECT, label: 'SELECT', cx: ssCx, cy: f[0][0], w: pillW, h: f[1][0] })
        pills.push({ bit: BTN_START, label: 'RESET', cx: ssCx, cy: f[0][1], w: pillW, h: f[1][1] })
        break
      }
      case 'SMS':
      case 'GG': {
        addCircle(BTN_B, '1', bx, by)
        addCircle(BTN_A, '2', ax, ay)
        const f = fit([pillH], [startY])
        pills.push({ bit: BTN_START, label: 'PAUSE', cx: ssCx, cy: f[0][0], w: pillW, h: f[1][0] })
        break
      }
      case 'MD': {
        addCircle(BTN_Y, 'A', bx - baseR * 0.85, by + baseR * 0.55)
        addCircle(BTN_B, 'B', bx, by)
        addCircle(BTN_A, 'C', ax, ay)
        const f = fit([pillH], [startY])
        pills.push({ bit: BTN_START, label: 'START', cx: ssCx, cy: f[0][0], w: pillW, h: f[1][0] })
        break
      }
      case 'MAME': {
        // CPS six-button panel in the right letterbox (0.794w ~ 0.992w), per §2.6.
        // Column order must match Android's VirtualPadView exactly:
        // weak->strong left to right (X Y Z / A B C) like a real CPS cabinet.
        const barTo = w * 0.992
        const barW = barTo - w * 0.794
        const edgeGap = 0.008 * w
        const aR = Math.min(0.072 * ref, (barW - 2 * edgeGap) / 6)
        const colGap = 2 * aR + (barW - 6 * aR) / 2
        const rowGap = 2.5 * aR
        const cxR = barTo - aR
        const cyBot = h - 0.03 * ref - aR
        const cyTop = cyBot - rowGap
        addCircle(BTN_Y, 'X', cxR - 2 * colGap, cyTop, aR) // X -> Y
        addCircle(BTN_X, 'Y', cxR - colGap, cyTop, aR)     // Y -> X
        addCircle(BTN_L, 'Z', cxR, cyTop, aR)              // Z -> L
        addCircle(BTN_B, 'A', cxR - 2 * colGap, cyBot, aR) // A -> B
        addCircle(BTN_A, 'B', cxR - colGap, cyBot, aR)     // B -> A
        addCircle(BTN_R, 'C', cxR, cyBot, aR)              // C -> R
        break
      }
      case 'NEOGEO': {
        // NEOGEO mini four-button panel (2x2) in the right letterbox, per §2.6.
        const barTo = w * 0.992
        const barW = barTo - w * 0.794
        const edgeGap = 0.008 * w
        const aR = Math.min(0.088 * ref, (barW - edgeGap) / 4.5)
        const colGap = 2.5 * aR
        const rowGap = 2.3 * aR
        const cxR = barTo - edgeGap - aR
        const cxL = cxR - colGap
        const cyBot = h - 0.03 * ref - aR
        const cyTop = cyBot - rowGap
        addCircle(BTN_B, 'A', cxL, cyTop, aR)             // A -> B
        addCircle(BTN_A, 'B', cxR, cyTop, aR)             // B -> A
        addCircle(BTN_Y, 'C', cxL, cyBot, aR)             // C -> Y
        addCircle(BTN_X, 'D', cxR, cyBot, aR)             // D -> X
        break
      }
      default: {
        addCircle(BTN_B, 'B', bx, by)
        addCircle(BTN_A, 'A', ax, ay)
        const f = fit([pillH, pillH], [selectY, startY])
        pills.push({ bit: BTN_SELECT, label: 'SELECT', cx: ssCx, cy: f[0][0], w: pillW, h: f[1][0] })
        pills.push({ bit: BTN_START, label: 'START', cx: ssCx, cy: f[0][1], w: pillW, h: f[1][1] })
        break
      }
    }
    // Shift the whole pad from pad-local space into the window's content box.
    for (const c of circles) {
      c.cx += this.layX
      c.cy += this.layY
    }
    for (const p of pills) {
      p.cx += this.layX
      p.cy += this.layY
    }
    // Arcade overlay geometry (MAME/NEOGEO menu + NEOGEO 招式 panel), per §2.7/§2.8.
    const apillW = baseR * 1.42
    const apillH = baseR * 0.55
    const amenuY = this.layY + 0.017 * h + 0.05 * ref
    const aexitLeft = this.layX + w - 0.017 * w - 0.077 * ref
    const ahGap = 0.012 * w
    this.arcMenuCx = aexitLeft - ahGap - apillW / 2
    this.arcMenuY = amenuY
    this.arcPillW = apillW
    this.arcPillH = apillH
    this.arcMenuGap = ahGap + apillW
    // NEOGEO 招式 (fight-assist) row — 1:1 port of Android buildFightAssist():
    // a collapsible pill plus a 2-wide grid that fills the right letterbox band
    // between the pill and the A/B/C/D cluster. Cells are sized to the band
    // (not to the pill), and the grid is capped above the cluster so it can
    // never overlap the discs the thumb rests on.
    const barFrom = w * 0.794
    const barTo = w * 0.992
    const barW = barTo - barFrom
    const barPad = w * 0.008
    const aR = Math.min(0.088 * ref, (barW - barPad) / 4.5)
    // Top of the A/B/C/D cluster: same maths as the NEOGEO face branch.
    const clusterTop = this.layY + h - 0.03 * ref - aR - 2.3 * aR - aR
    const cxAssist = this.layX + (barFrom + barTo) / 2
    // Android's pillTop is the TOP edge; convert to a center for our pill builder.
    const pillCenter = amenuY + apillH + 0.022 * ref
    this.movesCx = cxAssist
    this.movesPillTop = pillCenter
    const gridTop = pillCenter + apillH / 2 + 0.022 * ref
    const gridBottom = clusterTop - 0.022 * ref
    const n = this.movesPresets.length
    const cols = 2
    const rows = Math.ceil(n / cols)
    const gapX = 0.018 * ref
    const gapY = 0.014 * ref
    const cellW = ((barW - 2 * barPad) - (cols - 1) * gapX) / cols
    const cellH = ((gridBottom - gridTop) - (rows - 1) * gapY) / rows
    const gridW = cols * cellW + (cols - 1) * gapX
    const startX = cxAssist - gridW / 2
    const cells: MoveCellSpec[] = []
    if (gridBottom > gridTop && cellW > 0 && cellH > 0) {
      for (let i = 0; i < n; i++) {
        const col = i % cols
        const row = Math.floor(i / cols)
        const cx = startX + col * (cellW + gapX) + cellW / 2
        const cy = gridTop + row * (cellH + gapY) + cellH / 2
        cells.push({ label: this.movesPresets[i].label, script: this.movesPresets[i].script, cx, cy, w: cellW, h: cellH })
      }
    }
    this.movesCells = cells
    this.padCircles = circles
    this.padPills = pills
  }

  @Builder
  faceAndPills() {
    ForEach(this.padCircles, (c: PadCircleSpec) => {
      this.padCircle(c.bit, c.label, c.cx, c.cy, c.r)
    }, (c: PadCircleSpec) => 'c' + c.bit + c.label)
    ForEach(this.padPills, (p: PadPillSpec) => {
      this.padPill(p.bit, p.label, p.cx, p.cy, p.w, p.h)
    }, (p: PadPillSpec) => 'p' + p.bit + p.label)
  }

  @Builder
  padCircle(bit: number, label: string, cx: number, cy: number, r: number) {
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.isActive(bit) ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((r - (this.isActive(bit) ? this.pressInset() : 0)) * 2 + 'px')
    .height((r - (this.isActive(bit) ? this.pressInset() : 0)) * 2 + 'px')
    .borderRadius('50%')
    .backgroundColor(this.isActive(bit) ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.isActive(bit)) + 'px', color: this.isActive(bit) ? C_STROKE_ACTIVE : C_STROKE })
    .position({
      x: (cx - r + (this.isActive(bit) ? this.pressInset() : 0)) + 'px',
      y: (cy - r + (this.isActive(bit) ? this.pressInset() : 0)) + 'px'
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.press(bit)
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.release(bit)
    })
  }

  @Builder
  padPill(bit: number, label: string, cx: number, cy: number, w: number, h: number) {
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.isActive(bit) ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((w - (this.isActive(bit) ? this.pressInset() * 2 : 0)) + 'px')
    .height((h - (this.isActive(bit) ? this.pressInset() * 2 : 0)) + 'px')
    .borderRadius('50%')
    .backgroundColor(this.isActive(bit) ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.isActive(bit)) + 'px', color: this.isActive(bit) ? C_STROKE_ACTIVE : C_STROKE })
    .position({
      x: (cx - w / 2 + (this.isActive(bit) ? this.pressInset() : 0)) + 'px',
      y: (cy - h / 2 + (this.isActive(bit) ? this.pressInset() : 0)) + 'px'
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.press(bit)
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.release(bit)
    })
  }

  // ---------- arcade profile overlays (MAME / NEOGEO) ----------
  @Builder
  arcadeMenu() {
    this.arcadeMenuPill(this.arcMenuCx, this.arcMenuY, this.arcPillW, this.arcPillH)
    if (this.menuExpanded) {
      this.padPill(BTN_START, '开始', this.arcMenuCx - this.arcMenuGap, this.arcMenuY, this.arcPillW, this.arcPillH)
      this.padPill(BTN_SELECT, '投币', this.arcMenuCx - 2 * this.arcMenuGap, this.arcMenuY, this.arcPillW, this.arcPillH)
      // Netplay: the port is derived from the role, so the pill is meaningless
      // (Android hides it and locks pad.portLocked = true).
      if (!this.netplayParams) {
        this.playerTogglePill(this.arcMenuCx - 3 * this.arcMenuGap, this.arcMenuY, this.arcPillW, this.arcPillH)
      }
    }
  }

  @Builder
  arcadeMenuPill(cx: number, cy: number, w: number, h: number) {
    Stack() {
      Text(this.menuExpanded ? '收起' : '菜单')
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.menuExpanded ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((w - (this.menuExpanded ? this.pressInset() * 2 : 0)) + 'px')
    .height((h - (this.menuExpanded ? this.pressInset() * 2 : 0)) + 'px')
    .borderRadius('50%')
    .backgroundColor(this.menuExpanded ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.menuExpanded) + 'px', color: this.menuExpanded ? C_STROKE_ACTIVE : C_STROKE })
    .position({ x: (cx - w / 2 + (this.menuExpanded ? this.pressInset() : 0)) + 'px', y: (cy - h / 2 + (this.menuExpanded ? this.pressInset() : 0)) + 'px' })
    .onTouch((e: TouchEvent) => { if (e.type === TouchType.Down) this.menuExpanded = !this.menuExpanded })
  }

  @Builder
  playerTogglePill(cx: number, cy: number, w: number, h: number) {
    Stack() {
      Text(this.playerPort === 1 ? '2P' : '1P')
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.playerPort === 1 ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((w - (this.playerPort === 1 ? this.pressInset() * 2 : 0)) + 'px')
    .height((h - (this.playerPort === 1 ? this.pressInset() * 2 : 0)) + 'px')
    .borderRadius('50%')
    .backgroundColor(this.playerPort === 1 ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.playerPort === 1) + 'px', color: this.playerPort === 1 ? C_STROKE_ACTIVE : C_STROKE })
    .position({ x: (cx - w / 2 + (this.playerPort === 1 ? this.pressInset() : 0)) + 'px', y: (cy - h / 2 + (this.playerPort === 1 ? this.pressInset() : 0)) + 'px' })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.playerPort = this.playerPort === 1 ? 0 : 1
        // Hand control of the core's pad port over: without this the pad drives
        // port 0 no matter what the pill says (Android: GsRunner::activePort_).
        setPlayerPort(this.playerPort)
      }
    })
  }

  @Builder
  movesPanel() {
    this.movesPill(this.movesCx, this.movesPillTop, this.arcPillW, this.arcPillH)
    if (this.movesExpanded) {
      ForEach(this.movesCells, (c: MoveCellSpec) => {
        this.moveCell(c.label, c.script, c.cx, c.cy, c.w, c.h)
      }, (c: MoveCellSpec) => c.label + '|' + c.script)
    }
  }

  @Builder
  movesPill(cx: number, cy: number, w: number, h: number) {
    Stack() {
      Text(this.movesExpanded ? '收起' : '招式')
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(this.movesExpanded ? C_TEXT_ACTIVE : C_TEXT)
    }
    .width((w - (this.movesExpanded ? this.pressInset() * 2 : 0)) + 'px')
    .height((h - (this.movesExpanded ? this.pressInset() * 2 : 0)) + 'px')
    .borderRadius((this.ref() * 0.05) + 'px')
    .backgroundColor(this.movesExpanded ? C_FILL_ACTIVE : C_FILL)
    .border({ width: this.strokeW(this.movesExpanded) + 'px', color: this.movesExpanded ? C_STROKE_ACTIVE : C_STROKE })
    .position({ x: (cx - w / 2 + (this.movesExpanded ? this.pressInset() : 0)) + 'px', y: (cy - h / 2 + (this.movesExpanded ? this.pressInset() : 0)) + 'px' })
    .onTouch((e: TouchEvent) => { if (e.type === TouchType.Down) this.movesExpanded = !this.movesExpanded })
  }

  @Builder
  moveCell(label: string, script: string, cx: number, cy: number, w: number, h: number) {
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(C_TEXT)
    }
    .width(w + 'px')
    .height(h + 'px')
    .borderRadius((this.ref() * 0.05) + 'px')
    .backgroundColor(C_FILL)
    .border({ width: this.strokeW(false) + 'px', color: C_STROKE })
    .position({ x: (cx - w / 2) + 'px', y: (cy - h / 2) + 'px' })
    .onTouch((e: TouchEvent) => { if (e.type === TouchType.Down) this.playMove(script) })
  }

  private playMove(script: string): void {
    // Netplay-safe: every macro frame is replayed through press()/release(),
    // i.e. the SAME press path the on-screen keys use — during a netplay
    // session that path feeds netplayLocalMask (the lockstep gate's own
    // local slot), so the move is just ordinary local input and cannot
    // desync the pair. (The desync risk belonged to Android's old
    // nativePlayMacro path, which bypassed the per-frame mask entirely.)
    this.cancelMacro()
    const steps = this.parseMacro(script)
    if (steps.length === 0) return
    const FRAME_MS = 50 // 3 frames @ 60fps
    let i = 0
    const tick = (): void => {
      if (this.macroBits !== 0) {
        this.applyMacroMask(this.macroBits, false)
        this.macroBits = 0
      }
      if (i >= steps.length) { this.macroTimer = -1; return }
      this.macroBits = steps[i++]
      this.applyMacroMask(this.macroBits, true)
      this.macroTimer = setTimeout(tick, FRAME_MS)
    }
    tick()
  }

  private cancelMacro(): void {
    if (this.macroTimer !== -1) {
      clearTimeout(this.macroTimer)
      this.macroTimer = -1
    }
    if (this.macroBits !== 0) {
      this.applyMacroMask(this.macroBits, false)
      this.macroBits = 0
    }
  }

  private applyMacroMask(mask: number, on: boolean): void {
    for (let b = 0; b < 16; b++) {
      if (((mask >> b) & 1) === 1) {
        if (on) this.press(b); else this.release(b)
      }
    }
  }

  // assets/moves_presets.json script syntax (SpecialMovesStore.ScriptCompiler):
  // numpad direction digits 1-9 (5 = neutral) + comma-separated motions +
  // '+' joins a motion to a button group; buttons P/H/L/K. The button is held
  // on the final direction step (e.g. 236+P = ↓,↘,→+P).
  private parseMacro(script: string): number[] {
    const out: number[] = []
    const subs = script.split(',')
    for (const sub of subs) {
      const plus = sub.split('+')
      const motion = plus[0] ?? ''
      const btns = plus.length > 1 ? plus[1] : ''
      const btnMask = this.macroButtonMask(btns)
      const digits = motion.split('')
      for (let k = 0; k < digits.length; k++) {
        let m = this.macroDirMask(digits[k])
        if (k === digits.length - 1) m |= btnMask
        out.push(m)
      }
    }
    return out
  }

  private macroDirMask(d: string): number {
    switch (d) {
      case '8': return 1 << BTN_UP
      case '2': return 1 << BTN_DOWN
      case '4': return 1 << BTN_LEFT
      case '6': return 1 << BTN_RIGHT
      case '7': return (1 << BTN_UP) | (1 << BTN_LEFT)
      case '9': return (1 << BTN_UP) | (1 << BTN_RIGHT)
      case '1': return (1 << BTN_DOWN) | (1 << BTN_LEFT)
      case '3': return (1 << BTN_DOWN) | (1 << BTN_RIGHT)
      default: return 0
    }
  }

  private macroButtonMask(s: string): number {
    let m = 0
    for (const ch of s) {
      // Must match Android's ScriptCompiler.buttonMasks exactly, otherwise a
      // 一键必杀 presses the wrong NeoGeo face button (P/K were previously swapped
      // here, so 波/升/超 fired B/D instead of A/C). NEOGEO candy mapping:
      // A->BTN_B, B->BTN_A, C->BTN_Y, D->BTN_X; macro letters:
      //   P -> BTN_B (bit0)   H -> BTN_Y (bit1)
      //   L -> BTN_A (bit8)   K -> BTN_X (bit9)
      if (ch === 'P') m |= (1 << BTN_B)
      else if (ch === 'K') m |= (1 << BTN_X)
      else if (ch === 'H') m |= (1 << BTN_Y)
      else if (ch === 'L') m |= (1 << BTN_A)
    }
    return m
  }

  // ---------- corner toolbar: 功能 (top-left) + ✕ (top-right) ----------
  private toolRowX(): number { return this.layX + this.winW * 0.017 }
  private toolRowY(): number {
    return this.layY + this.winH * 0.017 + (this.ref() * 0.10 - this.toolPillH()) / 2
  }

  @Builder
  cornerToolbar() {
    this.toolPill('功能', C_STROKE, this.toolPillW(), this.toolPillH(),
      this.toolRowX(), this.toolRowY(),
      () => { this.panelOpen = !this.panelOpen })
    Stack() {
      Text('✕')
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(C_EXIT)
    }
    .width(this.toolPillH() + 'px').height(this.toolPillH() + 'px')
    .borderRadius('50%')
    .backgroundColor(C_FILL)
    .border({ width: this.strokeW(false) + 'px', color: 'rgba(239,154,154,0.82)' })
    .position({
      x: (this.layX + this.winW - this.winW * 0.017 - this.toolPillH()) + 'px',
      y: this.toolRowY() + 'px'
    })
    .onClick(() => { this.exitToLibrary() })
  }

  @Builder
  toolPill(label: string, stroke: string, w: number, h: number, x: number, y: number, action: () => void) {
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(C_TEXT)
    }
    .width(w + 'px').height(h + 'px')
    .borderRadius('50%')
    .backgroundColor(C_FILL)
    .border({ width: this.strokeW(false) + 'px', color: stroke })
    .position({ x: x + 'px', y: y + 'px' })
    .onClick(action)
  }

  // ---------- pop-out command panel (to the right of 功能) ----------
  @Builder
  panel() {
    Row({ space: 0 }) {
      this.panelBtn('摇杆', () => { this.onCommand('摇杆') })
      this.panelBtn(this.speedMult > 1 ? ('加速×' + this.speedMult) : '加速', () => { this.onCommand('加速') })
      this.panelBtn('重开', () => { this.onCommand('重开') })
      this.panelBtn('金手', () => { this.onCommand('金手') })
      this.panelBtn('存档', () => { this.onCommand('存档') })
      this.panelBtn('读档', () => { this.onCommand('读档') })
    }
    .height(this.toolPillH() + 'px')
    .position({
      x: (this.toolRowX() + this.toolPillW() + this.winW * 0.012 - this.winW * 0.006) + 'px',
      y: this.toolRowY() + 'px'
    })
    .onClick(() => { this.panelOpen = false })
  }

  @Builder
  panelBtn(label: string, action: () => void) {
    Stack() {
      Text(label)
        .fontSize((this.ref() * 0.042) + 'px')
        .fontColor(C_TEXT)
    }
    .width(this.toolPillW() + 'px').height(this.toolPillH() + 'px')
    .borderRadius('50%')
    .backgroundColor(C_FILL)
    .border({ width: this.strokeW(false) + 'px', color: C_STROKE })
    .margin({ left: (this.winW * 0.006) + 'px', right: (this.winW * 0.006) + 'px' })
    .onClick(action)
  }

  // ---------- 3-slot load dialog (mirrors EmulatorActivity's load list) ----------
  @Builder
  loadDialogView() {
    // Dimmed backdrop (tap to dismiss).
    Column()
      .width('100%').height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .onClick(() => { this.loadDialog = false })
    Column() {
      Text('读档')
        .fontSize((this.ref() * 0.05) + 'px')
        .fontColor('#222222')
        .fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: this.ref() * 0.016 })
      ForEach(this.saveList, (s: SaveSlotInfo) => {
        Row() {
          if (s.thumb) {
            Image(s.thumb)
              .width((this.ref() * 0.13) + 'px')
              .height((this.ref() * 0.13 * s.h / s.w) + 'px')
              .borderRadius(this.ref() * 0.01)
              .objectFit(ImageFit.Cover)
          } else {
            Column()
              .width((this.ref() * 0.13) + 'px')
              .height((this.ref() * 0.13 * (s.h > 0 ? s.h / s.w : 0.75)) + 'px')
              .backgroundColor('rgba(255,255,255,0.12)')
          }
          Column() {
            Text('槽位 ' + (s.slot + 1))
              .fontColor('#222222')
              .fontSize(15)
            Text(s.exists ? this.fmtTime(s.time) : '空')
              .fontColor(s.exists ? '#888888' : '#BBBBBB')
              .fontSize(12)
          }
          .layoutWeight(1)
          .alignSelf(ItemAlign.Center)
          .padding({ left: this.ref() * 0.012 })
          if (s.exists) {
            Button('读档')
              .fontSize(14)
              .backgroundColor(C_FILL_ACTIVE)
              .fontColor(C_TEXT_ACTIVE)
              .borderRadius(this.ref() * 0.02)
              .onClick(() => { this.loadSlot(s.slot) })
            Button('删除')
              .fontSize(14)
              .backgroundColor('rgba(239,154,154,0.9)')
              .fontColor('#FFFFFF')
              .borderRadius(this.ref() * 0.02)
              .onClick(() => { this.deleteSave(s.slot) })
          }
        }
        .width('100%')
        .padding(this.ref() * 0.01)
        .margin({ bottom: this.ref() * 0.01 })
        .backgroundColor('rgba(255,255,255,0.92)')
        .borderRadius(this.ref() * 0.02)
      }, (s: SaveSlotInfo) => 'slot' + s.slot)
      Button('关闭')
        .width('100%')
        .fontSize(15)
        .backgroundColor(C_FILL)
        .fontColor(C_TEXT)
        .borderRadius(this.ref() * 0.02)
        .margin({ top: this.ref() * 0.01 })
        .onClick(() => { this.loadDialog = false })
    }
    .width('78%')
    .padding(this.ref() * 0.025)
    .backgroundColor('#FFFFFF')
    .borderRadius(this.ref() * 0.03)
    .position({ x: (this.layX + this.winW / 2) + 'px', y: (this.layY + this.winH / 2) + 'px' })
    .translate({ x: '-50%', y: '-50%' })
  }

  private onCommand(label: string): void {
    switch (label) {
      case '摇杆': {
        // VirtualPadView.StickMode cycle: STICK -> DPAD8 -> DPAD4 -> STICK
        const order: StickMode[] = ['STICK', 'DPAD8', 'DPAD4']
        const idx = (order.indexOf(this.stickMode) + 1) % order.length
        this.stickMode = order[idx]
        this.saveSettings()
        const name = this.stickMode === 'STICK' ? '模拟摇杆'
          : this.stickMode === 'DPAD8' ? '十字键(八向)' : '十字键(四向)'
        this.showToast('摇杆模式：' + name)
        break
      }
      case '加速': {
        // EmulatorActivity.cycleSpeed(): 1 -> 2 -> 4 -> 6 -> 8 -> 1
        const steps = [1, 2, 4, 6, 8]
        const idx = (steps.indexOf(this.speedMult) + 1) % steps.length
        this.speedMult = steps[idx]
        setSpeed(this.speedMult)
        // "加速时同步音频": when OFF, mute while fast-forwarding for stable frames.
        this.applyFastForwardAudio()
        this.showToast(this.speedMult === 1
          ? '已恢复常速'
          : ('游戏加速 ×' + this.speedMult + (this.fastForwardAudio ? '（音效同步加快）' : '（已静音）')))
        break
      }
      case '重开':
        this.confirmRestart()
        break
      case '金手':
        this.openCheatsDialog()
        this.panelOpen = false
        break
      case '存档': {
        // Android writes to the next of 3 slots (auto-advancing).
        const slot = this.saveSlot
        const ok = saveStateSlot(slot)
        if (ok) {
          this.showToast('已存档 槽 ' + (slot + 1))
          this.saveSlot = (slot + 1) % 3
        } else {
          this.showToast('存档失败')
        }
        this.panelOpen = false
        break
      }
      case '读档':
        this.openLoadDialog()
        this.panelOpen = false
        break
      default:
        break
    }
  }

  // ---- boot diagnostics ----
  /// Polls libgpretro's load-error slot and turns it into a user-facing
  /// explanation. Cheap (a short string read) so it rides the 500 ms FPS tick.
  private pollLoadError(): void {
    try {
      const raw: string = getLoadError()
      if (raw === this.loadErrorRaw) return
      this.loadErrorRaw = raw
      if (!raw || raw.length === 0) {
        this.loadErrorMsg = ''
        return
      }
      console.error('[EmulatorSpike] load failed: ' + raw)
      this.loadErrorMsg = this.formatLoadError(raw)
    } catch (e) {
      // Older host builds without getLoadError: nothing to show.
    }
  }

  /// `{"reason":"load_game","missing":["nffe.03"],"detail":"…"}` -> Chinese text
  /// that tells the user what to import / which ROM set to use.
  private formatLoadError(raw: string): string {
    let info: LoadErrorInfo = {}
    try {
      info = JSON.parse(raw) as LoadErrorInfo
    } catch (e) {
      return '游戏无法启动\n\n' + raw
    }
    const head = '游戏无法启动\n\n'
    const missing: string[] = (info.missing && info.missing.length > 0) ? info.missing : []
    if (info.reason === 'dlopen') {
      return head + '模拟核心加载失败：' + missing.join('、') +
        '\n\n该核心未随安装包提供，请安装包含街机核心的完整版本。'
    }
    if (info.reason === 'rom_missing') {
      return head + '找不到游戏文件：' + missing.join('、') +
        '\n\n请重新导入该游戏后重试。'
    }
    let s = head + '该游戏 ROM 集与 MAME 0.289 不匹配，核心拒绝启动。'
    if (missing.length > 0) {
      s += '\n\n缺少文件：\n'
      for (const m of missing) {
        s += '· ' + m + '\n'
      }
    }
    // Turn the missing-file list into a concrete action. These filenames are
    // unambiguous: dl-* belong to the CPS2 QSound sample set (qsound.zip) and
    // the NeoGeo BIOS entries live in neogeo.zip, while a `.key` only exists in
    // FBA / WinKawaks encrypted sets that MAME cannot read at all.
    let biosHint = ''
    for (const m of missing) {
      const low = m.toLowerCase()
      if (low === 'dl-1425.bin' || low === 'dl-1425am.bin') {
        biosHint = '\n\n已安装的 qsound.zip 不完整（缺少 QSound 样本 ' + m +
          '），请重新导入完整的 qsound.zip（设置 → 系统文件（BIOS））。'
        break
      }
      if (low.endsWith('.key')) {
        biosHint = '\n\n该 ROM 是 FBA / WinKawaks 风格的加密 CPS2 集（含 .key 文件），' +
          'MAME 无法解密；必须换用 MAME 0.289 对应版本的 ROM 集。'
        break
      }
      if (low.includes('qsound')) {
        biosHint = '\n\n已安装的 qsound.zip / qsound_hle.zip 不完整或缺失（缺少 ' + m +
          '），请重新导入完整的 Q-Sound BIOS（设置 → 系统文件（BIOS））。'
        break
      }
      if (low.includes('pgm')) {
        biosHint = '\n\n缺少 IGS PGM 基板 BIOS（pgm.zip），请导入 pgm.zip（设置 → 系统文件（BIOS））。'
        break
      }
      if (_neogeoBiosFiles.indexOf(low) >= 0) {
        biosHint = '\n\n已安装的 neogeo.zip 不完整或版本不符（缺少 ' + m +
          '），请重新导入完整的 neogeo.zip（设置 → 系统文件（BIOS））。'
        break
      }
    }
    s += biosHint
    if (biosHint.length === 0) {
      s += '\n常见原因：该 zip 多为 FBA / WinKawaks 风格的加密 CPS2 集（含 .key 文件），' +
        'MAME 不支持，请换用 MAME 0.289 对应版本的 ROM 集；只含 clone 的合集需同时有 ' +
        'parent（如 1943j 需 1943.zip）。'
    }
    return s
  }

  // ---- settings persistence (settings.json next to the ROMs) ----

  /// Directory holding app-level config (`settings.json`, `library/moves.json`).
  ///
  /// MUST be the same dir the Flutter plugin (GamePouchPlugin) uses, because
  /// that is where the Settings sheet's values are stamped and where the Dart
  /// `SpecialMovesEditor` writes `moves.json`. `getFilesDir()` (NAPI) points at
  /// a *different* sandbox dir on real devices, which silently severed the
  /// Settings sheet from the emulator. GamePouchPlugin passes the authoritative
  /// path through router params; NAPI is only a fallback for the bench page.
  private configDir(): string {
    if (this.cfgDir.length > 0) return this.cfgDir
    const d = getFilesDir() as string
    return d ? d : ''
  }

  private loadSettings(): void {
    try {
      const dir = this.configDir()
      if (!dir) return
      const path = dir + '/settings.json'
      if (!fs.accessSync(path)) {
        console.info('[EmulatorSpike] loadSettings: no ' + path)
        return
      }
      const data = fs.readTextSync(path)
      const j: Settings = JSON.parse(data) as Settings
      console.info('[EmulatorSpike] loadSettings dir=' + dir + ' raw=' + data)
      if (j.stickMode === 'STICK' || j.stickMode === 'DPAD8' || j.stickMode === 'DPAD4') {
        this.stickMode = j.stickMode
      }
      if (typeof j.padScale === 'number' && j.padScale > 0) {
        this.padScale = j.padScale
      }
      if (typeof j.stickDeadzone === 'number' && j.stickDeadzone >= 0 && j.stickDeadzone <= 1) {
        this.stickDeadzone = j.stickDeadzone
      }
      if (typeof j.useDpadUi === 'boolean') {
        this.useDpadUi = j.useDpadUi
      }
      if (typeof j.padOffsetX === 'number' && j.padOffsetX >= -0.45 && j.padOffsetX <= 0.45) {
        this.padOffsetX = j.padOffsetX
      }
      if (typeof j.padOffsetY === 'number' && j.padOffsetY >= -0.45 && j.padOffsetY <= 0.45) {
        this.padOffsetY = j.padOffsetY
      }
      if (typeof j.showFpsHud === 'boolean') this.showFpsHud = j.showFpsHud
      if (typeof j.highRefreshRate === 'boolean') this.highRefreshRate = j.highRefreshRate
      if (typeof j.fastForwardAudio === 'boolean') this.fastForwardAudio = j.fastForwardAudio
      // Load user-configured 招式 presets (overrides the built-in defaults so the
      // SettingsSheet editor's moves take effect on the native surface).
      this.loadMoves()
    } catch (e) {
      console.warn('[EmulatorSpike] loadSettings failed: ' + JSON.stringify(e))
    }
  }

  // Reads <filesDir>/library/moves.json (same file the Flutter SpecialMovesEditor
  // writes) and replaces the built-in 招式 presets with the active profile's moves.
  // Falls back to the built-in defaults when the file is missing/empty/invalid.
  private loadMoves(): void {
    try {
      const dir = this.configDir()
      if (!dir) return
      const path = dir + '/library/moves.json'
      if (!fs.accessSync(path)) return
      const data = fs.readTextSync(path)
      const j: MovesJson = JSON.parse(data) as MovesJson
      const profs = j.profiles
      const id = j.activeProfileId
      if (!profs || !id) return
      const prof: MoveProfile | undefined = profs[id]
      const list = prof ? prof.moves : undefined
      if (!list || !Array.isArray(list)) return
      const moves: MovePreset[] = []
      for (const m of list) {
        if (m && typeof m.script === 'string' && m.script.length > 0) {
          const label: string = (typeof m.label === 'string' && m.label.length > 0) ? m.label : m.script
          moves.push({ label: label, script: m.script })
        }
      }
      console.info(`[EmulatorSpike] loadMoves dir=${dir} profile=${id} n=${moves.length}` +
        (moves.length > 0 ? ` first=${moves[0].label}|${moves[0].script}` : ''))
      if (moves.length > 0) this.movesPresets = moves
    } catch (e) {
      console.warn('[EmulatorSpike] loadMoves failed: ' + JSON.stringify(e))
    }
  }

  // Applies the "高刷新率" toggle. NOTE: the OHOS public SDK (API 26) exposes no
  // per-window refresh-rate setter (Window only has setPreferredOrientation and
  // @ohos.display is read-only), and Android's implementation is likewise
  // unconditional — so this keeps the toggle stored/consistent (a logged no-op)
  // until a supported API lands.
  private applyDisplayRate(): void {
    console.info(`[EmulatorSpike] highRefreshRate=${this.highRefreshRate} ` +
      '(OHOS SDK: no per-window refresh-rate API; toggle stored only)')
  }

  // "加速时同步音频": mute the renderer while fast-forwarding when the toggle is
  // OFF; otherwise keep audio running.
  private applyFastForwardAudio(): void {
    try {
      const mute: boolean = this.speedMult > 1 && !this.fastForwardAudio
      setAudioMuted(mute)
    } catch (e) {
      // setAudioMuted may be absent on older host builds — ignore.
    }
  }

  private saveSettings(): void {
    try {
      const dir = this.configDir()
      if (!dir) return
      const path = dir + '/settings.json'
      const j: Settings = {
        stickMode: this.stickMode,
        padScale: this.padScale,
        stickDeadzone: this.stickDeadzone,
        useDpadUi: this.useDpadUi,
        padOffsetX: this.padOffsetX,
        padOffsetY: this.padOffsetY,
        showFpsHud: this.showFpsHud,
        highRefreshRate: this.highRefreshRate,
        fastForwardAudio: this.fastForwardAudio,
      }
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, JSON.stringify(j))
      fs.closeSync(file.fd)
    } catch (e) {
      console.warn('[EmulatorSpike] saveSettings failed: ' + JSON.stringify(e))
    }
  }

  // ---- 3-slot load dialog ----
  private openLoadDialog(): void {
    try {
      const json = listSaves()
      const arr = JSON.parse(json) as SaveSlotInfo[]
      const dir = getFilesDir()
      for (const s of arr) {
        if (s.exists && s.w > 0 && s.h > 0 && dir) {
          const path = dir + '/thumb' + s.slot + '.rgba'
          try {
            const file: fs.File = fs.openSync(path)
            const st = fs.statSync(path)
            const buf: ArrayBuffer = new ArrayBuffer(st.size)
            fs.readSync(file.fd, buf)
            fs.closeSync(file.fd)
            const opts: image.InitializationOptions = {
              pixelFormat: image.PixelMapFormat.RGBA_8888,
              size: { width: s.w, height: s.h }
            }
            image.createPixelMap(buf, opts).then((pm: image.PixelMap) => {
              s.thumb = pm
              // Trigger a refresh of the rendered list.
              this.saveList = this.saveList.slice()
            }).catch(() => {})
          } catch (e) { /* no thumbnail */ }
        }
      }
      this.saveList = arr
      this.loadDialog = true
    } catch (e) {
      this.showToast('读档列表失败')
    }
  }

  private loadSlot(slot: number): void {
    if (loadStateSlot(slot)) {
      this.showToast('已读档 槽 ' + (slot + 1))
    } else {
      this.showToast('读档失败')
    }
    this.loadDialog = false
  }

  private deleteSave(slot: number): void {
    const dir = getFilesDir()
    if (dir) {
      try { fs.unlinkSync(dir + '/state' + slot + '.sav') } catch (e) {}
      try { fs.unlinkSync(dir + '/thumb' + slot + '.rgba') } catch (e) {}
      try { fs.unlinkSync(dir + '/thumb' + slot + '.meta') } catch (e) {}
    }
    this.openLoadDialog() // refresh
  }

  private fmtTime(secs: number): string {
    const d = new Date(secs * 1000)
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n)
    return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes())
  }

  // EmulatorActivity.confirmRestart()
  private confirmRestart(): void {
    AlertDialog.show({
      title: '重新开始',
      message: '将清除自动存档并回到游戏开头。\n手动保存的存档位与游戏内电池存档不受影响。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '重新开始',
        fontColor: '#C62828',
        action: () => {
          resetEmu()
          this.panelOpen = false
        }
      }
    })
  }

  // EmulatorActivity.openCheatsDialog(): load cheats.json keyed by the loaded
  // ROM's CRC32, then open the Switch/Choice dialog (Android parity).
  private openCheatsDialog(): void {
    try {
      // Native side resolves cheats.json by the loaded ROM's CRC and returns the
      // concrete CheatInfo[] as a string — ArkTS never touches a dynamic key.
      const raw = getCheats()
      const list = JSON.parse(raw) as CheatInfo[]
      if (!list || list.length === 0) {
        this.showToast('本游戏暂无金手指')
        return
      }
      const rows: CheatRow[] = list.map((c: CheatInfo): CheatRow => {
        const hasChoice = !!(c.options && c.options.length > 0)
        const sel = c.selected ?? 0
        let code = c.code
        const labels: string[] = []
        const codes: string[] = []
        if (hasChoice) {
          for (const o of c.options!) {
            labels.push((o.label && o.label.length > 0) ? o.label! : (o.code ?? ''))
            codes.push(o.code ?? '')
          }
          const opt = c.options![sel]
          code = (opt && opt.code) ? opt.code! : ''
        }
        return {
          name: c.name,
          enabled: c.enabled,
          hasChoice: hasChoice,
          choiceLabels: labels,
          choiceCodes: codes,
          choiceSel: sel,
          code: code
        }
      })
      this.cheatRows = rows
      this.cheatsOpen = true
      this.applyCheats()
    } catch (e) {
      this.showToast('金手指读取失败')
    }
  }

  // Push the current toggle/choice state into the native cheat interface.
  private applyCheats(): void {
    const out: Array<[string, boolean]> = []
    for (const r of this.cheatRows) {
      if (r.enabled && r.code.length > 0) {
        out.push([r.code, true])
      }
    }
    setCheats(JSON.stringify(out))
  }

  @Builder
  cheatsDialogView() {
    Column() {
      Text('金手指')
        .fontSize((this.ref() * 0.05) + 'px')
        .fontColor('#222222')
        .fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Start)
        .margin({ bottom: this.ref() * 0.016 })
      if (this.cheatRows.length === 0) {
        Text('本游戏暂无金手指')
          .fontColor('#888888')
          .fontSize(14)
      }
      ForEach(this.cheatRows, (r: CheatRow, i: number) => {
        Row() {
          Column() {
            Text(r.name)
              .fontColor('#222222')
              .fontSize(15)
              .maxLines(2)
          }
          .layoutWeight(1)
          .alignSelf(ItemAlign.Center)
          if (r.hasChoice) {
            Row() {
              ForEach(r.choiceLabels, (lab: string, oi: number) => {
                Text(lab)
                  .fontSize(12)
                  .fontColor(r.choiceSel === oi ? C_TEXT_ACTIVE : C_TEXT)
                  .backgroundColor(r.choiceSel === oi ? C_FILL_ACTIVE : C_FILL)
                  .borderRadius(this.ref() * 0.02)
                  .padding({ left: (this.ref() * 0.012) + 'px', right: (this.ref() * 0.012) + 'px',
                    top: (this.ref() * 0.006) + 'px', bottom: (this.ref() * 0.006) + 'px' })
                  .margin({ right: (this.ref() * 0.008) + 'px' })
                  .onClick(() => {
                    this.cheatRows[i].choiceSel = oi
                    this.cheatRows[i].code = this.cheatRows[i].choiceCodes[oi] ?? ''
                    this.cheatRows = this.cheatRows.slice()
                    this.applyCheats()
                  })
              }, (lab: string, oi: number) => 'opt' + i + '_' + oi)
            }
            .layoutWeight(1)
          }
          Toggle({ type: ToggleType.Switch, isOn: r.enabled })
            .onChange((on: boolean) => {
              this.cheatRows[i].enabled = on
              this.cheatRows = this.cheatRows.slice()
              this.applyCheats()
            })
        }
        .width('100%')
        .padding(this.ref() * 0.01)
        .margin({ bottom: this.ref() * 0.01 })
        .backgroundColor('rgba(255,255,255,0.92)')
        .borderRadius(this.ref() * 0.02)
      }, (r: CheatRow, i: number) => 'cheat' + i)
      Button('关闭')
        .width('100%')
        .fontSize(15)
        .backgroundColor(C_FILL)
        .fontColor(C_TEXT)
        .borderRadius(this.ref() * 0.02)
        .margin({ top: this.ref() * 0.01 })
        .onClick(() => { this.cheatsOpen = false })
    }
    .width('82%')
    .constraintSize({ maxHeight: (this.ref() * 0.82) + 'px' })
    .padding(this.ref() * 0.025)
    .backgroundColor('#FFFFFF')
    .borderRadius(this.ref() * 0.03)
    .position({ x: (this.layX + this.winW / 2) + 'px', y: (this.layY + this.winH / 2) + 'px' })
    .translate({ x: '-50%', y: '-50%' })
  }

  private showToast(msg: string): void {
    this.toast = msg
    setTimeout(() => { this.toast = '' }, 1200)
  }
}

interface XComponentLoadEvent {
  value: object
}
