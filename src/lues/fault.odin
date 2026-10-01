package lues

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"
import "core:time"

// A fault or hang in plugin code unwinds back to dispatch, but only when the pc is inside that
// plugin's .so or an object it adopted (guard 1) and no api call is in progress (guard 2).
// Anything else dies. Each dispatch pushes a frame, so a plugin's api call that dispatches to
// another plugin nests, and the guards judge the plugin running at the top. depth and busy are
// atomic so the optimiser cannot fold them; the guard is per thread because the jump must land
// on the stack that faulted.

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
    __libc_current_sigrtmax :: proc() -> c.int ---
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

FAULT_SIGNALS :: [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT}

PLUG_HANG_MS :: 5000

// One dispatch in progress.
@(private = "file")
Frame :: struct {
    env:      Jmp_Buf,
    ctx:      runtime.Context, // the arming frame's, so recovery can allocate
    app:      ^Kernel,
    who:      int,
    gen:      u32,
    chain:    ^Chain,
    base:     uintptr,
    via:      rawptr, // .App's trampoline: the app's frame sits under the plugin's
    // The plugin's adopted objects, copied at arm time: the handler cannot follow its array.
    objects:  [FAULT_OBJECTS]uintptr,
    nobjects: int,
    // The plugin's name plus a newline, copied at arm time: the handler cannot allocate.
    name:     [NAME_MAX]u8,
    n:        int,
    left:     i64, // the frame below's watch time left, in ns; 0 for none
    busy:     bool, // atomic; inside an api call
}

@(private = "file")
Guard :: struct {
    frames: [FAULT_DEPTH]Frame,
    depth:  int, // atomic; 0 is unarmed
    step:   int, // the depth of the frame a hang is being stepped back into; 0 for none
    stepped: string, // why it is being stepped: the unwind's why
    why:    string, // a literal, or fail's copy in `said`
    said:   [SAID_MAX]u8,
    traced: bool,
    lost:   [NAME_MAX]u8, // fail's name when no frame holds one
}

// Dispatches nested on one thread; past this, dispatch refuses.
FAULT_DEPTH :: 16

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

@(private = "file")
g_kernel: uintptr // this object's base: the walk stops at the dispatch frame

@(private = "file")
g_libc: uintptr // blame looks through its frames to the caller

@(private = "file")
g_abort_safe: bool // this glibc's abort raises before it takes any lock

// The C++ runtime's objects (libstdc++, libc++abi, libgcc_s): blame looks through them, as
// through libc. Found from each plugin's own symbols at load; a static runtime is the plugin's.
@(private = "file")
RUNTIME_MAX :: 8

@(private = "file")
g_runtime: [RUNTIME_MAX]uintptr

@(private = "file")
g_nruntime: int // atomic

// --- install ---

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
    for sig in FAULT_SIGNALS {
        if !install(sig) {
            return false
        }
    }
    act := posix.sigaction_t {
        sa_sigaction = reap_handler,
        sa_flags     = {.SIGINFO, .ONSTACK},
    }
    posix.sigemptyset(&act.sa_mask)
    if os_sigaction(fault_reap_signal(), &act, nil) != .OK {
        return false
    }
    // The first backtrace dlopens the unwinder and mallocs; do it here, not in the handler.
    warm: [1]rawptr
    backtrace(raw_data(warm[:]), 1)
    g_kernel = fault_object_base(rawptr(fault_install))
    g_libc = fault_object_base(rawptr(gnu_get_libc_version()))
    g_abort_safe = glibc_at_least(2, 41)
    g_installed = true
    return true
}

fault_ready :: proc() -> bool {
    return g_installed
}

@(private = "file")
install :: proc "contextless" (sig: posix.Signal) -> bool {
    act := posix.sigaction_t {
        sa_sigaction = fault_handler,
        sa_flags     = {.SIGINFO, .ONSTACK},
    }
    posix.sigemptyset(&act.sa_mask)
    return os_sigaction(sig, &act, nil) == .OK
}

