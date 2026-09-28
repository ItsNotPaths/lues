package lues

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../conf"

// A plugin asks for a chord or a config key once; the file decides after that.

// Binds and config mark each owner's block with the same line.
owner_marker :: proc(owner: string) -> string {
    return fmt.tprintf("# --- %s ---", owner)
}

// Owners with a live request and no marker in `text` yet, in name order, so which of two
// asking for one thing wins does not depend on load order. Temp-allocated.
new_owners :: proc(reqs: []$T, text: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for r in reqs {
        if !r.dead && !slice.contains(out[:], r.owner) && !strings.contains(text, owner_marker(r.owner)) {
            append(&out, r.owner)
        }
    }
    slice.sort(out[:])
    return out[:]
}

// --- binds ---

BINDS_NAME :: "binds.conf"

Bind_Request :: struct {
    owner: string, // owned; the header it is written under
    ctx:   string, // owned
    chord: string, // owned
    line:  string, // owned
    dead:  bool, // plugin unloaded; the row stays in the file
}

// What the app's bind table holds for a chord; `held` names what answers it.
Bind_Held :: proc(k: ^Kernel, ctx, chord: string) -> (held: string, hold: Bind_Hold)

Bind_Hold :: enum u8 {
    Free,
    Taken, // on this ctx
    Shadowed, // a wider ctx answers it
}

// An empty ctx is "global".
bind_request :: proc(k: ^Kernel, owner, ctx, chord, line: string) -> bool {
    if owner == "" || chord == "" || line == "" {
        return false
    }
    append(&k.reqs, Bind_Request{
        strings.clone(owner),
        strings.clone(ctx if ctx != "" else "global"),
        strings.clone(chord),
        strings.clone(line),
        false,
    })
    return true
}

bind_requests_destroy :: proc(k: ^Kernel) {
    for r in k.reqs {
        delete(r.owner)
        delete(r.ctx)
        delete(r.chord)
        delete(r.line)
    }
    delete(k.reqs)
}

// Appends a section per owner the file has no header for. A taken chord is written commented
// and said; a shadowing one goes in live with a note. True when the file changed.
bind_writeback :: proc(k: ^Kernel, path: string) -> bool {
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    text := string(raw)
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, text)
    if text != "" && !strings.has_suffix(text, "\n") {
        strings.write_byte(&b, '\n')
    }
    // "<ctx> <chord>" written this run: two owners asking in one batch are not in the table yet.
    seen := make(map[string]string, 0, context.temp_allocator)
    wrote := false
    for owner in new_owners(k.reqs[:], text) {
        fmt.sbprintf(&b, "\n%s\n", owner_marker(owner))
        bind_rows(k, &b, owner, &seen)
        wrote = true
    }
    return wrote && os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

@(private = "file")
bind_rows :: proc(k: ^Kernel, b: ^strings.Builder, owner: string, seen: ^map[string]string) {
    section := ""
    for row in k.reqs {
        if row.dead || row.owner != owner {
            continue
        }
        if section != row.ctx {
            fmt.sbprintf(b, "[%s]\n", row.ctx)
            section = row.ctx
        }
        key := fmt.tprintf("%s %s", row.ctx, row.chord)
        held, hold := bind_held(k, row.ctx, row.chord)
        if other, asked := seen[key]; hold != .Taken && asked {
            held, hold = other, .Taken
        }
        if hold == .Taken {
            fmt.sbprintf(b, "# %s = %s   # taken by %s\n", row.chord, row.line, held)
            say(k, fmt.tprintf("%s: %s is taken by %s", owner, row.chord, held))
            continue
        }
        seen[key] = owner
        if hold == .Shadowed {
            fmt.sbprintf(b, "# shadows %s\n", held)
        }
        fmt.sbprintf(b, "%s = %s\n", row.chord, row.line)
    }
}

@(private = "file")
bind_held :: proc(k: ^Kernel, ctx, chord: string) -> (held: string, hold: Bind_Hold) {
    if k.hooks.bind_held == nil {
        return
    }
    return k.hooks.bind_held(k, ctx, chord)
}

