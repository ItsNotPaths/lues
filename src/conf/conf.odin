package conf

import "core:strings"

// `key = value` under `[section]` headers. Rows point into `text`: keep it alive with them.

Row :: struct {
    section:    string, // "" until the first header
    key, value: string,
    line:       int, // 1-based
}

// A header and what follows its `]`, which a reader may give a meaning: binds.conf's group list.
Head :: struct {
    section, rest: string,
    line:          int,
}

// A bad row is skipped, never fatal.
Error :: struct {
    line: int,
    why:  string,
}

parse :: proc(text: string, alloc := context.temp_allocator) -> (rows: []Row, errs: []Error) {
    out := make([dynamic]Row, alloc)
    bad := make([dynamic]Error, alloc)
    section := ""
    n := 0
    rest := text
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        row := strings.trim_space(raw)
        if row == "" || row[0] == '#' {
            continue
        }
        if row[0] == '[' {
            name, _, ok := header(row)
            if !ok {
                append(&bad, Error{n, "a section header wants a closing ]"})
                continue
            }
            section = name
            continue
        }
        // The first `=`: a value may hold more.
        key, sep, value := strings.partition(row, "=")
        key, value = strings.trim_space(key), strings.trim_space(value)
        if sep == "" || key == "" || value == "" {
            append(&bad, Error{n, "expected `key = value`"})
            continue
        }
        append(&out, Row{section, key, value, n})
    }
    return out[:], bad[:]
}

// Every header, with what follows it. One reading with parse, so the two cannot disagree.
heads :: proc(text: string, alloc := context.temp_allocator) -> []Head {
    out := make([dynamic]Head, alloc)
    n := 0
    rest := text
    for raw in strings.split_lines_iterator(&rest) {
        n += 1
        row := strings.trim_space(raw)
        if row == "" || row[0] != '[' {
            continue
        }
        if name, after, ok := header(row); ok {
            append(&out, Head{name, after, n})
        }
    }
    return out[:]
}

// `[name] rest`. A `#` after the `]` is a comment, as it is at the start of a line.
@(private = "file")
header :: proc(row: string) -> (name, rest: string, ok: bool) {
    close := strings.index_byte(row, ']')
    if close < 0 {
        return "", "", false
    }
    rest = strings.trim_space(row[close + 1:])
    if strings.has_prefix(rest, "#") {
        rest = ""
    }
    return strings.trim_space(row[1:close]), rest, true
}
