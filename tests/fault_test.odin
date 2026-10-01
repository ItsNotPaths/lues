package tests

import "core:c/libc"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
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

// A write into kernel memory faults where it happens, and only the plugin goes.
@(test)
pkey_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "pkey"); !ok || !lues.pkey_ready() {
        return // without pkeys the write lands
    }
    doc := docs.store_open(&k.store, transmute([]u8)string("kept"))

    testing.expect(t, !run(&k, "scribble", doc))
    testing.expect_value(t, strings.to_string(said), "cplug faulted (SIGSEGV), and is unloaded")
    testing.expect_value(t, doc_text(&k, doc), "kept")
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

// A fault in libc that the plugin called is not unwound, but it is blamed on the plugin.
@(test)
libc_blame_test :: proc(t: ^testing.T) {
    crash(t, "libc-blame", "strboom", .SIGSEGV)
}

// A plugin's own fault handler never replaces lues's: through signal it is only chained, and
// SIGALRM is refused. A fault in the plugin's code still unloads it.
@(test)
kept_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "kept"); !ok {
        return
    }

    testing.expect(t, run(&k, "sigign"))
    testing.expect(t, !run(&k, "boom"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
    testing.expect(t, strings.contains(strings.to_string(said), "SIGSEGV"), strings.to_string(said))
}

// A raw syscall goes around the export; lues puts its handler back after the call.
@(test)
raw_kept_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "raw-kept"); !ok {
        return
    }

    testing.expect(t, run(&k, "rawsig"))
    testing.expect(t, strings.contains(strings.to_string(said), "replaced a fault handler"), strings.to_string(said))
    testing.expect(t, !run(&k, "boom"))
    testing.expect_value(t, lues.loader_find(&k, "cplug"), -1)
}

// Unloading ends the plugin's threads: one in its own code at once, one in nanosleep once it is
// stepped back out of libc. Then the plugin is unmapped.
@(test)
reap_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "reap")
    if !ok {
        return
    }

    for how in ([]string{"spin", "sleep"}) {
        testing.expect(t, run(&k, "thread", args = how), how)
        from := time.tick_now()
        testing.expect(t, lues.loader_unload(&k, i), how)
        testing.expectf(t, time.tick_since(from) < time.Second, "%s: unload took %v", how, time.tick_since(from))
        testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Unloaded)
        testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    }
}

// A thread that can't be ended (blocked on a lock) keeps the plugin mapped, not unmapped under it.
@(test)
reap_stuck_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "reap-stuck")
    if !ok {
        return
    }

    testing.expect(t, run(&k, "thread", args = "lock"))
    testing.expect(t, lues.loader_unload(&k, i))
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    testing.expect(t, strings.contains(strings.to_string(said), "did not stop"), strings.to_string(said))
}

// A fault lues would die on goes to the plugin's own handler first, which can recover it.
@(test)
chain_test :: proc(t: ^testing.T) {
    data, staged := stage(t, "chain", "cplug", "grammar")
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

    testing.expect(t, run(&k, "catch", args = lues.loader_path(&k, "grammar")), strings.to_string(said))
    testing.expect(t, lues.loader_find(&k, "cplug") >= 0)
    testing.expect(t, run(&k, "hello"))
}

// A failed C assert unwinds like fail: unloaded and named, not quarantined.
@(test)
assert_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "assert")
    if !ok {
        return
    }

    testing.expect(t, !run(&k, "assert"))
    testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
    testing.expect(t, strings.contains(strings.to_string(said), "cplug aborted"), strings.to_string(said))
    testing.expect(t, !lues.quarantined(&k, "cplug"))
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect(t, run(&k, "hello"))
}

// An abort with libc's sort frames under it is not unwound, but it is blamed on the plugin.
@(test)
abort_foreign_test :: proc(t: ^testing.T) {
    crash(t, "abort-foreign", "sortabort", .SIGABRT)
}

// An abort another object called (as std::terminate does) dies, blamed on the plugin that
// called into it: an abort is on purpose, unlike a fault in an unadopted object.
@(test)
abort_third_party_test :: proc(t: ^testing.T) {
    crash(t, "abort-third-party", "gabort", .SIGABRT)
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

// A hang that is mostly in malloc is stepped out of it before the unwind, so no malloc lock is
// left held: loading the plugin again, which mallocs, still works.
@(test)
churn_test :: proc(t: ^testing.T) {
    sync.guard(&watch_lock)
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "churn"); !ok {
        return
    }
    lues.fault_watchdog_start(300)
    defer lues.fault_watchdog_stop()

    testing.expect(t, !run(&k, "churn"))
    testing.expect(t, strings.contains(strings.to_string(said), "stopped returning"), strings.to_string(said))
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    testing.expect(t, run(&k, "hello"))
}

