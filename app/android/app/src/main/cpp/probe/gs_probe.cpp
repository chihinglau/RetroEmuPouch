// GamePouch Phase-0 netplay probe.
//
// Standalone /data/local/tmp executable. No app code is involved.
//
// Modes:
//   gs_probe pong  <port> [durationSec]
//       UDP echo: reflects type-1 ping packets as type-2 pong.
//   gs_probe ping  <host> <port> <count> <intervalMs>
//       RTT / jitter / loss probe, prints percentiles.
//   gs_probe det   <core.so> <rom> <frames>
//       Runs the core twice from an identical cold start with identical
//       scripted per-port input; FNV-1a hashes of retro_serialize() at
//       checkpoints must match between runs AND between devices.
//   gs_probe lhost <core.so> <rom> <guestIp> <guestPort> <frames>
//   gs_probe lguest <core.so> <rom> <bindPort> <frames>
//       Bare delay-0 lockstep over UDP: host is pacemaker at the core's
//       native fps; per frame both sides exchange one 20-byte input packet
//       before retro_run(). Host prints the remote-input lead-time
//       distribution (the D=0 freeze indicator) and emu frame cost;
//       guest prints packet interarrival / emu cost. Final state hashes
//       on both phones must be byte-identical.
//   gs_probe lhost2  <core.so> <rom> <guestIp> [frames] [at:dur] [attack] [d2]
//   gs_probe lguest2 <core.so> <rom> <hostIp>  [frames] [at:dur] [attack] [d2]
//       Phase 1: real np::GsNetplay stack (HMAC codec/replay/ring/gap
//       resend) on fixed UDP ports 43811/43810. Fixed D=0 checkpoints must
//       equal the Phase-0 constants; "at:dur" injects an inbound blackhole;
//       "attack" injects malformed/tampered/replayed/foreign datagrams.
//
// Packet (24 bytes, little-endian):
//   u32 magic 'GSP0'  u8 type  u8 rsvd  u16 seq
//   u32 frame        u16 mask  u16 rsvd2
//   u64 t0Ns (ping only)

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <dlfcn.h>
#include <string>
#include <vector>

extern "C" {
#include <libretro.h>
}

#include "gs_np_codec.h"
#include "gs_np_delay.h"
#include "gs_np_replay.h"
#include "gs_np_ring.h"
#include "gs_np_sha256.h"
#include "gs_netplay.h"