// A plugin that went around the exports (a raw syscall) to replace a fault handler: lues's goes
// back, and the plugin's is chained. True when there was one.
fault_kept :: proc(k: ^Kernel, i: int) -> (replaced: bool) {
    for sig in FAULT_SIGNALS {
        cur: posix.sigaction_t
        if os_sigaction(sig, nil, &cur) != .OK || cur.sa_sigaction == fault_handler {
            continue
        }
        fault_chain(k.plugs[i].chain, sig)^ = cur
        install(sig)
        replaced = true
    }
    return
}

// The chain of the plugin whose code runs on this thread, outside an api call; nil for none.
fault_running :: proc "contextless" () -> ^Chain {
    f := top()
    if f == nil || intrinsics.atomic_load(&f.busy) {
        return nil
    }
    return f.chain
}

// The handler a plugin set for a fault signal; nil for any other signal.
fault_chain :: proc "contextless" (chain: ^Chain, sig: posix.Signal) -> ^posix.sigaction_t {
    for s, n in FAULT_SIGNALS {
        if s == sig {
            return &chain[n]
        }
    }
    return nil
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

// No frame left for another dispatch.
fault_full :: proc() -> bool {
    return intrinsics.atomic_load(&g_guard.depth) == FAULT_DEPTH
}

// The next frame's. Not while full.
fault_env :: proc() -> ^Jmp_Buf {
    return &g_guard.frames[intrinsics.atomic_load(&g_guard.depth)].env
}

// Call after the sigsetjmp that fills the buffer. Pushes the frame.
fault_arm :: proc(a: ^Kernel, i: int, via: rawptr = nil) {
    p := &a.plugs[i]
    f := next()
    f.app, f.who, f.gen, f.chain, f.base, f.via = a, i, p.gen, p.chain, p.base, via
    f.nobjects = copy(f.objects[:], p.objects[:])
    f.n = put_name(f.name[:], p.name)
    push(f)
}

// The frame the next arm fills.
@(private = "file")
next :: proc "contextless" () -> ^Frame {
    return &g_guard.frames[intrinsics.atomic_load(&g_guard.depth)]
}

// Only once f is filled: a signal from here on sees it.
@(private = "file")
push :: proc(f: ^Frame) {
    g := &g_guard
    f.ctx = context
    intrinsics.atomic_store(&f.busy, false)
    g.why, g.traced = "", false
    watch_push(f)
    intrinsics.atomic_store(&g.depth, intrinsics.atomic_load(&g.depth) + 1)
}

// An object adopted during the call counts at once, in every frame of the plugin, not from
// the next dispatch.
fault_adopt :: proc(i: int, base: uintptr) {
    g := &g_guard
    for &f in g.frames[:intrinsics.atomic_load(&g.depth)] {
        if f.who == i && f.nobjects < FAULT_OBJECTS {
            f.objects[f.nobjects] = base
            f.nobjects += 1
        }
    }
}

// Pops the frame.
fault_disarm :: proc() {
    pop()
}

// Guard 2: a fault while busy is not unwound.
// (hole pkey-tagging :tags (memory fault) :sev missing-system) kernel memory stays writable during plugin code; a stray plugin write corrupts it without a fault.
fault_busy :: proc "contextless" (on: bool) {
    if f := top(); f != nil {
        intrinsics.atomic_store(&f.busy, on)
    }
}

// The api's fail: the same jump as a fault, taken on purpose, so no guard 1. It can't jump
// with no net armed on this thread, or from inside an api call: it dies and the plugin is
// quarantined, `name` when no frame names it. The message is the plugin's memory, so it is
// copied while busy.
fault_fail :: proc "contextless" (name, msg: string) -> ! {
    g := &g_guard
    f := top()
    n, _ := walk(0)
    if f == nil || intrinsics.atomic_load(&f.busy) || !owned(f, n, caller(n)) {
        g.traced = trace_write(n, "failed")
        if f != nil {
            die(.SIGABRT, f.name[:f.n])
        } else {
            die(.SIGABRT, g.lost[:put_name(g.lost[:], name)])
        }
        abort()
    }
    intrinsics.atomic_store(&f.busy, true)
    m := copy(g.said[:], "failed")
    if len(msg) > 0 {
        m += copy(g.said[m:], ": ")
        m += copy(g.said[m:], msg)
    }
    intrinsics.atomic_store(&f.busy, false)
    why := string(g.said[:m])
    g.traced = trace_write(n, why)
    unwind(why)
}

// Reads only the guard: the jump does not restore the arming frame's locals. The frame unwind
// popped is still in its slot; copied out first, since unloading can dispatch into that slot.
fault_reap :: proc "contextless" () {
    g := &g_guard
    f := &g.frames[intrinsics.atomic_load(&g.depth)]
    context = f.ctx
    loader_faulted(f.app, f.who, g.why, g.traced)
}

@(private = "file")
top :: proc "contextless" () -> ^Frame {
    d := intrinsics.atomic_load(&g_guard.depth)
    return &g_guard.frames[d - 1] if d > 0 else nil
}

// Only after the jump buffer is done with: a signal from here on sees the frame below.
@(private = "file")
pop :: proc "contextless" () -> ^Frame {
    d := intrinsics.atomic_load(&g_guard.depth) - 1
    f := &g_guard.frames[d]
    intrinsics.atomic_store(&g_guard.depth, d)
    if g_guard.step > d {
        g_guard.step = 0
    }
    watch_pop(f)
    return f
}

// The name plus a newline, cut to fit. Returns the length; 1 for no name.
@(private = "file")
put_name :: proc "contextless" (buf: []u8, name: string) -> int {
    n := min(len(name), len(buf) - 1)
    copy(buf[:n], name[:n])
    buf[n] = '\n'
    return n + 1
}

// --- plugin threads ---
//
// A thread that plugin code starts runs under a copy of the frame that started it, so a fault on
// it is judged and unwound the same way, and the thread never reads the plugin table, which the
// main thread may be moving. Unloading is the main thread's: the thread posts the fault in
// Kernel.lost and ends, and loader_reap unloads the plugin. No watchdog watches it. Unloading
// a plugin ends its threads the same way, with the reap signal (fault_stop_threads).

// Plugin threads alive at once; past this, pthread_create says EAGAIN.
THREADS_MAX :: 256

// How long an unload waits for a plugin's threads to end.
REAP_MS :: 1000

@(private = "file")
Thread_Slot :: struct {
    state: enum u8 {Free, Taken, Live}, // atomic; Taken is starting, and only Live is signalled
    tid:   posix.pthread_t,
    app:   ^Kernel,
    who:   int,
    gen:   u32,
    told:  bool, // signalled; the main thread's
}

@(private = "file")
g_threads: [THREADS_MAX]Thread_Slot

@(private = "file")
REAPED :: "reaped"

@(private = "file")
Thread_Start :: struct {
    fn:     proc "c" (arg: rawptr) -> rawptr,
    arg:    rawptr,
    slot:   ^Thread_Slot,
    parent: Frame,
}

// The arg for fault_thread_main; nil when no plugin code runs on this thread, or `full`.
fault_thread :: proc "contextless" (fn: proc "c" (arg: rawptr) -> rawptr, arg: rawptr) -> (start: rawptr, full: bool) {
    f := top()
    if f == nil || intrinsics.atomic_load(&f.busy) {
        return nil, false
    }
    slot := take()
    if slot == nil {
        return nil, true
    }
    slot.app, slot.who, slot.gen, slot.told = f.app, f.who, f.gen, false
    context = runtime.default_context()
    s := new(Thread_Start, f.ctx.allocator)
    if s == nil {
        intrinsics.atomic_store(&slot.state, .Free)
        return nil, true
    }
    s^ = {fn = fn, arg = arg, slot = slot, parent = f^}
    return s, false
}

// The thread never started.
fault_thread_drop :: proc "contextless" (arg: rawptr) {
    s := (^Thread_Start)(arg)
    intrinsics.atomic_store(&s.slot.state, .Free)
    context = runtime.default_context()
    free(s, s.parent.ctx.allocator)
}

fault_thread_main :: proc "c" (arg: rawptr) -> rawptr {
    s := (^Thread_Start)(arg)
    context = runtime.default_context()
    context.allocator = s.parent.ctx.allocator
    start := s^
    free(s)
    slot := start.slot
    fault_install() // this thread's alt stack
    if sigsetjmp(fault_env(), 1) != 0 {
        if g_guard.why != REAPED {
            post()
        }
        intrinsics.atomic_store(&slot.state, .Free)
        return nil
    }
    p := &start.parent
    f := next()
    f.app, f.who, f.gen, f.chain, f.base, f.via = p.app, p.who, p.gen, p.chain, p.base, nil
    f.objects, f.nobjects, f.name, f.n = p.objects, p.nobjects, p.name, p.n
    push(f)
    slot.tid = posix.pthread_self()
    intrinsics.atomic_store(&slot.state, .Live)
    ret := start.fn(start.arg)
    intrinsics.atomic_store(&slot.state, .Free)
    fault_disarm()
    return ret
}

// Ends plugin i's threads. False when one has not ended by REAP_MS: it may still run the
// plugin's code, so the plugin must stay mapped.
fault_stop_threads :: proc(k: ^Kernel, i: int) -> bool {
    gen := k.plugs[i].gen
    until := time.tick_now()._nsec + REAP_MS * 1e6
    for {
        left := false
        for &s in g_threads {
            state := intrinsics.atomic_load(&s.state)
            if state == .Free || s.app != k || s.who != i || s.gen != gen {
                continue
            }
            left = true
            if state == .Live && !s.told {
                posix.pthread_kill(s.tid, fault_reap_signal())
                s.told = true
            }
        }
        if !left {
            return true
        }
        if time.tick_now()._nsec > until {
            return false
        }
        time.sleep(time.Millisecond)
    }
}

// The top realtime signal: glibc keeps the low ones.
fault_reap_signal :: proc "contextless" () -> posix.Signal {
    return posix.Signal(__libc_current_sigrtmax())
}

@(private = "file")
take :: proc "contextless" () -> ^Thread_Slot {
    for &s in g_threads {
        if _, ok := intrinsics.atomic_compare_exchange_strong(&s.state, .Free, .Taken); ok {
            return &s
        }
    }
    return nil
}

// Posts the frame unwind popped. A second plugin's post waits for the first to be reaped.
@(private = "file")
post :: proc "contextless" () {
    f := &g_guard.frames[intrinsics.atomic_load(&g_guard.depth)]
    v := pack(u32(f.who), f.gen)
    for {
        if _, ok := intrinsics.atomic_compare_exchange_strong(&f.app.lost, 0, v); ok {
            return
        }
        wait := posix.timespec{tv_nsec = 1e6}
        posix.nanosleep(&wait, nil)
    }
}

// --- the handlers ---
//
// Async-signal-safe: no allocation, no lock, no fmt. dladdr is the one exception.

// (hole leaf-libc-faults :tags fault :sev missing-system) a fault in memcpy or strlen the plugin called is blamed, not unwound: nothing here knows which libc code takes no lock.
@(private = "file")
fault_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    pc := fault_ip(uc)
    n, at := walk(pc)
    f := top()
    if f == nil {
        g_exit = dead_in(n)
        g_guard.traced = trace_write(n, signal_name(sig))
        die(sig, g_exit.name[:g_exit.n] if g_exit != nil else nil)
        return
    }
    // Inside an api call the plugin's call caused it, wherever the pc is: quarantined, so the
    // next start does not load it into the same crash.
    if f != nil && intrinsics.atomic_load(&f.busy) {
        g_guard.traced = trace_write(n, signal_name(sig))
        die(sig, f.name[:f.n])
        return
    }
    if in_plugin(f, pc) && owned(f, n, at) {
        g_guard.traced = trace_write(n, signal_name(sig))
        unwind(signal_name(sig))
    }
    // abort, called on purpose; from outside the process it is not the plugin's.
    aborted := sig == .SIGABRT && info.si_pid == posix.getpid()
    if aborted && g_abort_safe && f != nil {
        if c := past_libc(n, at); c < n && mine(f, g_objs[c].base) && owned(f, n, c) {
            g_guard.traced = trace_write(n, signal_name(sig))
            unwind(signal_name(sig))
        }
    }
    if chained(f, sig, info, uc) {
        return
    }
    g_guard.traced = trace_write(n, signal_name(sig))
    // Its fault under code that is not its own, which may hold a lock the jump would leave
    // held; a fault in libc that it called; or its abort past other code (std::terminate).
    die(sig, f.name[:f.n] if in_plugin(f, pc) else blamed(f, n, at, aborted))
}

