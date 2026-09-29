package pt

import "core:slice"
import "../rc"

// An immutable read at one generation. Safe without a lock: the arena never rewrites or moves
// what it has written, so `blocks` and `starts` are held by value as prefixes.
Snapshot :: struct {
    using text: Text,
    rc:         int, // atomic; a worker thread may hold the last reference
    gen:        u64,
}

// The caller owns one reference.
snapshot_take :: proc(pt: ^Piece_Table, gen: u64) -> ^Snapshot {
    context.allocator = kept(&pt.alloc)
    s := new(Snapshot)
    s.rc = 1
    s.gen = gen
    s.arena = pt.arena
    arena_retain(s.arena)
    s.blocks = pt.blocks
    s.starts = pt.starts
    s.pieces = slice.clone_to_dynamic(pt.pieces[:])
    s.segs = slice.clone_to_dynamic(pt.segs[:])
    s.size = pt.size
    s.lines = pt.lines
    return s
}

snapshot_retain :: proc(s: ^Snapshot) {
    rc.retain(&s.rc)
}

snapshot_release :: proc(s: ^Snapshot) {
    if !rc.release(&s.rc) {
        return
    }
    context.allocator = s.arena.alloc // the table's; read before the arena may go
    arena_release(s.arena)
    delete(s.pieces)
    delete(s.segs)
    free(s)
}
