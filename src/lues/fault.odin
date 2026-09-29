package lues

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"
import "core:time"

// A fault or hang in plugin code unwinds back to dispatch, but only when the pc is inside that
// plugin's .so or an object it adopted (guard 1) and no api call is in progress (guard 2). Anything else dies.
// armed and busy are atomic so the optimiser cannot fold them; the guard is per thread
// because the jump must land on the stack that faulted.

foreign import libc_ "system:c"

@(default_calling_convention = "c")
foreign libc_ {
    // glibc's sigsetjmp is a macro over this.
    @(link_name = "__sigsetjmp")
    sigsetjmp :: proc(env: ^Jmp_Buf, savemask: c.int) -> c.int ---
    siglongjmp :: proc(env: ^Jmp_Buf, val: c.int) -> ! ---
    dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> c.int ---
    // The _fd variant: backtrace_symbols mallocs.
    backtrace :: proc(buf: [^]rawptr, size: c.int) -> c.int ---
    backtrace_symbols_fd :: proc(buf: [^]rawptr, size: c.int, fd: posix.FD) ---
    abort :: proc() -> ! ---
    gnu_get_libc_version :: proc() -> cstring ---
}

// glibc's is 200 bytes.
Jmp_Buf :: struct #align(16) {
    _: [512]u8,
}

Dl_Info :: struct {
    dli_fname: cstring,
    dli_fbase: rawptr,
    dli_sname: cstring,
    dli_saddr: rawptr,
}

FAULT_SIGNALS :: [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE}

PLUG_HANG_MS :: 5000

@(private = "file")
Guard :: struct {
    env:      Jmp_Buf,
    ctx:      runtime.Context, // the arming frame's, so recovery can allocate
    app:      ^Kernel,
    who:      int,
    base:     uintptr,
    // The plugin's adopted objects, copied at arm time: the handler cannot follow its array.
    objects:  [FAULT_OBJECTS]uintptr,
    nobjects: int,
    why:      string, // a literal, or fail's copy in `said`
    // The plugin's name plus a newline, copied at arm time: the handler cannot allocate.
    name:     [NAME_MAX]u8,
    n:        int,
    said:     [SAID_MAX]u8,
    traced:   bool,
    armed:    bool, // atomic
    busy:     bool, // atomic; inside an api call
}

// Adopted objects per plugin; past this, adopt refuses.
FAULT_OBJECTS :: 64

// A longer name is truncated and quarantines nobody.
@(private = "file")
NAME_MAX :: 64

// fail's message past this is cut.
@(private = "file")
SAID_MAX :: 256

@(private = "file", thread_local)
g_guard: Guard

// Static: the handler's stack must not depend on the allocator.
@(private = "file", thread_local)
g_alt: [64 * 1024]u8

@(private = "file")
g_installed: bool

// --- install ---

// (hole rs-fault-handlers :tags (port fault) :sev missing-port :needs (rs-dispatch-trampoline pkey-tagging)) not ported; a Rust host must also install after std and take over its stack-overflow SIGSEGV handler.
// Handlers are per process, the alt stack per thread, so a second caller only adds its stack.
fault_install :: proc() -> bool {
    // Keep an existing alt stack: ASan unmaps its own at thread exit.
    old: posix.stack_t
    if posix.sigaltstack(nil, &old) != .OK || .DISABLE in old.ss_flags {
        ss := posix.stack_t {
            ss_sp   = &g_alt[0],
            ss_size = len(g_alt),
        }
        if posix.sigaltstack(&ss, nil) != .OK {
            return false
        }
    }
    if g_installed {
        return true
    }
    act: posix.sigaction_t
    act.sa_sigaction = fault_handler
    act.sa_flags = {.SIGINFO, .ONSTACK}
    posix.sigemptyset(&act.sa_mask)
    for sig in FAULT_SIGNALS {
        if posix.sigaction(sig, &act, nil) != .OK {
            return false
        }
    }
    // The first backtrace dlopens the unwinder and mallocs; do it here, not in the handler.
    warm: [1]rawptr
    backtrace(raw_data(warm[:]), 1)
    g_installed = true
    return true
}

fault_ready :: proc() -> bool {
    return g_installed
}

fault_object_base :: proc(addr: rawptr) -> uintptr {
    info: Dl_Info
    if addr == nil || dladdr(addr, &info) == 0 {
        return 0
    }
    return uintptr(info.dli_fbase)
}