// The plugin's own handler, for a fault lues would die on (wasmtime's, for a trap in its JIT
// code). It returns to retry the access, or jumps away. One that retries forever is a hang,
// and the watchdog ends it.
@(private = "file")
chained :: proc "contextless" (f: ^Frame, sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) -> bool {
    if f == nil {
        return false
    }
    act := fault_chain(f.chain, sig)^
    switch rawptr(act.sa_handler) {
    case rawptr(posix.SIG_DFL), rawptr(posix.SIG_IGN):
        return false
    }
    if .SIGINFO in act.sa_flags {
        act.sa_sigaction(sig, info, uc)
    } else {
        act.sa_handler(sig)
    }
    return true
}

// A hang in code that is not the plugin's may hold a lock there, so it is not unwound: the
// cpu steps it back into the plugin, one instruction per SIGTRAP, for one more window. A
// blocked syscall comes back with EINTR, since the alarm has no SA_RESTART.
@(private = "file")
hang_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    g := &g_guard
    f := top()
    if f == nil {
        return // stale: the dispatch came back
    }
    if intrinsics.atomic_load(&g_watch_until) != 0 {
        return // stale: a newer deadline was set while the alarm was in flight
    }
    pc := fault_ip(uc)
    n, at := walk(pc)
    if intrinsics.atomic_load(&f.busy) || g.step != 0 {
        g.traced = trace_write(n, "stopped returning")
        die(.SIGABRT, f.name[:f.n])
        return
    }
    if in_plugin(f, pc) && owned(f, n, at) {
        g.traced = trace_write(n, "stopped returning")
        unwind("stopped returning")
    }
    g.step, g.stepped = intrinsics.atomic_load(&g.depth), "stopped returning"
    step(uc, true)
    intrinsics.atomic_store(&g_watch_until, time.tick_now()._nsec + g_watch_ms * 1e6)
}