namespace {

constexpr uint32_t kMagic = 0x30505347; // 'G','S','P','0' little-endian
constexpr uint8_t  kPing = 1, kPong = 2, kFrame = 3;
constexpr int      kGuestPort = 43810;

double nowSec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

uint64_t nowNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

// ----------------------------------------------------------- packet codec

#pragma pack(push, 1)
struct Pkt {
    uint32_t magic;
    uint8_t  type;
    uint8_t  rsvd;
    uint16_t seq;
    uint32_t frame;
    uint16_t mask;
    uint16_t rsvd2;
    uint64_t t0;
};
#pragma pack(pop)
static_assert(sizeof(Pkt) == 24, "probe packet must be 24 bytes");

void putPkt(uint8_t *b, const Pkt &p) { memcpy(b, &p, sizeof(p)); }
bool getPkt(const uint8_t *b, size_t n, Pkt &p) {
    if (n != sizeof(Pkt)) return false;
    memcpy(&p, b, sizeof(p));
    return p.magic == kMagic;
}

// ------------------------------------------------------------ statistics

double pct(std::vector<double> v, double q) {
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    size_t i = (size_t)std::lround(q * (v.size() - 1));
    return v[i];
}

void printDist(const char *tag, const std::vector<double> &v) {
    if (v.empty()) { printf("%s: (no samples)\n", tag); return; }
    double sum = 0; for (double x : v) sum += x;
    printf("%s: n=%zu min=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f mean=%.3f ms\n",
           tag, v.size(), pct(v, 0), pct(v, .50), pct(v, .95),
           pct(v, .99), pct(v, 1), sum / (double)v.size());
}

uint64_t fnv1a(const uint8_t *p, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

// --------------------------------------------------------- scripted input
//
// Deterministic functions of the frame number ONLY; both phones derive the
// same masks without exchanging scripts. libretro digital ids:
//   B=0 Y=1 SELECT=2 START=3 UP=4 DOWN=5 LEFT=6 RIGHT=7 A=8 X=9 L=10 R=11

uint16_t maskA(uint32_t f) { // host / port 0
    uint16_t m = 0;
    if (f >= 60 && f < 1500) m |= 1u << 7;                 // hold RIGHT
    if (f >= 60 && f < 1500 && (f % 24) == 0) m |= 1u << 0; // tap B
    if (f == 30) m |= 1u << 3;                              // START once
    return m;
}

uint16_t maskB(uint32_t f) { // guest / port 1
    uint16_t m = 0;
    if (f >= 120 && f < 900) m |= 1u << 6;                 // hold LEFT
    if (f >= 900 && f < 1500) m |= 1u << 5;                // hold DOWN
    if ((f % 36) == 0) m |= 1u << 8;                       // tap A
    return m;
}

// ----------------------------------------------------------- core wrapper

struct Core {
    void *handle = nullptr;
    char *romPathAbs = nullptr;
    std::vector<uint8_t> romBytes;
    void (*init)() = nullptr;
    void (*deinit)() = nullptr;
    bool (*load_game)(const retro_game_info *) = nullptr;
    void (*unload_game)() = nullptr;
    void (*run)() = nullptr;
    void (*get_av)(retro_system_av_info *) = nullptr;
    size_t (*serialize_size)() = nullptr;
    bool (*serialize)(void *, size_t) = nullptr;
    void (*set_port)(unsigned, unsigned) = nullptr;

    static uint16_t masks[4];
    static unsigned pixFmt;
    static std::string saveDir, sysDir;

    static void coreLog(enum retro_log_level, const char *fmt, ...) {
        va_list ap; va_start(ap, fmt);
        printf("[core] "); vprintf(fmt, ap); printf("\n");
        va_end(ap); fflush(stdout);
    }

    template <typename T> bool sym(const char *name, T &out) {
        out = reinterpret_cast<T>(dlsym(handle, name));
        if (!out) { printf("dlsym %s failed: %s\n", name, dlerror()); return false; }
        return true;
    }

    static bool env(unsigned cmd, void *data) {
        switch (cmd) {
            case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
                pixFmt = *static_cast<const retro_pixel_format *>(data);
                return pixFmt == RETRO_PIXEL_FORMAT_XRGB8888 ||
                       pixFmt == RETRO_PIXEL_FORMAT_RGB565 ||
                       pixFmt == RETRO_PIXEL_FORMAT_0RGB1555;
            case RETRO_ENVIRONMENT_GET_CAN_DUPE:
                *static_cast<bool *>(data) = true; return true;
            case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
                *static_cast<const char **>(data) = saveDir.c_str(); return true;
            case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
                *static_cast<const char **>(data) = sysDir.c_str(); return true;
            case RETRO_ENVIRONMENT_SET_GEOMETRY: return true;
            case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS: return true;
            case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
                auto *lg = static_cast<retro_log_callback *>(data);
                lg->log = coreLog;
                return true;
            }
            default: return false;
        }
    }
    static void video(const void *, unsigned, unsigned, size_t) {}
    static size_t audioBatch(const int16_t *, size_t frames) { return frames; }
    static void poll() {}
    static int16_t input(unsigned port, unsigned device, unsigned, unsigned id) {
        if (port >= 4 || id > 15) return 0;
        if (device != RETRO_DEVICE_JOYPAD && device != RETRO_DEVICE_ANALOG) return 0;
        return (masks[port] >> id) & 1;
    }

    bool open(const char *soPath, const char *romPath) {
        handle = dlopen(soPath, RTLD_NOW | RTLD_LOCAL);
        if (!handle) { printf("dlopen failed: %s\n", dlerror()); return false; }
        unsigned (*api)() = nullptr;
        void (*set_env)(retro_environment_t) = nullptr;
        void (*set_vid)(retro_video_refresh_t) = nullptr;
        void (*set_ab)(retro_audio_sample_batch_t) = nullptr;
        void (*set_poll)(retro_input_poll_t) = nullptr;
        void (*set_in)(retro_input_state_t) = nullptr;
        if (!sym("retro_api_version", api)) return false;
        if (!sym("retro_set_environment", set_env)) return false;
        if (!sym("retro_set_video_refresh", set_vid)) return false;
        if (!sym("retro_set_audio_sample_batch", set_ab)) return false;
        if (!sym("retro_set_input_poll", set_poll)) return false;
        if (!sym("retro_set_input_state", set_in)) return false;
        if (!sym("retro_init", init)) return false;
        if (!sym("retro_deinit", deinit)) return false;
        if (!sym("retro_load_game", load_game)) return false;
        if (!sym("retro_unload_game", unload_game)) return false;
        if (!sym("retro_run", run)) return false;
        if (!sym("retro_get_system_av_info", get_av)) return false;
        if (!sym("retro_serialize_size", serialize_size)) return false;
        if (!sym("retro_serialize", serialize)) return false;
        set_port = reinterpret_cast<void (*)(unsigned, unsigned)>(
            dlsym(handle, "retro_set_controller_port_device"));

        printf("retro_api_version=%u\n", api());
        set_env(env);
        set_vid(video);
        set_ab(audioBatch);
        set_poll(poll);
        set_in(input);

        mkdir(saveDir.c_str(), 0777);
        mkdir(sysDir.c_str(), 0777);

        init();
        if (set_port) {
            // fbalpha-family cores expose the "Classic retropad" as
            // RETRO_DEVICE_ANALOG; fceumm's two pads are plain JOYPADs and it
            // crashes dereferencing the unknown ANALOG device pre-load.
            const bool fceumm = strstr(soPath, "fceumm") != nullptr;
            const unsigned dev =
                fceumm ? RETRO_DEVICE_JOYPAD : RETRO_DEVICE_ANALOG;
            for (unsigned p = 0; p < 4; ++p) set_port(p, dev);
            printf("assigned device %u (%s) to ports 0..3\n", dev,
                   fceumm ? "JOYPAD" : "CLASSIC-ANALOG");
            fflush(stdout);
        }

        FILE *f = fopen(romPath, "rb");
        if (!f) { printf("cannot open rom %s\n", romPath); return false; }
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        romBytes.resize((size_t)sz);
        if (fread(romBytes.data(), 1, romBytes.size(), f) != romBytes.size()) {
            printf("rom short read\n"); fclose(f); return false;
        }
        fclose(f);

        // App library ROMs ship as an MGS1-encrypted payload; the real core
        // never sees ciphertext (LockedRom.materialize on the Kotlin side).
        if (romBytes.size() >= 4 && memcmp(romBytes.data(), "MGS1", 4) == 0) {
            size_t plen = 0;
            uint8_t *p = gs_rom_decrypt(romBytes.data(), romBytes.size(), &plen);
            if (!p) { printf("MGS1 decrypt failed\n"); return false; }
            romBytes.assign(p, p + plen);
            gs_rom_free(p);
            printf("MGS1 decrypted: %zu plaintext bytes\n", plen);
        }

        // fbalpha opens the archive from disk by basename (driver lookup),
        // so materialise the plaintext under its original ffight.zip name.
        const char *slash = strrchr(romPath, '/');
        const char *base = slash ? slash + 1 : romPath;
        const std::string workDir = "/data/local/tmp/gsp/work";
        mkdir(workDir.c_str(), 0777);
        const std::string staged = workDir + "/" + base;
        FILE *o = fopen(staged.c_str(), "wb");
        if (!o) { printf("cannot stage rom: %s\n", strerror(errno)); return false; }
        fwrite(romBytes.data(), 1, romBytes.size(), o);
        fclose(o);

        romPathAbs = realpath(staged.c_str(), nullptr);
        if (!romPathAbs) {
            printf("realpath failed: %s\n", strerror(errno)); return false;
        }
        retro_game_info gi{};
        gi.path = romPathAbs;
        gi.data = romBytes.data();
        gi.size = romBytes.size();
        printf("load_game path=%s size=%zu\n", romPathAbs, romBytes.size());
        if (!load_game(&gi)) { printf("retro_load_game failed\n"); return false; }

        size_t st = serialize_size(); // R2 prime: cache may be lazy.
        printf("serialize_size=%zu\n", st);
        retro_system_av_info av{};
        get_av(&av);
        printf("fps=%.4f rate=%.1f\n", av.timing.fps, av.timing.sample_rate);
        fps = av.timing.fps > 0 ? av.timing.fps : 60.0;
        return st > 0;
    }

    double fps = 60.0;

    uint64_t hashState() {
        size_t n = serialize_size();
        std::vector<uint8_t> buf(n);
        if (!serialize(buf.data(), n)) { printf("serialize FAILED\n"); return 0; }
        return fnv1a(buf.data(), n);
    }

    void close() {
        if (!handle) return;
        unload_game();
        deinit();
        dlclose(handle);
        handle = nullptr;
        free(romPathAbs);
        romPathAbs = nullptr;
    }
};
uint16_t Core::masks[4] = {0, 0, 0, 0};
unsigned Core::pixFmt = 0;
std::string Core::saveDir, Core::sysDir;

// ----------------------------------------------------------------- modes

int modePong(int argc, char **argv) {
    int port = argc > 2 ? atoi(argv[2]) : kGuestPort;
    int duration = argc > 3 ? atoi(argv[3]) : 600;
    signal(SIGPIPE, SIG_IGN);
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (bind(fd, (sockaddr *)&a, sizeof(a)) < 0) {
        printf("bind failed: %s\n", strerror(errno)); return 1;
    }
    timeval tv{1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    printf("pong listening :%d for %ds\n", port, duration);
    fflush(stdout);
    double end = nowSec() + duration;
    long n = 0;
    uint8_t buf[64];
    while (nowSec() < end) {
        sockaddr_in from{};
        socklen_t fl = sizeof(from);
        ssize_t r = recvfrom(fd, buf, sizeof(buf), 0, (sockaddr *)&from, &fl);
        if (r < 0) continue;
        Pkt p;
        if (!getPkt(buf, (size_t)r, p) || p.type != kPing) continue;
        p.type = kPong;
        putPkt(buf, p);
        sendto(fd, buf, sizeof(Pkt), 0, (sockaddr *)&from, fl);
        ++n;
    }
    printf("pong reflected %ld packets\n", n);
    return 0;
}

int modePing(int argc, char **argv) {
    const char *host = argv[2];
    int port = atoi(argv[3]);
    int count = argc > 4 ? atoi(argv[4]) : 300;
    int intervalMs = argc > 5 ? atoi(argv[5]) : 16;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    timeval tv{1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int bindPort = argc > 6 ? atoi(argv[6]) : 0;
    if (bindPort > 0) {
        sockaddr_in la{};
        la.sin_family = AF_INET;
        la.sin_addr.s_addr = htonl(INADDR_ANY);
        la.sin_port = htons((uint16_t)bindPort);
        if (bind(fd, (sockaddr *)&la, sizeof(la)) < 0) {
            printf("bind %d failed: %s\n", bindPort, strerror(errno));
            return 1;
        }
    }
    sockaddr_in dst{};
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &dst.sin_addr) != 1) {
        printf("bad ip %s\n", host); return 1;
    }
    printf("ping %s:%d count=%d interval=%dms size=%zu\n",
           host, port, count, intervalMs, sizeof(Pkt));
    fflush(stdout);

    std::vector<double> rtts;
    std::vector<uint64_t> sentNs(count, 0);
    int lost = 0;
    for (int i = 0; i < count; ++i) {
        Pkt p{kMagic, kPing, 0, (uint16_t)i, 0, 0, 0, nowNs()};
        uint8_t buf[sizeof(Pkt)];
        putPkt(buf, p);
        sendto(fd, buf, sizeof(buf), 0, (sockaddr *)&dst, sizeof(dst));
        sentNs[i] = p.t0;
        double deadline = nowSec() + 1.0;
        bool got = false;
        while (nowSec() < deadline) {
            sockaddr_in src{}; socklen_t sl = sizeof(src);
            ssize_t r = recvfrom(fd, buf, sizeof(buf), 0, (sockaddr *)&src, &sl);
            if (r < 0) break; // timeout: count loss, move on
            Pkt q;
            if (!getPkt(buf, (size_t)r, q) || q.type != kPong) continue;
            int seq = q.seq;
            if (seq < 0 || seq >= count || sentNs[seq] == 0) continue;
            rtts.push_back((nowNs() - sentNs[seq]) / 1e6);
            sentNs[seq] = 0;
            got = true;
            break;
        }
        if (!got) ++lost;
        usleep((useconds_t)intervalMs * 1000);
    }
    printDist("rtt", rtts);
    printf("loss: %d/%d (%.1f%%)\n", lost, count, 100.0 * lost / count);
    return 0;
}

int modeBlast(int argc, char **argv) {
    const char *host = argv[2];
    int port = atoi(argv[3]);
    int count = argc > 4 ? atoi(argv[4]) : 100;
    int intervalMs = argc > 5 ? atoi(argv[5]) : 50;
    int bindPort = argc > 6 ? atoi(argv[6]) : 0;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (bindPort > 0) {
        sockaddr_in la{};
        la.sin_family = AF_INET;
        la.sin_addr.s_addr = htonl(INADDR_ANY);
        la.sin_port = htons((uint16_t)bindPort);
        if (bind(fd, (sockaddr *)&la, sizeof(la)) < 0) {
            printf("bind failed: %s\n", strerror(errno));
            return 1;
        }
    }
    sockaddr_in dst{};
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, host, &dst.sin_addr);
    uint8_t buf[24];
    memset(buf, 0xAB, sizeof(buf));
    for (int i = 0; i < count; ++i) {
        sendto(fd, buf, sizeof(buf), 0, (sockaddr *)&dst, sizeof(dst));
        if (intervalMs > 0) usleep((useconds_t)intervalMs * 1000);
    }
    printf("blast sent %d to %s:%d\n", count, host, port);
    close(fd);
    return 0;
}

