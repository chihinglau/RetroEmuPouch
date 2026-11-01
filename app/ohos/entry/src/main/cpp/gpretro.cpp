// M1: libretro host for OHOS (fceumm / NES).
//
// Dart `gs/emulator.launch` -> ArkTS GamePouchPlugin -> router.pushUrl
// (pages/EmulatorSpike, params: rom/core) -> XComponent -> (this NAPI module)
// dlopen(libfceumm.so) -> retro_init/load_game/run -> EGL texture + OHAudio.

#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <ohaudio/native_audio_stream_manager.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audio_common.h>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>

#include <dlfcn.h>
#include <libretro.h>
#include "gs_netplay.h"  // np::GsNetplay lockstep transport (§16.4)

#include <thread>
#include <chrono>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <cctype>
#include <string>
#include <time.h>   // clock_nanosleep / timespec for the netplay frame gate
#include <vector>
#include <deque>
#include <mutex>
#include <unistd.h>   // link() — cheap hard-link staging of sibling arcade sets
#include <filesystem>
#include <system_error>
#include <sys/stat.h>
#include <dirent.h>
#include <hilog/log.h>
#include <cstdlib>   // setenv / unsetenv for the per-entry netplay dump

// Verification logging: explicit domain+tag so the line is never filtered.
#define GPRETRO_DOMAIN 0xD001234
#define GPRETRO_TAG "GPRETRO"
#define GPRETRO_INFO(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, GPRETRO_DOMAIN, GPRETRO_TAG, fmt, ##__VA_ARGS__)
#define GPRETRO_WARN(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_WARN, GPRETRO_DOMAIN, GPRETRO_TAG, fmt, ##__VA_ARGS__)
#define GPRETRO_ERROR(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_ERROR, GPRETRO_DOMAIN, GPRETRO_TAG, fmt, ##__VA_ARGS__)

// Forward declaration (defined later, near NativeNetplayStateHash).
static void OhosNetCheckpoint();

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
static OH_NativeXComponent* g_component = nullptr;
static EGLDisplay g_eglDisplay = EGL_NO_DISPLAY;
static EGLSurface g_eglSurface = EGL_NO_SURFACE;
static EGLContext g_eglContext = EGL_NO_CONTEXT;
static int g_winW = 0;
static int g_winH = 0;
static std::atomic<bool> g_running{false};
static std::thread g_renderThread;
// Netplay cold boot (set by SetEmulatorTarget's `coldBoot` arg == Android's
// nativeInit(netplayColdBoot)): besides the core-side NVRAM guard, the core
// must also be pointed at a pristine save dir (see g_npSaveDir) so it cannot
// restore this phone's per-device MAME cfg / coin counters.
static bool g_netColdBoot = false;
static std::string g_npSaveDir;
// One-shot per session: the prime frame (see netplayFreeze) is the OHOS-side
// counterpart of Android's single pre-attach retro_run(). Required for MAME
// cold boot, where the guest does NOT receive the host's frame-0 state.
static bool g_netPrimeDone = false;
// Netplay attach gate (mirrors Android's runOnGlBlocking). Android performs
// loadState0 + nativeNetplayStart + nativeStartPacing inside ONE GL-thread
// block, so no retro_run() can slip in between them and the pair both start
// lockstep from frame 0. Here the bootstrap runs on the ArkTS thread while the
// render thread keeps emulating, so frames leak in during /sram + /state0 +
// netplayStart. For a cold-boot core (MAME, no state0 transfer) those frames
// are never undone and the two machines are desynced from frame 0. While this
// flag is set the loop renders but does NOT call retro_run().
static std::atomic<bool> g_emuFrozen{false};

// Target chosen by the ArkTS page (router params -> setEmulatorTarget).
static std::string g_romPath;
// Directory of the ROM (== app files dir / roms) where save states + thumbnails
// are persisted so they survive process restart (3 slots, like Android).
static std::string g_filesDir;
// App-private files dir (== parent of the ROM directory). Every core-visible
// directory is derived from it.
static std::string g_appDir;

// ---- core-load diagnostics ------------------------------------------------
// MAME reports arcade failures ("<file> NOT FOUND (tried in <set>)", "Required
// files are missing, the machine cannot be run") through the libretro log
// callback. Without this the page could only show the blue fallback screen, so
// "the game won't start" was indistinguishable from a crash. We keep a short
// tail of the core's own log and, when retro_load_game() fails, publish a JSON
// error blob (`getLoadError`) that the ArkTS page renders as an explanation.
static std::mutex g_errMutex;
static std::string g_loadError;                  // JSON, empty == no error
static std::string SoloSaveCrc();  // per-game save/cheat key = rom_index.json crc32 (mirrors Android CheatStore.crcKey)
static std::deque<std::string> g_coreLogTail;    // last kCoreLogTailMax lines
static const size_t kCoreLogTailMax = 24;
// MAME/arcade system (BIOS), content (ROM lookup) and save directories, derived
// from the ROM's parent dir. Mirrors Android's systemDir_/contentDir_/saveDir_.
static std::string g_systemDir;
static std::string g_contentDir;
static std::string g_saveDir;
static std::string g_coreName = "fceumm";
// Forced NES region for fceumm ("Dendy"/"PAL"), else empty = Auto.
static std::string g_forcedRegion;

// ---------------------------------------------------------------------------
// Libretro core handle
// ---------------------------------------------------------------------------
static void* g_coreLib = nullptr;
static struct {
  void (*retro_set_environment)(retro_environment_t);
  void (*retro_set_video_refresh)(retro_video_refresh_t);
  void (*retro_set_audio_sample)(retro_audio_sample_t);
  void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*retro_set_input_poll)(retro_input_poll_t);
  void (*retro_set_input_state)(retro_input_state_t);
  void (*retro_init)(void);
  void (*retro_deinit)(void);
  unsigned (*retro_api_version)(void);
  void (*retro_get_system_info)(struct retro_system_info*);
  void (*retro_get_system_av_info)(struct retro_system_av_info*);
  void (*retro_set_controller_port_device)(unsigned, unsigned);
  void (*retro_reset)(void);
  void (*retro_run)(void);
  bool (*retro_load_game)(const struct retro_game_info*);
  bool (*retro_unload_game)(void);
  size_t (*retro_serialize_size)(void);
  bool (*retro_serialize)(const void* data, size_t size);
  bool (*retro_unserialize)(const void* data, size_t size);
  void* (*retro_get_memory_data)(unsigned id);
  size_t (*retro_get_memory_size)(unsigned id);
  void (*retro_cheat_reset)(void);
  // Standard libretro cheat API is `retro_cheat_set` (plural). Some cores also
  // export the older singular `retro_set_cheat`; try both so cheats apply on any
  // core build (Android resolves `retro_cheat_set`, which is what actually works).
  void (*retro_cheat_set)(unsigned index, bool enabled, const char* code);
} g_core = {};

static enum retro_pixel_format g_pixFmt = RETRO_PIXEL_FORMAT_XRGB8888;
static bool g_coreReady = false;

// Frame texture
static std::vector<uint8_t> g_rgba;
static GLuint g_tex = 0;
static GLuint g_prog = 0;
static GLuint g_vbo = 0;
static bool g_texAllocated = false;
static int g_texW = 0, g_texH = 0;

// Audio ring buffer (S16LE samples, interleaved by core channels)
static std::vector<int16_t> g_audioBuf;
static const size_t AUDIO_CAP = 1 << 18;
static size_t g_audioWrite = 0;
static size_t g_audioRead = 0;
static std::mutex g_audioMtx;
static int g_audioChannels = 2;
static OH_AudioRenderer* g_renderer = nullptr;

// Input: NES joypad bitmask (RETRO_DEVICE_ID_JOYPAD_* bit positions)
static std::atomic<uint16_t> g_joypad{0};
// Libretro pad port driven by the on-screen pad: 0 = 1P, 1 = 2P (arcade only;
// every other profile always keeps 0). Mirrors Android's GsRunner::activePort_:
// a single virtual pad must drive ONE port, otherwise the core sees 1P and 2P
// pressed with the same bits at the same time (kof97 then never leaves the
// attract / service screen and every fire button looks dead for both players).
static std::atomic<int> g_playerPort{0};
#define BTN_START_BIT 3

// ---- netplay (§16.4 delay-based lockstep) ----
// One GsNetplay object backs the running session. When non-null the pace loop
// routes each retro_run() through the frame gate (beginFrame/endFrame) and the
// input callback returns the gated local/remote masks instead of g_joypad.
static np::GsNetplay* g_net = nullptr;
// 0 = host drives libretro port 0 (1P) with its local pad; 1 = guest drives
// port 1 (2P). Mirrors Android GsRunner::netIsHost_.
static int g_netLocalPort = 0;
// Live local pad mask, fed by SetInput during a session and published each frame.
static std::atomic<uint16_t> g_netLocalMask_{0};
// Per-port gated masks for the current frame (set by the pace loop pre-run).
static uint16_t g_netBtns[2] = {0, 0};
// Frames released to the core (== netplay frame counter K).
static long g_netFrame = 0;
static bool g_netDeadLogged = false;
// Host frame-0 serialized state, captured after the first locked frame so the
// ArkTS bootstrap HTTP server can serve it as /state0. Empty until captured.
static std::vector<uint8_t> g_netState0;
// Battery-RAM save path for the active netplay session (host serves /sram and
// /sram-final). Built from <appDir>/saves/<saveKey>.sav.
static std::string g_netSramPath;
// CRC key for the solo (1P) game's battery RAM. Set at retro_load_game time so
// StopEmulator can flush to <appDir>/saves/<crc>.sav — the same CRC-keyed
// location the cross-platform partner importer (and Android) read/write.
static std::string g_soloSaveKey;
// Defined below (in the netplay NAPI block); forward-declared so the pace loop
// (which runs earlier in this translation unit) can call it at frame 0.
static void CaptureNetState0();
// Fast-forward multiplier (1 = normal). Serialized against retro_run.
static std::atomic<int> g_speed{1};
// Audio mute (used by the "加速时同步音频" setting: when fast-forwarding with
// the toggle OFF, the audio is silenced to keep emulation stable). Serialized
// against the audio write callback via the ring-buffer mutex.
static std::atomic<bool> g_audioMuted{false};
// Presented frames per second, sampled every 0.5 s for the FPS HUD.
static std::atomic<double> g_fpsOut{0.0};
// Number of retro_run() calls that happened BEFORE netplay attached (must be 0:
// any solo frame shifts the guest's state away from the host's frame 0).
static std::atomic<long> g_emuRunCount{0};
// Core-reported AV timing fps (av.timing.fps), captured by EmuLoop. Mirrors
// Android GsRunner::fps_, which attachNetplay() uses for the default
// framePeriodSec (1.0 / fps_).
static std::atomic<double> g_coreFps{0.0};

// In-memory save-state slot + a mutex serializing UI ops vs retro_run.
static std::vector<uint8_t> g_saveBuf;
static std::mutex g_coreMtx;

// ---------------------------------------------------------------------------
// Libretro host callbacks
// ---------------------------------------------------------------------------
// Best-effort recursive mkdir (the OHOS libc mkdir has no -p); used to create
// the MAME BIOS directory before the core scans it.
static void MkDirs(const std::string& path) {
  std::string cur;
  for (size_t i = 0; i < path.size(); i++) {
    cur += path[i];
    if (path[i] == '/' || path[i] == '\\' || i + 1 == path.size()) {
      if (!cur.empty() && cur != "/" && cur != "\\") {
        mkdir(cur.c_str(), 0755);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Core log bridge
// ---------------------------------------------------------------------------
// Without RETRO_ENVIRONMENT_GET_LOG_INTERFACE the core falls back to
// fprintf(stderr) — invisible on OHOS — so every MAME startup error ("neogeo.zip
// NOT FOUND", "Required files are missing", unknown driver …) was silent.
// DEBUG level is dropped: MAME floods path-extraction info on every frame setup.
static void RetroLogByLevel(enum retro_log_level level, const char* fmt, va_list va) {
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, va);
  size_t n = strlen(buf);
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
  if (n == 0) return;
  // Keep the tail so a failed retro_load_game() can tell the user *which* files
  // the core could not find (see CollectMissingFromLog()).
  //
  // One entry per *line*: MAME emits whole blocks in a single call, e.g.
  // "nffe.03 NOT FOUND (tried in 1944)\nnffe.05 NOT FOUND (…)\n1944.key NOT
  // FOUND (…)", and storing that as one entry made the report list only the
  // first missing file.
  {
    std::lock_guard<std::mutex> lk(g_errMutex);
    const char* p = buf;
    while (*p != '\0') {
      const char* nl = strchr(p, '\n');
      const size_t len = (nl != nullptr) ? (size_t)(nl - p) : strlen(p);
      std::string line(p, len);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) {
        if (g_coreLogTail.size() >= kCoreLogTailMax) g_coreLogTail.pop_front();
        g_coreLogTail.emplace_back(line);
      }
      if (nl == nullptr) break;
      p = nl + 1;
    }
  }
  if (level == RETRO_LOG_ERROR) GPRETRO_ERROR("CORE: %{public}s", buf);
  else if (level == RETRO_LOG_WARN) GPRETRO_WARN("CORE: %{public}s", buf);
  else GPRETRO_INFO("CORE: %{public}s", buf);
}

static void RetroLogPrintf(enum retro_log_level level, const char* fmt, ...) {
  if (level == RETRO_LOG_DEBUG) return;
  va_list va;
  va_start(va, fmt);
  RetroLogByLevel(level, fmt, va);
  va_end(va);
}

static std::string JsonEscape(const std::string& s) {
  std::string o;
  o.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) {
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04x", c);
          o += esc;
        } else {
          o += (char)c;
        }
    }
  }
  return o;
}

// Publishes the reason a launch failed as a JSON blob for the ArkTS page:
//   {"reason":"load_game","missing":["nffe.03","1944.key"],"detail":"..."}
// `reason` is a stable token (rom_missing / dlopen / load_game) so the page can
// pick the right Chinese wording; `missing` is what MAME printed as NOT FOUND.
static void PublishLoadError(const char* reason,
                             const std::vector<std::string>& missing,
                             const std::string& detail) {
  std::string json = "{\"reason\":\"";
  json += reason;
  json += "\",\"missing\":[";
  for (size_t i = 0; i < missing.size(); ++i) {
    if (i) json += ",";
    json += "\"" + JsonEscape(missing[i]) + "\"";
  }
  json += "],\"detail\":\"" + JsonEscape(detail) + "\"}";
  std::lock_guard<std::mutex> lk(g_errMutex);
  g_loadError = json;
}

static void ClearLoadError() {
  std::lock_guard<std::mutex> lk(g_errMutex);
  g_loadError.clear();
  g_coreLogTail.clear();
}

