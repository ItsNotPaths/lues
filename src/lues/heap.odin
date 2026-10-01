package lues

import "base:runtime"
import "core:mem/tlsf"
import "core:sync"
import "core:sys/linux"

// The kernel's heap, never libc malloc: plugins share malloc, and an overrun there must not
// land in kernel memory. TLSF over pools mapped here, and a mapping of its own for anything
// past HEAP_LARGE, so every byte is in a mapping the kernel made. Locked: the io worker
// allocates, and any thread may drop the last reference to a snapshot.
Heap :: struct {
    tlsf:  tlsf.Allocator,
    large: map[uintptr]int, // base -> mapped length; the map itself is on tlsf
    lock:  sync.Mutex,
    live:  int, // allocations not yet freed
}

HEAP_POOL :: 8 << 20

// TLSF can't grow past its pool size, and a big buffer is better returned to the system whole.
HEAP_LARGE :: 1 << 20

@(private = "file")
PAGE :: 4096

// A mapping's length sits in front of it: TLSF frees its pool records with no size.
@(private = "file")
HEADER :: 64

heap_init :: proc(h: ^Heap) -> bool {
    pkey_init()
    pages := runtime.Allocator{procedure = pages_proc}
    if tlsf.init(&h.tlsf, pages, HEAP_POOL, HEAP_POOL) != .None {
        return false
    }
    h.large = make(map[uintptr]int, tlsf.allocator(&h.tlsf))
    return true
}

// Returns how many allocations were never freed.
heap_destroy :: proc(h: ^Heap) -> int {
    for base, n in h.large {
        linux.munmap(rawptr(base), uint(n))
    }
    delete(h.large)
    tlsf.destroy(&h.tlsf)
    live := h.live
    h^ = {}
    return live
}

heap_allocator :: proc(h: ^Heap) -> runtime.Allocator {
    return {procedure = heap_proc, data = h}
}

// Whether ptr is inside memory this heap handed out.
heap_owns :: proc(h: ^Heap, ptr: rawptr) -> bool {
    sync.guard(&h.lock)
    return owns(h, uintptr(ptr))
}

@(private = "file")
heap_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr,
                  old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
    h := (^Heap)(data)
    sync.guard(&h.lock)
    switch mode {
    case .Alloc, .Alloc_Non_Zeroed:
        return take(h, size, alignment, zero = mode == .Alloc)
    case .Free:
        give(h, old, old_size, loc)
        return nil, nil
    case .Resize, .Resize_Non_Zeroed:
        zero := mode == .Resize
        if old == nil {
            return take(h, size, alignment, zero)
        }
        if size == 0 {
            give(h, old, old_size, loc)
            return nil, nil
        }
        if uintptr(old) not_in h.large && size <= HEAP_LARGE {
            if !owns(h, uintptr(old)) {
                panic("lues heap: resize of memory it did not hand out", loc)
            }
            raw := tlsf.allocator(&h.tlsf)
            return raw.procedure(raw.data, mode, size, alignment, old, old_size, loc)
        }
        out, err := take(h, size, alignment, zero)
        if err != nil {
            return nil, err
        }
        copy(out, ([^]u8)(old)[:min(old_size, size)])
        give(h, old, old_size, loc)
        return out, nil
    case .Query_Features:
        if set := (^runtime.Allocator_Mode_Set)(old); set != nil {
            set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
        }
        return nil, nil
    case .Free_All, .Query_Info:
    }
    return nil, .Mode_Not_Implemented
}

@(private = "file")
take :: proc(h: ^Heap, size, alignment: int, zero: bool) -> ([]byte, runtime.Allocator_Error) {
    if size > HEAP_LARGE && alignment <= PAGE {
        n := align(size, PAGE)
        p, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
        if err != .NONE {
            return nil, .Out_Of_Memory
        }
        pkey_tag(p, n)
        h.large[uintptr(p)] = n
        h.live += 1
        return ([^]u8)(p)[:size], nil // fresh pages are zero
    }
    raw := tlsf.allocator(&h.tlsf)
    out, err := raw.procedure(raw.data, .Alloc if zero else .Alloc_Non_Zeroed, size, alignment, nil, 0)
    if err == nil && out != nil {
        h.live += 1
    }
    return out, err
}

// A pointer it did not hand out panics: freeing it into TLSF would corrupt the heap quietly.
@(private = "file")
give :: proc(h: ^Heap, ptr: rawptr, size: int, loc: runtime.Source_Code_Location) {
    if ptr == nil {
        return
    }
    if n, big := h.large[uintptr(ptr)]; big {
        delete_key(&h.large, uintptr(ptr))
        linux.munmap(ptr, uint(n))
    } else if owns(h, uintptr(ptr)) {
        tlsf.free_with_size(&h.tlsf, ptr, uint(size))
    } else {
        panic("lues heap: free of memory it did not hand out", loc)
    }
    h.live -= 1
}

@(private = "file")
owns :: proc(h: ^Heap, p: uintptr) -> bool {
    if in_slice(h.tlsf.pool.data, p) {
        return true
    }
    for pool := h.tlsf.pool.next; pool != nil; pool = pool.next {
        if in_slice(pool.data, p) {
            return true
        }
    }
    for base, n in h.large {
        if p >= base && p < base + uintptr(n) {
            return true
        }
    }
    return false
}

@(private = "file")
in_slice :: proc(s: []u8, p: uintptr) -> bool {
    base := uintptr(raw_data(s))
    return p >= base && p < base + uintptr(len(s))
}

@(private = "file")
align :: proc(n, to: int) -> int {
    return (n + to - 1) &~ (to - 1)
}

// TLSF's backing: every pool, and each pool's record, is a mapping of its own.
@(private = "file")
pages_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr,
                   old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
    #partial switch mode {
    case .Alloc, .Alloc_Non_Zeroed:
        if alignment > HEADER {
            return nil, .Invalid_Argument
        }
        n := align(size + HEADER, PAGE)
        p, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
        if err != .NONE {
            return nil, .Out_Of_Memory
        }
        pkey_tag(p, n)
        (^int)(p)^ = n
        return ([^]u8)(p)[HEADER:][:size], nil
    case .Free:
        if old != nil {
            base := rawptr(uintptr(old) - HEADER)
            linux.munmap(base, uint((^int)(base)^))
        }
        return nil, nil
    }
    return nil, .Mode_Not_Implemented
}
