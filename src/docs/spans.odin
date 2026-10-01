package docs

import "core:slice"
import "core:strings"
import "../pt"

// A bucket is sorted by `lo`; its runs of one key are flat and do not overlap. Runs move with
// the bytes.

Producer :: distinct u16

// 0 is a look. Any other key is a name the app interned, and the run is data.
Key :: distinct u16

Chan :: enum u8 {
    Fg,
    Bg,
    Attrs,
}
Chans :: distinct bit_set[Chan; u8]

// `set` says which of fg, bg and attrs a look paints; the rest come from the layer below. A data
// run paints nothing, and `text` is its value: empty means its own bytes.
Span_Run :: struct {
    lo, hi: int,
    fg, bg: u32,
    attrs:  u8,
    set:    Chans,
    key:    Key,
    open:   bool, // text typed at `lo` joins the run, as it always does at `hi`
    text:   string, // owned by whoever holds the run
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
    // Cut pieces share their old run's text, so every text is copied and the old list goes whole.
    for &run in out {
        if run.text != "" {
            run.text = strings.clone(run.text, b.list.allocator)
        }
    }
    bucket_clear(b)
    append(&b.list, ..out[:])
    return true
}

// Text typed at a boundary joins the run ending there, unless the run starting there is open.
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
            bucket_clear(&b)
            continue
        }
        for &sp in b.list {
            for ch in changes {
                sp.lo = off_shift(sp.lo, ch, low = sp.open)
                sp.hi = off_shift(sp.hi, ch, low = false)
            }
        }
        bucket_settle(&b)
    }
}

// Later in `order` wins per key, and per channel within a look. A producer `order` does not name
// is not read. Runs of different keys may overlap; the list is sorted by `lo`.
spans_read :: proc(s: ^Store, id: Id, lo, hi: int, order: []Producer,
                   alloc := context.temp_allocator) -> []Span_Run {
    context.allocator = pt.kept(&s.alloc)
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
    out := slice.clone(merged, alloc)
    for &run in out {
        if run.text != "" {
            run.text = strings.clone(run.text, alloc)
        }
    }
    return out
}

spans_forget :: proc(s: ^Store, who: Producer) {
    context.allocator = pt.kept(&s.alloc)
    for &slot in s.slots {
        for &b in slot.spans {
            if b.who == who {
                bucket_clear(&b)
            }
        }
    }
}

// Frees the texts too. The list keeps its memory.
bucket_clear :: proc(b: ^Bucket) {
    for run in b.list {
        delete(run.text, b.list.allocator)
    }
    clear(&b.list)
}

// --- internals ---

@(private = "file")
bucket_for :: proc(slot: ^Slot, who: Producer) -> ^Bucket {
    for &b in slot.spans {
        if b.who == who {
            return &b
        }
    }
    // The texts go where the list goes, whoever's context the first publish ran in.
    append(&slot.spans, Bucket{who = who, list = make([dynamic]Span_Run)})
    return &slot.spans[len(slot.spans) - 1]
}

// After a follow: text typed between two runs of one key goes to the open one, and what an edit
// emptied is dropped.
@(private = "file")
bucket_settle :: proc(b: ^Bucket) {
    last := make([dynamic]Key_At, 0, 4, context.temp_allocator)
    for &sp, i in b.list {
        if j := key_at(last[:], sp.key); j >= 0 {
            prev := &b.list[last[j].at]
            prev.hi = min(prev.hi, sp.lo)
            last[j].at = i
        } else {
            append(&last, Key_At{sp.key, i})
        }
    }
    kept := 0
    for sp in b.list {
        if sp.hi > sp.lo {
            b.list[kept] = sp
            kept += 1
        } else {
            delete(sp.text, b.list.allocator)
        }
    }
    resize(&b.list, kept)
}

// The last run of each key seen so far. A bucket holds few keys, so a list beats a map.
@(private = "file")
Key_At :: struct {
    key: Key,
    at:  int,
}

@(private = "file")
key_at :: proc(list: []Key_At, key: Key) -> int {
    for k, i in list {
        if k.key == key {
            return i
        }
    }
    return -1
}

// Plugin input: clipped, sorted, an overlap within one key won by the first start, and a look
// that paints nothing dropped.
@(private = "file")
spans_clean :: proc(list: []Span_Run, lo, hi: int) -> []Span_Run {
    out := make([dynamic]Span_Run, 0, len(list), context.temp_allocator)
    for sp in list {
        a, b := max(sp.lo, lo), min(sp.hi, hi)
        if a < b && (sp.set != {} || sp.key != 0) {
            append(&out, span_cut(sp, a, b))
        }
    }
    slice.stable_sort_by(out[:], proc(x, y: Span_Run) -> bool {return x.lo < y.lo})
    ends := make([dynamic]Key_At, 0, 4, context.temp_allocator) // `at` is the key's last end
    at := 0
    for sp in out {
        j := key_at(ends[:], sp.key)
        if j >= 0 && sp.lo < ends[j].at {
            continue
        }
        if j >= 0 {
            ends[j].at = sp.hi
        } else {
            append(&ends, Key_At{sp.key, sp.hi})
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

// Top wins per key per byte; within a look, per channel, and what top leaves unset comes from
// base. One key, the usual case, is one pass.
@(private = "file")
spans_overlay :: proc(base, top: []Span_Run) -> []Span_Run {
    if len(top) == 0 {
        return base
    }
    if len(base) == 0 {
        return top
    }
    keys := make([dynamic]Key, 0, 4, context.temp_allocator)
    for list in ([2][]Span_Run{base, top}) {
        for sp in list {
            if !slice.contains(keys[:], sp.key) {
                append(&keys, sp.key)
            }
        }
    }
    if len(keys) == 1 {
        return key_overlay(base, top)
    }
    out := make([dynamic]Span_Run, 0, len(base) + len(top), context.temp_allocator)
    for k in keys {
        append(&out, ..key_overlay(only(base, k), only(top, k)))
    }
    slice.stable_sort_by(out[:], proc(x, y: Span_Run) -> bool {return x.lo < y.lo})
    return out[:]
}

@(private = "file")
only :: proc(list: []Span_Run, key: Key) -> []Span_Run {
    out := make([dynamic]Span_Run, 0, len(list), context.temp_allocator)
    for sp in list {
        if sp.key == key {
            append(&out, sp)
        }
    }
    return out[:]
}

// Both lists flat and of one key.
@(private = "file")
key_overlay :: proc(base, top: []Span_Run) -> []Span_Run {
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
    if top.key != 0 {
        return top
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
           last.attrs == run.attrs && last.set == run.set && last.key == run.key &&
           last.open == run.open && last.text == run.text {
            last.hi = run.hi
            return
        }
    }
    append(out, run)
}
