import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodChannel,
  MethodCall,
  MethodResult,
  StandardMethodCodec,
} from '@ohos/flutter_ohos';
import common from '@ohos.app.ability.common';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';
import bundleManager from '@ohos.bundle.bundleManager';
import statfs from '@ohos.file.statvfs';
import zlib from '@ohos.zlib';
import router from '@ohos.router';
import { setEmulatorTarget, getRomCrc } from 'libgpretro.so';

/// Return shapes mirrored from the Dart side (`ImportedRom`, `ImportedPackage`,
/// `ImportedMovesConfig`/`ImportedPadConfig`). ArkTS strict mode forbids inline
/// object types, so they are declared as named interfaces.
interface NameSize {
  name: string;
  size: number;
}

interface RomInfo {
  name: string;
  originalName: string;
  relativePath: string;
  size: number;
  crc32: number;
  /// True when the file starts with the iNES magic ("NES\x1A"). Mirrors
  /// Android's `importRom()` — Dart currently ignores it, but the field keeps
  /// the two platforms' return shapes identical.
  ines: boolean;
}

interface PkgInfo {
  path: string;
  name: string;
  size: number;
}

interface JsonInfo {
  path: string;
  name: string;
  size: number;
  ok: boolean;
}

/// One file staged into the sandbox by [GamePouchPlugin.importFile].
interface StagedFile {
  /// Absolute path of the staged copy.
  path: string;
  /// File name actually used on disk (sanitised / de-duplicated).
  name: string;
  /// File name as reported by the picker — kept for `ImportedRom.originalName`.
  originalName: string;
  size: number;
}

/// Options controlling how [GamePouchPlugin.importFile] names the staged copy.
interface ImportOpts {
  /// `a.zip` -> `a_1.zip` when it already exists (Android's `uniqueName`).
  unique?: boolean;
  /// Prefix prepended to the name (Android's `moves-<ts>-` / `pad-<ts>-`).
  prefix?: string;
  /// Append `.json` when the picked name has no (or another) extension.
  ensureJsonExt?: boolean;
  /// Overwrite an existing file with the same name instead of de-duplicating
  /// (Android's `importBios` deletes the previous copy first).
  overwrite?: boolean;
}

interface VersionInfo {
  versionCode: number;
  versionName: string;
}

/// Arguments passed by the Dart side to the storage/emulator/updater methods.
/// Only a small, well-known set of keys is used, so a flat optional interface
/// keeps ArkTS strict mode happy (no `any`/`unknown`).
interface CallArgs {
  name?: string;
  mime?: string;
  sourcePath?: string;
  suggestedName?: string;
  rom?: string;
  core?: string;
}

interface LaunchArgs {
  rom: string;
  core: string;
  platform: string;
  pad?: PadArgs;
  // Netplay session config from the Dart lobby (PlayLobbyPage). Forwarded to
  // EmulatorSpike so it can run the bootstrap + lockstep session (§16.4).
  netplay?: Record<string, Object>;
  // App-level toggles from the Flutter SettingsSheet that the native emulator
  // surface consumes (FPS HUD, high refresh rate, fast-forward audio).
  prefs?: PrefsArgs;
}

/// Virtual-pad config pushed from the Flutter SettingsSheet (AppSettings) at
/// launch, mirroring Android's `applyPersistedSettings()`. All fields optional
/// so a missing key leaves the existing settings.json value untouched.
interface PadArgs {
  stickMode?: string;
  stickDeadzone?: number;
  useDpadUi?: boolean;
  padScale?: number;
  padOffsetX?: number;
  padOffsetY?: number;
}

/// App-level toggles consumed by the native emulator surface. Mirrors the
/// `AppSettings` bools of the same name.
interface PrefsArgs {
  showFpsHud?: boolean;
  highRefreshRate?: boolean;
  fastForwardAudio?: boolean;
}

/// Shape written to `<filesDir>/settings.json` (read by EmulatorSpike.loadSettings).
interface SettingsJson {
  stickMode: string;
  padScale: number;
  stickDeadzone: number;
  useDpadUi: boolean;
  padOffsetX: number;
  padOffsetY: number;
  showFpsHud: boolean;
  highRefreshRate: boolean;
  fastForwardAudio: boolean;
}

