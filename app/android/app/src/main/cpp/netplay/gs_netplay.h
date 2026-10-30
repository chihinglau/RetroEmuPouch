// UDP frame transport for GamePouch delay-based lockstep.
//
// One GsNetplay object backs one running GsRunner session. The emulation
// pacing thread drives it once per frame:
//
//   beginFrame(K)  -> gate: blocks until the REMOTE input for frame K-D is
//                    in the ring (inputs for frames before frame0 read as
//                    "buttons up"); returns the DELAYED local+remote masks
//                    that must drive frame K.
//   ... retro_run() ...
//   endFrame(K,m)  -> stores this frame's live local mask and redundantly
//                    sends INPUT packets for the last N=D+2 frames.
//
// A dedicated receive thread verifies every datagram (length -> magic ->
// version -> HMAC tag -> RFC6479 replay window) and enqueues accepted
// INPUT frames into the ring. CTRL packets drive pause/resume/bye/start
// and host-announced D changes. RTT is measured with sparse CTRL ping/pong.
//
// Threading: begin/endFrame run on the pacing thread; the receive thread
// only touches the ring/stats under mtx_. stop() joins before returning.
#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <netinet/in.h>
#include <string>
#include <thread>
#include <vector>

#include "gs_np_codec.h"
#include "gs_np_delay.h"
#include "gs_np_replay.h"
#include "gs_np_ring.h"

namespace np {

enum class Role { Host = 0, Guest = 1 };

enum class NetState {
  Idle = 0,
  Starting,  // socket up, CTRL_START gate not yet open
  Running,
  Dropped,   // >=10s without a valid packet outside pause
  Ended,     // local stop() or remote CTRL_BYE
  Paused,    // local or remote CTRL_PAUSE active
};

enum class GateResult {
  Ok = 0,
  Paused,    // local or remote paused; same frame must be retried later
  Dead,      // dropped/bye/stopped; session unusable
};

struct NetConfig {
  Role role = Role::Host;
  std::string peerIp;        // dotted IPv4
  uint16_t peerPort = 0;
  uint16_t localPort = 0;    // 0 = ephemeral high port
  std::array<uint8_t, 32> key{};
  uint32_t roomId = 0;
  int initialD = 2;          // production: 2; probe determinism run: 0
  // Host-only adaptive D controller (FR-16). The probe pins a fixed D so
  // checkpoints line up with the frame numbers; the shipping app leaves
  // this true.
  bool adaptive = true;
  uint32_t frame0 = 0;
  double framePeriodSec = 1.0 / 59.61;
  // Test knobs (0 = off): receiver drops every inbound packet during
  // [blackholeAt, blackholeAt+dur) measured from start().
  double blackholeAtSec = 0.0;
  double blackholeDurSec = 0.0;
};

struct NetStats {
  int state = 0;
  int d = 0;
  bool started = false;
  double rttMinMs = 0, rttP50Ms = 0, rttP95Ms = 0, rttP99Ms = 0;
  double leadP50Ms = 0, leadP95Ms = 0;
  uint64_t framesAdvanced = 0;
  uint64_t lateFrames = 0;
  uint64_t frozenFrames = 0;
  // Total wall time pace threads spent blocked at the frame gate (ms); the
  // user-visible freeze budget. frozenFrames counts blocking episodes.
  uint64_t blockedMsTotal = 0;
  uint64_t packetsIn = 0, packetsOut = 0;
  uint64_t bytesIn = 0, bytesOut = 0;
  uint64_t redundantSends = 0;
  uint64_t rejBadLen = 0, rejBadMagic = 0, rejBadVersion = 0, rejBadTag = 0;
  uint64_t replayDup = 0, replayOld = 0;
  uint64_t foreignPackets = 0;
  uint64_t dUpgrades = 0, dDowngrades = 0;
  double effFps = 0;
};

class GsNetplay {
public:
  GsNetplay();
  ~GsNetplay();

