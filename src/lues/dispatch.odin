package lues

import "core:fmt"
import "../docs"

// Every plugin call goes through dispatch. A fault there is `ok = false` with the plugin unloaded.

Ret :: struct {
    inst: rawptr,
    code: i32,
}

App_Fn :: #type proc(api: ^Api, self: Self, data: rawptr) -> i32

// (hole rs-dispatch-trampoline :tags (port fault) :sev missing-port) Rust cannot hold a sigsetjmp frame; dispatch needs a C or asm trampoline for the jump back.
// Data, so the sigsetjmp sits in the frame that makes the call.
Call :: struct {
    what:  enum {
        Entry,
        Open,
        Close,
        Event,
        Watch,
        Command,
        App,
    },
    entry: Entry_Fn,
    vt:    Kind_Vt,
    fn:    Command_Fn,
    fn_ev: Event_Fn,
    doc:   Doc_Handle,
    at:    ^At,
    inst:  rawptr,
    ev:    Event,
    data:  []u8,
    app:   App_Fn,
    arg:   rawptr, // for .App
}

// A dispatch from inside an api call nests: its own frame on the fault guard, so a fault is
// blamed on the plugin that was running, and the call that nested it goes on. When a nested
// fault unloads a plugin that is also further down the stack, its outer calls come back
// `ok = false`, so nothing it returns is kept.
dispatch :: proc(k: ^Kernel, i: int, c: Call) -> (r: Ret, ok: bool) {
    if c.what != .App {
        k.ran += 1
    }
    if !fault_ready() {
        r = run(k, i, c)
        return r, intact(k, i)
    }
    if fault_full() {
        say(k, fmt.tprintf("%s: calls nested more than %d deep", k.plugs[i].name, FAULT_DEPTH))
        return {}, false
    }
    gen := k.plugs[i].gen
    if sigsetjmp(fault_env(), 1) != 0 {
        fault_reap() // locals of this frame are not restored
        return {}, false
    }
    fault_arm(k, i)
    r = run(k, i, c)
    fault_disarm()
    return r, intact(k, i) && k.plugs[i].state == .Live && k.plugs[i].gen == gen
}

@(private = "file")
intact :: proc(k: ^Kernel, i: int) -> bool {
    if docs.store_check(&k.store) && (k.hooks.check == nil || k.hooks.check(k)) {
        return true
    }
    loader_faulted(k, i, "left a document corrupt")
    return false
}

@(private = "file")
run :: proc(k: ^Kernel, i: int, c: Call) -> (r: Ret) {
    api, self := k.api, self_handle(k, i)
    switch c.what {
    case .Entry:
        r.code = c.entry(api, self)
    case .Open:
        r.inst = c.vt.open(api, self, c.doc, raw_data(c.data), len(c.data))
    case .Close:
        c.vt.close(api, self, c.doc, c.inst)
    case .Event:
        r.code = c.vt.event(api, self, c.at, c.ev, raw_data(c.data), len(c.data))
    case .Watch:
        r.code = c.fn_ev(api, self, c.at, c.ev, raw_data(c.data), len(c.data))
    case .Command:
        r.code = c.fn(api, self, c.at, raw_data(c.data), len(c.data))
    case .App:
        r.code = c.app(api, self, c.arg)
    }
    return
}