int modeDet(int argc, char **argv) {
    const char *so = argv[2], *rom = argv[3];
    uint32_t frames = (uint32_t)atoi(argv[4]);
    const uint32_t cps[] = {120, 600, 1200, frames};
    Core::saveDir = "/data/local/tmp/gsp/save";
    Core::sysDir = "/data/local/tmp/gsp/system";

    std::vector<uint64_t> h1, h2;
    for (int run = 0; run < 2; ++run) {
        Core::masks[0] = Core::masks[1] = Core::masks[2] = Core::masks[3] = 0;
        Core c;
        printf("---- determinism run %d ----\n", run + 1);
        if (!c.open(so, rom)) return 1;
        size_t ci = 0;
        for (uint32_t f = 0; f < frames; ++f) {
            Core::masks[0] = maskA(f);
            Core::masks[1] = maskB(f);
            c.run();
            if (ci < 4 && f + 1 == cps[ci]) {
                uint64_t h = c.hashState();
                printf("cp f=%u hash=%016llx\n", f + 1, (unsigned long long)h);
                (run == 0 ? h1 : h2).push_back(h);
                ++ci;
            }
        }
        c.close();
    }
    bool ok = h1.size() == h2.size();
    for (size_t i = 0; ok && i < h1.size(); ++i) ok = h1[i] == h2[i];
    printf(ok ? "DETERMINISM: PASS (in-process)\n"
              : "DETERMINISM: FAIL\n");
    return ok ? 0 : 2;
}

