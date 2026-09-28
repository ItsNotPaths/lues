package pt

import "core:slice"
import "../rc"

// (hole rs-pt :tags (port) :sev missing-port :needs (kernel-arenas)) not yet a crate; the piece table and its arena are Odin only.
// Pieces over immutable blocks. Nothing written is copied or moved.
// Invariants: pieces in order, none empty, doc_off the running total; line 0 starts at 0 and
// the index is never empty; size is the sum of piece lengths.

// Nothing is freed until the whole arena is: a full buffer is retired, not freed, so a reader's
// slice stays valid. Atomic refcount: the last release may come from a worker thread.
Arena :: struct {
    rc:     int,
    owned:  [dynamic][]u8, // every text block, for freeing; writer-only, so it may move freely
    spines: [dynamic][][]u8, // block-list buffers, live one last
    starts: [dynamic][]int, // line-start buffers, live one last
}

// Shared by Piece_Table and Snapshot. `blocks` and `starts` are slices so a reader's copy keeps
// naming its prefix while the writer's grows.
Text :: struct {
    arena:  ^Arena,
    blocks: [][]u8,
    starts: []int,
    pieces: [dynamic]Piece,
    segs:   [dynamic]Line_Seg,
    size:   int,
    lines:  int,
}

Piece_Table :: struct {
    using text: Text,
    tail:       int, // the block appends go into, -1 before the first
    tail_used:  int,
    // The rebuild's other buffer, swapped with `pieces`. Never read.
    spare:      [dynamic]Piece,
    // Pieces the last splice visited, for a test.
    touched:    int,
}

// [lo, hi) becomes `text`. A batch is sorted by `lo` and disjoint.
Splice :: struct {
    lo, hi: int,
    text:   []u8,
}

// Lines first ..< first+n start at starts[at ..< at+n] + delta. An edit re-deltas segments and
// never rewrites starts, so typing costs per segment, not per line.
Line_Seg :: struct {
    first: int,
    at:    int,
    n:     int,
    delta: int,
}

// A line and a byte column.
Pos :: struct {
    line: int,
    col:  int,
}

// Past this many segments the index is flattened back to one.
PT_COMPACT_SEGS :: 2048

// [off, off+len) of blocks[block], at doc_off in the document. An op that resizes a piece
// repairs doc_off on the ones after it.
Piece :: struct {
    block:   int,
    off:     int,
    len:     int,
    doc_off: int,
}

// A larger append gets a block of its own, so one append is one piece.
PT_CHUNK :: 64 * 1024

PT_COMPACT_PIECES :: 2048

// How far the starts pool may outgrow the live index before a fresh arena is worth it.
PT_ARENA_SLACK :: 4

PT_ARENA_FLOOR :: 4096

// --- the arena ---

arena_new :: proc() -> ^Arena {
    a := new(Arena)
    a.rc = 1
    return a
}

arena_retain :: proc(a: ^Arena) {
    rc.retain(&a.rc)
}

arena_release :: proc(a: ^Arena) {
    if !rc.release(&a.rc) {
        return
    }
    for b in a.owned {
        delete(b)
    }
    for s in a.spines {
        delete(s)
    }
    for s in a.starts {
        delete(s)
    }
    delete(a.owned)
    delete(a.spines)
    delete(a.starts)
    free(a)
}

// A full buffer is retired, not freed, so `live` stays valid.
@(private = "file")
grown :: proc(bufs: ^[dynamic][]$T, live: []T, extra: int) -> []T {
    if len(bufs) > 0 && len(live) + extra <= len(bufs[len(bufs) - 1]) {
        return bufs[len(bufs) - 1]
    }
    next := make([]T, max(2 * (len(live) + extra), 16))
    copy(next, live)
    append(bufs, next)
    return next
}

// `owned` frees the bytes; the block list's retired buffers hold the same pointers.
@(private = "file")
push_block :: proc(pt: ^Piece_Table, b: []u8) {
    append(&pt.arena.owned, b)
    buf := grown(&pt.arena.spines, pt.blocks, 1)
    buf[len(pt.blocks)] = b
    pt.blocks = buf[:len(pt.blocks) + 1]
}

