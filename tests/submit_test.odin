package tests

import "core:strings"
import "core:testing"
import "../src/docs"
import lues "../src/lues"

// A plugin's edit lands at the settle after its command, and undoes as one step.
@(test)
submit_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "submit"); !ok {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("ab"))

    testing.expect(t, run(&k, "append", id, "cd"))
    testing.expect_value(t, doc_text(&k, id), "abcd")
    docs.doc_undo(docs.store_doc(&k.store, id))
    testing.expect_value(t, doc_text(&k, id), "ab")

    testing.expect(t, run(&k, "derive", id, "!"))
    docs.doc_undo(docs.store_doc(&k.store, id))
    testing.expect_value(t, doc_text(&k, id), "ab!") // the C flag bit maps to .Forget

    testing.expect(t, run(&k, "race", id, "X"))
    testing.expect_value(t, doc_text(&k, id), "ab!X") // the second submit was stale

    testing.expect(t, run(&k, "short", id, "Y"))
    testing.expect_value(t, doc_text(&k, id), "ab!X")
    testing.expect(t, strings.contains(strings.to_string(said), "short struct"), strings.to_string(said))
}

// A snapshot held through the api reads the same bytes, and release frees it.
@(test)
snapshot_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "snapshot"); !ok {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("12345"))

    testing.expect(t, run(&k, "peek", id))
    testing.expect_value(t, strings.to_string(said), "5")
}

// Spans land in the plugin's bucket and go with it on unload.
@(test)
spans_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "spans")
    if !ok {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("abc"))

    testing.expect(t, run(&k, "paint", id))
    who, published := lues.producer_find(&k, "cplug")
    testing.expect(t, published)
    runs := docs.spans_read(&k.store, id, 0, 3, {who})
    if testing.expect_value(t, len(runs), 1) {
        testing.expect_value(t, runs[0].fg, 3)
        testing.expect_value(t, runs[0].set, docs.Chans{.Fg})
    }

    lues.loader_unload(&k, i)
    testing.expect_value(t, len(docs.spans_read(&k.store, id, 0, 3, {who})), 0)
}

// hooks.submit_side sees a plugin's splices and flags, and land gets its answer, landed or not.
@(test)
side_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "side"); !ok {
        return
    }
    seen: Side_Seen
    seen.texts.allocator = context.temp_allocator
    seen.landed.allocator = context.temp_allocator
    // k.user is the say builder; the side carries ^Side_Seen to land.
    side_seen = &seen
    k.hooks.submit_side = proc(k: ^lues.Kernel, i: int, id: docs.Id, gen: u64,
                               splices: []docs.Splice, flags: lues.Submit_Flags) -> rawptr {
        for sp in splices {
            append(&side_seen.texts, strings.clone(string(sp.text), context.temp_allocator))
        }
        if .Forget in flags {
            side_seen.forget += 1
        }
        return side_seen
    }
    k.hooks.land = proc(k: ^lues.Kernel, id: docs.Id, side: rawptr, landed: bool) {
        append(&(^Side_Seen)(side).landed, landed)
    }
    id := docs.store_open(&k.store, transmute([]u8)string("ab"))

    testing.expect(t, run(&k, "append", id, "cd"))
    testing.expect(t, run(&k, "derive", id, "!"))
    testing.expect(t, run(&k, "race", id, "X"))
    testing.expect_value(t, len(seen.texts), 4)
    if len(seen.texts) == 4 {
        testing.expect_value(t, seen.texts[0], "cd")
        testing.expect_value(t, seen.texts[1], "!")
    }
    testing.expect_value(t, seen.forget, 1)
    testing.expect_value(t, len(seen.landed), 4)
    if len(seen.landed) == 4 {
        testing.expect(t, seen.landed[0] && seen.landed[1] && seen.landed[2] && !seen.landed[3])
    }
}

@(private = "file")
Side_Seen :: struct {
    texts:  [dynamic]string,
    forget: int,
    landed: [dynamic]bool,
}

// Only side_test sets it.
@(private = "file")
side_seen: ^Side_Seen
