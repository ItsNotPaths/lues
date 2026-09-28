package docs

import "core:slice"

// Runs are flat, sorted and non-overlapping within a bucket, and move with the bytes.

Producer :: distinct u16

Chan :: enum u8 {
    Fg,
    Bg,
    Attrs,
}
Chans :: distinct bit_set[Chan; u8]

// `set` says which of fg, bg and attrs this run paints; the rest come from the layer below.
Span_Run :: struct {
    lo, hi: int,
    fg, bg: u32,
    attrs:  u8,
    set:    Chans,
}

Spans :: struct {
    who:    Producer,
    lo, hi: int,
    list:   []Span_Run,
}

// Per producer per document; past it a publish is refused whole.
SPAN_MAX :: 1 << 14

Bucket :: struct {
    who:  Producer,
    list: [dynamic]Span_Run,
}

// A run across an edge is clipped, not dropped. False past SPAN_MAX.
spans_apply :: proc(slot: ^Slot, pub: Spans) -> bool {
    if pub.hi < pub.lo {
        return false
    }
    // `pub` is against the bytes as they are now, so the stored runs catch up first.
    spans_follow(slot)
    fresh := spans_clean(pub.list, pub.lo, pub.hi)
    b := bucket_for(slot, pub.who)
    // Below, then the range, then above: sorted by construction.
    out := make([dynamic]Span_Run, 0, len(b.list) + len(fresh), context.temp_allocator)
    for old in b.list {
        if old.lo < pub.lo {
            append(&out, span_cut(old, old.lo, min(old.hi, pub.lo)))
        }
    }
    append(&out, ..fresh)
    for old in b.list {
        if old.hi > pub.hi {
            append(&out, span_cut(old, max(old.lo, pub.hi), old.hi))
        }
    }
    if len(out) > SPAN_MAX {
        return false
    }
    clear(&b.list)
    append(&b.list, ..out[:])
    return true
}

// Text typed at a boundary joins the run ending there, so touching runs never overlap.
// A lost log drops every run: wrong colour is worse than none.
spans_follow :: proc(slot: ^Slot) {
    if slot.doc == nil {
        return
    }
    changes, lost := changes_since(slot.doc, slot.spans_reader)
    if len(changes) == 0 && !lost {
        return
    }
    // Acked with nothing to carry too, or a doc with no runs starts every publish behind.
    defer changes_ack(slot.doc, slot.spans_reader)
    for &b in slot.spans {
        if lost {
            clear(&b.list)
            continue
        }
        kept := 0
        for sp in b.list {
            moved := sp
            for ch in changes {
                moved.lo = off_shift(moved.lo, ch, low = false)
                moved.hi = off_shift(moved.hi, ch, low = false)
            }
            if moved.hi > moved.lo {
                b.list[kept] = moved
                kept += 1
            }
        }
        resize(&b.list, kept)
    }
}

// Later in `order` wins per channel. A producer `order` does not name is not read.
spans_read :: proc(s: ^Store, id: Id, lo, hi: int, order: []Producer,
                   alloc := context.temp_allocator) -> []Span_Run {
    slot, ok := store_resolve(s, id)
    if !ok || hi <= lo {
        return nil
    }
    spans_follow(slot)
    merged: []Span_Run
    for who in order {
        for &b in slot.spans {
            if b.who == who {
                merged = spans_overlay(merged, spans_clip(b.list[:], lo, hi))
            }
        }
    }
    return slice.clone(merged, alloc)
}

spans_forget :: proc(s: ^Store, who: Producer) {
    for &slot in s.slots {
        for &b in slot.spans {
            if b.who == who {
                clear(&b.list)
            }
        }
    }
}

// --- internals ---

@(private = "file")
bucket_for :: proc(slot: ^Slot, who: Producer) -> ^Bucket {
    for &b in slot.spans {
        if b.who == who {
            return &b
        }
    }
    append(&slot.spans, Bucket{who = who})
    return &slot.spans[len(slot.spans) - 1]
}