@(private = "file")
push_starts :: proc(pt: ^Piece_Table, vals: ..int) {
    buf := grown(&pt.arena.starts, pt.starts, len(vals))
    copy(buf[len(pt.starts):], vals)
    pt.starts = buf[:len(pt.starts) + len(vals)]
}

// --- lifecycle ---

pt_init :: proc(pt: ^Piece_Table) {
    pt.arena = arena_new()
    pt.tail = -1
    lines_set(pt, {0})
}

pt_destroy :: proc(pt: ^Piece_Table) {
    arena_release(pt.arena)
    delete(pt.pieces)
    delete(pt.spare)
    delete(pt.segs)
    pt^ = {}
}

// A fresh arena, so a snapshot of the old content reads on.
pt_load :: proc(pt: ^Piece_Table, src: []u8) {
    pt_renew(pt)
    pt.size = len(src)
    push_block(pt, slice.clone(src))
    if len(src) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(src), doc_off = 0})
    }
    lines_set(pt, {0})
    for c, i in src {
        if c == '\n' {
            lines_push(pt, i + 1)
        }
    }
}

// A Text over borrowed blocks; doc_off, size and lines are computed here. `arena` stays nil,
// so this must not outlive the blocks.
text_build :: proc(blocks: [][]u8, pieces: []Piece, alloc := context.temp_allocator) -> Text {
    t := Text {
        blocks = blocks,
        pieces = make([dynamic]Piece, 0, len(pieces), alloc),
        segs   = make([dynamic]Line_Seg, 1, 1, alloc),
    }
    starts := make([dynamic]int, 1, len(pieces) + 1, alloc) // line 0 starts at 0
    for p in pieces {
        if p.len <= 0 {
            continue
        }
        q := p
        q.doc_off = t.size
        append(&t.pieces, q)
        for c, i in blocks[p.block][p.off:][:p.len] {
            if c == '\n' {
                append(&starts, t.size + i + 1)
            }
        }
        t.size += p.len
    }
    t.starts = starts[:]
    t.segs[0] = Line_Seg{0, 0, len(starts), 0}
    t.lines = len(starts)
    return t
}

// --- reading ---

// The invariants, as far as O(1) reaches: the last piece's end is the size.
text_check :: proc(t: ^Text) -> bool {
    if t.lines < 1 || len(t.segs) < 1 {
        return false
    }
    if n := len(t.pieces); n > 0 {
        return t.pieces[n - 1].doc_off + t.pieces[n - 1].len == t.size
    }
    return t.size == 0
}

text_line_count :: proc(t: ^Text) -> int {
    return t.lines
}

text_line_start :: proc(t: ^Text, line: int) -> int {
    i := seg_at_line(t, line)
    if i < 0 {
        return 0
    }
    s := t.segs[i]
    return t.starts[s.at + clamp(line - s.first, 0, s.n - 1)] + s.delta
}

// Excludes the newline.
text_line_range :: proc(t: ^Text, line: int) -> (lo, hi: int) {
    lo = text_line_start(t, line)
    if line + 1 < t.lines {
        return lo, text_line_start(t, line + 1) - 1
    }
    return lo, t.size
}

text_line_len :: proc(t: ^Text, line: int) -> int {
    lo, hi := text_line_range(t, line)
    return hi - lo
}