// Pulls "<file> NOT FOUND (tried in <set>)" names out of the core log tail.
// MAME names one missing file per line, so this is the user's actionable list.
static std::vector<std::string> CollectMissingFromLog() {
  std::vector<std::string> out;
  std::lock_guard<std::mutex> lk(g_errMutex);
  static const char kMarker[] = " NOT FOUND";
  for (const auto& line : g_coreLogTail) {
    size_t p = line.find(kMarker);
    if (p == std::string::npos || p == 0) continue;
    std::string name = line.substr(0, p);
    while (!name.empty() && (name.front() == ' ' || name.front() == '\t')) name.erase(name.begin());
    // Keep the message short: names only, de-duplicated.
    bool dup = false;
    for (const auto& e : out) { if (e == name) { dup = true; break; } }
    if (!dup) out.push_back(name);
    if (out.size() >= 12) break;
  }
  return out;
}

// Last few core log lines, joined — used as the technical `detail`.
static std::string TailDetail() {
  std::string s;
  std::lock_guard<std::mutex> lk(g_errMutex);
  size_t start = g_coreLogTail.size() > 4 ? g_coreLogTail.size() - 4 : 0;
  for (size_t i = start; i < g_coreLogTail.size(); ++i) {
    if (!s.empty()) s += " | ";
    s += g_coreLogTail[i];
  }
  return s;
}

// ---------------------------------------------------------------------------
// Arcade content staging (OHOS port of Android's LockedRom staging)
// ---------------------------------------------------------------------------
// libretro MAME builds its search path in Set_Path_Option():
//   -rompath <dir of content>;<system_dir>/mame/bios;<system_dir>/mame/roms
// i.e. it only ever looks inside the content's *directory* plus `<system_dir>/mame`.
// Nothing populated those on OHOS: the imported zip stayed in roms/ and the
// user's BIOS stayed in system/ (root), so NeoGeo / QSound titles never found
// `neogeo.zip` / `qsound.zip` and stopped on MAME's blue "required files are
// missing" screen. Mirror what Android does before the core is handed the path.
static bool IsRegularFile(const std::string& p) {
  struct stat st;
  memset(&st, 0, sizeof(st));
  return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static int64_t FileSizeOf(const std::string& p) {
  struct stat st;
  memset(&st, 0, sizeof(st));
  return stat(p.c_str(), &st) == 0 ? (int64_t)st.st_size : -1;
}

static std::string BaseName(const std::string& p) {
  size_t s = p.find_last_of("/\\");
  return (s == std::string::npos) ? p : p.substr(s + 1);
}

// Copy [src] -> [dst] unless it is already there with the same size.
static bool CopyFileOnce(const std::string& src, const std::string& dst) {
  const int64_t srcSize = FileSizeOf(src);
  if (srcSize < 0) return false;
  if (IsRegularFile(dst) && FileSizeOf(dst) == srcSize) return true;
  FILE* in = fopen(src.c_str(), "rb");
  if (!in) return false;
  FILE* out = fopen(dst.c_str(), "wb");
  if (!out) {
    fclose(in);
    return false;
  }
  char buf[64 * 1024];
  size_t n;
  bool ok = true;
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
    if (fwrite(buf, 1, n, out) != n) {
      ok = false;
      break;
    }
  }
  fclose(in);
  fclose(out);
  if (!ok) {
    remove(dst.c_str());
    return false;
  }
  return true;
}

static std::string ToLowerCopy(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (char c : s) out += (char)tolower((unsigned char)c);
  return out;
}

// Forward declaration — defined later (Crc32File, IEEE 802.3) near the cheats
// code; used here by StagedUpToDate for BIOS CRC checks.
static uint32_t Crc32File(const std::string& path);

// True when [dst] already holds content identical to [src] for staging.
// Siblings (often 100s of MB) compare by size only — cheap, and matches
// Android LockedRom.gatherSiblingRoms. BIOS bundles (a few MB) also compare
// CRC32 so an equal-size-but-different dump is replaced — matches Android
// LockedRom.stageOneArcadeBios. This is exactly what stops a stale/truncated
// seed (e.g. a 2.6 KB qsound.zip left by a test) from shadowing the user's real
// BIOS, which is why MAME reported "dl-1425.bin NOT FOUND" on OHOS while the
// very same file booted fine on Android.
static bool StagedUpToDate(const std::string& src, const std::string& dst, bool useCrc) {
  if (!IsRegularFile(dst)) return false;
  if (FileSizeOf(dst) != FileSizeOf(src)) return false;
  if (useCrc && Crc32File(dst) != Crc32File(src)) return false;
  return true;
}

// Unlink [dst] then copy [src] -> [dst] (CopyFileOnce skips an existing dst, so
// the target must be gone first). Returns success.
static bool ReplaceWithCopy(const std::string& src, const std::string& dst) {
  remove(dst.c_str());
  return CopyFileOnce(src, dst);
}

// Stage [src] -> [dst], refreshing only when the existing copy is stale.
static bool StageFile(const std::string& src, const std::string& dst, bool useCrc) {
  if (StagedUpToDate(src, dst, useCrc)) return true;
  return ReplaceWithCopy(src, dst);
}

// Stages `<appDir>/rom_cache/mame/` so that it holds the game zip, every sibling
// set the user imported (clone parents such as 1943 for 1943j) and the BIOS
// bundles. Rewrites g_romPath to the staged copy so MAME's `g_rom_dir` — the
// *directory* of the content — is the directory we just populated.
// Hard-links [src] at [dst] (same filesystem → costs an inode, not the bytes),
// falling back to a copy where link() is unavailable. Refreshes [dst] when its
// size differs from [src] so a stale sibling never shadows a newer dump.
static bool LinkOrCopyOnce(const std::string& src, const std::string& dst) {
  if (IsRegularFile(dst)) {
    if (FileSizeOf(dst) == FileSizeOf(src)) return true;  // up to date by size
    remove(dst.c_str());                                  // stale → replace
  }
  if (link(src.c_str(), dst.c_str()) == 0) return true;
  return CopyFileOnce(src, dst);  // dst removed above, so the copy proceeds
}

static bool IsDirectory(const std::string& p) {
  struct stat st;
  if (stat(p.c_str(), &st) != 0) return false;
  return S_ISDIR(st.st_mode) != 0;
}

// Recursively stages every sibling *.zip under [root] into [destDir].
// MAME resolves a clone's parent by name from the rompath, so the parent must
// sit in the same directory as the content — which the flat (pre-recursive)
// version missed for anything imported into `roms/peer/` or `roms/cloud/`.
static void StageSiblingZips(const std::string& root, const std::string& destDir,
                             const std::string& skipName, int depth) {
  if (depth > 3) return;
  DIR* d = opendir(root.c_str());
  if (d == nullptr) return;
  struct dirent* e;
  while ((e = readdir(d)) != nullptr) {
    const std::string name(e->d_name);
    if (name == "." || name == "..") continue;
    const std::string full = root + "/" + name;
    const std::string lower = ToLowerCopy(name);
    if (lower.size() > 4 && lower.compare(lower.size() - 4, 4, ".zip") == 0) {
      // BIOS bundles are staged separately (step 2) so a partial copy from a
      // collection can never shadow the real one.
      if (lower == "neogeo.zip" || lower == "qsound.zip") continue;
      if (name == skipName) continue;  // already staged as the content itself
      if (LinkOrCopyOnce(full, destDir + "/" + name)) {
        GPRETRO_INFO("GPRETRO: staged sibling %{public}s", name.c_str());
      }
    } else if (IsDirectory(full)) {
      StageSiblingZips(full, destDir, skipName, depth + 1);
    }
  }
  closedir(d);
}

static void StageArcadeContent() {
  const std::string contentDir = g_appDir + "/rom_cache/mame";
  const std::string mameRomDir = g_appDir + "/system/mame/roms";
  MkDirs(contentDir);
  MkDirs(mameRomDir);

  // 1) The game itself. MAME re-reads it from disk through this path. Refresh on
  //    size change so an updated dump replaces a stale cached copy.
  const std::string srcRom = g_romPath;
  const std::string romName = BaseName(srcRom);
  const std::string dstRom = contentDir + "/" + romName;
  if (srcRom != dstRom) {
    if (StageFile(srcRom, dstRom, /*useCrc=*/false)) {
      if (g_romPath != dstRom) {
        GPRETRO_INFO("GPRETRO: staged content %{public}s (%{public}lld bytes)",
                     dstRom.c_str(), (long long)FileSizeOf(dstRom));
        g_romPath = dstRom;
      }
    } else {
      GPRETRO_WARN("GPRETRO: staging %{public}s failed, keeping original path", srcRom.c_str());
    }
  }

  // 2) BIOS bundles -> the content directory (== g_rom_dir) *and*
  //    <system_dir>/mame/roms, which is the other entry in MAME's rompath.
  //    CRC-checked (useCrc=true) to match Android LockedRom.stageOneArcadeBios:
  //    a stale/truncated qsound.zip (e.g. 2.6 KB seed) is overwritten with the
  //    user's real BIOS instead of being skipped because a copy already exists.
  static const char* kBios[] = {"neogeo.zip", "qsound.zip", "qsound_hle.zip", "pgm.zip"};
  for (const char* name : kBios) {
    const std::string rootSrc = g_appDir + "/system/" + name;
    const std::string subSrc = mameRomDir + "/" + name;
    std::string src;
    if (IsRegularFile(rootSrc)) src = rootSrc;
    else if (IsRegularFile(subSrc)) src = subSrc;
    if (src.empty()) {
      GPRETRO_WARN("GPRETRO: bios %{public}s not imported into system/ (arcade boot may fail)", name);
      continue;
    }
    const std::string targets[2] = {contentDir + "/" + name, subSrc};
    for (const std::string& t : targets) {
      if (StagedUpToDate(src, t, /*useCrc=*/true)) {
        GPRETRO_INFO("GPRETRO: bios %{public}s up to date at %{public}s", name, t.c_str());
      } else if (ReplaceWithCopy(src, t)) {
        GPRETRO_INFO("GPRETRO: staged bios %{public}s -> %{public}s", name, t.c_str());
      } else {
        GPRETRO_WARN("GPRETRO: bios copy %{public}s -> %{public}s failed", src.c_str(), t.c_str());
      }
    }
  }

  // 3) Sibling ROM sets (clone parents). MAME only opens what a driver asks
  //    for, so unrelated zips cost nothing at runtime. BIOS sets are skipped so
  //    a partial neogeo.zip from a collection can never shadow the real one.
  //
  //    Recursive on purpose: the library keeps user imports under flat
  //    `roms/` but peer/cloud transfers land in `roms/peer/`, `roms/cloud/` …
  //    and a clone (e.g. 1943j) needs its parent (1943.zip) in the *same*
  //    rompath entry. Staging is a hard link when possible, so pulling in the
  //    whole arcade library costs inodes instead of gigabytes.
  StageSiblingZips(g_filesDir, contentDir, romName, 0);
  // 4) The BIOS directory is the third rompath entry; link the sibling zips
  //    there too so a clone parent is found no matter which entry MAME probes.
  StageSiblingZips(g_filesDir, mameRomDir, romName, 0);
}

static bool EnvCallback(unsigned cmd, void* data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
      if (!data) return false;
      auto* logcb = static_cast<retro_log_callback*>(data);
      logcb->log = RetroLogPrintf;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      enum retro_pixel_format pf = *(const enum retro_pixel_format*)data;
      if (pf != RETRO_PIXEL_FORMAT_XRGB8888 && pf != RETRO_PIXEL_FORMAT_RGB565 &&
          pf != RETRO_PIXEL_FORMAT_0RGB1555) {
        GPRETRO_WARN("GPRETRO: env SET_PIXEL_FORMAT %{public}d unsupported", (int)pf);
        return false;
      }
      g_pixFmt = pf;
      GPRETRO_INFO("GPRETRO: env pixel format = %{public}d", (int)pf);
      return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      auto* var = static_cast<retro_variable*>(data);
      if (var != nullptr && strcmp(var->key, "fceumm_region") == 0) {
        var->value = g_forcedRegion.empty() ? "Auto" : const_cast<char*>(g_forcedRegion.c_str());
        return true;
      }
      // MAME: force the plain "-rom" media type so the core boots the arcade
      // driver derived from the file name directly (store CPS1/CPS2/NeoGeo).
      if (g_coreName == "mame" && var &&
          strcmp(var->key, "mame_media_type") == 0) {
        var->value = "rom";
        return true;
      }
      return false;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool*)data = false;
      return false;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      if (!g_systemDir.empty()) {
        *static_cast<const char**>(data) = g_systemDir.c_str();
        return true;
      }
      return false;
    case RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY:
      if (!g_contentDir.empty()) {
        *static_cast<const char**>(data) = g_contentDir.c_str();
        return true;
      }
      return false;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      // Netplay: mirror Android's npSaveDir_ — hand the core a pristine
      // per-process directory so it cannot restore this phone's own MAME cfg
      // (coin counters are part of the machine state, so two phones with
      // different play history desync from frame 0).
      if (g_netColdBoot && !g_npSaveDir.empty()) {
        *static_cast<const char**>(data) = g_npSaveDir.c_str();
        return true;
      }
      if (!g_saveDir.empty()) {
        *static_cast<const char**>(data) = g_saveDir.c_str();
        return true;
      }
      return false;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      if (data) *static_cast<bool*>(data) = true;
      return true;
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
      return true;
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
      return true;
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
      return true;
    default:
      return false;
  }
}

static void VideoRefresh(const void* data, unsigned width, unsigned height, size_t pitch) {
  if (data == nullptr || width == 0 || height == 0) {
    return;  // core skipped this frame
  }
  const size_t need = (size_t)width * height * 4;
  if (g_rgba.size() < need) {
    g_rgba.resize(need);
  }
  const uint8_t* src = (const uint8_t*)data;
  uint8_t* dst = g_rgba.data();
  if (g_pixFmt == RETRO_PIXEL_FORMAT_XRGB8888) {
    for (unsigned y = 0; y < height; y++) {
      const uint32_t* row = (const uint32_t*)(src + y * pitch);
      uint8_t* d = dst + (size_t)y * width * 4;
      for (unsigned x = 0; x < width; x++) {
        uint32_t p = row[x];
        d[0] = (uint8_t)((p >> 16) & 0xff);
        d[1] = (uint8_t)((p >> 8) & 0xff);
        d[2] = (uint8_t)(p & 0xff);
        d[3] = 255;
        d += 4;
      }
    }
  } else if (g_pixFmt == RETRO_PIXEL_FORMAT_RGB565) {
    for (unsigned y = 0; y < height; y++) {
      const uint16_t* row = (const uint16_t*)(src + y * pitch);
      uint8_t* d = dst + (size_t)y * width * 4;
      for (unsigned x = 0; x < width; x++) {
        uint16_t p = row[x];
        uint32_t r = (p >> 11) & 0x1f;
        uint32_t g = (p >> 5) & 0x3f;
        uint32_t b = p & 0x1f;
        d[0] = (uint8_t)((r * 255 + 15) / 31);
        d[1] = (uint8_t)((g * 255 + 31) / 63);
        d[2] = (uint8_t)((b * 255 + 15) / 31);
        d[3] = 255;
        d += 4;
      }
    }
  } else {  // 0RGB1555
    for (unsigned y = 0; y < height; y++) {
      const uint16_t* row = (const uint16_t*)(src + y * pitch);
      uint8_t* d = dst + (size_t)y * width * 4;
      for (unsigned x = 0; x < width; x++) {
        uint16_t p = row[x];
        uint32_t r = (p >> 10) & 0x1f;
        uint32_t g = (p >> 5) & 0x1f;
        uint32_t b = p & 0x1f;
        d[0] = (uint8_t)((r * 255 + 15) / 31);
        d[1] = (uint8_t)((g * 255 + 15) / 31);
        d[2] = (uint8_t)((b * 255 + 15) / 31);
        d[3] = 255;
        d += 4;
      }
    }
  }
  glBindTexture(GL_TEXTURE_2D, g_tex);
  if (!g_texAllocated || g_texW != (int)width || g_texH != (int)height) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, g_rgba.data());
    g_texW = (int)width;
    g_texH = (int)height;
    g_texAllocated = true;
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA,
                    GL_UNSIGNED_BYTE, g_rgba.data());
  }
  static bool firstVideo = true;
  if (firstVideo) {
    firstVideo = false;
    const uint32_t* p0 = (const uint32_t*)data;
    GPRETRO_INFO("GPRETRO: video first w=%{public}u h=%{public}u pitch=%{public}zu fmt=%{public}d "
                 "src0=0x%{public}08x src1=0x%{public}08x rgba=%{public}02x%{public}02x%{public}02x",
                 width, height, pitch, (int)g_pixFmt,
                 p0[0], p0[1], g_rgba[0], g_rgba[1], g_rgba[2]);
  }
}