// Unwinds at the first instruction where the stepped frame's plugin is back on top, with only
// its own frames under it. A nested dispatch is stepped through.
@(private = "file")
step_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    g := &g_guard
    d := intrinsics.atomic_load(&g.depth)
    if g.step == 0 || d < g.step {
        g.step = 0 // the frame came back or was unwound
        step(uc, false)
        return
    }
    f := top()
    pc := fault_ip(uc)
    if d > g.step || intrinsics.atomic_load(&f.busy) || !in_plugin(f, pc) {
        return
    }
    n, at := walk(pc)
    if !owned(f, n, at) {
        return
    }
    g.step = 0
    if g.stepped != REAPED {
        g.traced = trace_write(n, g.stepped)
    }
    unwind(g.stepped)
}

// Ends a plugin thread at its base frame, as a hang is ended: stepped back to the plugin's own
// code first when it is in libc or an api call.
@(private = "file")
reap_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uc: rawptr) {
    g := &g_guard
    f := top()
    if f == nil || g.step != 0 {
        return // left its frame, or already on its way out
    }
    pc := fault_ip(uc)
    if !intrinsics.atomic_load(&f.busy) && in_plugin(f, pc) {
        if n, at := walk(pc); owned(f, n, at) {
            unwind(REAPED)
        }
    }
    g.step, g.stepped = intrinsics.atomic_load(&g.depth), REAPED
    step(uc, true)
}

