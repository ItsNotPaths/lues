//! The Rust test plugin: lues.h declared by hand, a thin safe layer, and commands that probe
//! ownership across the seam.

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::{self, null};
use std::sync::atomic::{AtomicPtr, Ordering};

mod sys {
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
        pub generation: u64,
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
    }

    // The sizes lues.h asserts.
    const _: () = assert!(size_of::<Block>() == 16);
    const _: () = assert!(size_of::<Piece>() == 32);
    const _: () = assert!(size_of::<Snapshot>() == 104);
    const _: () = assert!(size_of::<At>() == 40);
    const _: () = assert!(size_of::<Edit>() == 48);
    const _: () = assert!(size_of::<Api>() == 152);
}

/// The kernel's vtable and this load's handle. Copy: both are plain values the kernel owns.
#[derive(Clone, Copy)]
struct Api {
    api: *const sys::Api,
    me: sys::Self_,
}

impl Api {
    fn say(self, text: &[u8]) {
        unsafe { ((*self.api).message)(self.api, self.me, text.as_ptr().cast(), text.len()) }
    }

    fn command(self, name: &str, doc: &str, f: sys::CommandFn) {
        unsafe {
            ((*self.api).register_command)(
                self.api, self.me, name.as_ptr().cast(), name.len(), doc.as_ptr().cast(),
                doc.len(), f,
            )
        }
    }

    /// Replaces [lo, hi) of the doc as read at `generation`.
    fn submit(self, doc: sys::Doc, generation: u64, lo: usize, hi: usize, text: &[u8]) {
        let e = sys::Edit {
            size: size_of::<sys::Edit>(),
            lo,
            hi,
            text: text.as_ptr(),
            text_len: text.len(),
            tag: 0,
            _pad: [0; 4],
        };
        unsafe { ((*self.api).submit)(self.api, self.me, doc, generation, &e, 1, null(), 0) }
    }

    /// A snapshot that outlives the call. Released on drop, or kept with `into_raw`.
    fn hold(self, doc: sys::Doc) -> Option<Held> {
        let snap = unsafe { ((*self.api).snapshot)(self.api, self.me, doc) };
        (!snap.is_null()).then_some(Held { api: self, snap })
    }
}

struct Held {
    api: Api,
    snap: *const sys::Snapshot,
}

impl Held {
    fn into_raw(self) -> *const sys::Snapshot {
        let snap = self.snap;
        std::mem::forget(self);
        snap
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        unsafe { ((*self.api.api).release)(self.api.api, self.api.me, self.snap) }
    }
}

/// The doc's bytes, walked piece by piece through the blocks in place.
fn text(s: &sys::Snapshot) -> Vec<u8> {
    let pieces = unsafe { std::slice::from_raw_parts(s.pieces, s.npieces) };
    let blocks = unsafe { std::slice::from_raw_parts(s.blocks, s.nblocks) };
    let mut out = Vec::with_capacity(s.size);
    for p in pieces {
        let b = &blocks[p.block as usize];
        let bytes = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
        out.extend_from_slice(&bytes[p.off as usize..(p.off + p.len) as usize]);
    }
    out
}

/// A panic must not unwind into the kernel's frames. It is caught here and becomes `fail`,
/// which unloads the plugin and never returns: it jumps back to the kernel over this frame and
/// the entry point's, so neither may hold anything with a destructor by then. Before API 2 it
/// is exit code 2.
fn guarded(api: *const sys::Api, me: sys::Self_, f: impl FnOnce() -> i32) -> i32 {
    let (msg, n) = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(code) => return code,
        Err(payload) => said(&*payload), // the payload is dropped here
    };
    unsafe {
        if (*api).version < 2 {
            return 2;
        }
        ((*api).fail)(api, me, msg.as_ptr().cast(), n)
    }
}

