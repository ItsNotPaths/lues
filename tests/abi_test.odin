package tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:testing"
import lues "../src/lues"

// The structs lues.h and rustplug's sys.rs mirror. Each mirror prints its own layout, by the
// field names abi.odin uses, so a field missing from a mirror fails its compile and one that
// moved fails the compare. Rust mirrors only the structs it uses.
@(private = "file")
ABI_TYPES := []typeid {
    lues.Block,
    lues.Piece,
    lues.Seg,
    lues.Snapshot,
    lues.At,
    lues.Kind_Vt,
    lues.Kind_Spec,
    lues.Edit,
    lues.Span,
    lues.Span_Pub,
    lues.Api,
}

@(test)
abi_test :: proc(t: ^testing.T) {
    tmp, _ := os.temp_directory(context.temp_allocator)
    dir, _ := filepath.join({tmp, "lues-test", "abi"}, context.temp_allocator)
    os.remove_all(dir)
    os.make_directory_all(dir)
    include, _ := filepath.join({TESTS, "..", "include"}, context.temp_allocator)
    sys_rs, _ := filepath.join({TESTS, "rustplug", "src", "sys.rs"}, context.temp_allocator)
    rust_has, _ := os.read_entire_file(sys_rs, context.temp_allocator)

    want, want_rs, c, rs: strings.Builder
    for b in ([]^strings.Builder{&want, &want_rs, &c, &rs}) {
        strings.builder_init(b, context.temp_allocator)
    }
    fmt.sbprintf(&want, "api %d\n", lues.API)
    fmt.sbprint(&c, "#include <stddef.h>\n#include <stdio.h>\n#include \"lues.h\"\nint main(void) {\n")
    fmt.sbprint(&c, "    printf(\"api %d\\n\", LUES_API);\n")
    fmt.sbprintf(&rs, "#![allow(dead_code)]\n#[path = %q]\nmod sys;\nuse std::mem::{{offset_of, size_of}};\nfn main() {{\n", sys_rs)
    for T in ABI_TYPES {
        name := type_name(T)
        c_name := strings.concatenate({"lues_", strings.to_lower(name, context.temp_allocator)}, context.temp_allocator)
        rs_name, _ := strings.remove_all(name, "_", context.temp_allocator)
        in_rust := strings.contains(string(rust_has), fmt.tprintf("pub struct %s {{", rs_name))

        fmt.sbprintf(&want, "%s sizeof %d\n", name, reflect.size_of_typeid(T))
        fmt.sbprintf(&c, "    printf(\"%s sizeof %%zu\\n\", sizeof(%s));\n", name, c_name)
        if in_rust {
            fmt.sbprintf(&want_rs, "%s sizeof %d\n", name, reflect.size_of_typeid(T))
            fmt.sbprintf(&rs, "    println!(\"%s sizeof {{}}\", size_of::<sys::%s>());\n", name, rs_name)
        }
        for f in reflect.struct_fields_zipped(T) {
            if f.name == "_" {
                continue // padding
            }
            fmt.sbprintf(&want, "%s %s %d\n", name, f.name, f.offset)
            fmt.sbprintf(&c, "    printf(\"%s %s %%zu\\n\", offsetof(%s, %s));\n", name, f.name, c_name, f.name)
            if in_rust {
                fmt.sbprintf(&want_rs, "%s %s %d\n", name, f.name, f.offset)
                fmt.sbprintf(&rs, "    println!(\"%s %s {{}}\", offset_of!(sys::%s, r#%s));\n", name, f.name, rs_name, f.name)
            }
        }
    }
    fmt.sbprint(&c, "    return 0;\n}\n")
    fmt.sbprint(&rs, "}\n")

    c_src, _ := filepath.join({dir, "abi.c"}, context.temp_allocator)
    c_bin, _ := filepath.join({dir, "abi-c"}, context.temp_allocator)
    rs_src, _ := filepath.join({dir, "abi.rs"}, context.temp_allocator)
    rs_bin, _ := filepath.join({dir, "abi-rs"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(c_src, transmute([]u8)strings.to_string(c)), nil)
    testing.expect_value(t, os.write_entire_file(rs_src, transmute([]u8)strings.to_string(rs)), nil)
    if got, ok := build_run(t, {"cc", "-std=c11", "-I", include, "-o", c_bin, c_src}, c_bin); ok {
        testing.expect_value(t, got, strings.to_string(want))
    }
    if got, ok := build_run(t, {"rustc", "--edition", "2024", "-o", rs_bin, rs_src}, rs_bin); ok {
        testing.expect_value(t, got, strings.to_string(want_rs))
    }
}

// "Kind_Spec" for lues.Kind_Spec.
@(private = "file")
type_name :: proc(T: typeid) -> string {
    return type_info_of(T).variant.(runtime.Type_Info_Named).name
}

// Its stdout. A failed build fails the test with the compiler's errors.
@(private = "file")
build_run :: proc(t: ^testing.T, build: []string, bin: string) -> (out: string, ok: bool) {
    state, _, errs, err := os.process_exec({command = build}, context.temp_allocator)
    if err != nil || !state.success {
        testing.expectf(t, false, "%s: %v\n%s", build[0], err, string(errs))
        return "", false
    }
    stdout: []u8
    state, stdout, errs, err = os.process_exec({command = {bin}}, context.temp_allocator)
    if err != nil || !state.success {
        testing.expectf(t, false, "%s: %v\n%s", bin, err, string(errs))
        return "", false
    }
    return string(stdout), true
}
