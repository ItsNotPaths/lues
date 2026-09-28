package conf

import "core:strings"

// (hole rs-conf :tags (port) :sev missing-port) not yet a crate; the conf reader is Odin only.
// `key = value` under `[section]` headers. Rows point into `text`: keep it alive with them.

Row :: struct {
    section:    string, // "" until the first header
    key, value: string,
    line:       int, // 1-based
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
            if row[len(row) - 1] != ']' {
                append(&bad, Error{n, "a section header wants a closing ]"})
                continue
            }
            section = strings.trim_space(row[1:len(row) - 1])
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
