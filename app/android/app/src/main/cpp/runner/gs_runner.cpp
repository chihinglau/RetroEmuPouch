#include "gs_runner.h"

#include <aaudio/AAudio.h>
#include <android/api-level.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cerrno>
#include <cstdarg>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>
#include <fstream>
#include <numeric>
#include <sstream>
#include <unistd.h>
#include <filesystem>
#include <system_error>
#include <sys/resource.h>
#include <sys/prctl.h>
#include <sched.h>
#include <time.h>

GsRunner *GsRunner::s_self = nullptr;

#include <android/log.h>

static double monoNow() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

GsRunner::GsRunner() { ring_.resize(RING_CAP); }

GsRunner::~GsRunner() { dispose(); }

void GsRunner::log(const char *fmt, ...) {
    // Build the formatted line once so we can mirror it to logcat AND the
    // per-run /data/data/<pkg>/files/logs/run-*.log file. The file is the
    // durable record (logcat is volatile across reboots); the logcat mirror
    // exists so release builds — where run-as is denied — still surface the
    // same diagnostics through `adb logcat -s GS-runner:V`. ~2 KB.
    char buf[2048];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(buf)) n = sizeof(buf) - 1;
    buf[n] = '\n';
    size_t len = (size_t)n + 1;
    __android_log_write(ANDROID_LOG_INFO, "GS-runner", buf);
    if (logFile_) {
        fwrite(buf, 1, len, logFile_);
        fflush(logFile_);
    }
}

void GsRunner::onLog(enum retro_log_level level, const char *fmt, ...) {
    GsRunner *s = s_self;
    if (!s || !s->logFile_ || !fmt) return;
    const char *tag = "CORE";
    if (level == RETRO_LOG_ERROR) tag = "ERR ";
    else if (level == RETRO_LOG_WARN) tag = "WARN";
    fprintf(s->logFile_, "[%s] ", tag);
    va_list ap; va_start(ap, fmt);
    vfprintf(s->logFile_, fmt, ap);
    va_end(ap);
    fputc('\n', s->logFile_);
    fflush(s->logFile_);
}

// Ordinary variadic function (clang cannot convert a lambda to a variadic
// function pointer) matching retro_log_printf_t.
static void gsCoreLog(retro_log_level level, const char *fmt, ...) {
    GsRunner *x = GsRunner::instance();
    if (!x || !fmt) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(buf)) n = sizeof(buf) - 1;
    int prio = ANDROID_LOG_INFO;
    if (level == RETRO_LOG_ERROR) prio = ANDROID_LOG_ERROR;
    else if (level == RETRO_LOG_WARN) prio = ANDROID_LOG_WARN;
    char line[2200];
    int hn = snprintf(line, sizeof(line), "[core] %.*s\n", n, buf);
    if (hn < 0) return;
    if ((size_t)hn >= sizeof(line)) hn = sizeof(line) - 1;
    __android_log_write(prio, "GS-core", line);
    if (x->hasLogFile()) {
        FILE *f = x->logFile();
        fwrite(line, 1, (size_t)hn, f);
        fflush(f);
    }
}

bool GsRunner::onEnvironment(unsigned cmd, void *data) {
    GsRunner *s = s_self;
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
            auto *iface = static_cast<retro_log_callback *>(data);
            iface->log = gsCoreLog;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (!s) return false;
            // Netplay: hand the core a pristine per-process directory so it
            // cannot restore this phone's own bookkeeping/cfg (see npSaveDir_).
            *static_cast<const char **>(data) =
                (s->netplayColdBoot_ && !s->npSaveDir_.empty())
                    ? s->npSaveDir_.c_str()
                    : s->saveDir_.c_str();
            return true;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if (!s) return false;
            *static_cast<const char **>(data) = s->systemDir_.c_str();
            return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            if (!s) return false;
            s->pixFmt_ = *static_cast<const retro_pixel_format *>(data);
            return s->pixFmt_ == RETRO_PIXEL_FORMAT_XRGB8888 ||
                   s->pixFmt_ == RETRO_PIXEL_FORMAT_RGB565 ||
                   s->pixFmt_ == RETRO_PIXEL_FORMAT_0RGB1555;
        }
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            if (!s) return false;
            // retro_game_geometry carries dimensions only; fps/rate live in
            // retro_system_timing (read once via retro_get_system_av_info).
            const auto *g = static_cast<const retro_game_geometry *>(data);
            s->fbW_ = g->base_width;
            s->fbH_ = g->base_height;
            s->aspectRatio_ = g->aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
            // Advertised by the core; the runner has no overlay mapping UI,
            // so the table is accepted and ignored.
            return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            // The runner always owns a persistent GL-side texture and can
            // accept a duplicated previous frame (data == nullptr). Several
            // cores (gambatte/picodrive/mgba) hard-require a true answer.
            if (data) *static_cast<bool *>(data) = true;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            auto *var = static_cast<retro_variable *>(data);
            // Region override chosen from the cart header in init():
            // TW-MMC3 clone boards (mappers 198/199) use Dendy timing,
            // true PAL ROMs use PAL, everything else stays Auto.
            // FCEUmm-only; other cores use their built-in defaults.
            if (s && s->coreId_ == "fceumm" && var &&
                strcmp(var->key, "fceumm_region") == 0) {
                var->value = s->forcedRegion_.empty()
                                 ? "Auto"
                                 : const_cast<char *>(s->forcedRegion_.c_str());
                return true;
            }
            // MAME: force the plain "-rom" media type. With the default
            // (unset) media type the core builds the command line as
            // "<system-name> <media> <game>", where <system-name> is the
            // content's PARENT directory (rom_cache/mame) — neither is a
            // valid MAME system, so boot fails with "Unknown system".
            // "-rom" makes it boot the arcade driver derived from the file
            // name ("1943") directly, which is what we always want for the
            // store's CPS1/CPS2/NeoGeo catalog.
            if (s && s->coreId_ == "mame" && var &&
                strcmp(var->key, "mame_media_type") == 0) {
                var->value = "rom";
                return true;
            }
            return false; // other options: use core defaults
        }
        default:
            return false;
    }
}

static inline void packPixel(uint32_t v, retro_pixel_format fmt, uint8_t *dst) {
    if (fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
        // memory layout on LE is B,G,R,X -> emit R,G,B,A
        dst[0] = (v >> 16) & 0xFF;
        dst[1] = (v >> 8) & 0xFF;
        dst[2] = v & 0xFF;
        dst[3] = 0xFF;
    } else if (fmt == RETRO_PIXEL_FORMAT_RGB565) {
        uint32_t r = (v >> 11) & 0x1F, g = (v >> 5) & 0x3F, b = v & 0x1F;
        dst[0] = (r << 3) | (r >> 2);
        dst[1] = (g << 2) | (g >> 4);
        dst[2] = (b << 3) | (b >> 2);
        dst[3] = 0xFF;
    } else { // 0RGB1555
        uint32_t r = (v >> 10) & 0x1F, g = (v >> 5) & 0x1F, b = v & 0x1F;
        dst[0] = (r << 3) | (r >> 2);
        dst[1] = (g << 3) | (g >> 2);
        dst[2] = (b << 3) | (b >> 2);
        dst[3] = 0xFF;
    }
}

void GsRunner::onVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    GsRunner *s = s_self;
    if (!s || !s->pixels_ || !data) return; // dupe frame / not ready
    if ((int)width > MAX_W || (int)height > MAX_H) return;
    s->fbW_ = width;
    s->fbH_ = height;
    auto *dst = reinterpret_cast<uint8_t *>(s->pixels_);
    const auto *src = static_cast<const uint8_t *>(data);
    for (unsigned y = 0; y < height; ++y) {
        if (s->pixFmt_ == RETRO_PIXEL_FORMAT_XRGB8888) {
            const auto *row = reinterpret_cast<const uint32_t *>(src + y * pitch);
            auto *out = dst + y * width * 4;
            for (unsigned x = 0; x < width; ++x) packPixel(row[x], s->pixFmt_, out + x * 4);
        } else {
            const auto *row = reinterpret_cast<const uint16_t *>(src + y * pitch);
            auto *out = dst + y * width * 4;
            for (unsigned x = 0; x < width; ++x) packPixel(row[x], s->pixFmt_, out + x * 4);
        }
    }
}