static void AudioSample(int16_t left, int16_t right) {
  std::lock_guard<std::mutex> lk(g_audioMtx);
  g_audioBuf[g_audioWrite] = left;
  g_audioWrite = (g_audioWrite + 1) % AUDIO_CAP;
  g_audioBuf[g_audioWrite] = right;
  g_audioWrite = (g_audioWrite + 1) % AUDIO_CAP;
}

static size_t AudioBatch(const int16_t* data, size_t frames) {
  static bool firstAudio = true;
  {
    std::lock_guard<std::mutex> lk(g_audioMtx);
    size_t n = frames * g_audioChannels;
    for (size_t i = 0; i < n; i++) {
      g_audioBuf[g_audioWrite] = data[i];
      g_audioWrite = (g_audioWrite + 1) % AUDIO_CAP;
    }
  }
  if (firstAudio) {
    firstAudio = false;
    GPRETRO_INFO("GPRETRO: audio batch first frames=%{public}zu", frames);
  }
  return frames;
}

static void InputPoll() {
  // state already latched in g_joypad
}

static int16_t InputState(unsigned port, unsigned device, unsigned index, unsigned id) {
  if (device == RETRO_DEVICE_JOYPAD) {
    if (g_net != nullptr) {
      // Lockstep: both machines emulate the SAME core state, so libretro port 0
      // is always the host's pad on both machines. g_netBtns[0/1] were set by
      // the pace loop from beginFrame()'s local/remote masks; the guest's own
      // physical pad is therefore on port 1 here.
      // Mirror GsRunner::inputState(): ports above the two lockstep pads are
      // NOT driven — clamping 3P/4P onto port 1 made every 4-player machine
      // (MAME MVS 4-slot etc.) read P2's buttons twice, and Android returns 0.
      if (port > 1) return 0;
      if (id > 15) return 0;
      return (g_netBtns[port] >> id) & 1;
    }
    // Only the player selected by the 1P/2P pill receives input; every other
    // port reads "buttons up". Returning the same mask for all ports made MAME
    // see 1P and 2P (plus 3P/4P) pressed identically every frame.
    if ((int)port != g_playerPort.load(std::memory_order_relaxed)) return 0;
    if (id > 15) return 0;
    return (g_joypad.load(std::memory_order_relaxed) >> id) & 1;
  }
  // The on-screen pad is a DIGITAL controller: report a neutral analog axis so
  // only the d-pad bits drive IPT_JOYSTICK_* (same as the Android runner).
  return 0;
}

// ---------------------------------------------------------------------------
// EGL setup (shared between M0 fallback and M1 emulation)
// ---------------------------------------------------------------------------
static bool SetupEgl(void* window) {
  OHNativeWindow* nativeWindow = static_cast<OHNativeWindow*>(window);
  if (nativeWindow == nullptr) {
    GPRETRO_ERROR("GPRETRO: native window is null");
    return false;
  }

  uint64_t w = 0, h = 0;
  OH_NativeXComponent_GetXComponentSize(g_component, window, &w, &h);
  g_winW = (int)w;
  g_winH = (int)h;
  if (g_winW == 0 || g_winH == 0) {
    g_winW = 1080;
    g_winH = 2340;
  }
  OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_BUFFER_GEOMETRY, g_winW, g_winH);
  OH_NativeWindow_NativeWindowHandleOpt(nativeWindow, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);

  g_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_eglDisplay == EGL_NO_DISPLAY) {
    GPRETRO_ERROR("GPRETRO: eglGetDisplay failed");
    return false;
  }
  EGLint major = 0, minor = 0;
  eglInitialize(g_eglDisplay, &major, &minor);
  eglBindAPI(EGL_OPENGL_ES_API);

  EGLint attribs[] = {
      EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
      EGL_NONE };
  EGLConfig config = nullptr;
  EGLint numConfig = 0;
  eglChooseConfig(g_eglDisplay, attribs, &config, 1, &numConfig);
  if (config == nullptr) {
    EGLint fb[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE };
    eglChooseConfig(g_eglDisplay, fb, &config, 1, &numConfig);
  }
  if (config == nullptr) {
    GPRETRO_ERROR("GPRETRO: no EGL config");
    return false;
  }

  EGLint ctxAttr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
  g_eglContext = eglCreateContext(g_eglDisplay, config, EGL_NO_CONTEXT, ctxAttr);
  g_eglSurface = eglCreateWindowSurface(
      g_eglDisplay, config, reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
  if (g_eglSurface == EGL_NO_SURFACE) {
    GPRETRO_ERROR("GPRETRO: eglCreateWindowSurface failed (0x%{public}x)", (unsigned)eglGetError());
    return false;
  }
  GPRETRO_INFO("GPRETRO: EGL ready %{public}dx%{public}d", g_winW, g_winH);
  return true;
}

// ---------------------------------------------------------------------------
// GL helpers
// ---------------------------------------------------------------------------
static GLuint CompileShader(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[512];
    glGetShaderInfoLog(s, sizeof(log), nullptr, log);
    GPRETRO_ERROR("GPRETRO: shader compile failed: %{public}s", log);
  }
  return s;
}

static bool InitGLForCore() {
  const char* ver = (const char*)glGetString(GL_VERSION);
  const char* rend = (const char*)glGetString(GL_RENDERER);
  GPRETRO_INFO("GPRETRO: GL_VERSION=%{public}s GL_RENDERER=%{public}s", ver ? ver : "?", rend ? rend : "?");
  // GLSL ES 1.00 shaders run on both ES2 and ES3 contexts (maximally portable).
  const char* vsrc =
      "attribute vec2 a_pos; attribute vec2 a_uv; varying vec2 v_uv;\n"
      "void main(){ v_uv = a_uv; gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
  const char* fsrc =
      "precision mediump float; varying vec2 v_uv; uniform sampler2D u_tex;\n"
      "void main(){ gl_FragColor = texture2D(u_tex, v_uv); }\n";
  GLuint vs = CompileShader(GL_VERTEX_SHADER, vsrc);
  GLuint fs = CompileShader(GL_FRAGMENT_SHADER, fsrc);
  g_prog = glCreateProgram();
  glAttachShader(g_prog, vs);
  glAttachShader(g_prog, fs);
  // Bind attribute locations explicitly so the draw calls below match.
  glBindAttribLocation(g_prog, 0, "a_pos");
  glBindAttribLocation(g_prog, 1, "a_uv");
  glLinkProgram(g_prog);
  GLint ok = 0;
  glGetProgramiv(g_prog, GL_LINK_STATUS, &ok);
  if (!ok) {
    GPRETRO_ERROR("GPRETRO: program link failed");
    return false;
  }
  glDeleteShader(vs);
  glDeleteShader(fs);

  // Full-screen quad (positions + uv). uv flips Y so the NES frame is upright.
  float quad[16] = {
      -1.0f, -1.0f, 0.0f, 1.0f,
       1.0f, -1.0f, 1.0f, 1.0f,
      -1.0f,  1.0f, 0.0f, 0.0f,
       1.0f,  1.0f, 1.0f, 0.0f,
  };
  glGenBuffers(1, &g_vbo);
  glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

  glGenTextures(1, &g_tex);
  glBindTexture(GL_TEXTURE_2D, g_tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  g_texAllocated = false;
  return true;
}

// Display aspect ratio per core, mirroring EmulatorActivity.coreDar(): NES/FC
// applies the 8:7 pixel-aspect correction, GB/GG is 10:9, GBA is 3:2 and the
// rest honour 4:3. Without this the picture uses the raw frame aspect
// (256/240 = 1.067) and looks noticeably narrower than the Android build.
static float CoreAspect(int w, int h) {
  if (w <= 0 || h <= 0) return 4.0f / 3.0f;
  if (w == 256 && h == 240) return (256.0f / 240.0f) * (8.0f / 7.0f); // 1.2190
  if (w == 160 && h == 144) return 160.0f / 144.0f;                  // 1.1111
  if (w == 240 && h == 160) return 1.5f;                             // GBA
  return 4.0f / 3.0f;
}

static void DrawCoreFrame() {
  // Clear the whole surface to black, then letterbox the game frame (aspect-
  // correct, centered) exactly like the Android GL stage does.
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  if (g_texAllocated && g_texW > 0 && g_texH > 0) {
    float surfaceAspect = (g_winH > 0) ? (float)g_winW / (float)g_winH : 1.0f;
    float gameAspect = CoreAspect(g_texW, g_texH);
    int vpW, vpH;
    if (gameAspect > surfaceAspect) {
      vpW = g_winW;
      vpH = (int)((float)g_winW / gameAspect);
    } else {
      vpH = g_winH;
      vpW = (int)((float)g_winH * gameAspect);
    }
    int vpX = (g_winW - vpW) / 2;
    int vpY = (g_winH - vpH) / 2;
    glViewport(vpX, vpY, vpW, vpH);
    glUseProgram(g_prog);
    glBindTexture(GL_TEXTURE_2D, g_tex);
    glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * 4, (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * 4, (void*)(2 * 4));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  }
}

// ---------------------------------------------------------------------------
// Audio (OHAudio) fed from the core's samples
// ---------------------------------------------------------------------------
static OH_AudioData_Callback_Result OnAudioWrite(OH_AudioRenderer* renderer, void* userData,
                                                void* audioData, int32_t audioDataSize) {
  (void)renderer;
  (void)userData;
  int16_t* out = static_cast<int16_t*>(audioData);
  const int samplesNeeded = audioDataSize / static_cast<int>(sizeof(int16_t));
  std::lock_guard<std::mutex> lk(g_audioMtx);
  const bool muted = g_audioMuted.load();
  for (int i = 0; i < samplesNeeded; i++) {
    if (muted) {
      out[i] = 0;
    } else if (g_audioRead != g_audioWrite) {
      out[i] = g_audioBuf[g_audioRead];
      g_audioRead = (g_audioRead + 1) % AUDIO_CAP;
    } else {
      out[i] = 0;
    }
  }
  return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

static void StartAudio(double sampleRate, int channels) {
  g_audioChannels = channels > 0 ? channels : 2;
  g_audioBuf.assign(AUDIO_CAP, 0);
  g_audioWrite = g_audioRead = 0;

  OH_AudioStreamBuilder* builder = nullptr;
  if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS) {
    GPRETRO_WARN("GPRETRO: AudioStreamBuilder_Create failed");
    return;
  }
  OH_AudioStreamBuilder_SetSamplingRate(builder, (int32_t)sampleRate);
  OH_AudioStreamBuilder_SetChannelCount(builder, g_audioChannels);
  OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
  OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
  OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, OnAudioWrite, nullptr);
  if (OH_AudioStreamBuilder_GenerateRenderer(builder, &g_renderer) != AUDIOSTREAM_SUCCESS) {
    GPRETRO_WARN("GPRETRO: GenerateRenderer failed");
    g_renderer = nullptr;
    return;
  }
  OH_AudioRenderer_Start(g_renderer);
  GPRETRO_INFO("GPRETRO: audio started (rate=%{public}d ch=%{public}d)", (int)sampleRate, g_audioChannels);
}

static void StopAudio() {
  if (g_renderer) {
    OH_AudioRenderer_Stop(g_renderer);
    OH_AudioRenderer_Release(g_renderer);
    g_renderer = nullptr;
  }
}

