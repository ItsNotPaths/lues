package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import lues "../src/lues"

@(private = "file")
read :: proc(path: string) -> string {
    raw, _ := os.read_entire_file(path, context.temp_allocator)
    return string(raw)
}

// A plugin's token is interned past the app's own, and one name is one id.
@(test)
token_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "token", {base_tokens = {"fg", "bg"}}); !ok {
        return
    }
    testing.expect(t, run(&k, "tok"))
    testing.expect_value(t, strings.to_string(said), "token 2")
    testing.expect_value(t, lues.token_intern(&k, "comment"), 2)
    testing.expect_value(t, lues.token_intern(&k, "bg"), 1)
    testing.expect_value(t, lues.token_name(&k, 2), "comment")
    testing.expect_value(t, lues.token_intern(&k, ""), 0)

    bare: lues.Kernel
    bare_box: Api_Box
    testing.expect(t, test_host(&bare, &bare_box, {base_tokens = {"fg"}}))
    defer lues.kernel_destroy(&bare)
    testing.expect_value(t, lues.token_name(&bare, 0), "fg") // named before anything interns
}

// A requested chord is written once under the plugin's marker, then the file decides.
@(test)
bind_writeback_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    i, ok := plug_host(t, &k, &box, &said, "binds")
    if !ok {
        return
    }
    path, _ := filepath.join({k.home.data, lues.BINDS_NAME}, context.temp_allocator)

    testing.expect(t, lues.bind_writeback(&k, path))
    testing.expect_value(t, read(path), "\n# --- cplug ---\n[text]\nalt+x = hello 1\n")
    testing.expect(t, !lues.bind_writeback(&k, path), "a second writeback")

    // The user deleted the row but kept the marker: it is not asked again.
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("# --- cplug ---\n")), nil)
    testing.expect(t, !lues.bind_writeback(&k, path))

    lues.loader_unload(&k, i)
    testing.expect_value(t, os.remove(path), nil)
    testing.expect(t, !lues.bind_writeback(&k, path), "a dead request wrote back")
}

// A chord the app's table holds is written commented and said; a wider one gets a note.
@(test)
bind_held_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    taken :: proc(k: ^lues.Kernel, ctx, chord: string) -> (string, lues.Bind_Hold) {
        return "quit", .Taken
    }
    if _, ok := plug_host(t, &k, &box, &said, "bind-held", {hooks = {bind_held = taken}}); !ok {
        return
    }
    path, _ := filepath.join({k.home.data, lues.BINDS_NAME}, context.temp_allocator)

    testing.expect(t, lues.bind_writeback(&k, path))
    testing.expect(t, strings.contains(read(path), "# alt+x = hello 1   # taken by quit\n"), read(path))
    testing.expect_value(t, strings.to_string(said), "cplug: alt+x is taken by quit")

    k.hooks.bind_held = proc(k: ^lues.Kernel, ctx, chord: string) -> (string, lues.Bind_Hold) {
        return "save", .Shadowed
    }
    testing.expect_value(t, os.remove(path), nil)
    testing.expect(t, lues.bind_writeback(&k, path))
    testing.expect(t, strings.contains(read(path), "# shadows save\nalt+x = hello 1\n"), read(path))
}

// A key the user set is left alone, except an ordered one, which is joined.
@(test)
config_writeback_test :: proc(t: ^testing.T) {
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    if _, ok := plug_host(t, &k, &box, &said, "config"); !ok {
        return
    }
    path, _ := filepath.join({k.home.data, lues.CONFIG_NAME}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("[edit]\nview = fold\ntab = 8\n")), nil)

    testing.expect(t, lues.config_writeback(&k, path, {"view"}))
    testing.expect_value(t, read(path), "[edit]\nview = fold, cplug\ntab = 8\n\n# --- cplug ---\n")
    testing.expect(t, !lues.config_writeback(&k, path, {"view"}), "a second writeback")

    testing.expect_value(t, os.remove(path), nil)
    testing.expect(t, lues.config_writeback(&k, path, {"view"}))
    testing.expect_value(t, read(path), "\n# --- cplug ---\n[edit]\nview = cplug\ntab = 4\n")
}

// Two plugins asking for one thing: the first by name keeps it, an ordered key joins both in
// name order, and each clash is said.
@(test)
two_owners_test :: proc(t: ^testing.T) {
    data, staged := stage(t, "two-owners", "cplug", "bplug")
    if !staged {
        return
    }
    said := strings.builder_make(context.temp_allocator)
    k: lues.Kernel
    box: Api_Box
    defer lues.kernel_destroy(&k)
    testing.expect(t, test_host(&k, &box, {home = {data = data}}))
    k.hooks.say, k.user = heard, &said
    lues.loader_load(&k, lues.loader_path(&k, "cplug")) // loaded first, asks second
    lues.loader_load(&k, lues.loader_path(&k, "bplug"))

    binds, _ := filepath.join({data, lues.BINDS_NAME}, context.temp_allocator)
    testing.expect(t, lues.bind_writeback(&k, binds))
    testing.expect_value(t, read(binds),
        "\n# --- bplug ---\n[text]\nalt+x = bplug\n\n# --- cplug ---\n[text]\n# alt+x = hello 1   # taken by bplug\n")

    config, _ := filepath.join({data, lues.CONFIG_NAME}, context.temp_allocator)
    testing.expect(t, lues.config_writeback(&k, config, {"view"}))
    testing.expect_value(t, read(config),
        "\n# --- bplug ---\n[edit]\nview = bplug, cplug\ntab = 2\n\n# --- cplug ---\n[edit]\n# tab = 4   # taken by bplug\n")
    testing.expect_value(t, strings.to_string(said), "bplug and cplug both asked for [edit] tab; bplug's is kept")
}
