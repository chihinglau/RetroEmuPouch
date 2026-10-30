#include "gs_netplay.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace np {

namespace {
constexpr double kRecvTimeoutSec = 0.1;
constexpr double kDropAfterSec = 10.0;
constexpr size_t kRingSlots = 64;
constexpr size_t kSampleCap = 512;

double nowSec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

uint64_t nowNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint32_t)ts.tv_nsec;
}

void setTimeval(int fd, int opt, double sec) {
    timeval tv{};
    tv.tv_sec = (time_t)sec;
    tv.tv_usec = (suseconds_t)((sec - tv.tv_sec) * 1e6);
    setsockopt(fd, SOL_SOCKET, opt, &tv, sizeof(tv));
}
} // namespace

GsNetplay::GsNetplay()
    : replay_(4096),
      remoteRing_(kRingSlots),
      localRing_(kRingSlots),
      delay_(1, 2),
      delayCur_(2) {
    arrival_.resize(kRingSlots);
}

GsNetplay::~GsNetplay() { stop(); }

bool GsNetplay::start(const NetConfig &cfg) {
    if (running_.exchange(true)) return false;
    cfg_ = cfg;
    droppedByTimeout_.store(false, std::memory_order_relaxed);
    arrival_.assign(kRingSlots, Arrival{});
    {
        std::lock_guard<std::mutex> lk(mtx_);
        seqOut_ = 1;
        replay_ = ReplayWindow(4096);
        remoteRing_ = InputRing(kRingSlots);
        localRing_ = InputRing(kRingSlots);
        delay_ = DelayCtrl(1, 2, cfg_.framePeriodSec);
        delay_.reset(cfg_.initialD, nowSec());
        delayCur_.store(cfg_.initialD, std::memory_order_relaxed);
        // Both host and guest start with start gate CLOSED. The host opens
        // it explicitly via notifyStart() AFTER guest has posted /ready;
        // the guest opens it on receiving CTRL_START from the host.
        // Previously the host pre-set started_=true here, which let the
        // pacing thread run warm-up frames and then block waiting for
        // remoteRing — if the guest took >10 s to finish bootstrap, the
        // host dead-timed out before ever seeing its first UDP packet.
        started_.store(false, std::memory_order_release);
        localPaused_.store(false, std::memory_order_relaxed);
        remotePaused_ = false;
        remoteSeen_ = false;
        framesAdvanced_ = frozenFrames_ = 0;
        blockedMsTotal_ = 0;
        frozenAtFrame_ = UINT32_MAX;
        lateFrames_ = 0;
        packetsIn_ = packetsOut_ = bytesIn_ = bytesOut_ = 0;
        redundantSends_ = 0;
        rejBadLen_ = rejBadMagic_ = rejBadVer_ = rejBadTag_ = 0;
        foreignPackets_ = 0;
        rttSamplesMs_.clear();
        leadSamplesMs_.clear();
        startSec_ = lastRecvSec_ = nowSec();
    }

    sock_ = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_ < 0) {
        running_.store(false);
        return false;
    }
    setTimeval(sock_, SO_RCVTIMEO, kRecvTimeoutSec);
    setTimeval(sock_, SO_SNDTIMEO, kRecvTimeoutSec);
    int yes = 1;
    setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(cfg_.localPort);
    if (bind(sock_, (sockaddr *)&local, sizeof(local)) < 0) {
        close(sock_);
        sock_ = -1;
        running_.store(false);
        return false;
    }

    std::memset(&peerAddr_, 0, sizeof(peerAddr_));
    peerAddr_.sin_family = AF_INET;
    peerAddr_.sin_port = htons(cfg_.peerPort);
    if (inet_pton(AF_INET, cfg_.peerIp.c_str(), &peerAddr_.sin_addr) != 1) {
        close(sock_);
        sock_ = -1;
        running_.store(false);
        return false;
    }

    recvThread_ = std::thread([this] { recvLoop(); });
    return true;
}

void GsNetplay::stop() {
    if (!running_.exchange(false)) {
      // Thread was never running; just close a possibly leftover fd.
    }
    cv_.notify_all();
    if (sock_ >= 0) {
        ::shutdown(sock_, SHUT_RDWR);
        close(sock_);
        sock_ = -1;
    }
    if (recvThread_.joinable()) recvThread_.join();
    started_.store(false, std::memory_order_release);
}

void GsNetplay::shutdown() {
    if (running_.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lk(mtx_);
        sendCtrl(CTRL_BYE);
    }
    stop();
}

