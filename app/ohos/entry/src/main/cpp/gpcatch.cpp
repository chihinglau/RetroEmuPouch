// On-device native crash capture for the OHOS build.
//
// Why this exists: the Pura70 test device is not rooted, so the platform fault
// log (`/data/log/faultlog/faultlogger/*`) is unreadable (`Permission denied`)
// and the `hdc shell hilog` ring buffer is flooded by system services and rolls
// over within minutes -- by the time a SIGSEGV shows up in the app it is often
// already gone, and even when it is there hilog only carries the signal name,
// not a stack.
//
// So the frontend installs its own fatal-signal handler that appends a
// symbolized backtrace to `<filesDir>/crash_native.txt`, which IS readable from
// the host with
//   hdc shell -b com.retroemupouch.app cat <filesDir>/crash_native.txt
// After writing it restores the default disposition and re-raises, so the
// process still dies exactly like before (no behaviour change for the system).
//
// Only open/write/close/dladdr/_Unwind_Backtrace are used inside the handler:
// no malloc, no stdio, no logging.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <csignal>
#include <initializer_list>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <unwind.h>
#include <sys/syscall.h>

namespace {

char g_crashPath[512] = {0};
volatile sig_atomic_t g_inHandler = 0;
char g_altStack[64 * 1024];

void WriteAll(int fd, const char* s) {
  if (s == nullptr) return;
  size_t n = ::strlen(s);
  while (n > 0) {
    ssize_t w = ::write(fd, s, n);
    if (w <= 0) break;
    s += (size_t)w;
    n -= (size_t)w;
  }
}

void WriteU64(int fd, uint64_t v) {
  char t[24];
  int n = 0;
  if (v == 0) t[n++] = '0';
  while (v > 0 && n < 24) {
    t[n++] = (char)('0' + (int)(v % 10));
    v /= 10;
  }
  while (n > 0) {
    n--;
    if (::write(fd, t + n, 1) != 1) return;
  }
}

void WriteHex(int fd, uint64_t v) {
  char t[20];
  int n = 0;
  if (v == 0) t[n++] = '0';
  while (v > 0 && n < 20) {
    int d = (int)(v & 0xf);
    t[n++] = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
    v >>= 4;
  }
  if (::write(fd, "0x", 2) != 2) return;
  while (n > 0) {
    n--;
    if (::write(fd, t + n, 1) != 1) return;
  }
}

struct BtState {
  void* pc[64];
  int n;
};

_Unwind_Reason_Code BtCallback(_Unwind_Context* ctx, void* arg) {
  BtState* st = static_cast<BtState*>(arg);
  uintptr_t ip = (uintptr_t)_Unwind_GetIP(ctx);
  if (ip == 0) return _URC_NO_REASON;
  if (st->n < 64) st->pc[st->n++] = (void*)ip;
  return st->n < 64 ? _URC_NO_REASON : _URC_END_OF_STACK;
}

const char* SignalName(int sig) {
  switch (sig) {
    case SIGSEGV: return "SIGSEGV";
    case SIGABRT: return "SIGABRT";
    case SIGBUS: return "SIGBUS";
    case SIGFPE: return "SIGFPE";
    case SIGILL: return "SIGILL";
    case SIGSYS: return "SIGSYS";
    default: return "SIGNAL";
  }
}

void CrashHandler(int sig, siginfo_t* info, void* /*uc*/) {
  if (g_inHandler) {
    // Nested fault (e.g. the handler itself crashed): give up immediately.
    ::_exit(128 + sig);
  }
  g_inHandler = 1;
  int fd = ::open(g_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (fd >= 0) {
    WriteAll(fd, "\n=== native crash ===\n");
    WriteAll(fd, "signal=");
    WriteAll(fd, SignalName(sig));
    WriteAll(fd, "(");
    WriteU64(fd, (uint64_t)sig);
    WriteAll(fd, ") faultAddr=");
    WriteHex(fd, (uint64_t)(info != nullptr ? (uintptr_t)info->si_addr : (uintptr_t)0));
    WriteAll(fd, " pid=");
    WriteU64(fd, (uint64_t)::getpid());
    WriteAll(fd, " tid=");
    WriteU64(fd, (uint64_t)::syscall(SYS_gettid));
    WriteAll(fd, "\nbacktrace:\n");

    BtState st{};
    _Unwind_Backtrace(BtCallback, &st);
    for (int i = 0; i < st.n; i++) {
      WriteAll(fd, "#");
      WriteU64(fd, (uint64_t)i);
      WriteAll(fd, " ");
      WriteHex(fd, (uint64_t)st.pc[i]);
      Dl_info di{};
      if (::dladdr(st.pc[i], &di) != 0 && di.dli_fname != nullptr) {
        WriteAll(fd, " ");
        WriteAll(fd, di.dli_fname);
        WriteAll(fd, "+");
        WriteHex(fd, (uint64_t)((const char*)st.pc[i] - (const char*)di.dli_fbase));
        if (di.dli_sname != nullptr) {
          WriteAll(fd, " ");
          WriteAll(fd, di.dli_sname);
        }
      }
      WriteAll(fd, "\n");
    }
    WriteAll(fd, "=== end ===\n");
    ::close(fd);
  }
  // SA_RESETHAND already restored SIG_DFL; re-raise so the process dies with the
  // original signal (crash reporting / appspawn behaviour stays unchanged).
  ::raise(sig);
}

}  // namespace

// Called once the app-private files dir is known (see SetEmulatorTarget).
extern "C" void GPCatchInstall(const char* appDir) {
  if (appDir == nullptr || appDir[0] == '\0') return;
  if (g_crashPath[0] != '\0') return;  // already installed
  int n = ::snprintf(g_crashPath, sizeof(g_crashPath), "%s/crash_native.txt", appDir);
  if (n <= 0 || (size_t)n >= sizeof(g_crashPath)) {
    g_crashPath[0] = '\0';
    return;
  }
  stack_t ss{};
  ss.ss_sp = g_altStack;
  ss.ss_size = sizeof(g_altStack);
  ss.ss_flags = 0;
  (void)::sigaltstack(&ss, nullptr);

  struct sigaction sa{};
  sa.sa_sigaction = CrashHandler;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
  ::sigemptyset(&sa.sa_mask);
  for (int sig : {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL}) {
    (void)::sigaction(sig, &sa, nullptr);
  }
}
