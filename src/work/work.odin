package work

import "base:runtime"
import "core:c"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "../wake"

// One worker thread polls children's pipes, one inotify fd and caller fds; results cross at
// pool_drain.
// Only the worker closes an fd: one closed under its poll could be reused by a spawn.
// A pool must not move once started.

// Unread bytes per job before the reader stops: the pipe then blocks the child.
CAP :: 4 << 20

Id :: struct {
    slot: u32,
    seq:  u32,
}

Kind :: enum u8 {
    Proc,
    Watch,
    Fd,
}

// `bytes` is temp-allocated by the drain; bytes and `ended` can both be set.
Msg :: struct {
    id:    Id,
    bytes: []u8,
    code:  i32,
    ended: bool,
}

@(private)
Job :: struct {
    id:      Id,
    kind:    Kind,
    live:    bool,
    closing: bool, // asked by the main thread; the worker closes
    ended:   bool,
    code:    i32,

    // Proc: `into` is stdin, `out` stdout.
    pid:     posix.pid_t,
    out:     posix.FD,
    into:    posix.FD,

    // Watch: inotify holds the directory, so a save by rename is seen. Empty `base` = every name.
    wd:      linux.Wd,
    dir:     string, // owned
    base:    string, // owned
    hit:     bool,

    // Fd: the caller's, never closed here. Out of the poll between a hit and pool_rearm.
    fd:      posix.FD,
    armed:   bool,

    to_child: [dynamic]u8,
    from:     [dynamic]u8,
}

Pool :: struct {
    lock:     sync.Mutex,
    // Thread-safe: buffers are filled on the worker and freed on the main thread.
    alloc:    mem.Allocator,
    jobs:     [dynamic]Job,
    seq:      u32,
    ino:      linux.Fd,
    wake_r:   posix.FD,
    wake_w:   posix.FD,
    worker:   ^thread.Thread,
    stopping: bool,
    started:  bool,
}

pool_start :: proc(p: ^Pool, alloc := context.allocator) -> bool {
    if p.started {
        return true
    }
    p.alloc = alloc
    // A write to an exited child must be EPIPE, not a death.
    sync.once_do(&sigpipe_once, proc() {
        act: posix.sigaction_t
        act.sa_handler = auto_cast posix.SIG_IGN
        posix.sigemptyset(&act.sa_mask)
        posix.sigaction(.SIGPIPE, &act, nil)
    })
    ino, ierr := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
    if ierr != .NONE {
        return false
    }
    fds: [2]posix.FD
    if posix.pipe(&fds) != .OK {
        linux.close(ino)
        return false
    }
    p.ino, p.wake_r, p.wake_w = ino, fds[0], fds[1]
    nonblock(p.wake_r)
    nonblock(p.wake_w)
    p.worker = thread.create(worker_proc)
    if p.worker == nil {
        linux.close(ino)
        posix.close(p.wake_r)
        posix.close(p.wake_w)
        return false
    }
    p.started = true
    p.worker.data = p
    thread.start(p.worker)
    return true
}

// Safe on a pool that never started.
pool_stop :: proc(p: ^Pool) {
    if !p.started {
        delete(p.jobs)
        p.jobs = nil
        return
    }
    context.allocator = p.alloc
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        p.jobs[i].closing = true
    }
    sync.atomic_store(&p.stopping, true)
    sync.mutex_unlock(&p.lock)
    poke(p)
    thread.join(p.worker)
    thread.destroy(p.worker)
    p.worker = nil
    linux.close(p.ino)
    posix.close(p.wake_r)
    posix.close(p.wake_w)
    delete(p.jobs)
    p.jobs = nil
    p.started = false
}

