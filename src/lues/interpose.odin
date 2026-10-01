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
    k, i := fault_running()
    if k == nil {
        return os_sigaction(sig, act, old)
    }
    if sig == .SIGALRM || sig == .SIGTRAP {
        posix.errno(.EINVAL)
        return .FAIL
    }
    chain := fault_chain(&k.plugs[i], sig)
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

// libc's sigaction. lues's own calls come here, never to the export.
os_sigaction :: proc "contextless" (sig: posix.Signal, act, old: ^posix.sigaction_t) -> posix.result {
    Sigaction :: proc "c" (posix.Signal, ^posix.sigaction_t, ^posix.sigaction_t) -> posix.result
    real := Sigaction(intrinsics.atomic_load(&g_real))
    if real == nil {
        RTLD_NEXT :: posix.Symbol_Table(~uintptr(0))
        real = Sigaction(posix.dlsym(RTLD_NEXT, "sigaction"))
        intrinsics.atomic_store(&g_real, rawptr(real))
    }
    return real(sig, act, old)
}

@(private = "file")
g_real: rawptr
