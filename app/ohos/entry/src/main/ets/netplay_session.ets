// Netplay orchestration for HarmonyOS (§16.4 bootstrap + lockstep integration).
//
// Faithful port of the Android EmulatorActivity + PlayBootstrapServer/Client
// flow, driven from the ArkTS emulator surface (EmulatorSpike) since OHOS has no
// Kotlin activity. The lockstep engine lives in C++ (np::GsNetplay, compiled into
// libgpretro.so); this module only:
//   1. performs the host<->guest bootstrap (SRAM/state0 exchange) over a tiny
//      HTTP server (host) / HTTP client (guest),
//   2. attaches the session via the netplay* NAPI bindings,
//   3. polls stats at 2 Hz and fires the native->Dart `playEnded` callback on
//      terminal states.
//
// NOTE: end-to-end validation requires two devices on the same Wi-Fi. The
// signalling layer (Dart PlayLobbyPage / play_session.dart) already fills the
// netplay map (peerIp/peerPort/localPort/sessionKey/...) that this consumes.

import {
  netplayStart, netplayStop, netplayLocalMask, netplayNotifyStart,
  netplayNotifyPaused, netplayStats, netplayFlushSram, netplayGetState0,
  netplayLoadState0, netplayLoadSram, netplayFreeze, netplayStateHash
} from 'libgpretro.so'
import { socket } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { GamePouchPlugin } from './plugins/GamePouchPlugin'

export interface NetplayCfg {
  role: number          // 0 = host, 1 = guest
  peerIp: string       // the OTHER side's netplay UDP address
  peerPort: number     // the OTHER side's netplay UDP port
  localPort: number    // THIS side's netplay UDP port
  sessionKey: string   // 64-char hex shared secret
  roomId: number       // uint32 room id
  initialD: number     // 1 or 2
  adaptive: boolean
  bootstrapPort: number
  saveKey: string      // rom crc hex, used for sram path
  framePeriodSec?: number
  filesDir: string
  /// libretro core id of the running game ('mame' / 'fceumm' / ...). MAME
  /// serialisation is lossy, so both ends cold-boot instead of transferring
  /// frame 0 (mirrors Android EmulatorActivity.hostBootstrap/guestBootstrap).
  coreId?: string
}

/// Parsed one-shot HTTP reply of the bootstrap channel.
interface HttpReply {
  code: number
  body: Uint8Array
}

/// Reply rendered by the host bootstrap server: status code + optional body.
interface BootstrapReply {
  code: number
  reason: string
  body: Uint8Array | null
}

export interface NetplayStatus {
  state: number
  rttMs: number
  dropped: number
  fps: number
  text: string
}

const enc = new util.TextEncoder()
const dec = new util.TextDecoder()

function toU8(s: string): Uint8Array { return enc.encodeInto(s) }
function fromU8(u: Uint8Array): string { return dec.decodeToString(u) }
function fs_readAll(path: string): Uint8Array | null {
  try {
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
    try {
      const stat = fileIo.statSync(path)
      const buf = new Uint8Array(stat.size)
      fileIo.readSync(f.fd, buf)
      return buf
    } finally { fileIo.closeSync(f) }
  } catch (e) { return null }
}

/// Poll [pred] every 100 ms until it is true or [timeoutMs] elapses.
async function waitUntil(pred: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline: number = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (pred()) return true
    await new Promise<void>((r: (v: void) => void): void => { setTimeout(r, 100) })
  }
  return pred()
}

export class NetplaySession {
  private cfg: NetplayCfg
  private isHost: boolean
  private filesDir: string
  private sramPath: string
  private onStatus?: (s: NetplayStatus) => void

  private server?: socket.TCPSocketServer
  private guestReady: boolean = false
  private started: boolean = false
  private stopped: boolean = false
  private pollTimer: number = -1
  private roomId32: number
  // ---- bootstrap state (host side) ----
  private coreId: string = ''
  /// MAME's serialize/unserialize round-trip is lossy, so (like Android) we
  /// never transfer frame 0 for it: both ends boot the ROM cold and let the
  /// lockstep align them from the inputs.
  private coldBoot: boolean = false
  private state0Published: boolean = false
  private state0Bytes: Uint8Array | null = null
  private startGate: boolean = false
  private sramFinal: Uint8Array | null = null
  private sramFinalReady: boolean = false