void setRcvo(int fd, int ms) {
    timeval tv{ms / 1000, ms % 1000 * 1000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

int modeLockHost(int argc, char **argv) {
    const char *so = argv[2], *rom = argv[3], *guestIp = argv[4];
    int guestPort = argc > 5 ? atoi(argv[5]) : kGuestPort;
    uint32_t frames = (uint32_t)argc > 6 ? atoi(argv[6]) : 1800;
    const uint32_t cps[] = {120, 600, 1200, frames};

    Core::saveDir = "/data/local/tmp/gsp/save";
    Core::sysDir = "/data/local/tmp/gsp/system";
    Core c;
    if (!c.open(so, rom)) return 1;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in dst{};
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)guestPort);
    if (inet_pton(AF_INET, guestIp, &dst.sin_addr) != 1) {
        printf("bad guest ip\n"); return 1;
    }
    setRcvo(fd, 8);

    std::vector<double> leads, emus;
    long rexmits = 0, late = 0;
    double anchor = nowSec();
    const double period = 1.0 / c.fps;

    size_t ci = 0;
    for (uint32_t f = 0; f < frames; ++f) {
        Core::masks[0] = maskA(f);
        Core::masks[1] = 0;
        Pkt p{kMagic, kFrame, 0, 0, f, Core::masks[0], 0, 0};
        uint8_t sb[sizeof(Pkt)], rb[64];
        putPkt(sb, p);

        double deadline = anchor + (f + 1) * period;
        sendto(fd, sb, sizeof(sb), 0, (sockaddr *)&dst, sizeof(dst));

        double arr = 0;
        double giveUp = nowSec() + 0.5;
        for (;;) {
            sockaddr_in src{}; socklen_t sl = sizeof(src);
            ssize_t r = recvfrom(fd, rb, sizeof(rb), 0, (sockaddr *)&src, &sl);
            if (r == (ssize_t)sizeof(Pkt)) {
                Pkt q;
                if (getPkt(rb, (size_t)r, q) && q.type == kFrame) {
                    if (q.frame == f) {
                        Core::masks[1] = q.mask;
                        arr = nowSec();
                        break;
                    }
                    // stale/duplicate: discard
                }
            } else {
                if (nowSec() > giveUp) { printf("frame %u peer timeout\n", f); return 3; }
                sendto(fd, sb, sizeof(sb), 0, (sockaddr *)&dst, sizeof(dst));
                ++rexmits;
            }
        }
        double leadMs = (deadline - arr) * 1000.0;
        leads.push_back(leadMs);
        if (leadMs < 0) ++late;

        double remain = deadline - nowSec();
        if (remain > 0) usleep((useconds_t)(remain * 1e6));

        double t0 = nowSec();
        c.run();
        emus.push_back((nowSec() - t0) * 1000.0);

        if (ci < 4 && f + 1 == cps[ci]) {
            printf("cp f=%u hash=%016llx\n", f + 1,
                   (unsigned long long)c.hashState());
            ++ci;
        }
    }
    double wall = nowSec() - anchor;
    printf("---- host stats ----\n");
    printDist("remoteLead(D0, + = safe)", leads);
    printDist("emuFrame", emus);
    printf("lateFrames=%ld/%u (%.1f%%) rexmits=%ld wall=%.2fs effFps=%.2f\n",
           late, frames, 100.0 * late / frames, rexmits, wall, frames / wall);
    c.close();
    return 0;
}

int modeLockGuest(int argc, char **argv) {
    const char *so = argv[2], *rom = argv[3];
    int bindPort = argc > 4 ? atoi(argv[4]) : kGuestPort;
    uint32_t frames = (uint32_t)argc > 5 ? atoi(argv[5]) : 1800;
    const uint32_t cps[] = {120, 600, 1200, frames};

    Core::saveDir = "/data/local/tmp/gsp/save";
    Core::sysDir = "/data/local/tmp/gsp/system";
    Core c;
    if (!c.open(so, rom)) return 1;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)bindPort);
    if (bind(fd, (sockaddr *)&a, sizeof(a)) < 0) {
        printf("guest bind failed: %s\n", strerror(errno)); return 1;
    }
    setRcvo(fd, 3000);

    uint16_t hist[64] = {0};
    std::vector<double> gaps, emus;
    sockaddr_in host{};
    socklen_t hl = sizeof(host);
    double lastArr = 0;
    long dups = 0, idleTimeouts = 0;
    size_t ci = 0;
    double t0all = nowSec();

    for (uint32_t f = 0; f < frames; ++f) {
        uint16_t peerMask = 0;
        double giveUp = nowSec() + 10.0;
        for (;;) {
            uint8_t rb[64], sb[sizeof(Pkt)];
            sockaddr_in src{}; socklen_t sl = sizeof(src);
            ssize_t r = recvfrom(fd, rb, sizeof(rb), 0, (sockaddr *)&src, &sl);
            if (r != (ssize_t)sizeof(Pkt)) {
                if (nowSec() > giveUp) { printf("frame %u host gone\n", f); return 3; }
                ++idleTimeouts;
                continue;
            }
            Pkt q;
            if (!getPkt(rb, (size_t)r, q) || q.type != kFrame) continue;
            host = src; hl = sl;
            uint16_t reply = maskB(q.frame);
            hist[q.frame % 64] = reply;
            Pkt a2{kMagic, kFrame, 0, 0, q.frame, reply, 0, 0};
            putPkt(sb, a2);
            sendto(fd, sb, sizeof(sb), 0, (sockaddr *)&host, hl);
            if (q.frame < f) { ++dups; continue; } // answered from retransmit
            if (q.frame > f) { printf("guest: frame gap %u->%u\n", f, q.frame); return 4; }
            peerMask = q.mask;
            break;
        }
        double arr = nowSec();
        if (lastArr > 0) gaps.push_back((arr - lastArr) * 1000.0);
        lastArr = arr;

        Core::masks[0] = peerMask;
        Core::masks[1] = maskB(f);
        double t0 = nowSec();
        c.run();
        emus.push_back((nowSec() - t0) * 1000.0);

        if (ci < 4 && f + 1 == cps[ci]) {
            printf("cp f=%u hash=%016llx\n", f + 1,
                   (unsigned long long)c.hashState());
            ++ci;
        }
    }
    printf("---- guest stats ----\n");
    printDist("hostPacketGap", gaps);
    printDist("emuFrame", emus);
    printf("dups=%ld idleTimeouts=%ld wall=%.2fs effFps=%.2f\n",
           dups, idleTimeouts, nowSec() - t0all,
           frames / (nowSec() - t0all));
    c.close();
    return 0;
}

