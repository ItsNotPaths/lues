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

// A reload after a fault maps a fresh copy: the dead image's globals don't come back.
@(test)
fresh_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "fresh"); !ok {
        return
    }

    testing.expect(t, run(&k, "count"))
    testing.expect(t, run(&k, "count"))
    testing.expect_value(t, strings.to_string(said), "count 2")
    testing.expect(t, !run(&k, "boom"))
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect(t, run(&k, "count"))
    testing.expect_value(t, strings.to_string(said), "count 1")
}

// A fault in an object the plugin adopted unloads it, the same as one in its own .so.
@(test)
adopt_test :: proc(t: ^testing.T) {
    data, staged := stage(t, "adopt", "cplug", "grammar")
    if !staged {
        return
    }
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    testing.expect(t, test_host(&k, &box, {home = {data = data}}))
    defer lues.kernel_destroy(&k)
    k.hooks.say, k.user = heard, &said
    if !testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said)) {
        return
    }
    i := lues.loader_find(&k, "cplug")

    testing.expect(t, !run(&k, "adoptk"), "adopted the kernel's object")
    testing.expect_value(t, len(k.plugs[i].objects), 0) // its own .so is not recorded
    testing.expect(t, !run(&k, "adopt", args = lues.loader_path(&k, "grammar")))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    testing.expect_value(t, len(k.plugs[i].objects), 0)
    text := strings.to_string(said)
    testing.expect(t, strings.contains(text, "cplug") && strings.contains(text, "SIGSEGV"), text)
    testing.expect(t, !lues.quarantined(&k, "cplug"))
}

// The same fault, not adopted, is in nobody's code: the process dies and nobody is quarantined.
@(test)
unadopted_test :: proc(t: ^testing.T) {
    crash(t, "unadopted", "scan", .SIGSEGV, blamed = false)
}

// A fault in the plugin's code with libc's frames under it is not unwound: libc may hold a lock
// there. The process dies and the plugin is quarantined.
@(test)
foreign_test :: proc(t: ^testing.T) {
    crash(t, "foreign", "sortboom", .SIGSEGV)
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
    sync.guard(&watch_lock)
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
// quarantined.
@(test)
fault_api_test :: proc(t: ^testing.T) {
    crash(t, "fault-api", "badsubmit", .SIGSEGV)
}

// fail unwinds like a fault: unloaded and named with its message, not quarantined.
@(test)
fail_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "fail")
    if !ok {
        return
    }

    testing.expect(t, !run(&k, "fail", args = "out of range"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    testing.expect(t, strings.contains(strings.to_string(said), "cplug failed: out of range"), strings.to_string(said))
    testing.expect(t, !lues.quarantined(&k, "cplug"))

    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect(t, run(&k, "hello"))
}

// fail with no net on its thread cannot unwind: the process dies and the plugin is quarantined.
@(test)
fail_thread_test :: proc(t: ^testing.T) {
    crash(t, "fail-thread", "failoff", .SIGABRT)
}

// Runs `cmd` in a child, this test binary again with only crash_child selected, and expects it
// to die of `sig`, with cplug quarantined when `blamed`.
@(private = "file")
crash :: proc(t: ^testing.T, name, cmd: string, sig: posix.Signal, blamed := true) {
    sync.guard(&state_lock)
    data, staged := stage(t, name, "cplug", "grammar")
    if !staged {
        return
    }
    state, _, errs, err := os.process_exec({
        command = {"/proc/self/exe", "-tests:crash_child"}, // args[0] may not be a path
        env     = {fmt.tprintf("%s=%s", CRASH_ENV, data), fmt.tprintf("%s=%s", CRASH_CMD_ENV, cmd)},
    }, context.temp_allocator)
    testing.expectf(t, err == nil && !state.success && state.exit_code == int(sig),
                    "the child did not die of %v: %v %v %s", sig, err, state, errs)
    file, _ := filepath.join({data, lues.QUARANTINE_FILE}, context.temp_allocator)
    raw, _ := os.read_entire_file(file, context.temp_allocator)
    testing.expect_value(t, string(raw), "cplug\n" if blamed else "")
}

@(private = "file")
CRASH_ENV :: "LUES_CRASH_CHILD"

@(private = "file")
CRASH_CMD_ENV :: "LUES_CRASH_CMD"

// A no-op unless crash runs it.
@(test)
crash_child :: proc(t: ^testing.T) {
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
    // Every command gets the grammar's path; only scan reads it.
    run(&k, os.get_env(CRASH_CMD_ENV, context.temp_allocator), id, lues.loader_path(&k, "grammar"))
    testing.fail_now(t, "the process survived")
}