void GsRunner::pushSamples(const int16_t *data, uint32_t need) {
    // need = number of interleaved stereo int16 values.
    uint32_t w = wPos_.load(std::memory_order_relaxed);
    uint32_t r = rPos_.load(std::memory_order_acquire);
    uint32_t used = w - r;
    uint32_t avail = RING_CAP - used;
    if (avail < need) {
        xruns_.fetch_add(1, std::memory_order_relaxed);
        overflows_.fetch_add(1, std::memory_order_relaxed);
        need = avail; // drop overflow instead of overrunning
    }
    uint32_t first = std::min(need, RING_CAP - (w & (RING_CAP - 1)));
    std::memcpy(&ring_[w & (RING_CAP - 1)], data, first * sizeof(int16_t));
    if (need > first)
        std::memcpy(&ring_[0], data + first, (need - first) * sizeof(int16_t));
    wPos_.store(w + need, std::memory_order_release);
    audioProdFrames_.fetch_add(need / 2, std::memory_order_relaxed);
    audioBatches_.fetch_add(1, std::memory_order_relaxed);
}

size_t GsRunner::onAudioBatch(const int16_t *data, size_t frames) {
    GsRunner *s = s_self;
    if (!s) return 0;
    int speed = s->speed_.load(std::memory_order_relaxed);
    if (speed <= 1) {
        s->ffCarry_ = 0; s->ffSumL_ = 0; s->ffSumR_ = 0;
        s->pushSamples(data, static_cast<uint32_t>(frames * 2));
        return frames;
    }

    // Fast-forward: the core emits speed x more samples per wall second than
    // the 48 kHz HAL consumes. Decimate by N with a length-N boxcar average
    // (cheap anti-aliasing): N emulated samples -> 1 output sample. Tempo and
    // pitch both rise N x (classic sped-up game audio), and producer/consumer
    // wall-clock rates match exactly, so the ring neither underflows nor
    // overflows. Partial groups carry across callbacks.
    const int N = speed;
    if (s->ffOut_.size() < frames * 2) s->ffOut_.resize(frames * 2);
    uint32_t out = 0;
    for (size_t i = 0; i < frames; ++i) {
        s->ffSumL_ += data[i * 2];
        s->ffSumR_ += data[i * 2 + 1];
        if (++s->ffCarry_ == static_cast<uint32_t>(N)) {
            auto roundAvg = [N](int32_t sum) -> int16_t {
                int32_t q = sum >= 0 ? (sum + N / 2) / N : (sum - N / 2) / N;
                if (q > 32767) q = 32767;
                if (q < -32768) q = -32768;
                return static_cast<int16_t>(q);
            };
            s->ffOut_[out * 2] = roundAvg(s->ffSumL_);
            s->ffOut_[out * 2 + 1] = roundAvg(s->ffSumR_);
            ++out;
            s->ffCarry_ = 0; s->ffSumL_ = 0; s->ffSumR_ = 0;
        }
    }
    if (out) s->pushSamples(s->ffOut_.data(), out * 2);
    return frames;
}

void GsRunner::playMacro(const std::vector<uint32_t> &frames) {
    // A macro is just local input synthesis: it expands into the same retropad
    // frames the player would press by hand, so it is part of THIS player's
    // input stream. In netplay that stream is transmitted and applied on both
    // machines under the frame gate (see pacingLoop), so a macro is perfectly
    // deterministic — it cannot desync. The pace thread ORs macroMask_ into the
    // published local mask each frame, so the peer receives the exact same
    // frames the local side feeds the core.
    std::lock_guard<std::mutex> lk(macroMtx_);
    macroQueue_.assign(frames.begin(), frames.end());
    macroMask_.store(0, std::memory_order_relaxed);
}

void GsRunner::clearMacro() {
    std::lock_guard<std::mutex> lk(macroMtx_);
    macroQueue_.clear();
    macroMask_.store(0, std::memory_order_relaxed);
}

void GsRunner::advanceMacro() {
    uint32_t mm = 0;
    {
        std::lock_guard<std::mutex> lk(macroMtx_);
        if (!macroQueue_.empty()) {
            mm = macroQueue_.front();
            macroQueue_.pop_front();
        }
    }
    macroMask_.store(mm, std::memory_order_relaxed);
    // DIAGNOSTIC: trace each macro step so a logcat capture shows whether the
    // queued direction bits actually reach the pad (combo debugging).
    static int macroLogBudget = 0;
    if (mm != 0 || macroLogBudget > 0) {
        if (macroLogBudget < 64) {
            __android_log_print(ANDROID_LOG_INFO, "GS-Runner",
                                "[macro] step mask=0x%08x", mm);
            ++macroLogBudget;
        }
        if (mm == 0) macroLogBudget = 0;
    }
}

void GsRunner::onInputPoll() {
    // The macro used to be advanced here, but libretro cores are free to skip
    // input_poll_cb — the MAME port never calls it at all, which left macros
    // queued forever (macroMask_ stuck at 0). pacingLoop now steps the macro
    // once per emulated frame right before runFrame(); this hook intentionally
    // does nothing so the two can never double-advance.
}

int16_t GsRunner::onInputState(unsigned port, unsigned device, unsigned /*index*/, unsigned id) {
    GsRunner *s = s_self;
    if (!s) return 0;
    if (device != RETRO_DEVICE_JOYPAD && device != RETRO_DEVICE_ANALOG) return 0;
    if (id > 31) return 0;
    // The on-screen pad is a DIGITAL controller: directions ride the joypad
    // d-pad bits (set in onInputPoll from the native runner's mask), and the
    // analog axis is always neutral. Returning 0 for the analog axis query
    // keeps the axis-NEG/POS assignments silent so only the d-pad switch drives
    // IPT_JOYSTICK_*. (Earlier this branch returned a retropad BIT as the axis
    // value, leaking button presses into the analog axis.)
    if (device == RETRO_DEVICE_ANALOG) return 0;
    // Netplay: the frame gate fills both player slots with the deterministic
    // masks for frame K-D; ports 2/3 always read buttons up.
    if (s->net_) {
        if (port > 1) return 0;
        return (s->netButtons_[port] >> id) & 1;
    }
    // The single on-screen pad drives only the selected player port
    // (0 = 1P, 1 = 2P); the other player always reads buttons up.
    if (static_cast<int>(port) != s->activePort_.load(std::memory_order_relaxed)) return 0;
    const uint32_t m = s->buttons_.load(std::memory_order_relaxed) |
                       s->macroMask_.load(std::memory_order_relaxed);
    return (m >> id) & 1;
}

bool GsRunner::setupAudio(double sampleRate) {
    if (android_get_device_api_level() < 26) {
        log("AAudio requires API26+; audio disabled");
        return false;
    }
    AAudioStreamBuilder *b = nullptr;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return false;
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    // EXCLUSIVE + LOW_LATENCY perf mode is the fast-path; the system silently
    // falls back to SHARED where exclusive is unavailable.
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_EXCLUSIVE);
    AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, 2);
    AAudioStreamBuilder_setSampleRate(b, static_cast<int32_t>(sampleRate + 0.5));
    AAudioStreamBuilder_setDataCallback(b,
        [](AAudioStream *stream, void *userData, void *audioData, int32_t numFrames)
            -> aaudio_data_callback_result_t {
            auto *s = static_cast<GsRunner *>(userData);
            auto *out = static_cast<int16_t *>(audioData);
            uint32_t need = static_cast<uint32_t>(numFrames) * 2;
            uint32_t r = s->rPos_.load(std::memory_order_relaxed);
            uint32_t w = s->wPos_.load(std::memory_order_acquire);
            uint32_t avail = w - r;
            if (avail < need) {
                s->xruns_.fetch_add(1, std::memory_order_relaxed);
                s->underruns_.fetch_add(1, std::memory_order_relaxed);
                std::memset(out, 0, need * sizeof(int16_t));
                // consume whatever is available, padded with silence
                uint32_t take = avail & ~1u;
                uint32_t first = std::min(take, GsRunner::RING_CAP - (r & (GsRunner::RING_CAP - 1)));
                std::memcpy(out, &s->ring_[r & (GsRunner::RING_CAP - 1)], first * sizeof(int16_t));
                if (take > first)
                    std::memcpy(out + first, &s->ring_[0], (take - first) * sizeof(int16_t));
                s->rPos_.store(r + take, std::memory_order_release);
            } else {
                uint32_t idx = r & (GsRunner::RING_CAP - 1);
                uint32_t first = std::min(need, GsRunner::RING_CAP - idx);
                std::memcpy(out, &s->ring_[idx], first * sizeof(int16_t));
                if (need > first)
                    std::memcpy(out + first, &s->ring_[0], (need - first) * sizeof(int16_t));
                s->rPos_.store(r + need, std::memory_order_release);
            }
            (void)stream;
            return AAUDIO_CALLBACK_RESULT_CONTINUE;
        }, this);
    AAudioStreamBuilder_setErrorCallback(b,
        [](AAudioStream *, void *userData, aaudio_result_t err) {
            auto *s = static_cast<GsRunner *>(userData);
            s->xruns_.fetch_add(1, std::memory_order_relaxed);
            s->aerrors_.fetch_add(1, std::memory_order_relaxed);
            (void)err;
        }, this);

    AAudioStream *stream = nullptr;
    aaudio_result_t res = AAudioStreamBuilder_openStream(b, &stream);
    AAudioStreamBuilder_delete(b);
    if (res != AAUDIO_OK) {
        log("AAudio open failed: %d", (int)res);
        return false;
    }
    audioStream_ = stream;
    audioReady_ = true;
    int32_t actualRate = AAudioStream_getSampleRate(stream);
    log("AAudio opened rate=%d frames/period~%d (start deferred for prefill)", actualRate,
        AAudioStream_getFramesPerBurst(stream));
    // Producer/consumer run at the same wall-clock rate, so once the ring is
    // prefilled the cushion stays roughly constant (adds only a fixed startup
    // latency, no drift). 120 ms comfortably covers burst (5 ms) and typical
    // scheduler stalls on the GL thread, keeping callback underruns at zero.
    audioPrefillSamples_ = static_cast<uint32_t>(actualRate * 2 * 0.12);
    if (audioPrefillSamples_ > (RING_CAP / 2)) audioPrefillSamples_ = RING_CAP / 2;
    rPos_.store(0, std::memory_order_release);
    wPos_.store(0, std::memory_order_release);
    audioStartPending_ = true;
    (void)res;
    return true;
}

