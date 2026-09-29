package lues

import "../docs"

// A bind row holds the index.
Plug_Cmd :: struct {
    name:  string, // owned
    doc:   string, // owned
    owner: int,
    fn:    Command_Fn,
}

// True on exit 0. What it submitted lands before this returns.
cmd_run :: proc(k: ^Kernel, slot: int, focused: Maybe(docs.Id), args: string) -> bool {
    context = k.ctx
    if slot < 0 || slot >= len(k.cmds) || k.cmds[slot].owner < 0 {
        say(k, "that command's plugin is not loaded")
        return false
    }
    c := k.cmds[slot]
    at: At
    if id, ok := focused.?; ok {
        at = at_make(k, c.owner, id)
    }
    defer at_free(k, at)
    // (hole advice :tags (compose abi) :sev missing-system :needs (plugin-calls)) the command's own fn always runs; another plugin cannot wrap it.
    r, ok := dispatch(k, c.owner, {what = .Command, fn = c.fn, at = &at, data = transmute([]u8)args})
    if !ok {
        return false
    }
    kernel_settle(k)
    return r.code == 0
}

cmd_named :: proc(k: ^Kernel, name: string) -> (int, bool) {
    for c, i in k.cmds {
        if c.owner >= 0 && c.name == name {
            return i, true
        }
    }
    return 0, false
}