@(private = "file")
unwind :: proc "contextless" (why: string) -> ! {
    g_guard.why = why
    f := pop()
    siglongjmp(&f.env, 1)
}

// Guard 1: who is to blame. Guard 2 decides whether it can be unwound.
@(private = "file")
in_plugin :: proc "contextless" (f: ^Frame, pc: uintptr) -> bool {
    info: Dl_Info
    if f == nil || pc == 0 || f.base == 0 || dladdr(rawptr(pc), &info) == 0 {
        return false
    }
    return mine(f, uintptr(info.dli_fbase))
}

// (hole cxx-runtime-frames :tags fault :sev wrong-behavior) a C++ runtime frame under the plugin's (libstdc++'s std::thread trampoline) counts as foreign, so a fault on a std::thread dies and its reap never ends it.
// Guard 1 for the rest of the stack: every frame under `at`, down to the dispatch frame, is
// the plugin's. A walk that missed the pc (at < 0), or ends first, judges only what it saw.
@(private = "file")
owned :: proc "contextless" (f: ^Frame, n, at: int) -> bool {
    if at < 0 {
        return true
    }
    via: uintptr
    if info: Dl_Info; f.via != nil && dladdr(f.via, &info) != 0 {
        via = uintptr(info.dli_fbase)
    }
    for o in g_objs[at + 1:n] {
        if o.base == g_kernel || (via != 0 && o.base == via) {
            return true
        }
        if !mine(f, o.base) {
            return false
        }
    }
    return true
}

