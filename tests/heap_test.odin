package tests

import "core:strings"
import "core:testing"
import "../src/docs"
import lues "../src/lues"

// What the kernel keeps is on its own heap, not the caller's allocator: the plugin table, a
// command's name, a document and its bytes, and a temp result.
@(test)
heap_owned_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "heap-owned"); !ok {
        return
    }
    slot, _ := lues.cmd_named(&k, "hello")
    id := docs.store_open(&k.store, transmute([]u8)string("text"))
    d := docs.store_doc(&k.store, id)

    testing.expect(t, lues.heap_owns(&k.heap, raw_data(k.plugs)))
    testing.expect(t, lues.heap_owns(&k.heap, raw_data(k.cmds[slot].name)))
    testing.expect(t, lues.heap_owns(&k.heap, d))
    testing.expect(t, lues.heap_owns(&k.heap, raw_data(d.table.blocks[0])))
    testing.expect(t, lues.heap_owns(&k.heap, raw_data(lues.loader_path(&k, "cplug"))))
    testing.expect(t, !lues.heap_owns(&k.heap, raw_data(strings.to_string(said))), "the host's builder")
}

// Past HEAP_LARGE a buffer is a mapping of its own. Growing into one and shrinking back out
// keeps the bytes, and what is never freed is counted at destroy.
@(test)
heap_large_test :: proc(t: ^testing.T) {
    h: lues.Heap
    if !testing.expect(t, lues.heap_init(&h)) {
        return
    }
    a := lues.heap_allocator(&h)

    buf := make([dynamic]u8, 16, a)
    buf[15] = 7
    resize(&buf, lues.HEAP_LARGE * 3)
    testing.expect_value(t, buf[15], 7)
    testing.expect_value(t, buf[len(buf) - 1], 0)
    testing.expect(t, lues.heap_owns(&h, &buf[len(buf) - 1]))
    shrink(&buf, 32)
    resize(&buf, 32)
    testing.expect_value(t, buf[15], 7)
    delete(buf)

    _ = make([]u8, 8, a)
    testing.expect_value(t, lues.heap_destroy(&h), 1)
}

// A document bigger than a heap pool opens, and reads back whole.
@(test)
heap_big_doc_test :: proc(t: ^testing.T) {
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {}))
    defer lues.kernel_destroy(&k)
    big := make([]u8, 3 * lues.HEAP_POOL, context.temp_allocator)
    big[len(big) - 1] = 'z'

    id := docs.store_open(&k.store, big)
    text := doc_text(&k, id)
    testing.expect_value(t, len(text), len(big))
    testing.expect_value(t, text[len(text) - 1], 'z')
    testing.expect(t, lues.heap_owns(&k.heap, raw_data(docs.store_doc(&k.store, id).table.blocks[0])))
}
