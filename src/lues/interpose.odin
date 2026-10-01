package lues

import "base:intrinsics"
import "core:sys/posix"

// The app exports these: an @(export) lands in an executable's dynamic symbols, so a plugin's
// calls, and those of any library it loaded, reach them before libc's. A call from plugin code
// never replaces lues's handlers: a fault signal's handler is chained (see fault_chain), and the
// watchdog's signals are refused. Anything else passes through. A raw syscall or an
// RTLD_DEEPBIND library goes around them; fault_kept repairs that after the call.

@(export, link_name = "sigaction")
interpose_sigaction :: proc "c" (sig: posix.Signal, act, old: ^posix.sigaction_t) -> posix.result {
    running := fault_running()
    if running == nil {
        return os_sigaction(sig, act, old)
    }
    if sig == .SIGALRM || sig == .SIGTRAP {
        posix.errno(.EINVAL)
        return .FAIL
    }
    chain := fault_chain(running, sig)
    if chain == nil {
        return os_sigaction(sig, act, old)
    }
    if old != nil {
        old^ = chain^
    }
    if act != nil {
        chain^ = act^
    }
    return .OK
}

// glibc's signal calls its own sigaction, not the export.
@(export, link_name = "signal")
interpose_signal :: proc "c" (sig: posix.Signal, handler: proc "c" (posix.Signal)) -> proc "c" (posix.Signal) {
    act := posix.sigaction_t {
        sa_handler = handler,
        sa_flags   = {.RESTART},
    }
    posix.sigemptyset(&act.sa_mask)
    posix.sigaddset(&act.sa_mask, sig)
    old: posix.sigaction_t
    if interpose_sigaction(sig, &act, &old) != .OK {
        return auto_cast posix.SIG_ERR
    }
    return old.sa_handler
}

// A thread that plugin code starts runs under a fault frame of its own.
@(export, link_name = "pthread_create")
interpose_pthread_create :: proc "c" (t: ^posix.pthread_t, attr: ^posix.pthread_attr_t,
                                      fn: proc "c" (arg: rawptr) -> rawptr, arg: rawptr) -> posix.Errno {
    Create :: proc "c" (^posix.pthread_t, ^posix.pthread_attr_t, proc "c" (arg: rawptr) -> rawptr, rawptr) -> posix.Errno
    real := Create(libc_next(&g_create, "pthread_create"))
    start := fault_thread(fn, arg)
    if start == nil {
        return real(t, attr, fn, arg)
    }
    err := real(t, attr, fault_thread_main, start)
    if err != .NONE {
        fault_thread_drop(start)
    }
    return err
}

// libc's sigaction. lues's own calls come here, never to the export.
os_sigaction :: proc "contextless" (sig: posix.Signal, act, old: ^posix.sigaction_t) -> posix.result {
    Sigaction :: proc "c" (posix.Signal, ^posix.sigaction_t, ^posix.sigaction_t) -> posix.result
    return Sigaction(libc_next(&g_sigaction, "sigaction"))(sig, act, old)
}

// The definition after the app's: libc's.
@(private = "file")
libc_next :: proc "contextless" (slot: ^rawptr, name: cstring) -> rawptr {
    RTLD_NEXT :: posix.Symbol_Table(~uintptr(0))
    if p := intrinsics.atomic_load(slot); p != nil {
        return p
    }
    p := posix.dlsym(RTLD_NEXT, name)
    intrinsics.atomic_store(slot, p)
    return p
}

@(private = "file")
g_sigaction: rawptr

@(private = "file")
g_create: rawptr