// Who called into libc or the C++ runtime when it faulted: the plugin if the first frame past
// theirs is its own. An abort is called on purpose, so for one any frame of the plugin's over
// dispatch counts.
@(private = "file")
blamed :: proc "contextless" (f: ^Frame, n, at: int, aborted: bool) -> []u8 {
    if f == nil || at < 0 {
        return nil
    }
    for o in g_objs[at:n] {
        if mine(f, o.base) {
            return f.name[:f.n]
        }
        if o.base == g_kernel || (!runtime_object(o.base) && !aborted) {
            return nil
        }
    }
    return nil
}

// libc, or the C++ runtime.
@(private = "file")
runtime_object :: proc "contextless" (base: uintptr) -> bool {
    if base == g_libc {
        return true
    }
    for r in g_runtime[:intrinsics.atomic_load(&g_nruntime)] {
        if base == r {
            return true
        }
    }
    return false
}

// Records the C++ runtime a plugin links, by where its own lookup finds the runtime's symbols.
// The main thread only.
fault_runtime :: proc(lib: rawptr, plugin: uintptr) {
    for sym in ([]cstring{"__cxa_throw", "_Unwind_RaiseException"}) {
        base := fault_object_base(posix.dlsym(posix.Symbol_Table(lib), sym))
        n := intrinsics.atomic_load(&g_nruntime)
        if base == 0 || base == plugin || base == g_libc || n == RUNTIME_MAX || runtime_object(base) {
            continue
        }
        g_runtime[n] = base
        intrinsics.atomic_store(&g_nruntime, n + 1)
    }
}

// The first frame from `at` that is not libc's; n for none.
@(private = "file")
past_libc :: proc "contextless" (n, at: int) -> int {
    if at < 0 {
        return n
    }
    c := at
    for c < n && g_objs[c].base == g_libc {
        c += 1
    }
    return c
}

