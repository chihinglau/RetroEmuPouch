#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include <deque>
#include <atomic>
#include <cstdio>
#include <thread>
#include <mutex>
#include <condition_variable>

#include "gs_core.h"
#include "gs_netplay.h"

extern "C" {
#include <libretro.h>
}

/**
 * Minimal libretro frontend runner.
 * - RGBA8888 frame target (tightly packed, width*height*4)
 * - SPSC audio ring consumed by an AAudio low-latency stream
 * - single retro pad (bit i = RETRO_DEVICE_ID_JOYPAD_i)
 * - self-contained file logging (HarmonyOS 4.2 AOSP layer hides logcat)
 * - built-in wall-clock benchmark with JSON export
 */
class GsRunner {
public:
    static constexpr int MAX_W = 1024;
    static constexpr int MAX_H = 1024;

    GsRunner();
    ~GsRunner();

    bool init(const std::string &coreId, const std::string &romPath,
              const std::string &saveDir, const std::string &systemDir,
              const std::string &logPath, const std::string &saveKey,
              bool netplayColdBoot = false);
    void dispose();

    // Kotlin direct ByteBuffer the GL thread uploads from. The emulation thread
    // never writes here directly; pumpFrame() copies the latest published frame
    // into it under a short lock.
    void attachPixels(void *p) { extPixels_ = p; }
    void setButtons(uint32_t mask) { buttons_.store(mask, std::memory_order_relaxed); }
    /**
     * Queue a frame-by-frame input macro for one-button special moves. Each
     * entry is the RETRO pad mask to hold for one emulated frame; the pace
     * thread consumes one entry per frame (onInputPoll) and onInputState ORs
     * the current step into the driven pad. Replaces any in-flight macro;
     * ignored while a netplay session is attached (lockstep must stay
     * deterministic). An empty [frames] clears the macro.
     */
    void playMacro(const std::vector<uint32_t> &frames);
    void clearMacro();
    /**
     * Select which libretro pad port (0 = 1P, 1 = 2P) the single on-screen
     * pad drives. Only that port reports input; the other reads all buttons
     * up. Arcade cabinets expose coin/start per player through the same
     * retropad (SELECT = coin, START = start), so picking the port also
     * picks whose coin/start the 投币 / 开始 pills trigger.
     */
    void setActivePort(int port) {
        activePort_.store(port == 1 ? 1 : 0, std::memory_order_relaxed);
    }
    void setAudioPaused(bool paused);
    /** Pause/resume the dedicated emulation pacing thread (+ audio). */
    void setPaused(bool paused);
    /**
     * Emulation speed multiplier (1 = normal). Allowed: 1/2/4/6/8.
     * The pacing thread runs N frames per normal frame period while the GL
     * thread still shows only the latest published frame per vsync (frame
     * skip). Audio is decimated to the fixed HAL rate and plays back at Nx
     * tempo/pitch (no mute, no ring overflow).
     */
    void setSpeed(int mult);
    int speed() const { return speed_.load(std::memory_order_relaxed); }

    /**
     * Replaces the active cheat set (codes only, enabled entries). The core
     * accepts Game Genie (6/8 letters), raw "XXXX:XX" / "XXXX?XX:XX" and
     * 8-hex Pro Action Replay codes; multiple codes may be joined with '+'.
     * Safe to call at run time (serialized with retro_run); call once after
     * the game is loaded to seed the initial set.
     */
    void setCheats(const std::vector<std::string> &codes);

    /**
     * Runs one frame synchronously (used once to learn geometry before the
     * pacing thread is started). Geometry via w/h/pitch (pitch always w*4).
     */
    bool runFrame(int &w, int &h, int &pitch);

    /**
     * Display aspect ratio (W/H) reported by the core via geometry, or 0 when
     * the core leaves it unspecified (caller falls back to square pixels).
     */
    double aspectRatio() const { return aspectRatio_; }

    /** Spawns the dedicated emulation thread after the geometry probe. */
    void startPacing();
    /**
     * Called by the GL thread every vsync. If the emulation thread has published
     * a new frame, copies it tightly packed into the attached ByteBuffer and
     * returns its geometry; returns false when no new frame is available.
     */
    bool pumpFrame(int &w, int &h, int &pitch);

    uint32_t audioXruns() const { return xruns_.load(std::memory_order_relaxed); }
    /** Real output underruns plus stream error callbacks (the M3 threshold metric). */
    uint32_t audioUnderruns() const {
        return underruns_.load(std::memory_order_relaxed) + aerrors_.load(std::memory_order_relaxed);
    }
    uint32_t audioOverflows() const { return overflows_.load(std::memory_order_relaxed); }

