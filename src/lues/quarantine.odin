package lues

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// A plugin that kills the process is named in this file by the handler and held back at the
// next start. An explicit load lifts it.

QUARANTINE_FILE :: "quarantine" // in the state directory

// Reads first, then opens the same file for the handler to append to.
quarantine_open :: proc(a: ^Kernel) {
    context = a.ctx
    path := quarantine_path(a)
    if path == "" || a.report != nil {
        return
    }
    raw, err := os.read_entire_file(path, context.temp_allocator)
    text := string(raw) if err == nil else ""
    for line in strings.split_lines_iterator(&text) {
        name := strings.trim_space(line)
        if name != "" && !quarantined(a, name) {
            append(&a.quarantined, strings.clone(name))
        }
    }
    f, open_err := os.open(path, {.Write, .Create, .Append}, {.Read_User, .Write_User})
    if open_err == nil {
        a.report = f
        fault_report_fd(os.fd(f))
    }
}

quarantine_destroy :: proc(a: ^Kernel) {
    context = a.ctx
    if a.report != nil {
        fault_report_fd(0)
        os.close(a.report)
        a.report = nil
    }
    for name in a.quarantined {
        delete(name)
    }
    delete(a.quarantined)
    a.quarantined = nil
}

quarantined :: proc(a: ^Kernel, name: string) -> bool {
    context = a.ctx
    return slice.contains(a.quarantined[:], name)
}

quarantine_clear :: proc(a: ^Kernel, name: string) {
    context = a.ctx
    i, found := slice.linear_search(a.quarantined[:], name)
    if !found {
        return
    }
    delete(a.quarantined[i])
    ordered_remove(&a.quarantined, i)
    path := quarantine_path(a)
    if path == "" {
        return
    }
    if len(a.quarantined) == 0 {
        os.remove(path)
        return
    }
    b := strings.builder_make(context.temp_allocator)
    for left in a.quarantined {
        fmt.sbprintfln(&b, "%s", left)
    }
    _ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}

@(private = "file")
quarantine_path :: proc(a: ^Kernel) -> string {
    if a.home.state == "" {
        return ""
    }
    path, _ := filepath.join({a.home.state, QUARANTINE_FILE}, context.temp_allocator)
    return path
}
