package com.retroemupouch.app.netplay

import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Lightweight append-only diagnostics for the netplay bootstrap phase.
 *
 * The HarmonyOS AOSP compatibility layer hides third-party logcat, so the
 * bootstrap handshake (which runs before the native runner creates its own
 * run-*.log) would otherwise be completely unobservable on real devices.
 * EmulatorActivity points [dir] at filesDir/logs once, on create.
 */
object NpLog {
    @Volatile private var dir: File? = null
    private val ts = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    fun init(logsDir: File) {
        dir = logsDir
    }

    fun log(msg: String) {
        Log.i("GS-NetBoot", msg)
        val d = dir ?: return
        try {
            val f = File(d, "netboot.log")
            f.appendText("${ts.format(Date())} $msg\n")
        } catch (_: Throwable) { /* diagnostics must never break flow */ }
    }
}