  bool start(const NetConfig &cfg);
  void stop();
  /// Best-effort CTRL_BYE then stop(). Safe to call repeatedly.
  void shutdown();
  bool running() const { return running_.load(std::memory_order_relaxed); }
  uint16_t localPort() const;

  /// Host: open the START gate locally and announce CTRL_START (re-sent
  /// automatically until the guest's first INPUT arrives).
  void notifyStart();

  /// Gate frame [frame]. On Ok, [localMask]/[remoteMask] are the delayed
  /// (frame-D) masks that must drive retro_run.
  GateResult beginFrame(uint32_t frame, uint16_t &localMask,
                        uint16_t &remoteMask);

  /// Record the live local mask for [frame] and flush redundant INPUT.
  void endFrame(uint32_t frame, uint16_t localMask);

  /// Local pause intent: also sends CTRL_PAUSE/RESUME so the peer gate
  /// parks deterministically.
  void setLocalPaused(bool paused);

  /// Send one CTRL_PING (peer auto-replies PONG). Used to warm the Wi-Fi
  /// path and keep RTT fresh while the guest waits for CTRL_START.
  void ping();

  NetStats stats() const;

  /// Test/probe hook: send raw bytes to the configured peer.
  void debugSendRaw(const uint8_t *data, size_t len);

  /// Test/probe hook: next outbound sequence number (for replay crafting).
  uint32_t debugNextSeq() const;

private:
  struct Arrival {
    bool present = false;
    double t = 0.0;
    uint32_t frame = UINT32_MAX; // owner frame; stale-slot guard
  };

  void recvLoop();
  bool handleDatagram(const uint8_t *buf, size_t len, double nowSec);
  void onCtrl(const Decoded &pkt);

  // All send helpers assume mtx_ is held (send path shares the encode
  // sequence counter with the receive/state path).
  size_t sendInput(uint32_t frame, uint16_t mask);
  // One datagram carrying masks for newestFrame, newestFrame-1, ... in order.
  size_t sendInputBatch(uint32_t newestFrame,
                        const std::vector<uint16_t> &masks);
  void sendCtrl(CtrlType type, const uint8_t *payload = nullptr,
                size_t payloadLen = 0);
  void sendToPeerLocked(const uint8_t *data, size_t len);
  static double percentile(std::deque<double> v, double q);

  NetConfig cfg_;
  int sock_ = -1;
  struct sockaddr_in peerAddr_{};
  std::atomic<bool> running_{false};
  std::atomic<bool> droppedByTimeout_{false};
  std::thread recvThread_;

  mutable std::mutex mtx_;
  std::condition_variable cv_;

  uint32_t seqOut_ = 1;
  ReplayWindow replay_;
  InputRing remoteRing_;
  InputRing localRing_;
  std::vector<Arrival> arrival_; // 64 slots keyed by frame & 63

  DelayCtrl delay_;
  std::atomic<int> delayCur_;
  std::atomic<bool> started_{false};
  std::atomic<bool> localPaused_{false};
  bool remotePaused_ = false;
  bool remoteSeen_ = false;
  double lastRecvSec_ = 0;
  double startSec_ = 0;
  uint64_t framesAdvanced_ = 0;
  uint64_t frozenFrames_ = 0;
  uint64_t blockedMsTotal_ = 0;
  uint32_t frozenAtFrame_ = UINT32_MAX;
  uint64_t lateFrames_ = 0;
  uint64_t packetsIn_ = 0, packetsOut_ = 0;
  uint64_t bytesIn_ = 0, bytesOut_ = 0;
  uint64_t redundantSends_ = 0;
  uint64_t rejBadLen_ = 0, rejBadMagic_ = 0, rejBadVer_ = 0, rejBadTag_ = 0;
  uint64_t foreignPackets_ = 0;
  std::deque<double> rttSamplesMs_; // cap 512
  std::deque<double> leadSamplesMs_; // cap 512
};

} // namespace np
