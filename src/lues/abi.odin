package lues

import "core:c"
import "../abi"
import "../docs"

// The ABI under the kernel's own names (src/abi).
API :: abi.API
ENTRY :: abi.ENTRY
Self :: abi.Self
Doc_Handle :: abi.Doc_Handle
Io :: abi.Io
Kind :: abi.Kind
NO_DOC :: abi.NO_DOC
Token :: abi.Token
Event :: abi.Event
Call_Status :: abi.Call_Status
Hook_Mode :: abi.Hook_Mode
Join_How :: abi.Join_How
Join_Flag :: abi.Join_Flag
Join_Flags :: abi.Join_Flags
Block :: abi.Block
Piece :: abi.Piece
Seg :: abi.Seg
Snapshot :: abi.Snapshot
At :: abi.At
Event_Fn :: abi.Event_Fn
Open_Fn :: abi.Open_Fn
Close_Fn :: abi.Close_Fn
Command_Fn :: abi.Command_Fn
Entry_Fn :: abi.Entry_Fn
Kind_Vt :: abi.Kind_Vt
Kind_Spec :: abi.Kind_Spec
Edit :: abi.Edit
Span :: abi.Span
Span_Pub :: abi.Span_Pub
Submit_Flag :: abi.Submit_Flag
Submit_Flags :: abi.Submit_Flags
Api :: abi.Api

// A run's channels cross as abi's set; the bits are docs'.
#assert(int(abi.Chan.Fg) == int(docs.Chan.Fg) && int(abi.Chan.Bg) == int(docs.Chan.Bg) &&
        int(abi.Chan.Attrs) == int(docs.Chan.Attrs) && len(abi.Chan) == len(docs.Chan))

pack :: proc "contextless" (lo, hi: u32) -> u64 {
    return u64(lo) | u64(hi) << 32
}

unpack :: proc "contextless" (v: u64) -> (lo, hi: u32) {
    return u32(v & 0xffff_ffff), u32(v >> 32)
}

doc_handle :: proc(id: docs.Id) -> Doc_Handle {
    return Doc_Handle(pack(id.slot, id.seq))
}

doc_id :: proc(doc: Doc_Handle) -> docs.Id {
    slot, seq := unpack(u64(doc))
    return {slot, seq}
}

// Whether a plugin struct of `size` bytes holds a field ending at `end`.
has :: proc "contextless" (size: c.size_t, end: uintptr) -> bool {
    return uintptr(size) >= end
}

// A plugin array strides by its first element's `size`. Every API 1 field is required; a field
// appended later is read only where has() says it exists. ok = false when the stride is short.
stride :: proc($T: typeid, base: rawptr, n: int) -> (step: uintptr, ok: bool) {
    if n == 0 {
        return 0, true
    }
    if base == nil {
        return 0, false
    }
    size := (^c.size_t)(base)^
    return uintptr(size), has(size, size_of(T))
}

elem :: proc($T: typeid, base: rawptr, step: uintptr, i: int) -> ^T {
    return (^T)(uintptr(base) + uintptr(i) * step)
}
