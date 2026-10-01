package lues

import "core:c"
import "core:sync"

// One protection key on every kernel heap mapping. Plugin code runs with it write-disabled, so a
// stray write into kernel memory faults where it happens and is blamed like any other fault.
// Rights are per thread. Without pkeys (no hardware, or none left) all of this does nothing.

foreign import libc_pkey "system:c"

@(default_calling_convention = "c")
foreign libc_pkey {
    pkey_alloc :: proc(flags: c.uint, rights: c.uint) -> c.int ---
    pkey_mprotect :: proc(addr: rawptr, len: c.size_t, prot: c.int, pkey: c.int) -> c.int ---
    // rdpkru and wrpkru: no syscall, no lock, so a signal handler may call it.
    pkey_set :: proc(pkey: c.int, rights: c.uint) -> c.int ---
}

@(private = "file")
PKEY_DISABLE_WRITE :: 2

@(private = "file")
PROT_RW :: 0x1 | 0x2

@(private = "file")
g_pkey: c.int = -1

@(private = "file")
g_pkey_once: sync.Once

// The key is per process; test kernels share it. Linux starts every thread with a new key's
// access disabled, so each thread that touches kernel memory opens it once: this one here, and
// the threads it starts after inherit that.
pkey_init :: proc() {
    sync.once_do(&g_pkey_once, proc() {
        g_pkey = pkey_alloc(0, 0)
    })
    pkey_write(true)
}

pkey_ready :: proc "contextless" () -> bool {
    return g_pkey >= 0
}

// A fresh read-write mapping of the kernel's.
pkey_tag :: proc "contextless" (p: rawptr, n: int) {
    if g_pkey >= 0 {
        pkey_mprotect(p, c.size_t(n), PROT_RW, g_pkey)
    }
}

// This thread's write access to kernel memory.
pkey_write :: proc "contextless" (on: bool) {
    if g_pkey >= 0 {
        pkey_set(g_pkey, 0 if on else PKEY_DISABLE_WRITE)
    }
}