// ---------------------------------------------------------------------------
// Core load + emulation loop
// ---------------------------------------------------------------------------
static bool LoadCore() {
  // Prefer loading the sibling libgs_<coreId>.so next to libgpretro.so (robust
  // on OHOS where a bare soname may not be on the dlopen search path).
  // RTLD_LOCAL keeps the core's symbols out of the global namespace so sibling
  // cores (each with their own libretro-common) never collide.
  const std::string soname = "libgs_" + g_coreName + ".so";
  std::string corePath;
  Dl_info selfInfo;
  memset(&selfInfo, 0, sizeof(selfInfo));
  if (dladdr((void*)&LoadCore, &selfInfo) != 0 && selfInfo.dli_fname != nullptr) {
    std::string selfPath = selfInfo.dli_fname;
    size_t slash = selfPath.find_last_of('/');
    if (slash != std::string::npos) {
      corePath = selfPath.substr(0, slash + 1) + soname;
    }
  }
  if (!corePath.empty()) {
    g_coreLib = dlopen(corePath.c_str(), RTLD_NOW | RTLD_LOCAL);
    GPRETRO_INFO("GPRETRO: dlopen(%{public}s) -> %{public}p", corePath.c_str(), g_coreLib);
  }
  if (!g_coreLib) {
    g_coreLib = dlopen(soname.c_str(), RTLD_NOW | RTLD_LOCAL);
    GPRETRO_INFO("GPRETRO: dlopen(%{public}s) -> %{public}p", soname.c_str(), g_coreLib);
  }
  if (!g_coreLib) {
    const char* err = dlerror();
    GPRETRO_ERROR("GPRETRO: dlopen %{public}s failed: %{public}s", soname.c_str(), err);
    PublishLoadError("dlopen", std::vector<std::string>{soname},
                     err != nullptr ? err : "dlopen failed");
    return false;
  }
  g_core.retro_set_environment = (void (*)(retro_environment_t))dlsym(g_coreLib, "retro_set_environment");
  g_core.retro_set_video_refresh = (void (*)(retro_video_refresh_t))dlsym(g_coreLib, "retro_set_video_refresh");
  g_core.retro_set_audio_sample = (void (*)(retro_audio_sample_t))dlsym(g_coreLib, "retro_set_audio_sample");
  g_core.retro_set_audio_sample_batch = (void (*)(retro_audio_sample_batch_t))dlsym(g_coreLib, "retro_set_audio_sample_batch");
  g_core.retro_set_input_poll = (void (*)(retro_input_poll_t))dlsym(g_coreLib, "retro_set_input_poll");
  g_core.retro_set_input_state = (void (*)(retro_input_state_t))dlsym(g_coreLib, "retro_set_input_state");
  g_core.retro_init = (void (*)(void))dlsym(g_coreLib, "retro_init");
  g_core.retro_deinit = (void (*)(void))dlsym(g_coreLib, "retro_deinit");
  g_core.retro_api_version = (unsigned (*)(void))dlsym(g_coreLib, "retro_api_version");
  g_core.retro_get_system_info = (void (*)(struct retro_system_info*))dlsym(g_coreLib, "retro_get_system_info");
  g_core.retro_get_system_av_info = (void (*)(struct retro_system_av_info*))dlsym(g_coreLib, "retro_get_system_av_info");
  g_core.retro_set_controller_port_device = (void (*)(unsigned, unsigned))dlsym(g_coreLib, "retro_set_controller_port_device");
  g_core.retro_reset = (void (*)(void))dlsym(g_coreLib, "retro_reset");
  g_core.retro_run = (void (*)(void))dlsym(g_coreLib, "retro_run");
  g_core.retro_load_game = (bool (*)(const struct retro_game_info*))dlsym(g_coreLib, "retro_load_game");
  g_core.retro_unload_game = (bool (*)(void))dlsym(g_coreLib, "retro_unload_game");
  g_core.retro_serialize_size = (size_t (*)(void))dlsym(g_coreLib, "retro_serialize_size");
  g_core.retro_serialize = (bool (*)(const void*, size_t))dlsym(g_coreLib, "retro_serialize");
  g_core.retro_unserialize = (bool (*)(const void*, size_t))dlsym(g_coreLib, "retro_unserialize");
  g_core.retro_get_memory_data = (void* (*)(unsigned))dlsym(g_coreLib, "retro_get_memory_data");
  g_core.retro_get_memory_size = (size_t (*)(unsigned))dlsym(g_coreLib, "retro_get_memory_size");
  // Cheat interface is optional (cores that don't support cheats leave these null).
  g_core.retro_cheat_reset = (void (*)(void))dlsym(g_coreLib, "retro_cheat_reset");
  g_core.retro_cheat_set = (void (*)(unsigned, bool, const char*))dlsym(g_coreLib, "retro_cheat_set");
  if (!g_core.retro_cheat_set) {
    // Fallback for cores that only export the older singular symbol.
    g_core.retro_cheat_set = (void (*)(unsigned, bool, const char*))dlsym(g_coreLib, "retro_set_cheat");
  }
  if (!g_core.retro_set_environment || !g_core.retro_run || !g_core.retro_load_game) {
    GPRETRO_ERROR("GPRETRO: missing core symbols");
    return false;
  }

  // Read the ROM first so the header heuristic can set g_forcedRegion before
  // the core reads the fceumm_region variable during retro_init.
  static std::vector<uint8_t> romData;
  if (g_coreName == "mame") {
    // MAME is need_fullpath and opens the zip itself, so slurping it into RAM
    // (60 MB+ for a NeoGeo cart, hundreds for later sets) would be pure waste.
    if (!IsRegularFile(g_romPath)) {
      GPRETRO_ERROR("GPRETRO: rom missing: %{public}s", g_romPath.c_str());
      PublishLoadError("rom_missing", std::vector<std::string>{BaseName(g_romPath)}, g_romPath);
      return false;
    }
    GPRETRO_INFO("GPRETRO: mame content %{public}s (%{public}lld bytes) - read from disk by core",
                 g_romPath.c_str(), (long long)FileSizeOf(g_romPath));
  } else {
    FILE* fp = fopen(g_romPath.c_str(), "rb");
    if (fp == nullptr) {
      GPRETRO_ERROR("GPRETRO: fopen rom failed: %{public}s", g_romPath.c_str());
      return false;
    }
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz <= 0) {
      fclose(fp);
      GPRETRO_ERROR("GPRETRO: rom size invalid: %{public}ld", sz);
      return false;
    }
    romData.resize((size_t)sz);
    size_t rd = fread(romData.data(), 1, (size_t)sz, fp);
    fclose(fp);
    GPRETRO_INFO("GPRETRO: read rom bytes=%{public}zu", rd);
    if (rd != (size_t)sz) {
      GPRETRO_ERROR("GPRETRO: short read rom %{public}zu != %{public}ld", rd, sz);
      return false;
    }
  }

  // iNES header heuristic (mirrors the Android runner): some Chinese TW-MMC3
  // pirate carts (e.g. 吞食天地 三国外传) ship with a WRONG iNES header claiming
  // Mapper 4 (MMC3) while actually being Mapper 198, with 640 KiB PRG (40 banks,
  // non-power-of-two), zero CHR banks (CHR-RAM) and battery WRAM. fceumm then
  // emulates the wrong board and stays at power-up (gray screen + silence).
  // Correct the header to mapper 198 and force the Dendy region.
  if (g_coreName == "fceumm" && romData.size() >= 16 && romData[0] == 'N' &&
      romData[1] == 'E' && romData[2] == 'S' && romData[3] == 0x1A) {
    bool plainInes = (romData[7] & 0x0C) == 0x00;
    int rawMapper = (romData[7] & 0xF0) | (romData[6] >> 4);
    int prgBanks = romData[4];
    int chrBanks = romData[5];
    bool battery = (romData[6] & 0x02) != 0;
    if (plainInes && rawMapper == 4 && prgBanks == 40 && chrBanks == 0 && battery) {
      uint8_t new6 = (uint8_t)((romData[6] & 0x0F) | 0x60); // mapper 198 low nibble
      uint8_t new7 = (uint8_t)((romData[7] & 0x0F) | 0xC0); // mapper 198 high nibble
      romData[6] = new6;
      romData[7] = new7;
      // fceumm is need_fullpath: it reads the file from disk, so persist the
      // corrected header bytes in place (the app's own imported copy).
      FILE* pf = fopen(g_romPath.c_str(), "r+b");
      if (pf) {
        fseek(pf, 6, SEEK_SET);
        fputc((int)new6, pf);
        fputc((int)new7, pf);
        fclose(pf);
        GPRETRO_INFO("GPRETRO: rom heuristic mapper4->198 header patched in place");
      } else {
        GPRETRO_WARN("GPRETRO: rom heuristic mapper198 detected but file not writable");
      }
    }
    bool nes2 = (romData[7] & 0x0C) == 0x08;
    int mapper = (romData[7] & 0xF0) | (romData[6] >> 4);
    if (nes2) mapper |= (romData[8] & 0x0F) << 8;
    bool headerPal = nes2 ? ((romData[12] & 0x03) == 0x01) : (romData[9] == 0x01);
    if (mapper == 198 || mapper == 199) {
      g_forcedRegion = "Dendy";
    } else if (headerPal) {
      g_forcedRegion = "PAL";
    }
    GPRETRO_INFO("GPRETRO: rom header mapper=%{public}d nes2=%{public}d region=%{public}s",
                 mapper, (int)nes2, g_forcedRegion.empty() ? "Auto" : g_forcedRegion.c_str());
  }

  g_pixFmt = RETRO_PIXEL_FORMAT_XRGB8888;
  g_core.retro_set_environment(EnvCallback);
  g_core.retro_set_video_refresh(VideoRefresh);
  g_core.retro_set_audio_sample(AudioSample);
  g_core.retro_set_audio_sample_batch(AudioBatch);
  g_core.retro_set_input_poll(InputPoll);
  g_core.retro_set_input_state(InputState);
  g_core.retro_init();

  if (g_core.retro_get_system_info) {
    struct retro_system_info si;
    memset(&si, 0, sizeof(si));
    g_core.retro_get_system_info(&si);
    GPRETRO_INFO("GPRETRO: core lib=%{public}s ver=%{public}s valid=%{public}s needFullPath=%{public}d",
                 si.library_name ? si.library_name : "?", si.library_version ? si.library_version : "?",
                 si.valid_extensions ? si.valid_extensions : "?", (int)si.need_fullpath);
  }

  // MAME reads the ROM from disk via info.path and ignores in-memory data, so drop
  // the buffer and make sure its BIOS directory exists. (fceumm is also
  // need_fullpath but accepts the patched data buffer, so we leave it.)
  if (g_coreName == "mame") {
    romData.clear();
    romData.shrink_to_fit();
    MkDirs(g_systemDir);
  }

  // Solo (1P): mirror Android (gs_runner.cpp) — the libretro save directory is
  // the flat <appDir>/saves. The core's own auto-SRAM lands at
  // <saveDir>/<romBasename>.sav, which we migrate into the CRC-keyed canonical
  // file below. (Do NOT scope per-CRC here; Android keeps this flat and relies
  // on the CRC-keyed canonical for isolation.)
  if (g_netSramPath.empty()) {
    g_saveDir = g_appDir + "/saves";
    MkDirs(g_saveDir);
  }

  struct retro_game_info info;
  memset(&info, 0, sizeof(info));
  info.path = g_romPath.c_str();
  info.data = romData.empty() ? nullptr : romData.data();
  info.size = romData.empty() ? 0 : romData.size();
  if (!g_core.retro_load_game(&info)) {
    GPRETRO_ERROR("GPRETRO: retro_load_game failed for %{public}s", g_romPath.c_str());
    // MAME logs one "<file> NOT FOUND (tried in <set>)" line per missing dump
    // before failing, so this is exactly what the user must fix (wrong ROM set
    // revision, missing parent/clone set, or a missing BIOS like neogeo.zip).
    PublishLoadError("load_game", CollectMissingFromLog(), TailDetail());
    return false;
  }

  struct retro_system_av_info av;
  memset(&av, 0, sizeof(av));
  g_core.retro_get_system_av_info(&av);
  GPRETRO_INFO("GPRETRO: loaded rom %{public}s  frame=%{public}d x %{public}d  fps=%{public}.1f rate=%{public}d",
               g_romPath.c_str(), av.geometry.base_width, av.geometry.base_height,
               (float)av.timing.fps, (int)av.timing.sample_rate);
  StartAudio(av.timing.sample_rate, 2);
  // HarmonyOS solo play: mirror Android's gs_runner.cpp exactly. The canonical
  // battery RAM is CRC-keyed at <appDir>/saves/<crc>.sav (the same location the
  // cross-platform partner importer and Android read/write). The libretro core
  // also auto-saves <saveDir>/<romBasename>.sav (<appDir>/saves/<basename>.sav);
  // when no CRC-keyed save exists we migrate that one into the canonical file
  // (rename, matching Android's one-time migration) so existing saves carry over
  // without a stale shared file ever being used. Netplay keeps its own
  // g_netSramPath and loads via the frame-0 bootstrap.
  if (g_netSramPath.empty()) {
    // Per-game key = the CRC32 stored in rom_index.json for this ROM's
    // relativePath (mirrors Android's CheatStore.crcKey). Different devices may
    // carry different dumps (different disk bytes -> different Crc32File), but
    // they share the same synced rom_index.json, so the key stays identical and
    // imported saves load. Falls back to the disk CRC for unindexed ROMs.
    g_soloSaveKey = SoloSaveCrc();
    if (!g_soloSaveKey.empty() && !g_appDir.empty() &&
        g_core.retro_get_memory_data != nullptr && g_core.retro_get_memory_size != nullptr) {
      std::string sp = g_appDir + "/saves/" + g_soloSaveKey + ".sav";
      // legacy = <saveDir>/<romBasename>.sav (the core's own auto-save location)
      std::string base = g_romPath.substr(g_romPath.find_last_of('/') + 1);
      auto dot = base.find_last_of('.');
      if (dot != std::string::npos) base = base.substr(0, dot);
      std::string legacy = g_saveDir + "/" + base + ".sav";
      // Mirror Android: if the canonical CRC-keyed save exists, load it;
      // otherwise migrate the legacy <basename>.sav into the canonical path.
      std::string loadFrom;
      FILE* probe = fopen(sp.c_str(), "rb");
      if (probe != nullptr) {
        loadFrom = sp;
        fclose(probe);
      } else {
        FILE* lg = fopen(legacy.c_str(), "rb");
        if (lg != nullptr) {
          fclose(lg);
          loadFrom = legacy;
        }
      }
      if (!loadFrom.empty()) {
        FILE* f = fopen(loadFrom.c_str(), "rb");
        if (f != nullptr) {
          fseek(f, 0, SEEK_END);
          long sz = ftell(f);
          fseek(f, 0, SEEK_SET);
          if (sz > 0) {
            std::vector<uint8_t> buf(static_cast<size_t>(sz));
            if (fread(buf.data(), 1, buf.size(), f) == buf.size()) {
              void* d = g_core.retro_get_memory_data(0);
              size_t cap = g_core.retro_get_memory_size(0);
              if (d != nullptr && cap >= buf.size()) {
                memcpy(d, buf.data(), buf.size());
                // Migrate the legacy file into the canonical path so it is not
                // reused / shared across games (matches Android's rename).
                if (loadFrom != sp) {
                  fclose(f);
                  f = nullptr;
                  rename(legacy.c_str(), sp.c_str());
                }
              }
            }
          }
          if (f) fclose(f);
        }
      }
    }
  }
  return true;
}