void GsRunner::teardownAudio() {
    auto *stream = static_cast<AAudioStream *>(audioStream_);
    if (!stream) return;
    AAudioStream_requestStop(stream);
    AAudioStream_close(stream);
    audioStream_ = nullptr;
    audioReady_ = false;
    streamRunning_.store(false);
}

void GsRunner::setAudioPaused(bool paused) {
    auto *stream = static_cast<AAudioStream *>(audioStream_);
    if (!stream) return;
    audioPaused_.store(paused, std::memory_order_relaxed);
    if (paused) {
        AAudioStream_requestPause(stream);
    } else if (!audioStartPending_) {
        AAudioStream_requestStart(stream); // prefill gate in runFrame owns the first start
    }
}

void GsRunner::setPaused(bool paused) {
    {
        std::lock_guard<std::mutex> lk(pauseMtx_);
        pacePaused_.store(paused, std::memory_order_relaxed);
    }
    paceCv_.notify_all();
    setAudioPaused(paused);
    // Persist in-game saves whenever the app goes to background; Android may
    // kill the process without onDestroy, so this is the reliable flush point.
    if (paused) flushBatteryRam();
}

void GsRunner::setSpeed(int mult) {
    static const int kAllowed[] = {1, 2, 4, 6, 8};
    int wanted = 1;
    for (int m : kAllowed) if (m == mult) { wanted = m; break; }
    {
        std::lock_guard<std::mutex> coreLock(coreMtx_);
        // Lockstep tolerates exactly one wall-clock speed: anything else
        // would desync inputs from frame timing. UI hides the control in
        // netplay; this is the defensive second layer.
        if (net_ && wanted != 1) {
            log("[GS-Netplay] speed x%d ignored (lockstep forces x1)", wanted);
            return;
        }
        int prev = speed_.exchange(wanted, std::memory_order_acq_rel);
        if (prev == wanted) return;
        // coreMtx_ serializes against retro_run/onAudioBatch on the pace thread;
        // drop any partial decimation group so group boundaries restart cleanly.
        // The AAudio stream keeps running at its fixed rate: onAudioBatch decimates
        // to exactly the HAL's wall-clock rate, so no pause/flush is needed.
        ffCarry_ = 0; ffSumL_ = 0; ffSumR_ = 0;
    }
    log("speed x%d", wanted);
}

void GsRunner::setCheats(const std::vector<std::string> &codes) {
    if (!gameLoaded_) {
        log("setCheats ignored: no game loaded");
        return;
    }
    // Serializes against retro_run() (which walks the cheat list every frame)
    // and against the read-handler rebuild inside the core.
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    if (net_ && !codes.empty()) {
        // Cheats diverge the deterministic state the moment only one side
        // applies them; only an explicit clear is tolerated while attached.
        log("[GS-Netplay] %zu cheat code(s) rejected while in lockstep",
            codes.size());
        return;
    }
    core_.cheat_reset();
    unsigned idx = 0;
    for (const auto &code : codes) {
        if (code.empty()) continue;
        core_.cheat_set(idx++, true, code.c_str());
    }
    log("cheats applied: %zu active code(s)", codes.size());
}

void GsRunner::startPacing() {
    if (pacing_.exchange(true)) return;
    netFrame_ = 0;
    netButtons_[0] = netButtons_[1] = 0;
    netDbgPrevLm_ = netDbgPrevRm_ = 0xFFFF;
    netDeadLogged_ = false;
    paceThread_ = std::thread([this] { pacingLoop(); });
}

bool GsRunner::pumpFrame(int &w, int &h, int &pitch) {
    if (!initialized_ || !extPixels_) return false;
    if (publishedSeq_ == pumpedSeq_) return false; // no new frame since last pump
    int fw, fh;
    {
        std::lock_guard<std::mutex> lk(frameMtx_);
        fw = pubW_; fh = pubH_;
        if (publishedSeq_ == pumpedSeq_) return false;
        std::memcpy(extPixels_, renderFront_.data(),
                    static_cast<size_t>(fw) * fh * 4);
        pumpedSeq_ = publishedSeq_;
    }
    w = fw; h = fh; pitch = fw * 4;
    return true;
}