// Stderr is inherited: merged into stdout it would corrupt a framed protocol.
// The exec path is resolved before the fork: a child of a threaded process may not allocate.
pool_spawn :: proc(p: ^Pool, argv: []string, cwd := "") -> (Id, bool) {
    if !p.started || len(argv) == 0 {
        return {}, false
    }
    context.allocator = p.alloc
    exe, found := exe_path(argv[0])
    if !found {
        return {}, false
    }
    defer delete(exe)

    cargv := make([]cstring, len(argv) + 1)
    for arg, i in argv {
        cargv[i] = strings.clone_to_cstring(arg)
    }
    cexe := strings.clone_to_cstring(exe)
    cdir := cwd == "" ? cstring(nil) : strings.clone_to_cstring(cwd)
    defer {
        for s in cargv {
            delete(s)
        }
        delete(cargv)
        delete(cexe)
        delete(cdir)
    }

    // CLOEXEC, or an overlapping spawn's child inherits a write end and EOF never comes.
    in_pipe, out_pipe: [2]linux.Fd
    if linux.pipe2(&in_pipe, {.CLOEXEC}) != .NONE {
        return {}, false
    }
    if linux.pipe2(&out_pipe, {.CLOEXEC}) != .NONE {
        linux.close(in_pipe[0])
        linux.close(in_pipe[1])
        return {}, false
    }
    in_fds := [2]posix.FD{posix.FD(in_pipe[0]), posix.FD(in_pipe[1])}
    out_fds := [2]posix.FD{posix.FD(out_pipe[0]), posix.FD(out_pipe[1])}
    pid := posix.fork()
    if pid < 0 {
        for fd in ([?]posix.FD{in_fds[0], in_fds[1], out_fds[0], out_fds[1]}) {
            posix.close(fd)
        }
        return {}, false
    }
    if pid == 0 {
        // Child: pre-built cstrings only.
        if cdir != nil {
            posix.chdir(cdir) // best effort
        }
        posix.setsid() // its own group, so a close kills the tree
        posix.dup2(in_fds[0], posix.STDIN_FILENO)
        posix.dup2(out_fds[1], posix.STDOUT_FILENO)
        for fd in ([?]posix.FD{in_fds[0], in_fds[1], out_fds[0], out_fds[1]}) {
            if fd > posix.STDERR_FILENO {
                posix.close(fd)
            }
        }
        posix.execv(cexe, raw_data(cargv))
        posix._exit(127) // exec failed
    }
    posix.close(in_fds[0])
    posix.close(out_fds[1])
    nonblock(in_fds[1])
    nonblock(out_fds[0])

    sync.mutex_lock(&p.lock)
    j := job_take(p)
    j.kind = .Proc
    j.pid = pid
    j.into = in_fds[1]
    j.out = out_fds[0]
    id := j.id
    sync.mutex_unlock(&p.lock)
    poke(p)
    return id, true
}

// Watches the parent directory and filters by name, so a save by rename is seen. A directory
// path is watched whole.
pool_watch :: proc(p: ^Pool, path: string) -> (Id, bool) {
    if !p.started || path == "" {
        return {}, false
    }
    context.allocator = p.alloc
    full, _ := filepath.abs(path, context.temp_allocator)
    if full == "" {
        full = path
    }
    dir, base := filepath.dir(full), filepath.base(full)
    if os.is_dir(full) {
        dir, base = full, ""
    }
    cdir := strings.clone_to_cstring(dir, context.temp_allocator)
    wd, err := linux.inotify_add_watch(p.ino, cdir,
                                       {.CLOSE_WRITE, .MOVED_TO, .CREATE, .DELETE, .MOVED_FROM})
    if err != .NONE {
        return {}, false
    }
    sync.mutex_lock(&p.lock)
    j := job_take(p)
    j.kind = .Watch
    j.wd = wd
    j.dir = strings.clone(dir)
    j.base = strings.clone(base)
    id := j.id
    sync.mutex_unlock(&p.lock)
    return id, true
}

// A foreign fd in the poll set. Readable posts one empty Msg, then the fd stays out of the poll
// until pool_rearm, so a level-triggered fd does not spin the worker. The fd is never closed here.
pool_fd :: proc(p: ^Pool, fd: posix.FD) -> (Id, bool) {
    if !p.started || fd < 0 {
        return {}, false
    }
    context.allocator = p.alloc
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    j := job_take(p)
    j.kind, j.fd, j.armed = .Fd, fd, true
    poke(p)
    return j.id, true
}

