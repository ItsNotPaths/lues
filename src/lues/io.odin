package lues

import "../docs"
import "core:sys/posix"
import "../work"

// Completions go to the caller's own instance, else its watcher, else the job is closed.

Io_Job :: struct {
    owner: int,
    doc:   docs.Id,
}

// Once a frame. An fd job is rearmed after its handler ran, which is where the plugin reads it.
io_pump :: proc(k: ^Kernel) {
    context = k.ctx
    if k.io == nil {
        return
    }
    for m in work.pool_drain(k.io) {
        job := k.io_jobs[m.id] or_continue
        if len(m.bytes) > 0 || !m.ended {
            io_deliver(k, job, m.id, .Io, m.bytes, 0)
            work.pool_rearm(k.io, m.id)
        }
        // Asked again: the handler may have closed this job, and then it is not told.
        if _, still := k.io_jobs[m.id]; still && m.ended {
            io_deliver(k, job, m.id, .Io_End, nil, m.code)
            delete_key(&k.io_jobs, m.id)
        }
    }
}

// A plugin's jobs die with it.
io_forget :: proc(k: ^Kernel, owner: int) {
    context = k.ctx
    if k.io == nil {
        return
    }
    dead := make([dynamic]work.Id, 0, len(k.io_jobs), context.temp_allocator)
    for id, job in k.io_jobs {
        if job.owner == owner {
            append(&dead, id)
        }
    }
    for id in dead {
        work.pool_close(k.io, id)
        delete_key(&k.io_jobs, id)
    }
}

io_destroy :: proc(k: ^Kernel) {
    context = k.ctx
    if k.io != nil {
        work.pool_stop(k.io)
        free(k.io)
        k.io = nil
    }
    delete(k.io_jobs)
    k.io_jobs = nil // a plugin's close under kernel_destroy still looks here
}

io_handle :: proc(id: work.Id) -> Io {
    return Io(pack(id.slot, id.seq))
}

work_id :: proc(io: Io) -> work.Id {
    slot, seq := unpack(u64(io))
    return {slot, seq}
}

@(private)
api_io_spawn :: proc "c" (api: ^Api, self: Self, doc: Doc_Handle, argv: [^]cstring, nargv: uint,
                          cwd: [^]u8, cwd_len: uint) -> Io {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok || nargv == 0 {
        return 0
    }
    context = k.ctx
    pool := io_pool(k)
    if pool == nil {
        return 0
    }
    words := make([]string, nargv, context.temp_allocator)
    for &w, n in words {
        w = string(argv[n])
    }
    return io_start(k, i, doc, work.pool_spawn(pool, words, string(cwd[:cwd_len])))
}

@(private)
api_io_watch :: proc "c" (api: ^Api, self: Self, doc: Doc_Handle, path: [^]u8, path_len: uint) -> Io {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok || path_len == 0 {
        return 0
    }
    context = k.ctx
    pool := io_pool(k)
    if pool == nil {
        return 0
    }
    return io_start(k, i, doc, work.pool_watch(pool, string(path[:path_len])))
}

// Readable = .Io with no bytes; the plugin reads the fd. The kernel never closes it.
@(private)
api_io_fd :: proc "c" (api: ^Api, self: Self, doc: Doc_Handle, fd: i32) -> Io {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return 0
    }
    context = k.ctx
    pool := io_pool(k)
    if pool == nil {
        return 0
    }
    return io_start(k, i, doc, work.pool_fd(pool, posix.FD(fd)))
}

@(private)
api_io_write :: proc "c" (api: ^Api, self: Self, io: Io, bytes: [^]u8, length: uint) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    id := work_id(io)
    if job, held := k.io_jobs[id]; held && job.owner == i {
        work.pool_write(k.io, id, bytes[:length])
    }
}

@(private)
api_io_close :: proc "c" (api: ^Api, self: Self, io: Io) {
    k, i, ok := api_kernel(api, self)
    defer api_done()
    if !ok {
        return
    }
    context = k.ctx
    id := work_id(io)
    if job, held := k.io_jobs[id]; held && job.owner == i {
        work.pool_close(k.io, id)
        delete_key(&k.io_jobs, id)
    }
}

// On the heap and started on the first job: the worker holds this address.
@(private = "file")
io_pool :: proc(k: ^Kernel) -> ^work.Pool {
    if k.io == nil {
        k.io = new(work.Pool)
        if !work.pool_start(k.io) {
            free(k.io)
            k.io = nil
        }
    }
    return k.io
}

// A failed start is a zero handle, told at the call.
@(private = "file")
io_start :: proc(k: ^Kernel, owner: int, doc: Doc_Handle, id: work.Id, started: bool) -> Io {
    if !started {
        return 0
    }
    k.io_jobs[id] = {owner, doc_id(doc)}
    return io_handle(id)
}

// The caller's own instance gets its kind's event, else its watcher; with neither, the job is
// closed rather than left running with no reader.
@(private = "file")
io_deliver :: proc(k: ^Kernel, job: Io_Job, id: work.Id, ev: Event, text: []u8, code: i32) {
    call := Call{what = .Watch, ev = ev, data = text}
    if inst, held := k.insts[job.doc]; held && inst.owner == job.owner {
        if kd, known := kind_get(k, inst.kind); known && kd.vt.event != nil {
            call.what, call.vt = .Event, kd.vt
        }
    } else if k.plugs[job.owner].state == .Live {
        call.fn_ev = k.plugs[job.owner].watch
    }
    if call.vt.event == nil && call.fn_ev == nil {
        work.pool_close(k.io, id)
        delete_key(&k.io_jobs, id)
        return
    }
    at := at_make(k, job.owner, job.doc)
    defer at_free(k, at)
    at.doc, at.io, at.code = doc_handle(job.doc), io_handle(id), code
    call.at = &at
    if _, ran := dispatch(k, job.owner, call); ran {
        kernel_settle(k)
    }
}