void GsRunner::pacingLoop() {
    prctl(PR_SET_NAME, "gs-emu", 0, 0, 0);
    // Minimal timer slack: some vendors inherit a coarse slack (up to tens of
    // ms) into spawned app threads, which rounds absolute sleeps late.
    prctl(PR_SET_TIMERSLACK, 1000UL, 0, 0, 0);
    // Same urgency as the platform UI/render threads so ordinary background
    // activity cannot pre-empt a frame deadline (avoids 59-fps seconds).
    setpriority(PRIO_PROCESS, 0, -8 /* ANDROID_PRIORITY_URGENT_DISPLAY */);

    const double basePeriod = 1.0 / fps_;
    int curSpeed = 1;
    double anchor = monoNow();
    // Stall diagnostics (per sampling second).
    int repSec = -1, repFrames = 0, repResyncs = 0;
    double repMaxOvershootMs = 0.0, repMaxYield = 0.0;
    int over2ms = 0, over5ms = 0, over10ms = 0;
    // TEMP pacing/audio diagnostics
    int dbgN = 0; double dbgT0 = monoNow();
    double dbgStartT = dbgT0; int64_t dbgTotalFrames = 0; // cumulative probe
    int64_t dbgAr0 = -1, dbgAw0 = -1;
    uint64_t dbgProd0 = 0, dbgUnder0 = 0, dbgOver0 = 0, dbgBat0 = 0;
    int dbgSleeps = 0, dbgYields = 0, dbgResyncs = 0;
    double dbgEmuMs = 0, dbgEmuMax = 0, dbgOvershootMax = 0, dbgYieldMax = 0;
    // TEMP per-frame accounting
    double dbgPrevTop = dbgT0, dbgCycleSum = 0, dbgLateSum = 0, dbgLateMax = 0;
    double dbgIntendSum = 0, dbgOverSum = 0; int dbgPeriodLogged = 0;
    bool dbgSkipCycle = true;
    while (pacing_.load(std::memory_order_relaxed)) {
        bool resumedFromPause = false;
        {
            std::unique_lock<std::mutex> lk(pauseMtx_);
            // Only block (and re-anchor) when actually paused. Re-baselining
            // anchor every frame would discard the absolute TIMER_ABSTIME
            // timeline, so each wake's small overshoot (~0.1-0.2ms) would
            // accumulate permanently instead of being absorbed by the next
            // frame's shorter sleep.
            if (pacePaused_.load(std::memory_order_relaxed)) {
                paceCv_.wait(lk, [this] {
                    return !pacePaused_.load(std::memory_order_relaxed) ||
                           !pacing_.load(std::memory_order_relaxed);
                });
                resumedFromPause = true;
            }
            if (!pacing_.load(std::memory_order_relaxed)) break;
            if (resumedFromPause) {
                anchor = monoNow(); // do not try to catch up across a pause
                dbgPrevTop = anchor;
                dbgSkipCycle = true;
            }
        }
        // Re-baseline the absolute timeline whenever the speed multiplier
        // changes: otherwise the old (longer) deadline would already be in the
        // past and trigger an uncapped catch-up burst.
        int wantedSpeed = speed_.load(std::memory_order_relaxed);
        if (wantedSpeed != curSpeed) {
            curSpeed = wantedSpeed;
            anchor = monoNow();
            dbgSkipCycle = true;
        }

        // ---- netplay frame gate ----
        // Blocks this (pace) thread until the remote input for frame
        // (K-D) is authenticated and buffered. Paused/Starting/Dead park
        // here without consuming a frame; audio drains to silence and the
        // absolute timeline is re-anchored when the gate releases so no
        // catch-up burst occurs.
        if (net_) {
            bool gateWaited = false;
            np::GateResult gr;
            while (pacing_.load(std::memory_order_relaxed)) {
                uint16_t lm = 0, rm = 0;
                gr = net_->beginFrame(static_cast<uint32_t>(netFrame_), lm, rm);
                if (gr == np::GateResult::Ok) {
                    // Both machines emulate the SAME core state, so retropad
                    // port 0 must be the host's pad on both machines.
                    // beginFrame's lm/rm are local/remote relative to self:
                    // swap on the guest so its own physical pad drives port 1.
                    // `lm` is exactly what endFrame published for frame
                    // (K-D) — the UI pad mask ORed with that frame's macro
                    // step (see endFrame below). DO NOT OR macroMask_ in
                    // again here: it would double-count the macro locally
                    // and desync the peer.
                    if (netIsHost_) {
                        netButtons_[0] = lm;
                        netButtons_[1] = rm;
                    } else {
                        netButtons_[0] = rm;
                        netButtons_[1] = lm;
                    }
                    if (lm != netDbgPrevLm_ || rm != netDbgPrevRm_) {
                        log("[GS-Netplay] btn f=%llu host=%d lm=0x%04x rm=0x%04x",
                            static_cast<unsigned long long>(netFrame_),
                            static_cast<int>(netIsHost_), lm, rm);
                        netDbgPrevLm_ = lm; netDbgPrevRm_ = rm;
                    }
                    break;
                }
                gateWaited = true;
                if (gr == np::GateResult::Dead && !netDeadLogged_) {
                    netDeadLogged_ = true;
                    // Session dropped/bye: never release another frame
                    // (determinism cannot resume). UI layer ends the
                    // activity; park until pacing stops.
                    log("[GS-Netplay] session dead at frame %llu; emulation parked",
                        static_cast<unsigned long long>(netFrame_));
                }
                struct timespec rest{};
                rest.tv_nsec = 100 * 1000 * 1000;
                clock_nanosleep(CLOCK_MONOTONIC, 0, &rest, nullptr);
            }
            if (!pacing_.load(std::memory_order_relaxed)) break;
            if (gateWaited) {
                anchor = monoNow();
                dbgSkipCycle = true;
            }
        }

        const double period = basePeriod / curSpeed;
        double dbgTop = monoNow();
        if (!dbgSkipCycle) dbgCycleSum += dbgTop - dbgPrevTop;
        dbgPrevTop = dbgTop;
        dbgSkipCycle = false;

        int fw = 0, fh = 0, pitch = 0;
        double dbgTf0 = monoNow();
        // The MAME libretro core never invokes the frontend's input_poll_cb
        // (it queries input_state_cb directly each frame), so advancing the
        // queued macro there is dead code. Step it here, once per emulated
        // frame, immediately before retro_run consumes input. This is the
        // single reliable per-frame hook for macro playback (solo and
        // netplay alike); the frame's macroMask_ is then read by onInputState
        // and, in netplay, published to the peer in endFrame below.
        advanceMacro();
        bool ran = runFrame(fw, fh, pitch);
        if (ran) {
            {
                std::lock_guard<std::mutex> lk(frameMtx_);
                std::swap(emuBack_, renderFront_);
                // swap exchanges the vectors' heap buffers; the libretro video
                // callback writes through this raw pointer, so it must follow
                // emuBack_ or every other frame is rendered into the front
                // buffer (and the GL thread pumps a never-written zero buffer
                // => alternating gray/game frames).
                pixels_ = emuBack_.data();
                pubW_ = fw; pubH_ = fh;
                ++publishedSeq_;
            }
            if (net_) {
                // Publish this side's mask with the frame it belongs to;
                // GsNetplay redundantly carries the last N=D+2 frames. The
                // local input for THIS frame is the fresh UI pad mask ORed
                // with the macro step drained for this frame — the peer
                // receives the identical frames, so a macro stays perfectly
                // deterministic. (Never publish the gate's delayed output
                // back here: that would echo the input through the gate and
                // drop the fresh UI mask entirely.)
                net_->endFrame(static_cast<uint32_t>(netFrame_),
                               static_cast<uint16_t>(
                                   netLocalMask_.load(std::memory_order_relaxed) |
                                   macroMask_.load(std::memory_order_relaxed)));
                ++netFrame_;
                // 120/600/1200 early checkpoints, then one every 600 frames
                // (~10s) so a 60s steady-state window can be read from logs.
                if (netFrame_ == 1 ||
                    netFrame_ == 120 || netFrame_ == 600 ||
                    netFrame_ == 1200 ||
                    (netFrame_ >= 1800 && netFrame_ % 600 == 0)) {
                    netCheckpointHash();
                    // determinism audit: how many retro_run() calls produced the
                    // checkpoint above (the OHOS side logs the same as runs=).
                    log("[GS-Netplay] runs=%ld at f=%llu",
                        emuRuns_.load(std::memory_order_relaxed),
                        static_cast<unsigned long long>(netFrame_));
                    }
            }
        }

        double dbgEmu = (monoNow() - dbgTf0) * 1000.0;
        dbgEmuMs += dbgEmu;
        if (dbgEmu > dbgEmuMax) dbgEmuMax = dbgEmu;

        // TEMP: log production vs audio consumption every 250 frames
        if (++dbgN >= 250) {
            double dt = monoNow() - dbgT0;
            uint64_t prod = audioProdFrames_.load(), bat = audioBatches_.load();
            uint64_t un = underruns_.load(), ov = overflows_.load();
            dbgTotalFrames += 250;
            double cum = monoNow() - dbgStartT;
            int64_t ar = -1, aw = -1;
            if (audioStream_) {
                ar = AAudioStream_getFramesRead(static_cast<AAudioStream *>(audioStream_));
                aw = AAudioStream_getFramesWritten(static_cast<AAudioStream *>(audioStream_));
            }
            log("[pace] 250f %.3fs (%.2f fps) prodF=%llu (%.1f/s, %llu batches avg%.1f) "
                "underrun+%llu overflow+%llu ring=%d | sleeps=%d yields=%d resyncs=%d "
                "emuAvg=%.2fms emuMax=%.2fms sleepOverMax=%.2fms yieldMax=%.2fms",
                dt, 250.0 / dt,
                (unsigned long long)(prod - dbgProd0),
                (prod - dbgProd0) / dt,
                (unsigned long long)(bat - dbgBat0),
                (bat - dbgBat0) ? (double)(prod - dbgProd0) / (bat - dbgBat0) : 0.0,
                (unsigned long long)(un - dbgUnder0),
                (unsigned long long)(ov - dbgOver0),
                (int)((int64_t)wPos_.load() - (int64_t)rPos_.load()),
                dbgSleeps, dbgYields, dbgResyncs,
                dbgEmuMs / dbgN, dbgEmuMax, dbgOvershootMax, dbgYieldMax);
            // TEMP cumulative (boundary artefacts cancel across windows):
            // true producer fps vs the HAL's actual presentation clock.
            if (ar >= 0) {
                if (dbgAr0 < 0) { dbgAr0 = ar; dbgAw0 = aw; }
                log("[cum] t=%.3f frames=%d -> fps=%.4f | HAL read+%lld (%.1f/s) "
                    "written+%lld (%.1f/s)",
                    cum, (int)dbgTotalFrames, dbgTotalFrames / cum,
                    (long long)(ar - dbgAr0), (ar - dbgAr0) / cum,
                    (long long)(aw - dbgAw0), (aw - dbgAw0) / cum);
            }
            if (!dbgPeriodLogged) {
                log("[acc] period=%.6fms", basePeriod * 1000.0);
                dbgPeriodLogged = 1;
            }
            log("[acc] cycAvg=%.4fms lateWork avg=%.4f max=%.4f | "
                "intendedSleep avg=%.4fms wakeOver avg=%.4fms",
                dbgCycleSum * 1000.0 / dbgN,
                dbgLateSum * 1000.0 / dbgN, dbgLateMax * 1000.0,
                dbgIntendSum * 1000.0 / dbgN, dbgOverSum * 1000.0 / dbgN);
            dbgN = 0; dbgT0 = monoNow();
            dbgProd0 = prod; dbgUnder0 = un; dbgOver0 = ov; dbgBat0 = bat;
            dbgSleeps = dbgYields = dbgResyncs = 0;
            dbgEmuMs = dbgEmuMax = dbgOvershootMax = dbgYieldMax = 0;
            dbgCycleSum = dbgLateSum = dbgLateMax = dbgIntendSum = dbgOverSum = 0;
        }

        // Absolute timeline: frame k targets start + k*period. Sleeping to an
        // absolute CLOCK_MONOTONIC time prevents drift accumulation; when we are
        // late we catch up by running the next frame immediately (burst), and a
        // large lag (>~3 frames) is forgiven instead of spiral-of-death.
        double nowPre = monoNow();
        double lateWork = nowPre - anchor; // past prev target after this frame's work
        anchor += period;
        double now = nowPre;
        double diff = anchor - now;
        dbgLateSum += lateWork;
        if (lateWork > dbgLateMax) dbgLateMax = lateWork;

        // Per-second pacing diagnostics while bench sampling is active.
        if (benchPhase_.load(std::memory_order_relaxed) == 2) {
            int sec = static_cast<int>(now - benchSampleStart_);
            if (sec != repSec) {
                if (repSec >= 0) {
                    log("pace[%d] frames=%d resyncs=%d over2/5/10ms=%d/%d/%d "
                        "maxSleepOvershoot=%.2fms maxYieldGap=%.2fms",
                        repSec, repFrames, repResyncs, over2ms, over5ms, over10ms,
                        repMaxOvershootMs, repMaxYield);
                }
                repSec = sec; repFrames = 0; repResyncs = 0;
                over2ms = over5ms = over10ms = 0;
                repMaxOvershootMs = repMaxYield = 0.0;
            }
            ++repFrames;
        }

        if (diff < -0.05) {
            anchor = now;
            ++repResyncs;
            ++dbgResyncs;
        } else if (diff > 0.0005) {
            ++dbgSleeps;
            dbgIntendSum += diff;
            struct timespec ts;
            ts.tv_sec = static_cast<time_t>(anchor);
            ts.tv_nsec = static_cast<long>((anchor - ts.tv_sec) * 1e9);
            while (true) {
                int rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, nullptr);
                if (rc != EINTR) break;
                if (!pacing_.load(std::memory_order_relaxed)) break;
            }
            double overMs = (monoNow() - anchor) * 1000.0;
            dbgOverSum += overMs / 1000.0;
            if (overMs > dbgOvershootMax) dbgOvershootMax = overMs;
            if (benchPhase_.load(std::memory_order_relaxed) == 2) {
                if (overMs > repMaxOvershootMs) repMaxOvershootMs = overMs;
                if (overMs > 2.0) ++over2ms;
                if (overMs > 5.0) ++over5ms;
                if (overMs > 10.0) ++over10ms;
            }
        } else {
            ++dbgYields;
            double y0 = monoNow();
            sched_yield(); // slightly behind: burst-catch next frame promptly
            double gap = (monoNow() - y0) * 1000.0;
            if (gap > dbgYieldMax) dbgYieldMax = gap;
            if (benchPhase_.load(std::memory_order_relaxed) == 2) {
                if (gap > repMaxYield) repMaxYield = gap;
            }
        }
    }
}