// This object and libc, which no plugin may adopt. libc is placed by a string it returns: the
// address of one of its functions may be a PLT stub in the executable.
fault_kernel_object :: proc(base: uintptr) -> bool {
    return base == fault_object_base(rawptr(fault_install)) ||
           base == fault_object_base(rawptr(gnu_get_libc_version()))
}

// --- arming, and coming back ---

fault_armed :: proc() -> bool {
    return intrinsics.atomic_load(&g_guard.armed)
}

fault_env :: proc() -> ^Jmp_Buf {
    return &g_guard.env
}

// Call after the sigsetjmp that fills the buffer.
fault_arm :: proc(a: ^Kernel, i: int) {
    p := &a.plugs[i]
    g := &g_guard
    g.ctx, g.app, g.who, g.base, g.why, g.traced = context, a, i, p.base, "", false
    g.nobjects = copy(g.objects[:], p.objects[:])
    name := p.name
    g.n = min(len(name), NAME_MAX - 1)
    copy(g.name[:g.n], name[:g.n])
    g.name[g.n] = '\n'
    g.n += 1
    intrinsics.atomic_store(&g.busy, false)
    intrinsics.atomic_store(&g.armed, true)
    watch_arm()
}

// An object adopted during the call counts at once, not from the next dispatch.
fault_adopt :: proc(i: int, base: uintptr) {
    g := &g_guard
    if intrinsics.atomic_load(&g.armed) && g.who == i && g.nobjects < FAULT_OBJECTS {
        g.objects[g.nobjects] = base
        g.nobjects += 1
    }
}

fault_disarm :: proc() {
    intrinsics.atomic_store(&g_guard.armed, false)
    watch_clear()
}

// Guard 2: a fault while busy is not unwound.
// (hole pkey-tagging :tags (memory fault) :sev missing-system :needs (kernel-arenas)) kernel memory stays writable during plugin code; a stray plugin write corrupts it without a fault.
fault_busy :: proc "contextless" (on: bool) {
    intrinsics.atomic_store(&g_guard.busy, on)
}

// The api's fail: the same jump as a fault, taken on purpose, so no guard 1. It can't jump
// with no net armed on this thread, or from inside an api call (a nested dispatch): it dies
// and `name` is quarantined. The message is the plugin's memory, so it is copied while busy.
fault_fail :: proc "contextless" (name, msg: string) -> ! {
    g := &g_guard
    armed := intrinsics.atomic_load(&g.armed)
    if !armed || intrinsics.atomic_load(&g.busy) {
        if !armed {
            g.n = min(len(name), NAME_MAX - 1)
            copy(g.name[:g.n], name[:g.n])
            g.name[g.n] = '\n'
            g.n += 1
        }
        g.traced = trace_write(0, "failed")
        die(.SIGABRT, blame = g.n > 1)
        abort()
    }
    intrinsics.atomic_store(&g.busy, true)
    n := copy(g.said[:], "failed")
    if len(msg) > 0 {
        n += copy(g.said[n:], ": ")
        n += copy(g.said[n:], msg)
    }
    intrinsics.atomic_store(&g.busy, false)
    why := string(g.said[:n])
    g.traced = trace_write(0, why)
    unwind(why)
}

// Reads only the guard: the jump does not restore the arming frame's locals.
fault_reap :: proc "contextless" () {
    context = g_guard.ctx
    loader_faulted(g_guard.app, g_guard.who, g_guard.why, g_guard.traced)
}

// --- the handlers ---
//
// Async-signal-safe: no allocation, no lock, no fmt. dladdr is the one exception.

@(private = "file")
fault_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    pc := fault_ip(uc)
    g_guard.traced = trace_write(pc, signal_name(sig))
    // Inside an api call the plugin's call caused it, wherever the pc is: quarantined, so the
    // next start does not load it into the same crash.
    if intrinsics.atomic_load(&g_guard.armed) && intrinsics.atomic_load(&g_guard.busy) {
        die(sig, blame = true)
        return
    }
    if !in_plugin(pc) {
        die(sig, blame = false)
        return
    }
    unwind(signal_name(sig))
}