uint16_t GsNetplay::localPort() const {
    if (sock_ < 0) return cfg_.localPort;
    sockaddr_in a{};
    socklen_t al = sizeof(a);
    if (getsockname(sock_, (sockaddr *)&a, &al) != 0) return 0;
    return ntohs(a.sin_port);
}

void GsNetplay::notifyStart() {
    if (!running_.load(std::memory_order_relaxed)) return;
    started_.store(true, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lk(mtx_);
        sendCtrl(CTRL_START);
    }
    cv_.notify_all();
}

// ------------------------------------------------------------ frame gate

GateResult GsNetplay::beginFrame(uint32_t frame, uint16_t &localMask,
                                 uint16_t &remoteMask) {
    std::unique_lock<std::mutex> lk(mtx_);
    if (!running_.load(std::memory_order_relaxed)) return GateResult::Dead;

    // START gate: no frame is released until the host announces both sides
    // are ready.
    if (!started_.load(std::memory_order_relaxed)) {
        cv_.wait_for(lk, std::chrono::milliseconds(100));
        return GateResult::Paused;
    }
    if (localPaused_.load(std::memory_order_relaxed) || remotePaused_) {
        cv_.wait_for(lk, std::chrono::milliseconds(100));
        return GateResult::Paused;
    }

    const int d = delayCur_.load(std::memory_order_relaxed);
    const uint32_t firstDelayed = cfg_.frame0 + static_cast<uint32_t>(d);
    if (frame < firstDelayed) {
        // Warm-up frames before the delay pipeline fills: buttons up on the
        // not-yet-existing frames, identical on both sides by construction.
        localMask = 0;
        remoteMask = 0;
        return GateResult::Ok;
    }

    const uint32_t target = frame - static_cast<uint32_t>(d);
    // Chronology-independent lead: how long the authenticated remote frame
    // sat in the ring before the gate consumed it. The two pace threads
    // rebaseline their clocks independently after stalls, so an anchor-based
    // deadline used to stay permanently offset and pinned D at max forever.
    bool missed = false;
    double waitStartSec = 0.0;
    if (!remoteRing_.has(target)) {
        missed = true;
        waitStartSec = nowSec();
        if (frozenAtFrame_ != target) {
            frozenAtFrame_ = target;
            ++frozenFrames_;
        }
        // FR-15 gap resend: ask the peer to re-dump its local input ring
        // starting at the frame we are missing (serviced on its receive
        // thread, so it works even while both pace threads are frozen).
        auto sendNeed = [&] {
            uint8_t b[4];
            std::memcpy(b, &target, 4);
            sendCtrl(CTRL_NEED, b, 4);
        };
        sendNeed();
        while (running_.load(std::memory_order_relaxed)) {
            cv_.wait_for(lk, std::chrono::milliseconds(100));
            if (localPaused_.load(std::memory_order_relaxed) || remotePaused_) {
                return GateResult::Paused;
            }
            if (remoteRing_.has(target)) break;
            sendNeed(); // ~10 Hz while the gate stays blocked
            if (lastRecvSec_ > 0 && nowSec() - lastRecvSec_ > kDropAfterSec) {
                droppedByTimeout_.store(true, std::memory_order_relaxed);
                running_.store(false, std::memory_order_relaxed);
                return GateResult::Dead;
            }
        }
        if (!running_.load(std::memory_order_relaxed)) return GateResult::Dead;
    }

    uint16_t rm = 0, lm = 0;
    remoteRing_.get(target, rm);
    if (!localRing_.get(target, lm)) lm = 0;

    double leadSec;
    if (missed) {
        // Pain is the actual gate wait; it delays presentation of this frame.
        leadSec = -(nowSec() - waitStartSec);
        ++lateFrames_;
        blockedMsTotal_ += static_cast<uint64_t>(-leadSec * 1000.0 + 0.5);
    } else {
        const Arrival &arr = arrival_[target & (kRingSlots - 1)];
        leadSec = (arr.present && arr.frame == target) ? nowSec() - arr.t : 0.0;
    }
    if (leadSamplesMs_.size() >= kSampleCap) leadSamplesMs_.pop_front();
    leadSamplesMs_.push_back(leadSec * 1000.0);

    if (cfg_.role == Role::Host && cfg_.adaptive) {
        const double t = nowSec();
        if (delay_.onFrame(leadSec, t)) {
            const int nd = delay_.d();
            delayCur_.store(nd, std::memory_order_relaxed);
            uint8_t buf[1] = {static_cast<uint8_t>(nd)};
            sendCtrl(CTRL_DCHANGE, buf, 1);
        }
    }

    localMask = lm;
    remoteMask = rm;
    return GateResult::Ok;
}

