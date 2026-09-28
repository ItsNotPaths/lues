package lues

import "core:c"
import "../docs"

// include/lues.h mirrors this.

API :: 1

ENTRY :: "lues_main"

Self :: distinct u64

Doc_Handle :: distinct u64

Io :: distinct u64

Kind :: distinct u32

Token :: u16

Event :: enum c.int32_t {
    Chord,
    Text,
    Moved,
    Io,
    Io_End,
}

// --- the read view: the piece table, read in place ---

Block :: struct {
    ptr: [^]u8,
    len: c.size_t,
}

Piece :: struct {
    block:   c.ptrdiff_t,
    off:     c.ptrdiff_t,
    len:     c.ptrdiff_t,
    doc_off: c.ptrdiff_t,
}

// A run of line starts: starts[at ..< at+n] + delta are lines first ..< first+n.
Seg :: struct {
    first: c.ptrdiff_t,
    at:    c.ptrdiff_t,
    n:     c.ptrdiff_t,
    delta: c.ptrdiff_t,
}

// Kernel-allocated.
Snapshot :: struct {
    blocks:  [^]Block,
    starts:  [^]c.ptrdiff_t,
    pieces:  [^]Piece,
    segs:    [^]Seg,
    nblocks: c.size_t,
    nstarts: c.size_t,
    npieces: c.size_t,
    nsegs:   c.size_t,
    size:    c.size_t, // bytes
    lines:   c.size_t,
    gen:     u64,
    doc:     Doc_Handle,
    app:     rawptr,
}

At :: struct {
    doc:  Doc_Handle,
    inst: rawptr,
    snap: ^Snapshot,
    io:   Io,
    code: c.int32_t,
    _:    [4]u8,
}

Event_Fn :: #type proc "c" (api: ^Api, self: Self, at: ^At, ev: Event, text: [^]u8, len: c.size_t) -> c.int32_t
Open_Fn :: #type proc "c" (api: ^Api, self: Self, doc: Doc_Handle, args: [^]u8, args_len: c.size_t) -> rawptr
Close_Fn :: #type proc "c" (api: ^Api, self: Self, doc: Doc_Handle, inst: rawptr)
Command_Fn :: #type proc "c" (api: ^Api, self: Self, at: ^At, args: [^]u8, args_len: c.size_t) -> c.int32_t
Entry_Fn :: #type proc "c" (api: ^Api, self: Self) -> c.int32_t

Kind_Vt :: struct {
    open:  Open_Fn,
    close: Close_Fn,
    event: Event_Fn,
}

// Plugin-allocated, `size` first.
Kind_Spec :: struct {
    size:     c.size_t,
    name:     [^]u8,
    name_len: c.size_t,
    ctx:      [^]u8,
    ctx_len:  c.size_t,
    vt:       Kind_Vt,
}

// --- the write side ---

// Plugin-allocated, `size` first. Arrays stride by the first element's `size`.
Edit :: struct {
    size:     c.size_t,
    lo:       c.size_t,
    hi:       c.size_t,
    text:     [^]u8,
    text_len: c.size_t,
    tag:      u32, // the app's
    _:        [4]u8,
}

// Channels not in `set` come from the layer below.
Span :: struct {
    size:  c.size_t,
    lo:    c.size_t,
    hi:    c.size_t,
    tok:   Token,
    attrs: u8, // the app's bits
    set:   docs.Chans,
    _:     [4]u8,
}

// Replaces this plugin's runs in [lo, hi).
Span_Pub :: struct {
    size:   c.size_t,
    lo:     c.size_t,
    hi:     c.size_t,
    spans:  [^]Span,
    nspans: c.size_t,
}

Submit_Flag :: enum u32 {
    Forget = 0, // derived bytes: nothing to undo
    Join   = 1, // into the last undo step
}
Submit_Flags :: distinct bit_set[Submit_Flag; u32]

