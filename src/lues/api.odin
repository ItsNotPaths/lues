package lues

import "core:fmt"
import "core:slice"
import "core:strings"
import "../docs"

// `A` starts with Api. The `where` keeps the kernel pointer right before it for every A.
// Box and Kernel must not move after kernel_init.
Box :: struct($A: typeid) where align_of(A) <= align_of(^Kernel) {
    kernel: ^Kernel,
    api:    A,
}

// The app fills its own tail after this.
api_init :: proc(k: ^Kernel) {
    box_kernel(k.api)^ = k
    k.api^ = {
        version          = API,
        app_version      = k.app_version,
        app              = k.app,
        register_kind    = api_register_kind,
        register_command = api_register_command,
        request_bind     = api_request_bind,
        request_config   = api_request_config,
        register_token   = api_register_token,
        register_watch   = api_register_watch,
        submit           = api_submit,
        snapshot         = api_snapshot,
        release          = api_release,
        message          = api_message,
        io_spawn         = api_io_spawn,
        io_write         = api_io_write,
        io_watch         = api_io_watch,
        io_fd            = api_io_fd,
        io_close         = api_io_close,
    }
}

// Refuses a Self from an earlier load. Opens fault guard 2 until api_done.
api_kernel :: proc "c" (api: ^Api, self: Self) -> (k: ^Kernel, i: int, ok: bool) {
    if api == nil {
        return nil, 0, false
    }
    k = box_kernel(api)^
    idx, gen := unpack(u64(self))
    i = int(idx)
    if i >= len(k.plugs) || k.plugs[i].state != .Live || k.plugs[i].gen != gen {
        return nil, 0, false
    }
    fault_busy(true)
    return k, i, true
}

api_done :: proc "c" () {
    fault_busy(false)
}

@(private = "file")
box_kernel :: proc "contextless" (api: ^Api) -> ^^Kernel {
    return (^^Kernel)(uintptr(api) - size_of(^Kernel))
}

@(private = "file")
api_register_kind :: proc "c" (api: ^Api, self: Self, spec: ^Kind_Spec) -> Kind {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok || spec == nil || !has(spec.size, size_of(Kind_Spec)) {
        return 0
    }
    context = k.ctx
    name := string(spec.name[:spec.name_len])
    if name == "" {
        return 0
    }
    if _, taken := kind_named(k, name); taken {
        say(k, fmt.tprintf("%s: a kind called %s is already registered", k.plugs[i].name, name))
        return 0
    }
    ctx: u32
    if k.hooks.kind_ctx != nil {
        known: bool
        ctx, known = k.hooks.kind_ctx(k, string(spec.ctx[:spec.ctx_len]))
        if !known {
            say(k, fmt.tprintf("%s: %s is not a context", k.plugs[i].name, string(spec.ctx[:spec.ctx_len])))
            return 0
        }
    }
    append(&k.kinds, Plug_Kind{strings.clone(name), ctx, i, spec.vt})
    append(&k.plugs[i].ledger, Record{what = .Kind, idx = len(k.kinds) - 1})
    return Kind(int(k.kind_base) + len(k.kinds))
}

@(private = "file")
api_register_command :: proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: uint,
                                  doc: [^]u8, doc_len: uint, fn: Command_Fn) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok || fn == nil {
        return
    }
    context = k.ctx
    n := string(name[:name_len])
    if n == "" || strings.contains(n, " ") {
        return // could never be typed back
    }
    if _, taken := cmd_named(k, n); taken {
        say(k, fmt.tprintf("%s: :%s is already registered", k.plugs[i].name, n))
        return
    }
    append(&k.cmds, Plug_Cmd{strings.clone(n), strings.clone(string(doc[:doc_len])), i, fn})
    append(&k.plugs[i].ledger, Record{what = .Command, idx = len(k.cmds) - 1})
}

@(private = "file")
api_request_bind :: proc "c" (api: ^Api, self: Self, ctx: [^]u8, ctx_len: uint,
                              chord: [^]u8, chord_len: uint, line: [^]u8, line_len: uint) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    if bind_request(k, k.plugs[i].name, string(ctx[:ctx_len]), string(chord[:chord_len]),
                    string(line[:line_len])) {
        append(&k.plugs[i].ledger, Record{what = .Bind, idx = len(k.reqs) - 1})
    }
}

