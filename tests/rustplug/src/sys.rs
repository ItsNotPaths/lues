//! lues.h, declared by hand. tests/abi_test.odin checks it against src/abi/abi.odin.

use std::ffi::{c_char, c_void};

pub type Self_ = u64;
pub type Doc = u64;
pub type Io = u64;

#[repr(C)]
pub struct Block {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct Piece {
    pub block: isize,
    pub off: isize,
    pub len: isize,
    pub doc_off: isize,
}

#[repr(C)]
pub struct Snapshot {
    pub blocks: *const Block,
    pub starts: *const isize,
    pub pieces: *const Piece,
    pub segs: *const c_void,
    pub nblocks: usize,
    pub nstarts: usize,
    pub npieces: usize,
    pub nsegs: usize,
    pub size: usize,
    pub lines: usize,
    pub r#gen: u64,
    pub doc: Doc,
    pub app: *const c_void,
}

#[repr(C)]
pub struct At {
    pub doc: Doc,
    pub inst: *mut c_void,
    pub snap: *const Snapshot,
    pub io: Io,
    pub code: i32,
    pub _pad: [u8; 4],
}

#[repr(C)]
pub struct Edit {
    pub size: usize,
    pub lo: usize,
    pub hi: usize,
    pub text: *const u8,
    pub text_len: usize,
    pub tag: u32,
    pub _pad: [u8; 4],
}

pub type CommandFn =
    unsafe extern "C" fn(*const Api, Self_, *const At, *const c_char, usize) -> i32;

// Arms this plugin never calls are typed as bare pointers: same size, no layout claimed.
type Unused = *const c_void;

#[repr(C)]
pub struct Api {
    pub version: u32,
    pub app_version: u32,
    pub app: *const c_char,
    pub register_kind: Unused,
    pub register_command: unsafe extern "C" fn(
        *const Api, Self_, *const c_char, usize, *const c_char, usize, CommandFn),
    pub request_bind: Unused,
    pub request_config: Unused,
    pub register_token: Unused,
    pub register_watch: Unused,
    pub submit: unsafe extern "C" fn(
        *const Api, Self_, Doc, u64, *const Edit, usize, *const c_void, u32),
    pub snapshot: unsafe extern "C" fn(*const Api, Self_, Doc) -> *const Snapshot,
    pub release: unsafe extern "C" fn(*const Api, Self_, *const Snapshot),
    pub message: unsafe extern "C" fn(*const Api, Self_, *const c_char, usize),
    pub io_spawn: Unused,
    pub io_write: Unused,
    pub io_watch: Unused,
    pub io_fd: Unused,
    pub io_close: Unused,
    pub fail: unsafe extern "C" fn(*const Api, Self_, *const c_char, usize) -> !,
    pub adopt: Unused,
    pub call: Unused,
    pub hook_define: Unused,
    pub hook_add: Unused,
    pub hook_run: Unused,
    pub advise: Unused,
    pub advice_next: Unused,
    pub var_define: Unused,
    pub var_set: Unused,
    pub var_get: Unused,
    pub var_watch: Unused,
}

// The sizes lues.h asserts.
const _: () = assert!(size_of::<Block>() == 16);
const _: () = assert!(size_of::<Piece>() == 32);
const _: () = assert!(size_of::<Snapshot>() == 104);
const _: () = assert!(size_of::<At>() == 40);
const _: () = assert!(size_of::<Edit>() == 48);
const _: () = assert!(size_of::<Api>() == 232);