static void EmuLoop() {
  // The EGL context must be current on this thread before any GL calls
  // (shader compile, texture upload, draw). Make it current up-front.
  eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext);
  if (!InitGLForCore()) {
    GPRETRO_ERROR("GPRETRO: GL init failed");
    return;
  }
  if (!LoadCore()) {
    GPRETRO_ERROR("GPRETRO: core load failed; showing blue fallback");
    // blue fallback
    while (g_running.load()) {
      eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext);
      glClearColor(0.20f, 0.60f, 0.90f, 1.0f);
      glClear(GL_COLOR_BUFFER_BIT);
      eglSwapBuffers(g_eglDisplay, g_eglSurface);
      std::this_thread::sleep_for(std::chrono::milliseconds(16));
    }
    return;
  }
  g_coreReady = true;

  double fps = 60.0;
  // fps unknown until av info; LoadCore already started audio. Re-query fps.
  struct retro_system_av_info av;
  memset(&av, 0, sizeof(av));
  g_core.retro_get_system_av_info(&av);
  if (av.timing.fps > 0.0) {
    fps = av.timing.fps;
  }
  g_coreFps.store(fps, std::memory_order_relaxed);
  const double frameMs = 1000.0 / fps;
  bool firstFrame = true;
  long frameCount = 0;
  long fpsFrames = 0;
  auto fpsT0 = std::chrono::steady_clock::now();
  double statRunMs = 0, statDrawMs = 0, statSleepMs = 0, statTotalMs = 0;

  while (g_running.load()) {
    auto t0 = std::chrono::steady_clock::now();

    eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext);
    {
      // Fast-forward: run `speed` emulated frames per presented frame.
      //
      // LOCK ORDER (mirrors Android GsRunner::pacingLoop exactly):
      //   - beginFrame / endFrame / notifyStart / OhosNetCheckpoint  → NO g_coreMtx
      //     (these acquire netplay's own mtx_ internally, or call
      //      retro_serialize which must NOT race retro_run)
      //   - retro_run                                                → g_coreMtx
      //     (mutual exclusion vs UI save/load/reset on other threads)
      // The outer scope here holds NO mutex — only the inner retro_run()
      // acquisition protects the core. This avoids the std::mutex non-recursive
      // re-deadlock (OhosNetCheckpoint tried to lock g_coreMtx while the outer
      // scope still held it, which killed the pace thread at frame 120).
      if (g_emuFrozen.load(std::memory_order_relaxed)) {
        // Netplay attach gate: render, but do NOT emulate (see g_emuFrozen).
        // Sleep so we don't spin the EGL swap at kilohertz while parked.
        usleep(4000);
      } else {
      int sp = g_speed.load();
      if (sp < 1) sp = 1;
      for (int i = 0; i < sp; i++) {
        if (g_net != nullptr) {
          // Netplay frame gate: block until the remote input for frame (K-D) is
          // authenticated, then drive the gated local/remote masks. Mirror
          // GsRunner::pacingLoop — Park (Paused/Starting) loops, Dead parks.
          static bool g_netLoopEntered = false;
          if (!g_netLoopEntered) {
            g_netLoopEntered = true;
            GPRETRO_ERROR("GPRETRO: *** NETPLAY ENTERED *** localPort=%d f=%d",
                          g_netLocalPort, (int)g_netFrame);
          }
          uint16_t lm = 0, rm = 0;
          np::GateResult gr;
          int parkCount = 0;
          while (g_running.load()) {
            gr = g_net->beginFrame((uint32_t)g_netFrame, lm, rm);
            if (gr == np::GateResult::Ok) {
              parkCount = 0;
              if (g_netLocalPort == 0) {  // host: local on port 0
                g_netBtns[0] = lm;
                g_netBtns[1] = rm;
              } else {  // guest: local on port 1
                g_netBtns[0] = rm;
                g_netBtns[1] = lm;
              }
              break;
            }
            if (gr == np::GateResult::Dead && !g_netDeadLogged) {
              g_netDeadLogged = true;
              GPRETRO_ERROR("GPRETRO: netplay dead at frame %{public}ld after %d parks", g_netFrame, parkCount);
            }
            parkCount++;
            struct timespec rest {};
            rest.tv_nsec = 100 * 1000 * 1000;  // 100 ms
            clock_nanosleep(CLOCK_MONOTONIC, 0, &rest, nullptr);
          }
          if (!g_running.load()) break;
          {
            std::lock_guard<std::mutex> lk(g_coreMtx);
            g_core.retro_run();
            g_emuRunCount.fetch_add(1, std::memory_order_relaxed);
          }
          g_net->endFrame((uint32_t)g_netFrame, g_netLocalMask_.load());
          if (g_netFrame == 0) {
            // Capture host frame-0 state for the bootstrap server (/state0).
            CaptureNetState0();
          }
          g_netFrame++;
          OhosNetCheckpoint();
        } else {
          std::lock_guard<std::mutex> lk(g_coreMtx);
          g_core.retro_run();
          g_emuRunCount.fetch_add(1, std::memory_order_relaxed);
        }
      }
      }  // end of the !g_emuFrozen branch
    }
    auto tRun = std::chrono::steady_clock::now();
    DrawCoreFrame();
    EGLBoolean sw = eglSwapBuffers(g_eglDisplay, g_eglSurface);
    (void)sw;
    auto tSwap = std::chrono::steady_clock::now();
    statRunMs += std::chrono::duration<double, std::milli>(tRun - t0).count();
    statDrawMs += std::chrono::duration<double, std::milli>(tSwap - tRun).count();
    frameCount++;
    fpsFrames++;
    {
      // HUD readout: presented frames per second over a 0.5 s window.
      auto now = std::chrono::steady_clock::now();
      double win = std::chrono::duration<double, std::milli>(now - fpsT0).count();
      if (win >= 500.0) {
        g_fpsOut.store((double)fpsFrames * 1000.0 / win);
        fpsFrames = 0;
        fpsT0 = now;
      }
    }
    if (firstFrame) {
      GPRETRO_INFO("GPRETRO: emu first frame swap=%{public}d glErr=0x%{public}x", (int)sw, (unsigned)glGetError());
      firstFrame = false;
    } else if (frameCount % 300 == 0) {
      GPRETRO_INFO("GPRETRO: emu running frames=%{public}ld glErr=0x%{public}x run=%{public}.2fms draw+swap=%{public}.2fms sleep=%{public}.2fms total=%{public}.2fms",
                   frameCount, (unsigned)glGetError(),
                   statRunMs / 300.0, statDrawMs / 300.0, statSleepMs / 300.0,
                   statTotalMs / 300.0);
      statRunMs = 0; statDrawMs = 0; statSleepMs = 0; statTotalMs = 0;
    }

    auto t1 = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
    double remain = frameMs - elapsed;
    auto tSleep0 = std::chrono::steady_clock::now();
    if (remain > 0.0) {
      std::this_thread::sleep_for(std::chrono::milliseconds((long)remain));
    }
    auto tSleep1 = std::chrono::steady_clock::now();
    statSleepMs += std::chrono::duration<double, std::milli>(tSleep1 - tSleep0).count();
    statTotalMs += std::chrono::duration<double, std::milli>(tSleep1 - t0).count();
  }

  GPRETRO_INFO("GPRETRO: emu loop exit; unloading core");
  g_core.retro_unload_game();
  g_core.retro_deinit();
  StopAudio();
  // NOTE: deliberately NOT calling dlclose() here. libgs_mame.so is large and its
  // static destructors can crash the render thread (and therefore the whole
  // process) when unloaded at emu-exit time -- this is exactly the arcade-only
  // "exiting to the library crashes the app" bug. Leaking the handle is
  // harmless: the next launch re-dlopens the same refcounted object and
  // re-resolves the dlsym'd symbols. NES/GBA cores are tiny and unload cleanly,
  // so they never hit this; skipping dlclose for them is equally safe.
  g_coreLib = nullptr;
}

// ---------------------------------------------------------------------------
// XComponent callbacks
// ---------------------------------------------------------------------------
static void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
  GPRETRO_INFO("GPRETRO: OnSurfaceCreated fired component=%{public}p window=%{public}p", (void*)component, window);
  if (!SetupEgl(window)) {
    return;
  }
  g_running.store(true);
  if (!g_romPath.empty()) {
    g_renderThread = std::thread(EmuLoop);
    GPRETRO_INFO("GPRETRO: emu thread started for %{public}s", g_romPath.c_str());
  } else {
    // M0 fallback: plain blue clear + a steady tone.
    g_renderThread = std::thread([]() {
      while (g_running.load()) {
        eglMakeCurrent(g_eglDisplay, g_eglSurface, g_eglSurface, g_eglContext);
        glClearColor(0.20f, 0.60f, 0.90f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        eglSwapBuffers(g_eglDisplay, g_eglSurface);
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
      }
    });
    GPRETRO_INFO("GPRETRO: M0 fallback thread started");
  }
}

static void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
  uint64_t w = 0, h = 0;
  if (component != nullptr) {
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
  }
  if (w > 0 && h > 0 && ((int)w != g_winW || (int)h != g_winH)) {
    g_winW = (int)w;
    g_winH = (int)h;
    GPRETRO_INFO("GPRETRO: surface changed %{public}dx%{public}d", g_winW, g_winH);
  }
}

// Stops the emulation thread and releases all EGL/GL/audio resources. Idempotent
// and safe to call from either the ArkTS page teardown (aboutToDisappear / the
// in-app exit button) BEFORE the XComponent surface is destroyed, or from
// OnSurfaceDestroyed. Stopping the thread first is the fix for the app crash on
// exit to the library: router.back() tears the XComponent surface down while the
// render thread can still be inside eglSwapBuffers(), and swapping into a dying
// surface aborts the process. Calling this up-front guarantees the thread is
// parked before the surface goes away.
static void StopEmulator() {
  GPRETRO_INFO("GPRETRO: StopEmulator");
  // Flush solo battery RAM to the CRC-keyed <appDir>/saves/<crc>.sav — the same
  // location the partner importer (and Android) read/write. Must run while the
  // render thread is alive and frozen: take g_coreMtx (released between frames),
  // stop the loop, snapshot SAVE_RAM, then release. Netplay flushes its own path.
  if (g_netSramPath.empty() && !g_soloSaveKey.empty() && !g_appDir.empty() &&
      g_core.retro_get_memory_data != nullptr && g_core.retro_get_memory_size != nullptr) {
    std::lock_guard<std::mutex> lk(g_coreMtx);
    g_running.store(false, std::memory_order_relaxed);
    void* p = g_core.retro_get_memory_data(0);
    size_t sz = g_core.retro_get_memory_size(0);
    if (p != nullptr && sz > 0) {
      std::string sp = g_appDir + "/saves/" + g_soloSaveKey + ".sav";
      MkDirs(g_appDir + "/saves");
      std::string tmp = sp + ".np-tmp";
      FILE* f = fopen(tmp.c_str(), "wb");
      if (f != nullptr) {
        if (fwrite(p, 1, sz, f) == sz) {
          fclose(f);
          rename(tmp.c_str(), sp.c_str());
        } else {
          fclose(f);
          remove(tmp.c_str());
        }
      }
    }
  } else {
    g_running.store(false, std::memory_order_relaxed);
  }
  if (g_renderThread.joinable()) {
    g_renderThread.join();
  }
  if (g_eglDisplay != EGL_NO_DISPLAY) {
    eglMakeCurrent(g_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (g_eglSurface != EGL_NO_SURFACE) {
      eglDestroySurface(g_eglDisplay, g_eglSurface);
      g_eglSurface = EGL_NO_SURFACE;
    }
    if (g_eglContext != EGL_NO_CONTEXT) {
      eglDestroyContext(g_eglDisplay, g_eglContext);
      g_eglContext = EGL_NO_CONTEXT;
    }
    eglTerminate(g_eglDisplay);
    g_eglDisplay = EGL_NO_DISPLAY;
  }
  g_coreReady = false;
}

// NAPI wrapper: ArkTS calls stopEmulator() to tear the emulation down before the
// page is popped (router.back()). Returns nothing.
static napi_value StopEmulatorNapi(napi_env env, napi_callback_info info) {
  (void)env; (void)info;
  StopEmulator();
  return nullptr;
}

static void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
  GPRETRO_INFO("GPRETRO: OnSurfaceDestroyed");
  (void)component;
  (void)window;
  StopEmulator();
}

static void DispatchTouchEvent(OH_NativeXComponent* component, void* window) {
  (void)component;
  (void)window;
}

static OH_NativeXComponent_Callback g_xcCallback = {
    OnSurfaceCreated,
    OnSurfaceChanged,
    OnSurfaceDestroyed,
    DispatchTouchEvent
};

// ---------------------------------------------------------------------------
// NAPI exports
// ---------------------------------------------------------------------------
static napi_value StartEmulator(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  GPRETRO_INFO("GPRETRO: StartEmulator called g_component=%{public}p rom=%{public}s",
               (void*)g_component, g_romPath.c_str());
  if (g_component == nullptr && argc > 0) {
    OH_NativeXComponent* candidate = nullptr;
    if (napi_unwrap(env, args[0], reinterpret_cast<void**>(&candidate)) == napi_ok &&
        candidate != nullptr) {
      g_component = candidate;
      OH_NativeXComponent_RegisterCallback(candidate, &g_xcCallback);
    }
  }
  return nullptr;
}

// Args: (string rom, string core, bool coldBoot = false). Stores the target so
// OnSurfaceCreated can dlopen + run. Called from the ArkTS page before the
// surface is created.
//
// [coldBoot] mirrors Android's `NativeBridge.nativeInit(netplayColdBoot =
// npCfg != null)`: it arms `GP_NETPLAY_COLD_BOOT` for the MAME core so
// running_machine::nvram_load() seeds NVRAM from the deterministic device
// default instead of the phone's own <saveDir>/<core>/nvram/<game> file. A
// lockstep session cold-boots both peers independently (the bootstrap
// deliberately skips the frame-0 state sync), so without this each device
// starts from a DIFFERENT NVRAM image and the two machines desync from the
// very first checkpoint — exactly the failure this fixes.
static napi_value SetEmulatorTarget(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = { nullptr, nullptr, nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  char rom[4096] = {0};
  char core[64] = {0};
  if (argc > 0) {
    napi_get_value_string_utf8(env, args[0], rom, sizeof(rom), nullptr);
  }
  if (argc > 1) {
    napi_get_value_string_utf8(env, args[1], core, sizeof(core), nullptr);
  }
  bool coldBoot = false;
  if (argc > 2 && args[2] != nullptr) {
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, args[2], &t) == napi_ok) {
      if (t == napi_boolean) {
        bool b = false;
        if (napi_get_value_bool(env, args[2], &b) == napi_ok) coldBoot = b;
      } else if (t == napi_number) {
        double d = 0;
        if (napi_get_value_double(env, args[2], &d) == napi_ok) coldBoot = d != 0;
      }
    }
  }
  // Must be armed BEFORE the core is dlopened/loaded (the core reads it during
  // machine start), and cleared for solo play so normal save/load is untouched.
  if (coldBoot) setenv("GP_NETPLAY_COLD_BOOT", "1", 1);
  else unsetenv("GP_NETPLAY_COLD_BOOT");
  g_netColdBoot = coldBoot;
  g_npSaveDir.clear();
  g_netSramPath.clear();
  g_soloSaveKey.clear();
  g_netPrimeDone = false;
  g_emuRunCount.store(0);
  g_romPath = rom;
  if (core[0]) {
    g_coreName = core;
  }
  // Each launch starts with a clean diagnosis slate.
  ClearLoadError();
  // Every launch starts on 1P, whether or not the previous one was switched to
  // 2P (the native state outlives the ArkTS page).
  g_playerPort.store(0, std::memory_order_relaxed);
  // The app root is the directory that contains the `roms/` segment: ROMs live
  // under <appRoot>/roms/..., either flat (<appRoot>/roms/<name>.zip) or nested
  // in <appRoot>/roms/peer/, <appRoot>/roms/cloud/, ... The BIOS / system dir is
  // always <appRoot>/system. Deriving the root by "going one level up from the
  // ROM's own directory" only works for flat ROMs — for peer/cloud ROMs it stops
  // at <appRoot>/roms, so the core searched <appRoot>/roms/system/qsound.zip and
  // never found the real <appRoot>/system/qsound.zip, breaking every CPS-1/2
  // (Q-Sound) game even though the identical file boots on Android. Android's
  // LockedRom.kt avoids this by taking the true filesDir from the app context,
  // never reconstructing it from the ROM path. Mirror that: anchor on `roms/`.
  g_filesDir = g_romPath.substr(0, g_romPath.find_last_of("/\\"));   // ROM's own dir
  std::string rootDir;
  // Anchor the app root on a known app subdir so /roms/, /rom_cache/, /system/
  // and /state all resolve against the true <appRoot>. The ROM may legitimately
  // live under rom_cache/mame (netplay probe + the real arcade import path) or
  // roms/peer/ (cloud import), not only flat roms/, so fall back to /rom_cache
  // when /roms/ is absent. Without this, a cache-path ROM made g_appDir resolve
  // to <appRoot>/rom_cache, so g_systemDir became <appRoot>/rom_cache/system and
  // the BIOS lookup never found the real <appRoot>/system/neogeo.zip — every
  // NeoGeo game failed with "sfix.sfix / 000-lo.lo NOT FOUND".
  size_t rp = g_romPath.find("/roms/");
  if (rp == std::string::npos) rp = g_romPath.find("\\roms\\");
  if (rp == std::string::npos) rp = g_romPath.find("/rom_cache");
  if (rp == std::string::npos) rp = g_romPath.find("\\rom_cache");
  if (rp != std::string::npos) {
    rootDir = g_romPath.substr(0, rp);
  } else {
    rootDir = g_filesDir;
    size_t sep = g_filesDir.find_last_of("/\\");
    if (sep != std::string::npos) rootDir = g_filesDir.substr(0, sep);
  }
  g_appDir = rootDir;
  // Per the field comment, g_filesDir is "app files dir / roms" (save states,
  // thumbnails, cheats live here); keep it stable regardless of ROM nesting so
  // the BIOS lookup below resolves against the true <appRoot>/system.
  g_filesDir = rootDir + "/roms";
  // RetroArch semantics: the system dir is the *root* that already contains
  // `mame/`, because the core appends `<CORE_NAME>/roms` itself when it builds
  // `-rompath`. Pointing it at `system/mame/roms` (as it used to) made the core
  // scan `system/mame/roms/mame/roms` and never see the imported BIOS.
  g_systemDir = rootDir + "/system";
  g_contentDir = rootDir + "/rom_cache/mame";
  g_saveDir = rootDir + "/state";
  // Mirror Android GsRunner::init(): a lockstep pair must not restore this
  // phone's own MAME cfg (coin counters / bookkeeping are part of the machine
  // state), so point the core at a brand-new empty per-process save directory.
  // Solo play keeps using the real one (<appRoot>/state).
  if (g_netColdBoot) {
    const std::string tag = "np_" + std::to_string(static_cast<long>(getpid()));
    g_npSaveDir = g_saveDir + "/" + tag;
    // Create it up front (mirrors Android's std::filesystem::create_directories)
    // so the very first cfg write has a home and the directory exists for the
    // leftover-sweep above.
    MkDirs(g_npSaveDir);
    // Drop the leftovers of earlier sessions (a few KB of core cfg each).
    std::error_code ec;
    for (const auto &e : std::filesystem::directory_iterator(g_saveDir, ec)) {
      if (ec) break;
      if (!e.is_directory(ec)) continue;
      const std::string n = e.path().filename().string();
      if (n.rfind("np_", 0) == 0 && n != tag) std::filesystem::remove_all(e.path(), ec);
    }
  }
  GPRETRO_INFO("GPRETRO: SetEmulatorTarget rom=%{public}s core=%{public}s dir=%{public}s sys=%{public}s coldBoot=%{public}d",
               rom, core, g_filesDir.c_str(), g_systemDir.c_str(), (int)coldBoot);
  // Arcade only: everything else boots straight from the imported file.
  if (g_coreName == "mame") {
    StageArcadeContent();
  }
  return nullptr;
}

