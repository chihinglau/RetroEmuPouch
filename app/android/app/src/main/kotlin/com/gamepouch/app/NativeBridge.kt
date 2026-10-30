package com.retroemupouch.app

import java.nio.ByteBuffer

/**
 * JNI bindings to libgsrunner.so. The runner itself is core-agnostic; the
 * active emulator core is libgs_<coreId>.so, resolved with dlopen at init.
 */
object NativeBridge {
    init { System.loadLibrary("gsrunner") }

    /**
     * Returns non-zero handle, 0 on failure. [coreId] selects the core .so
     * (fceumm/gambatte/mgba/picodrive/stella2014). [saveKey] names per-game
     * save files (<saveDir>/<saveKey>.sav); pass the ROM CRC32 hex when known.
     * [netplayColdBoot] makes the core start from the deterministic default
     * instead of per-device NVRAM files, so both lockstep peers cold-boot
     * identically (a netplay session cold-boots independently by design).
     */
    external fun nativeInit(
        coreId: String,
        romPath: String, saveDir: String, systemDir: String, logPath: String,
        saveKey: String, netplayColdBoot: Boolean
    ): Long

    external fun nativeDispose(handle: Long)

    /** Attach a direct ByteBuffer used as the RGBA8888 frame target. */
    external fun nativeAttachPixels(handle: Long, buffer: ByteBuffer)

    /** Retro pad bitmask, bit i = RETRO_DEVICE_ID_JOYPAD_*. */
    external fun nativeSetButtons(handle: Long, mask: Int)

    /**
     * Queue a frame-by-frame input macro (one-button special move). Each entry
     * is the RETRO pad mask to hold for one emulated frame; consumed one per
     * frame and OR'd into the driven pad. Replaces any in-flight macro; an
     * empty array clears it. Ignored during netplay (lockstep determinism).
     */
    external fun nativePlayMacro(handle: Long, seq: IntArray)

    /** Cancel any in-flight input macro. */
    external fun nativeClearMacro(handle: Long)

    /**
     * Select the libretro pad port the single on-screen pad drives
     * (0 = 1P, 1 = 2P). The other player port reads all buttons up.
     */
    external fun nativeSetPlayerPort(handle: Long, port: Int)

    /**
     * Runs one emulated frame synchronously. Used once as a geometry probe
     * before the pacing thread takes over. [width, height, pitchBytes] or null.
     */
    external fun nativeRunFrame(handle: Long): IntArray?

    /** Core-reported display aspect ratio (W/H); 0 when unspecified. */
    external fun nativeAspect(handle: Long): Float

    /** Starts the dedicated native emulation pacing thread. */
    external fun nativeStartPacing(handle: Long)

    /**
     * Copies the latest frame produced by the pacing thread into the attached
     * ByteBuffer. Returns [width, height, pitchBytes], or null when no new frame
     * has been published since the last pump.
     */
    external fun nativePumpFrame(handle: Long): IntArray?

    external fun nativeSetAudioPaused(handle: Long, paused: Boolean)

    /** Pauses/resumes both the emulation pacing thread and audio output. */
    external fun nativeSetPaused(handle: Long, paused: Boolean)

    /**
     * Emulation speed multiplier: 1 (normal) or 2/4/6/8 fast-forward.
     * Video frames are produced faster (display keeps only the latest per
     * vsync); audio is decimated and plays back at Nx tempo/pitch.
     */
    external fun nativeSetSpeed(handle: Long, multiplier: Int)

    /**
     * Replaces the active cheat set with the given enabled codes. The core
     * parses Game Genie / raw XXXX:XX / XXXX?XX:XX / PAR codes.
     */
    external fun nativeSetCheats(handle: Long, codes: Array<String>)

    /** Returns audio xrun (underrun/overflow) count. */
    external fun nativeAudioXruns(handle: Long): Int

    external fun nativeBenchStart(handle: Long, warmupSeconds: Int, sampleSeconds: Int)

    /** 0 = idle/no bench, 1 = warm-up, 2 = sampling, 3 = finished. */
    external fun nativeBenchPhase(handle: Long): Int

    /** Writes the bench result JSON. Returns false on failure. */
    external fun nativeBenchFinish(
        handle: Long,
        outPath: String,
        benchId: String,
        coreCommit: String,
        appBuild: String,
        romCrc32: String,
        romSize: Long,
        deviceModel: String,
        osRelease: String
    ): Boolean

    external fun nativeSaveState(handle: Long): ByteArray?
    external fun nativeLoadState(handle: Long, data: ByteArray): Boolean

    // ---- netplay (Phase 1 lockstep) ----