// --- config ---

CONFIG_NAME :: "config.conf"

Config_Request :: struct {
    owner:   string, // owned
    section: string, // owned
    key:     string, // owned
    value:   string, // owned
    dead:    bool,
}

// Only a held request gets a ledger record.
config_request :: proc(k: ^Kernel, owner, section, key, value: string) -> bool {
    if owner == "" || section == "" || key == "" || value == "" {
        return false
    }
    append(&k.creqs, Config_Request{strings.clone(owner), strings.clone(section),
                                    strings.clone(key), strings.clone(value), false})
    return true
}

config_requests_destroy :: proc(k: ^Kernel) {
    for r in k.creqs {
        delete(r.owner)
        delete(r.section)
        delete(r.key)
        delete(r.value)
    }
    delete(k.creqs)
}

// Appends a marked block per owner the file has none for. A key the user already set is left
// alone, except `ordered` keys: sets, joined in place. True when the file changed.
config_writeback :: proc(k: ^Kernel, path: string, ordered: []string) -> bool {
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    text := string(raw)
    owners := new_owners(k.creqs[:], text)
    if len(owners) == 0 {
        return false
    }
    rows, _ := conf.parse(text)
    lines := strings.split_lines(text, context.temp_allocator)
    add := make([dynamic]string, context.temp_allocator)
    added := make(map[string]Added, 0, context.temp_allocator)
    for owner in owners {
        append(&add, "", owner_marker(owner))
        config_rows(k, owner, rows, lines, &add, &added, ordered)
    }
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, strings.join(lines, "\n", context.temp_allocator))
    if text != "" && !strings.has_suffix(text, "\n") {
        strings.write_byte(&b, '\n')
    }
    strings.write_string(&b, strings.join(add[:], "\n", context.temp_allocator))
    strings.write_byte(&b, '\n')
    return os.write_entire_file(path, transmute([]u8)strings.to_string(b)) == nil
}

// A row this writeback added, by "[section] key", and whose it is.
@(private = "file")
Added :: struct {
    at:    int, // into add
    owner: string,
}

// A key an earlier owner (by name) added this run: an ordered one is joined, any other is
// written commented. Both are said, for the app to show.
@(private = "file")
config_rows :: proc(k: ^Kernel, owner: string, rows: []conf.Row, lines: []string,
                    add: ^[dynamic]string, added: ^map[string]Added, ordered: []string) {
    section := ""
    for q in k.creqs {
        if q.dead || q.owner != owner {
            continue
        }
        set := slice.contains(ordered, q.key)
        if at, held := row_at(rows, q.section, q.key); held {
            if set {
                lines[at - 1] = join(lines[at - 1], q.value)
            }
            continue
        }
        key := fmt.tprintf("[%s] %s", q.section, q.key)
        first, twice := added[key]
        if twice && set {
            add[first.at] = join(add[first.at], q.value)
            say(k, fmt.tprintf("%s and %s both asked for %s; joined in name order", first.owner, owner, key))
            continue
        }
        if section != q.section {
            append(add, fmt.tprintf("[%s]", q.section))
            section = q.section
        }
        if twice {
            append(add, fmt.tprintf("# %s = %s   # taken by %s", q.key, q.value, first.owner))
            say(k, fmt.tprintf("%s and %s both asked for %s; %s's is kept", first.owner, owner, key, first.owner))
            continue
        }
        added[key] = {len(add), owner}
        append(add, fmt.tprintf("%s = %s", q.key, q.value))
    }
}

@(private = "file")
row_at :: proc(rows: []conf.Row, section, key: string) -> (line: int, ok: bool) {
    for r in rows {
        if r.section == section && r.key == key {
            return r.line, true
        }
    }
    return
}

// `name` added to a `key = a, b` line unless it is there.
@(private = "file")
join :: proc(line, name: string) -> string {
    _, _, value := strings.partition(line, "=")
    for part in strings.split_iterator(&value, ",") {
        if strings.trim_space(part) == name {
            return line
        }
    }
    return strings.concatenate({strings.trim_right_space(line), ", ", name}, context.temp_allocator)
}
