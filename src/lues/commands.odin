package lues

import "../docs"

// A bind row holds the index.
Plug_Cmd :: struct {
    name:  string, // owned
    doc:   string, // owned
    owner: int,
    fn:    Command_Fn,
}

// True on exit 0.
cmd_run :: proc(k: ^Kernel, slot: int, focused: Maybe(docs.Id), args: string) -> bool {
    code, ran := cmd_call(k, slot, focused, args)
    return ran && code == 0
}

// What it submitted lands before this returns.
cmd_call :: proc(k: ^Kernel, slot: int, focused: Maybe(docs.Id), args: string) -> (code: i32, ran: bool) {
    context = k.ctx
    if slot < 0 || slot >= len(k.cmds) || k.cmds[slot].owner < 0 {
        say(k, "that command's plugin is not loaded")
        return
    }
    c := k.cmds[slot]
    at: At
    if id, ok := focused.?; ok {
        at = at_make(k, c.owner, id)
    }
    defer at_free(k, at)
    // (hole advice :tags (compose abi) :sev missing-system) the command's own fn always runs; another plugin cannot wrap it.
    r := dispatch(k, c.owner, {what = .Command, fn = c.fn, at = &at, data = transmute([]u8)args}) or_return
    kernel_settle(k)
    return r.code, true
}

cmd_named :: proc(k: ^Kernel, name: string) -> (int, bool) {
    for c, i in k.cmds {
        if c.owner >= 0 && c.name == name {
            return i, true
        }
    }
    return 0, false
}
