package tests

import "core:strings"
import "core:testing"
import "../src/docs"
import lues "../src/lues"

@(private = "file")
rust_host :: proc(t: ^testing.T, k: ^lues.Kernel, box: ^Api_Box, said: ^strings.Builder,
                  name: string) -> bool {
    data := stage(t, name, "rustplug") or_return
    testing.expect(t, test_host(k, box, {home = {data = data}}))
    k.hooks.say, k.user = heard, said
    return testing.expect(t, lues.loader_load(k, lues.loader_path(k, "rustplug")), strings.to_string(said^))
}

// Rust reads the piece table in place and writes back through submit.
@(test)
rust_read_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if !rust_host(t, &k, &box, &said, "rust-read") {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("hello\nworld"))
    gen, _ := docs.store_gen(&k.store, id)
    docs.store_submit(&k.store, id, gen, {{5, 5, transmute([]u8)string(","), 0}})
    lues.kernel_settle(&k) // now more than one piece

    testing.expect(t, run(&k, "rs-read", id))
    testing.expect_value(t, strings.to_string(said), "hello,\nworld")
    testing.expect(t, run(&k, "rs-upper", id))
    testing.expect_value(t, doc_text(&k, id), "HELLO,\nWORLD")
}

// A snapshot held across calls keeps the bytes it was taken at while the doc moves on.
@(test)
rust_hold_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if !rust_host(t, &k, &box, &said, "rust-hold") {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("abc"))

    testing.expect(t, run(&k, "rs-hold", id))
    testing.expect(t, run(&k, "rs-upper", id))
    testing.expect_value(t, doc_text(&k, id), "ABC")
    testing.expect(t, run(&k, "rs-release"))
    testing.expect_value(t, strings.to_string(said), "abc")
    testing.expect(t, !run(&k, "rs-release"), "released twice")

    testing.expect(t, run(&k, "rs-double", id)) // the second release is ignored, not a double free
    i := lues.loader_find(&k, "rustplug")
    testing.expect(t, run(&k, "rs-hold", id))
    testing.expect_value(t, len(k.plugs[i].held), 1)
    lues.loader_unload(&k, i)
    testing.expect_value(t, len(k.plugs[i].held), 0) // released for it
}

// A panic is caught at the seam: the command fails and the plugin stays loaded.
@(test)
rust_panic_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if !rust_host(t, &k, &box, &said, "rust-panic") {
        return
    }
    testing.expect(t, !run(&k, "rs-panic", nil, "now"))
    testing.expect(t, lues.loader_find(&k, "rustplug") >= 0)
    id := docs.store_open(&k.store, transmute([]u8)string("still"))
    testing.expect(t, run(&k, "rs-read", id))
    testing.expect_value(t, strings.to_string(said), "still")
}