void GsNetplay::endFrame(uint32_t frame, uint16_t localMask) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (!running_.load(std::memory_order_relaxed)) return;
    ++framesAdvanced_;

    localRing_.put(frame, localMask);
    const int d = delayCur_.load(std::memory_order_relaxed);
    const size_t n = static_cast<size_t>(d + 2); // N = D+2, always >= 3
    // One batched datagram carries the contiguous newest..oldest masks that
    // exist (warm-up frames below frame0 are simply absent).
    std::vector<uint16_t> batch;
    batch.reserve(n);
    for (uint32_t g = frame; batch.size() < n;) {
        uint16_t m = 0;
        if (!localRing_.get(g, m)) break;
        batch.push_back(m);
        if (g == cfg_.frame0) break; // do not underflow past frame0
        --g;
    }
    if (batch.size() > 1) redundantSends_ += batch.size() - 1;
    sendInputBatch(frame, batch);

    // Host re-announces START until the guest is visibly live.
    if (cfg_.role == Role::Host &&
        started_.load(std::memory_order_relaxed) &&
        !remoteSeen_ && (frame % 10) == 0) {
        sendCtrl(CTRL_START);
    }
    // Sparse RTT ping (both sides).
    if ((frame % 30) == 0) {
        uint64_t t0 = nowNs();
        uint8_t buf[8];
        std::memcpy(buf, &t0, 8);
        sendCtrl(CTRL_PING, buf, 8);
    }
}

void GsNetplay::setLocalPaused(bool paused) {
    localPaused_.store(paused, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(mtx_);
        sendCtrl(paused ? CTRL_PAUSE : CTRL_RESUME);
    }
    cv_.notify_all();
}

void GsNetplay::ping() {
    uint64_t t0 = nowNs();
    std::lock_guard<std::mutex> lk(mtx_);
    sendCtrl(CTRL_PING, reinterpret_cast<const uint8_t *>(&t0), sizeof(t0));
}

// ------------------------------------------------------------- receiving

void GsNetplay::recvLoop() {
    prctl(PR_SET_NAME, "gs-net", 0, 0, 0);
    uint8_t buf[2048];
    while (running_.load(std::memory_order_relaxed)) {
        sockaddr_in src{};
        socklen_t sl = sizeof(src);
        ssize_t r = recvfrom(sock_, buf, sizeof(buf), 0,
                             (sockaddr *)&src, &sl);
        if (r < 0) continue; // timeout or transient error
        if (src.sin_addr.s_addr != peerAddr_.sin_addr.s_addr ||
            src.sin_port != peerAddr_.sin_port) {
            std::lock_guard<std::mutex> lk(mtx_);
            ++foreignPackets_;
            continue;
        }
        // Test blackhole: emulate total inbound loss for a window.
        const double el = nowSec() - startSec_;
        if (cfg_.blackholeDurSec > 0 && el >= cfg_.blackholeAtSec &&
            el < cfg_.blackholeAtSec + cfg_.blackholeDurSec) {
            continue;
        }
        std::lock_guard<std::mutex> lk(mtx_);
        handleDatagram(buf, static_cast<size_t>(r), nowSec());
    }
}

