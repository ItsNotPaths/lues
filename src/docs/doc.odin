package docs

import "base:runtime"
import "core:bytes"
import "core:slice"
import "../pt"

DOC_MAGIC :: 0x6c75_6573_646f_6300 // "luesdoc\0"

Doc :: struct {
    magic:        u64, // first, so a wild store from a plugin is caught by doc_check
    table:        pt.Piece_Table,
    gen:          u64, // bumped on every change to the bytes
    snap:         ^pt.Snapshot,
    undo:         [dynamic]Step,
    redo:         [dynamic]Step,
    changes:      [dynamic]Change,
    changes_base: u64,
    changes_next: u64,
    seen:         [dynamic]u64, // per Reader
    side:         rawptr, // the app's per-doc data
    alloc:        runtime.Allocator, // everything it holds, whoever calls; set by doc_init
}

// [lo, hi) of the document as it arrived becomes `text`. `tag` is the app's.
Splice :: struct {
    lo, hi: int,
    text:   []u8,
    tag:    u32,
}

// Offsets and points, both against the document as it stood when the change landed.
Change :: struct {
    start, old_end, new_end:          int,
    start_pt, old_end_pt, new_end_pt: pt.Pos,
}

// Strings owned.
Op :: struct {
    at, inv_at:        int,
    removed, inserted: []u8,
}

// `before` and `after` are the app's bytes. Batches stay apart: each `inv_at` is against
// the document right after its batch.
Step :: struct {
    batches:       [dynamic][]Op, // owned
    before, after: []u8, // owned
}

History :: enum u8 {
    Step,
    Join,
    Forget, // nothing to undo, and the history goes
}

Reader :: distinct int

DOC_CHANGE_MAX :: 256
READER_FREE :: max(u64)
UNDO_MAX :: 1000

doc_init :: proc(d: ^Doc, data: []u8 = nil) {
    d.magic = DOC_MAGIC
    d.alloc = context.allocator
    pt.pt_init(&d.table)
    if len(data) > 0 {
        pt.pt_load(&d.table, data)
    }
}

doc_destroy :: proc(d: ^Doc) {
    context.allocator = pt.kept(&d.alloc)
    drop_snap(d)
    pt.pt_destroy(&d.table)
    doc_forget_undo(d)
    delete(d.undo)
    delete(d.redo)
    delete(d.changes)
    delete(d.seen)
    d^ = {}
}

// Nothing can follow a full replace, so the history goes and every reader rebuilds.
doc_set :: proc(d: ^Doc, data: []u8) {
    context.allocator = pt.kept(&d.alloc)
    doc_forget_undo(d)
    pt.pt_load(&d.table, data)
    changes_reset(d)
    bump(d)
}

// O(1): runs after every dispatch.
doc_check :: proc(d: ^Doc) -> bool {
    return d.magic == DOC_MAGIC && pt.text_check(&d.table)
}

// Edits are against the document as it arrived.
doc_apply :: proc(d: ^Doc, splices: []Splice, history := History.Step) -> (moved: bool) {
    context.allocator = pt.kept(&d.alloc)
    ops: [dynamic]Op
    moved = apply(d, splices, nil if history == .Forget else &ops)
    switch {
    case history == .Forget:
        doc_forget_undo(d)
    case !moved:
        delete(ops)
    case history == .Join && len(d.undo) > 0:
        clear_steps(&d.redo)
        append(&d.undo[len(d.undo) - 1].batches, ops[:])
    case:
        clear_steps(&d.redo)
        step: Step
        append(&step.batches, ops[:])
        append(&d.undo, step)
        for len(d.undo) > UNDO_MAX {
            step_destroy(&d.undo[0])
            ordered_remove(&d.undo, 0)
        }
    }
    return
}

// Answers the step, so the app restores Step.before; nil when empty. Valid until the next edit.
doc_undo :: proc(d: ^Doc) -> ^Step {
    context.allocator = pt.kept(&d.alloc)
    if len(d.undo) == 0 {
        return nil
    }
    step := pop(&d.undo)
    #reverse for batch in step.batches {
        back := make([]Splice, len(batch), context.temp_allocator)
        for op, i in batch {
            back[i] = {op.inv_at, op.inv_at + len(op.inserted), op.removed, 0}
        }
        apply(d, back, nil)
    }
    append(&d.redo, step)
    return &d.redo[len(d.redo) - 1]
}