// Returns "" while the current target is healthy, or a JSON blob describing why
// it did not boot:
//   {"reason":"load_game","missing":["nffe.03","1944.key"],"detail":"..."}
// The ArkTS page polls this so an arcade ROM whose set does not match MAME can
// be explained ("缺 nffe.03 …，请更换完整 ROM 集") instead of a silent blue screen.
static napi_value GetLoadError(napi_env env, napi_callback_info info) {
  (void)info;
  std::string s;
  {
    std::lock_guard<std::mutex> lk(g_errMutex);
    s = g_loadError;
  }
  napi_value out = nullptr;
  napi_create_string_utf8(env, s.c_str(), s.size(), &out);
  return out;
}

// Args: (int32 mask). NES joypad bitmask (RETRO_DEVICE_ID_JOYPAD_* bits).
static napi_value SetInput(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t mask = 0;
  if (argc > 0) {
    napi_get_value_int32(env, args[0], &mask);
  }
  g_joypad.store((uint16_t)(mask & 0xFFFF));
  // During netplay the live local pad also feeds the lockstep transport; the
  // single-player g_joypad is untouched so solo play is unaffected.
  g_netLocalMask_.store((uint16_t)(mask & 0xFFFF));
  return nullptr;
}

// Args: (int32 port). Selects the libretro pad port the virtual pad drives:
// 0 = 1P, 1 = 2P. Arcade profiles only; everything else must stay on 0.
static napi_value SetPlayerPort(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t port = 0;
  if (argc > 0) {
    napi_get_value_int32(env, args[0], &port);
  }
  if (port < 0) port = 0;
  if (port > 1) port = 1;
  g_playerPort.store(port, std::memory_order_relaxed);
  GPRETRO_INFO("GPRETRO: player port = %{public}d", port);
  return nullptr;
}

// ---- netplay NAPI surface (§16.4) ---------------------------------------
// Minimal flat-JSON reader for the session config (machine-generated by the
// ArkTS bootstrap); mirrors the Android jni_bridge flat reader.
namespace {
size_t npFindKey(const std::string &j, const char *key) {
  const std::string needle = std::string("\"") + key + "\"";
  size_t p = j.find(needle);
  if (p == std::string::npos) return std::string::npos;
  p += needle.size();
  while (p < j.size() && (j[p] == ' ' || j[p] == '\t' || j[p] == '\n' ||
                          j[p] == '\r' || j[p] == ':')) { ++p; }
  return p;
}
bool npJsonString(const std::string &j, const char *key, std::string &out) {
  size_t p = npFindKey(j, key);
  if (p == std::string::npos || p >= j.size() || j[p] != '"') return false;
  ++p; std::string s;
  while (p < j.size() && j[p] != '"') {
    if (j[p] == '\\' && p + 1 < j.size()) { s.push_back(j[p + 1]); p += 2; }
    else s.push_back(j[p++]);
  }
  out = std::move(s); return true;
}
bool npJsonLong(const std::string &j, const char *key, long long &out) {
  size_t p = npFindKey(j, key);
  if (p == std::string::npos || p >= j.size()) return false;
  char *end = nullptr;
  const long long v = std::strtoll(j.c_str() + p, &end, 10);
  if (end == j.c_str() + p) return false;
  out = v; return true;
}
bool npJsonBool(const std::string &j, const char *key, bool dflt) {
  size_t p = npFindKey(j, key);
  if (p == std::string::npos || p + 4 > j.size()) return dflt;
  if (j.compare(p, 4, "true") == 0) return true;
  if (p + 5 <= j.size() && j.compare(p, 5, "false") == 0) return false;
  return dflt;
}
bool npJsonDouble(const std::string &j, const char *key, double &out) {
  size_t p = npFindKey(j, key);
  if (p == std::string::npos || p >= j.size()) return false;
  char *end = nullptr;
  const double v = std::strtod(j.c_str() + p, &end);
  if (end == j.c_str() + p) return false;
  out = v; return true;
}
bool npHexDecode(const std::string &hex, std::array<uint8_t, 32> &out) {
  if (hex.size() != 64) return false;
  auto nib = [](char c, int &v) -> bool {
    if (c >= '0' && c <= '9') { v = c - '0'; return true; }
    if (c >= 'a' && c <= 'f') { v = c - 'a' + 10; return true; }
    if (c >= 'A' && c <= 'F') { v = c - 'A' + 10; return true; }
    return false;
  };
  for (size_t i = 0; i < 32; ++i) {
    int hi = 0, lo = 0;
    if (!nib(hex[2 * i], hi) || !nib(hex[2 * i + 1], lo)) return false;
    out[i] = static_cast<uint8_t>((hi << 4) | lo);
  }
  return true;
}
constexpr int kNetStatCount = 28;
}  // namespace

static napi_value JsBool(napi_env env, bool v) {
  napi_value b; napi_get_boolean(env, v ? true : false, &b); return b;
}

// Serialize the current core state into g_netState0 (called once after frame 0,
// under g_coreMtx, so the host bootstrap can serve it as /state0).
static void CaptureNetState0() {
  g_netState0.clear();
  if (!g_coreReady || !g_core.retro_serialize || !g_core.retro_serialize_size) return;
  size_t sz = g_core.retro_serialize_size();
  if (sz == 0) return;
  g_netState0.resize(sz);
  if (!g_core.retro_serialize(g_netState0.data(), sz)) g_netState0.clear();
}

// Args: (bool frozen). Parks emulation (rendering continues, retro_run() does
// not) for the duration of the netplay bootstrap.
//
// Android runs loadState + nativeNetplayStart + nativeStartPacing inside a
// single runOnGlBlocking { } block, so the pair always enters lockstep from the
// same frame 0. The OHOS bootstrap runs on the ArkTS thread, so without this
// gate the render thread keeps emulating during /sram -> /state0 ->
// netplayStart. Those leaked frames are invisible for a state0 core (the load
// overwrites them) but permanent for a cold-boot core (MAME), and even for a
// state0 core the window between netplayLoadState0() and netplayStart() lets a
// frame through.
static napi_value NativeNetplayFreeze(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool on = true;
  if (argc > 0 && args[0] != nullptr) {
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, args[0], &t) == napi_ok) {
      if (t == napi_boolean) {
        bool b = false;
        if (napi_get_value_bool(env, args[0], &b) == napi_ok) on = b;
      } else if (t == napi_number) {
        double d = 1;
        if (napi_get_value_double(env, args[0], &d) == napi_ok) on = d != 0;
      }
    }
  }
  if (on) {
    g_emuFrozen.store(true, std::memory_order_relaxed);
    // Parity with Android host: GsRunner::attachNetplay runs exactly ONE
    // retro_run() between core-ready and the netplay session starting
    // (observed: "[GS-Netplay] attach hash=... runs=1", the GL renderer draws
    // a frame). For MAME (coldBoot) the guest does NOT load the host's frame-0
    // state — both peers cold-boot independently and must run the SAME number
    // of pre-lockstep retro_run()s or they desync from frame 0. This prime
    // frame is the OHOS side of that one run; it runs on the fresh boot state
    // and is the only retro_run() that can slip in while parked. The
    // g_emuFrozen gate prevents the render loop from leaking further frames
    // during the ArkTS bootstrap.
    if (g_netColdBoot && !g_netPrimeDone && g_coreReady && g_core.retro_run) {
      {
        std::lock_guard<std::mutex> lk(g_coreMtx);
        g_core.retro_run();
      }
      g_emuRunCount.fetch_add(1, std::memory_order_relaxed);
      g_netPrimeDone = true;
      GPRETRO_ERROR("[GS-Netplay] prime frame run=%{public}ld", g_emuRunCount.load());
    }
    // Host side: Android captures the frame-0 state BEFORE netplayStart /
    // startPacing. Here the pace loop used to capture it at frame 0, which can
    // never happen while parked, so capture it from the same point instead.
    if (g_netState0.empty()) {
      std::lock_guard<std::mutex> lk(g_coreMtx);
      CaptureNetState0();
    }
  } else {
    g_emuFrozen.store(false, std::memory_order_relaxed);
  }
  return nullptr;
}

// Args: (string cfgJson). Attaches a lockstep session; returns bool.
static napi_value NativeNetplayStart(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  char cfgJson[2048] = { 0 };
  if (argc > 0) napi_get_value_string_utf8(env, args[0], cfgJson, sizeof(cfgJson), nullptr);
  std::string j(cfgJson);

  np::NetConfig cfg;
  long long role = 0, peerPort = 0, localPort = 0, roomId = 0, initialD = 2;
  std::string peerIp, keyHex, saveKey;
  if (!npJsonLong(j, "role", role) || (role != 0 && role != 1)) return JsBool(env, false);
  if (!npJsonString(j, "peerIp", peerIp) || peerIp.empty()) return JsBool(env, false);
  if (!npJsonString(j, "sessionKeyHex", keyHex)) return JsBool(env, false);
  if (!npHexDecode(keyHex, cfg.key)) return JsBool(env, false);
  npJsonLong(j, "peerPort", peerPort);
  npJsonLong(j, "localPort", localPort);
  npJsonLong(j, "roomId", roomId);
  if (npJsonLong(j, "initialD", initialD) && (initialD < 1 || initialD > 2))
    return JsBool(env, false);
  if (peerPort < 0 || peerPort > 65535 || localPort < 0 || localPort > 65535)
    return JsBool(env, false);
  npJsonString(j, "saveKey", saveKey);

  cfg.role = role == 0 ? np::Role::Host : np::Role::Guest;
  cfg.peerIp = peerIp;
  cfg.peerPort = static_cast<uint16_t>(peerPort);
  cfg.localPort = static_cast<uint16_t>(localPort);
  cfg.roomId = static_cast<uint32_t>(roomId);
  cfg.initialD = static_cast<int>(initialD);
  cfg.adaptive = npJsonBool(j, "adaptive", true);
  double period = 0.0;
  if (npJsonDouble(j, "framePeriodSec", period) && period > 0.0) cfg.framePeriodSec = period;
  // Mirror Android GsRunner::attachNetplay(): `if (cfg.framePeriodSec <= 0.0)
  // cfg.framePeriodSec = 1.0 / fps_;`. Left at 0 the shared DelayCtrl falls
  // back to its own 1/59.61 default instead of this core's real frame period.
  if (cfg.framePeriodSec <= 0.0) {
    const double coreFps = g_coreFps.load(std::memory_order_relaxed);
    cfg.framePeriodSec = 1.0 / (coreFps > 1.0 ? coreFps : 60.0);
  }
  cfg.frame0 = 0;

  if (!saveKey.empty()) {
    std::string dir = g_appDir + "/saves";
    MkDirs(dir);
    g_netSramPath = dir + "/" + saveKey + ".sav";
  } else {
    g_netSramPath.clear();
  }

  if (g_net) { g_net->shutdown(); delete g_net; g_net = nullptr; }
  g_net = new np::GsNetplay();
  if (!g_net->start(cfg)) {
    delete g_net; g_net = nullptr;
    return JsBool(env, false);
  }
  g_netLocalPort = (role == 0) ? 0 : 1;
  g_netFrame = 0;
  g_netDeadLogged = false;
  g_netState0.clear();
  GPRETRO_INFO("GPRETRO: netplay start role=%{public}d peer=%{public}s:%{public}d",
               (int)cfg.role, peerIp.c_str(), (int)cfg.peerPort);
  // Determinism audit: `soloRuns` MUST be 0 — every retro_run() before the
  // session attaches shifts this machine's state away from the peer's frame 0.
  // `size` is the serialize buffer length (compare with the peer's).
  {
    size_t sz = 0;
    uint64_t hh = 0;
    {
      std::lock_guard<std::mutex> lk(g_coreMtx);
      if (g_coreReady && g_core.retro_serialize_size && g_core.retro_serialize) {
        sz = g_core.retro_serialize_size();
        std::vector<uint8_t> buf(sz);
        if (g_core.retro_serialize(buf.data(), sz)) {
          hh = 0xcbf29ce484222325ULL;
          for (uint8_t b : buf) { hh ^= b; hh *= 0x100000001b3ULL; }
        }
      }
    }
    GPRETRO_ERROR("GPRETRO: netplay attach soloRuns=%{public}ld serializeSize=%{public}zu frozen=%{public}d",
                  g_emuRunCount.load(), sz, (int)g_emuFrozen.load());
    // Same audit line Android logs ("[GS-Netplay] attach hash=...") so the two
    // frame-0 states can be compared directly across the two devices.
    GPRETRO_ERROR("[GS-Netplay] attach hash=%{public}016llx size=%{public}zu",
                  (unsigned long long)hh, sz);
  }

  // NOTE (parity): Android's GsRunner::attachNetplay() does NOT retro_reset()
  // the core — it only starts the UDP session; the pace thread then runs every
  // lockstep frame from the pristine post-load_game state (host) or from the
  // host's /state0 (guest). An earlier version reset here to undo the solo
  // frames the OHOS render loop used to run before ArkTS attached netplay.
  // Those frames are now prevented by the g_emuFrozen gate (netplayFreeze),
  // and the reset actively BROKE the guest: it ran AFTER netplayLoadState0()
  // and threw the host's frame-0 state away. Keep the two platforms identical:
  // no reset.
  return JsBool(env, true);
}