/// A panic's message, cut to fit a buffer that needs no drop.
fn said(payload: &(dyn std::any::Any + Send)) -> ([u8; 256], usize) {
    let text = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("panicked");
    let mut buf = [0; 256];
    let n = text.len().min(buf.len());
    buf[..n].copy_from_slice(&text.as_bytes()[..n]);
    (buf, n)
}

fn args<'a>(p: *const c_char, n: usize) -> &'a [u8] {
    if n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p.cast(), n) } }
}

/// One snapshot held across calls.
static HELD: AtomicPtr<sys::Snapshot> = AtomicPtr::new(ptr::null_mut());

/// Says the focused doc's bytes, read in place.
unsafe extern "C" fn read(api: *const sys::Api, me: sys::Self_, at: *const sys::At,
                          _: *const c_char, _: usize) -> i32 {
    guarded(api, me, || {
        let api = Api { api, me };
        match unsafe { (*at).snap.as_ref() } {
            Some(s) => {
                api.say(&text(s));
                0
            }
            None => 1,
        }
    })
}

/// Uppercases the focused doc with one edit.
unsafe extern "C" fn upper(api: *const sys::Api, me: sys::Self_, at: *const sys::At,
                           _: *const c_char, _: usize) -> i32 {
    guarded(api, me, || {
        let api = Api { api, me };
        let Some(s) = (unsafe { (*at).snap.as_ref() }) else { return 1 };
        api.submit(s.doc, s.generation, 0, s.size, &text(s).to_ascii_uppercase());
        0
    })
}

/// Takes a snapshot of the focused doc and keeps it past this call.
unsafe extern "C" fn hold(api: *const sys::Api, me: sys::Self_, at: *const sys::At,
                          _: *const c_char, _: usize) -> i32 {
    guarded(api, me, || {
        let api = Api { api, me };
        let doc = unsafe { (*at).doc };
        let Some(held) = api.hold(doc) else { return 1 };
        let old = HELD.swap(held.into_raw().cast_mut(), Ordering::Relaxed);
        if !old.is_null() {
            drop(Held { api, snap: old });
        }
        0
    })
}

/// Says the held snapshot's bytes, then releases it.
unsafe extern "C" fn release(api: *const sys::Api, me: sys::Self_, _: *const sys::At,
                             _: *const c_char, _: usize) -> i32 {
    guarded(api, me, || {
        let api = Api { api, me };
        let snap = HELD.swap(ptr::null_mut(), Ordering::Relaxed);
        if snap.is_null() {
            return 1;
        }
        let held = Held { api, snap };
        api.say(&text(unsafe { &*held.snap }));
        0
    })
}

/// Releases one snapshot twice; the second must be ignored.
unsafe extern "C" fn double(api: *const sys::Api, me: sys::Self_, at: *const sys::At,
                            _: *const c_char, _: usize) -> i32 {
    guarded(api, me, || {
        let api = Api { api, me };
        let Some(held) = api.hold(unsafe { (*at).doc }) else { return 1 };
        let snap = held.snap;
        drop(held);
        unsafe { ((*api.api).release)(api.api, api.me, snap) };
        0
    })
}

unsafe extern "C" fn panic(api: *const sys::Api, me: sys::Self_, _: *const sys::At,
                           a: *const c_char, n: usize) -> i32 {
    guarded(api, me, || panic!("asked to: {}", String::from_utf8_lossy(args(a, n))))
}

/// # Safety
/// Called once by the kernel, with its own vtable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lues_main(api: *const sys::Api, me: sys::Self_) -> i32 {
    guarded(api, me, || {
        let app = unsafe { CStr::from_ptr((*api).app) };
        if app.to_bytes() != b"test" {
            return 1;
        }
        let api = Api { api, me };
        api.command("rs-read", "say the doc, read in place", read);
        api.command("rs-upper", "uppercase the doc", upper);
        api.command("rs-hold", "hold a snapshot past the call", hold);
        api.command("rs-release", "say the held snapshot, then release it", release);
        api.command("rs-double", "release one snapshot twice", double);
        api.command("rs-panic", "panic inside a command", panic);
        0
    })
}