// A hang that never gets back to the plugin's own frames alone dies when its second window ends,
// with the plugin quarantined.
@(test)
foreign_hang_test :: proc(t: ^testing.T) {
    crash(t, "foreign-hang", "sorthang", .SIGABRT)
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

// A fault, or fail, on a thread the plugin started ends that thread and unloads the plugin.
@(test)
thread_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "thread")
    if !ok {
        return
    }

    for cmd in ([]string{"threadboom", "failoff"}) {
        strings.builder_reset(&said)
        testing.expect(t, !run(&k, cmd), cmd)
        testing.expect_value(t, k.plugs[i].state, lues.Plug_State.Faulted)
        testing.expect(t, strings.contains(strings.to_string(said), "cplug faulted on a thread of its own"), strings.to_string(said))
        testing.expect(t, !lues.quarantined(&k, "cplug"))
        testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, "cplug")), strings.to_string(said))
    }
    testing.expect(t, run(&k, "hello"))
}

// A faulted plugin stays mapped, so glibc runs its destructors at exit, after the kernel is gone.
// A crash there is blamed on it.
@(test)
exit_test :: proc(t: ^testing.T) {
    crash(t, "exit", "dtorboom", .SIGSEGV, exit = true)
}

// Unguarded, a fault in plugin code kills the process, and nothing is quarantined.
@(test)
unguarded_test :: proc(t: ^testing.T) {
    crash(t, "unguarded", "boom", .SIGSEGV, blamed = false, unguarded = true)
}

// Runs `cmd` of `plug` in a child, this test binary again with only crash_child selected, and
// expects it to die of `sig`, with `plug` quarantined when `blamed`. With `exit`, the child
// destroys its kernel and exits after the command. With `unguarded`, its kernel has no net.
crash :: proc(t: ^testing.T, name, cmd: string, sig: posix.Signal, blamed := true, exit := false,
              plug := "cplug", unguarded := false) {
    sync.guard(&state_lock)
    data, staged := stage(t, name, plug, "grammar")
    if !staged {
        return
    }
    state, outs, errs, err := os.process_exec({
        command = {"/proc/self/exe", "-tests:crash_child"}, // args[0] may not be a path
        env     = {
            fmt.tprintf("%s=%s", CRASH_ENV, data),
            fmt.tprintf("%s=%s", CRASH_PLUG_ENV, plug),
            fmt.tprintf("%s=%s", CRASH_CMD_ENV, cmd),
            fmt.tprintf("%s=%s", CRASH_EXIT_ENV, "1" if exit else ""),
            fmt.tprintf("%s=%s", CRASH_UNGUARDED_ENV, "1" if unguarded else ""),
        },
    }, context.temp_allocator)
    // Unguarded, the test runner's own handler reports it and exits 1.
    died := state.exit_code == int(sig)
    if unguarded {
        died = strings.contains(string(outs), "Signal caught") || strings.contains(string(errs), "Signal caught")
    }
    testing.expectf(t, err == nil && !state.success && died,
                    "the child did not die of %v: %v %v %s", sig, err, state, errs)
    file, _ := filepath.join({data, lues.QUARANTINE_FILE}, context.temp_allocator)
    raw, _ := os.read_entire_file(file, context.temp_allocator)
    testing.expect_value(t, string(raw), fmt.tprintf("%s\n", plug) if blamed else "")
}

@(private = "file")
CRASH_ENV :: "LUES_CRASH_CHILD"

@(private = "file")
CRASH_CMD_ENV :: "LUES_CRASH_CMD"

@(private = "file")
CRASH_EXIT_ENV :: "LUES_CRASH_EXIT"

@(private = "file")
CRASH_PLUG_ENV :: "LUES_CRASH_PLUG"

@(private = "file")
CRASH_UNGUARDED_ENV :: "LUES_CRASH_UNGUARDED"

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
    unguarded := os.get_env(CRASH_UNGUARDED_ENV, context.temp_allocator) != ""
    testing.expect(t, test_host(&k, &box, {home = {data = data, state = data}, unguarded = unguarded}))
    k.hooks.say, k.user = heard, &said
    testing.expect(t, lues.loader_load(&k, lues.loader_path(&k, os.get_env(CRASH_PLUG_ENV, context.temp_allocator))))
    lues.fault_watchdog_start(200) // a child's own process: no other test to trip
    id := docs.store_open(&k.store)
    // Every command gets the grammar's path; only scan reads it.
    run(&k, os.get_env(CRASH_CMD_ENV, context.temp_allocator), id, lues.loader_path(&k, "grammar"))
    if os.get_env(CRASH_EXIT_ENV, context.temp_allocator) != "" {
        lues.kernel_destroy(&k)
        libc.exit(0) // libc's: it runs the destructors
    }
    testing.fail_now(t, "the process survived")
}
