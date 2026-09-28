package lues

import "core:slice"
import "../docs"

// `latch`: call again next frame.
Watch :: struct {
    gen:   u64,
    tag:   u64, // its own pending submit, based on `gen`; not reported back to it
    latch: bool,
}

// `owner` = -1 after unload; the id stays and resolves to nothing.
Plug_Kind :: struct {
    name:  string, // owned
    ctx:   u32, // from hooks.kind_ctx
    owner: int,
    vt:    Kind_Vt,
}

Plug_Inst :: struct {
    owner:      int,
    kind:       Kind,
    inst:       rawptr,
    using told: Watch,
}

// The doc exists before the plugin's code runs, so a faulted open leaves no half-made doc.
// What open submits lands before this returns; whether that is undoable is the app's call.
inst_open :: proc(k: ^Kernel, kind: Kind, args := "") -> (id: docs.Id, ok: bool) {
    kd := kind_get(k, kind) or_return
    if kd.vt.open == nil {
        return
    }
    if k.hooks.doc_open != nil {
        id = k.hooks.doc_open(k, kind) or_return
    } else {
        id = docs.store_open(&k.store)
    }
    r, ran := dispatch(k, kd.owner, {what = .Open, vt = kd.vt, doc = doc_handle(id), data = transmute([]u8)args})
    if !ran {
        doc_close(k, id)
        return {}, false
    }
    kernel_settle(k)
    gen, _ := docs.store_gen(&k.store, id) // where open left it, so it is not reported back
    k.insts[id] = {kd.owner, kind, r.inst, {gen = gen}}
    return id, true
}

// Through the app when it has a doc_close hook, which must call inst_close.
doc_close :: proc(k: ^Kernel, id: docs.Id) {
    if k.hooks.doc_close != nil {
        k.hooks.doc_close(k, id)
        return
    }
    inst_close(k, id)
    docs.store_close(&k.store, id)
}

// The app calls this for every doc it closes. A faulted plugin's close does not run.
inst_close :: proc(k: ^Kernel, id: docs.Id) {
    inst, held := k.insts[id]
    if !held {
        return
    }
    delete_key(&k.insts, id)
    kd, ok := kind_get(k, inst.kind)
    if k.plugs[inst.owner].state == .Live && ok && kd.vt.close != nil {
        _, _ = dispatch(k, inst.owner, {what = .Close, vt = kd.vt, doc = doc_handle(id), inst = inst.inst})
    }
}

// False: nothing took it. What it submits lands before this returns, so two events in one
// frame are not written against the same gen.
inst_event :: proc(k: ^Kernel, id: docs.Id, ev: Event, text: string) -> bool {
    inst, held := k.insts[id]
    if !held {
        return false
    }
    kd, ok := kind_get(k, inst.kind)
    if !ok || kd.vt.event == nil {
        return false
    }
    at := at_make(k, inst.owner, id)
    defer at_free(k, at)
    r, ran := dispatch(k, inst.owner, {what = .Event, vt = kd.vt, at = &at, ev = ev, data = transmute([]u8)text})
    if !ran {
        return false
    }
    kernel_settle(k)
    return r.code != 0
}

// Owners hear .Moved for their own docs. Who to tell is decided first: a fault unloads its
// plugin, which deletes from insts.
pump_insts :: proc(k: ^Kernel) -> (latched: bool) {
    moved := make([dynamic]docs.Id, 0, len(k.insts), context.temp_allocator)
    for id, &inst in k.insts {
        gen := docs.store_gen(&k.store, id) or_continue
        if watch_due(inst.told, gen) {
            append(&moved, id)
        }
        inst.told = {gen = gen}
    }
    for id in moved {
        inst := k.insts[id] or_continue // its plugin died earlier in this loop
        kd, ok := kind_get(k, inst.kind)
        if !ok || kd.vt.event == nil {
            continue
        }
        latched |= tell(k, inst.owner, id, {what = .Event, vt = kd.vt, ev = .Moved})
    }
    return
}

// Watchers hear .Moved for every doc.
pump_watch :: proc(k: ^Kernel) -> (latched: bool) {
    ids := docs.store_ids(&k.store)
    for &p, i in k.plugs {
        if p.state != .Live || p.watch == nil {
            continue
        }
        due := make([dynamic]docs.Id, 0, len(ids), context.temp_allocator)
        for id in ids {
            gen, _ := docs.store_gen(&k.store, id)
            w, told := p.seen[id]
            if !told || watch_due(w, gen) {
                append(&due, id)
            }
            p.seen[id] = {gen = gen}
        }
        watch_prune(&p, ids)
        for id in due {
            if p.state != .Live {
                break // it faulted on an earlier doc
            }
            latched |= tell(k, i, id, {what = .Watch, fn_ev = p.watch, ev = .Moved})
        }
    }
    return
}

// One .Moved call. A non-zero answer latches: call again next pump.
@(private = "file")
tell :: proc(k: ^Kernel, i: int, id: docs.Id, c: Call) -> (latched: bool) {
    c := c
    at := at_make(k, i, id)
    defer at_free(k, at)
    c.at = &at
    r := dispatch(k, i, c) or_return
    latched = r.code != 0
    if c.what == .Watch {
        if w, held := &k.plugs[i].seen[id]; held {
            w.latch = latched
        }
    } else if inst, held := &k.insts[id]; held {
        inst.latch = latched
    }
    return
}

@(private = "file")
watch_prune :: proc(p: ^Plugin, ids: []docs.Id) {
    dead := make([dynamic]docs.Id, 0, len(p.seen), context.temp_allocator)
    for id in p.seen {
        if !slice.contains(ids, id) {
            append(&dead, id)
        }
    }
    for id in dead {
        delete_key(&p.seen, id)
    }
}

watch_due :: proc(w: Watch, gen: u64) -> bool {
    return w.latch || gen != w.gen
}

// Tags a plugin's own submit, only when it is based on what it was last told: then nothing
// unreported is swallowed when it lands.
watch_submit :: proc(w: ^Watch, gen, tag: u64) {
    if w.gen == gen {
        w.tag = tag
    }
}

// After a drain: a watch whose own submit landed is told the new gen.
watch_landed :: proc(w: ^Watch, gen: u64, landed: []u64) {
    if w.tag != 0 && slice.contains(landed, w.tag) {
        w.gen, w.tag = gen, 0
    }
}

// `inst` only when the doc is the caller's own. Free with at_free.
at_make :: proc(k: ^Kernel, i: int, id: docs.Id) -> At {
    v := view_make(k, id)
    if v == nil {
        return {}
    }
    inst, held := k.insts[id]
    return {doc = doc_handle(id), inst = inst.inst if held && inst.owner == i else nil, snap = &v.snap}
}

at_free :: proc(k: ^Kernel, at: At) {
    view_free(k, (^View)(at.snap))
}

// Plugin kind ids start at kind_base + 1.
kind_get :: proc(k: ^Kernel, kind: Kind) -> (Plug_Kind, bool) {
    i := int(kind) - int(k.kind_base) - 1
    if i < 0 || i >= len(k.kinds) || k.kinds[i].owner < 0 {
        return {}, false
    }
    return k.kinds[i], true
}

kind_named :: proc(k: ^Kernel, name: string) -> (Kind, bool) {
    for kd, i in k.kinds {
        if kd.owner >= 0 && kd.name == name {
            return Kind(int(k.kind_base) + i + 1), true
        }
    }
    return 0, false
}
