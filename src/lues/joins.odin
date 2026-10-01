package lues

import "core:slice"
import "core:strings"
import "../docs"

// Hook listeners, command advice and doc-var watches. All join by name, so they can come
// before what they join.

// `owner` = -1 after unload, as with commands.
Hook_Point :: struct {
    name:  string, // owned
    owner: int,
    mode:  Hook_Mode,
}

Join :: struct {
    name:  string, // owned
    owner: int,
    fn:    Command_Fn,
    how:   Join_How,
    order: i64, // ascending; a prepend is negative
}

// One advised command call: its joins, outermost first.
Advice_Run :: struct {
    slot:    int,
    due:     []int,
    focused: Maybe(docs.Id),
}

// The around advice running now, innermost last; next continues from it.
Around :: struct {
    run:   ^Advice_Run,
    level: int,
}

point_named :: proc(k: ^Kernel, name: string) -> (int, bool) {
    for p, i in k.points {
        if p.owner >= 0 && p.name == name {
            return i, true
        }
    }
    return 0, false
}

join_add :: proc(k: ^Kernel, i: int, name: string, fn: Command_Fn, how: Join_How, flags: Join_Flags) {
    context = k.ctx
    k.join_seq += 1
    order := -k.join_seq if .Prepend in flags else k.join_seq
    append(&k.joins, Join{strings.clone(name), i, fn, how, order})
    record(k, i, {what = .Join, idx = len(k.joins) - 1})
}

// Temp-allocated, in run order. Taken before the run: a joiner that faults is unloaded
// mid-run, and one may join while it runs.
joins_due :: proc(k: ^Kernel, name: string, hows: bit_set[Join_How]) -> []int {
    Due :: struct {
        order: i64,
        join:  int,
    }
    due := make([dynamic]Due, context.temp_allocator)
    for j, n in k.joins {
        if j.owner >= 0 && j.name == name && j.how in hows {
            append(&due, Due{j.order, n})
        }
    }
    slice.sort_by(due[:], proc(a, b: Due) -> bool { return a.order < b.order })
    out := make([]int, len(due), context.temp_allocator)
    for d, n in due {
        out[n] = d.join
    }
    return out
}

point_run :: proc(k: ^Kernel, point: int, focused: docs.Id, args: string) -> i32 {
    context = k.ctx
    p := k.points[point]
    return joins_emit(k, joins_due(k, p.name, {.Hook}), focused, args, p.mode == .Bail)
}

// 0, or with `bail` the first non-zero exit, which stops the rest.
joins_emit :: proc(k: ^Kernel, due: []int, focused: docs.Id, args: string, bail := false) -> i32 {
    for n in due {
        j := k.joins[n]
        if j.owner < 0 {
            continue // unloaded earlier in this run
        }
        code, ran := fn_run(k, j.owner, j.fn, focused, args)
        if ran && bail && code != 0 {
            return code
        }
    }
    return 0
}

advice_run :: proc(k: ^Kernel, slot: int, focused: Maybe(docs.Id), args: string) -> (code: i32, ran: bool) {
    context = k.ctx
    run := Advice_Run{slot, joins_due(k, k.cmds[slot].name, {.Before, .After, .Around}), focused}
    return advice_step(k, &run, 0, args)
}

// From `level` in, then the command. A before or after that faults is skipped; an around that
// faults fails the call.
advice_step :: proc(k: ^Kernel, run: ^Advice_Run, level: int, args: string) -> (code: i32, ran: bool) {
    for l in level ..< len(run.due) {
        j := k.joins[run.due[l]]
        #partial switch j.how {
        case .Before:
            if j.owner >= 0 {
                fn_run(k, j.owner, j.fn, run.focused, args)
            }
        case .After:
            code, ran = advice_step(k, run, l + 1, args)
            if k.joins[run.due[l]].owner >= 0 {
                fn_run(k, j.owner, j.fn, run.focused, args)
            }
            return
        case .Around:
            if j.owner < 0 {
                continue
            }
            append(&k.arounds, Around{run, l})
            code, ran = fn_run(k, j.owner, j.fn, run.focused, args)
            pop(&k.arounds)
            return
        }
    }
    c := k.cmds[run.slot]
    if c.owner < 0 {
        return // its plugin went during the advice
    }
    return fn_run(k, c.owner, c.fn, run.focused, args)
}