// Clamped: an offset past the end answers the last line.
text_line_at_off :: proc(t: ^Text, off: int) -> int {
    lo, hi := 0, t.lines
    for lo < hi {
        mid := (lo + hi) / 2
        if text_line_start(t, mid) <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return max(0, lo - 1)
}

// Up to the end of one piece. Borrowed: valid until the next edit on a Piece_Table.
text_span :: proc(t: ^Text, off: int) -> []u8 {
    i := piece_at(t.pieces[:], off)
    if i < 0 {
        return nil
    }
    p := t.pieces[i]
    return t.blocks[p.block][p.off + off - p.doc_off:p.off + p.len]
}

text_read :: proc(t: ^Text, lo, hi: int, alloc := context.allocator) -> []u8 {
    a := clamp(lo, 0, t.size)
    b := clamp(hi, a, t.size)
    out := make([]u8, b - a, alloc)
    n := 0
    for n < len(out) {
        src := text_span(t, a + n)
        if len(src) == 0 {
            break
        }
        n += copy(out[n:], src)
    }
    return out
}

// Borrowed when the line sits in one piece, else copied into `alloc`.
text_line :: proc(t: ^Text, line: int, alloc := context.allocator) -> []u8 {
    lo, hi := text_line_range(t, line)
    if hi <= lo {
        return nil
    }
    if s := text_span(t, lo); len(s) >= hi - lo {
        return s[:hi - lo]
    }
    return text_read(t, lo, hi, alloc)
}

// --- positions ---

// Into the document, with the column on a rune boundary.
text_clamp_pos :: proc(t: ^Text, p: Pos) -> Pos {
    line := clamp(p.line, 0, t.lines - 1)
    src := text_line(t, line, context.temp_allocator)
    col := clamp(p.col, 0, len(src))
    for col > 0 && col < len(src) && src[col] & 0xC0 == 0x80 {
        col -= 1
    }
    return Pos{line, col}
}

text_off :: proc(t: ^Text, p: Pos) -> int {
    q := text_clamp_pos(t, p)
    return text_line_start(t, q.line) + q.col
}

text_pos :: proc(t: ^Text, off: int) -> Pos {
    o := clamp(off, 0, t.size)
    line := text_line_at_off(t, o)
    return Pos{line, o - text_line_start(t, line)}
}

// --- editing ---

// The one mutator. `edits` is sorted by `lo` and disjoint. Rebuilt front to back:
// O(pieces + edits), not a repair per cut.
pt_splice_many :: proc(pt: ^Piece_Table, edits: []Splice) {
    pt.touched = 0
    if len(edits) == 0 {
        return
    }
    // Only a single splice keeps the incremental line index and the typing fast path.
    if len(edits) == 1 {
        a, b := splice_clamp(edits[0], 0, pt.size)
        text := edits[0].text
        if a == b && len(text) == 0 {
            return
        }
        pt_splice_lines(pt, a, b, text, len(text) - (b - a))
        if a == b && pt_extend_tail(pt, a, text) {
            pt.size += len(text)
            return
        }
    } else {
        lines_rebuild(pt, edits)
    }
    pt_rebuild(pt, edits)
}

pt_should_compact :: proc(pt: ^Piece_Table) -> bool {
    if len(pt.pieces) > PT_COMPACT_PIECES {
        return true
    }
    return len(pt.starts) > PT_ARENA_SLACK * max(pt.lines, PT_ARENA_FLOOR)
}

// One block and one line segment in a fresh arena. A snapshot holding the old arena reads on;
// the bytes are the same.
pt_compact :: proc(pt: ^Piece_Table) {
    // Both reads use the old arena, so before pt_renew.
    flat := text_read(pt, 0, pt.size)
    starts := make([]int, pt.lines)
    defer delete(starts)
    for i in 0 ..< pt.lines {
        starts[i] = text_line_start(pt, i)
    }

    size := pt.size
    pt_renew(pt)
    pt.size = size
    push_block(pt, flat)
    if len(flat) > 0 {
        append(&pt.pieces, Piece{block = 0, off = 0, len = len(flat), doc_off = 0})
    }
    lines_set(pt, starts)
}

// --- internals ---

// The caller refills the pieces and the line index.
@(private = "file")
pt_renew :: proc(pt: ^Piece_Table) {
    arena_release(pt.arena)
    pt.arena = arena_new()
    pt.blocks, pt.starts = nil, nil
    clear(&pt.pieces)
    clear(&pt.spare)
    clear(&pt.segs)
    pt.tail, pt.tail_used, pt.size, pt.lines = -1, 0, 0, 0
}

// -1 at or past the end.
@(private = "file")
piece_at :: proc(pieces: []Piece, off: int) -> int {
    lo, hi := 0, len(pieces)
    for lo < hi {
        mid := (lo + hi) / 2
        if pieces[mid].doc_off + pieces[mid].len <= off {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo < len(pieces) ? lo : -1
}

// Both ends into [floor, size], `hi` never behind `lo`.
@(private = "file")
splice_clamp :: proc(e: Splice, floor, size: int) -> (lo, hi: int) {
    lo = clamp(e.lo, floor, size)
    hi = clamp(e.hi, lo, size)
    return
}

// `pi` holds `cur`, so both walks only go forwards.
@(private = "file")
Rebuild :: struct {
    pt:    ^Piece_Table,
    out:   ^[dynamic]Piece,
    pi:    int, // the old piece `cur` sits in
    cur:   int, // the old offset reached
    shift: int, // where an old byte lands, minus where it was
}

@(private = "file")
rb_carry :: proc(r: ^Rebuild, to: int) {
    for r.cur < to {
        p := r.pt.pieces[r.pi]
        off := r.cur - p.doc_off
        take := min(p.len - off, to - r.cur)
        append(r.out, Piece{p.block, p.off + off, take, r.cur + r.shift})
        r.cur += take
        r.pt.touched += 1
        if r.cur == p.doc_off + p.len {
            r.pi += 1
        }
    }
}

// The same walk, emitting nothing.
@(private = "file")
rb_drop :: proc(r: ^Rebuild, to: int) {
    for r.cur < to {
        p := r.pt.pieces[r.pi]
        end := p.doc_off + p.len
        r.pt.touched += 1
        if end > to {
            r.cur = to
            return
        }
        r.cur = end
        r.pi += 1
    }
}

@(private = "file")
pt_rebuild :: proc(pt: ^Piece_Table, edits: []Splice) {
    r := Rebuild {
        pt  = pt,
        out = &pt.spare,
    }
    clear(r.out)
    for e in edits {
        lo, hi := splice_clamp(e, r.cur, pt.size)
        rb_carry(&r, lo)
        if len(e.text) > 0 {
            block, off := pt_append(pt, e.text)
            append(r.out, Piece{block, off, len(e.text), lo + r.shift})
            r.shift += len(e.text)
        }
        rb_drop(&r, hi)
        r.shift -= hi - lo
    }
    rb_carry(&r, pt.size)
    pt.pieces, pt.spare = pt.spare, pt.pieces
    pt.size += r.shift
}

// Extends the piece ending at `at` when its bytes also end at the append cursor. The new bytes
// land past `tail_used`, which no snapshot reaches.
@(private = "file")
pt_extend_tail :: proc(pt: ^Piece_Table, at: int, text: []u8) -> bool {
    if at == 0 || pt.tail < 0 {
        return false
    }
    i := piece_at(pt.pieces[:], at - 1)
    if i < 0 {
        return false
    }
    p := &pt.pieces[i]
    if p.doc_off + p.len != at || p.block != pt.tail || p.off + p.len != pt.tail_used {
        return false
    }
    if pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        return false
    }
    copy(pt.blocks[pt.tail][pt.tail_used:], text)
    pt.tail_used += len(text)
    p.len += len(text)
    for k in i + 1 ..< len(pt.pieces) {
        pt.pieces[k].doc_off += len(text)
        pt.touched += 1
    }
    return true
}

// A written chunk never grows or moves, since a snapshot may read it.
@(private = "file")
pt_append :: proc(pt: ^Piece_Table, text: []u8) -> (block, off: int) {
    if pt.tail < 0 || pt.tail_used + len(text) > len(pt.blocks[pt.tail]) {
        push_block(pt, make([]u8, max(PT_CHUNK, len(text))))
        pt.tail, pt.tail_used = len(pt.blocks) - 1, 0
    }
    off = pt.tail_used
    copy(pt.blocks[pt.tail][off:], text)
    pt.tail_used += len(text)
    return pt.tail, off
}

// Rebuilds only the lines the replacement straddles. Called before the pieces move, while the
// old index still describes the same document.
@(private = "file")
pt_splice_lines :: proc(pt: ^Piece_Table, a, b: int, text: []u8, delta: int) {
    first := text_line_at_off(pt, a)
    last := text_line_at_off(pt, b)

    // New starts are absolute, so they get a zero delta.
    at := len(pt.starts)
    n := 0
    for c, i in text {
        if c == '\n' {
            push_starts(pt, a + i + 1)
            n += 1
        }
    }

    seg_split(pt, first + 1)
    seg_split(pt, last + 1)
    lo, hi := seg_bound(pt, first + 1), seg_bound(pt, last + 1)
    if n > 0 {
        fresh := Line_Seg{first + 1, at, n, 0}
        if hi > lo {
            pt.segs[lo] = fresh
            remove_range(&pt.segs, lo + 1, hi)
        } else {
            inject_at(&pt.segs, lo, fresh)
        }
        lo += 1
    } else if hi > lo {
        remove_range(&pt.segs, lo, hi)
    }

    // Everything after the splice shifts by one add per segment, not per line.
    line := first + 1 + n
    for i in lo ..< len(pt.segs) {
        pt.segs[i].first = line
        pt.segs[i].delta += delta
        line += pt.segs[i].n
    }
    pt.lines = line
    if len(pt.segs) > PT_COMPACT_SEGS {
        lines_compact(pt)
    }
}

// --- the line index ---

// The pool is append-only, so a snapshot holding it is untouched.
@(private = "file")
lines_set :: proc(pt: ^Piece_Table, starts: []int) {
    at := len(pt.starts)
    push_starts(pt, ..starts)
    clear(&pt.segs)
    append(&pt.segs, Line_Seg{0, at, len(starts), 0})
    pt.lines = len(starts)
}

// Only while the last segment runs to the end of the pool, as during a load.
@(private = "file")
lines_push :: proc(pt: ^Piece_Table, start: int) {
    push_starts(pt, start)
    pt.segs[len(pt.segs) - 1].n += 1
    pt.lines += 1
}

// -1 only for an empty index.
@(private = "file")
seg_at_line :: proc(t: ^Text, line: int) -> int {
    lo, hi := 0, len(t.segs)
    for lo < hi {
        mid := (lo + hi) / 2
        if t.segs[mid].first <= line {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo - 1
}

// First segment starting at or after `line`: an insertion point.
@(private = "file")
seg_bound :: proc(t: ^Text, line: int) -> int {
    for s, i in t.segs {
        if s.first >= line {
            return i
        }
    }
    return len(t.segs)
}

// Splits the segment that straddles `line`. A no-op on a boundary, so typing adds one segment.
@(private = "file")
seg_split :: proc(t: ^Text, line: int) {
    i := seg_at_line(t, line)
    if i < 0 {
        return
    }
    s := t.segs[i]
    if line <= s.first || line >= s.first + s.n {
        return
    }
    take := line - s.first
    t.segs[i].n = take
    inject_at(&t.segs, i + 1, Line_Seg{line, s.at + take, s.n - take, s.delta})
}

// A batch flattens the index in one O(lines) pass: the incremental path would re-base every
// segment after each of N cuts.
@(private = "file")
lines_rebuild :: proc(pt: ^Piece_Table, edits: []Splice) {
    flat := make([dynamic]int, 0, pt.lines, context.temp_allocator)
    line := 0 // the next old line to carry
    cum := 0 // the byte delta of the edits already folded in
    prev := 0
    for e in edits {
        lo, hi := splice_clamp(e, prev, pt.size)
        prev = hi
        first, last := text_line_at_off(pt, lo), text_line_at_off(pt, hi)
        for ; line <= first; line += 1 {
            append(&flat, text_line_start(pt, line) + cum)
        }
        for c, i in e.text {
            if c == '\n' {
                append(&flat, lo + cum + i + 1)
            }
        }
        line = last + 1 // the lines the replacement straddles go with it
        cum += len(e.text) - (hi - lo)
    }
    for ; line < pt.lines; line += 1 {
        append(&flat, text_line_start(pt, line) + cum)
    }
    lines_set(pt, flat[:])
}

// The old starts stay as arena garbage: the read path has no lock. pt_should_compact watches it.
@(private = "file")
lines_compact :: proc(pt: ^Piece_Table) {
    flat := make([]int, pt.lines)
    defer delete(flat)
    at := 0
    for s in pt.segs {
        for k in 0 ..< s.n {
            flat[at] = pt.starts[s.at + k] + s.delta
            at += 1
        }
    }
    lines_set(pt, flat)
}
