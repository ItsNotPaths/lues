package lues

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../docs"

// Slots are tombstoned, never compacted: a bind row may hold an index across a reload.

PLUGIN_DIR :: "plugins" // <data>/plugins/<name>/<name>.so

Plugin :: struct {
    name:    string, // owned
    path:    string, // owned
    lib:     dynlib.Library,
    base:    uintptr, // where dlopen mapped it
    gen:     u32,
    state:   Plug_State,
    ledger:  [dynamic]Record,
    watch:   Event_Fn,
    seen:    map[docs.Id]Watch,
    held:    [dynamic]^View, // snapshots it holds past a call; released at unload
}

// Faulted keeps the library mapped: dlclose would run more of the code that died.
Plug_State :: enum u8 {
    Unloaded,
    Live,
    Faulted,
}

Record_Kind :: enum u8 {
    Kind,
    Command,
    Bind,
    Watch,
    Config,
    App,
}

Record :: struct {
    what: Record_Kind,
    idx:  int,
    tag:  u32, // .App only: the app's record kind
}

// For app api arms. Unload hands the record to hooks.unregister.
ledger_add :: proc(k: ^Kernel, i: int, tag: u32, idx: int) {
    append(&k.plugs[i].ledger, Record{what = .App, idx = idx, tag = tag})
}

// (hole rs-loader :tags (port loader) :sev missing-port :needs (rs-plugin-abi rs-fault-handlers reload-fresh-map)) the loader, ledger and quarantine are Odin only.
loader_load :: proc(k: ^Kernel, path: string) -> bool {
    name := strings.trim_suffix(filepath.base(path), ".so")
    if loader_find(k, name) >= 0 {
        say(k, fmt.tprintf("%s is already loaded", name))
        return false
    }
    // (hole reload-fresh-map :tags (loader fault) :sev wrong-behavior) a faulted plugin stays mapped, so reloading it gets the same image back with its old globals instead of a clean copy.
    lib, loaded := dynlib.load_library(path)
    if !loaded {
        say(k, fmt.tprintf("%s: %s", path, dynlib.last_error()))
        return false
    }
    sym, found := dynlib.symbol_address(lib, ENTRY)
    if !found {
        dynlib.unload_library(lib)
        say(k, fmt.tprintf("%s exports no %s", name, ENTRY))
        return false
    }

    quarantine_clear(k, name)
    i := loader_slot(k, name, path)
    p := &k.plugs[i]
    p.lib = lib
    p.base = fault_object_base(sym)
    p.gen += 1
    p.state = .Live

    r, ok := dispatch(k, i, {what = .Entry, entry = Entry_Fn(sym)})
    if !ok {
        return false // faulted; already unloaded
    }
    if r.code != 0 {
        loader_unload(k, i)
        say(k, fmt.tprintf("%s refused to load (%d)", name, r.code))
        return false
    }
    changed(k)
    return true
}

loader_unload :: proc(k: ^Kernel, i: int) -> bool {
    if i < 0 || i >= len(k.plugs) || k.plugs[i].state != .Live {
        return false
    }
    unload(k, i)
    return true
}

loader_faulted :: proc(k: ^Kernel, i: int, why: string, traced := false) {
    if i < 0 || i >= len(k.plugs) || k.plugs[i].state != .Live {
        return // a nested dispatch may blame the same plugin twice
    }
    k.plugs[i].state = .Faulted
    unload(k, i)
    trace := fmt.tprintf("; trace in %s", fault_trace_path(k)) if traced else ""
    say(k, fmt.tprintf("%s %s, and is unloaded%s", k.plugs[i].name, why, trace))
}

// In name order. Quarantined plugins are held back; loader_load lifts a quarantine.
loader_autoload :: proc(k: ^Kernel) {
    dir, _ := filepath.join({k.home.data, PLUGIN_DIR}, context.temp_allocator)
    f, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(f)
    it := os.read_directory_iterator_create(f)
    defer os.read_directory_iterator_destroy(&it)
    found := make([dynamic]string, context.temp_allocator)
    for info in os.read_directory_iterator(&it) {
        if info.type == .Directory && os.exists(loader_path(k, info.name)) {
            append(&found, strings.clone(info.name, context.temp_allocator))
        }
    }
    slice.sort(found[:])
    held := make([dynamic]string, context.temp_allocator)
    for name in found {
        if quarantined(k, name) {
            append(&held, name)
        } else {
            loader_load(k, loader_path(k, name))
        }
    }
    if len(held) > 0 {
        say(k, fmt.tprintf("%s took a start down and %s not loaded",
                           strings.join(held[:], ", ", context.temp_allocator),
                           len(held) == 1 ? "is" : "are"))
    }
}

loader_reload :: proc(k: ^Kernel, name: string) -> bool {
    i := loader_find(k, name)
    if i < 0 {
        say(k, fmt.tprintf("%s is not loaded", name))
        return false
    }
    path := strings.clone(k.plugs[i].path, context.temp_allocator)
    loader_unload(k, i)
    return loader_load(k, path)
}

loader_find :: proc(k: ^Kernel, name: string) -> int {
    for p, i in k.plugs {
        if p.state == .Live && p.name == name {
            return i
        }
    }
    return -1
}

// Reused per name; the bumped gen makes an old Self refuse.
loader_slot :: proc(k: ^Kernel, name, path: string) -> int {
    for &p, i in k.plugs {
        if p.state != .Live && p.name == name {
            delete(p.path)
            p.path = strings.clone(path)
            return i
        }
    }
    append(&k.plugs, Plugin{name = strings.clone(name), path = strings.clone(path)})
    return len(k.plugs) - 1
}

// Temp-allocated.
loader_path :: proc(k: ^Kernel, name: string) -> string {
    file := fmt.tprintf("%s.so", name)
    path, _ := filepath.join({k.home.data, PLUGIN_DIR, name, file}, context.temp_allocator)
    return path
}

self_handle :: proc(k: ^Kernel, i: int) -> Self {
    return Self(pack(u32(i), k.plugs[i].gen))
}

@(private = "file")
unload :: proc(k: ^Kernel, i: int) {
    // Collected first: closing deletes from insts.
    mine := make([dynamic]docs.Id, 0, len(k.insts), context.temp_allocator)
    for id, inst in k.insts {
        if inst.owner == i {
            append(&mine, id)
        }
    }
    for id in mine {
        doc_close(k, id)
    }
    io_forget(k, i)
    for v in k.plugs[i].held {
        view_free(k, v)
    }
    clear(&k.plugs[i].held)
    if who, published := producer_find(k, k.plugs[i].name); published {
        docs.spans_forget(&k.store, who)
    }
    p := &k.plugs[i]
    #reverse for r in p.ledger {
        switch r.what {
        case .Kind:
            kd := &k.kinds[r.idx]
            delete(kd.name)
            kd^ = {owner = -1}
        case .Command:
            c := &k.cmds[r.idx]
            delete(c.name)
            delete(c.doc)
            c^ = {owner = -1}
        case .Bind:
            k.reqs[r.idx].dead = true // the row in the file stays
        case .Config:
            k.creqs[r.idx].dead = true
        case .Watch:
            p.watch = nil
            clear(&p.seen)
        case .App:
            if k.hooks.unregister != nil {
                k.hooks.unregister(k, r)
            }
        }
    }
    clear(&p.ledger)
    // (hole plugin-arenas :tags (memory abi) :sev missing-system :needs (kernel-arenas)) no arena per plugin; what a faulted plugin allocated leaks.
    if p.state == .Live {
        dynlib.unload_library(p.lib)
        p.state = .Unloaded
    }
    p.lib = nil
    changed(k)
}