// The app restores Step.after.
doc_redo :: proc(d: ^Doc) -> ^Step {
    context.allocator = pt.kept(&d.alloc)
    if len(d.redo) == 0 {
        return nil
    }
    step := pop(&d.redo)
    for batch in step.batches {
        fwd := make([]Splice, len(batch), context.temp_allocator)
        for op, i in batch {
            fwd[i] = {op.at, op.at + len(op.removed), op.inserted, 0}
        }
        apply(d, fwd, nil)
    }
    append(&d.undo, step)
    return &d.undo[len(d.undo) - 1]
}

doc_forget_undo :: proc(d: ^Doc) {
    context.allocator = pt.kept(&d.alloc)
    clear_steps(&d.undo)
    clear_steps(&d.redo)
}

// A new reader starts caught up.
reader_add :: proc(d: ^Doc) -> Reader {
    context.allocator = pt.kept(&d.alloc)
    for v, i in d.seen {
        if v == READER_FREE {
            d.seen[i] = d.changes_next
            return Reader(i)
        }
    }
    append(&d.seen, d.changes_next)
    return Reader(len(d.seen) - 1)
}

reader_drop :: proc(d: ^Doc, r: Reader) {
    context.allocator = pt.kept(&d.alloc)
    d.seen[r] = READER_FREE
    trim(d)
}

// Oldest first. `lost`: the log no longer reaches back that far; rebuild from the document.
changes_since :: proc(d: ^Doc, r: Reader) -> (changes: []Change, lost: bool) {
    if d.seen[r] < d.changes_base {
        return nil, true
    }
    return d.changes[d.seen[r] - d.changes_base:], false
}

changes_ack :: proc(d: ^Doc, r: Reader) {
    context.allocator = pt.kept(&d.alloc)
    d.seen[r] = d.changes_next
    trim(d)
}

// `low` is a range's left edge: an insert exactly there joins the range. An offset inside
// the replaced text collapses onto its front.
off_shift :: proc(off: int, ch: Change, low: bool) -> int {
    if off >= ch.old_end && (!low || off > ch.start) {
        return off + ch.new_end - ch.old_end
    }
    if off > ch.start {
        return ch.start
    }
    return off
}

// On the change's last replaced line, the column rebases on the new end.
point_shift :: proc(p: pt.Pos, ch: Change, low: bool) -> pt.Pos {
    s, o, n := ch.start_pt, ch.old_end_pt, ch.new_end_pt
    if !pos_less(p, o) && (!low || pos_less(s, p)) {
        if p.line == o.line {
            return {n.line, n.col + p.col - o.col}
        }
        return {p.line + n.line - o.line, p.col}
    }
    if pos_less(s, p) {
        return s
    }
    return p
}

pos_less :: proc(a, b: pt.Pos) -> bool {
    return a.line != b.line ? a.line < b.line : a.col < b.col
}

// One more reference; release with pt.snapshot_release.
doc_snapshot :: proc(d: ^Doc) -> ^pt.Snapshot {
    context.allocator = pt.kept(&d.alloc)
    if d.snap == nil {
        d.snap = pt.snapshot_take(&d.table, d.gen)
    }
    pt.snapshot_retain(d.snap)
    return d.snap
}

// Drops the cached snapshot: it would pin the arena compaction replaced.
doc_maintain :: proc(d: ^Doc) {
    context.allocator = pt.kept(&d.alloc)
    if !pt.pt_should_compact(&d.table) {
        return
    }
    pt.pt_compact(&d.table)
    drop_snap(d)
}

// --- internals ---

