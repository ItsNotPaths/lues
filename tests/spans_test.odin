package tests

import "core:testing"
import "../src/docs"

@(private = "file")
run :: proc(lo, hi: int, fg: u32, set := docs.Chans{.Fg}) -> docs.Span_Run {
    return {lo = lo, hi = hi, fg = fg, set = set}
}

@(private = "file")
open :: proc(s: ^docs.Store, text: string) -> (docs.Id, ^docs.Slot) {
    id := docs.store_open(s, transmute([]u8)text)
    slot, _ := docs.store_resolve(s, id)
    return id, slot
}

@(test)
spans_apply_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id, slot := open(&s, "0123456789")

    testing.expect(t, docs.spans_apply(slot, {1, 0, 10, {run(0, 4, 1), run(6, 10, 2)}}))
    testing.expect(t, docs.spans_apply(slot, {1, 3, 7, {run(4, 6, 3), run(0, 9, 9)}}))
    got := docs.spans_read(&s, id, 0, 10, {1})
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[0], run(0, 3, 1))
    testing.expect_value(t, got[1], run(3, 7, 9)) // the first start wins
    testing.expect_value(t, got[2], run(7, 10, 2))

    docs.spans_apply(slot, {1, 0, 10, {run(0, 5, 7, {})}})
    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 10, {1})), 0)
    testing.expect(t, !docs.spans_apply(slot, {1, 5, 4, nil}))
}

@(test)
spans_follow_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id, slot := open(&s, "aaaa bbbb")
    docs.spans_apply(slot, {1, 0, 9, {run(0, 4, 1), run(5, 9, 2)}})

    // Typed at the end of the first run: it grows. Typed before the second: it moves.
    docs.doc_apply(slot.doc, {{4, 4, transmute([]u8)string("XX"), 0}})
    got := docs.spans_read(&s, id, 0, 20, {1})
    testing.expect_value(t, got[0], run(0, 6, 1))
    testing.expect_value(t, got[1], run(7, 11, 2))

    docs.doc_apply(slot.doc, {{7, 11, nil, 0}})
    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 20, {1})), 1)

    docs.doc_set(slot.doc, transmute([]u8)string("fresh"))
    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 20, {1})), 0)
}

@(test)
spans_overlay_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id, slot := open(&s, "0123456789")
    docs.spans_apply(slot, {1, 0, 10, {run(0, 10, 1)}})
    docs.spans_apply(slot, {2, 0, 10, {{lo = 2, hi = 4, bg = 5, set = {.Bg}}}})

    got := docs.spans_read(&s, id, 0, 10, {1, 2})
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[1], docs.Span_Run{lo = 2, hi = 4, fg = 1, bg = 5, set = {.Fg, .Bg}})

    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 10, {2})), 1)
    docs.spans_forget(&s, 2)
    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 10, {1, 2})), 1)
}

@(test)
spans_cap_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    _, slot := open(&s, "")
    many := make([]docs.Span_Run, docs.SPAN_MAX + 1, context.temp_allocator)
    for &r, i in many {
        r = run(i, i + 1, 1)
    }
    testing.expect(t, !docs.spans_apply(slot, {1, 0, len(many), many}))
    testing.expect(t, docs.spans_apply(slot, {1, 0, len(many), many[:docs.SPAN_MAX]}))
}

@(test)
spans_publish_after_edit_test :: proc(t: ^testing.T) {
    s: docs.Store
    defer docs.store_destroy(&s, nil, nil)
    id, slot := open(&s, "abc")

    // The first publish after edits on a doc with no runs is not taken for a lost log.
    for _ in 0 ..< docs.DOC_CHANGE_MAX + 1 {
        docs.store_submit(&s, id, slot.doc.gen, {{0, 0, transmute([]u8)string("x"), 0}})
        docs.store_drain(&s, nil, nil)
    }
    docs.spans_apply(slot, {1, 0, 3, {run(0, 3, 1)}})
    testing.expect_value(t, len(docs.spans_read(&s, id, 0, 3, {1})), 1)
}
