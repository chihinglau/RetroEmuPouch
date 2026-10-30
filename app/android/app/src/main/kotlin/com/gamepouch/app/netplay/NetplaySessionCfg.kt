package com.retroemupouch.app.netplay

import android.content.Intent
import org.json.JSONObject

/**
 * Parsed `np_*` intent extras for one lockstep session. The same values are
 * (a) rendered into the flat cfgJson consumed by `nativeNetplayStart` and
 * (b) used by the bootstrap HTTP channel. [sessionKey] is the 32-byte bearer
 * secret for that channel — it never touches disk or the system log.
 */
class NetplaySessionCfg private constructor(
    /** 0 = host (P1), 1 = guest (P2). */
    val role: Int,
    val peerIp: String,
    val peerUdpPort: Int,
    val localUdpPort: Int,
    val sessionKey: String,
    val roomId: Int,
    val initialD: Int,
    val adaptive: Boolean,
    /** Host-only bootstrap HTTP port (guest connects to it). */
    val bootstrapPort: Int,
    val saveKey: String,
) {
    val isHost: Boolean get() = role == 0

    /** Flat JSON for NativeBridge.nativeNetplayStart. */
    fun toCfgJson(framePeriodSec: Double = 0.0): String = JSONObject().apply {
        put("role", role)
        put("peerIp", peerIp)
        put("peerPort", peerUdpPort)
        put("localPort", localUdpPort)
        put("sessionKeyHex", sessionKey)
        put("roomId", roomId)
        put("initialD", initialD)
        put("adaptive", adaptive)
        put("framePeriodSec", framePeriodSec)
    }.toString()

    companion object {
        /** Returns null when any mandatory extra is missing/malformed. */
        fun from(intent: Intent): NetplaySessionCfg? {
            if (!intent.hasExtra("np_role")) return null
            val role = intent.getIntExtra("np_role", -1)
            val peerIp = intent.getStringExtra("np_peer_ip")?.takeIf { it.isNotBlank() }
            val peerUdpPort = intent.getIntExtra("np_peer_port", 0)
            val localUdpPort = intent.getIntExtra("np_local_port", 0)
            val key = intent.getStringExtra("np_session_key")
            val roomId = intent.getIntExtra("np_room_id", 0)
            val bootstrapPort = intent.getIntExtra("np_bootstrap_port", 0)
            val saveKey = intent.getStringExtra("np_save_key")?.takeIf { it.isNotBlank() }
            if (role !in 0..1) return null
            if (peerIp == null || key == null || saveKey == null) return null
            if (!key.matches(Regex("^[0-9a-f]{64}$"))) return null
            if (peerUdpPort !in 1..65535 || localUdpPort !in 1..65535) return null
            if (bootstrapPort !in 1..65535 || roomId == 0) return null
            return NetplaySessionCfg(
                role = role,
                peerIp = peerIp,
                peerUdpPort = peerUdpPort,
                localUdpPort = localUdpPort,
                sessionKey = key,
                roomId = roomId,
                initialD = intent.getIntExtra("np_initial_d", 2).coerceIn(1, 2),
                adaptive = intent.getBooleanExtra("np_adaptive", true),
                bootstrapPort = bootstrapPort,
                saveKey = saveKey,
            )
        }
    }
}
