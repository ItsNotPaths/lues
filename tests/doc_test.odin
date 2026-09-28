package tests

import "core:testing"
import "../src/docs"
import "../src/pt"

@(private = "file")
text :: proc(d: ^docs.Doc) -> string {
    return string(pt.text_read(&d.table, 0, d.table.size, context.temp_allocator))
}

@(private = "file")
sp :: proc(lo, hi: int, s: string) -> docs.Splice {
    return {lo, hi, transmute([]u8)s, 0}
}

@(test)
doc_life_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("ab\ncd"))
    defer docs.doc_destroy(&d)
    testing.expect(t, docs.doc_check(&d))
    testing.expect_value(t, text(&d), "ab\ncd")
    testing.expect_value(t, d.table.lines, 2)

    docs.doc_set(&d, transmute([]u8)string("x"))
    testing.expect_value(t, text(&d), "x")
    testing.expect_value(t, d.gen, 1)
}

@(test)
doc_apply_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("hello world"))
    defer docs.doc_destroy(&d)

    // Against the document as it arrived, out of order.
    moved := docs.doc_apply(&d, {sp(6, 11, "there"), sp(0, 5, "hi")})
    testing.expect(t, moved)
    testing.expect_value(t, text(&d), "hi there")
    testing.expect_value(t, d.gen, 1)
    testing.expect_value(t, len(d.changes), 2)

    testing.expect(t, !docs.doc_apply(&d, {sp(2, 2, "")}))
    testing.expect(t, !docs.doc_apply(&d, {}))
    testing.expect_value(t, d.gen, 1)
    testing.expect_value(t, len(d.changes), 2)

    docs.doc_apply(&d, {sp(2, 2, "\nab")})
    end := d.changes[len(d.changes) - 1].new_end_pt
    testing.expect_value(t, end, pt.Pos{1, 2})
    testing.expect_value(t, d.table.lines, 2)

    // Undoes whole: the inverse offsets read the finished document.
    docs.doc_undo(&d)
    docs.doc_undo(&d)
    testing.expect_value(t, text(&d), "hello world")
    testing.expect(t, docs.doc_undo(&d) == nil)
}

@(test)
doc_apply_edges_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("abcdef"))
    defer docs.doc_destroy(&d)

    docs.doc_apply(&d, {sp(1, 3, "X"), sp(2, 4, "Y")})
    testing.expect_value(t, text(&d), "aXYef")

    docs.doc_apply(&d, {sp(3, 99, "!")})
    testing.expect_value(t, text(&d), "aXY!")
    testing.expect(t, docs.doc_check(&d))
    testing.expect_value(t, d.changes[len(d.changes) - 1].old_end, 5)
}

@(test)
doc_apply_history_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d)
    defer docs.doc_destroy(&d)

    docs.doc_apply(&d, {sp(0, 0, "a")}, .Join)
    docs.doc_apply(&d, {sp(1, 1, "b")}, .Join)
    docs.doc_apply(&d, {sp(2, 2, "c")})
    docs.doc_undo(&d)
    testing.expect_value(t, text(&d), "ab")
    docs.doc_undo(&d)
    testing.expect_value(t, text(&d), "")
    testing.expect(t, docs.doc_undo(&d) == nil)

    docs.doc_apply(&d, {sp(0, 0, "x")})
    docs.doc_apply(&d, {sp(0, 1, "derived")}, .Forget)
    testing.expect_value(t, text(&d), "derived")
    testing.expect(t, docs.doc_undo(&d) == nil)
    testing.expect(t, docs.doc_redo(&d) == nil)
}

@(test)
doc_caps_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d)
    defer docs.doc_destroy(&d)

    for _ in 0 ..< docs.UNDO_MAX + 5 {
        docs.doc_apply(&d, {sp(0, 0, "x")})
    }
    testing.expect_value(t, len(d.undo), docs.UNDO_MAX)

    // Past the cap the log restarts at the batch that crossed it; readers behind lose it.
    testing.expect(t, len(d.changes) <= docs.DOC_CHANGE_MAX)
    testing.expect(t, d.changes_base > 0)
    testing.expect_value(t, d.changes_base + u64(len(d.changes)), d.changes_next)
}