@(private = "file")
hang_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    if !intrinsics.atomic_load(&g_guard.armed) {
        return // stale: the dispatch came back
    }
    if intrinsics.atomic_load(&g_watch_until) != 0 {
        return // stale: a newer dispatch armed while the alarm was in flight
    }
    g_guard.traced = trace_write(fault_ip(uc), "stopped returning")
    if intrinsics.atomic_load(&g_guard.busy) {
        die(.SIGABRT, blame = true)
        return
    }
    unwind("stopped returning")
}

@(private = "file")
unwind :: proc "contextless" (why: string) -> ! {
    g_guard.why = why
    intrinsics.atomic_store(&g_guard.armed, false)
    watch_clear()
    siglongjmp(&g_guard.env, 1)
}

// Guard 1: who is to blame. Guard 2 decides whether it can be unwound.
@(private = "file")
in_plugin :: proc "contextless" (pc: uintptr) -> bool {
    g := &g_guard
    if !intrinsics.atomic_load(&g.armed) {
        return false
    }
    info: Dl_Info
    if pc == 0 || g.base == 0 || dladdr(rawptr(pc), &info) == 0 {
        return false
    }
    base := uintptr(info.dli_fbase)
    if base == g.base {
        return true
    }
    for o in g.objects[:g.nobjects] {
        if base == o {
            return true
        }
    }
    return false
}

// Syncs the app's fds and names the plugin to blame, then re-raises with the default action.
@(private = "file")
die :: proc "contextless" (sig: posix.Signal, blame: bool) {
    for &fd in g_syncs {
        if v := intrinsics.atomic_load(&fd); v != 0 {
            posix.fsync(posix.FD(v))
        }
    }
    if report := intrinsics.atomic_load(&g_report); blame && report != 0 {
        posix.write(posix.FD(report), &g_guard.name[0], uint(g_guard.n))
    }
    posix.signal(sig, auto_cast posix.SIG_DFL)
    posix.kill(posix.getpid(), sig)
}

// --- what the handler leaves behind: fds opened while the process was healthy ---

@(private = "file")
SYNC_FDS :: 32

@(private = "file")
g_syncs: [SYNC_FDS]i32 // 0 is an empty slot

@(private = "file")
g_report: i32 // the quarantine file; 0 for none

// An app fd the handler fsyncs before it dies. Past the table it is not synced.
fault_sync_add :: proc(fd: uintptr) {
    for &slot in g_syncs {
        if intrinsics.atomic_load(&slot) == 0 {
            intrinsics.atomic_store(&slot, i32(fd))
            return
        }
    }
}

fault_sync_drop :: proc(fd: uintptr) {
    for &slot in g_syncs {
        if intrinsics.atomic_load(&slot) == i32(fd) {
            intrinsics.atomic_store(&slot, 0)
            return
        }
    }
}

fault_report_fd :: proc(fd: uintptr) {
    intrinsics.atomic_store(&g_report, i32(fd))
}

// --- the trace ---
//
// The handler walks the stack before it unwinds and writes one `addr2line` line per object,
// then glibc's frame list. Caller offsets are return addresses, one line past the call.

FAULTS_FILE :: "faults" // in the state directory

@(private = "file")
TRACE_MAX :: 64

@(private = "file")
Object :: struct {
    base: uintptr, // 0 when dladdr could not place the frame
    path: cstring,
}

@(private = "file", thread_local)
g_pcs: [TRACE_MAX]rawptr
@(private = "file", thread_local)
g_objs: [TRACE_MAX]Object

@(private = "file")
g_trace: i32 // the faults file; 0 for none

// Append-only: repeated crashes keep their history.
fault_trace_open :: proc(a: ^Kernel) {
    path := fault_trace_path(a)
    if path == "" || a.traces != nil {
        return
    }
    f, err := os.open(path, {.Write, .Create, .Append}, {.Read_User, .Write_User})
    if err != nil {
        return
    }
    a.traces = f
    intrinsics.atomic_store(&g_trace, i32(os.fd(f)))
}

fault_trace_close :: proc(a: ^Kernel) {
    if a.traces == nil {
        return
    }
    intrinsics.atomic_store(&g_trace, 0)
    os.close(a.traces)
    a.traces = nil
}

// Temp-allocated; empty with no state dir.
fault_trace_path :: proc(a: ^Kernel) -> string {
    if a.home.state == "" {
        return ""
    }
    path, _ := filepath.join({a.home.state, FAULTS_FILE}, context.temp_allocator)
    return path
}

