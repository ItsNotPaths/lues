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

cmd_call :: proc(k: ^Kernel, slot: int, focused: Maybe(docs.Id), args: string) -> (code: i32, ran: bool) {
    context = k.ctx
    if slot < 0 || slot >= len(k.cmds) || k.cmds[slot].owner < 0 {
        say(k, "that command's plugin is not loaded")
        return
    }
    return advice_run(k, slot, focused, args)
}

// A command or a hook listener. What it submitted lands before this returns.
fn_run :: proc(k: ^Kernel, owner: int, fn: Command_Fn, focused: Maybe(docs.Id), args: string) -> (code: i32, ran: bool) {
    at: At
    if id, ok := focused.?; ok {
        at = at_make(k, owner, id)
    }
    defer at_free(k, at)
    r := dispatch(k, owner, {what = .Command, fn = fn, at = &at, data = transmute([]u8)args}) or_return
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