bool GsRunner::init(const std::string &coreId, const std::string &romPath,
                    const std::string &saveDir,
                    const std::string &systemDir, const std::string &logPath,
                    const std::string &saveKey, bool netplayColdBoot) {
    s_self = this;
    coreId_ = coreId.empty() ? "fceumm" : coreId;
    romPath_ = romPath; saveDir_ = saveDir; systemDir_ = systemDir; logPath_ = logPath;
    saveKey_ = saveKey;
    jiffiesPerSec_ = sysconf(_SC_CLK_TCK);
    pageSize_ = sysconf(_SC_PAGESIZE);

    // Netplay cold boot: a lockstep session deliberately cold-boots both peers
    // (the bootstrap skips the frame-0 state sync), so each machine must start
    // from the SAME deterministic state. Per-device NVRAM files (e.g. the MAME
    // nvram_device "saveram" at <saveDir>/<core>/nvram/<game>/<tag>) differ
    // between the two phones and desync them from the first checkpoint. Arm
    // the core-side guard so nvram_load() uses the deterministic default fill
    // instead. Cleared for solo play so normal save/load is unaffected.
    if (netplayColdBoot)
        setenv("GP_NETPLAY_COLD_BOOT", "1", 1);
    else
        unsetenv("GP_NETPLAY_COLD_BOOT");
    // Same reasoning as the NVRAM guard above, for the MAME cfg file: coin
    // counters live in <saveDir>/mame/cfg/<game>.cfg and are part of the
    // machine state, so two phones with different play history boot with
    // different counters and drift apart from frame 0. A brand-new (empty)
    // per-process directory makes both peers start from the core defaults.
    // Solo play keeps the user's real save directory untouched.
    netplayColdBoot_ = netplayColdBoot;
    npSaveDir_.clear();
    if (netplayColdBoot_ && !saveDir_.empty()) {
        const std::string tag = "np_" + std::to_string(static_cast<long>(::getpid()));
        npSaveDir_ = saveDir_ + "/" + tag;
        // Drop the leftovers of earlier sessions (a few KB of core cfg each).
        std::error_code ec;
        namespace fs = std::filesystem;
        for (const auto &e : fs::directory_iterator(saveDir_, ec)) {
            if (ec) break;
            if (!e.is_directory(ec)) continue;
            const std::string n = e.path().filename().string();
            if (n.rfind("np_", 0) == 0 && n != tag) fs::remove_all(e.path(), ec);
        }
    }

    logFile_ = fopen(logPath.c_str(), "wb");
    log("== GamePouch runner start ==");
    log("core=%s rom=%s save=%s system=%s api=%d", coreId_.c_str(),
        romPath.c_str(), saveDir.c_str(), systemDir.c_str(),
        android_get_device_api_level());

    // Resolve the emulator core (separate libgs_<id>.so packaged in the APK).
    {
        std::string loadErr;
        core_ = gsLoadCore(coreId_, loadErr);
        if (!core_.valid()) {
            log("core load failed: %s", loadErr.c_str());
            return false;
        }
        log("core loaded: libgs_%s.so", coreId_.c_str());
    }

    ring_.assign(RING_CAP, 0);
    rPos_.store(0); wPos_.store(0);
    xruns_.store(0); underruns_.store(0); overflows_.store(0); aerrors_.store(0);
    audioStartPending_ = false;

    // Video double buffer (4 bytes/pixel RGBA, max supported geometry).
    emuBack_.assign(MAX_W * MAX_H, 0);
    renderFront_.assign(MAX_W * MAX_H, 0);
    pixels_ = emuBack_.data();
    publishedSeq_ = 0; pumpedSeq_ = 0;

    // read ROM
    {
        std::ifstream f(romPath, std::ios::binary);
        if (!f) { log("cannot open rom"); return false; }
        f.seekg(0, std::ios::end);
        auto sz = f.tellg();
        f.seekg(0, std::ios::beg);
        romBytes_.resize(static_cast<size_t>(sz));
        f.read(reinterpret_cast<char *>(romBytes_.data()), sz);
    }

    // Region selection:
    //  - iNES byte 9 / NES 2.0 byte 12 flag true PAL ROMs  -> PAL timing
    //  - Chinese TW-MMC3 clone boards (mappers 198/199) ran on Dendy/UMC
    //    famiclones: 50 fps with NTSC CPU/APU clocks and a ~50-line vblank.
    //    Their font engines stream glyph patterns into CHR-RAM during that
    //    long vblank; NTSC's 20-line window cuts the upload off (garbled
    //    menus), while plain PAL would slow the game and flatten audio pitch.
    // FCEUmm/NES only; other cores have their own cart header formats.
    if (coreId_ == "fceumm" &&
        romBytes_.size() >= 16 &&
        romBytes_[0] == 'N' && romBytes_[1] == 'E' && romBytes_[2] == 'S' &&
        romBytes_[3] == 0x1A) {
        // Heuristic mapper re-assignment for pirate TW-MMC3 carts shipped with
        // a wrong iNES header (e.g. 吞食天地 三国外传 豪华中文版, 1994).
        // Fingerprint of the iNES Mapper 198 board: plain iNES header claiming
        // MMC3 (mapper 4), 40x16 KiB = 640 KiB PRG (non-power-of-two => two
        // stacked PRG chips - no legit MMC3 cart ever has this), zero CHR banks
        // (8 KiB CHR-RAM), and battery-backed WRAM. Relabel in the in-memory
        // image only (the file on disk is untouched) before the core parses it;
        // the Dendy region rule below then applies automatically.
        bool plainInes = (romBytes_[7] & 0x0C) == 0x00;
        int rawMapper = (romBytes_[7] & 0xF0) | (romBytes_[6] >> 4);
        int prgBanks = romBytes_[4];
        int chrBanks = romBytes_[5];
        bool battery = (romBytes_[6] & 0x02) != 0;
        if (plainInes && rawMapper == 4 && prgBanks == 40 &&
            chrBanks == 0 && battery) {
            uint8_t new6 = (romBytes_[6] & 0x0F) | 0x60; // mapper 198 low nibble
            uint8_t new7 = (romBytes_[7] & 0x0F) | 0xC0; // mapper 198 high nibble
            romBytes_[6] = new6;
            romBytes_[7] = new7;
            // The core loads need_fullpath from disk (GET_GAME_INFO_EXT is not
            // supported), so an in-memory patch alone would be bypassed. The
            // imported copy lives in our private filesDir and is unplayable
            // with its original header, so persist the two corrected header
            // bytes in place (the user's source file is never touched).
            std::ofstream pf(romPath_, std::ios::binary | std::ios::in |
                                      std::ios::out);
            if (pf) {
                pf.seekp(6);
                pf.put(static_cast<char>(new6));
                pf.put(static_cast<char>(new7));
                log("rom heuristic: mislabelled mapper4 -> mapper198, header "
                    "patched in place (640K PRG/CHR-RAM/battery)");
            } else {
                log("rom heuristic: detected mapper198 but header file is "
                    "not writable");
            }
        }

        bool nes2 = (romBytes_[7] & 0x0C) == 0x08;
        int mapper = (romBytes_[7] & 0xF0) | (romBytes_[6] >> 4);
        if (nes2) mapper |= (romBytes_[8] & 0x0F) << 8;
        bool headerPal = nes2 ? ((romBytes_[12] & 0x03) == 0x01)
                              : (romBytes_[9] == 0x01);
        if (mapper == 198 || mapper == 199) forcedRegion_ = "Dendy";
        else if (headerPal) forcedRegion_ = "PAL";
        log("rom header: mapper=%d nes2=%d tvbyte9=%d -> region=%s",
            mapper, (int)nes2, romBytes_[9],
            forcedRegion_.empty() ? "Auto" : forcedRegion_.c_str());
    }

    core_.set_environment(onEnvironment);
    core_.set_video_refresh(onVideoRefresh);
    core_.set_audio_sample(nullptr);
    core_.set_audio_sample_batch(onAudioBatch);
    core_.set_input_poll(onInputPoll);
    core_.set_input_state(onInputState);

    log("retro_api_version=%u", core_.api_version());
    core_.init();

    std::memset(&gameInfo_, 0, sizeof(gameInfo_));
    gameInfo_.path = romPath_.c_str();
    gameInfo_.data = romBytes_.data();
    gameInfo_.size = romBytes_.size();
    if (!core_.load_game(&gameInfo_)) {
        log("retro_load_game failed");
        core_.deinit();
        return false;
    }
    gameLoaded_ = true;

    // fbalpha-family cores only finalise their per-device input remap and
    // push retro_input_descriptor entries after the frontend assigns a
    // controller to every port (RetroArch always does this). The default
    // "Classic retropad" is exposed by the core as RETRO_DEVICE_ANALOG.
    if ((coreId_.find("fbalpha") != std::string::npos ||
         coreId_.find("fbneo") != std::string::npos) &&
        core_.set_controller_port_device) {
        for (unsigned p = 0; p < 4; ++p)
            core_.set_controller_port_device(p, RETRO_DEVICE_ANALOG);
        log("assigned CLASSIC retropad to ports 0..3");
    }

    // Prime the savestate size cache. Some cores (notably fbalpha2012)
    // compute retro_serialize_size() lazily on the first call and cache
    // it in a static; retro_serialize()/retro_unserialize() then compare
    // against that cache. In a process that restores a state before ever
    // saving one, the cache is 0 and every state is rejected.
    if (core_.serialize_size) {
        size_t stateBytes = core_.serialize_size();
        log("savestate size primed: %zu bytes", stateBytes);
    }

    // Battery-backed cart RAM (the game's own save slots) is exposed by the
    // core via RETRO_MEMORY_SAVE_RAM; restore the persisted image before the
    // first frame so in-game saves survive app restarts. The file is keyed by
    // the stable per-game key (CRC32 from the Kotlin side) instead of the ROM
    // file name, so two games sharing a file name can never swap saves.
    {
        std::string legacyBase;
        {
            size_t slash = romPath_.find_last_of('/');
            legacyBase = (slash == std::string::npos) ? romPath_
                                                      : romPath_.substr(slash + 1);
            size_t dot = legacyBase.find_last_of('.');
            if (dot != std::string::npos) legacyBase.resize(dot);
        }
        const std::string key =
            saveKey_.empty() ? legacyBase : saveKey_;
        sramPath_ = saveDir_ + "/" + key + ".sav";
        // One-time migration from the legacy <romBase>.sav layout (only when
        // no CRC-keyed save exists, to avoid clobbering newer data).
        const std::string legacyPath = saveDir_ + "/" + legacyBase + ".sav";
        if (key != legacyBase) {
            FILE *probe = fopen(sramPath_.c_str(), "rb");
            const bool haveNew = probe != nullptr;
            if (probe) fclose(probe);
            FILE *legacy = haveNew ? nullptr : fopen(legacyPath.c_str(), "rb");
            if (legacy) {
                fclose(legacy);
                if (rename(legacyPath.c_str(), sramPath_.c_str()) == 0) {
                    log("migrated battery save %s -> %s.sav", legacyBase.c_str(),
                        key.c_str());
                }
            }
        }
    }
    loadBatteryRam();

    retro_system_av_info av{};
    core_.get_system_av_info(&av);
    fbW_ = av.geometry.base_width;
    fbH_ = av.geometry.base_height;
    if (av.geometry.aspect_ratio > 0.0) aspectRatio_ = av.geometry.aspect_ratio;
    fps_ = av.timing.fps > 0 ? av.timing.fps : 60.0988;
    sampleRate_ = av.timing.sample_rate > 0 ? av.timing.sample_rate : 48000.0;
    log("av: %dx%d fps=%.4f rate=%.1f pixFmt=%d", fbW_, fbH_, fps_, sampleRate_, (int)pixFmt_);

    setupAudio(sampleRate_);

    initialized_ = true;
    return true;
}