@(private = "file")
trace_write :: proc "contextless" (pc: uintptr, why: string) -> bool {
    fd := posix.FD(intrinsics.atomic_load(&g_trace))
    if fd == 0 {
        return false
    }
    n := walk(pc)
    put_header(fd, why)
    // The plugin's object first: the walk starts in kernel frames.
    plug := g_guard.base if intrinsics.atomic_load(&g_guard.armed) else 0
    put_object(fd, n, plug)
    for i in 0 ..< n {
        if g_objs[i].base != 0 && g_objs[i].base != plug && !seen(i) {
            put_object(fd, n, g_objs[i].base)
        }
    }
    backtrace_symbols_fd(raw_data(g_pcs[:]), c.int(n), fd)
    return true
}

// A plugin without unwind tables stops the walk short, so the pc is added when it was missed.
@(private = "file")
walk :: proc "contextless" (pc: uintptr) -> int {
    n := int(backtrace(raw_data(g_pcs[:]), TRACE_MAX))
    walked := false
    for i in 0 ..< n {
        walked ||= uintptr(g_pcs[i]) == pc
    }
    if !walked && pc != 0 && n < TRACE_MAX {
        copy(g_pcs[1:], g_pcs[:n]) // overlapping; copy is a memmove
        g_pcs[0] = rawptr(pc)
        n += 1
    }
    for i in 0 ..< n {
        info: Dl_Info
        g_objs[i] = {}
        if g_pcs[i] != nil && dladdr(g_pcs[i], &info) != 0 {
            g_objs[i] = {uintptr(info.dli_fbase), info.dli_fname}
        }
    }
    return n
}

// Drops the newline fault_arm put after the name.
@(private = "file")
put_header :: proc "contextless" (fd: posix.FD, why: string) {
    put(fd, "\n--- ")
    if intrinsics.atomic_load(&g_guard.armed) && g_guard.n > 1 {
        posix.write(fd, &g_guard.name[0], uint(g_guard.n - 1))
    } else {
        put(fd, "kernel")
    }
    put(fd, " ")
    put(fd, why)
    put(fd, "\n")
}

// addr2line takes one -e, so each object gets its own line.
@(private = "file")
put_object :: proc "contextless" (fd: posix.FD, n: int, base: uintptr) {
    if base == 0 {
        return
    }
    named := false
    for i in 0 ..< n {
        if g_objs[i].base != base {
            continue
        }
        if !named {
            put(fd, "addr2line -e ")
            if path := plugin_path(base); path != "" {
                put(fd, path)
            } else {
                put_c(fd, g_objs[i].path)
            }
            named = true
        }
        put(fd, " 0x")
        put_hex(fd, uintptr(g_pcs[i]) - base)
    }
    if named {
        put(fd, "\n")
    }
}

// A plugin is mapped from a memfd, so dladdr names a /proc/self/fd path closed long ago: this
// is the file it was copied from. Wrong offsets if that file was rebuilt since the load.
@(private = "file")
plugin_path :: proc "contextless" (base: uintptr) -> string {
    g := &g_guard
    if !intrinsics.atomic_load(&g.armed) || g.app == nil {
        return "" // no kernel to ask
    }
    for p in g.app.plugs {
        if p.state == .Live && p.base == base {
            return p.path
        }
    }
    return ""
}

@(private = "file")
seen :: proc "contextless" (i: int) -> bool {
    for j in 0 ..< i {
        if g_objs[j].base == g_objs[i].base {
            return true
        }
    }
    return false
}

@(private = "file")
put :: proc "contextless" (fd: posix.FD, s: string) {
    posix.write(fd, raw_data(s), uint(len(s)))
}

// By hand: len(cstring) is a runtime call.
@(private = "file")
put_c :: proc "contextless" (fd: posix.FD, s: cstring) {
    if s == nil {
        return
    }
    p := ([^]u8)(rawptr(s))
    n := 0
    for p[n] != 0 {
        n += 1
    }
    posix.write(fd, p, uint(n))
}

@(private = "file")
put_hex :: proc "contextless" (fd: posix.FD, v: uintptr) {
    hex := "0123456789abcdef"
    buf: [16]u8
    i, left := len(buf), v
    for {
        i -= 1
        buf[i] = hex[left & 0xf]
        left >>= 4
        if left == 0 || i == 0 {
            break
        }
    }
    put(fd, string(buf[i:]))
}

