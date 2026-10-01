package lues

import "base:intrinsics"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "../docs"

// Slots are tombstoned, never compacted: a bind row may hold an index across a reload.

PLUGIN_DIR :: "plugins" // <data>/plugins/<name>/<name>.so

Plugin :: struct {
    name:    string, // owned
    path:    string, // owned
    lib:     dynlib.Library,
    copy:    Maybe(linux.Fd), // the memfd it was mapped from; see load_fresh
    base:    uintptr, // where dlopen mapped it
    gen:     u32,
    state:   Plug_State,
    ledger:  [dynamic]Record,
    watch:   Event_Fn,
    seen:    map[docs.Id]Watch,
    held:    [dynamic]^View, // snapshots it holds past a call; released at unload
    objects: [dynamic]uintptr, // bases of objects it adopted; guard 1 blames it for these
    chain:   ^Chain, // its own fault handlers; its own allocation, so a thread can reach it
}

// A plugin's handlers for FAULT_SIGNALS, in that order, run before lues dies.
Chain :: [len(FAULT_SIGNALS)]posix.sigaction_t

// Faulted keeps the library mapped: dlclose would run more of the code that died.
Plug_State :: enum u8 {
    Unloaded,
    Live,
    Faulted,
}

Record_Kind :: enum u8 {
    Kind,
    Command,
    Point,
    Join,
    Var,
    Bind,
    Watch,
    Config,
    App,
}

Record :: struct {
    what:  Record_Kind,
    idx:   int,
    tag:   u32, // .App only: the app's record kind
    scope: Maybe(docs.Id), // the instance whose open added it; closing that doc reverts it
}

// For app api arms. Reverting hands the record to hooks.unregister.
ledger_add :: proc(k: ^Kernel, i: int, tag: u32, idx: int) {
    record(k, i, {what = .App, idx = idx, tag = tag})
}

record :: proc(k: ^Kernel, i: int, r: Record) {
    context = k.ctx
    r := r
    if k.opening.owner == i {
        r.scope = k.opening.doc
    }
    append(&k.plugs[i].ledger, r)
}

// What instance `id`'s open added, newest first.
scope_revert :: proc(k: ^Kernel, i: int, id: docs.Id) {
    context = k.ctx
    p := &k.plugs[i]
    reverted := false
    #reverse for r, j in p.ledger {
        if doc, scoped := r.scope.?; scoped && doc == id {
            revert(k, p, r)
            ordered_remove(&p.ledger, j)
            reverted = true
        }
    }
    if reverted {
        changed(k)
    }
}

loader_load :: proc(k: ^Kernel, path: string) -> bool {
    context = k.ctx
    name := strings.trim_suffix(filepath.base(path), ".so")
    if loader_find(k, name) >= 0 {
        say(k, fmt.tprintf("%s is already loaded", name))
        return false
    }
    lib, copy, loaded := load_fresh(path)
    if !loaded {
        say(k, fmt.tprintf("%s: %s", path, dynlib.last_error()))
        return false
    }
    sym, found := dynlib.symbol_address(lib, ENTRY)
    if !found {
        dynlib.unload_library(lib)
        copy_release(copy)
        say(k, fmt.tprintf("%s exports no %s", name, ENTRY))
        return false
    }

    quarantine_clear(k, name)
    i := loader_slot(k, name, path)
    p := &k.plugs[i]
    p.lib = lib
    p.copy = copy
    p.base = fault_object_base(sym)
    fault_runtime(rawptr(lib), p.base)
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
    context = k.ctx
    if i < 0 || i >= len(k.plugs) || k.plugs[i].state != .Live {
        return false
    }
    unload(k, i)
    return true
}

loader_faulted :: proc(k: ^Kernel, i: int, why: string, traced := false) {
    context = k.ctx
    if i < 0 || i >= len(k.plugs) || k.plugs[i].state != .Live {
        return // a nested dispatch may blame the same plugin twice
    }
    k.plugs[i].state = .Faulted
    unload(k, i)
    trace := fmt.tprintf("; trace in %s", fault_trace_path(k)) if traced else ""
    say(k, fmt.tprintf("%s %s, and is unloaded%s", k.plugs[i].name, why, trace))
}

// Unloads a plugin whose own thread faulted. The main thread only.
loader_reap :: proc(k: ^Kernel) {
    context = k.ctx
    v := intrinsics.atomic_exchange(&k.lost, 0)
    if v == 0 {
        return
    }
    i, gen := unpack(v)
    if int(i) < len(k.plugs) && k.plugs[i].gen == gen {
        loader_faulted(k, int(i), "faulted on a thread of its own", k.traces != nil)
    }
}

// In name order. Quarantined plugins are held back; loader_load lifts a quarantine.
loader_autoload :: proc(k: ^Kernel) {
    context = k.ctx
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
    context = k.ctx
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
    context = k.ctx
    for &p, i in k.plugs {
        if p.state != .Live && p.name == name {
            delete(p.path)
            p.path = strings.clone(path)
            return i
        }
    }
    append(&k.plugs, Plugin{name = strings.clone(name), path = strings.clone(path), chain = new(Chain)})
    return len(k.plugs) - 1
}