// Non-nil `rec` gets the reversible ops.
@(private = "file")
apply :: proc(d: ^Doc, batch: []Splice, rec: ^[dynamic]Op) -> (moved: bool) {
    edits := fuse(batch, d.table.size)
    if len(edits) == 0 {
        return false
    }

    // Where each edit's text sits once the whole batch is in: the inverse reads the result.
    landed := make([]int, len(edits), context.temp_allocator)
    removed := make([][]u8, len(edits), context.temp_allocator)
    splices := make([]pt.Splice, len(edits), context.temp_allocator)
    cum := 0
    for e, i in edits {
        landed[i] = e.lo + cum
        cum += len(e.text) - (e.hi - e.lo)
        removed[i] = pt.text_read(&d.table, e.lo, e.hi, context.temp_allocator)
        splices[i] = {e.lo, e.hi, e.text}
    }

    // Back to front: each entry is against the document the ones before it landed on.
    log := make([]Change, len(edits), context.temp_allocator)
    for e, i in edits {
        start_pt := pt.text_pos(&d.table, e.lo)
        log[len(edits) - 1 - i] = {
            start      = e.lo,
            old_end    = e.hi,
            new_end    = e.lo + len(e.text),
            start_pt   = start_pt,
            old_end_pt = pt.text_pos(&d.table, e.hi),
            new_end_pt = pos_after(start_pt, e.text),
        }
    }

    pt.pt_splice_many(&d.table, splices)
    record_changes(d, log)
    if rec != nil {
        for e, i in edits {
            append(rec, Op{e.lo, landed[i], slice.clone(removed[i]), slice.clone(e.text)})
        }
    }
    bump(d)
    return true
}

// Clamped, sorted, overlaps fused, no-ops dropped. Temp-allocated.
@(private = "file")
fuse :: proc(batch: []Splice, size: int) -> []Splice {
    edits := make([dynamic]Splice, 0, len(batch), context.temp_allocator)
    for e in batch {
        lo := clamp(e.lo, 0, size)
        c := Splice{lo, clamp(e.hi, lo, size), e.text, e.tag}
        if c.lo != c.hi || len(c.text) > 0 {
            append(&edits, c)
        }
    }
    slice.sort_by(edits[:], proc(a, b: Splice) -> bool {
        return a.lo != b.lo ? a.lo < b.lo : a.hi < b.hi
    })
    w := 0
    for r in 1 ..< len(edits) {
        acc, e := &edits[w], edits[r]
        if e.lo < acc.hi {
            acc.hi = max(acc.hi, e.hi)
            acc.text = slice.concatenate([][]u8{acc.text, e.text}, context.temp_allocator)
            continue
        }
        w += 1
        edits[w] = e
    }
    return edits[:min(w + 1, len(edits))]
}

@(private = "file")
bump :: proc(d: ^Doc) {
    d.gen += 1
    drop_snap(d)
}

@(private = "file")
drop_snap :: proc(d: ^Doc) {
    if d.snap != nil {
        pt.snapshot_release(d.snap)
        d.snap = nil
    }
}

@(private = "file")
pos_after :: proc(at: pt.Pos, text: []u8) -> pt.Pos {
    nl := bytes.last_index_byte(text, '\n')
    if nl < 0 {
        return {at.line, at.col + len(text)}
    }
    return {at.line + bytes.count(text, {'\n'}), len(text) - nl - 1}
}

// A batch may run past DOC_CHANGE_MAX; the cap bounds the log between commits.
@(private = "file")
record_changes :: proc(d: ^Doc, batch: []Change) {
    if len(batch) == 0 {
        return
    }
    if len(d.changes) + len(batch) > DOC_CHANGE_MAX {
        changes_drop(d)
    }
    append(&d.changes, ..batch)
    d.changes_next += u64(len(batch))
}

@(private = "file")
trim :: proc(d: ^Doc) {
    slowest := d.changes_next
    for v in d.seen {
        slowest = min(slowest, v)
    }
    if slowest > d.changes_base {
        remove_range(&d.changes, 0, int(slowest - d.changes_base))
        d.changes_base = slowest
    }
}

// Readers behind are told they lost it; readers caught up are untouched.
@(private = "file")
changes_drop :: proc(d: ^Doc) {
    clear(&d.changes)
    d.changes_base = d.changes_next
}

@(private = "file")
changes_reset :: proc(d: ^Doc) {
    d.changes_next += 1
    changes_drop(d)
}

@(private = "file")
clear_steps :: proc(steps: ^[dynamic]Step) {
    for &st in steps {
        step_destroy(&st)
    }
    clear(steps)
}

@(private = "file")
step_destroy :: proc(st: ^Step) {
    for batch in st.batches {
        for op in batch {
            delete(op.removed)
            delete(op.inserted)
        }
        delete(batch)
    }
    delete(st.batches)
    delete(st.before)
    delete(st.after)
}
