package lues

import "core:slice"
import "../docs"

// Plugin hooks. Joins are by name, not by point, so a listener can come before its definer.

// `owner` = -1 after unload, as with commands.
Hook_Point :: struct {
    name:  string, // owned
    owner: int,
    mode:  Hook_Mode,
}

Hook_Join :: struct {
    name:  string, // owned
    owner: int,
    fn:    Command_Fn,
    order: i64, // ascending; a prepend is negative
}

point_named :: proc(k: ^Kernel, name: string) -> (int, bool) {
    for p, i in k.points {
        if p.owner >= 0 && p.name == name {
            return i, true
        }
    }
    return 0, false
}

// 0, or under .Bail the exit that stopped it. Who is due is taken first: a listener that faults
// is unloaded mid-run, and one may join while it runs.
point_run :: proc(k: ^Kernel, point: int, focused: docs.Id, args: string) -> i32 {
    context = k.ctx
    Due :: struct {
        order: i64,
        join:  int,
    }
    p := k.points[point]
    due := make([dynamic]Due, context.temp_allocator)
    for j, n in k.joins {
        if j.owner >= 0 && j.name == p.name {
            append(&due, Due{j.order, n})
        }
    }
    slice.sort_by(due[:], proc(a, b: Due) -> bool { return a.order < b.order })
    for d in due {
        j := k.joins[d.join]
        if j.owner < 0 {
            continue // unloaded earlier in this run
        }
        code, ran := fn_run(k, j.owner, j.fn, focused, args)
        if ran && p.mode == .Bail && code != 0 {
            return code
        }
    }
    return 0
}