// A no-op for any job but an Fd.
pool_rearm :: proc(p: ^Pool, id: Id) {
    if !p.started {
        return
    }
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    if j := job_at(p, id); j != nil && j.kind == .Fd && !j.armed {
        j.armed = true
        poke(p)
    }
}

// Queued, never written here: a full pipe would block the frame.
pool_write :: proc(p: ^Pool, id: Id, bytes: []u8) -> bool {
    if !p.started || len(bytes) == 0 {
        return false
    }
    context.allocator = p.alloc
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    j := job_at(p, id)
    if j == nil || j.kind != .Proc || j.into < 0 {
        return false
    }
    append(&j.to_child, ..bytes)
    poke(p)
    return true
}

// Only asks; the worker tears the job down. Nothing is reported.
pool_close :: proc(p: ^Pool, id: Id) {
    if !p.started {
        return
    }
    sync.mutex_lock(&p.lock)
    if j := job_at(p, id); j != nil {
        j.closing = true
        poke(p)
    }
    sync.mutex_unlock(&p.lock)
}

pool_live :: proc(p: ^Pool, id: Id) -> bool {
    if !p.started {
        return false
    }
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    j := job_at(p, id)
    return j != nil && !j.closing
}

// One Msg per job since the last drain. An ended job's slot is freed here, by its last reader.
pool_drain :: proc(p: ^Pool, alloc := context.temp_allocator) -> []Msg {
    if !p.started {
        return nil
    }
    out := make([dynamic]Msg, 0, 4, alloc)
    context.allocator = p.alloc
    blocked := false
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if !j.live || j.closing {
            continue
        }
        if len(j.from) == 0 && !j.hit && !j.ended {
            continue
        }
        m := Msg{id = j.id, code = j.code, ended = j.ended}
        if len(j.from) > 0 {
            m.bytes = slice.clone(j.from[:], alloc)
            blocked ||= len(j.from) >= CAP
            clear(&j.from)
        } else if j.hit && j.kind == .Watch {
            m.bytes = transmute([]u8)strings.concatenate({j.dir, "/", j.base}, alloc)
        }
        j.hit = false
        append(&out, m)
        if j.ended {
            job_free(j)
        }
    }
    sync.mutex_unlock(&p.lock)
    if blocked {
        // A job at CAP left the poll set; wake the worker to re-arm it.
        poke(p)
    }
    return out[:]
}

// --- the worker ---

@(private = "file")
sigpipe_once: sync.Once

@(private = "file")
worker_proc :: proc(th: ^thread.Thread) {
    p := (^Pool)(th.data)
    // Its own context: the creator's temp arena is not thread-safe.
    context = runtime.default_context()
    context.allocator = p.alloc
    fds := make([dynamic]posix.pollfd)
    owners := make([dynamic]int) // fds[i] belongs to jobs[owners[i]]; -1 for the two fixed ones
    defer {
        delete(fds)
        delete(owners)
    }
    for !sync.atomic_load(&p.stopping) {
        waiting := worker_arm(p, &fds, &owners)
        // A child with stdout closed but not reaped has no fd to wait on: poll on a timer.
        n := posix.poll(raw_data(fds), posix.nfds_t(len(fds)), waiting ? 20 : -1)
        if n < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            break
        }
        if .IN in fds[0].revents {
            drink(p.wake_r)
        }
        if .IN in fds[1].revents {
            worker_inotify(p)
        }
        if worker_pump(p, fds[:], owners[:]) {
            wake.hook()
        }
    }
    sync.mutex_lock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        job_tear_down(&p.jobs[i])
    }
    sync.mutex_unlock(&p.lock)
}