// ------------------------------------------------- Phase 1 lockstep probe
//
// lhost2 / lguest2 drive the REAL production stack: np::GsNetplay
// (28-byte HMAC codec, replay window, input rings, FR-15 gap resend) plus
// the same scripted two-player input and FNV checkpoints.
//
// Determinism run uses fixed D=0 (publish-before-gate ordering): frame K
// runs with both masks of frame K, so checkpoints equal the Phase-0 solo
// constants. A "d2" run pins D=2; then gate frame K carries solo frame
// K-D, so the same constants must appear at checkpoints 122/602/1202/1802.

constexpr uint16_t kNpHostPort = 43811;
constexpr uint16_t kNpGuestPort = 43810;
constexpr uint32_t kNpRoom = 0x47534e32; // 'GSN2'

void npSessionKey(uint8_t out[32]) {
    for (int i = 0; i < 32; ++i) out[i] = (uint8_t)(0x50 + i);
}

bool parseBlackhole(const char *s, double &at, double &dur) {
    if (!s) return false;
    return sscanf(s, "%lf:%lf", &at, &dur) == 2;
}

// TR-3.3 adversarial traffic. Authenticated malformed/replayed packets go
// out through the session socket (peer addr/port match) via debugSendRaw;
// one junk packet comes from an ephemeral socket and must be counted as
// foreign before HMAC is even looked at.
void runAttack(np::GsNetplay &net, const sockaddr_in &peer, int fixedD) {
    uint8_t key[32];
    npSessionKey(key);
    uint8_t buf[3100];

    size_t good = np::encode(np::PKT_INPUT, kNpRoom, 100, 7, 0x1234, 0,
                             nullptr, 0, key, buf, sizeof(buf));
    // Truncated (below header) and oversized datagram.
    net.debugSendRaw(buf, good - 1);
    net.debugSendRaw(buf, 10);
    for (size_t i = 0; i < 3000; ++i) buf[i] = (uint8_t)(i * 31 + 7);
    net.debugSendRaw(buf, 3000);

    // Broken magic, header only.
    size_t n = np::encode(np::PKT_INPUT, kNpRoom, 101, 7, 0, 0,
                          nullptr, 0, key, buf, sizeof(buf));
    buf[0] = 0x00;
    net.debugSendRaw(buf, n);

    // Wrong protocol version with a correctly recomputed tag.
    n = np::encode(np::PKT_INPUT, kNpRoom, 102, 7, 0, 0,
                   nullptr, 0, key, buf, sizeof(buf));
    buf[2] = 99;
    np::Packet ph{};
    memcpy(&ph, buf, np::kHeaderLen);
    np::computeTag(ph, nullptr, 0, key, ph.tag);
    memcpy(buf, &ph, np::kHeaderLen);
    net.debugSendRaw(buf, n);

    // Valid shape, tag bit flipped.
    n = np::encode(np::PKT_INPUT, kNpRoom, 103, 7, 0, 0,
                   nullptr, 0, key, buf, sizeof(buf));
    buf[np::kHeaderLen - 1] ^= 0x80;
    net.debugSendRaw(buf, n);

    // Encoded with a foreign key -> tag mismatch.
    uint8_t wrong[32];
    memcpy(wrong, key, 32);
    wrong[0] ^= 0xFF;
    n = np::encode(np::PKT_INPUT, kNpRoom, 104, 7, 0, 0,
                   nullptr, 0, wrong, buf, sizeof(buf));
    net.debugSendRaw(buf, n);

    // Replays of recently accepted outbound sequence numbers, each sent
    // twice: every copy lands inside the peer's 4096 window on a slot it
    // has already marked, so all four count as RP_DUPLICATE and never
    // touch the input ring. Called after frame 30 has advanced, so the
    // peer has necessarily consumed these packets via the gate.
    uint32_t cur = net.debugNextSeq();
    if (cur < 16) {
        printf("attack: seq space too small (%u), replay checks skipped\n", cur);
    } else {
        for (uint32_t sq : {cur - 8, cur - 8, cur - 9, cur - 9}) {
            n = np::encode(np::PKT_INPUT, kNpRoom, sq, sq, 0, 0,
                           nullptr, 0, key, buf, sizeof(buf));
            net.debugSendRaw(buf, n);
        }
    }
    (void)fixedD;

    // Foreign source: ephemeral port, junk payload.
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    uint8_t junk[5] = {1, 2, 3, 4, 5};
    sendto(fd, junk, sizeof(junk), 0, (sockaddr *)&peer, sizeof(peer));
    close(fd);
    printf("attack: adversarial datagrams injected\n");
    fflush(stdout);
}

void printStats(const np::NetStats &st, bool host) {
    printf("---- %s stats ----\n", host ? "host" : "guest");
    printf("state=%d D=%d frames=%llu effFps=%.2f frozen=%llu late=%llu\n",
           st.state, st.d, (unsigned long long)st.framesAdvanced, st.effFps,
           (unsigned long long)st.frozenFrames,
           (unsigned long long)st.lateFrames);
    printf("rttMs min=%.2f p50=%.2f p95=%.2f p99=%.2f leadMs p50=%.2f p95=%.2f\n",
           st.rttMinMs, st.rttP50Ms, st.rttP95Ms, st.rttP99Ms,
           st.leadP50Ms, st.leadP95Ms);
    printf("packets in=%llu out=%llu bytes in=%llu out=%llu redundant=%llu\n",
           (unsigned long long)st.packetsIn,
           (unsigned long long)st.packetsOut,
           (unsigned long long)st.bytesIn,
           (unsigned long long)st.bytesOut,
           (unsigned long long)st.redundantSends);
    printf("reject badLen=%llu badMagic=%llu badVer=%llu badTag=%llu "
           "replayDup=%llu replayOld=%llu foreign=%llu dUp=%llu dDown=%llu\n",
           (unsigned long long)st.rejBadLen,
           (unsigned long long)st.rejBadMagic,
           (unsigned long long)st.rejBadVersion,
           (unsigned long long)st.rejBadTag,
           (unsigned long long)st.replayDup,
           (unsigned long long)st.replayOld,
           (unsigned long long)st.foreignPackets,
           (unsigned long long)st.dUpgrades,
           (unsigned long long)st.dDowngrades);
    fflush(stdout);
}

