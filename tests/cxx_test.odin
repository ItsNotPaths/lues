package tests

import "core:strings"
import "core:testing"
import "core:time"
import lues "../src/lues"

// cxxplug links libstdc++ as a shared object, as a C++ plugin usually does.

// A fault on a std::thread unloads the plugin, though libstdc++'s trampoline is under it.
@(test)
cxx_thread_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := cxx_host(t, &k, &box, &said, "cxx-thread")
    if !ok {
        return
    }

    testing.expect(t, !run(&k, "threadboom"))
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    testing.expect(t, strings.contains(strings.to_string(said), "cxxplug faulted on a thread of its own"), strings.to_string(said))
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cxxplug")), strings.to_string(said))
    testing.expect(t, run(&k, "hello"))
}

// Unloading ends a running std::thread, and the plugin is unmapped.
@(test)
cxx_reap_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := cxx_host(t, &k, &box, &said, "cxx-reap")
    if !ok {
        return
    }

    testing.expect(t, run(&k, "spin"))
    from := time.tick_now()
    testing.expect(t, lues.loader_unload(&k, i))
    testing.expectf(t, time.tick_since(from) < time.Second, "unload took %v", time.tick_since(from))
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Unloaded)
}

// A fault in libc that libstdc++ called for the plugin is blamed on the plugin.
@(test)
cxx_blame_test :: proc(t: ^testing.T) {
    crash(t, "cxx-blame", "strboom", .SIGSEGV, plug = "cxxplug")
}

// An exception out of the entry ends in std::terminate: blamed on the plugin.
@(test)
cxx_throw_test :: proc(t: ^testing.T) {
    crash(t, "cxx-throw", "throw", .SIGABRT, plug = "cxxplug")
}

// cxxplug loaded into k.
@(private = "file")
cxx_host :: proc(t: ^testing.T, k: ^lues.Kernel, box: ^Api_Box, said: ^strings.Builder, name: string) -> (i: int, ok: bool) {
    data := stage(t, name, "cxxplug") or_return
    testing.expect(t, test_host(k, box, {home = {data = data}}))
    k.hooks.say, k.user = heard, said
    if !testing.expect(t, lues.loader_load(k, lues.loader_path(k, "cxxplug")), strings.to_string(said^)) {
        return -1, false
    }
    return lues.loader_find(k, "cxxplug"), true
}
