package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "../src/docs"
import lues "../src/lues"

// Frames until `id` reads `want`, or 5 s. A test has no window to wake it, so it polls.
@(private = "file")
frames_until :: proc(k: ^lues.Kernel, id: docs.Id, want: string) -> bool {
    for _ in 0 ..< 1000 {
        lues.kernel_frame(k)
        if doc_text(k, id) == want {
            return true
        }
        time.sleep(5 * time.Millisecond)
    }
    return false
}

// A child's output lands in its doc, then its exit code.
@(test)
spawn_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "spawn"); !ok {
        return
    }
    id := docs.store_open(&k.store)

    testing.expect(t, run(&k, "spawn", id, "printf hi; exit 3"))
    testing.expect(t, frames_until(&k, id, "hi"), doc_text(&k, id))
    for _ in 0 ..< 1000 {
        if strings.to_string(said) == "end 3" {
            break
        }
        lues.kernel_frame(&k)
        time.sleep(5 * time.Millisecond)
    }
    testing.expect_value(t, strings.to_string(said), "end 3")
    testing.expect_value(t, len(k.io_jobs), 0) // an ended job is forgotten
}

// A readable fd is told once, then again after its handler read it.
@(test)
fd_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "fd"); !ok {
        return
    }
    id := docs.store_open(&k.store)

    testing.expect(t, run(&k, "pipe", id))
    testing.expect(t, run(&k, "poke", id, "a"))
    testing.expect(t, frames_until(&k, id, "a"), doc_text(&k, id))
    testing.expect(t, run(&k, "poke", id, "b"))
    testing.expect(t, frames_until(&k, id, "ab"), doc_text(&k, id)) // rearmed
    lues.kernel_frame(&k)
    testing.expect_value(t, strings.to_string(said), "watched 1") // told the new doc, not its own writes
}

// A save to a watched file is reported with its path.
@(test)
watchfile_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "watchfile"); !ok {
        return
    }
    file, _ := filepath.join({k.home.data, "watched"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(file, transmute([]u8)string("x")), nil)
    id := docs.store_open(&k.store)

    testing.expect(t, run(&k, "watchfile", id, file))
    testing.expect_value(t, os.write_entire_file(file, transmute([]u8)string("y")), nil)
    testing.expect(t, frames_until(&k, id, file), doc_text(&k, id))
}

// Unloading a plugin ends its jobs.
@(test)
io_forget_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "io-forget")
    if !ok {
        return
    }
    id := docs.store_open(&k.store)
    testing.expect(t, run(&k, "spawn", id, "sleep 5"))
    testing.expect_value(t, len(k.io_jobs), 1)

    lues.loader_unload(&k, i)
    testing.expect_value(t, len(k.io_jobs), 0)
}