// Tears down closing jobs. True when a child with stdout closed still owes an exit code.
@(private = "file")
worker_arm :: proc(p: ^Pool, fds: ^[dynamic]posix.pollfd, owners: ^[dynamic]int) -> bool {
    clear(fds)
    clear(owners)
    append(fds, posix.pollfd{fd = p.wake_r, events = {.IN}})
    append(fds, posix.pollfd{fd = posix.FD(p.ino), events = {.IN}})
    append(owners, -1, -1)

    waiting := false
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if !j.live {
            continue
        }
        if j.closing {
            job_tear_down(j)
            continue
        }
        if j.kind == .Fd && j.armed {
            append(fds, posix.pollfd{fd = j.fd, events = {.IN}})
            append(owners, i)
        }
        if j.kind != .Proc {
            continue
        }
        if j.out >= 0 && len(j.from) < CAP {
            append(fds, posix.pollfd{fd = j.out, events = {.IN}})
            append(owners, i)
        }
        if j.into >= 0 && len(j.to_child) > 0 {
            append(fds, posix.pollfd{fd = j.into, events = {.OUT}})
            append(owners, i)
        }
        waiting ||= j.out < 0 && !j.ended
    }
    return waiting
}

@(private = "file")
worker_pump :: proc(p: ^Pool, fds: []posix.pollfd, owners: []int) -> bool {
    told := false
    sync.mutex_lock(&p.lock)
    defer sync.mutex_unlock(&p.lock)
    for pfd, i in fds[2:] {
        j := &p.jobs[owners[i + 2]]
        if !j.live || j.closing {
            continue
        }
        if j.kind == .Fd && pfd.revents != {} {
            j.hit, j.armed = true, false
            told = true
        } else if pfd.fd == j.out && pfd.revents != {} {
            told = worker_read(j) || told
        } else if pfd.fd == j.into && .OUT in pfd.revents {
            worker_send(j)
        }
    }
    for i in 0 ..< len(p.jobs) {
        j := &p.jobs[i]
        if j.live && !j.closing && j.kind == .Proc && j.out < 0 && !j.ended {
            told = worker_reap(j) || told
        }
    }
    return told
}

// Under the pool lock.
@(private = "file")
worker_read :: proc(j: ^Job) -> bool {
    buf: [16 * 1024]u8
    for {
        n := posix.read(j.out, raw_data(buf[:]), len(buf))
        if n > 0 {
            append(&j.from, ..buf[:n])
            if len(j.from) >= CAP {
                return true
            }
            continue
        }
        if n < 0 {
            err := posix.errno()
            if err == .EINTR {
                continue
            }
            if err == .EAGAIN || err == .EWOULDBLOCK {
                return len(j.from) > 0
            }
        }
        posix.close(j.out)
        j.out = -1
        return true
    }
}

@(private = "file")
worker_send :: proc(j: ^Job) {
    for len(j.to_child) > 0 {
        n := posix.write(j.into, raw_data(j.to_child), c.size_t(len(j.to_child)))
        if n > 0 {
            remove_range(&j.to_child, 0, int(n))
            continue
        }
        if n < 0 && posix.errno() == .EINTR {
            continue
        }
        if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) {
            return // full; the next POLLOUT takes the rest
        }
        // The child stopped reading: drop the queue.
        posix.close(j.into)
        j.into = -1
        clear(&j.to_child)
        return
    }
}

@(private = "file")
worker_reap :: proc(j: ^Job) -> bool {
    status: c.int
    if posix.waitpid(j.pid, &status, {.NOHANG}) != j.pid {
        return false
    }
    // Exited first: core's WIFSIGNALED compares signed and reads exit 0 as signal 0.
    if posix.WIFEXITED(status) {
        j.code = i32(posix.WEXITSTATUS(status))
    } else {
        j.code = 128 + i32(posix.WTERMSIG(status))
    }
    j.pid = 0
    if j.into >= 0 {
        posix.close(j.into)
        j.into = -1
    }
    j.ended = true
    return true
}

