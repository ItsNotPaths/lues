package lues

import "core:c"

import "../docs"
import "../pt"

// `snap` first: the pointer a plugin holds casts back to this.
View :: struct {
    snap: Snapshot,
    src:  ^pt.Snapshot,
}

// Plugins read pt's memory in place.
#assert(size_of(pt.Piece) == size_of(Piece) && size_of(pt.Line_Seg) == size_of(Seg))
#assert(size_of([]u8) == size_of(Block) && size_of(int) == size_of(c.ptrdiff_t))

// nil for a closed doc.
view_make :: proc(k: ^Kernel, id: docs.Id) -> ^View {
    d := docs.store_doc(&k.store, id)
    if d == nil {
        return nil
    }
    src := docs.doc_snapshot(d)
    v := new(View)
    v.src = src
    v.snap = {
        blocks  = ([^]Block)(raw_data(src.blocks)),
        starts  = ([^]c.ptrdiff_t)(raw_data(src.starts)),
        pieces  = ([^]Piece)(raw_data(src.pieces)),
        segs    = ([^]Seg)(raw_data(src.segs)),
        nblocks = len(src.blocks),
        nstarts = len(src.starts),
        npieces = len(src.pieces),
        nsegs   = len(src.segs),
        size    = uint(src.size),
        lines   = uint(src.lines),
        gen     = src.gen,
        doc     = doc_handle(id),
        app     = k.hooks.side_make(k, id, src.gen) if k.hooks.side_make != nil else nil,
    }
    return v
}

view_free :: proc(k: ^Kernel, v: ^View) {
    if v == nil {
        return
    }
    if k.hooks.side_free != nil {
        k.hooks.side_free(k, v.snap.app)
    }
    pt.snapshot_release(v.src)
    free(v)
}
