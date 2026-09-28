package lues

import "base:runtime"
import "core:os"
import "../docs"
import "../work"

// Owned. An empty `state` or `config` writes nothing.
Home :: struct {
    config: string, // binds.conf, config.conf
    data:   string, // plugins/
    state:  string, // quarantine, faults
}

// (hole rs-host-abi :tags (port host) :sev missing-port :needs (rs-kernel)) Hooks, Spec and the Box api tail are Odin types; oket needs them as a C ABI to link the crate.
// All nil-safe.
Hooks :: struct {
    say:        proc(k: ^Kernel, text: string),
    // Snapshot.app.
    side_make:  proc(k: ^Kernel, id: docs.Id, gen: u64) -> rawptr,
    side_free:  proc(k: ^Kernel, side: rawptr),
    land:       proc(k: ^Kernel, id: docs.Id, side: rawptr, landed: bool),
    // After each drain.
    drained:    proc(k: ^Kernel),
    // After each dispatch, on top of store_check.
    check:      proc(k: ^Kernel) -> bool,
    doc_open:   proc(k: ^Kernel, kind: Kind) -> (docs.Id, bool),
    doc_close:  proc(k: ^Kernel, id: docs.Id),
    kind_ctx:   proc(k: ^Kernel, name: string) -> (ctx: u32, ok: bool),
    unregister: proc(k: ^Kernel, r: Record),
    // A plugin loaded or unloaded.
    changed:    proc(k: ^Kernel),
    bind_held:  Bind_Held,
}

Spec :: struct {
    home:  Home,
    app:         cstring,
    app_version: u32,
    kind_base: u32,
    // Ids 0..; interned names follow.
    base_tokens: []string,
    hooks: Hooks,
    api:   ^Api, // inside a Box
    user:  rawptr,
}

// (hole rs-kernel :tags (port) :sev missing-port :needs (rs-docs rs-work rs-conf rs-loader rs-extern-panic rs-arenas)) the kernel proper (insts, commands, requests, tokens, io, views) is not a crate.
Kernel :: struct {
    using spec:  Spec,
    ctx:         runtime.Context, // api arms run in it
    store:       docs.Store,
    plugs:       [dynamic]Plugin,
    kinds:       [dynamic]Plug_Kind,
    cmds:        [dynamic]Plug_Cmd,
    insts:       map[docs.Id]Plug_Inst,
    io:          ^work.Pool,
    io_jobs:     map[work.Id]Io_Job,
    tokens:      [dynamic]string, // owned; base_tokens first
    producers:   [dynamic]string, // owned; a docs.Producer indexes this
    reqs:        [dynamic]Bind_Request,
    creqs:       [dynamic]Config_Request,
    quarantined: [dynamic]string,
    report:      ^os.File,
    traces:      ^os.File,
    // Bumped per plugin call but .App: plugins keep view state in their own memory, so cached
    // views key on this.
    ran:         u64,
}

// k must not move after this. The hang watchdog is the caller's to start.
kernel_init :: proc(k: ^Kernel, spec: Spec) -> bool {
    k.spec = spec
    // (hole rs-arenas :tags (port memory) :sev missing-port :needs (kernel-arenas pkey-tagging plugin-arenas)) arenas ride Odin's context allocator; Rust has no stable per-collection allocator to carry them.
    // (hole kernel-arenas :tags (memory) :sev missing-system) the kernel allocates from libc malloc, the heap plugins share, so a plugin overrun can crash kernel code.
    k.ctx = context
    tokens_seed(k)
    api_init(k)
    quarantine_open(k)
    fault_trace_open(k)
    return fault_install()
}

// Io first: a plugin's close must not see a completion arrive.
kernel_destroy :: proc(k: ^Kernel) {
    quarantine_destroy(k)
    fault_trace_close(k)
    io_destroy(k)
    #reverse for _, i in k.plugs {
        loader_unload(k, i)
    }
    for p in k.plugs {
        delete(p.name)
        delete(p.path)
        delete(p.ledger)
        delete(p.seen)
        delete(p.held)
    }
    delete(k.plugs)
    for kd in k.kinds {
        delete(kd.name)
    }
    delete(k.kinds)
    for c in k.cmds {
        delete(c.name)
        delete(c.doc)
    }
    delete(k.cmds)
    delete(k.insts)
    delete(k.io_jobs)
    tokens_destroy(k)
    producers_destroy(k)
    bind_requests_destroy(k)
    config_requests_destroy(k)
    docs.store_destroy(&k.store, land_side, k)
}

// Io before the moved pumps, so what an io handler wrote is reported once. True when a plugin
// latched: call again next frame even if nothing moved.
kernel_frame :: proc(k: ^Kernel) -> (latched: bool) {
    kernel_settle(k)
    io_pump(k)
    return pump_insts(k) | pump_watch(k)
}

say :: proc(k: ^Kernel, text: string) {
    if k.hooks.say != nil {
        k.hooks.say(k, text)
    }
}

changed :: proc(k: ^Kernel) {
    if k.hooks.changed != nil {
        k.hooks.changed(k)
    }
}

land_side :: proc(user: rawptr, id: docs.Id, side: rawptr, landed: bool) {
    k := (^Kernel)(user)
    if k.hooks.land != nil {
        k.hooks.land(k, id, side, landed)
    }
}

// Every drain goes through here, or a plugin is told about its own write.
kernel_settle :: proc(k: ^Kernel) {
    docs.store_drain(&k.store, land_side, k)
    if landed := docs.store_landed(&k.store); len(landed) > 0 {
        for id, &inst in k.insts {
            gen, _ := docs.store_gen(&k.store, id)
            watch_landed(&inst.told, gen, landed)
        }
        for &p in k.plugs {
            for id, &w in p.seen {
                gen, _ := docs.store_gen(&k.store, id)
                watch_landed(&w, gen, landed)
            }
        }
    }
    if k.hooks.drained != nil {
        k.hooks.drained(k)
    }
}
