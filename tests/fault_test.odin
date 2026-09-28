package tests

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "../src/docs"
import lues "../src/lues"

// A segfault in plugin code unloads that plugin, names it, and the kernel carries on.
// A fault does not quarantine: an explicit load takes it again.
@(test)
segv_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "segv")
    if !ok {
        return
    }

    testing.expect(t, !run(&k, "boom"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    text := strings.to_string(said)
    testing.expect(t, strings.contains(text, "cplug") && strings.contains(text, "SIGSEGV"), text)
    testing.expect(t, !strings.contains(text, "trace in"), text)

    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), i)
    testing.expect(t, run(&k, "hello"))
}

// The trace's first line is the plugin's own object, with an offset.
@(test)
trace_test :: proc(t: ^testing.T) {
    sync.guard(&state_lock)
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "trace", state = true); !ok {
        return
    }

    testing.expect(t, !run(&k, "boom"))
    testing.expect(t, strings.contains(strings.to_string(said), "trace in"), strings.to_string(said))
    path, _ := filepath.join({k.home.state, lues.FAULTS_FILE}, context.temp_allocator)
    raw, err := os.read_entire_file(path, context.temp_allocator)
    if !testing.expectf(t, err == nil, "no trace at %s: %v", path, err) {
        return
    }
    trace, line := string(raw), ""
    for row in strings.split_lines_iterator(&trace) {
        if strings.has_prefix(row, "addr2line -e ") {
            line = row
            break
        }
    }
    testing.expect(t, strings.contains(line, "cplug.so 0x"), string(raw))
}

// The watchdog ends a call that stops returning, the same way as a fault.
@(test)
hang_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "hang"); !ok {
        return
    }
    // Stopped on the way out: runner threads are shared, and a short deadline left on would
    // trip another test's dispatch.
    lues.fault_watchdog_start(1000)
    defer lues.fault_watchdog_stop()

    testing.expect(t, !run(&k, "hang"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect(t, strings.contains(strings.to_string(said), "stopped returning"), strings.to_string(said))
}

// Guard 1: only a pc inside the plugin's own object is recovered.
@(test)
guard_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "guard")
    if !ok {
        return
    }

    entry, found := dynlib.symbol_address(k.plugs[i].lib, lues.ENTRY)
    testing.expect(t, found && k.plugs[i].base != 0)
    testing.expect_value(t, lues.fault_object_base(entry), k.plugs[i].base)
    kernel := lues.fault_object_base(rawptr(lues.loader_find))
    testing.expect(t, kernel != 0 && kernel != k.plugs[i].base, "the kernel looks like a plugin")
}

// A doc corrupt after a clean return is caught and blamed on the plugin that just ran.
@(test)
corrupt_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "corrupt"); !ok {
        return
    }
    id := docs.store_open(&k.store, transmute([]u8)string("text"))
    docs.store_doc(&k.store, id).magic = 0

    testing.expect(t, !run(&k, "hello"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect(t, strings.contains(strings.to_string(said), "corrupt"), strings.to_string(said))
}

// Guard 2: a fault inside an api call is not unwound. The process dies and the plugin is
// quarantined. Run in a child: this test binary again, with only the child test selected.
@(test)
fault_api_test :: proc(t: ^testing.T) {
    sync.guard(&state_lock)
    data, staged := stage(t, "fault-api", "cplug")
    if !staged {
        return
    }
    state, _, errs, err := os.process_exec({
        command = {os.args[0], "-tests:fault_api_child"},
        env     = {fmt.tprintf("%s=%s", CRASH_ENV, data)},
    }, context.temp_allocator)
    testing.expectf(t, err == nil && !state.success && state.exit_code == int(posix.Signal.SIGSEGV),
                    "the child did not die of SIGSEGV: %v %v %s", err, state, errs)
    file, _ := filepath.join({data, lues.QUARANTINE_FILE}, context.temp_allocator)
    raw, _ := os.read_entire_file(file, context.temp_allocator)
    testing.expect_value(t, string(raw), "cplug\n")
}

@(private = "file")
CRASH_ENV :: "LUES_FAULT_API_CHILD"

// A no-op unless fault_api_test runs it.
@(test)
fault_api_child :: proc(t: ^testing.T) {
    data := os.get_env(CRASH_ENV, context.temp_allocator)
    if data == "" {
        return
    }
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {home = {data = data, state = data}}))
    k.hooks.say, k.user = heard, &said
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")))
    id := docs.store_open(&k.store)
    run(&k, "badsubmit", id)
    testing.fail_now(t, "the process survived a fault inside an api call")
}
