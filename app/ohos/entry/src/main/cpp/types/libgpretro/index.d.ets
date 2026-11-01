// NAPI module declaration for the native emulator host (libgpretro.so).
// Must use `export const` (named export) — ArkTS forbids ambient `declare module`
// and object-literal-as-type in .d.ets. Mirrors the OHOS external_textures
// sample (`export const renderFrame: (...) => void;`).
export const startEmulator: (xcomponent: object) => void;
// Stops the emulation and releases EGL/audio. Call from the page teardown / exit
// button BEFORE the XComponent surface is destroyed to avoid a process crash.
export const stopEmulator: () => void;
// [coldBoot] = Android's nativeInit(netplayColdBoot = npCfg != null): arms
// GP_NETPLAY_COLD_BOOT so MAME seeds NVRAM from the deterministic default
// instead of this phone's nvram file (a lockstep pair cold-boots separately).
export const setEmulatorTarget: (rom: string, core: string, coldBoot?: boolean) => void;
export const setInput: (mask: number) => void;
// Selects the pad port driven by the virtual pad: 0 = 1P, 1 = 2P (arcade only).
export const setPlayerPort: (port: number) => void;
export const resetEmu: () => void;
export const setSpeed: (mult: number) => void;
// Mute/unmute audio (drives the "加速时同步音频" setting).
export const setAudioMuted: (muted: boolean) => void;
export const saveState: () => boolean;
export const loadState: () => boolean;
/// "" while the current target booted fine; otherwise a JSON blob explaining
/// the failure: {"reason":"load_game","missing":["nffe.03"],"detail":"..."}.
/// `reason` is one of rom_missing / dlopen / load_game.
export const getLoadError: () => string;
export const getFps: () => number;
export const getFilesDir: () => string;
// Absolute path of the saves directory (== app files dir / saves); mirrors
// Android's filesDir/saves/. Used to locate per-game CRC-keyed save-state slots.
export const getSavesDir: () => string;
export const saveStateSlot: (slot: number) => boolean;
export const loadStateSlot: (slot: number) => boolean;
export const listSaves: () => string;
// CRC32 (8-hex uppercase) of the loaded ROM — the cheats.json key.
export const getRomCrc: () => string;
// Cheats for the loaded ROM (cheats.json byCrc[crc]) as a JSON array string ("[]" if none).
export const getCheats: () => string;
// Apply cheats: JSON array of [code, enabled] pairs. Returns bool (false if the
// core has no cheat interface).
export const setCheats: (cheatsJson: string) => boolean;

// ---- netplay (§16.4 delay-based lockstep) ----
// Attach a lockstep session. cfgJson = {"role":0|1,"peerIp":str,"peerPort":int,
// "localPort":int,"sessionKeyHex":64hex,"roomId":u32,"initialD":1|2,
// "adaptive":bool,"framePeriodSec":double,"frame0":int}. Returns bool.
export const netplayStart: (cfgJson: string) => boolean;
// Sends CTRL_BYE and tears the session down (idempotent).
export const netplayStop: () => void;
// Feeds the live local pad mask (published each frame by the pace loop).
export const netplayLocalMask: (mask: number) => void;
// Host opens the START gate (announces CTRL_START).
export const netplayNotifyStart: () => void;
// Local pause intent -> CTRL_PAUSE / RESUME.
export const netplayNotifyPaused: (paused: boolean) => void;
// Returns a 28-element double[] mirroring Android NativeBridge.NetplayStats.
export const netplayStats: () => number[];
// FNV-1a64 hex of the serialized core state (determinism check), or null.
export const netplayStateHash: () => string | null;
// Flushes battery RAM to <appDir>/saves/<saveKey>.sav (atomic). Returns bool.
export const netplayFlushSram: () => boolean;
// Host frame-0 serialized state (ArrayBuffer) for the bootstrap server, or null.
export const netplayGetState0: () => ArrayBuffer | null;
// Guest: unserializes the host's starting core state. Returns bool.
export const netplayLoadState0: (state0: ArrayBuffer) => boolean;
// Guest: injects the host-provided battery RAM into the core. Returns bool.
export const netplayLoadSram: (sram: ArrayBuffer) => boolean;
// True once the core has finished loading (mirrors Android's npCoreReady gate).
// The netplay bootstrap must wait for this before attaching a session.
export const isCoreReady: () => boolean;
// Parks emulation (rendering continues, retro_run() does not) for the duration
// of the netplay bootstrap, so no frame leaks in between netplayLoadState0()
// and netplayStart() — Android performs that whole sequence inside one
// runOnGlBlocking block. Unfreeze on teardown so solo play resumes.
export const netplayFreeze: (frozen: boolean) => void;