void GsRunner::dispose() {
    // Stop the emulation thread before touching the core/audio/log it uses.
    pacing_.store(false);
    {
        std::lock_guard<std::mutex> lk(pauseMtx_);
        pacePaused_.store(false);
    }
    paceCv_.notify_all();
    // Unblock a parked netplay frame gate before joining the pace thread.
    if (net_) net_->shutdown();
    if (paceThread_.joinable()) paceThread_.join();
    {
        std::lock_guard<std::mutex> coreLock(coreMtx_);
        net_.reset();
    }

    teardownAudio();
    if (gameLoaded_) {
        // Detach cheat read handlers while the core is still live.
        { std::lock_guard<std::mutex> coreLock(coreMtx_); core_.cheat_reset(); }
        flushBatteryRam(); // last chance before the core frees SaveGame RAM
        core_.unload_game();
        gameLoaded_ = false;
    }
    if (initialized_) {
        core_.deinit();
        initialized_ = false;
    }
    gsUnloadCore(core_);
    if (logFile_) {
        log("== runner disposed ==");
        fclose(logFile_);
        logFile_ = nullptr;
    }
    if (s_self == this) s_self = nullptr;
}

bool GsRunner::runFrame(int &w, int &h, int &pitch) {
    if (!initialized_) return false;
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    double t0 = monoNow();
    core_.run();
    emuRuns_.fetch_add(1, std::memory_order_relaxed);
    double t1 = monoNow();
    w = fbW_; h = fbH_; pitch = fbW_ * 4;

    // Start the AAudio callback only after the ring holds the prefill cushion.
    if (audioStartPending_ && audioStream_) {
        uint32_t buffered = wPos_.load(std::memory_order_acquire)
                          - rPos_.load(std::memory_order_acquire);
        if (buffered >= audioPrefillSamples_) {
            auto *st = static_cast<AAudioStream *>(audioStream_);
            aaudio_result_t r = AAudioStream_requestStart(st);
            if (r == AAUDIO_OK) {
                audioStartPending_ = false;
                streamRunning_.store(true, std::memory_order_release);
                log("AAudio started after prefill: %u samples buffered", buffered);
            } else {
                log("AAudio requestStart failed: %d (will retry next frame)", (int)r);
            }
        }
    }

    if (benchPhase_.load() == 1 && t1 >= benchWarmupEnd_) {
        benchPhase_.store(2);
        benchSampleStart_ = t1;
        benchSampleEnd_ = t1 + (benchSampleEnd_ - benchWarmupEnd_); // duration preserved
        frameMs_.clear();
        secondBuckets_.clear();
        benchFrames_ = 0;
        currentSecond_ = -1;
        cpuAcc_ = 0; cpuSamples_ = 0;
        rssMax_ = 0;
        lastCpuTime_ = 0;
    }
    if (benchPhase_.load() == 2) {
        frameMs_.push_back((t1 - t0) * 1000.0);
        benchFrames_++;
        int sec = static_cast<int>(t1 - benchSampleStart_);
        if (sec != currentSecond_) {
            while ((int)secondBuckets_.size() <= sec) secondBuckets_.push_back(0);
            currentSecond_ = sec;
        }
        if (sec >= 0 && sec < (int)secondBuckets_.size()) secondBuckets_[sec]++;
        if (sec > 0 && sec < (int)secondBuckets_.size() && secondBuckets_[sec - 1] < 58)
            thermal_ = true;
        // /proc/self/{stat,statm} opens cost scheduler variance; ~4 Hz is plenty
        // for CPU%/RSS accounting (deltas use wall time, so intervals are fine).
        if ((benchFrames_ % 15) == 0) sampleProc(t1);
        if (t1 >= benchSampleEnd_) {
            benchPhase_.store(3);
            log("bench sampling done frames=%llu", (unsigned long long)benchFrames_);
        }
    }
    return true;
}

