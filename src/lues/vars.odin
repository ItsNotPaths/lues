package lues

import "core:slice"
import "../docs"

// Doc-vars: named bytes per doc. The definer writes; anyone reads and watches. The values are
// data: an unload keeps them, read-only, until a plugin of the same name defines it again.

Doc_Var :: struct {
    name:   string, // owned
    plugin: string, // owned; the definer's name, which can take it back
    owner:  int, // -1 while its plugin is away
    values: map[docs.Id][]u8, // owned
}

var_named :: proc(k: ^Kernel, name: string) -> (int, bool) {
    for v, i in k.vars {
        if v.name == name {
            return i, true
        }
    }
    return 0, false
}

// Watchers run with the doc focused and the new value as args.
var_set :: proc(k: ^Kernel, v: int, id: docs.Id, value: []u8) {
    context = k.ctx
    old, held := k.vars[v].values[id]
    if held && string(old) == string(value) {
        return
    }
    delete(old)
    k.vars[v].values[id] = slice.clone(value)
    joins_emit(k, joins_due(k, k.vars[v].name, {.Watch}), id, string(value))
}

// A closed doc's values go with it. The app calls inst_close for every doc it closes.
vars_forget :: proc(k: ^Kernel, id: docs.Id) {
    context = k.ctx
    for &v in k.vars {
        if value, held := v.values[id]; held {
            delete(value)
            delete_key(&v.values, id)
        }
    }
}

vars_destroy :: proc(k: ^Kernel) {
    context = k.ctx
    for v in k.vars {
        delete(v.name)
        delete(v.plugin)
        for _, value in v.values {
            delete(value)
        }
        delete(v.values)
    }
    delete(k.vars)
}