@(private = "file")
api_request_config :: proc "c" (api: ^Api, self: Self, section: [^]u8, section_len: uint,
                                key: [^]u8, key_len: uint, value: [^]u8, value_len: uint) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    if config_request(k, k.plugs[i].name, string(section[:section_len]), string(key[:key_len]),
                      string(value[:value_len])) {
        append(&k.plugs[i].ledger, Record{what = .Config, idx = len(k.creqs) - 1})
    }
}

@(private = "file")
api_register_token :: proc "c" (api: ^Api, self: Self, name: [^]u8, name_len: uint) -> Token {
    k, _, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return 0
    }
    context = k.ctx
    return token_intern(k, string(name[:name_len]))
}

// Registering twice replaces, with one ledger record.
@(private = "file")
api_register_watch :: proc "c" (api: ^Api, self: Self, fn: Event_Fn) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok || fn == nil {
        return
    }
    context = k.ctx
    p := &k.plugs[i]
    if p.watch == nil {
        append(&p.ledger, Record{what = .Watch})
    }
    p.watch = fn
    clear(&p.seen)
}

// Held until release, past the call.
@(private = "file")
api_snapshot :: proc "c" (api: ^Api, self: Self, doc: Doc_Handle) -> ^Snapshot {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return nil
    }
    context = k.ctx
    v := view_make(k, doc_id(doc))
    if v == nil {
        return nil
    }
    append(&k.plugs[i].held, v)
    return &v.snap
}

// Only a snapshot this plugin holds: a second release or a stranger's pointer is ignored.
@(private = "file")
api_release :: proc "c" (api: ^Api, self: Self, snap: ^Snapshot) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    held := &k.plugs[i].held
    if at, found := slice.linear_search(held[:], (^View)(snap)); found {
        unordered_remove(held, at)
        view_free(k, (^View)(snap))
    }
}

// A short struct drops the whole submit.
@(private = "file")
api_submit :: proc "c" (api: ^Api, self: Self, doc: Doc_Handle, gen: u64, edits: [^]Edit,
                        nedits: uint, spans: ^Span_Pub, flags: Submit_Flags) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    splices, whole := take_edits(edits, int(nedits))
    pub: Maybe(docs.Spans)
    if whole && spans != nil {
        runs: docs.Spans
        runs, whole = take_spans(k, i, spans)
        pub = runs
    }
    if !whole {
        say(k, fmt.tprintf("%s: a submit with a short struct was dropped", k.plugs[i].name))
        return
    }
    history := docs.History.Forget if .Forget in flags else .Join if .Join in flags else .Step
    id := doc_id(doc)
    tag := docs.store_submit(&k.store, id, gen, splices, pub, nil, history)
    if inst, held := &k.insts[id]; held && inst.owner == i {
        watch_submit(&inst.told, gen, tag)
    }
    if w, held := &k.plugs[i].seen[id]; held {
        watch_submit(w, gen, tag)
    }
}

// Temp-allocated. Offsets are clamped: they are the plugin's, not trusted.
@(private = "file")
take_edits :: proc(edits: [^]Edit, n: int) -> (out: []docs.Splice, ok: bool) {
    step := stride(Edit, edits, n) or_return
    out = make([]docs.Splice, n, context.temp_allocator)
    for &sp, j in out {
        e := elem(Edit, edits, step, j)
        sp = {off(e.lo), off(e.hi), e.text[:e.text_len], e.tag}
    }
    return out, true
}

@(private = "file")
take_spans :: proc(k: ^Kernel, i: int, pub: ^Span_Pub) -> (out: docs.Spans, ok: bool) {
    has(pub.size, size_of(Span_Pub)) or_return
    step := stride(Span, pub.spans, int(pub.nspans)) or_return
    list := make([]docs.Span_Run, pub.nspans, context.temp_allocator)
    for &run, j in list {
        sp := elem(Span, pub.spans, step, j)
        set := sp.set & {.Fg, .Bg, .Attrs} // stray bits are not channels
        run = {
            lo    = off(sp.lo),
            hi    = off(sp.hi),
            fg    = u32(sp.tok) if .Fg in set else 0,
            bg    = u32(sp.tok) if .Bg in set else 0,
            attrs = sp.attrs,
            set   = set,
        }
    }
    return {who = producer_intern(k, k.plugs[i].name), lo = off(pub.lo), hi = off(pub.hi), list = list}, true
}

@(private = "file")
off :: proc(v: uint) -> int {
    return int(min(v, uint(max(int))))
}

@(private = "file")
api_message :: proc "c" (api: ^Api, self: Self, text: [^]u8, text_len: uint) {
    k, _, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    say(k, string(text[:text_len]))
}