    /**
     * Attach a lockstep UDP session before nativeStartPacing(). [cfgJson]
     * is a flat JSON object:
     * {"role":0(host)|1(guest),"peerIp","peerPort","localPort"(0=ephemeral),
     *  "sessionKeyHex"(64 hex),"roomId","initialD"(1|2, production=2),
     *  "framePeriodSec"(0=core fps),"adaptive"(true)}.
     * Returns false on bad config or socket failure; the runner stays usable.
     */
    external fun nativeNetplayStart(handle: Long, cfgJson: String): Boolean

    /** CTRL_BYE + teardown. Idempotent. */
    external fun nativeNetplayStop(handle: Long)

    /** This side's live retropad mask (retro pad bits). */
    external fun nativeNetplayLocalMask(handle: Long, mask: Int)

    /** Host: open the START gate and announce CTRL_START. */
    external fun nativeNetplayNotifyStart(handle: Long)

    /** Local pause intent -> CTRL_PAUSE/RESUME, gate parks on both sides. */
    external fun nativeNetplayNotifyPaused(handle: Long, paused: Boolean)

    /** Fixed-layout stats vector, see [NetplayStats.fromVector]. */
    external fun nativeNetplayStats(handle: Long): DoubleArray

    /** FNV-1a64 hex of the serialized core state (determinism checkpoint). */
    external fun nativeNetplayStateHash(handle: Long): String?

    /** Atomic-write saves/<key>.sav from live cart SaveRAM (host end-of-session). */
    external fun nativeNetplayFlushSram(handle: Long)

}

/** Snapshot of the native lockstep session (fixed-layout JNI vector). */
data class NetplayStats(
    val state: Int,
    val d: Int,
    val started: Boolean,
    val rttMinMs: Double,
    val rttP50Ms: Double,
    val rttP95Ms: Double,
    val rttP99Ms: Double,
    val leadP50Ms: Double,
    val leadP95Ms: Double,
    val framesAdvanced: Long,
    val lateFrames: Long,
    val frozenFrames: Long,
    val packetsIn: Long,
    val packetsOut: Long,
    val bytesIn: Long,
    val bytesOut: Long,
    val redundantSends: Long,
    val effFps: Double,
    val rejBadLen: Long,
    val rejBadMagic: Long,
    val rejBadVersion: Long,
    val rejBadTag: Long,
    val replayDup: Long,
    val replayOld: Long,
    val foreignPackets: Long,
    val dUpgrades: Long,
    val dDowngrades: Long,
    val blockedMsTotal: Long,
) {
    /** np::NetState mirror. */
    val isRunning: Boolean get() = state == STATE_RUNNING
    /** 10 s frame timeout / peer killed / network down: keep the local SRAM. */
    val isDropped: Boolean get() = state == STATE_DROPPED
    /** Peer sent CTRL_BYE (clean leave): the host's final SRAM is authoritative. */
    val isPeerBye: Boolean get() = state == STATE_ENDED
    val isPaused: Boolean get() = state == STATE_PAUSED

    companion object {
        const val STATE_IDLE = 0
        const val STATE_STARTING = 1
        const val STATE_RUNNING = 2
        const val STATE_DROPPED = 3
        const val STATE_ENDED = 4
        const val STATE_PAUSED = 5

        fun fromVector(v: DoubleArray?): NetplayStats? {
            if (v == null || v.size < 28) return null
            fun d(i: Int) = v[i]
            return NetplayStats(
                state = d(0).toInt(),
                d = d(1).toInt(),
                started = d(2) != 0.0,
                rttMinMs = d(3),
                rttP50Ms = d(4),
                rttP95Ms = d(5),
                rttP99Ms = d(6),
                leadP50Ms = d(7),
                leadP95Ms = d(8),
                framesAdvanced = d(9).toLong(),
                lateFrames = d(10).toLong(),
                frozenFrames = d(11).toLong(),
                packetsIn = d(12).toLong(),
                packetsOut = d(13).toLong(),
                bytesIn = d(14).toLong(),
                bytesOut = d(15).toLong(),
                redundantSends = d(16).toLong(),
                effFps = d(17),
                rejBadLen = d(18).toLong(),
                rejBadMagic = d(19).toLong(),
                rejBadVersion = d(20).toLong(),
                rejBadTag = d(21).toLong(),
                replayDup = d(22).toLong(),
                replayOld = d(23).toLong(),
                foreignPackets = d(24).toLong(),
                dUpgrades = d(25).toLong(),
                dDowngrades = d(26).toLong(),
                blockedMsTotal = d(27).toLong(),
            )
        }
    }
}
