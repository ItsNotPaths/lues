package docs

import "core:slice"

// Writes queue and store_drain applies them, so gen moves at one place.

Id :: struct {
    slot: u32,
    seq:  u32,
}

Store :: struct {
    slots:   [dynamic]Slot,
    free:    [dynamic]u32,
    pending: [dynamic]Txn,
    landed:  [dynamic]u64, // tags the last drain applied
    tag:     u64,
}

Slot :: struct {
    seq:   u32,
    doc:   ^Doc, // nil = closed; on the heap so a growing `slots` never moves it
    seen:         u64, // highest gen store_check saw
    spans:        [dynamic]Bucket,
    spans_reader: Reader,
}

// Splices, spans and side data land together at one gen, or not at all.
Txn :: struct {
    id:      Id,
    gen:     u64,
    tag:     u64,
    splices: []Splice, // owned
    spans:   Maybe(Spans), // owned; nil = leave every publisher's runs
    side:    rawptr, // the app's; handed to Land either way
    history: History,
}

Land :: #type proc(user: rawptr, id: Id, side: rawptr, landed: bool)

store_destroy :: proc(s: ^Store, land: Land, user: rawptr) {
    for &slot in s.slots {
        if slot.doc != nil {
            doc_destroy(slot.doc)
            free(slot.doc)
        }
        for b in slot.spans {
            delete(b.list)
        }
        delete(slot.spans)
    }
    for t in s.pending {
        txn_destroy(t, land, user, false)
    }
    delete(s.slots)
    delete(s.free)
    delete(s.pending)
    delete(s.landed)
    s^ = {}
}

store_open :: proc(s: ^Store, data: []u8 = nil) -> Id {
    i: u32
    if len(s.free) > 0 {
        i = pop(&s.free)
    } else {
        i = u32(len(s.slots))
        append(&s.slots, Slot{})
    }
    slot := &s.slots[i]
    slot.doc = new(Doc)
    doc_init(slot.doc, data)
    slot.spans_reader = reader_add(slot.doc)
    slot.seen = 0
    return {i, slot.seq}
}

// Every Id for this document stops resolving. A snapshot someone holds outlives it.
store_close :: proc(s: ^Store, id: Id) -> bool {
    slot := store_resolve(s, id) or_return
    doc_destroy(slot.doc)
    free(slot.doc)
    for b in slot.spans {
        delete(b.list)
    }
    clear(&slot.spans)
    slot.doc = nil
    slot.seq += 1
    append(&s.free, id.slot)
    return true
}

store_resolve :: proc(s: ^Store, id: Id) -> (^Slot, bool) {
    if int(id.slot) >= len(s.slots) {
        return nil, false
    }
    slot := &s.slots[id.slot]
    if slot.doc == nil || slot.seq != id.seq {
        return nil, false
    }
    return slot, true
}

store_doc :: proc(s: ^Store, id: Id) -> ^Doc {
    slot, ok := store_resolve(s, id)
    return ok ? slot.doc : nil
}

store_gen :: proc(s: ^Store, id: Id) -> (gen: u64, ok: bool) {
    slot := store_resolve(s, id) or_return
    return slot.doc.gen, true
}

// Slot order.
store_ids :: proc(s: ^Store, alloc := context.temp_allocator) -> []Id {
    out := make([dynamic]Id, 0, len(s.slots), alloc)
    for slot, i in s.slots {
        if slot.doc != nil {
            append(&out, Id{u32(i), slot.seq})
        }
    }
    return out[:]
}

// Valid until the next drain.
store_landed :: proc(s: ^Store) -> []u64 {
    return s.landed[:]
}

// Copies the splices and runs. `side` reaches the drain's Land either way. The tag is
// named by store_landed once it lands.
store_submit :: proc(s: ^Store, id: Id, gen: u64, splices: []Splice, spans: Maybe(Spans) = nil,
                     side: rawptr = nil, history := History.Step) -> (tag: u64) {
    owned := make([]Splice, len(splices))
    for e, i in splices {
        owned[i] = e
        owned[i].text = slice.clone(e.text)
    }
    kept := spans
    if pub, publishing := spans.?; publishing {
        pub.list = slice.clone(pub.list)
        kept = pub
    }
    s.tag += 1
    append(&s.pending, Txn{id = id, gen = gen, tag = s.tag, splices = owned, spans = kept,
                           side = side, history = history})
    return s.tag
}

// A transaction whose doc moved since its author read it is dropped whole.
store_drain :: proc(s: ^Store, land: Land, user: rawptr) -> (applied, stale: int) {
    clear(&s.landed)
    for t in s.pending {
        slot, ok := store_resolve(s, t.id)
        if !ok || slot.doc.gen != t.gen {
            txn_destroy(t, land, user, false)
            stale += 1
            continue
        }
        doc_apply(slot.doc, t.splices, t.history)
        if pub, publishing := t.spans.?; publishing {
            spans_apply(slot, pub)
        }
        txn_destroy(t, land, user, true)
        append(&s.landed, t.tag)
        applied += 1
    }
    clear(&s.pending)
    for &slot in s.slots {
        spans_follow(&slot)
        if slot.doc != nil {
            doc_maintain(slot.doc)
        }
    }
    return
}

// Runs after every dispatch: each open doc is intact and its gen never went backwards.
store_check :: proc(s: ^Store) -> bool {
    for &slot in s.slots {
        if slot.doc == nil {
            continue
        }
        if !doc_check(slot.doc) || slot.doc.gen < slot.seen {
            return false
        }
        slot.seen = slot.doc.gen
    }
    return true
}

@(private = "file")
txn_destroy :: proc(t: Txn, land: Land, user: rawptr, landed: bool) {
    for e in t.splices {
        delete(e.text)
    }
    delete(t.splices)
    if pub, publishing := t.spans.?; publishing {
        delete(pub.list)
    }
    if t.side != nil && land != nil {
        land(user, t.id, t.side, landed)
    }
}
