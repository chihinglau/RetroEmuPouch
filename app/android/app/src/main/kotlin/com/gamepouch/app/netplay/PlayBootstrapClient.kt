package com.retroemupouch.app.netplay

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Guest-side counterpart of [PlayBootstrapServer]. Every call carries the
 * session key as a bearer token. Uses a raw [Socket] with one-shot request
 * writes (the protocol is four trivial routes) instead of HttpURLConnection:
 * the request line + headers are assembled into one byte[] and sent in a
 * single write, so request segmentation can never interact with the server's
 * line-oriented parser.
 */
class PlayBootstrapClient(
    private val peerIp: String,
    private val port: Int,
    private val sessionKey: String,
) {
    sealed class SramResult {
        /** Host has no SRAM: the guest must boot without (and park its own). */
        object Absent : SramResult()
        data class Present(val data: ByteArray) : SramResult()
    }

    private class Response(val code: Int, val body: ByteArray)

    /** Before runner init: pull the host battery save, or learn there is none. */
    fun fetchSram(): SramResult {
        val r = request("GET", "/sram")
        return when (r.code) {
            204 -> SramResult.Absent
            200 -> SramResult.Present(r.body)
            else -> throw BootstrapException("sram http ${r.code}")
        }
    }

    /** After geometry probe: pull host frame-0 state (host may block briefly). */
    fun fetchState0(): ByteArray {
        val r = request("GET", "/state0")
        if (r.code != 200) throw BootstrapException("state0 http ${r.code}")
        return r.body
    }

    fun postReady() {
        val r = request("POST", "/ready")
        if (r.code != 200) throw BootstrapException("ready http ${r.code}")
    }

    /** Long-poll the host START gate; throws on timeout/5xx. */
    fun awaitStart() {
        val r = request("GET", "/start")
        if (r.code != 200) throw BootstrapException("start http ${r.code}")
    }

    /**
     * Clean-session-end convergence: null when the host has no final SRAM
     * (cart without battery RAM) or it could not be fetched within timeout.
     */
    fun fetchSramFinal(): ByteArray? {
        // Teardown-only best-effort pull: the host is already going away, so
        // use ONE short-connect attempt instead of the boot path's 20 s
        // retry window (which would keep the "返回游戏库" button spinning
        // through ~21 futile reconnects when the host's server has closed).
        return try {
            val r = oneRequest("GET", "/sram-final", connectTimeoutMs = 3_000)
            if (r.code == 200) r.body else {
                NpLog.log("guest /sram-final non-200 (${r.code}), keep local SRAM")
                null
            }
        } catch (t: Throwable) {
            // Server's post-exit grace window may have expired; the lockstep
            // core's own deterministic SRAM flush remains the fallback.
            NpLog.log("guest /sram-final failed ${t.javaClass.simpleName}: keep local SRAM")
            null
        }
    }

    /**
     * One TCP request per call, serialized by the np-ctl thread. The whole
     * request (line + headers + terminator) is assembled first and written
     * in a single write so it leaves in one segment; the reply is read to
     * EOF because the server always replies `Connection: close`.
     */
    private fun request(method: String, path: String): Response =
        withConnectRetry(method, path) { oneRequest(method, path, 10_000) }

    private fun oneRequest(method: String, path: String, connectTimeoutMs: Int): Response {
            NpLog.log("guest raw-connect $peerIp:$port$path ($method)")
            Socket().use { sock ->
                sock.connect(InetSocketAddress(peerIp, port), connectTimeoutMs)
                sock.soTimeout = 35_000
                sock.tcpNoDelay = true
                val out = BufferedOutputStream(sock.getOutputStream())
                val req = buildString {
                    append(method).append(' ').append(path).append(" HTTP/1.1\r\n")
                    append("Host: ").append(peerIp).append(':').append(port).append("\r\n")
                    append("Authorization: Bearer ").append(sessionKey).append("\r\n")
                    append("Connection: close\r\n")
                    append("\r\n")
                }
                val reqBytes = req.toByteArray(Charsets.US_ASCII)
                out.write(reqBytes)
                out.flush()
                NpLog.log("guest wrote ${reqBytes.size} request bytes to $path")

                val rawIn = sock.getInputStream()
                // Read until EOF (Connection: close) or the read timeout.
                val buf = ByteArray(8192)
                val acc = ByteArrayOutputStream()
                while (true) {
                    val n = try { rawIn.read(buf) } catch (e: java.io.IOException) {
                        if (acc.size() > 0) {
                            NpLog.log("guest read ended ${e.javaClass.simpleName} after ${acc.size()} bytes")
                            -1
                        } else throw e
                    }
                    if (n <= 0) break
                    acc.write(buf, 0, n)
                    if (acc.size() > MAX_RESPONSE) {
                        throw BootstrapException("response too large for $path")
                    }
                }
                return parseResponse(path, acc.toByteArray())
            }
    }

    private fun parseResponse(path: String, raw: ByteArray): Response {
        val text = String(raw, Charsets.ISO_8859_1)
        val headerEnd = text.indexOf("\r\n\r\n")
        if (headerEnd < 0) throw BootstrapException("malformed response for $path")
        val head = text.substring(0, headerEnd)
        val firstLine = head.lineSequence().firstOrNull()
            ?: throw BootstrapException("empty response for $path")
        val parts = firstLine.split(' ')
        if (parts.size < 2 || !parts[0].startsWith("HTTP/")) {
            throw BootstrapException("bad status line for $path: $firstLine")
        }
        val code = parts[1].toIntOrNull()
            ?: throw BootstrapException("bad status code for $path")
        var bodyLen = -1
        for (line in head.lineSequence().drop(1)) {
            val idx = line.indexOf(':')
            if (idx > 0 && line.substring(0, idx).trim().equals("content-length", true)) {
                bodyLen = line.substring(idx + 1).trim().toIntOrNull() ?: -1
            }
        }
        val body = raw.copyOfRange(headerEnd + 4, raw.size)
        if (bodyLen >= 0 && body.size != bodyLen) {
            NpLog.log("guest $path body ${body.size} != content-length $bodyLen")
        }
        NpLog.log("guest $path -> $code (${body.size} body bytes)")
        return Response(code, body)
    }

    /**
     * The host signals /start BEFORE its own EmulatorActivity (and therefore
     * the bootstrap ServerSocket) is up, so the guest's first connection
     * attempts can be refused. Retry ONLY connect-level failures within a
     * short window; HTTP status failures surface immediately.
     */
    private fun <T> withConnectRetry(method: String, path: String, op: () -> T): T {
        val deadline = System.currentTimeMillis() + 20_000
        var attempt = 0
        while (true) {
            attempt++
            try {
                return op()
            } catch (e: java.io.IOException) {
                NpLog.log("guest $method $path attempt $attempt ${e.javaClass.simpleName}: ${e.message}")
                val connectRace = e is java.net.ConnectException ||
                    (e is java.net.SocketTimeoutException &&
                        e.message?.contains("connect", ignoreCase = true) == true)
                if (!connectRace || System.currentTimeMillis() >= deadline) throw e
                try { Thread.sleep(minOf(300L * attempt, 1_000L)) } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt(); throw e
                }
            }
        }
    }

    companion object {
        private const val MAX_RESPONSE = 32 * 1024 * 1024
    }
}

class BootstrapException(message: String) : Exception(message)

/**
 * Atomically replace [target] with [bytes] (temp file + rename), keeping one
 * `.preplay` backup of the pre-session file for disaster recovery.
 */
fun atomicWriteWithBackup(target: java.io.File, bytes: ByteArray, backupSuffix: String = ".preplay") {
    target.parentFile?.mkdirs()
    if (target.exists() && !java.io.File(target.absolutePath + backupSuffix).exists()) {
        try { target.copyTo(java.io.File(target.absolutePath + backupSuffix), overwrite = false) }
        catch (_: Throwable) { /* backup best effort */ }
    }
    val tmp = java.io.File(target.absolutePath + ".np-tmp")
    tmp.writeBytes(bytes)
    if (!tmp.renameTo(target)) {
        // rename across caches can fail; fall back to copy+delete.
        tmp.copyTo(target, overwrite = true)
        tmp.delete()
    }
}