bool GsNetplay::handleDatagram(const uint8_t *buf, size_t len,
                               double nowSecTime) {
    Decoded dec;
    const RejectReason rr = verify(buf, len, cfg_.key.data(), dec);
    if (rr != REJ_OK) {
        switch (rr) {
        case REJ_BAD_LEN: ++rejBadLen_; break;
        case REJ_BAD_MAGIC: ++rejBadMagic_; break;
        case REJ_BAD_VERSION: ++rejBadVer_; break;
        case REJ_BAD_TAG: ++rejBadTag_; break;
        default: break;
        }
        return false;
    }
    if (dec.hdr.room != cfg_.roomId) {
        ++rejBadTag_; // foreign session with a valid-looking tag
        return false;
    }
    const ReplayVerdict rv = replay_.examine(dec.hdr.seq);
    if (rv == RP_DUPLICATE || rv == RP_OLD) {
        // Replayed/duplicated valid packet: counted via replay counters in
        // stats(); never applied to the input ring.
        return false;
    }

    ++packetsIn_;
    bytesIn_ += len;
    lastRecvSec_ = nowSecTime;
    remoteSeen_ = true;

    if (dec.hdr.type == PKT_INPUT) {
        auto recordFrame = [&](uint32_t f, uint16_t mask) {
            remoteRing_.put(f, mask);
            Arrival &a = arrival_[f & (kRingSlots - 1)];
            // Earliest arrival wins: redundant copies (bundled in later
            // batches or NEED re-dumps) must not push the lead measurement
            // later than the frame truly became usable.
            if (!a.present || a.frame != f) {
                a.present = true;
                a.frame = f;
                a.t = nowSecTime;
            }
        };
        if (dec.payload.empty()) {
            recordFrame(dec.hdr.frame, dec.hdr.mask);
        } else {
            const size_t count = dec.payload[0];
            for (size_t i = 0; i < count; ++i) {
                if (i > dec.hdr.frame) break; // malformed: below frame 0
                const uint16_t mask = static_cast<uint16_t>(
                    dec.payload[1 + 2 * i] |
                    (static_cast<uint16_t>(dec.payload[2 + 2 * i]) << 8));
                recordFrame(dec.hdr.frame - static_cast<uint32_t>(i), mask);
            }
        }
        cv_.notify_all();
    } else if (dec.hdr.type == PKT_CTRL) {
        onCtrl(dec);
        cv_.notify_all();
    }
    return true;
}

void GsNetplay::onCtrl(const Decoded &pkt) {
    const CtrlType ct = static_cast<CtrlType>(pkt.hdr.flags & 0xFF);
    switch (ct) {
    case CTRL_PING:
        if (pkt.payload.size() >= 8) {
            sendCtrl(CTRL_PONG, pkt.payload.data(), 8);
            // Re-announce START until the first frame advances: the guest
            // pings during the START wait, doubling as a retransmit ack.
            if (cfg_.role == Role::Host && framesAdvanced_ == 0) {
                sendCtrl(CTRL_START);
            }
        }
        break;
    case CTRL_PONG: {
        if (pkt.payload.size() >= 8) {
            uint64_t t0 = 0;
            std::memcpy(&t0, pkt.payload.data(), 8);
            const double rttMs = (nowNs() - t0) / 1e6;
            if (rttMs >= 0 && rttMs < 10000) {
                if (rttSamplesMs_.size() >= kSampleCap) rttSamplesMs_.pop_front();
                rttSamplesMs_.push_back(rttMs);
            }
        }
        break;
    }
    case CTRL_PAUSE:
        remotePaused_ = true;
        break;
    case CTRL_RESUME:
        remotePaused_ = false;
        break;
    case CTRL_BYE:
        running_.store(false, std::memory_order_relaxed);
        break;
    case CTRL_DCHANGE:
        // Only the host measures lead; the guest obeys, host ignores.
        // A fixed-D session (probe) ignores announcements altogether.
        if (cfg_.adaptive && cfg_.role == Role::Guest && !pkt.payload.empty()) {
            int nd = pkt.payload[0];
            if (nd >= 1 && nd <= 2) {
                delayCur_.store(nd, std::memory_order_relaxed);
            }
        }
        break;
    case CTRL_START:
        if (cfg_.role == Role::Guest) {
            started_.store(true, std::memory_order_release);
        }
        break;
    case CTRL_NEED: {
        // Gap resend (FR-15): re-dump local masks [need .. newest] in ONE
        // batch datagram. Runs on the receive thread, so it still fires while
        // the local pace thread is itself frozen behind the gate. Frames
        // older than the 64-slot ring are unrecoverable; the 10s drop timer
        // ends it.
        if (pkt.payload.size() < 4 || !localRing_.everReceived()) break;
        uint32_t need = 0;
        std::memcpy(&need, pkt.payload.data(), 4);
        const uint32_t newest = localRing_.newest();
        if (need > newest || newest - need > kInputBatchMax - 1) break;
        std::vector<uint16_t> masks;
        masks.reserve(static_cast<size_t>(newest - need) + 1);
        for (uint32_t g = newest + 1; g-- > need;) {
            uint16_t m = 0;
            if (!localRing_.get(g, m)) break; // contiguous newest..need only
            masks.push_back(m);
            if (g == 0) break;
        }
        if (!masks.empty()) sendInputBatch(newest, masks);
        break;
    }
    default:
        break;
    }
}

// --------------------------------------------------------------- sending