// Args: none. Sends CTRL_BYE and tears the session down (idempotent).
static napi_value NativeNetplayStop(napi_env, napi_callback_info) {
  // Tear the netplay object down and stop the emulator BEFORE freeing g_net.
  // The emulator pace thread (g_renderThread, reported as "pouch.gamepouch")
  // calls g_net->beginFrame()/endFrame() every frame; if g_net is deleted while
  // it is still alive it dereferences freed memory and SIGSEGVs the process
  // when the peer (e.g. Android) drops. Order:
  //   1. g_net->shutdown() -> sets running_=false, joins the gs-net recv thread
  //   2. StopEmulator()     -> sets g_running=false, joins the pace thread.
  //      With running_ already false the pace thread's beginFrame() returns
  //      Dead immediately, so the join never blocks up to the 10s drop timer.
  //   3. delete g_net
  if (g_net) {
    g_net->shutdown();
    StopEmulator();
    delete g_net;
    g_net = nullptr;
  }
  g_netState0.clear();
  return nullptr;
}

// Args: (int32 mask). Feeds the live local pad mask (published each frame).
static napi_value NativeNetplayLocalMask(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t mask = 0;
  if (argc > 0) napi_get_value_int32(env, args[0], &mask);
  g_netLocalMask_.store((uint16_t)(mask & 0xFFFF));
  return nullptr;
}

// Args: none. Host opens the START gate (announces CTRL_START).
static napi_value NativeNetplayNotifyStart(napi_env, napi_callback_info) {
  if (g_net) g_net->notifyStart();
  return nullptr;
}

// Args: (bool paused). Local pause intent -> CTRL_PAUSE/RESUME.
static napi_value NativeNetplayNotifyPaused(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool paused = false;
  if (argc > 0) { napi_value b; if (napi_get_value_bool(env, args[0], &paused) == napi_ok) paused = !!paused; }
  if (g_net) g_net->setLocalPaused(paused);
  return nullptr;
}

// Args: none. Returns a 28-element double[] mirroring NativeBridge.NetplayStats.
static napi_value NativeNetplayStats(napi_env env, napi_callback_info) {
  napi_value arr;
  if (napi_create_array_with_length(env, kNetStatCount, &arr) != napi_ok) return nullptr;
  double v[kNetStatCount] = { 0 };
  if (g_net) {
    const np::NetStats s = g_net->stats();
    v[0] = (double)s.state; v[1] = (double)s.d; v[2] = s.started ? 1.0 : 0.0;
    v[3] = s.rttMinMs; v[4] = s.rttP50Ms; v[5] = s.rttP95Ms; v[6] = s.rttP99Ms;
    v[7] = s.leadP50Ms; v[8] = s.leadP95Ms;
    v[9] = (double)s.framesAdvanced; v[10] = (double)s.lateFrames; v[11] = (double)s.frozenFrames;
    v[12] = (double)s.packetsIn; v[13] = (double)s.packetsOut;
    v[14] = (double)s.bytesIn; v[15] = (double)s.bytesOut;
    v[16] = (double)s.redundantSends; v[17] = s.effFps;
    v[18] = (double)s.rejBadLen; v[19] = (double)s.rejBadMagic; v[20] = (double)s.rejBadVersion;
    v[21] = (double)s.rejBadTag; v[22] = (double)s.replayDup; v[23] = (double)s.replayOld;
    v[24] = (double)s.foreignPackets; v[25] = (double)s.dUpgrades; v[26] = (double)s.dDowngrades;
    v[27] = (double)s.blockedMsTotal;
  }
  for (int i = 0; i < kNetStatCount; ++i) {
    napi_value d; napi_create_double(env, v[i], &d);
    napi_set_element(env, arr, i, d);
  }
  return arr;
}

// Args: none. FNV-1a64 hex of the serialized core state (determinism check).
static napi_value NativeNetplayStateHash(napi_env env, napi_callback_info) {
  std::vector<uint8_t> buf;
  {
    std::lock_guard<std::mutex> lk(g_coreMtx);
    if (!g_coreReady || !g_core.retro_serialize_size || !g_core.retro_serialize) return nullptr;
    size_t sz = g_core.retro_serialize_size();
    if (sz == 0) return nullptr;
    buf.resize(sz);
    if (!g_core.retro_serialize(buf.data(), sz)) return nullptr;
  }
  uint64_t h = 0xcbf29ce484222325ULL;
  for (uint8_t b : buf) { h ^= b; h *= 0x100000001b3ULL; }
  char hex[17];
  snprintf(hex, sizeof(hex), "%016llx", (unsigned long long)h);
  napi_value s; napi_create_string_utf8(env, hex, strlen(hex), &s);
  return s;
}

// Mirror of Android GsRunner::netCheckpointHash (§diagnostics): arm the
// per-entry serialize dump (files/mame_entries.log) at a handful of early
// frames and emit a per-frame FNV-1a64 state hash so a cross-device diff
// can pinpoint the exact diverging MAME save region. Serializes under the
// core mutex, identical to NativeNetplayStateHash() above.
static void OhosNetCheckpoint() {
  if (!g_net) return;
  static const unsigned DUMP_FRAMES[] = {1, 120, 600, 1200, 1800, 2400};
  const unsigned f = (unsigned)g_netFrame;
  bool needDump = false;
  for (unsigned df : DUMP_FRAMES) {
    if (f == df) { needDump = true; setenv("GP_NETPLAY_DUMP_TAG", std::to_string(f).c_str(), 1); break; }
  }
  if (!needDump && f % 600 != 0) return;  // 诊断块仅在 checkpoint 帧运行，正常帧跳过
  // Mirror Android GsRunner::netplayStateHash(): acquire g_coreMtx here
  // because the caller (EmuLoop pacing loop) NO LONGER holds it — retro_run()
  // alone is protected by g_coreMtx; beginFrame/endFrame/OhosNetCheckpoint all
  // run lock-free at the outer scope.
  std::vector<uint8_t> buf;
  {
    std::lock_guard<std::mutex> lk(g_coreMtx);
    if (!g_coreReady || !g_core.retro_serialize_size || !g_core.retro_serialize) {
      // Logged at ERROR: hilog flow-control silently DROPS info lines when a
      // process floods the buffer, and a missing checkpoint is indistinguishable
      // from a divergence when it never reaches the log at all.
      GPRETRO_ERROR("[GS-Netplay] checkpoint f=%{public}u UNAVAILABLE ready=%{public}d", f, (int)g_coreReady);
      return;
    }
    size_t sz = g_core.retro_serialize_size();
    if (sz == 0) {
      GPRETRO_ERROR("[GS-Netplay] checkpoint f=%{public}u SIZE0", f);
      return;
    }
    buf.resize(sz);
    if (!g_core.retro_serialize(buf.data(), sz)) {
      GPRETRO_ERROR("[GS-Netplay] checkpoint f=%{public}u SERIALIZE_FAILED size=%{public}zu", f, sz);
      return;
    }
  }
  uint64_t h = 0xcbf29ce484222325ULL;
  for (uint8_t b : buf) { h ^= b; h *= 0x100000001b3ULL; }
  unsetenv("GP_NETPLAY_DUMP_TAG");
  GPRETRO_ERROR("[GS-Netplay] checkpoint f=%{public}u hash=%{public}016llx runs=%{public}ld", f,
                (unsigned long long)h, g_emuRunCount.load());
}

// Args: none. Flushes battery RAM to <appDir>/saves/<saveKey>.sav (atomic).
static napi_value NativeNetplayFlushSram(napi_env env, napi_callback_info) {
  bool ok = false;
  if (!g_netSramPath.empty() && g_core.retro_get_memory_data && g_core.retro_get_memory_size) {
    void *p = g_core.retro_get_memory_data(0 /*RETRO_MEMORY_SAVE_RAM*/);
    size_t sz = g_core.retro_get_memory_size(0);
    if (p && sz > 0) {
      std::string tmp = g_netSramPath + ".np-tmp";
      FILE *f = fopen(tmp.c_str(), "wb");
      if (f) {
        fwrite(p, 1, sz, f);
        fclose(f);
        ok = (rename(tmp.c_str(), g_netSramPath.c_str()) == 0);
        if (!ok) remove(tmp.c_str());
      }
    }
  }
  return JsBool(env, ok);
}

// Args: none. Returns the host frame-0 serialized state (ArrayBuffer) or null.
static napi_value NativeNetplayGetState0(napi_env env, napi_callback_info) {
  if (g_netState0.empty()) return nullptr;
  void *ptr = nullptr;
  napi_value ab;
  // NOTE: OHOS NAPI orders args as (env, length, void** data, napi_value* result).
  if (napi_create_arraybuffer(env, g_netState0.size(), &ptr, &ab) != napi_ok) return nullptr;
  memcpy(ptr, g_netState0.data(), g_netState0.size());
  return ab;
}

// Args: (ArrayBuffer state0). Unserializes the guest's starting core state,
// matching the host's captured frame 0 so both machines advance identically.
static napi_value NativeNetplayLoadState0(napi_env env, napi_callback_info info) {
  size_t argc = 1; napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool ok = false;
  if (argc > 0) {
    void *ptr = nullptr; size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[0], &ptr, &len) == napi_ok && ptr && len > 0) {
      std::lock_guard<std::mutex> lk(g_coreMtx);
      if (g_coreReady && g_core.retro_unserialize) ok = g_core.retro_unserialize(ptr, len);
    }
  }
  return JsBool(env, ok);
}

// Args: (ArrayBuffer sram). Injects the host-provided battery RAM into the core.
static napi_value NativeNetplayLoadSram(napi_env env, napi_callback_info info) {
  size_t argc = 1; napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool ok = false;
  if (argc > 0) {
    void *ptr = nullptr; size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[0], &ptr, &len) == napi_ok && ptr && len > 0) {
      std::lock_guard<std::mutex> lk(g_coreMtx);
      if (g_core.retro_get_memory_data && g_core.retro_get_memory_size) {
        void *d = g_core.retro_get_memory_data(0 /*SAVE_RAM*/);
        size_t cap = g_core.retro_get_memory_size(0);
        if (d && cap >= len) { memcpy(d, ptr, len); ok = true; }
      }
    }
  }
  return JsBool(env, ok);
}

// Menu: reset the running game.
static napi_value ResetEmu(napi_env env, napi_callback_info info) {
  if (g_coreReady && g_core.retro_reset) {
    std::lock_guard<std::mutex> lk(g_coreMtx);
    g_core.retro_reset();
  }
  return nullptr;
}

// Menu: fast-forward multiplier (1..8).
static napi_value SetSpeed(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t n = 1;
  if (argc > 0) {
    napi_get_value_int32(env, args[0], &n);
  }
  if (n < 1) n = 1;
  if (n > 8) n = 8;
  g_speed.store(n);
  return nullptr;
}

// Menu: mute/unmute audio (drives the "加速时同步音频" setting — when the toggle
// is OFF we silence the renderer during fast-forward).
static napi_value SetAudioMuted(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool muted = false;
  if (argc > 0) {
    napi_get_value_bool(env, args[0], &muted);
  }
  g_audioMuted.store(muted);
  return nullptr;
}

// Forward decls (defined after GetFps) so the compat wrappers below can call them.
static napi_value SaveStateSlot(napi_env env, napi_callback_info info);
static napi_value LoadStateSlot(napi_env env, napi_callback_info info);

// Menu: serialize the current game into on-disk slot 0 (kept for compatibility).
static napi_value SaveState(napi_env env, napi_callback_info info) {
  return SaveStateSlot(env, info);
}

// Menu: restore the game from on-disk slot 0 (kept for compatibility).
static napi_value LoadState(napi_env env, napi_callback_info info) {
  return LoadStateSlot(env, info);
}

// HUD: last measured presented-FPS (0 until the first 0.5 s window closes).
static napi_value GetFps(napi_env env, napi_callback_info info) {
  napi_value out = nullptr;
  napi_create_double(env, g_fpsOut.load(), &out);
  return out;
}

// Absolute path of the ROM directory (== app files dir / roms).
static napi_value GetFilesDir(napi_env env, napi_callback_info info) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, g_filesDir.c_str(), NAPI_AUTO_LENGTH, &out);
  return out;
}

// Absolute path of the saves directory (== app files dir / saves) — the same
// place battery RAM lives. Mirrors Android's `filesDir/saves/` so ArkTS can
// locate the per-game CRC-keyed save-state slot thumbnails / meta files.
static napi_value GetSavesDir(napi_env env, napi_callback_info info) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, (g_appDir + "/saves").c_str(), NAPI_AUTO_LENGTH, &out);
  return out;
}

// Save-state slots are keyed by the loaded ROM's CRC (== Android's
// `$saveKey.slot$i.state`), so each game keeps its own 3 slots and the load
// dialog never cross-loads another game's state. (g_soloSaveKey is the CRC for
// solo play; netplay falls back to "shared" since it manages state itself.)
static std::string SlotPrefix() {
  const std::string& key = g_soloSaveKey.empty() ? std::string("shared") : g_soloSaveKey;
  return g_appDir + "/saves/" + key + ".slot";
}
static std::string StatePath(int slot) {
  return SlotPrefix() + std::to_string(slot) + ".state";
}
static std::string ThumbPath(int slot) {
  return SlotPrefix() + std::to_string(slot) + ".rgba";
}
static std::string MetaPath(int slot) {
  return SlotPrefix() + std::to_string(slot) + ".meta";
}