// Temp-allocated.
loader_path :: proc(k: ^Kernel, name: string) -> string {
    context = k.ctx
    file := fmt.tprintf("%s.so", name)
    path, _ := filepath.join({k.home.data, PLUGIN_DIR, name, file}, context.temp_allocator)
    return path
}

// dlopen shares a mapping with any earlier load of the same path or inode, and a faulted
// plugin stays mapped: a reload would get the old image back, globals as they were when it
// died. So each load maps its own copy, from a memfd. dlopen also matches by name, so the fd
// stays open while its image is mapped: no later copy is given the same /proc/self/fd name.
// dladdr names that path; the fault trace names `path` in its place. If the copy can't be
// made, `path` is loaded as is.
@(private = "file")
load_fresh :: proc(path: string) -> (lib: dynlib.Library, copy: Maybe(linux.Fd), ok: bool) {
    fd, copied := fresh_copy(path)
    if !copied {
        lib, ok = dynlib.load_library(path)
        return lib, nil, ok
    }
    if lib, ok = dynlib.load_library(copy_name(fd)); !ok {
        linux.close(fd)
        return nil, nil, false
    }
    return lib, fd, true
}

// After dlclose. dlclose can leave an object mapped (NODELETE, as one with thread-local
// destructors is); then its fd stays open for good.
@(private = "file")
copy_release :: proc(copy: Maybe(linux.Fd)) {
    fd, held := copy.?
    if !held {
        return
    }
    NOW_NOLOAD :: 0x2 | 0x4 // glibc's RTLD_NOW | RTLD_NOLOAD; posix has no NOLOAD
    name := strings.clone_to_cstring(copy_name(fd), context.temp_allocator)
    if still := posix.dlopen(name, transmute(posix.RTLD_Flags)i32(NOW_NOLOAD)); still != nil {
        posix.dlclose(still)
        return
    }
    linux.close(fd)
}

// Temp-allocated.
@(private = "file")
copy_name :: proc(fd: linux.Fd) -> string {
    return fmt.tprintf("/proc/self/fd/%d", fd)
}

@(private = "file")
fresh_copy :: proc(path: string) -> (fd: linux.Fd, ok: bool) {
    src, err := os.open(path)
    if err != nil {
        return -1, false
    }
    defer os.close(src)
    left, _ := os.file_size(src)
    name := strings.clone_to_cstring(filepath.base(path), context.temp_allocator)
    errno: linux.Errno
    if fd, errno = linux.memfd_create(name, {.CLOEXEC}); errno != .NONE {
        return -1, false
    }
    for left > 0 {
        n, e := linux.sendfile(fd, linux.Fd(os.fd(src)), nil, uint(left))
        if e != .NONE || n <= 0 {
            linux.close(fd)
            return -1, false
        }
        left -= i64(n)
    }
    return fd, true
}

self_handle :: proc(k: ^Kernel, i: int) -> Self {
    return Self(pack(u32(i), k.plugs[i].gen))
}

@(private = "file")
unload :: proc(k: ^Kernel, i: int) {
    stopped := fault_stop_threads(k, i)
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
    clear(&k.plugs[i].objects)
    k.plugs[i].chain^ = {}
    if who, published := producer_find(k, k.plugs[i].name); published {
        docs.spans_forget(&k.store, who)
    }
    p := &k.plugs[i]
    #reverse for r in p.ledger {
        revert(k, p, r)
    }
    clear(&p.ledger)
    // (hole plugin-arenas :tags (memory abi) :sev missing-system) no arena per plugin; what it allocated and still holds leaks on every unload.
    if p.state == .Live && !stopped {
        p.state = .Faulted
        say(k, fmt.tprintf("%s: a thread of its own did not stop, so it stays mapped", p.name))
    }
    if p.state == .Faulted {
        fault_dead(p.base, p.name, p.path)
    }
    if p.state == .Live {
        dynlib.unload_library(p.lib)
        p.state = .Unloaded
        copy_release(p.copy)
    }
    p.copy = nil // a faulted plugin's stays open with its mapping
    p.lib = nil
    changed(k)
}

@(private = "file")
revert :: proc(k: ^Kernel, p: ^Plugin, r: Record) {
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
    case .Point:
        pt := &k.points[r.idx]
        delete(pt.name)
        pt^ = {owner = -1}
    case .Join:
        j := &k.joins[r.idx]
        delete(j.name)
        j^ = {owner = -1}
    case .Var:
        k.vars[r.idx].owner = -1 // the values stay
    case .Bind:
        k.reqs[r.idx].dead = true // the row in the file stays
    case .Config:
        k.creqs[r.idx].dead = true
    case .Watch:
        p.watch = nil
        clear(&p.seen)
    case .App:
        if k.hooks.unregister != nil {
            context = k.host
            k.hooks.unregister(k, r)
        }
    }
}