size_t GsNetplay::sendInput(uint32_t frame, uint16_t mask) {
    uint8_t out[kHeaderLen];
    const size_t n = encode(PKT_INPUT, cfg_.roomId, seqOut_++, frame, mask,
                            0, nullptr, 0, cfg_.key.data(), out, sizeof(out));
    if (n) sendToPeerLocked(out, n);
    return n;
}

size_t GsNetplay::sendInputBatch(uint32_t newestFrame,
                                 const std::vector<uint16_t> &masks) {
    if (masks.empty()) return 0;
    uint8_t out[kHeaderLen + 1 + 2 * kInputBatchMax];
    const size_t n = encodeInputBatch(cfg_.roomId, seqOut_++, newestFrame,
                                      masks.data(), masks.size(),
                                      cfg_.key.data(), out, sizeof(out));
    if (n) sendToPeerLocked(out, n);
    return n;
}

void GsNetplay::sendCtrl(CtrlType type, const uint8_t *payload,
                         size_t payloadLen) {
    uint8_t out[128];
    const size_t n =
        encode(PKT_CTRL, cfg_.roomId, seqOut_++, 0, 0,
               static_cast<uint16_t>(type), payload, payloadLen,
               cfg_.key.data(), out, sizeof(out));
    if (n) sendToPeerLocked(out, n);
}

void GsNetplay::sendToPeerLocked(const uint8_t *data, size_t len) {
    if (sock_ < 0) return;
    ssize_t w = sendto(sock_, data, len, 0,
                       (sockaddr *)&peerAddr_, sizeof(peerAddr_));
    if (w > 0) {
        ++packetsOut_;
        bytesOut_ += static_cast<uint64_t>(w);
    }
}

void GsNetplay::debugSendRaw(const uint8_t *data, size_t len) {
    std::lock_guard<std::mutex> lk(mtx_);
    sendToPeerLocked(data, len);
}

uint32_t GsNetplay::debugNextSeq() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return seqOut_;
}

// ----------------------------------------------------------------- stats

double GsNetplay::percentile(std::deque<double> v, double q) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    size_t i = (size_t)std::lround(q * (v.size() - 1));
    return v[i];
}

NetStats GsNetplay::stats() const {
    std::lock_guard<std::mutex> lk(mtx_);
    NetStats s;
    int st;
    if (!running_.load(std::memory_order_relaxed)) {
        st = static_cast<int>(droppedByTimeout_.load(std::memory_order_relaxed)
                                  ? NetState::Dropped
                                  : NetState::Ended);
    } else if (!started_.load(std::memory_order_relaxed)) {
        st = static_cast<int>(NetState::Starting);
    } else if (localPaused_.load(std::memory_order_relaxed) || remotePaused_) {
        st = static_cast<int>(NetState::Paused);
    } else {
        st = static_cast<int>(NetState::Running);
    }
    s.state = st;
    s.d = delayCur_.load(std::memory_order_relaxed);
    s.started = started_.load(std::memory_order_relaxed);
    s.rttMinMs = percentile(rttSamplesMs_, 0);
    s.rttP50Ms = percentile(rttSamplesMs_, 0.50);
    s.rttP95Ms = percentile(rttSamplesMs_, 0.95);
    s.rttP99Ms = percentile(rttSamplesMs_, 0.99);
    s.leadP50Ms = percentile(leadSamplesMs_, 0.50);
    s.leadP95Ms = percentile(leadSamplesMs_, 0.95);
    s.framesAdvanced = framesAdvanced_;
    s.lateFrames = lateFrames_;
    s.frozenFrames = frozenFrames_;
    s.blockedMsTotal = blockedMsTotal_;
    s.packetsIn = packetsIn_;
    s.packetsOut = packetsOut_;
    s.bytesIn = bytesIn_;
    s.bytesOut = bytesOut_;
    s.redundantSends = redundantSends_;
    s.rejBadLen = rejBadLen_;
    s.rejBadMagic = rejBadMagic_;
    s.rejBadVersion = rejBadVer_;
    s.rejBadTag = rejBadTag_;
    s.replayDup = replay_.duplicates();
    s.replayOld = replay_.expired();
    s.foreignPackets = foreignPackets_;
    s.dUpgrades = delay_.upgrades();
    s.dDowngrades = delay_.downgrades();
    const double el = nowSec() - startSec_;
    s.effFps = el > 0 ? framesAdvanced_ / el : 0;
    return s;
}

} // namespace np