    void benchStart(int warmupSeconds, int sampleSeconds);
    /** 0 idle, 1 warmup, 2 sampling, 3 finished. */
    int benchPhase() const;
    bool benchFinish(const std::string &outPath, const std::string &benchId,
                     const std::string &coreCommit, const std::string &appBuild,
                     const std::string &romCrc32, long romSize,
                     const std::string &deviceModel, const std::string &osRelease);

    bool saveState(std::vector<uint8_t> &out);
    bool loadState(const std::vector<uint8_t> &in);

    /** Persists the cart's battery-backed save RAM (in-game saves) to disk. */
    void flushBatteryRam();

    // ---- netplay (Phase 1) ----
    // Attaches a lockstep session BEFORE startPacing(): binds the UDP
    // socket and starts the receive thread, but frames stay gated until the
    // host calls netplayNotifyStart() (guest releases on CTRL_START).
    // Returns false when a session is already attached or the socket fails.
    bool attachNetplay(const np::NetConfig &cfg);
    uint16_t netplayLocalPort();
    void netplayNotifyStart();
    /** Local pause intent: sends CTRL_PAUSE/RESUME and parks the gate. */
    void netplaySetPaused(bool paused);
    /** Local player's retropad mask (UI thread -> pace thread). */
    void netplayLocalMask(uint16_t mask) {
        netLocalMask_.store(mask, std::memory_order_relaxed);
    }
    np::NetStats netplayStats();
    /** Sends CTRL_BYE and tears the session down; idempotent. */
    void netplayStop();
    /**
     * FNV-1a64 hex of the full serialized core state (empty string if no
     * session/core). Debug/determinism checkpoint callable off the pace
     * thread; serializes under coreMtx_.
     */
    std::string netplayStateHash();

    // accessors for the C-style variadic core log shim (gsCoreLog)
    static GsRunner *instance() { return s_self; }
    bool hasLogFile() const { return logFile_ != nullptr; }
    FILE *logFile() const { return logFile_; }

private:
    // ---- libretro callbacks ----
    static bool onEnvironment(unsigned cmd, void *data);
    static void onVideoRefresh(const void *data, unsigned width, unsigned height, size_t pitch);
    static size_t onAudioBatch(const int16_t *data, size_t frames);
    static void onInputPoll();
    static int16_t onInputState(unsigned port, unsigned device, unsigned index, unsigned id);
    static void onLog(enum retro_log_level level, const char *fmt, ...);

    bool setupAudio(double sampleRate);
    void teardownAudio();
    /** Appends interleaved stereo samples to the AAudio producer ring. */
    void pushSamples(const int16_t *data, uint32_t stereoSamples);
    /** Loads the cart battery RAM image (<saveDir>/<rom>.sav) into the core. */
    void loadBatteryRam();
    void log(const char *fmt, ...);
    void sampleProc(double now);
    void pacingLoop();

    // instance for static callbacks (single runner)
    static GsRunner *s_self;

    // Dynamically loaded libretro core (libgs_<coreId>.so).
    GsCoreApi core_;
    std::string coreId_;

    bool initialized_ = false;
    bool gameLoaded_ = false;
    // Video double buffer: emulation thread writes emuBack_ (via the static
    // video callback), then swaps it with renderFront_ under frameMtx_. The GL
    // thread copies renderFront_ into extPixels_ for upload.
    std::vector<uint32_t> emuBack_;
    std::vector<uint32_t> renderFront_;
    void *pixels_ = nullptr;    // -> emuBack_.data() while initialized
    void *extPixels_ = nullptr; // Kotlin direct ByteBuffer
    std::mutex frameMtx_;
    int pubW_ = 256, pubH_ = 240;
    uint64_t publishedSeq_ = 0, pumpedSeq_ = 0;

    // serializes core entry (retro_run vs save/load state from the GL thread)
    std::mutex coreMtx_;

    // dedicated emulation pacing thread
    std::thread paceThread_;
    std::atomic<bool> pacing_{false};
    std::atomic<bool> pacePaused_{false};
    std::mutex pauseMtx_;
    std::condition_variable paceCv_;

    int fbW_ = 256, fbH_ = 240;
    // Core-reported display aspect ratio (0 = unspecified -> square pixels).
    double aspectRatio_ = 0.0;
    double fps_ = 60.0988;
    double sampleRate_ = 48000.0;
    retro_pixel_format pixFmt_ = RETRO_PIXEL_FORMAT_0RGB1555;

    std::atomic<uint32_t> buttons_{0};
    // Currently driven libretro pad port: 0 = 1P, 1 = 2P. Only this port
    // reports [buttons_]; the other player reads all buttons released.
    std::atomic<int> activePort_{0};

    // ---- input macro (one-button special moves) ----
    // playMacro() (UI thread) replaces the frame sequence under macroMtx_; the
    // pace thread advances it one step per emulated frame in onInputPoll and
    // onInputState ORs the current step (macroMask_) into the driven pad.
    void advanceMacro(); // pace thread only, called from onInputPoll
    std::mutex macroMtx_;
    std::deque<uint32_t> macroQueue_;
    std::atomic<uint32_t> macroMask_{0};

