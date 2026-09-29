package tests

import "core:strings"
import "core:sync"
import "core:testing"
import lues "../src/lues"

// The test app with a tail, app_version 1: run executes a command inside the calling one.
Nest_Api :: struct {
    using base: lues.Api,
    run:        proc "c" (api: ^lues.Api, self: lues.Self, line: [^]u8, n: uint) -> i32,
}

Nest_Box :: lues.Box(Nest_Api)

@(private = "file")
nest_run :: proc "c" (api: ^lues.Api, self: lues.Self, line: [^]u8, n: uint) -> i32 {
    k, _, ok := lues.api_kernel(api, self)
    defer lues.api_done()
    if !ok {
        return 1
    }
    context = k.ctx
    name, _, args := strings.partition(string(line[:n]), " ")
    return 0 if run(k, name, nil, args) else 1
}

// Every message, one per line.
@(private = "file")
heard_all :: proc(k: ^lues.Kernel, text: string) {
    b := (^strings.Builder)(k.user)
    strings.write_string(b, text)
    strings.write_byte(b, '\n')
}

// nplug and cplug loaded into k.
@(private = "file")
nest_host :: proc(t: ^testing.T, k: ^lues.Kernel, box: ^Nest_Box, said: ^strings.Builder,
                  name: string) -> bool {
    data := stage(t, name, "cplug", "nplug") or_return
    testing.expect(t, lues.kernel_init(k, {home = {data = data}, app = "test", app_version = 1, api = &box.api.base}))
    box.api.run = nest_run
    k.hooks.say, k.user = heard_all, said
    ok := lues.loader_load(k, lues.loader_path(k, "cplug")) && lues.loader_load(k, lues.loader_path(k, "nplug"))
    return testing.expect(t, ok, strings.to_string(said^))
}

@(private = "file")
state :: proc(k: ^lues.Kernel, name: string) -> lues.Plug_State {
    for p in k.plugs {
        if p.name == name {
            return p.state
        }
    }
    return .Unloaded
}

// A fault in a nested call unloads the plugin that faulted, not the one that nested it, and
// the outer call goes on.
@(test)
nest_fault_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Nest_Box
    defer lues.kernel_destroy(&k)
    if !nest_host(t, &k, &box, &said, "nest-fault") {
        return
    }

    testing.expect(t, !run(&k, "nest", nil, "boom"))
    testing.expect_value(t, state(&k, "cplug"), lues.Plug_State.Faulted)
    testing.expect_value(t, state(&k, "nplug"), lues.Plug_State.Live)
    testing.expect_value(t, strings.to_string(said), "cplug faulted (SIGSEGV), and is unloaded\nback\n")
}

// fail in a nested call unwinds that call only.
@(test)
nest_fail_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Nest_Box
    defer lues.kernel_destroy(&k)
    if !nest_host(t, &k, &box, &said, "nest-fail") {
        return
    }

    testing.expect(t, !run(&k, "nest", nil, "fail oops"))
    testing.expect_value(t, state(&k, "cplug"), lues.Plug_State.Faulted)
    testing.expect_value(t, state(&k, "nplug"), lues.Plug_State.Live)
    testing.expect_value(t, strings.to_string(said), "cplug failed: oops, and is unloaded\nback\n")
}

// A plugin that faults while its own outer call waits: the outer call's api calls are refused
// and its return is a failure.
@(test)
nest_self_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Nest_Box
    defer lues.kernel_destroy(&k)
    if !nest_host(t, &k, &box, &said, "nest-self") {
        return
    }

    testing.expect(t, !run(&k, "nest", nil, "die"))
    testing.expect_value(t, state(&k, "nplug"), lues.Plug_State.Faulted)
    testing.expect_value(t, state(&k, "cplug"), lues.Plug_State.Live)
    testing.expect_value(t, strings.to_string(said), "nplug faulted (SIGSEGV), and is unloaded\n")
}

// A nested call that stops returning is ended on its own deadline; the outer one's is paused
// meanwhile, so the outer call goes on.
@(test)
nest_hang_test :: proc(t: ^testing.T) {
    sync.guard(&watch_lock)
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Nest_Box
    defer lues.kernel_destroy(&k)
    if !nest_host(t, &k, &box, &said, "nest-hang") {
        return
    }
    lues.fault_watchdog_start(1000)
    defer lues.fault_watchdog_stop()

    testing.expect(t, !run(&k, "nest", nil, "hang"))
    testing.expect_value(t, state(&k, "cplug"), lues.Plug_State.Faulted)
    testing.expect_value(t, state(&k, "nplug"), lues.Plug_State.Live)
    testing.expect_value(t, strings.to_string(said), "cplug stopped returning, and is unloaded\nback\n")
}

// Past FAULT_DEPTH frames the call is refused, and nobody is unloaded.
@(test)
nest_deep_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Nest_Box
    defer lues.kernel_destroy(&k)
    if !nest_host(t, &k, &box, &said, "nest-deep") {
        return
    }
    line :: proc(nests: int) -> string {
        return strings.concatenate({strings.repeat("nest ", nests, context.temp_allocator), "hello 0"}, context.temp_allocator)
    }

    // The outer run is one frame; each nest inside it and hello are one more.
    testing.expect(t, run(&k, "nest", nil, line(lues.FAULT_DEPTH - 2)), strings.to_string(said))
    strings.builder_reset(&said)
    testing.expect(t, !run(&k, "nest", nil, line(lues.FAULT_DEPTH - 1)))
    testing.expect(t, strings.has_prefix(strings.to_string(said), "cplug: calls nested more than 16 deep\n"), strings.to_string(said))
    testing.expect_value(t, state(&k, "cplug"), lues.Plug_State.Live)
    testing.expect_value(t, state(&k, "nplug"), lues.Plug_State.Live)
}