// Serialize the running game into on-disk slot 0..2 (Android has 3 slots).
// Also writes a downscaled raw-RGBA thumbnail so the load dialog can preview it.
static napi_value SaveStateSlot(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t slot = 0;
  if (argc > 0) napi_get_value_int32(env, args[0], &slot);
  if (slot < 0) slot = 0;
  if (slot > 2) slot = 2;
  bool ok = false;
  if (g_coreReady && g_core.retro_serialize && g_core.retro_serialize_size) {
    std::lock_guard<std::mutex> lk(g_coreMtx);
    size_t sz = g_core.retro_serialize_size();
    if (sz > 0) {
      std::vector<uint8_t> buf(sz);
      ok = g_core.retro_serialize(buf.data(), sz);
      if (ok) {
        FILE* f = fopen(StatePath(slot).c_str(), "wb");
        if (f) { fwrite(buf.data(), 1, sz, f); fclose(f); }
        else ok = false;
        if (ok && g_texAllocated && g_texW > 0 && g_texH > 0) {
          int tw = g_texW / 3, th = g_texH / 3;
          if (tw < 1) tw = 1;
          if (th < 1) th = 1;
          std::vector<uint8_t> small((size_t)tw * th * 4);
          for (int y = 0; y < th; y++) {
            for (int x = 0; x < tw; x++) {
              int sx = x * 3, sy = y * 3;
              const uint8_t* s = g_rgba.data() + ((size_t)sy * g_texW + sx) * 4;
              uint8_t* d = small.data() + ((size_t)y * tw + x) * 4;
              d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
            }
          }
          FILE* tf = fopen(ThumbPath(slot).c_str(), "wb");
          if (tf) { fwrite(small.data(), 1, small.size(), tf); fclose(tf); }
          FILE* mf = fopen(MetaPath(slot).c_str(), "wb");
          if (mf) { fprintf(mf, "%d %d", tw, th); fclose(mf); }
        }
      }
    }
  }
  napi_value r = nullptr;
  napi_get_boolean(env, ok, &r);
  return r;
}

// Restore on-disk slot 0..2. Returns bool.
static napi_value LoadStateSlot(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t slot = 0;
  if (argc > 0) napi_get_value_int32(env, args[0], &slot);
  if (slot < 0) slot = 0;
  if (slot > 2) slot = 2;
  bool ok = false;
  FILE* f = fopen(StatePath(slot).c_str(), "rb");
  if (f) {
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz > 0) {
      std::vector<uint8_t> buf(sz);
      if (fread(buf.data(), 1, sz, f) == (size_t)sz &&
          g_coreReady && g_core.retro_unserialize) {
        std::lock_guard<std::mutex> lk(g_coreMtx);
        ok = g_core.retro_unserialize(buf.data(), (size_t)sz);
      }
    }
    fclose(f);
  }
  napi_value r = nullptr;
  napi_get_boolean(env, ok, &r);
  return r;
}

// JSON list of the 3 slots: [{slot,exists,time,w,h}, ...] for the load dialog.
static napi_value ListSaves(napi_env env, napi_callback_info info) {
  std::string json = "[";
  for (int slot = 0; slot < 3; slot++) {
    struct stat st;
    bool exists = (stat(StatePath(slot).c_str(), &st) == 0);
    json += "{\"slot\":" + std::to_string(slot) + ",\"exists\":" + (exists ? "true" : "false");
    if (exists) {
      json += ",\"time\":" + std::to_string((long long)st.st_mtime);
      struct stat mst;
      if (stat(MetaPath(slot).c_str(), &mst) == 0) {
        FILE* mf = fopen(MetaPath(slot).c_str(), "rb");
        int w = 0, h = 0;
        if (mf) { fscanf(mf, "%d %d", &w, &h); fclose(mf); }
        json += ",\"w\":" + std::to_string(w) + ",\"h\":" + std::to_string(h);
      }
    }
    json += "}";
    if (slot < 2) json += ",";
  }
  json += "]";
  napi_value out = nullptr;
  napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &out);
  return out;
}

// IEEE 802.3 CRC32 (matches Android/PC tools; no header stripping for NES).
static uint32_t Crc32File(const std::string& path) {
  static uint32_t table[256];
  static bool inited = false;
  if (!inited) {
    for (uint32_t i = 0; i < 256; i++) {
      uint32_t c = i;
      for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
      table[i] = c;
    }
    inited = true;
  }
  uint32_t crc = 0xFFFFFFFFu;
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return 0;
  unsigned char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ buf[i]) & 0xff] ^ (crc >> 8);
  }
  fclose(f);
  return crc ^ 0xFFFFFFFFu;
}

// Per-game save/cheat key: the CRC32 recorded in rom_index.json for the loaded
// ROM's relativePath. Mirrors Android's CheatStore.crcKey(filesDir, romRel) so
// the same game yields the same key on every device (saves/cheats line up
// across dumps), instead of Crc32File() which depends on on-disk bytes.
static std::string SoloSaveCrc() {
  std::vector<std::string> candidates;
  if (!g_romPath.empty()) {
    candidates.push_back(g_romPath);
    if (!g_appDir.empty() && g_romPath.size() > g_appDir.size() + 1 &&
        g_romPath.compare(0, g_appDir.size(), g_appDir) == 0) {
      candidates.push_back(g_romPath.substr(g_appDir.size() + 1));
    }
  }
  std::string json;
  FILE* f = fopen((g_appDir + "/rom_index.json").c_str(), "rb");
  if (f) {
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) json.append(buf, n);
    fclose(f);
  }
  // Scan every "relativePath" entry. The index is pretty-printed JSON with a
  // SPACE after the colon, so a rigid `"relativePath":"..."` needle would never
  // match and we'd wrongly fall back to the disk CRC (a different value across
  // dumps) — that is exactly what made imported saves/thumbnails invisible.
  // Match the entry whose relativePath equals one of our candidates, then read
  // the following "crc32".
  const std::string relKey = "\"relativePath\"";
  const std::string crcKey = "\"crc32\"";
  size_t pos = 0;
  while (true) {
    size_t kpos = json.find(relKey, pos);
    if (kpos == std::string::npos) break;
    size_t vstart = json.find('"', kpos + relKey.size());
    if (vstart == std::string::npos) break;
    vstart++;
    size_t vend = json.find('"', vstart);
    if (vend == std::string::npos) break;
    std::string rel = json.substr(vstart, vend - vstart);
    bool match = false;
    for (const auto& c : candidates) {
      if (c == rel) { match = true; break; }
    }
    pos = vend + 1;
    if (!match) continue;
    size_t cpos = json.find(crcKey, vend);
    if (cpos == std::string::npos) break;
    cpos += crcKey.size();
    while (cpos < json.size() && json[cpos] != '-' &&
           (json[cpos] < '0' || json[cpos] > '9')) cpos++;
    bool neg = false;
    if (cpos < json.size() && json[cpos] == '-') { neg = true; cpos++; }
    long long v = 0;
    while (cpos < json.size() && json[cpos] >= '0' && json[cpos] <= '9') {
      v = v * 10 + (json[cpos] - '0'); cpos++;
    }
    uint32_t u = (uint32_t)(neg ? -v : v);
    char hex[16];
    snprintf(hex, sizeof(hex), "%08X", u);
    return std::string(hex);
  }
  // Unindexed / sideloaded ROM: Android falls back to the file base name; keep
  // the historical disk-CRC behaviour to avoid regressing those local saves.
  char hex[16];
  snprintf(hex, sizeof(hex), "%08X", Crc32File(g_romPath));
  return std::string(hex);
}

// CRC32 (8-hex uppercase) of the currently loaded ROM. Must equal the key the
// native save paths use (g_soloSaveKey, resolved at load from the rom_index.json
// crc32 — mirroring Android's CheatStore.crcKey). listSaves/deleteSave/thumbnail
// all build paths from this value, so returning anything else (e.g. a freshly
// recomputed disk CRC) would make delete target a different CRC than the list,
// silently no-op'ing and leaving the dialog stale until page re-entry.
static napi_value GetRomCrc(napi_env env, napi_callback_info info) {
  std::string key = g_soloSaveKey.empty() ? SoloSaveCrc() : g_soloSaveKey;
  char hex[16];
  snprintf(hex, sizeof(hex), "%s", key.c_str());
  napi_value out = nullptr;
  napi_create_string_utf8(env, hex, NAPI_AUTO_LENGTH, &out);
  return out;
}

// Return the cheats.json array for the loaded ROM's CRC as a JSON string (or "[]").
// Keeps the dynamic-key lookup on the C++ side so ArkTS only parses a concrete
// CheatInfo[] (ArkTS forbids index signatures / ESObject for JSON dicts).
//
// Cheats live in <appRoot>/library/ (sibling of /roms/), but g_filesDir is the
// roms dir, so the old path (<appRoot>/roms/library/cheats.json) never matched the
// Dart/PC-written store. Use g_appDir (the true app root) instead. Mirror Android
// CheatStore.load: the local `cheats.json` wins, and the LAN-sync
// `cloud_cheats.json` snapshot is the fallback — so PC-downloaded cheats (which
// land in cloud_cheats.json) actually show up. Fixes the OHOS "无法启用金手指" /
// "本游戏暂无金手指" regression (switch + choice cheats both flow through here).
static std::string CheatsForCrc(const std::string& path, const char* key) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return std::string();
  std::string content;
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) content.append(buf, n);
  fclose(f);
  size_t pos = content.find(key);
  if (pos == std::string::npos) return std::string();
  size_t b = content.find('[', pos);
  if (b == std::string::npos) return std::string();
  int depth = 0;
  size_t e = b;
  for (; e < content.size(); e++) {
    if (content[e] == '[') depth++;
    else if (content[e] == ']') { depth--; if (depth == 0) break; }
  }
  if (e >= content.size()) return std::string();
  return content.substr(b, e - b + 1);
}

static napi_value GetCheats(napi_env env, napi_callback_info info) {
  const char* empty = "[]";
  napi_value out = nullptr;
  char key[16];
  snprintf(key, sizeof(key), "\"%08X\"", Crc32File(g_romPath));
  std::string base = g_appDir + "/library/";
  // Local store wins; cloud sync snapshot is the fallback (Android parity).
  std::string arr = CheatsForCrc(base + "cheats.json", key);
  if (arr.empty()) arr = CheatsForCrc(base + "cloud_cheats.json", key);
  napi_create_string_utf8(env, arr.empty() ? empty : arr.c_str(),
                          NAPI_AUTO_LENGTH, &out);
  return out;
}

// Apply cheats. arg0 = JSON string: array of [code, enabled] pairs. Each enabled
// cheat's code may hold multiple newline-separated lines; every line becomes its
// own retro_set_cheat index (mirrors RetroArch's cheat manager). Cores without a
// cheat interface return false. Minimal JSON parse (cheat codes never contain '"').
static napi_value SetCheats(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = { nullptr };
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (!g_core.retro_cheat_set || !g_core.retro_cheat_reset) {
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
  }
  char buf[65536] = { 0 };
  size_t len = 0;
  napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);
  std::string s(buf);
  g_core.retro_cheat_reset();
  unsigned idx = 0;
  size_t pos = 0;
  while (true) {
    size_t open = s.find('[', pos);
    if (open == std::string::npos) break;
    size_t q1 = s.find('"', open);
    if (q1 == std::string::npos) break;
    size_t q2 = s.find('"', q1 + 1);
    if (q2 == std::string::npos) break;
    std::string code = s.substr(q1 + 1, q2 - q1 - 1);
    size_t after = s.find_first_of("tf", q2);
    if (after == std::string::npos) break;
    bool enabled = (s[after] == 't');
    if (enabled && !code.empty()) {
      size_t start = 0;
      while (start <= code.size()) {
        size_t nl = code.find('\n', start);
        if (nl == std::string::npos) nl = code.size();
        std::string line = code.substr(start, nl - start);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty()) {
          g_core.retro_cheat_set(idx, true, line.c_str());
          idx++;
        }
        if (nl == code.size()) break;
        start = nl + 1;
      }
    }
    pos = after + 1;
  }
  napi_value r = nullptr;
  napi_get_boolean(env, true, &r);
  return r;
}

// Args: none. Mirrors Android's `npCoreReady` gate: true once the core has
// finished loading (retro_load_game done + first geometry probe), false while
// it is still booting or unloaded.
//
// The ArkTS bootstrap MUST wait for this before calling netplayStart(). Android
// blocks on npCoreReady.await(35s) on both host and guest, so every lockstep
// frame it runs starts from the pristine post-load_game state. OHOS called
// netplayStart() straight after startEmulator() (which returns immediately
// without waiting for LoadCore), so the determinism retro_reset() inside
// NativeNetplayStart() — guarded by g_coreReady — silently no-oped and the
// guest entered lockstep from a state the Android host could never match.
static napi_value NativeIsCoreReady(napi_env env, napi_callback_info) {
  return JsBool(env, g_coreReady);
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  GPRETRO_INFO("GPRETRO: NAPI module init (libgpretro.so loaded)");

  napi_value exportInstance = nullptr;
  napi_status st = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance);
  if (st == napi_ok && exportInstance != nullptr) {
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) == napi_ok &&
        nativeXComponent != nullptr) {
      g_component = nativeXComponent;
      OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xcCallback);
      GPRETRO_INFO("GPRETRO: RegisterCallback (bound in Init)");
    } else {
      GPRETRO_WARN("GPRETRO: napi_unwrap returned null XComponent");
    }
  } else {
    GPRETRO_WARN("GPRETRO: OH_NATIVE_XCOMPONENT_OBJ not present");
  }

  napi_property_descriptor desc[] = {
      { "startEmulator", nullptr, StartEmulator, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "stopEmulator", nullptr, StopEmulatorNapi, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setEmulatorTarget", nullptr, SetEmulatorTarget, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setInput", nullptr, SetInput, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setPlayerPort", nullptr, SetPlayerPort, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "resetEmu", nullptr, ResetEmu, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setSpeed", nullptr, SetSpeed, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setAudioMuted", nullptr, SetAudioMuted, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getLoadError", nullptr, GetLoadError, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "saveState", nullptr, SaveState, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "loadState", nullptr, LoadState, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getFps", nullptr, GetFps, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getFilesDir", nullptr, GetFilesDir, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getSavesDir", nullptr, GetSavesDir, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "saveStateSlot", nullptr, SaveStateSlot, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "loadStateSlot", nullptr, LoadStateSlot, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "listSaves", nullptr, ListSaves, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getRomCrc", nullptr, GetRomCrc, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "getCheats", nullptr, GetCheats, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "setCheats", nullptr, SetCheats, nullptr, nullptr, nullptr, napi_default, nullptr },
      // netplay (§16.4 delay-based lockstep) — mirrors Android NativeBridge.
      { "netplayStart", nullptr, NativeNetplayStart, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayStop", nullptr, NativeNetplayStop, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayLocalMask", nullptr, NativeNetplayLocalMask, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayNotifyStart", nullptr, NativeNetplayNotifyStart, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayNotifyPaused", nullptr, NativeNetplayNotifyPaused, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayStats", nullptr, NativeNetplayStats, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayStateHash", nullptr, NativeNetplayStateHash, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayFlushSram", nullptr, NativeNetplayFlushSram, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayGetState0", nullptr, NativeNetplayGetState0, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayLoadState0", nullptr, NativeNetplayLoadState0, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayLoadSram", nullptr, NativeNetplayLoadSram, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "netplayFreeze", nullptr, NativeNetplayFreeze, nullptr, nullptr, nullptr, napi_default, nullptr },
      { "isCoreReady", nullptr, NativeIsCoreReady, nullptr, nullptr, nullptr, napi_default, nullptr },
  };
  // Register EVERY entry in desc[]. The count MUST be derived from the array,
  // not hard-coded: the literal used to lag the array by one, so the last
  // binding (netplayLoadSram, and now isCoreReady) was silently never
  // registered — ArkTS then got `undefined` for it and every call threw.
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "gpretro",
    .nm_priv = nullptr,
};

extern "C" __attribute__((constructor)) void RegisterGpretroModule() {
  napi_module_register(&g_module);
}