/// ArkTS/NAPI side of [OhosPal]. Registers the four Flutter MethodChannels
/// (`gs/storage`, `gs/emulator`, `gs/updater`, `gs/netplay`) and answers each
/// method call with the OpenHarmony equivalent of the Android/Kotlin behavior.
///
/// SAF-style file picks use `@ohos.file.picker`; the picked document URI is
/// copied into the app sandbox (`filesDir`) so the pure-Dart library code can
/// read it the same way it reads Android-imported files.
export class GamePouchPlugin implements FlutterPlugin {
  private appCtx?: common.Context;
  private uiCtx?: common.UIAbilityContext;
  private channels: MethodChannel[] = [];
  private netplayCh?: MethodChannel;
  // Singleton handle so EmulatorSpike can fire the reverse netplay callback.
  private static instance?: GamePouchPlugin;

  constructor(uiCtx?: common.UIAbilityContext) {
    this.uiCtx = uiCtx;
  }

  getUniqueClassName(): string {
    return 'GamePouchPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.appCtx = binding.getApplicationContext();
    this.register(binding, 'gs/storage');
    this.register(binding, 'gs/emulator');
    this.register(binding, 'gs/updater');
    this.register(binding, 'gs/netplay');
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    for (const ch of this.channels) {
      ch.setMethodCallHandler(null);
    }
    this.channels = [];
  }