    // ---- netplay state ----
    // The pointer is created in attachNetplay() before pacing starts and
    // deleted in dispose() after the pace thread joins; the pace thread
    // reads it without a lock. Shutdown flips the session to a dead state
    // (frame gate parks), it never frees the object mid-frame.
    std::unique_ptr<np::GsNetplay> net_;
    bool netIsHost_ = false; // selects local->retropad port mapping
    std::atomic<uint32_t> netLocalMask_{0}; // local player mask from the UI
    uint16_t netButtons_[2] = {0, 0};       // gated masks for the current frame
    uint64_t netFrame_ = 0;                 // frames released to the core
    bool netDeadLogged_ = false;            // one-shot dead-session log
    uint16_t netDbgPrevLm_ = 0xFFFF;        // edge-log local/remote masks
    uint16_t netDbgPrevRm_ = 0xFFFF;
    void netCheckpointHash();               // f=120/600/1200/1800 debug log
    std::atomic<bool> audioPaused_{false};
    // 1 = normal speed; 2/4/6/8 = fast-forward (frames produced faster, audio
    // muted). Switched from the UI thread, read every frame by the pace thread.
    std::atomic<int> speed_{1};

    std::string romPath_, saveDir_, systemDir_, logPath_;
    // Netplay: a pristine per-process save directory handed to the core instead
    // of the user's own. MAME restores per-device bookkeeping (coin counters)
    // from <saveDir>/mame/cfg/<game>.cfg, so two phones that have been played a
    // different amount boot with DIFFERENT counters and desync from frame 0.
    // A fresh empty directory makes both ends start from the core defaults.
    bool netplayColdBoot_ = false;
    std::string npSaveDir_;
    // Total retro_run() calls (determinism audit: compare with the peer's).
    std::atomic<long> emuRuns_{0};
    // Stable per-game storage key (CRC32 when known, else ROM file base).
    std::string saveKey_;
    // <saveDir>/<romBase>.sav: battery-backed cart WRAM (in-game saves).
    std::string sramPath_;
    FILE *logFile_ = nullptr;
    std::vector<uint8_t> romBytes_;
    // Region forced from the cart: "" = Auto, "PAL", or "Dendy".
    std::string forcedRegion_;
    retro_game_info gameInfo_{};

    // ---- audio ----
    void *audioStream_ = nullptr; // AAudioStream* (opaque here)
    bool audioReady_ = false;
    static constexpr uint32_t RING_CAP = 1u << 17; // samples (stereo interleaved)
    std::vector<int16_t> ring_;
    std::atomic<uint32_t> rPos_{0}, wPos_{0};
    std::atomic<uint32_t> xruns_{0};          // total: underruns+overflows+errors (HUD)
    std::atomic<uint32_t> underruns_{0};      // AAudio callback found < requested frames
    std::atomic<uint32_t> overflows_{0};      // producer ring full, samples dropped
    std::atomic<uint32_t> aerrors_{0};        // AAudio error/disconnect callbacks
    std::atomic<bool> streamRunning_{false};
    // Defer AAudio requestStart until the ring holds ~PREFILL_SECONDS of audio so
    // normal GL-thread scheduling jitter (< burst) cannot starve the callback.
    bool audioStartPending_ = false;
    uint32_t audioPrefillSamples_ = 0;
    // TEMP pacing/audio diagnostics
    std::atomic<uint64_t> audioProdFrames_{0}, audioBatches_{0};

    // Fast-forward audio decimator (touched only by the pace thread inside
    // retro_run; reset under coreMtx_ when speed changes): groups of N core
    // samples are boxcar-averaged into one so sped-up music is played at Nx
    // tempo/pitch into the fixed-rate HAL instead of overflowing the ring.
    int32_t ffSumL_ = 0, ffSumR_ = 0;
    uint32_t ffCarry_ = 0;
    std::vector<int16_t> ffOut_;

    // ---- benchmark ----
    // Written by the pacing thread, polled/read by the GL thread.
    std::atomic<int> benchPhase_{0};
    double benchWarmupEnd_ = 0, benchSampleStart_ = 0, benchSampleEnd_ = 0;
    std::vector<double> frameMs_;
    std::vector<int> secondBuckets_;
    uint64_t benchFrames_ = 0;
    int currentSecond_ = -1;
    double cpuAcc_ = 0; int cpuSamples_ = 0;
    double lastCpuTime_ = 0; double lastCpuNs_ = 0;
    uint64_t rssMax_ = 0;
    bool thermal_ = false;
    long jiffiesPerSec_ = 100;
    long pageSize_ = 4096;
};
