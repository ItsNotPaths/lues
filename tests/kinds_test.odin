package tests

import "core:strings"
import "core:testing"
import "../src/docs"
import lues "../src/lues"

// A write the plugin did not make, landed now.
@(private = "file")
foreign_write :: proc(k: ^lues.Kernel, id: docs.Id) {
    gen, _ := docs.store_gen(&k.store, id)
    docs.store_submit(&k.store, id, gen, {{0, 0, transmute([]u8)string("+"), 0}})
    lues.kernel_settle(k)
}

// A plugin kind opens a doc it fills, takes its events, hears foreign writes but not its
// own, and closes with its plugin.
@(test)
kind_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "kinds")
    if !ok {
        return
    }
    kind, named := lues.kind_named(&k, "note")
    testing.expect(t, named)
    id, opened := lues.inst_open(&k, kind, "hi")
    if !testing.expect(t, opened, strings.to_string(said)) {
        return
    }
    testing.expect_value(t, doc_text(&k, id), "hi")

    testing.expect(t, lues.inst_event(&k, id, .Text, "!"))
    testing.expect(t, !lues.inst_event(&k, id, .Chord, "x"), "a chord it does not take")
    testing.expect_value(t, doc_text(&k, id), "hi!")

    strings.builder_reset(&said)
    lues.pump_insts(&k)
    testing.expect_value(t, strings.to_string(said), "") // its own write
    foreign_write(&k, id)
    lues.pump_insts(&k)
    testing.expect_value(t, strings.to_string(said), "moved 1")
    lues.pump_insts(&k)
    testing.expect_value(t, strings.to_string(said), "moved 1") // nothing moved since
    foreign_write(&k, id)
    testing.expect(t, lues.inst_event(&k, id, .Text, "?"))
    lues.pump_insts(&k)
    testing.expect_value(t, strings.to_string(said), "moved 2") // its own write hid nothing

    testing.expect(t, lues.loader_unload(&k, i))
    testing.expect_value(t, strings.to_string(said), "closed")
    testing.expect(t, docs.store_doc(&k.store, id) == nil, "the plugin's doc outlived it")
    _, still := lues.kind_named(&k, "note")
    testing.expect(t, !still)
}

// An open that faults leaves no doc behind.
@(test)
open_fault_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "open-fault"); !ok {
        return
    }
    kind, _ := lues.kind_named(&k, "note")
    spare := docs.store_open(&k.store)
    docs.store_close(&k.store, spare) // the next open takes this slot

    _, opened := lues.inst_open(&k, kind, "boom")
    testing.expect(t, !opened)
    again := docs.store_open(&k.store)
    testing.expect_value(t, again.slot, spare.slot) // free again, so the half-made doc closed
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
}

// A watcher hears every doc once, then only what moved, then what it latched on.
@(test)
watch_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "watch")
    if !ok {
        return
    }
    a := docs.store_open(&k.store, transmute([]u8)string("a"))
    b := docs.store_open(&k.store, transmute([]u8)string("b"))

    lues.pump_watch(&k)
    testing.expect_value(t, strings.to_string(said), "watched 2")
    lues.pump_watch(&k)
    testing.expect_value(t, strings.to_string(said), "watched 2")
    foreign_write(&k, a)
    lues.pump_watch(&k)
    testing.expect_value(t, strings.to_string(said), "watched 3")

    testing.expect(t, run(&k, "latch", nil, "1"))
    foreign_write(&k, a)
    testing.expect(t, lues.pump_watch(&k), "a non-zero answer latches")
    testing.expect(t, !lues.pump_watch(&k), "called again, and it let go")
    testing.expect_value(t, strings.to_string(said), "watched 5")

    docs.store_close(&k.store, b)
    lues.pump_watch(&k)
    testing.expect_value(t, len(k.plugs[i].seen), 1) // the closed doc is pruned
}
