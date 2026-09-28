package lues

import "../docs"

// Every plugin call goes through dispatch. A fault there is `ok = false` with the plugin unloaded.

Ret :: struct {
    inst: rawptr,
    code: i32,
}

App_Fn :: #type proc(api: ^Api, self: Self, data: rawptr) -> i32

// (hole rs-dispatch-trampoline :tags (port fault) :sev missing-port :needs (nested-dispatch-blame)) Rust cannot hold a sigsetjmp frame; dispatch needs a C or asm trampoline for the jump back.
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

// A nested dispatch runs unguarded; the outer net blames the outer plugin.
dispatch :: proc(k: ^Kernel, i: int, c: Call) -> (r: Ret, ok: bool) {
    if c.what != .App {
        k.ran += 1
    }
    // (hole nested-dispatch-blame :tags (fault compose) :sev wrong-behavior) one guard per thread: a fault in a nested call blames and unloads the outer plugin.
    if !fault_ready() || fault_armed() {
        r = run(k, i, c)
        return r, intact(k, i)
    }
    if sigsetjmp(fault_env(), 1) != 0 {
        fault_reap() // locals of this frame are not restored
        return {}, false
    }
    fault_arm(k, i, k.plugs[i].base, k.plugs[i].name)
    r = run(k, i, c)
    fault_disarm()
    return r, intact(k, i)
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