int modeLock2(bool host, int argc, char **argv) {
    const char *so = argv[2];
    const char *rom = argv[3];
    const char *peerIp = argv[4];
    uint32_t frames = argc > 5 ? (uint32_t)atoi(argv[5]) : 1800;
    double bhAt = 0, bhDur = 0;
    bool attack = false;
    int fixedD = 0;
    for (int i = 6; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "attack") attack = true;
        else if (a == "d2") fixedD = 2;
        else parseBlackhole(argv[i], bhAt, bhDur);
    }

    Core::saveDir = "/data/local/tmp/gsp/save";
    Core::sysDir = "/data/local/tmp/gsp/system";
    Core c;
    if (!c.open(so, rom)) return 1;

    np::NetConfig cfg;
    cfg.role = host ? np::Role::Host : np::Role::Guest;
    cfg.peerIp = peerIp;
    cfg.peerPort = host ? kNpGuestPort : kNpHostPort;
    cfg.localPort = host ? kNpHostPort : kNpGuestPort;
    npSessionKey(cfg.key.data());
    cfg.roomId = kNpRoom;
    cfg.initialD = fixedD;
    cfg.adaptive = false; // fixed D -> checkpoints land on fixed frame numbers
    cfg.frame0 = 0;
    cfg.framePeriodSec = 1.0 / c.fps;
    cfg.blackholeAtSec = bhAt;
    cfg.blackholeDurSec = bhDur;

    np::GsNetplay net;
    if (!net.start(cfg)) {
        printf("net start failed\n");
        c.close();
        return 1;
    }
    printf("phase1 %s: localPort=%u peer=%s:%u frames=%u D=%d blackhole=%.2f+%.2fs attack=%d\n",
           host ? "host" : "guest", net.localPort(), peerIp,
           host ? kNpGuestPort : kNpHostPort, frames, fixedD,
           bhAt, bhDur, attack ? 1 : 0);
    fflush(stdout);

    sockaddr_in peerAddr{};
    peerAddr.sin_family = AF_INET;
    peerAddr.sin_port = htons(cfg.peerPort);
    inet_pton(AF_INET, peerIp, &peerAddr.sin_addr);

    if (host) {
        net.notifyStart();
    } else {
        // Warm the (often dozing) Wi-Fi link with bidirectional PING/PONG
        // while waiting; the host re-announces START on every PING.
        double giveUp = nowSec() + 20.0;
        double nextPing = nowSec();
        while (!net.stats().started && nowSec() < giveUp) {
            if (nowSec() >= nextPing) { net.ping(); nextPing = nowSec() + 0.2; }
            usleep(20000);
        }
        if (!net.stats().started) {
            printf("guest: no CTRL_START within 20s\n");
            printStats(net.stats(), host);
            net.stop();
            c.close();
            return 3;
        }
        printf("guest: START received\n");
    }
    usleep(200000); // let both sockets settle

    // At fixed D, gate frame K carries solo frame K-D, so the D=0 solo
    // constants appear at f+D.
    const uint64_t expect[4] = {
        0x8ac7176e24fb2e71ull, 0xe3ae80ab916c4325ull,
        0x47e505be2b33aa13ull, 0xf8f8530b38e2e83eull};
    uint64_t got[4] = {0, 0, 0, 0};
    size_t ci = 0;

    const double period = 1.0 / c.fps;
    double anchor = nowSec();
    int rc = 0;
    bool attackFired = false;
    for (uint32_t f = 0; f < frames; ++f) {
        const uint16_t localMask = host ? maskA(f) : maskB(f);

        // Publish this frame's local input BEFORE the gate: at D=0 both
        // sides exchange current-frame masks then run (Phase-0 semantics);
        // at D=2 the redundancy window additionally preloads f-1, f-2.
        net.endFrame(f, localMask);

        np::GateResult gr;
        uint16_t lm = 0, rm = 0;
        for (;;) {
            gr = net.beginFrame(f, lm, rm);
            if (gr == np::GateResult::Ok) break;
            if (gr == np::GateResult::Dead) {
                printf("frame %u: session dead\n", f);
                rc = 3;
                break;
            }
            usleep(100000);
        }
        if (rc) break;

        Core::masks[0] = host ? lm : rm;
        Core::masks[1] = host ? rm : lm;
        Core::masks[2] = Core::masks[3] = 0;

        // Host is the pacemaker; guest follows packet arrival naturally.
        if (host) {
            double deadline = anchor + (f + 1) * period;
            double remain = deadline - nowSec();
            if (remain > 0) usleep((useconds_t)(remain * 1e6));
        }
        c.run();

        // TR-3.3: inject once both sides have advanced ~0.5 s, so the
        // crafted replay seqs are guaranteed already-accepted history.
        if (attack && !attackFired && f + 1 == 30) {
            runAttack(net, peerAddr, fixedD);
            attackFired = true;
        }

        const uint32_t cp[4] = {120, 600, 1200, 1800};
        if (ci < 4 && f + 1 == cp[ci] + (uint32_t)fixedD) {
            uint64_t h = c.hashState();
            got[ci] = h;
            printf("cp f=%u hash=%016llx\n", f + 1, (unsigned long long)h);
            ++ci;
        }
    }

    // The host is the pacemaker; under D>0 the guest's gate only needs the
    // peer's frame K-D, so the non-sleeping guest can finish ~D frames
    // early. It must not tear down (CTRL_BYE parks the host) before the
    // host has run the same number of frames — the shipping app ends
    // sessions through signaling; here just wait out the host's timeline.
    if (!host && rc == 0) usleep(2000000);

    np::NetStats st = net.stats();
    printStats(st, host);

    bool hashOk = (ci == 4);
    for (size_t i = 0; hashOk && i < 4; ++i) hashOk = got[i] == expect[i];
    if (rc == 0 && ci == 4) {
        printf(hashOk ? "LOCKSTEP2: PASS (checkpoints match Phase 0 at D=%d)\n"
                      : "LOCKSTEP2: HASH FAIL\n", fixedD);
        if (!hashOk) rc = 2;
    }
    if (bhDur > 0) {
        // Recovery = frame stream resumed to completion with matching
        // hashes. Ended(4) is normal (peer finished and sent CTRL_BYE);
        // only Dropped(3) is a failed recovery.
        bool recov = st.frozenFrames > 0 &&
                     st.state != (int)np::NetState::Dropped && hashOk &&
                     ci == 4;
        if (recov) {
            printf("BLACKHOLE: PASS (frozen=%llu, recovered, final hash %s, state=%d)\n",
                   (unsigned long long)st.frozenFrames,
                   hashOk ? "matches" : "MISMATCH", st.state);
        } else {
            printf("BLACKHOLE: FAIL (frozen=%llu state=%d hashOk=%d cps=%zu)\n",
                   (unsigned long long)st.frozenFrames, st.state,
                   (int)hashOk, ci);
        }
        if (!recov && rc == 0) rc = 2;
    }
    if (attack) {
        bool sec = st.rejBadLen >= 2 && st.rejBadMagic >= 1 &&
                   st.rejBadVersion >= 1 && st.rejBadTag >= 2 &&
                   st.replayDup >= 2 && st.foreignPackets >= 1;
        printf(sec ? "ATTACK: PASS (all reject counters moved)\n"
                   : "ATTACK: FAIL (counters insufficient)\n");
        if (!sec && rc == 0) rc = 2;
    }

    net.shutdown();
    c.close();
    return rc;
}