// Plugin input: clipped, sorted, an overlap won by the first start, empty runs dropped.
@(private = "file")
spans_clean :: proc(list: []Span_Run, lo, hi: int) -> []Span_Run {
    out := make([dynamic]Span_Run, 0, len(list), context.temp_allocator)
    for sp in list {
        a, b := max(sp.lo, lo), min(sp.hi, hi)
        if a < b && sp.set != {} {
            append(&out, span_cut(sp, a, b))
        }
    }
    slice.sort_by(out[:], proc(x, y: Span_Run) -> bool {return x.lo < y.lo})
    at := 0
    for sp in out {
        if at > 0 && sp.lo < out[at - 1].hi {
            continue
        }
        out[at] = sp
        at += 1
    }
    return out[:at]
}

@(private = "file")
span_cut :: proc(sp: Span_Run, lo, hi: int) -> Span_Run {
    out := sp
    out.lo, out.hi = lo, hi
    return out
}

@(private = "file")
spans_clip :: proc(list: []Span_Run, lo, hi: int) -> []Span_Run {
    at, _ := slice.binary_search_by(list, lo, proc(sp: Span_Run, key: int) -> slice.Ordering {
        return .Less if sp.hi <= key else .Greater
    })
    out := make([dynamic]Span_Run, 0, 64, context.temp_allocator)
    for i := at; i < len(list) && list[i].lo < hi; i += 1 {
        a, b := max(list[i].lo, lo), min(list[i].hi, hi)
        if a < b {
            append(&out, span_cut(list[i], a, b))
        }
    }
    return out[:]
}

// Top wins per channel per byte; what top leaves unset comes from base.
@(private = "file")
spans_overlay :: proc(base, top: []Span_Run) -> []Span_Run {
    if len(top) == 0 {
        return base
    }
    if len(base) == 0 {
        return top
    }
    out := make([dynamic]Span_Run, 0, len(base) + len(top), context.temp_allocator)
    i, j := 0, 0
    at := min(base[0].lo, top[0].lo)
    for i < len(base) || j < len(top) {
        i = span_seek(base, i, at)
        j = span_seek(top, j, at)
        b, hold_b := span_at(base, i, at)
        t, hold_t := span_at(top, j, at)
        end := min(hold_b ? b.hi : span_next(base, i, at), hold_t ? t.hi : span_next(top, j, at))
        if end == max(int) {
            break
        }
        if hold_b || hold_t {
            run := span_merge(b, t, hold_b, hold_t)
            run.lo, run.hi = at, end
            spans_push(&out, run)
        }
        at = end
    }
    return out[:]
}

// The first run not wholly behind `at`.
@(private = "file")
span_seek :: proc(list: []Span_Run, from, at: int) -> int {
    i := from
    for i < len(list) && list[i].hi <= at {
        i += 1
    }
    return i
}

@(private = "file")
span_at :: proc(list: []Span_Run, i, at: int) -> (sp: Span_Run, held: bool) {
    if i < len(list) && list[i].lo <= at && at < list[i].hi {
        return list[i], true
    }
    return {}, false
}

// Where this list next starts a run, or max(int).
@(private = "file")
span_next :: proc(list: []Span_Run, i, at: int) -> int {
    return i < len(list) && list[i].lo > at ? list[i].lo : max(int)
}

@(private = "file")
span_merge :: proc(base, top: Span_Run, hold_b, hold_t: bool) -> (out: Span_Run) {
    if hold_b {
        out = base
    }
    if !hold_t {
        return out
    }
    if .Fg in top.set {
        out.fg = top.fg
    }
    if .Bg in top.set {
        out.bg = top.bg
    }
    if .Attrs in top.set {
        out.attrs = top.attrs
    }
    out.set |= top.set
    return out
}

@(private = "file")
spans_push :: proc(out: ^[dynamic]Span_Run, run: Span_Run) {
    if len(out) > 0 {
        last := &out[len(out) - 1]
        if last.hi == run.lo && last.fg == run.fg && last.bg == run.bg &&
           last.attrs == run.attrs && last.set == run.set {
            last.hi = run.hi
            return
        }
    }
    append(out, run)
}