// From 2.41 glibc's abort raises SIGABRT before anything else; before, it took a lock first.
@(private = "file")
glibc_at_least :: proc "contextless" (major, minor: int) -> bool {
    v := string(gnu_get_libc_version())
    num :: proc "contextless" (s: ^string) -> (n: int) {
        for len(s^) > 0 && s[0] >= '0' && s[0] <= '9' {
            n = n * 10 + int(s[0] - '0')
            s^ = s[1:]
        }
        if len(s^) > 0 {
            s^ = s[1:] // the dot
        }
        return
    }
    got_major := num(&v)
    got_minor := num(&v)
    return got_major > major || (got_major == major && got_minor >= minor)
}

// The frame under the walk's own kernel frames: whoever called into the api.
@(private = "file")
caller :: proc "contextless" (n: int) -> int {
    at := 0
    for at < n && g_objs[at].base == g_kernel {
        at += 1
    }
    return at - 1
}

@(private = "file")
mine :: proc "contextless" (f: ^Frame, base: uintptr) -> bool {
    if base == 0 {
        return false
    }
    if base == f.base {
        return true
    }
    for o in f.objects[:f.nobjects] {
        if base == o {
            return true
        }
    }
    return false
}

// Syncs the app's fds and names the plugin to blame (`who`, newline included; nil for nobody),
// then re-raises with the default action.
@(private = "file")
die :: proc "contextless" (sig: posix.Signal, who: []u8) {
    for &fd in g_syncs {
        if v := intrinsics.atomic_load(&fd); v != 0 {
            posix.fsync(posix.FD(v))
        }
    }
    if report := intrinsics.atomic_load(&g_report); len(who) > 1 && report != 0 {
        posix.write(posix.FD(report), raw_data(who), uint(len(who)))
    }
    dfl := posix.sigaction_t {
        sa_handler = auto_cast posix.SIG_DFL,
    }
    os_sigaction(sig, &dfl, nil)
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

// Before the kernel closes the quarantine or faults file: a dead plugin's destructors still run
// at exit, so the handler keeps its own copy of the fd while one is mapped.
fault_fd_drop :: proc(slot: ^i32) {
    fd := intrinsics.atomic_load(slot)
    if fd != 0 && intrinsics.atomic_load(&g_ndead) > 0 {
        fd = posix.fcntl(posix.FD(fd), .DUPFD_CLOEXEC, c.int(0))
    } else {
        fd = 0
    }
    intrinsics.atomic_store(slot, max(fd, 0))
}

fault_report_drop :: proc() {
    fault_fd_drop(&g_report)
}

// --- dead plugins ---
//
// A faulted plugin stays mapped, and glibc runs its destructors and atexit handlers at exit,
// with no frame armed. A crash there is blamed by the frames it is in. The table outlives the
// kernel.

@(private = "file")
DEAD_MAX :: 64

@(private = "file")
PATH_MAX :: 256

@(private = "file")
Dead :: struct {
    base: uintptr,
    name: [NAME_MAX]u8, // with a newline, as a frame's
    n:    int,
    path: [PATH_MAX]u8,
    plen: int,
}

@(private = "file")
g_dead: [DEAD_MAX]Dead

@(private = "file")
g_ndead: int // atomic

// The dead plugin a crash with no frame is in, for the trace; nil for none.
@(private = "file", thread_local)
g_exit: ^Dead

// The main thread only. Past DEAD_MAX, a crash at exit is not blamed.
fault_dead :: proc(base: uintptr, name, path: string) {
    n := intrinsics.atomic_load(&g_ndead)
    if base == 0 || n == DEAD_MAX {
        return
    }
    d := &g_dead[n]
    d.base = base
    d.n = put_name(d.name[:], name)
    d.plen = copy(d.path[:], path)
    intrinsics.atomic_store(&g_ndead, n + 1)
}

@(private = "file")
dead_in :: proc "contextless" (n: int) -> ^Dead {
    for o in g_objs[:n] {
        for &d in g_dead[:intrinsics.atomic_load(&g_ndead)] {
            if o.base == d.base {
                return &d
            }
        }
    }
    return nil
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
    context = a.ctx
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
    context = a.ctx
    if a.traces == nil {
        return
    }
    fault_fd_drop(&g_trace)
    os.close(a.traces)
    a.traces = nil
}

// Temp-allocated; empty with no state dir.
fault_trace_path :: proc(a: ^Kernel) -> string {
    context = a.ctx
    if a.home.state == "" {
        return ""
    }
    path, _ := filepath.join({a.home.state, FAULTS_FILE}, context.temp_allocator)
    return path
}

// Writes the last walk.
@(private = "file")
trace_write :: proc "contextless" (n: int, why: string) -> bool {
    fd := posix.FD(intrinsics.atomic_load(&g_trace))
    if fd == 0 {
        return false
    }
    put_header(fd, why)
    // The plugin's object first: the walk starts in kernel frames.
    plug: uintptr
    if f := top(); f != nil {
        plug = f.base
    } else if g_exit != nil {
        plug = g_exit.base
    }
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
// `at` is the pc's frame; -1 when the walk missed it.
@(private = "file")
walk :: proc "contextless" (pc: uintptr) -> (n, at: int) {
    n = int(backtrace(raw_data(g_pcs[:]), TRACE_MAX))
    at = -1
    for i in 0 ..< n {
        if pc != 0 && uintptr(g_pcs[i]) == pc {
            at = i
            break
        }
    }
    if at < 0 && pc != 0 && n < TRACE_MAX {
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
    return
}

// Drops the newline fault_arm put after the name.
@(private = "file")
put_header :: proc "contextless" (fd: posix.FD, why: string) {
    put(fd, "\n--- ")
    if f := top(); f != nil && f.n > 1 {
        posix.write(fd, &f.name[0], uint(f.n - 1))
    } else if g_exit != nil && g_exit.n > 1 {
        posix.write(fd, &g_exit.name[0], uint(g_exit.n - 1))
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
    if g_exit != nil && g_exit.base == base {
        return string(g_exit.path[:g_exit.plen])
    }
    f := top()
    if f == nil || f.app == nil {
        return "" // no kernel to ask
    }
    for p in f.app.plugs {
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
    case .SIGABRT:
        return "aborted"
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
    @(private = "file")
    REG_EFL :: 17
    #assert(offset_of(Ucontext, gregs) == 40)

    // The trap flag: once the handler returns, the cpu raises SIGTRAP after each instruction.
    @(private = "file")
    step :: proc "contextless" (uc: rawptr, on: bool) {
        TF :: 0x100
        efl := &(^Ucontext)(uc).gregs[REG_EFL]
        efl^ = efl^ | TF if on else efl^ & ~u64(TF)
    }

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

    // No stepping: a hang outside the plugin dies when its second window ends.
    @(private = "file")
    step :: proc "contextless" (uc: rawptr, on: bool) {}
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
    if os_sigaction(.SIGALRM, &act, nil) != .OK {
        return
    }
    act.sa_sigaction = step_handler
    if os_sigaction(.SIGTRAP, &act, nil) != .OK {
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

// A new deadline for f; the one below pauses, so a nested call's time is not charged to it.
@(private = "file")
watch_push :: proc "contextless" (f: ^Frame) {
    f.left = 0
    if !watching() {
        return
    }
    now := time.tick_now()._nsec
    if until := intrinsics.atomic_load(&g_watch_until); until != 0 {
        f.left = max(until - now, 1)
    }
    intrinsics.atomic_store(&g_watch_until, now + g_watch_ms * 1e6)
}

// The frame below gets the time it had left.
@(private = "file")
watch_pop :: proc "contextless" (f: ^Frame) {
    if !watching() {
        return
    }
    intrinsics.atomic_store(&g_watch_until, time.tick_now()._nsec + f.left if f.left != 0 else 0)
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