@(private = "file")
signal_name :: proc "contextless" (sig: posix.Signal) -> string {
    #partial switch sig {
    case .SIGSEGV:
        return "faulted (SIGSEGV)"
    case .SIGBUS:
        return "faulted (SIGBUS)"
    case .SIGILL:
        return "faulted (SIGILL)"
    case .SIGFPE:
        return "faulted (SIGFPE)"
    }
    return "faulted"
}

// Odin declares no ucontext_t; only the amd64 register block is read.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
    @(private = "file")
    Uc_Stack :: struct {
        ss_sp:    rawptr,
        ss_flags: i32,
        _pad:     i32,
        ss_size:  uint,
    }

    @(private = "file")
    Ucontext :: struct {
        uc_flags: u64,
        uc_link:  rawptr,
        uc_stack: Uc_Stack,
        gregs:    [23]u64,
    }

    @(private = "file")
    REG_RIP :: 16
    #assert(offset_of(Ucontext, gregs) == 40)

    @(private = "file")
    fault_ip :: proc "contextless" (uc: rawptr) -> uintptr {
        return uc == nil ? 0 : uintptr((^Ucontext)(uc).gregs[REG_RIP])
    }
} else {
    // No pc: guard 1 never passes, so every fault dies.
    @(private = "file")
    fault_ip :: proc "contextless" (uc: rawptr) -> uintptr {
        return 0
    }
}

// --- the watchdog ---

@(private = "file")
g_watch_on: bool // a deadline is kept
@(private = "file")
g_watch_live: bool // the watcher thread exists; it never stops
@(private = "file")
g_watch_main: posix.pthread_t
@(private = "file")
g_watch_ms: i64
@(private = "file")
g_watch_tick: time.Duration
@(private = "file")
g_watch_until: i64 // monotonic ns; 0 while no plugin is on the stack

// Watches only the calling thread, which must be the one that dispatches.
fault_watchdog_start :: proc(ms := PLUG_HANG_MS) {
    if g_watch_on || !g_installed {
        return
    }
    act: posix.sigaction_t
    act.sa_sigaction = hang_handler
    act.sa_flags = {.SIGINFO, .ONSTACK}
    posix.sigemptyset(&act.sa_mask)
    if posix.sigaction(.SIGALRM, &act, nil) != .OK {
        return
    }
    g_watch_ms = i64(ms)
    g_watch_tick = time.Duration(clamp(i64(ms) / 4, 10, 200)) * time.Millisecond
    g_watch_main = posix.pthread_self()
    g_watch_on = true
    if g_watch_live {
        return
    }
    // A raw pthread: it never returns, so a core:thread object would never be freed.
    tid: posix.pthread_t
    if posix.pthread_create(&tid, nil, watchdog, nil) != nil {
        g_watch_on = false
        return
    }
    posix.pthread_detach(tid)
    g_watch_live = true
}

// The watcher thread stays; only the deadline stops.
fault_watchdog_stop :: proc() {
    watch_clear()
    g_watch_on = false
}

@(private = "file")
watchdog :: proc "c" (arg: rawptr) -> rawptr {
    context = runtime.default_context()
    for {
        time.sleep(g_watch_tick)
        until := intrinsics.atomic_load(&g_watch_until)
        if until == 0 || time.tick_now()._nsec <= until {
            continue
        }
        // Cleared first: a second alarm would land on a stack being left.
        intrinsics.atomic_store(&g_watch_until, 0)
        // Thread-directed: kill() could deliver it to any thread.
        posix.pthread_kill(g_watch_main, .SIGALRM)
    }
}

@(private = "file")
watch_arm :: proc() {
    if watching() {
        intrinsics.atomic_store(&g_watch_until, time.tick_now()._nsec + g_watch_ms * 1e6)
    }
}

@(private = "file")
watch_clear :: proc "contextless" () {
    if watching() {
        intrinsics.atomic_store(&g_watch_until, 0)
    }
}

// Only the watched thread may set or clear the deadline.
@(private = "file")
watching :: proc "contextless" () -> bool {
    return g_watch_on && posix.pthread_equal(posix.pthread_self(), g_watch_main)
}