// Kernel-allocated; grows at the end. The first field of the app's vtable.
Api :: struct {
    version:          u32,
    app_version:      u32,
    app:              cstring,
    register_kind:    proc "c" (api: ^Api, self: Self, spec: ^Kind_Spec) -> Kind,
    register_command: proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: c.size_t,
                                doc: [^]u8, doc_len: c.size_t, fn: Command_Fn),
    request_bind:     proc "c" (api: ^Api, self: Self, ctx: [^]u8, ctx_len: c.size_t,
                                chord: [^]u8, chord_len: c.size_t,
                                line: [^]u8, line_len: c.size_t),
    request_config:   proc "c" (api: ^Api, self: Self, section: [^]u8, section_len: c.size_t,
                                key: [^]u8, key_len: c.size_t,
                                value: [^]u8, value_len: c.size_t),
    register_token:   proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: c.size_t) -> Token,
    register_watch:   proc "c" (api: ^Api, self: Self, fn: Event_Fn),
    // Copied at the call; lands at the drain or is dropped whole.
    submit:           proc "c" (api: ^Api, self: Self, doc: Doc_Handle, gen: u64,
                                edits: [^]Edit, nedits: c.size_t, spans: ^Span_Pub,
                                flags: Submit_Flags),
    snapshot:         proc "c" (api: ^Api, self: Self, doc: Doc_Handle) -> ^Snapshot,
    release:          proc "c" (api: ^Api, self: Self, snap: ^Snapshot),
    message:          proc "c" (api: ^Api, self: Self, text: [^]u8, text_len: c.size_t),
    io_spawn:         proc "c" (api: ^Api, self: Self, doc: Doc_Handle, argv: [^]cstring,
                                nargv: c.size_t, cwd: [^]u8, cwd_len: c.size_t) -> Io,
    io_write:         proc "c" (api: ^Api, self: Self, io: Io, bytes: [^]u8, len: c.size_t),
    io_watch:         proc "c" (api: ^Api, self: Self, doc: Doc_Handle, path: [^]u8,
                                path_len: c.size_t) -> Io,
    io_fd:            proc "c" (api: ^Api, self: Self, doc: Doc_Handle, fd: c.int32_t) -> Io,
    io_close:         proc "c" (api: ^Api, self: Self, io: Io),
}

#assert(size_of(Block) == 16)
#assert(size_of(Piece) == 32)
#assert(size_of(Seg) == 32)
#assert(size_of(Snapshot) == 104)
#assert(size_of(At) == 40)
#assert(size_of(Edit) == 48)
#assert(size_of(Span) == 32)
#assert(size_of(Span_Pub) == 40)
#assert(size_of(Kind_Vt) == 24)
#assert(size_of(Kind_Spec) == 64)
#assert(size_of(Api) == 136)

pack :: proc "contextless" (lo, hi: u32) -> u64 {
    return u64(lo) | u64(hi) << 32
}

unpack :: proc "contextless" (v: u64) -> (lo, hi: u32) {
    return u32(v & 0xffff_ffff), u32(v >> 32)
}

doc_handle :: proc(id: docs.Id) -> Doc_Handle {
    return Doc_Handle(pack(id.slot, id.seq))
}

doc_id :: proc(doc: Doc_Handle) -> docs.Id {
    slot, seq := unpack(u64(doc))
    return {slot, seq}
}

// Whether a plugin struct of `size` bytes holds a field ending at `end`.
has :: proc "contextless" (size: c.size_t, end: uintptr) -> bool {
    return uintptr(size) >= end
}

// A plugin array strides by its first element's `size`. Every API 1 field is required; a field
// appended later is read only where has() says it exists. ok = false when the stride is short.
stride :: proc($T: typeid, base: rawptr, n: int) -> (step: uintptr, ok: bool) {
    if n == 0 {
        return 0, true
    }
    if base == nil {
        return 0, false
    }
    size := (^c.size_t)(base)^
    return uintptr(size), has(size, size_of(T))
}

elem :: proc($T: typeid, base: rawptr, step: uintptr, i: int) -> ^T {
    return (^T)(uintptr(base) + uintptr(i) * step)
}