// ------------------------------------------------------------- selftest
//
// Exercises the pure netplay logic (no socket, no core):
// SHA-256 / HMAC RFC 4231 vectors, packet codec + tag reject
// branches, anti-replay bitmap window, input ring, adaptive-D rules.

std::string hex(const uint8_t *p, size_t n) {
    static const char *h = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) { s += h[p[i] >> 4]; s += h[p[i] & 15]; }
    return s;
}

int modeSelfTest(int, char **) {
    int pass = 0, fail = 0;
    auto check = [&](const char *name, bool ok) {
        printf("  [%s] %s\n", ok ? "PASS" : "FAIL", name);
        ok ? ++pass : ++fail;
    };

    printf("== sha256 ==\n");
    {
        uint8_t d[32];
        gs_sha256("abc", 3, d);
        check("sha256(\"abc\") fips vector",
              hex(d, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        gs_sha256("", 0, d);
        check("sha256(\"\") fips vector",
              hex(d, 32) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }

    printf("== hmac-sha256 (RFC 4231) ==\n");
    {
        uint8_t d[32];
        std::vector<uint8_t> k1(20, 0x0b);
        gs_hmac_sha256(k1.data(), k1.size(),
                       (const uint8_t *)"Hi There", 8, d);
        check("tc1 key=0b*20 \"Hi There\"",
              hex(d, 32) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
        const char *k2 = "Jefe";
        gs_hmac_sha256((const uint8_t *)k2, 4,
                       (const uint8_t *)"what do ya want for nothing?", 28, d);
        check("tc2 key=\"Jefe\"",
              hex(d, 32) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    printf("== packet codec ==\n");
    {
        std::vector<uint8_t> key;
        for (size_t i = 0; i < np::kKeyLen; ++i) key.push_back((uint8_t)(0xA0 + i));
        uint8_t buf[128];
        long rejects[5] = {0, 0, 0, 0, 0};
        auto vr = [&](const uint8_t *b, size_t n) {
            np::Decoded out;
            np::RejectReason r = np::verify(b, n, key.data(), out);
            if (r != np::REJ_OK) ++rejects[r];
            return r;
        };

        size_t n = np::encode(np::PKT_INPUT, 0x12345678, 100, 120, 0xA5A5, 0,
                              nullptr, 0, key.data(), buf, sizeof(buf));
        check("encode INPUT == 28 bytes", n == np::kHeaderLen);
        check("verify valid INPUT", vr(buf, n) == np::REJ_OK);

        np::Decoded dec;
        check("decoded fields roundtrip",
              np::verify(buf, n, key.data(), dec) == np::REJ_OK &&
              dec.hdr.room == 0x12345678 && dec.hdr.seq == 100 &&
              dec.hdr.frame == 120 && dec.hdr.mask == 0xA5A5 &&
              dec.payload.empty());

        uint8_t bad[128];
        memcpy(bad, buf, n);
        bad[10] ^= 0x01; // flip a header byte
        check("flipped header byte -> badTag", vr(bad, n) == np::REJ_BAD_TAG);
        check("truncated 27 bytes -> badLen", vr(buf, n - 1) == np::REJ_BAD_LEN);

        memcpy(bad, buf, n);
        bad[2] = 99; // wrong proto version, tag recomputed below
        np::Packet ph{};
        memcpy(&ph, bad, sizeof(ph));
        np::computeTag(ph, nullptr, 0, key.data(), ph.tag);
        memcpy(bad, &ph, np::kHeaderLen);
        check("wrong version -> badVersion", vr(bad, n) == np::REJ_BAD_VERSION);

        memcpy(bad, buf, n);
        bad[0] = 0x00; // break magic
        check("wrong magic -> badMagic", vr(bad, n) == np::REJ_BAD_MAGIC);

        // CTRL with 8-byte timestamp payload.
        uint8_t pl[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        size_t cn = np::encode(np::PKT_CTRL, 42, 7, 0, 0, np::CTRL_PING,
                              pl, sizeof(pl), key.data(), buf, sizeof(buf));
        check("encode CTRL == 36 bytes", cn == 36);
        np::Decoded cd;
        check("verify+payload CTRL",
              np::verify(buf, cn, key.data(), cd) == np::REJ_OK &&
              cd.payload.size() == 8 && memcmp(cd.payload.data(), pl, 8) == 0 &&
              cd.hdr.flags == np::CTRL_PING);
        memcpy(bad, buf, cn);
        bad[np::kHeaderLen + 3] ^= 0x80; // tamper payload
        check("tampered payload -> badTag", vr(bad, cn) == np::REJ_BAD_TAG);

        // INPUT must never carry payload.
        check("INPUT with payload rejected by encoder",
              np::encode(np::PKT_INPUT, 1, 1, 1, 0, 0, pl, 8,
                        key.data(), buf, sizeof(buf)) == 0);

        printf("  codec rejects: badLen=%ld badMagic=%ld badVersion=%ld badTag=%ld\n",
               rejects[np::REJ_BAD_LEN], rejects[np::REJ_BAD_MAGIC],
               rejects[np::REJ_BAD_VERSION], rejects[np::REJ_BAD_TAG]);
        check("all four reject branches hit",
              rejects[np::REJ_BAD_LEN] == 1 && rejects[np::REJ_BAD_MAGIC] == 1 &&
              rejects[np::REJ_BAD_VERSION] == 1 && rejects[np::REJ_BAD_TAG] == 2);
    }

    printf("== batched INPUT ==\n");
    {
        std::vector<uint8_t> key;
        for (size_t i = 0; i < np::kKeyLen; ++i) key.push_back((uint8_t)(0xA0 + i));
        uint8_t buf[256];
        const uint16_t masks[4] = {0x0010, 0x0020, 0x0040, 0x0080};

        size_t n = np::encodeInputBatch(0x77, 200, 300, masks, 4,
                                        key.data(), buf, sizeof(buf));
        check("encode batch count=4 -> 37 bytes", n == 37);
        np::Decoded dec;
        check("verify batch", np::verify(buf, n, key.data(), dec) == np::REJ_OK);
        check("batch header frame/mask",
              dec.hdr.frame == 300 && dec.hdr.mask == 0x0010 &&
              dec.payload.size() == 9 && dec.payload[0] == 4);
        bool pairs = true;
        for (int i = 0; i < 4; ++i) {
            uint16_t m = (uint16_t)(dec.payload[1 + 2 * i] |
                                    (dec.payload[2 + 2 * i] << 8));
            if (m != masks[i]) pairs = false;
        }
        check("batch masks newest->oldest", pairs);

        // count=0 and count=65 shapes are illegal; length must match 1+2c.
        size_t cnt = 999;
        check("shape single", np::inputBatchShape(0, 0, cnt) && cnt == 0);
        check("shape count4 valid", np::inputBatchShape(9, 4, cnt) && cnt == 4);
        check("shape count0 rejected", !np::inputBatchShape(1, 0, cnt));
        check("shape count65 rejected", !np::inputBatchShape(1, 65, cnt));
        check("shape truncated rejected", !np::inputBatchShape(8, 4, cnt));

        uint8_t bad[256];
        memcpy(bad, buf, n);
        bad[np::kHeaderLen] = 99; // claim 99 frames, length unchanged
        np::Decoded tmp;
        check("batch lying count -> badLen",
              np::verify(bad, n, key.data(), tmp) == np::REJ_BAD_LEN);
        check("batch one byte short -> badLen",
              np::verify(buf, n - 1, key.data(), tmp) == np::REJ_BAD_LEN);

        memcpy(bad, buf, n);
        bad[np::kHeaderLen + 1] ^= 0xFF; // flip a mask byte
        check("tampered batch mask -> badTag",
              np::verify(bad, n, key.data(), tmp) == np::REJ_BAD_TAG);

        const uint16_t big[np::kInputBatchMax] = {0};
        check("max-size batch encodes (64 frames)",
              np::encodeInputBatch(1, 1, 1000, big, np::kInputBatchMax,
                                   key.data(), buf, sizeof(buf)) ==
                  np::kHeaderLen + 1 + 2 * np::kInputBatchMax);
        check("oversize batch refused",
              np::encodeInputBatch(1, 1, 1000, big, np::kInputBatchMax + 1,
                                   key.data(), buf, sizeof(buf)) == 0);
    }

    printf("== anti-replay window ==\n");
    {
        np::ReplayWindow w(4096);
        check("first packet accepted", w.examine(1) == np::RP_ACCEPT);
        check("in-order accepted", w.examine(2) == np::RP_ACCEPT &&
                                  w.examine(3) == np::RP_ACCEPT);
        check("duplicate rejected", w.examine(2) == np::RP_DUPLICATE);
        check("forward jump accepted", w.examine(4096) == np::RP_ACCEPT);
        check("seq0 behind window -> old", w.examine(0) == np::RP_OLD);
        check("seq1 still inside window -> duplicate",
              w.examine(1) == np::RP_DUPLICATE);
        check("seq4097 accepted", w.examine(4097) == np::RP_ACCEPT);
        check("seq1 now behind window -> old", w.examine(1) == np::RP_OLD);

        np::ReplayWindow r(64);
        r.examine(10); r.examine(12);
        check("gap fill accepted", r.examine(11) == np::RP_ACCEPT);
        check("gap fill then duplicate", r.examine(12) == np::RP_DUPLICATE);
        printf("  replay counters: accepted=%llu dup=%llu old=%llu\n",
               (unsigned long long)w.accepted(),
               (unsigned long long)w.duplicates(),
               (unsigned long long)w.expired());
    }

    printf("== input ring ==\n");
    {
        np::InputRing ring(64);
        ring.put(100, 0x0001);
        ring.put(101, 0x0002);
        ring.put(103, 0x0008);
        uint16_t m = 0;
        check("present get", ring.get(103, m) && m == 0x0008);
        check("gap absent", !ring.has(102));
        check("contiguous stops at gap", ring.contiguous(100) == 2);
        ring.put(102, 0x0004);
        check("gap filled -> contiguous 4", ring.contiguous(100) == 4);
        ring.put(164, 0x0010); // same slot as frame 100 in a 64-ring
        check("wrapped slot evicts old frame", !ring.has(100) && ring.get(164, m) && m == 0x0010);
        ring.put(164, 0x0020);
        check("same frame overwrite", ring.get(164, m) && m == 0x0020);
    }

    printf("== adaptive delay ==\n");
    {
        const double p = 1.0 / 59.61;
        np::DelayCtrl dc(1, 2, p);
        dc.reset(1, 0.0);
        bool changed = dc.onFrame(-0.001, p);
        check("late frame at D=1 immediately raises D", changed && dc.d() == 2 &&
                                                    dc.upgrades() == 1);
        for (int i = 1; i <= 130; ++i) {
            dc.onFrame(0.030, (i + 1) * p);
        }
        check("2s comfortably early -> downgrade to D=1",
              dc.d() == 1 && dc.downgrades() == 1);

        np::DelayCtrl dc2(1, 2, p);
        dc2.reset(2, 0.0);
        for (int i = 0; i < 5; ++i) dc2.onFrame(-0.001, (i + 1) * p);
        check("D=2 cannot upgrade past max", dc2.d() == 2 && dc2.upgrades() == 0 &&
                                               dc2.lateFrames() == 5);

        np::DelayCtrl dc3(1, 2, p);
        dc3.reset(2, 0.0);
        for (int i = 0; i < 130; ++i) {
            // Only 10ms early: below the 1.5-frame downgrade margin.
            dc3.onFrame(0.010, (i + 1) * p);
        }
        check("marginal lead does not downgrade", dc3.d() == 2);
    }

    printf("SELFTEST: %d passed, %d failed\n", pass, fail);
    return fail == 0 ? 0 : 2;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        printf("usage: gs_probe pong|ping|blast|det|lhost|lguest|lhost2|lguest2|selftest ...\n");
        return 1;
    }
    std::string mode = argv[1];
    if (mode == "pong") return modePong(argc, argv);
    if (mode == "ping") return modePing(argc, argv);
    if (mode == "blast") return modeBlast(argc, argv);
    if (mode == "det") return modeDet(argc, argv);
    if (mode == "lhost") return modeLockHost(argc, argv);
    if (mode == "lguest") return modeLockGuest(argc, argv);
    if (mode == "lhost2") return modeLock2(true, argc, argv);
    if (mode == "lguest2") return modeLock2(false, argc, argv);
    if (mode == "selftest") return modeSelfTest(argc, argv);
    printf("unknown mode %s\n", mode.c_str());
    return 1;
}