// Jobs on one directory share a `wd`, so every event is matched against all of them.
@(private = "file")
worker_inotify :: proc(p: ^Pool) {
    buf: [8 * 1024]u8
    told := false
    for {
        n, err := linux.read(p.ino, buf[:])
        if n <= 0 {
            if err == .EINTR {
                continue
            }
            break
        }
        sync.mutex_lock(&p.lock)
        for off := 0; off + size_of(linux.Inotify_Event) <= int(n); {
            ev := (^linux.Inotify_Event)(&buf[off])
            name := ""
            if ev.len > 0 {
                raw := buf[off + size_of(linux.Inotify_Event):][:ev.len]
                name = string(cstring(raw_data(raw)))
            }
            for i in 0 ..< len(p.jobs) {
                j := &p.jobs[i]
                if j.live && !j.closing && j.kind == .Watch && j.wd == ev.wd &&
                   (j.base == "" || j.base == name) {
                    j.hit = true
                    told = true
                }
            }
            off += size_of(linux.Inotify_Event) + int(ev.len)
        }
        sync.mutex_unlock(&p.lock)
        if int(n) < len(buf) {
            break
        }
    }
    if told {
        wake.hook()
    }
}

// --- internals ---

// Under the pool lock, on the worker only. The whole group is killed, or a grandchild keeps the
// pipe open. A watch's `wd` is not removed: another job may share it.
@(private = "file")
job_tear_down :: proc(j: ^Job) {
    if j.pid > 0 {
        posix.kill(-j.pid, .SIGTERM)
        status: c.int
        for _ in 0 ..< 20 {
            if posix.waitpid(j.pid, &status, {.NOHANG}) == j.pid {
                j.pid = 0
                break
            }
            time.sleep(5 * time.Millisecond)
        }
        if j.pid > 0 {
            posix.kill(-j.pid, .SIGKILL)
            posix.waitpid(j.pid, &status, {})
            j.pid = 0
        }
    }
    for fd in ([?]^posix.FD{&j.out, &j.into}) {
        if fd^ >= 0 {
            posix.close(fd^)
            fd^ = -1
        }
    }
    job_free(j)
}

@(private = "file")
job_free :: proc(j: ^Job) {
    delete(j.dir)
    delete(j.base)
    delete(j.to_child)
    delete(j.from)
    j^ = Job{id = j.id, out = -1, into = -1, fd = -1}
}

@(private = "file")
job_take :: proc(p: ^Pool) -> ^Job {
    for i in 0 ..< len(p.jobs) {
        if !p.jobs[i].live {
            p.seq += 1
            p.jobs[i] = Job{id = {u32(i), p.seq}, live = true, out = -1, into = -1, fd = -1}
            return &p.jobs[i]
        }
    }
    p.seq += 1
    append(&p.jobs, Job{id = {u32(len(p.jobs)), p.seq}, live = true, out = -1, into = -1, fd = -1})
    return &p.jobs[len(p.jobs) - 1]
}

@(private = "file")
job_at :: proc(p: ^Pool, id: Id) -> ^Job {
    if int(id.slot) >= len(p.jobs) {
        return nil
    }
    j := &p.jobs[id.slot]
    return j.live && j.id.seq == id.seq ? j : nil
}

@(private = "file")
poke :: proc(p: ^Pool) {
    b: [1]u8
    posix.write(p.wake_w, raw_data(b[:]), 1)
}

@(private = "file")
drink :: proc(fd: posix.FD) {
    buf: [256]u8
    for posix.read(fd, raw_data(buf[:]), len(buf)) == len(buf) {}
}

@(private = "file")
nonblock :: proc(fd: posix.FD) {
    flags := posix.fcntl(fd, .GETFL)
    posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
}

// A name with no slash is looked up in $PATH, on the main thread.
@(private = "file")
exe_path :: proc(name: string) -> (string, bool) {
    if strings.contains(name, "/") {
        return strings.clone(name), os.is_file(name)
    }
    path := os.get_env("PATH", context.temp_allocator)
    for dir in strings.split_iterator(&path, ":") {
        if dir == "" {
            continue
        }
        full, _ := filepath.join({dir, name}, context.temp_allocator)
        if os.is_file(full) {
            return strings.clone(full), true
        }
    }
    return "", false
}
