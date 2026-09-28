package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "../src/docs"
import lues "../src/lues"
import "../src/pt"

// (hole rs-test-parity :tags (port) :sev missing-port :needs (rs-host-abi)) the suite drives the Odin kernel only; nothing proves the crate behaves the same.
Api_Box :: lues.Box(lues.Api)

// No app: no hooks, no side data, no api tail.
// The app is "test" unless the spec names one.
test_host :: proc(k: ^lues.Kernel, box: ^Api_Box, spec: lues.Spec) -> bool {
    spec := spec
    spec.app = spec.app if spec.app != nil else "test"
    spec.api = &box.api
    return lues.kernel_init(k, spec)
}

TESTS :: #directory

// Per test: the runner is threaded. Temp-allocated.
stage :: proc(t: ^testing.T, name: string, plugins: ..string) -> (data: string, ok: bool) {
    tmp, _ := os.temp_directory(context.temp_allocator)
    data, _ = filepath.join({tmp, "lues-test", name}, context.temp_allocator)
    os.remove_all(data)
    out, _ := filepath.join({data, lues.PLUGIN_DIR}, context.temp_allocator)
    script, _ := filepath.join({TESTS, "stage.sh"}, context.temp_allocator)
    for plugin in plugins {
        src, _ := filepath.join({TESTS, plugin}, context.temp_allocator)
        state, _, errs, err := os.process_exec({command = {script, src, out}}, context.temp_allocator)
        if err != nil || !state.success {
            testing.expectf(t, false, "stage.sh %s: %v %s", plugin, err, string(errs))
            return "", false
        }
    }
    return data, true
}

doc_text :: proc(k: ^lues.Kernel, id: docs.Id) -> string {
    d := docs.store_doc(&k.store, id)
    return string(pt.text_read(&d.table, 0, d.table.size, context.temp_allocator))
}

// k.user points at the builder.
heard :: proc(k: ^lues.Kernel, text: string) {
    b := (^strings.Builder)(k.user)
    strings.builder_reset(b)
    strings.write_string(b, text)
}


@(test)
loader_test :: proc(t: ^testing.T) {
    data, staged := stage(t, "loader", "cplug")
    if !staged {
        return
    }
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {home = {data = data}}))
    defer lues.kernel_destroy(&k)
    k.hooks.say, k.user = heard, &said

    lues.loader_autoload(&k)
    i := lues.loader_find(&k, "cplug")
    hello, named := lues.cmd_named(&k, "hello")
    if !testing.expect(t, i >= 0 && named, strings.to_string(said)) {
        return
    }
    testing.expect(t, !lues.loader_load(&k, lues.loader_path(&k, "cplug")), "a second load of the same name")
    testing.expect(t, lues.cmd_run(&k, hello, nil, "0"))
    testing.expect(t, !lues.cmd_run(&k, hello, nil, "3"), "a non-zero exit is a failure")
    testing.expect_value(t, strings.to_string(said), "3")

    size, _ := lues.cmd_named(&k, "size")
    testing.expect(t, !lues.cmd_run(&k, size, nil, ""), "no focused doc")
    doc := docs.store_open(&k.store, transmute([]u8)string("four\nlines"))
    testing.expect(t, lues.cmd_run(&k, size, doc, ""))
    testing.expect_value(t, strings.to_string(said), "10")

    old := lues.self_handle(&k, i)
    testing.expect(t, lues.loader_reload(&k, "cplug"), strings.to_string(said))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), i)
    _, _, stale := lues.api_kernel(&box.api, old)
    testing.expect(t, !stale, "a Self from the last load still resolves")
    _, _, nobody := lues.api_kernel(&box.api, lues.Self(lues.pack(99, 1)))
    testing.expect(t, !nobody, "a Self past the table resolves")
    _, _, live := lues.api_kernel(&box.api, lues.self_handle(&k, i))
    lues.api_done()
    testing.expect(t, live)
    testing.expect_value(t, k.cmds[hello].owner, -1) // tombstoned, not reused
    testing.expect(t, !lues.cmd_run(&k, hello, nil, "0"))
    again, _ := lues.cmd_named(&k, "hello")
    testing.expect(t, again != hello && lues.cmd_run(&k, again, nil, "0"))

    testing.expect(t, lues.loader_unload(&k, i))
    testing.expect(t, !lues.loader_unload(&k, i), "a second unload")
    _, still := lues.cmd_named(&k, "hello")
    testing.expect(t, !still, "the ledger left a command behind")
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Unloaded)
}

@(test)
refuse_test :: proc(t: ^testing.T) {
    data, staged := stage(t, "refuse", "cplug")
    if !staged {
        return
    }
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {home = {data = data}, app = "other"}))
    defer lues.kernel_destroy(&k)

    testing.expect(t, !lues.loader_load(&k, lues.loader_path(&k, "cplug")))
    _, named := lues.cmd_named(&k, "hello")
    testing.expect(t, !named, "a refused load kept a command")
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
}

// cplug loaded into k. With `state`, the kernel writes its faults file in the data dir.
plug_host :: proc(t: ^testing.T, k: ^lues.Kernel, box: ^Api_Box, said: ^strings.Builder,
                   name: string, spec := lues.Spec{}, state := false) -> (i: int, ok: bool) {
    data := stage(t, name, "cplug") or_return
    spec := spec
    spec.home = {data = data, state = data if state else ""}
    testing.expect(t, test_host(k, box, spec))
    k.hooks.say, k.user = heard, said
    if !testing.expect(t, lues.loader_load(k, lues.loader_path(k, "cplug")), strings.to_string(said^)) {
        return -1, false
    }
    return lues.loader_find(k, "cplug"), true
}

run :: proc(k: ^lues.Kernel, name: string, focused: Maybe(docs.Id) = nil, args := "") -> bool {
    slot, named := lues.cmd_named(k, name)
    return named && lues.cmd_run(k, slot, focused, args)
}

// The faults and quarantine fds are per process: a test that sets home.state holds this.
state_lock: sync.Mutex

@(test)
quarantine_test :: proc(t: ^testing.T) {
    sync.guard(&state_lock)
    data, staged := stage(t, "quarantine", "cplug")
    if !staged {
        return
    }
    file, _ := filepath.join({data, lues.QUARANTINE_FILE}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(file, transmute([]u8)string("cplug\n")), nil)
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {home = {data = data, state = data}}))
    defer lues.kernel_destroy(&k)
    k.hooks.say, k.user = heard, &said

    lues.loader_autoload(&k)
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect(t, strings.contains(strings.to_string(said), "cplug took a start down"), strings.to_string(said))

    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect(t, !lues.quarantined(&k, "cplug"))
    testing.expect(t, !os.exists(file), "the lifted name is still on disk")
}
