package tests

import "core:testing"
import "../src/docs"
import "../src/pt"

@(test)
store_slots_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)

    a := docs.store_open(&s, transmute([]u8)string("a"))
    b := docs.store_open(&s)
    testing.expect_value(t, len(docs.store_ids(&s)), 2)

    testing.expect(t, docs.store_close(&s, a))
    testing.expect(t, !docs.store_close(&s, a))
    c := docs.store_open(&s)
    testing.expect_value(t, c.slot, a.slot)
    testing.expect(t, docs.store_doc(&s, a) == nil)
    testing.expect(t, docs.store_doc(&s, c) != nil)
    _, ok := docs.store_gen(&s, a)
    testing.expect(t, !ok)

    testing.expect(t, docs.store_doc(&s, {99, 0}) == nil)
    testing.expect(t, docs.store_doc(&s, b) != nil)
}

@(test)
store_submit_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id := docs.store_open(&s)

    // Copied at the call, so the caller's buffer may die.
    buf := [3]u8{'a', 'b', 'c'}
    tag := docs.store_submit(&s, id, 0, {{0, 0, buf[:], 7}})
    buf[0] = 'X'
    docs.store_drain(&s, nil, nil)
    testing.expect_value(t, docs.store_landed(&s)[0], tag)
    d := docs.store_doc(&s, id)
    testing.expect_value(t, string(pt.text_read(&d.table, 0, 3, context.temp_allocator)), "abc")
}

@(test)
store_check_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id := docs.store_open(&s)
    testing.expect(t, docs.store_check(&s))

    d := docs.store_doc(&s, id)
    d.gen = 5
    testing.expect(t, docs.store_check(&s))
    d.gen = 4 // a gen that went backwards is corruption
    testing.expect(t, !docs.store_check(&s))
    d.gen = 5
    d.magic = 0
    testing.expect(t, !docs.store_check(&s))
    d.magic = docs.DOC_MAGIC
}

@(test)
store_destroy_lands_test :: proc(t: ^testing.T) {
    Seen :: struct {
        calls:  int,
        landed: bool,
    }
    seen: Seen
    land :: proc(user: rawptr, id: docs.Id, side: rawptr, landed: bool) {
        s := (^Seen)(user)
        s.calls += 1
        s.landed = landed
    }

    s: docs.Store
    id := docs.store_open(&s)
    side := 1
    docs.store_submit(&s, id, 0, nil, side = &side)
    docs.store_submit(&s, id, 0, nil)
    docs.store_destroy(&s, land, &seen)

    testing.expect_value(t, seen.calls, 1)
    testing.expect(t, !seen.landed)
}

@(test)
store_drain_test :: proc(t: ^testing.T) {
    Lands :: struct {
        landed, dropped: int,
    }
    lands: Lands
    land :: proc(user: rawptr, id: docs.Id, side: rawptr, landed: bool) {
        l := (^Lands)(user)
        if landed {
            l.landed += 1
        } else {
            l.dropped += 1
        }
    }

    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id := docs.store_open(&s, transmute([]u8)string("abc"))
    side := 1

    // Both read gen 0: the first lands, the second is dropped whole, spans too.
    first := docs.store_submit(&s, id, 0, {{3, 3, transmute([]u8)string("d"), 0}}, side = &side,
                               spans = docs.Spans{1, 0, 4, {{lo = 3, hi = 4, fg = 7, set = {.Fg}}}})
    docs.store_submit(&s, id, 0, {{0, 0, transmute([]u8)string("X"), 0}}, side = &side,
                      spans = docs.Spans{2, 0, 1, {{lo = 0, hi = 1, fg = 8, set = {.Fg}}}})
    applied, stale := docs.store_drain(&s, land, &lands)
    testing.expect_value(t, applied, 1)
    testing.expect_value(t, stale, 1)
    testing.expect_value(t, lands, Lands{1, 1})
    testing.expect_value(t, len(docs.store_landed(&s)), 1)
    testing.expect_value(t, docs.store_landed(&s)[0], first)

    runs := docs.spans_read(&s, id, 0, 4, {1, 2})
    testing.expect_value(t, len(runs), 1)
    testing.expect_value(t, runs[0].lo, 3)
    gen, _ := docs.store_gen(&s, id)
    testing.expect_value(t, gen, 1)

    docs.store_submit(&s, id, 1, {{0, 0, transmute([]u8)string("Y"), 0}})
    docs.store_close(&s, id)
    reused := docs.store_open(&s)
    applied, stale = docs.store_drain(&s, nil, nil)
    testing.expect_value(t, stale, 1)
    testing.expect_value(t, docs.store_doc(&s, reused).table.size, 0)
}
