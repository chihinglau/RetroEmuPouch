package com.retroemupouch.app.netplay

import android.util.Log
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Host-side, single-session bootstrap HTTP/1.1 server.
 *
 * Routes (all require `Authorization: Bearer <sessionKey>`):
 *  - GET  /sram        : host saves/<saveKey>.sav, or 204 when absent.
 *  - GET  /state0      : blocks until the host runner published frame-0
 *                        serialized state (30 s → 503).
 *  - POST /ready       : guest announces state0 is loaded; releases the
 *                        host's [awaitGuestReady].
 *  - GET  /start       : long-poll until the host opens the START gate.
 *  - GET  /sram-final  : blocks until the host publishes its flushed SRAM
 *                        at clean session end (30 s → 503).
 *
 * Deliberately dependency-free (ServerSocket + a 2-thread pool): the guest
 * issues the calls strictly serially, so two worker threads are enough even
 * with one long-poll in flight.
 */
class PlayBootstrapServer(
    private val port: Int,
    private val sessionKey: String,
    private val sramFile: File,
) : Closeable {

    private val workers = Executors.newFixedThreadPool(2)
    private var server: ServerSocket? = null
    @Volatile private var stopped = false

    private val state0Latch = CountDownLatch(1)
    private val readyLatch = CountDownLatch(1)
    private val startLatch = CountDownLatch(1)
    private val sramFinalLatch = CountDownLatch(1)

    @Volatile private var state0: ByteArray? = null
    @Volatile private var sramFinal: ByteArray? = null
    // Set once the converged SRAM has actually been delivered to the guest;
    // the host's teardown watchdog closes early on this instead of waiting
    // the full grace window.
    private val sramFinalServed = java.util.concurrent.atomic.AtomicBoolean(false)

    /** True after the guest successfully pulled /sram-final. */
    fun finalSramServed(): Boolean = sramFinalServed.get()

    @Throws(Exception::class)
    fun start() {
        val srv = ServerSocket()
        srv.reuseAddress = true
        srv.bind(InetSocketAddress(port))
        server = srv
        workers.execute { acceptLoop(srv) }
        NpLog.log("bootstrap server listening on 0.0.0.0:$port")
        Log.i(TAG, "bootstrap server listening on $port")
    }

    private fun acceptLoop(srv: ServerSocket) {
        while (!stopped) {
            val sock = try {
                srv.accept()
            } catch (t: Throwable) {
                if (stopped) return
                NpLog.log("srv accept threw ${t.javaClass.simpleName}: ${t.message}")
                continue
            }
            NpLog.log("srv accepted from ${sock.remoteSocketAddress}, queue handle")
            workers.execute { handle(sock) }
        }
    }

    private fun handle(sock: Socket) {
        val peer = sock.remoteSocketAddress
        NpLog.log("srv handle ENTER from $peer on ${Thread.currentThread().name}")
        try {
            sock.soTimeout = 35_000
            sock.use { s ->
                // ONE BufferedReader for the whole request: a second wrapper
                // would start with an empty 8 KB buffer while the headers are
                // already stranded in the first wrapper's buffer.
                val reader = s.getInputStream().bufferedReader()
                val tReq = System.currentTimeMillis()
                val requestLine = reader.readLine() ?: run {
                    NpLog.log("srv conn from $peer: empty request line (after ${System.currentTimeMillis() - tReq}ms)")
                    return
                }
                NpLog.log("srv request line from $peer after ${System.currentTimeMillis() - tReq}ms: $requestLine")
                val parts = requestLine.split(' ')
                if (parts.size < 3) {
                    NpLog.log("srv conn from $peer: bad request line '$requestLine' -> 400")
                    send(s, 400, "bad request", null); return
                }
                val method = parts[0]
                val path = parts[1].substringBefore('?')
                val headers = HashMap<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val idx = line.indexOf(':')
                    if (idx > 0) {
                        headers[line.substring(0, idx).trim().lowercase()] =
                            line.substring(idx + 1).trim()
                    }
                }
                val auth = headers["authorization"]
                if (auth != "Bearer $sessionKey") {
                    NpLog.log("srv $method $path from $peer auth mismatch " +
                        "(got ${if (auth == null) "none" else "len=" + auth.length}) -> 401")
                    Log.w(TAG, "bootstrap 401 on $method $path")
                    send(s, 401, "unauthorized", null)
                    return
                }
                NpLog.log("srv $method $path from $peer authed")
                route(s, method, path)
            }
        } catch (t: Throwable) {
            // Socket timeout / client gone — single-request connections only.
            NpLog.log("srv conn from $peer threw ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun route(s: Socket, method: String, path: String) {
        when {
            method == "GET" && path == "/sram" -> {
                val data = if (sramFile.exists()) {
                    try { sramFile.readBytes() } catch (_: Throwable) { null }
                } else null
                if (data == null) send(s, 204, "no sram", null)
                else send(s, 200, "application/octet-stream", data)
            }
            method == "GET" && path == "/state0" -> {
                if (!state0Latch.await(30, TimeUnit.SECONDS)) {
                    send(s, 503, "state0 not ready", null); return
                }
                val b = state0
                if (b == null) send(s, 503, "state0 failed", null)
                else send(s, 200, "application/octet-stream", b)
            }
            method == "POST" && path == "/ready" -> {
                readyLatch.countDown()
                send(s, 200, "application/json", "{\"ok\":true}".toByteArray())
            }
            method == "GET" && path == "/start" -> {
                if (!startLatch.await(30, TimeUnit.SECONDS)) {
                    send(s, 503, "start timeout", null); return
                }
                send(s, 200, "application/json", "{\"ok\":true}".toByteArray())
            }
            method == "GET" && path == "/sram-final" -> {
                if (!sramFinalLatch.await(30, TimeUnit.SECONDS)) {
                    send(s, 503, "no final sram", null); return
                }
                val b = sramFinal
                if (b == null) {
                    send(s, 503, "no final sram", null)
                } else {
                    send(s, 200, "application/octet-stream", b)
                    sramFinalServed.set(true)
                    NpLog.log("srv /sram-final delivered (${b.size} bytes)")
                }
            }
            else -> send(s, 404, "not found", null)
        }
    }

    private fun send(s: Socket, code: Int, contentType: String, body: ByteArray?) {
        val reason = when (code) {
            200 -> "OK"; 204 -> "No Content"; 401 -> "Unauthorized"
            404 -> "Not Found"; 503 -> "Service Unavailable"; else -> "Error"
        }
        val out = BufferedOutputStream(s.getOutputStream())
        val header = StringBuilder()
            .append("HTTP/1.1 ").append(code).append(' ').append(reason).append("\r\n")
            .append("Connection: close\r\n")
            .append("Content-Type: $contentType\r\n")
            .append("Content-Length: ").append(body?.size ?: 0).append("\r\n\r\n")
        out.write(header.toString().toByteArray(Charsets.US_ASCII))
        if (body != null) out.write(body)
        out.flush()
    }

    // ------------------------------------------------------ host-side hooks

    /** Frame-0 serialized state, captured on the GL thread. */
    fun publishState0(bytes: ByteArray) {
        state0 = bytes
        state0Latch.countDown()
    }

    /**
     * Guest POSTed /ready; returns false once the wait expires.
     *
     * 120 s (was 30 s) because a cross-platform peer can be far slower to boot:
     * a HarmonyOS guest running MAME first re-stages its whole arcade library
     * into the MAME rompath and then lets MAME index every zip in it, which
     * routinely takes ~50 s before it can even POST /ready. An Android guest is
     * ready in ~1 s, so Android<->Android behaviour is unchanged.
     */
    fun awaitGuestReady(): Boolean =
        readyLatch.await(120, TimeUnit.SECONDS)

    /** Open the guest /start long-poll gate. */
    fun publishStart() = startLatch.countDown()

    /** Flushed end-of-session SRAM bytes. */
    fun publishSramFinal(bytes: ByteArray?) {
        sramFinal = bytes
        sramFinalLatch.countDown()
    }

    override fun close() {
        stopped = true
        try { server?.close() } catch (_: Throwable) {}
        // Release every long-poll with a 503 so worker threads can exit.
        state0Latch.countDown()
        startLatch.countDown()
        sramFinalLatch.countDown()
        workers.shutdownNow()
        try { workers.awaitTermination(1, TimeUnit.SECONDS) } catch (_: Throwable) {}
        Log.i(TAG, "bootstrap server closed")
    }

    companion object { private const val TAG = "GS-NetBoot" }
}