  private register(binding: FlutterPluginBinding, name: string): void {
    const ch = new MethodChannel(binding.getBinaryMessenger(), name, StandardMethodCodec.INSTANCE);
    const self = this;
    ch.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        self.dispatch(name, call, result);
      },
    });
    this.channels.push(ch);
    if (name === 'gs/netplay') {
      // Keep a handle so we can invoke the reverse (native -> Dart) callback
      // `playEnded` used by netplay teardown.
      this.netplayCh = ch;
    }
    GamePouchPlugin.instance = this;
  }

  private filesDir(): string {
    return this.appCtx?.filesDir ?? '';
  }

  private dispatch(channel: string, call: MethodCall, result: MethodResult): void {
    const method: string = call.method;
    if (channel === 'gs/emulator') {
      // The emulator channel receives a single JSON-string argument (a Map
      // argument is not decoded by the OHOS MethodChannel).
      this.onEmulator(method, call.args as string, result);
      return;
    }
    const args: CallArgs = call.argument as CallArgs;
    if (channel === 'gs/storage') {
      this.onStorage(method, args, result);
    } else if (channel === 'gs/updater') {
      this.onUpdater(method, args, result);
    } else {
      // gs/netplay: native -> Dart `playEnded` callback is dormant until a real
      // OHOS emulator exists; nothing native invokes it yet.
      result.notImplemented();
    }
  }

  // --------------------------------------------------------------------------
  // gs/storage
  // --------------------------------------------------------------------------
  private async onStorage(method: string, args: CallArgs, result: MethodResult): Promise<void> {
    switch (method) {
      case 'getFilesDir':
        result.success(this.filesDir());
        return;
      case 'getDeviceModel': {
        // Mirrors Android's `"$MANUFACTURER $MODEL"` so 「发现伙伴」 renders a
        // human-friendly default name (e.g. "HUAWEI Pura70") instead of a bare
        // model code; falls back to "OpenHarmony" like Android's "Android".
        try {
          const model: string = deviceInfo.productModel ?? '';
          const maker: string = deviceInfo.manufacture ?? '';
          const parts: string[] = [];
          if (maker.trim().length > 0) parts.push(maker.trim());
          if (model.trim().length > 0) parts.push(model.trim());
          const joined: string = parts.join(' ').trim();
          result.success(joined.length > 0 ? joined : 'OpenHarmony');
        } catch (e) {
          result.success('OpenHarmony');
        }
        return;
      }
      case 'getAvailableBytes':
        try {
          const free = await statfs.getFreeSize(this.filesDir());
          result.success(Number(free));
        } catch (e) {
          result.success(0);
        }
        return;
      // NOTE: the Dart side calls this `getRunningSaveKey` (see
      // AndroidPal/OhosPal.runningSaveKey) — the case label must match exactly
      // or the call silently drops into `notImplemented()`.
      case 'getRunningSaveKey': {
        // Report the CRC of the ROM currently loaded by the in-process native
        // emulator (gpretro.getRomCrc returns an 8-hex-char string), so peer
        // import can lock saves for the running game — mirroring Android's
        // getRunningSaveKey. Returns null when no core is loaded ("00000000").
        try {
          const crc = getRomCrc() as string;
          const empty = !crc || crc === '00000000' || crc.toUpperCase() === '00000000';
          result.success(empty ? null : crc);
        } catch (e) {
          result.success(null);
        }
        return;
      }
      case 'acquireMulticastLock':
      case 'releaseMulticastLock':
        // OHOS exposes no public Wi-Fi multicast-lock API. The `INTERNET`
        // permission already permits broadcast/multicast sockets (the peer
        // discovery protocol uses 255.255.255.255 broadcast, not multicast
        // groups), so there is nothing to acquire/release. Report success so the
        // Dart discovery flow proceeds instead of bailing on a false failure.
        result.success(true);
        return;
      case 'deleteBios': {
        const name: string = args?.name ?? '';
        result.success(this.deleteBios(name));
        return;
      }
      case 'importRomViaSaf': {
        const mime: string = args?.mime ?? '*/*';
        this.importFile<RomInfo>('roms', mime, { unique: true },
          (f: StagedFile): RomInfo => {
            const crc = crc32File(f.path);
            return {
              name: f.name,
              originalName: f.originalName,
              relativePath: `roms/${f.name}`,
              size: f.size,
              crc32: crc,
              ines: sniffInes(f.path),
            };
          })
          .then((m: RomInfo | null) => result.success(m))
          .catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      }
      case 'importPackageViaSaf':
        this.importFile<PkgInfo>('import_cache', '*/*', { unique: true },
          (f: StagedFile): PkgInfo => {
            return { path: `import_cache/${f.name}`, name: f.name, size: f.size };
          })
          .then((m: PkgInfo | null) => result.success(m))
          .catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      case 'importBiosViaSaf':
        this.importFile<string>('system', '*/*', { overwrite: true },
          (f: StagedFile): string => f.name)
          .then((m: string | null) => result.success(m))
          .catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      case 'importBiosBatchViaSaf':
        this.importFiles('system').then((m: string[] | null) => result.success(m)).catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      // Android names the staged copy `moves-<ts>-<name>.json` and only marks
      // `ok` when the JSON has a `profiles` object; the pad variant accepts any
      // JSON object. Mirror both so the Dart editors see identical results.
      case 'importMovesConfigViaSaf':
        this.importJson('library/imports', 'moves', 'profiles')
          .then((m: JsonInfo | null) => result.success(m))
          .catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      case 'importPadConfigViaSaf':
        this.importJson('library/imports', 'pad', '')
          .then((m: JsonInfo | null) => result.success(m))
          .catch((e: Error) => result.error('IMPORT_FAILED', e.message, ''));
        return;
      case 'exportBiosZipViaSaf':
        this.exportBiosZip().then((ok: boolean) => result.success(ok)).catch((e: Error) => result.error('EXPORT_FAILED', e.message, ''));
        return;
      case 'exportPackageViaSaf':
      case 'exportMovesConfigViaSaf':
      case 'exportPadConfigViaSaf': {
        const sourcePath: string = args?.sourcePath ?? '';
        const suggestedName: string = args?.suggestedName ?? 'gamepouch_export';
        // Pre-fill the picker's file name (Android passes EXTRA_TITLE) so the
        // user gets `moves-kof97.json` instead of an untitled document.
        this.exportFile(sourcePath, suggestedName).then((ok: boolean) => result.success(ok)).catch((e: Error) => result.error('EXPORT_FAILED', e.message, ''));
        return;
      }
      default:
        result.notImplemented();
    }
  }

  // --------------------------------------------------------------------------
  // gs/emulator
  // --------------------------------------------------------------------------
  // Resolve the libretro core id from a ROM file extension (mirrors the
  // Android platform->core map). Used when Dart does not pass an explicit core.
  private coreForRom(rom: string): string {
    const n = rom.toLowerCase()
    if (n.endsWith('.nes') || n.endsWith('.unf') || n.endsWith('.unif') || n.endsWith('.fds')) return 'fceumm'
    if (n.endsWith('.gb') || n.endsWith('.gbc')) return 'gambatte'
    if (n.endsWith('.gba')) return 'mgba'
    if (n.endsWith('.md') || n.endsWith('.gen') || n.endsWith('.sms') || n.endsWith('.gg')) return 'picodrive'
    if (n.endsWith('.a26')) return 'stella2014'
    // Arcade (CPS1/CPS2/NeoGeo) ROMs ship as zips -> the store-flavour MAME
    // core (libgs_mame.so). Mirrors Dart's PlatformKind.mame/neogeo -> 'mame'.
    if (n.endsWith('.zip') || n.endsWith('.7z')) return 'mame'
    return 'fceumm'
  }

  // Parse the launch argument. Dart sends a single JSON string
  // ({"rom":..,"core":..,"platform":..}); a bare string is treated as a rom path.
  private parseLaunch(argJson: string): LaunchArgs {
    const out: LaunchArgs = { rom: '', core: '', platform: '', pad: undefined }
    if (!argJson) {
      return out
    }
    try {
      const p = JSON.parse(argJson) as LaunchArgs
      if (p) {
        out.rom = (typeof p.rom === 'string') ? p.rom : ''
        out.core = (typeof p.core === 'string') ? p.core : ''
        out.platform = (typeof p.platform === 'string') ? p.platform : ''
        if (typeof p.pad === 'object' && p.pad !== null) {
          out.pad = p.pad as PadArgs
        }
        if (typeof p.netplay === 'object' && p.netplay !== null) {
          out.netplay = p.netplay as Record<string, Object>
        }
        if (typeof p.prefs === 'object' && p.prefs !== null) {
          out.prefs = p.prefs as PrefsArgs
        }
      }
    } catch (e) {
      // Not JSON — treat the raw string as a relative rom path.
      out.rom = argJson
    }
    return out
  }

  private onEmulator(method: string, argJson: string, result: MethodResult): void {
    if (method === 'launch') {
      // M1: open the native emulator surface page with the chosen ROM. The ROM
      // path may be relative to the app files dir (e.g. "roms/yx.nes"); resolve
      // it against filesDir so the native dlopen host receives an absolute path.
      const la = this.parseLaunch(argJson)
      const romRel: string = la.rom || 'roms/' + decodeURIComponent('%E5%8F%A3%E8%A2%8B%E5%A6%96%E6%80%AA%E5%8F%B6%E7%BB%BF.gba');
      const core: string = la.core || this.coreForRom(romRel);
      const platform: string = la.platform
      console.info(`[GamePouchPlugin] onEmulator romRel=${romRel} core=${core} platform=${platform}`);
      let romAbs = romRel;
      if (romRel.length > 0 && !romRel.startsWith('/')) {
        romAbs = `${this.filesDir()}/${romRel}`;
      }
      console.info(`[GamePouchPlugin] onEmulator.launch rom=${romAbs} core=${core}`);
      try {
        // Mirror Android's applyPersistedSettings(): stamp the Flutter
        // SettingsSheet pad config into settings.json BEFORE the emulator surface
        // is created, so EmulatorSpike.loadSettings() picks it up on appear.
        if (la.pad) {
          this.writePadSettings(la.pad, la.prefs);
        }
        // Tell the native host the target ROM up-front (before the surface is
        // created) so OnSurfaceCreated can dlopen the core and start emulation.
        setEmulatorTarget(romAbs, core, la.netplay !== undefined);
        // [platform] is what drives the control panel (NEOGEO 4-button vs MAME
        // 6-button); it must ride along because several platforms share the
        // 'mame' core id, exactly like Android's intent extra.
        // Netplay: forward the lobby-provided session config (if any) so the
        // emulator surface can run the bootstrap + lockstep session (§16.4).
        const params: Record<string, Object> = {}
        params['rom'] = romAbs
        params['core'] = core
        params['platform'] = platform
        // The NAPI `getFilesDir()` the emulator page uses is NOT the same as
        // this plugin's `appCtx.filesDir` on real devices, which made
        // EmulatorSpike.loadSettings()/loadMoves() read (and saveSettings()
        // write) a settings.json / library/moves.json nobody else touches —
        // i.e. the Settings sheet had no effect on the running emulator. Hand
        // the authoritative config dir over explicitly.
        params['filesDir'] = this.filesDir()
        if (la.netplay) {
          params['netplay'] = la.netplay
          console.info(`[GamePouchPlugin] onEmulator.launch netplay role=${(la.netplay['role'] as number) ?? -1}`);
        }
        router.pushUrl({ url: 'pages/EmulatorSpike', params: params });
        console.info('[GamePouchPlugin] router.pushUrl(EmulatorSpike) ok');
        result.success(true);
      } catch (e) {
        console.error('[GamePouchPlugin] router.pushUrl failed: ' + (e as ESObject)?.message);
        result.success(false);
      }
      return;
    }
    if (method === 'stop') {
      // Netplay teardown / emulator exit: notify Dart via the reverse channel so
      // the active PlaySession ends. No-op when no netplay session is active (no
      // listener is registered on the Dart side in that case).
      this.emitPlayEnded(0, true);
      result.success(true);
      return;
    }
    result.notImplemented();
  }

  /// Native -> Dart reverse callback for netplay session end (mirrors Android's
  /// `gs/netplay playEnded`). Consumed by [OhosPal._playEnds] on the Dart side.
  private emitPlayEnded(roomId32: number, clean: boolean): void {
    try {
      // Android sends {"roomId": <int32>, "clean": bool} and
      // NetplayPlayEnd.fromMap reads m['roomId'] — sending 'roomId32' made the
      // cast throw, the event was dropped and the local PlaySession was never
      // released, so the *next* invite failed with "已有一个联机邀请或对局在进行".
      // Keep roomId32 as well so any older Dart build still parses.
      this.netplayCh?.invokeMethod('playEnded', { 'roomId': roomId32, 'roomId32': roomId32, 'clean': clean });
    } catch (e) {
      console.warn('[GamePouchPlugin] emitPlayEnded failed: ' + (e as ESObject)?.message);
    }
  }

  /// Static entry point used by the emulator (EmulatorSpike) to fire the reverse
  /// (native -> Dart) netplay `playEnded` callback when a session drops/ends.
  public static emitNetplayPlayEnded(roomId32: number, clean: boolean): void {
    GamePouchPlugin.instance?.emitPlayEnded(roomId32, clean);
  }

  // --------------------------------------------------------------------------
  // gs/updater
  // --------------------------------------------------------------------------
  private onUpdater(method: string, args: CallArgs, result: MethodResult): void {
    if (method === 'getVersion') {
      try {
        const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        const v: VersionInfo = { versionCode: info.versionCode, versionName: info.versionName };
        result.success(v);
      } catch (e) {
        const v: VersionInfo = { versionCode: 0, versionName: '' };
        result.success(v);
      }
      return;
    }
    if (method === 'installApk') {
      // OHOS installs .hap, not .apk. No-op (returns false).
      result.success(false);
      return;
    }
    if (method === 'openStore') {
      // Best-effort: no equivalent store intent on OHOS.
      result.success(null);
      return;
    }
    result.notImplemented();
  }

  // --------------------------------------------------------------------------
  // SAF helpers
  // --------------------------------------------------------------------------

  /// Mirrors Android's `applyPersistedSettings()`: stamps the Flutter
  /// SettingsSheet pad config into `<filesDir>/settings.json` so the OHOS native
  /// pad (EmulatorSpike.loadSettings) honours it. The Flutter side always sends
  /// all six fields, so we overwrite unconditionally (the in-emulator
  /// stickMode/padScale cycle also writes the same six fields via saveSettings).
  private writePadSettings(pad: PadArgs, prefs?: PrefsArgs): void {
    try {
      const path = `${this.filesDir()}/settings.json`;
      const obj: SettingsJson = {
        stickMode: (typeof pad.stickMode === 'string') ? pad.stickMode : 'DPAD8',
        padScale: (typeof pad.padScale === 'number') ? pad.padScale : 1.0,
        stickDeadzone: (typeof pad.stickDeadzone === 'number') ? pad.stickDeadzone : 0.18,
        useDpadUi: (typeof pad.useDpadUi === 'boolean') ? pad.useDpadUi : false,
        padOffsetX: (typeof pad.padOffsetX === 'number') ? pad.padOffsetX : 0.0,
        padOffsetY: (typeof pad.padOffsetY === 'number') ? pad.padOffsetY : 0.0,
        showFpsHud: (prefs && typeof prefs.showFpsHud === 'boolean') ? prefs.showFpsHud : true,
        highRefreshRate: (prefs && typeof prefs.highRefreshRate === 'boolean') ? prefs.highRefreshRate : true,
        fastForwardAudio: (prefs && typeof prefs.fastForwardAudio === 'boolean') ? prefs.fastForwardAudio : true,
      };
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(obj));
      fs.closeSync(file.fd);
    } catch (e) {
      console.warn('[GamePouchPlugin] writePadSettings failed: ' + (e as Error)?.message);
    }
  }

  /// `yyyyMMdd_HHmmss` stamp used for exported documents (mirrors Android's
  /// `SimpleDateFormat("yyyyMMdd_HHmmss")`).
  private stamp(): string {
    const d = new Date();
    const p = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
      `_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  }

  private ensureDir(rel: string): string {
    const dir = `${this.filesDir()}/${rel}`;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // already exists
    }
    return dir;
  }

  private copyUriTo(uri: string, destPath: string): NameSize {
    const st = fs.statSync(uri);
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, destPath);
    } finally {
      fs.closeSync(src);
    }
    const ns: NameSize = { name: fileNameFromUri(uri), size: Number(st.size) };
    return ns;
  }

  /// Mirrors Android's `sanitize()`: strips characters that are illegal in a
  /// sandbox file name so a picker-provided display name can never escape the
  /// target directory (or smuggle a path separator into a Chinese ROM name).
  private safeName(raw: string): string {
    const cleaned: string = raw.replace(/[\\/:*?"<>|]+/g, '_').trim();
    return cleaned.length > 0 ? cleaned : 'rom';
  }

  /// Mirrors Android's `uniqueName()`: `a.zip` -> `a_1.zip` when `a.zip`
  /// already exists, so re-importing a ROM never silently clobbers the copy
  /// already in the library (whose saves are keyed by that file's CRC).
  private uniqueName(dir: string, name: string): string {
    if (!fs.accessSync(`${dir}/${name}`)) {
      return name;
    }
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';
    let i = 1;
    while (fs.accessSync(`${dir}/${base}_${i}${ext}`)) {
      i++;
    }
    return `${base}_${i}${ext}`;
  }

  private applyNameOpts(dir: string, raw: string, opts: ImportOpts): string {
    let n: string = this.safeName(raw);
    if (opts.prefix !== undefined && opts.prefix.length > 0) {
      n = `${opts.prefix}-${Date.now()}-${n}`;
    }
    if (opts.ensureJsonExt === true && !n.toLowerCase().endsWith('.json')) {
      n = `${n}.json`;
    }
    if (opts.unique === true) {
      n = this.uniqueName(dir, n);
    }
    return n;
  }

  private async importFile<T>(relDir: string, mime: string, opts: ImportOpts, build: (f: StagedFile) => T): Promise<T | null> {
    const ctx = this.uiCtx;
    if (!ctx) {
      return null;
    }
    const dp = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await dp.select({ maxSelectNumber: 1 });
    if (!uris || uris.length === 0) {
      return null;
    }
    const uri = uris[0];
    const dir = this.ensureDir(relDir);
    const tmp = this.copyUriTo(uri, `${dir}/_tmp_import`);
    const finalName: string = this.applyNameOpts(dir, tmp.name, opts);
    const destPath = `${dir}/${finalName}`;
    if (opts.overwrite === true && fs.accessSync(destPath)) {
      fs.unlinkSync(destPath);
    }
    fs.renameSync(`${dir}/_tmp_import`, destPath);
    return build({ path: destPath, name: finalName, originalName: tmp.name, size: tmp.size });
  }

  private async importFiles(relDir: string): Promise<string[] | null> {
    const ctx = this.uiCtx;
    if (!ctx) {
      return null;
    }
    const dp = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await dp.select({ maxSelectNumber: 100 });
    if (!uris || uris.length === 0) {
      return null;
    }
    const dir = this.ensureDir(relDir);
    const names: string[] = [];
    let idx = 0;
    for (const uri of uris) {
      const tmp = this.copyUriTo(uri, `${dir}/_tmp_${idx}`);
      // Android's importBios() replaces an existing copy with the same name
      // (BIOS blobs are matched by exact name, so de-duplicating `_1` variants
      // would make the core fail to find them).
      const destPath = `${dir}/${this.safeName(tmp.name)}`;
      if (fs.accessSync(destPath)) {
        fs.unlinkSync(destPath);
      }
      fs.renameSync(`${dir}/_tmp_${idx}`, destPath);
      names.push(this.safeName(tmp.name));
      idx++;
    }
    return names;
  }

  /// Mirrors Android's `importMovesConfig` / `importPadConfig`: stages the
  /// picked JSON under `library/imports/` as `<prefix>-<ts>-<name>.json` and
  /// pre-validates it. [requireKey] is the top-level key the payload must have
  /// (`profiles` for moves, empty for the pad layout which accepts any object).
  private async importJson(relDir: string, prefix: string, requireKey: string): Promise<JsonInfo | null> {
    const ctx = this.uiCtx;
    if (!ctx) {
      return null;
    }
    const dp = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await dp.select({ maxSelectNumber: 1 });
    if (!uris || uris.length === 0) {
      return null;
    }
    const uri = uris[0];
    const dir = this.ensureDir(relDir);
    const tmp = this.copyUriTo(uri, `${dir}/_tmp_json`);
    const finalName: string = this.applyNameOpts(dir, tmp.name,
      { prefix: prefix, ensureJsonExt: true });
    const destPath = `${dir}/${finalName}`;
    fs.renameSync(`${dir}/_tmp_json`, destPath);
    let ok = false;
    try {
      const parsed: ESObject = JSON.parse(fs.readTextSync(destPath)) as ESObject;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        ok = requireKey.length === 0 || parsed[requireKey] !== undefined;
      }
    } catch (e) {
      ok = false;
    }
    return { path: destPath, name: finalName, size: tmp.size, ok: ok };
  }

  private async exportFile(sourcePath: string, suggestedName?: string): Promise<boolean> {
    const ctx = this.uiCtx;
    if (!ctx || !sourcePath || !fs.accessSync(sourcePath)) {
      return false;
    }
    const dp = new picker.DocumentViewPicker(ctx);
    const saveOpts: ESObject = {};
    if (suggestedName !== undefined && suggestedName.length > 0) {
      saveOpts['newFileNames'] = [suggestedName];
    }
    const uris: Array<string> = await dp.save(saveOpts);
    if (!uris || uris.length === 0) {
      return false;
    }
    const destUri = uris[0];
    const src = fs.openSync(sourcePath, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, destUri);
    } finally {
      fs.closeSync(src);
    }
    return true;
  }

  private deleteBios(name: string): boolean {
    if (!name) {
      return false;
    }
    const base = `${this.filesDir()}/system`;
    let removed = false;
    const target = `${base}/${name}`;
    if (fs.accessSync(target)) {
      fs.unlinkSync(target);
      removed = true;
    }
    // Also remove any per-core mirror (LockedRom step on Android).
    try {
      const subdirs = fs.listFileSync(base);
      for (const sd of subdirs) {
        const mirrored = `${base}/${sd}/${name}`;
        if (fs.accessSync(mirrored)) {
          fs.unlinkSync(mirrored);
          removed = true;
        }
      }
    } catch (e) {
      // ignore
    }
    return removed;
  }

  /// Zips `<filesDir>/system/` into a single archive via SAF so the user can
  /// back up their BIOS set. Mirrors Android `exportBiosZipViaSaf`.
  private async exportBiosZip(): Promise<boolean> {
    const ctx = this.uiCtx;
    if (!ctx) {
      return false;
    }
    const systemDir = `${this.filesDir()}/system`;
    if (!fs.accessSync(systemDir)) {
      return false;
    }
    const cacheDir = this.ensureDir('import_cache');
    const tmpZip = `${cacheDir}/bios_backup.zip`;
    try {
      if (fs.accessSync(tmpZip)) {
        fs.unlinkSync(tmpZip);
      }
    } catch (e) {
      // ignore
    }
    try {
      await zlib.zipFile(systemDir, tmpZip, {});
    } catch (e) {
      return false;
    }
    const dp = new picker.DocumentViewPicker(ctx);
    // Android pre-fills `gamepouch-bios-<stamp>.zip` via EXTRA_TITLE; do the
    // same so the exported backup doesn't land as an unnamed document.
    const stamp: string = this.stamp();
    const uris: Array<string> = await dp.save({ newFileNames: [`gamepouch-bios-${stamp}.zip`] });
    if (!uris || uris.length === 0) {
      return false;
    }
    const destUri = uris[0];
    const src = fs.openSync(tmpZip, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, destUri);
    } finally {
      fs.closeSync(src);
    }
    try {
      fs.unlinkSync(tmpZip);
    } catch (e) {
      // best-effort cleanup
    }
    return true;
  }
}

// --------------------------------------------------------------------------
// CRC32 (IEEE 802.3) — used by importRomViaSaf to mirror Android/Kotlin value.
// --------------------------------------------------------------------------

/// The `@ohos.file.fileuri` helper is not exported in this SDK version, so we
/// derive the display name from the picked document URI's last path segment.
function fileNameFromUri(uri: string): string {
  let name = uri;
  const slash = uri.lastIndexOf('/');
  if (slash >= 0) {
    name = uri.substring(slash + 1);
  }
  const q = name.indexOf('?');
  if (q >= 0) {
    name = name.substring(0, q);
  }
  const h = name.indexOf('#');
  if (h >= 0) {
    name = name.substring(0, h);
  }
  // SAF document URIs percent-encode non-ASCII file names (e.g. a Chinese ROM
  // comes back as `%E6%8B%B3%E7%9A%87%2097.zip`). Decode so the library shows
  // 拳皇 97.zip instead of the percent-encoded mojibake. A raw UTF-8 segment
  // (no '%') passes through unchanged; an invalid escape keeps the raw string.
  try {
    const decoded = decodeURIComponent(name);
    if (decoded.length > 0) {
      name = decoded;
    }
  } catch (_) {
    // keep raw name if it is not valid percent-encoding
  }
  return name;
}

/// True when [path] starts with the iNES magic (`NES\x1A`). Mirrors the
/// `ines` field Android's `importRom()` reports (that sniff reads "NNN\x1A",
/// which never matches — this uses the real magic). Informational only: Dart's
/// [ImportedRom] ignores it, but the two return shapes stay identical.
function sniffInes(path: string): boolean {
  try {
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(4);
    const n = fs.readSync(f.fd, buf);
    fs.closeSync(f);
    if (n < 4) return false;
    const b = new Uint8Array(buf);
    return b[0] === 0x4E && b[1] === 0x45 && b[2] === 0x53 && b[3] === 0x1A;
  } catch (e) {
    return false;
  }
}

function buildCrcTable(): number[] {
  const table: number[] = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  return table;
}

const CRC_TABLE: number[] = buildCrcTable();

function crc32File(path: string): number {
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  let crc = 0xFFFFFFFF;
  const chunk = new ArrayBuffer(1024 * 1024);
  try {
    while (true) {
      const n = fs.readSync(f.fd, chunk);
      if (n <= 0) {
        break;
      }
      const view = new Uint8Array(chunk, 0, n);
      for (let i = 0; i < n; i++) {
        crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ view[i]) & 0xFF];
      }
    }
  } finally {
    fs.closeSync(f);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