void GsRunner::sampleProc(double now) {
    // CPU% of one core from /proc/self/stat
    std::ifstream f("/proc/self/stat");
    std::string line;
    if (!std::getline(f, line)) return;
    auto rp = line.rfind(')');
    if (rp == std::string::npos) return;
    std::istringstream ss(line.substr(rp + 2));
    char state = 0;
    long fields[20] = {0};
    ss >> state;
    for (int i = 0; i < 20; ++i) ss >> fields[i];
    // after state: ppid is token #4 => index 0; utime (#14) => index 10, stime => 11
    long utime = fields[10], stime = fields[11];
    double cpuNs = (utime + stime) * 1e9 / jiffiesPerSec_;
    if (lastCpuTime_ > 0) {
        double wall = now - lastCpuTime_;
        if (wall > 0) {
            cpuAcc_ += (cpuNs - lastCpuNs_) / (wall * 1e9) * 100.0;
            cpuSamples_++;
        }
    }
    lastCpuTime_ = now;
    lastCpuNs_ = cpuNs;

    std::ifstream m("/proc/self/statm");
    long resPages = 0;
    m >> resPages >> resPages;
    uint64_t bytes = static_cast<uint64_t>(resPages) * pageSize_;
    if (bytes > rssMax_) rssMax_ = bytes;
}

void GsRunner::benchStart(int warmupSeconds, int sampleSeconds) {
    double now = monoNow();
    benchPhase_.store(1);
    benchWarmupEnd_ = now + warmupSeconds;
    benchSampleStart_ = now + warmupSeconds;
    benchSampleEnd_ = now + warmupSeconds + sampleSeconds;
    frameMs_.clear();
    secondBuckets_.clear();
    benchFrames_ = 0;
    thermal_ = false;
    cpuAcc_ = 0; cpuSamples_ = 0; lastCpuTime_ = 0;
    rssMax_ = 0;
    log("bench start warmup=%ds sample=%ds", warmupSeconds, sampleSeconds);
}

int GsRunner::benchPhase() const { return benchPhase_.load(); }

static double percentile(std::vector<double> v, double q) {
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    size_t i = static_cast<size_t>(q * (v.size() - 1));
    return v[i];
}

bool GsRunner::benchFinish(const std::string &outPath, const std::string &benchId,
                           const std::string &coreCommit, const std::string &appBuild,
                           const std::string &romCrc32, long romSize,
                           const std::string &deviceModel, const std::string &osRelease) {
    if (benchPhase_.load() != 3) return false;
    double duration = benchSampleEnd_ - benchSampleStart_;
    double fpsAvg = benchFrames_ / duration;
    double p95 = percentile(frameMs_, 0.95);
    double p99 = percentile(frameMs_, 0.99);
    double msAvg = frameMs_.empty() ? 0
        : std::accumulate(frameMs_.begin(), frameMs_.end(), 0.0) / frameMs_.size();
    double budget = 1000.0 / fps_;
    uint64_t dropped = 0;
    for (double ms : frameMs_) if (ms > budget) dropped++;

    // per-second buckets, exclude trailing partial second
    std::vector<double> perSec;
    int full = static_cast<int>(duration);
    for (int i = 0; i < full && i < (int)secondBuckets_.size(); ++i)
        perSec.push_back(static_cast<double>(secondBuckets_[i]));
    double fpsP5 = percentile(perSec, 0.05);

    double cpuAvg = cpuSamples_ > 0 ? cpuAcc_ / cpuSamples_ : 0;
    if (cpuAvg < 0) cpuAvg = 0;

    FILE *f = fopen(outPath.c_str(), "wb");
    if (!f) { log("cannot write bench json: %s", outPath.c_str()); return false; }
    fprintf(f,
        "{\n"
        "  \"bench_id\": \"%s\",\n"
        "  \"core\": \"%s\",\n"
        "  \"core_commit\": \"%s\",\n"
        "  \"rom_crc32\": \"%s\",\n"
        "  \"rom_size\": %ld,\n"
        "  \"device\": \"%s\",\n"
        "  \"os\": \"HarmonyOS 4.2 / AOSP API%s\",\n"
        "  \"abi\": \"arm64-v8a\",\n"
        "  \"app_build\": \"%s\",\n"
        "  \"target_fps\": %.4f,\n"
        "  \"sample_seconds\": %.3f,\n"
        "  \"fps_avg\": %.3f,\n"
        "  \"fps_p5\": %.3f,\n"
        "  \"frame_ms_avg\": %.4f,\n"
        "  \"frame_ms_p95\": %.4f,\n"
        "  \"frame_ms_p99\": %.4f,\n"
        "  \"frames_total\": %llu,\n"
        "  \"frames_dropped\": %llu,\n"
        "  \"audio_underruns\": %u,\n"
        "  \"audio_overflows\": %u,\n"
        "  \"cpu_pct_avg\": %.2f,\n"
        "  \"rss_mb_max\": %.2f,\n"
        "  \"thermal_throttled\": %s,\n"
        "  \"render\": \"GLES2+SW_RGBA8888\"\n"
        "}\n",
        benchId.c_str(), coreId_.c_str(), coreCommit.c_str(), romCrc32.c_str(), romSize,
        deviceModel.c_str(), osRelease.c_str(), appBuild.c_str(),
        fps_, duration, fpsAvg, fpsP5, msAvg, p95, p99,
        (unsigned long long)benchFrames_, (unsigned long long)dropped,
        audioUnderruns(), audioOverflows(), cpuAvg, rssMax_ / (1024.0 * 1024.0),
        thermal_ ? "true" : "false");
    fclose(f);
    log("bench json -> %s fps=%.3f p5=%.3f p95=%.3f rssMB=%.1f underruns=%u overflows=%u",
        outPath.c_str(), fpsAvg, fpsP5, p95, rssMax_ / (1024.0 * 1024.0),
        audioUnderruns(), audioOverflows());
    benchPhase_.store(0);
    return true;
}

bool GsRunner::saveState(std::vector<uint8_t> &out) {
    std::lock_guard<std::mutex> coreLock(coreMtx_); // vs retro_run on pace thread
    if (net_) {
        // External save slots are a desync hazard in lockstep. The frame-0
        // alignment load happens before attachNetplay() and stays allowed.
        log("[GS-Netplay] saveState rejected while in lockstep");
        return false;
    }
    size_t n = core_.serialize_size();
    if (!n) return false;
    out.resize(n);
    bool ok = core_.serialize(out.data(), n);
    if (!ok) out.clear();
    return ok;
}

bool GsRunner::loadState(const std::vector<uint8_t> &in) {
    if (in.empty()) return false;
    std::lock_guard<std::mutex> coreLock(coreMtx_); // vs retro_run on pace thread
    if (net_) {
        log("[GS-Netplay] loadState rejected while in lockstep");
        return false;
    }
    // fbalpha2012 lazily caches the savestate size inside the first
    // retro_serialize_size() call and retro_unserialize() rejects any
    // buffer whose length differs from that cache, so in a fresh process
    // the cache must be primed before unserialize or every load fails.
    const size_t want = core_.serialize_size();
    bool ok = core_.unserialize(in.data(), in.size());
    if (ok) {
        log("state restore: ok (%zu bytes)", in.size());
    } else {
        log("state restore: FAILED (file=%zu bytes, expected=%zu)", in.size(), want);
    }
    return ok;
}