  constructor(cfg: NetplayCfg, onStatus?: (s: NetplayStatus) => void) {
    this.cfg = cfg
    this.isHost = cfg.role === 0
    this.filesDir = cfg.filesDir
    this.sramPath = `${cfg.filesDir}/saves/${cfg.saveKey}.sav`
    this.onStatus = onStatus
    this.roomId32 = cfg.roomId >>> 0
    this.coreId = (cfg.coreId ?? '').toLowerCase()
    this.coldBoot = this.coreId === 'mame'
  }

  /// Begin the session. Core must already be loaded (state0 is captured at the
  /// first locked frame by the C++ pace loop).
  async start(): Promise<void> {
    // Fail CLOSED, exactly like Android's NetplaySessionCfg.from(intent): a
    // malformed room must fall back to solo play with a loud log instead of
    // silently binding port 0 (a random ephemeral port the peer can never
    // reach) or attaching with a 0 UDP port.
    const bad: string | null = this.validateCfg()
    if (bad != null) {
      console.error(`[netplay] cfg rejected: ${bad}`)
      this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: `cfg: ${bad}` })
      this.teardown(false)
      return
    }
    // Poll stats while the bootstrap is still in flight: both flows can block
    // for tens of seconds (state0 capture, guest /ready, host /start gate).
    const flow: Promise<void> = this.isHost ? this.startHost() : this.startGuest()
    this.startPolling()
    await flow
  }

  /// Mirrors NetplaySessionCfg.from(): every check that returns null on
  /// Android must abort here too.
  private validateCfg(): string | null {
    const c: NetplayCfg = this.cfg
    if (c.role !== 0 && c.role !== 1) return `role=${c.role}`
    if (!c.peerIp || c.peerIp.length === 0) return 'peerIp empty'
    if (!/^[0-9a-f]{64}$/.test(c.sessionKey)) return `sessionKey len=${c.sessionKey.length}`
    if (c.peerPort < 1 || c.peerPort > 65535) return `peerPort=${c.peerPort}`
    if (c.localPort < 1 || c.localPort > 65535) return `localPort=${c.localPort}`
    if (c.bootstrapPort < 1 || c.bootstrapPort > 65535) return `bootstrapPort=${c.bootstrapPort}`
    if ((c.roomId >>> 0) === 0) return 'roomId=0'
    return null
  }

  /// Feed the live local pad mask (the Flutter pad -> setInput path also calls
  /// this). Published each frame by the C++ gate.
  setLocalMask(mask: number): void {
    try { netplayLocalMask(mask & 0xFFFF) } catch (e) { /* ignore */ }
  }

  /// Set local pause intent.
  setPaused(paused: boolean): void {
    try { netplayNotifyPaused(paused) } catch (e) { /* ignore */ }
  }

  // ---- host flow -----------------------------------------------------------
  // Mirrors Android EmulatorActivity.hostBootstrap: bind the bootstrap server,
  // publish frame 0 (skipped for MAME), wait for the guest's /ready, then
  // announce START and open the /start gate.
  private async startHost(): Promise<void> {
    this.startBootstrapServer()
    const cfgJson: string = this.buildCfgJson()
    console.info(`[netplay] host cfgJson=${cfgJson}`)
    const ok: boolean = netplayStart(cfgJson) as boolean
    console.info(`[netplay] host netplayStart ok=${ok} peerIp=${this.cfg.peerIp} ` +
      `peerPort=${this.cfg.peerPort} localPort=${this.cfg.localPort}`)
    if (!ok) {
      this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: 'attach failed' })
      this.teardown(false)
      return
    }
    if (this.coldBoot) {
      // No frame-0 transfer: publish an empty state0 so a guest that asks for
      // one gets a well-formed (zero-length) reply instead of hanging.
      this.publishState0(new Uint8Array(0))
    } else {
      // state0 is captured by the pace loop at the first locked frame.
      const got: boolean = await waitUntil((): boolean => {
        const ab: ArrayBuffer | null = netplayGetState0() as ArrayBuffer | null
        if (ab && ab.byteLength > 0) {
          this.publishState0(new Uint8Array(ab))
          return true
        }
        return false
      }, 15000)
      if (!got) this.publishState0(new Uint8Array(0))
    }
    this.started = true
    // Attached: release the emulation gate (Android's startPacing happens in
    // the same GL block as netplayStart).
    try { netplayFreeze(false) } catch (e) { /* ignore */ }
    // Android awaits the guest's /ready for 120s (PlayBootstrapServer
    // .awaitGuestReady): the peer may have to boot MAME from cold, which alone
    // takes ~50s on this device. 30s timed out before the peer even had a core.
    const ready: boolean = await waitUntil((): boolean => this.guestReady, 120000)
    if (!ready) {
      this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: 'guest not ready (120s)' })
      this.teardown(false)
      return
    }
    try { netplayNotifyStart() } catch (e) { /* ignore */ }
    this.startGate = true
  }

  private publishState0(b: Uint8Array): void {
    this.state0Bytes = b
    this.state0Published = true
  }

  // ---- guest flow ----------------------------------------------------------
  // Mirrors Android guestBootstrap: SRAM (host battery wins) -> optional
  // frame-0 state -> attach -> POST /ready -> await the host /start gate.
  private async startGuest(): Promise<void> {
    console.info(`[netplay] startGuest cfg peerIp=${this.cfg.peerIp} peerPort=${this.cfg.peerPort} ` +
      `localPort=${this.cfg.localPort} bootPort=${this.cfg.bootstrapPort} role=${this.cfg.role} ` +
      `sessionKeyLen=${this.cfg.sessionKey.length}`)
    try {
      const sramReply: HttpReply | null = await this.tcpRequest('GET', '/sram')
      console.info(`[netplay] guest /sram -> ${sramReply ? sramReply.code : 'null'} ` +
        `${sramReply ? sramReply.body.length : 0} bytes`)
      if (sramReply && sramReply.code === 200 && sramReply.body.length > 0) {
        try { netplayLoadSram(sramReply.body.buffer as ArrayBuffer) } catch (e) { /* ignore */ }
      }
      if (!this.coldBoot) {
        const st: HttpReply | null = await this.tcpRequest('GET', '/state0')
        console.info(`[netplay] guest /state0 -> ${st ? st.code : 'null'} ${st ? st.body.length : 0} bytes`)
        if (st && st.code === 200 && st.body.length > 0) {
          let loaded = false
          try { loaded = netplayLoadState0(st.body.buffer as ArrayBuffer) as boolean } catch (e) { loaded = false }
          // Diagnostics: the guest's state right after the host's frame-0
          // state is applied must be identical on every run (and equal to the
          // host's). A `false` here means the serialize layouts differ and the
          // pair can never converge.
          let h = 'null'
          try { h = String(netplayStateHash()) } catch (e) { h = 'null' }
          console.info(`[netplay] guest loadState0 ok=${loaded} hashAfter=${h}`)
        } else if (st && st.code === 503) {
          this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: 'no state0' })
          this.teardown(false)
          return
        } else if (!st || st.code !== 200) {
          // Android PlayBootstrapClient.fetchState0() accepts ONLY 200; 401
          // (bearer mismatch) / 404 / anything else raises and aborts the
          // bootstrap. Previously those codes fell through silently and the
          // guest attached without the host's frame-0 state.
          this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: `state0 http ${st ? st.code : 'null'}` })
          this.teardown(false)
          return
        }
        // 200 with an empty body == host runs MAME (cold-boot alignment).
      }
      const cfgJson: string = this.buildCfgJson()
      console.info(`[netplay] guest cfgJson=${cfgJson}`)
      const ok: boolean = netplayStart(cfgJson) as boolean
      console.info(`[netplay] guest netplayStart ok=${ok} localPort=${this.cfg.localPort} peer=${this.cfg.peerIp}:${this.cfg.peerPort}`)
      if (!ok) {
        this.report({ state: 3, rttMs: 0, dropped: 0, fps: 0, text: 'attach failed' })
        this.teardown(false)
        return
      }
      this.started = true
      // Attached: release the emulation gate so lockstep frame 0 runs from the
      // state the host published (Android: loadState + netplayStart +
      // startPacing are one atomic GL block).
      try { netplayFreeze(false) } catch (e) { /* ignore */ }
      const rd: HttpReply | null = await this.tcpRequest('POST', '/ready') // tell host we are ready
      console.info(`[netplay] guest POST /ready -> ${rd ? rd.code : 'null'}`)
      // Android PlayBootstrapClient.postReady()/awaitStart() accept ONLY 200;
      // any other status (401 bearer mismatch, 503 host gate timeout, 404)
      // raises. Previously the code was logged but never branched on, so a
      // session the host had rejected still "entered lockstep" and then hung
      // with no checkpoints instead of reporting the real failure.
      if (!rd || rd.code !== 200) {
        this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: `ready http ${rd ? rd.code : 'null'}` })
        this.teardown(false)
        return
      }
      const stg: HttpReply | null = await this.tcpRequest('GET', '/start') // long-poll the host START gate
      console.info(`[netplay] guest /start -> ${stg ? stg.code : 'null'}`)
      if (!stg || stg.code !== 200) {
        this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: `start http ${stg ? stg.code : 'null'}` })
        this.teardown(false)
        return
      }
      console.info(`[netplay] guest bootstrap ALL DONE, entering lockstep...`)
    } catch (e) {
      this.report({ state: 4, rttMs: 0, dropped: 0, fps: 0, text: 'bootstrap failed' })
      this.teardown(false)
    }
  }

  // ---- bootstrap HTTP server (host) ---------------------------------------
  // Same contract as Android PlayBootstrapServer: every request must carry
  // `Authorization: Bearer <sessionKey>`, and 204/503/404 carry real meaning
  // (the Android guest branches on the status code).
  private startBootstrapServer(): void {
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance()
    this.server = server
    const baddr: socket.NetAddress = { address: '0.0.0.0', port: this.cfg.bootstrapPort }
    // HarmonyOS NEXT: TCPSocketServer has no bind(); listen(NetAddress) binds+listens.
    server.listen(baddr)
    server.on('connect', (client: socket.TCPSocketConnection): void => {
      client.on('message', (info: socket.SocketMessageInfo): void => {
        const req: string = fromU8(new Uint8Array(info.message as ArrayBuffer))
        const line: string = req.split('\r\n')[0]
        const m: RegExpMatchArray | null = line.match(/^(GET|POST)\s+(\/\S*)\s+HTTP/)
        if (m == null) { this.reply(client, 400, 'Bad Request', null); return }
        const method: string = m[1]
        const path: string = m[2]
        if (!this.authed(req)) {
          console.error(`[netplay] host ${method} ${path} -> 401 (bearer mismatch)`)
          this.reply(client, 401, 'Unauthorized', null)
          return
        }
        this.handleRoute(method, path).then((r: BootstrapReply): void => {
          console.info(`[netplay] host ${method} ${path} -> ${r.code}`)
          this.reply(client, r.code, r.reason, r.body)
        })
      })
    })
  }

  private authed(req: string): boolean {
    const m: RegExpMatchArray | null = req.match(/Authorization:\s*Bearer\s+(\S+)/i)
    if (m == null) return false
    return m[1] === this.cfg.sessionKey
  }

  private reply(client: socket.TCPSocketConnection, code: number, reason: string, body: Uint8Array | null): void {
    const n: number = body ? body.length : 0
    let head: string = `HTTP/1.1 ${code} ${reason}\r\nContent-Length: ${n}\r\nConnection: close\r\n`
    if (code === 200 || code === 404 || code === 401 || code === 503) {
      head += 'Content-Type: application/octet-stream\r\n'
    }
    head += '\r\n'
    const out: Uint8Array = new Uint8Array(n + toU8(head).length)
    out.set(toU8(head))
    if (body) out.set(body, toU8(head).length)
    const opt: socket.TCPSendOptions = { data: out.buffer as ArrayBuffer }
    // Close after the response so the peer's read-to-EOF (Android
    // PlayBootstrapClient reads until the socket closes) returns promptly
    // instead of stalling on the 35 s socket timeout — especially for the
    // /start long-poll, whose stall would otherwise strand the guest's
    // "waiting for host" overlay over an already-running game.
    client.send(opt)
      .then((): void => { try { client.close() } catch (e) {} })
      .catch((): void => { try { client.close() } catch (e) {} })
  }

  private async handleRoute(method: string, path: string): Promise<BootstrapReply> {
    if (path.startsWith('/state0')) {
      const ok: boolean = await waitUntil((): boolean => this.state0Published, 30000)
      if (!ok) return { code: 503, reason: 'Service Unavailable', body: null }
      return { code: 200, reason: 'OK', body: this.state0Bytes }
    }
    if (path.startsWith('/sram-final')) {
      const ok: boolean = await waitUntil((): boolean => this.sramFinalReady, 30000)
      const data: Uint8Array | null = this.sramFinal
      // 503 (not 200 + empty body) so an Android guest keeps its own save
      // instead of overwriting it with zero bytes.
      if (!ok || data == null || data.length === 0) {
        return { code: 503, reason: 'Service Unavailable', body: null }
      }
      return { code: 200, reason: 'OK', body: data }
    }
    if (path.startsWith('/sram')) {
      const data: Uint8Array | null = fs_readAll(this.sramPath)
      if (data == null || data.length === 0) {
        // Android guest maps 204 to "host has no battery save".
        return { code: 204, reason: 'No Content', body: null }
      }
      return { code: 200, reason: 'OK', body: data }
    }
    if (path.startsWith('/ready')) {
      this.guestReady = true
      return { code: 200, reason: 'OK', body: toU8('{"ok":true}') }
    }
    if (path.startsWith('/start')) {
      const ok: boolean = await waitUntil((): boolean => this.startGate, 30000)
      if (!ok) return { code: 503, reason: 'Service Unavailable', body: null }
      return { code: 200, reason: 'OK', body: toU8('{"ok":true}') }
    }
    if (path.startsWith('/bye')) {
      // Peer said BYE: a *clean* end (Android's cleanBye=true).
      this.teardown(true)
      return { code: 200, reason: 'OK', body: toU8('ok') }
    }
    return { code: 404, reason: 'Not Found', body: null }
  }

  // ---- bootstrap HTTP client (guest) --------------------------------------
  // Android's host rejects every request without `Authorization: Bearer
  // <sessionKey>` (401), so the bearer header is mandatory for cross-platform
  // sessions — this was the bug that made Android<->HarmonyOS netplay fail.
  //
  // HarmonyOS TCPSocket.connect() is NON-BLOCKING: the completion callback
  // routinely arrives with EINPROGRESS (HarmonyOS code 2301115 / POSIX 115)
  // while the TCP handshake is still in flight. The real "connected" signal
  // is the 'connect' event. Treating EINPROGRESS as a fatal error — as the
  // old code did — closed the socket before the handshake finished, so every
  // bootstrap request returned null and the guest could never reach the host.
  //
  // connect-retry (mirrors Android PlayBootstrapClient.withConnectRetry):
  // The Dart signalling layer fires both host and guest's emulator launch
  // nearly simultaneously. The host's ServerSocket takes a moment to bind
  // (Flutter→Activity→renderer→ServerSocket), so the guest's first connect
  // attempt always races a "connection refused". Android retries connect
  // failures for 20 s with exponential backoff; we do the same here. Without
  // this, the 8 s single-attempt timeout was the #1 cause of guest black
  // screens on Android<->HarmonyOS sessions.
  private static readonly TCP_CONNECT_RETRY_WINDOW_MS: number = 20_000
  private static readonly TCP_CONNECT_TIMEOUT_MS: number = 8_000

  private tcpRequest(method: string, path: string): Promise<HttpReply | null> {
    return new Promise<HttpReply | null>((resolve: (v: HttpReply | null) => void): void => {
      const deadline: number = Date.now() + NetplaySession.TCP_CONNECT_RETRY_WINDOW_MS
      let attempt: number = 0
      const runOnce = (): void => {
        attempt++
        const cli: socket.TCPSocket = socket.constructTCPSocketInstance()
        let buf: Uint8Array = new Uint8Array(0)
        let settled: boolean = false
        let connected: boolean = false
        let sent: boolean = false
        let connectTimer: number = -1
        let retryableFailure: boolean = false
        let finalResult: HttpReply | null = null
        const cleanup = (): void => {
          if (connectTimer >= 0) { clearTimeout(connectTimer); connectTimer = -1 }
          try { cli.close() } catch (e) {}
        }
        const finish = (v: HttpReply | null, retryable: boolean): void => {
          if (settled) return
          settled = true
          finalResult = v
          retryableFailure = retryable
          cleanup()
          maybeResolveOrRetry()
        }
        const maybeResolveOrRetry = (): void => {
          // Retry on ANY null outcome within the window — whether connect
          // refused, connect timeout, EINPROGRESS 风暴, send failure, or
          // server closing before a full HTTP response. Only a *complete*
          // HTTP reply (any code, even 401/404/503) is terminal. This
          // mirrors Android PlayBootstrapClient.withConnectRetry where
          // IOException covers the whole socket lifetime, not just the
          // initial connect() call.
          if (finalResult === null && Date.now() < deadline) {
            const delay: number = Math.min(300 * attempt, 1000)
            console.info(`[netplay] tcpRequest ${method} ${path} attempt ${attempt} failed, retrying in ${delay}ms`)
            setTimeout(runOnce, delay)
            return
          }
          resolve(finalResult)
        }
        const sendReq = (): void => {
          if (sent || !connected) return
          sent = true
          let req: string = `${method} ${path} HTTP/1.1\r\nHost: ${this.cfg.peerIp}:${this.cfg.bootstrapPort}\r\n` +
            `Authorization: Bearer ${this.cfg.sessionKey}\r\nConnection: close\r\n`
          if (method === 'POST') req += 'Content-Length: 0\r\n'
          req += '\r\n'
          const opt: socket.TCPSendOptions = { data: enc.encodeInto(req).buffer as ArrayBuffer }
          cli.send(opt).catch((): void => finish(null, true))
        }
        cli.on('message', (info: socket.SocketMessageInfo): void => {
          const chunk: Uint8Array = new Uint8Array(info.message as ArrayBuffer)
          const merged: Uint8Array = new Uint8Array(buf.length + chunk.length)
          merged.set(buf)
          merged.set(chunk, buf.length)
          buf = merged
        })
        cli.on('close', (): void => {
          // Closed before we ever connected => the connect failed (refused/timeout).
          if (!connected) { finish(null, true); return }
          const text: string = fromU8(buf)
          const idx: number = text.indexOf('\r\n\r\n')
          if (idx < 0) { finish(null, false); return }
          const header: string = text.substring(0, idx)
          const sm: RegExpMatchArray | null = header.match(/^HTTP\/1\.[01]\s+(\d{3})/)
          const code: number = sm ? parseInt(sm[1], 10) : 0
          const m: RegExpMatchArray | null = header.match(/Content-Length:\s*(\d+)/i)
          const cl: number = m ? parseInt(m[1], 10) : 0
          const start: number = idx + 4
          const body: Uint8Array = buf.subarray(start, start + cl)
          finish({ code: code, body: body }, false)
        })
        cli.on('error', (): void => finish(null, true))
        cli.on('connect', (): void => { connected = true; sendReq() })
        // Guard against a connect that never completes (e.g. host unreachable).
        connectTimer = setTimeout((): void => { if (!connected) finish(null, true) }, NetplaySession.TCP_CONNECT_TIMEOUT_MS)
        // HarmonyOS NEXT: connect() takes TCPConnectOptions, whose `address` is a NetAddress.
        const opts: socket.TCPConnectOptions = { address: { address: this.cfg.peerIp, port: this.cfg.bootstrapPort } }
        cli.connect(opts, (err: ESObject): void => {
          // EINPROGRESS is expected for a non-blocking connect; the 'connect'
          // event delivers the real completion. Only a *different* error is fatal.
          if (err && err.code !== 2301115 && err.code !== 115) {
            console.error(`[netplay] tcp connect FAILED code=${err?.code} ` +
              `msg=${err?.message} -> ${this.cfg.peerIp}:${this.cfg.bootstrapPort}`)
            finish(null, true); return
          }
          // Older API variant: the callback itself is the success signal.
          if (!err) { connected = true; sendReq() }
        })
      }
      runOnce()
    })
  }

  // ---- stats polling + terminal detection ---------------------------------
  // C++ GsNetplay::NetState enum (gs_netplay.h L43-50):
  //   0=Idle  1=Starting  2=Running  3=Dropped(>=10s no packet)  4=Ended(BYE/stop)  5=Paused
  // Android mirrors this exactly (NativeBridge.STATE_DROPPED=3, STATE_ENDED=4, STATE_PAUSED=5).
  private static pollCount: number = 0
  private startPolling(): void {
    this.pollTimer = setInterval((): void => {
      let s: number[] | null = null
      try { s = netplayStats() as number[] } catch (e) { return }
      if (!s) return
      const state: number = s[0] ?? 0
      const rtt: number = (s[4] as number) || 0       // rttP50Ms
      const dropped: number = (s[10] as number) || 0   // lateFrames
      const fps: number = (s[17] as number) || 0
      const pktsIn: number = (s[12] as number) || 0
      const pktsOut: number = (s[13] as number) || 0
      const rejBadMagic: number = (s[19] as number) || 0
      NetplaySession.pollCount++
      if (NetplaySession.pollCount <= 4 || NetplaySession.pollCount % 6 === 0 || state >= 3) {
        console.info(`[netplay] poll#${NetplaySession.pollCount} state=${state}(${this.stateText(state)}) rtt=${rtt}ms drop=${dropped} fps=${fps} in=${pktsIn} out=${pktsOut} rejMagic=${rejBadMagic}`)
      }
      this.report({ state, rttMs: rtt, dropped, fps, text: this.stateText(state) })
      // Terminal: Dropped(3) = 10s no valid packet, Ended(4) = peer BYE
      if (state === 3 || state === 4) {
        console.warn(`[netplay] TERMINAL state=${state}(${this.stateText(state)}) -> teardown`)
        this.teardown(false)
      }
    }, 500) as number
  }

  private stateText(st: number): string {
    switch (st) {
      case 0: return 'Idle'
      case 1: return 'Starting'
      case 2: return 'Running'
      case 3: return 'Dropped'
      case 4: return 'Ended'
      case 5: return 'Paused'
      default: return `?${st}`
    }
  }

  private report(s: NetplayStatus): void { this.onStatus?.(s) }

  // ---- teardown -----------------------------------------------------------
  /// [clean] mirrors Android's cleanBye: true when the session ended normally
  /// (peer BYE / local exit), false on any failure or timeout.
  private teardown(clean: boolean): void {
    if (this.stopped) { console.info(`[netplay] teardown: already stopped, skip`); return }
    console.warn(`[netplay] teardown(clean=${clean}) role=${this.isHost ? 'host' : 'guest'}`)
    this.stopped = true
    // Release the emulation gate: a bootstrap that never completed (or a
    // terminal session) must fall back to solo play, not stay parked forever.
    try { netplayFreeze(false) } catch (e) {}
    if (this.pollTimer >= 0) { clearInterval(this.pollTimer); this.pollTimer = -1 }
    if (this.isHost) {
      try { netplayFlushSram() } catch (e) {}
      // Publish the flushed battery RAM so an Android guest can converge on
      // /sram-final (same contract as PlayBootstrapServer.publishSramFinal).
      this.sramFinal = fs_readAll(this.sramPath)
      this.sramFinalReady = true
    }
    try { netplayStop() } catch (e) {}
    try { this.server?.close() } catch (e) {}
    this.server = undefined
    // Always emit: the Dart PlaySession slot is only released by this event,
    // so swallowing it blocks the next invite ("已有一个联机邀请或对局在进行").
    try { GamePouchPlugin.emitNetplayPlayEnded(this.roomId32, clean) } catch (e) {}
  }

  /// Public stop (e.g. user leaves the session).
  stop(): void { this.teardown(true) }

  private buildCfgJson(): string {
    const c: NetplayCfg = this.cfg
    return JSON.stringify({
      role: c.role,
      peerIp: c.peerIp,
      peerPort: c.peerPort,
      localPort: c.localPort,
      sessionKeyHex: c.sessionKey,
      roomId: c.roomId,
      initialD: c.initialD,
      adaptive: c.adaptive,
      framePeriodSec: c.framePeriodSec ?? 0,
      frame0: 0,
      // MUST be forwarded to native: gpretro.cpp NativeNetplayStart() reads
      // "saveKey" and derives g_netSramPath = <appDir>/saves/<saveKey>.sav.
      // Without it the path is cleared and netplayFlushSram() (and the SRAM
      // convergence with an Android peer) silently no-ops. Android supplies the
      // same value via nativeInit(..., saveKey, ...) instead of via cfgJson.
      saveKey: c.saveKey ?? ''
    })
  }
}