@(test)
doc_undo_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("abc"))
    defer docs.doc_destroy(&d)

    testing.expect(t, docs.doc_undo(&d) == nil)

    // The second batch is only right against the first's result, so undo replays them apart.
    docs.doc_apply(&d, {sp(0, 1, "XYZ"), sp(2, 3, "")})
    docs.doc_apply(&d, {sp(4, 4, "!"), sp(0, 1, "")}, .Join)
    testing.expect_value(t, text(&d), "YZb!")

    docs.doc_apply(&d, {sp(0, 0, ">")})
    testing.expect_value(t, text(&d), ">YZb!")

    testing.expect(t, docs.doc_undo(&d) != nil)
    testing.expect_value(t, text(&d), "YZb!")
    testing.expect(t, docs.doc_undo(&d) != nil)
    testing.expect_value(t, text(&d), "abc")
    testing.expect(t, docs.doc_undo(&d) == nil)

    testing.expect(t, docs.doc_redo(&d) != nil)
    testing.expect_value(t, text(&d), "YZb!")
    gen := d.gen

    docs.doc_apply(&d, {sp(0, 0, "#")})
    testing.expect(t, docs.doc_redo(&d) == nil)
    testing.expect_value(t, d.gen, gen + 1)
}

@(test)
doc_readers_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("abc"))
    defer docs.doc_destroy(&d)

    a := docs.reader_add(&d)
    b := docs.reader_add(&d)
    docs.doc_apply(&d, {sp(0, 0, "x")})
    docs.doc_apply(&d, {sp(0, 0, "y")})

    ch, lost := docs.changes_since(&d, a)
    testing.expect(t, !lost)
    testing.expect_value(t, len(ch), 2)

    docs.changes_ack(&d, a)
    testing.expect_value(t, len(d.changes), 2)
    docs.changes_ack(&d, b)
    testing.expect_value(t, len(d.changes), 0)

    docs.doc_apply(&d, {sp(0, 0, "z")})
    docs.reader_drop(&d, b)
    docs.changes_ack(&d, a)
    testing.expect_value(t, len(d.changes), 0)
    testing.expect_value(t, docs.reader_add(&d), b)

    docs.doc_set(&d, transmute([]u8)string("new"))
    _, lost = docs.changes_since(&d, a)
    testing.expect(t, lost)
}

@(test)
doc_shift_test :: proc(t: ^testing.T) {
    // "ab\ncd": replace [1, 4) ("b\nc") with "XY".
    ch := docs.Change{1, 4, 3, {0, 1}, {1, 1}, {0, 3}}

    testing.expect_value(t, docs.off_shift(0, ch, false), 0)
    testing.expect_value(t, docs.off_shift(5, ch, false), 4) // after: moves by the delta
    testing.expect_value(t, docs.off_shift(2, ch, false), 1) // inside: onto the front
    testing.expect_value(t, docs.off_shift(1, ch, true), 1) // a low edge at the start stays
    testing.expect_value(t, docs.off_shift(4, ch, true), 3)

    testing.expect_value(t, docs.point_shift({1, 2}, ch, false), pt.Pos{0, 4})
    testing.expect_value(t, docs.point_shift({2, 5}, ch, false), pt.Pos{1, 5})
    testing.expect_value(t, docs.point_shift({1, 0}, ch, false), pt.Pos{0, 1})
}

@(test)
doc_snapshot_test :: proc(t: ^testing.T) {
    d: docs.Doc
    docs.doc_init(&d, transmute([]u8)string("old"))
    defer docs.doc_destroy(&d)

    a := docs.doc_snapshot(&d)
    b := docs.doc_snapshot(&d)
    testing.expect(t, a == b)

    docs.doc_apply(&d, {sp(0, 3, "new")})
    c := docs.doc_snapshot(&d)
    testing.expect(t, c != a)
    testing.expect_value(t, string(pt.text_read(a, 0, a.size, context.temp_allocator)), "old")
    testing.expect_value(t, string(pt.text_read(c, 0, c.size, context.temp_allocator)), "new")
    testing.expect_value(t, a.gen, 0)
    testing.expect_value(t, c.gen, 1)
    pt.snapshot_release(a)
    pt.snapshot_release(b)
    pt.snapshot_release(c)
}