void GsRunner::loadBatteryRam() {
    size_t n = core_.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (n == 0) { log("battery ram: cart has none"); return; }
    void *dst = core_.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!dst) { log("battery ram: size=%zu but no buffer", n); return; }
    std::ifstream f(sramPath_, std::ios::binary);
    if (!f) { log("battery ram: %zu bytes, no existing save at %s", n, sramPath_.c_str()); return; }
    f.seekg(0, std::ios::end);
    auto sz = f.tellg();
    f.seekg(0, std::ios::beg);
    if (sz <= 0 || static_cast<uint64_t>(sz) > n) {
        log("battery ram: save size %lld mismatches %zu, ignored",
            static_cast<long long>(sz), n);
        return;
    }
    f.read(reinterpret_cast<char *>(dst), sz);
    log("battery ram: restored %lld/%zu bytes from %s",
        static_cast<long long>(sz), n, sramPath_.c_str());
}

void GsRunner::flushBatteryRam() {
    if (!gameLoaded_) return;
    size_t n = core_.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (n == 0) return;
    void *src = core_.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!src || sramPath_.empty()) return;
    std::lock_guard<std::mutex> coreLock(coreMtx_); // vs retro_run on pace thread
    // Temp file + rename = atomic replacement, so a killed process can never
    // leave a truncated .sav.
    std::string tmp = sramPath_ + ".tmp";
    std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
    if (!f) { log("battery ram: cannot write %s", tmp.c_str()); return; }
    f.write(reinterpret_cast<const char *>(src), static_cast<std::streamsize>(n));
    f.close();
    if (std::rename(tmp.c_str(), sramPath_.c_str()) != 0) {
        log("battery ram: rename failed");
        return;
    }
    log("battery ram: flushed %zu bytes -> %s", n, sramPath_.c_str());
}

// ---------------------------------------------------------------- netplay

bool GsRunner::attachNetplay(const np::NetConfig &cfgIn) {
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    if (net_) {
        log("[GS-Netplay] attach rejected: session already active");
        return false;
    }
    np::NetConfig cfg = cfgIn;
    if (cfg.framePeriodSec <= 0.0) cfg.framePeriodSec = 1.0 / fps_;
    auto n = std::make_unique<np::GsNetplay>();
    if (!n->start(cfg)) {
        log("[GS-Netplay] UDP session start failed (peer=%s:%u)",
            cfg.peerIp.c_str(), static_cast<unsigned>(cfg.peerPort));
        return false;
    }
    netDeadLogged_ = false;
    netIsHost_ = cfg.role == np::Role::Host;
    net_ = std::move(n);
    log("[GS-Netplay] attached role=%d localPort=%u peer=%s:%u room=%u D=%d",
        static_cast<int>(cfg.role), static_cast<unsigned>(net_->localPort()),
        cfg.peerIp.c_str(), static_cast<unsigned>(cfg.peerPort),
        cfg.roomId, cfg.initialD);
    // DETERMINISM AUDIT (temporary): the frame-0 state hash the peer must also
    // start from. Serialize inline — netplayStateHash() would re-lock
    // coreMtx_, which this call already holds (std::mutex is not recursive).
    if (core_.serialize_size && core_.serialize) {
        const size_t n = core_.serialize_size();
        std::vector<uint8_t> buf(n);
        if (core_.serialize(buf.data(), n)) {
            uint64_t h = 0xcbf29ce484222325ULL;
            for (uint8_t b : buf) { h ^= b; h *= 0x100000001b3ULL; }
            log("[GS-Netplay] attach hash=%016llx size=%zu runs=%ld",
                static_cast<unsigned long long>(h), n,
                emuRuns_.load(std::memory_order_relaxed));
        }
    }
    return true;
}

uint16_t GsRunner::netplayLocalPort() {
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    return net_ ? net_->localPort() : 0;
}

void GsRunner::netplayNotifyStart() {
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    if (net_) net_->notifyStart();
}

void GsRunner::netplaySetPaused(bool paused) {
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    if (net_) net_->setLocalPaused(paused);
}

np::NetStats GsRunner::netplayStats() {
    std::lock_guard<std::mutex> coreLock(coreMtx_);
    np::NetStats s;
    if (net_) s = net_->stats();
    return s;
}

void GsRunner::netplayStop() {
    np::GsNetplay *n = nullptr;
    {
        std::lock_guard<std::mutex> coreLock(coreMtx_);
        n = net_.get();
    }
    // Safe without coreMtx_: shutdown only flips atomics/joins the receive
    // thread; the object itself is deleted in dispose() after the pace
    // thread has joined.
    if (n) {
        n->shutdown();
        log("[GS-Netplay] session stopped by local side");
    }
}

std::string GsRunner::netplayStateHash() {
    if (!net_ || !core_.serialize_size || !core_.serialize) return {};
    std::lock_guard<std::mutex> coreLock(coreMtx_); // vs anything entering retro_*
    const size_t n = core_.serialize_size();
    if (!n) return {};
    std::vector<uint8_t> buf(n);
    if (!core_.serialize(buf.data(), n)) return {};
    // FNV-1a 64 over the serialized core state: the cross-device equality
    // proof for the deterministic replay checkpoints.
    uint64_t h = 0xcbf29ce484222325ull;
    for (uint8_t b : buf) {
        h ^= b;
        h *= 0x100000001b3ull;
    }
    char out[17];
    snprintf(out, sizeof(out), "%016llx",
             static_cast<unsigned long long>(h));
    return std::string(out);
}

void GsRunner::netCheckpointHash() {
    if (!net_) return;

    // DIAGNOSTIC (temporary): arm a per-ENTRY (named) serialize-hash dump for
    // a few early frames. The MAME core reads the GP_NETPLAY_DUMP_TAG env var
    // inside save_manager::do_write() and appends "F<frame> <entry> <hash>"
    // lines to files/mame_entries.log. A cross-device diff of that file names
    // the exact diverging device/region. Must be armed BEFORE netplayStateHash()
    // below triggers the serialize that the core consumes.
    // Frames chosen to coincide with the checkpoint cadence (f=120/600/1200
    // early, then every 600) so the armed serialize actually happens; see the
    // netCheckpointHash() call site in the pacing loop.
    static const unsigned DUMP_FRAMES[] = {120, 600, 1200, 1800, 2400};
    for (unsigned f : DUMP_FRAMES) {
        if (netFrame_ == f) {
            // The MAME core is a separate .so loaded via dlopen, so we arm the
            // per-entry dump with a process env var (robust across the .so
            // boundary, no symbol export needed). save_manager::do_write()
            // reads GP_NETPLAY_DUMP_TAG, emits the dump on the serialize()
            // call just below, then unsets it.
            setenv("GP_NETPLAY_DUMP_TAG", std::to_string(static_cast<int>(netFrame_)).c_str(), 1);
            log("[GS-Netplay] arming per-entry dump for f=%llu",
                static_cast<unsigned long long>(netFrame_));
            break;
        }
    }

    const std::string hash = netplayStateHash();
    if (hash.empty()) return;
    const np::NetStats st = net_->stats();
    log("[GS-Netplay] checkpoint f=%llu hash=%s D=%d state=%d "
        "rttP50=%.2fms leadP50=%.2fms late=%llu frozen=%llu blockedMs=%llu "
        "pktIn=%llu pktOut=%llu bytesIn=%llu bytesOut=%llu "
        "dUp=%llu dDown=%llu effFps=%.2f "
        "rejTag=%llu replayDup=%llu foreign=%llu",
        static_cast<unsigned long long>(netFrame_), hash.c_str(), st.d,
        st.state, st.rttP50Ms, st.leadP50Ms,
        static_cast<unsigned long long>(st.lateFrames),
        static_cast<unsigned long long>(st.frozenFrames),
        static_cast<unsigned long long>(st.blockedMsTotal),
        static_cast<unsigned long long>(st.packetsIn),
        static_cast<unsigned long long>(st.packetsOut),
        static_cast<unsigned long long>(st.bytesIn),
        static_cast<unsigned long long>(st.bytesOut),
        static_cast<unsigned long long>(st.dUpgrades),
        static_cast<unsigned long long>(st.dDowngrades),
        st.effFps,
        static_cast<unsigned long long>(st.rejBadTag),
        static_cast<unsigned long long>(st.replayDup),
        static_cast<unsigned long long>(st.foreignPackets));
}
