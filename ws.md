<!-- (swiss :tags (fault loader abi compose memory sdk) :sev (wrong-behavior missing-system polish)) -->

lues becomes a "real" kernel, inside one process. Kernel memory is read only to
plugins, all change goes through the abi, and a plugin that fails is unloaded instead of
taking the process down wherever that can be done soundly. a rust port is
shelved (see the end).

## Decisions

- Threat model: buggy plugins only.-
- Plugins stay in-process, as `.so`s.
- A crashing `.so` can't always be survived.
- The kernel stays Odin. rust port is a future possibility.
- The plugin ABI stays C. 

## Workstream A1: failures that unload instead of kill

Goal: when a plugin crashes, lues detaches and kills it, and the process lives. The kill is
only sound when nothing but the plugin's own code is left half-done, so each gap below is a
way that a crash still leaves another party's state or code running.

Built (2026-09-29): fail-call, reload-fresh-map (memfd copy per load), adopt-objects,
sdk-shims for Rust, and nested-dispatch-blame from A2. The Zig and Odin SDKs have no code yet;
their panics go to `fail` when they are started (Zig: its `panic`; Odin:
`context.assertion_failure_proc`). C relies on the fault net and ASan in `:harness`.

Left, in order:

1. foreign-frames (done, 2026-09-30): guard 1 walks the stack, and every frame from the pc down
   to the dispatch frame must be the plugin's or an adopted object's. A fault with foreign
   frames under it dies, blamed. A hang there is single-stepped (the trap flag, one SIGTRAP
   per instruction) until the plugin's own frames are back on top, then unwound; a blocked
   syscall comes back with EINTR on the way. It dies, blamed, if a second window ends first.
   The kernel cannot name what libc is doing: libc is stripped, and memcpy and friends
   resolve to unnamed IFUNC copies.
2. `leaf-libc-faults` (parked, 2026-10-01): a fault in libc that the plugin called straight
   away is blamed on it (done, 2026-09-30: the handler looks through libc's frames to the
   caller). Unwinding it needs to know that the libc code takes no lock. The symbols route
   (a table of the lock-free leaves from libc's debug file) does not work on a pinned distro:
   Omarchy's stable mirror holds glibc 2.44+r24, and no server keeps that build's debug info
   (Arch's debuginfod and debug repo serve only the current build; the Arch Linux Archive
   keeps no -debug packages). Its fix is the copies route under "Once lues is done". Until
   then such a crash dies, blamed.
3. interpose and net-kept (done, 2026-10-01): the app exports `sigaction` and `signal` (an
   Odin @(export) in an executable lands in its dynamic symbols, no `-rdynamic` needed;
   glibc's `signal` calls its own `sigaction`, so it needs its own export). A call from
   plugin code for a fault signal stores the handler as that plugin's chained handler;
   `SIGALRM` and `SIGTRAP` are refused with EINVAL. A fault that lues would die on runs the
   running plugin's chained handler first. One that retries forever is a hang, and the
   watchdog ends it. After each dispatch, lues puts back a handler that a raw syscall
   replaced, chains the plugin's, and says so. lues's own calls go to libc's through
   `os_sigaction`. Not seccomp: its filter can't be lifted, and io_spawn's children would
   inherit it. An RTLD_DEEPBIND library still binds libc's first; the check after the
   dispatch catches that too.
4. plugin-threads (done, 2026-10-01): plugins may start threads (decided 2026-09-30). The
   app exports `pthread_create`; a thread that plugin code starts runs under a copy of its
   parent's fault frame, so it is judged and unwound the same way, and never reads the
   plugin table. A fault on it ends the thread and posts the plugin in `Kernel.lost`; the
   main thread unloads it at its next dispatch or frame (`loader_reap`). No watchdog watches
   a plugin thread. Not caught: C11 `thrd_create` (glibc calls its own `pthread_create`), and
   a raw `clone` (Go's runtime).
5. thread-reap (done, 2026-10-01): every plugin thread holds a slot (THREADS_MAX, 256; past
   it `pthread_create` says EAGAIN). Unloading signals the plugin's threads with the reap
   signal (the top realtime signal; plugins are refused it), and each unwinds to its base
   frame and exits, stepped back out of libc or an api call first, as a hang is. A thread
   that has not ended by REAP_MS (1 s; for example, blocked on a lock) keeps the plugin
   mapped: the plugin is marked Faulted and the user is told.
6. faulted-fini (done, 2026-10-01): a faulted plugin stays mapped, so glibc runs its
   destructors at exit, and a crash there is acceptable if it is blamed right (decided
   2026-09-30). Each faulted plugin goes in a table that outlives the kernel (base, name,
   path; DEAD_MAX 64). A crash with no frame armed is blamed on the dead plugin whose frame
   it is in, quarantined and traced. While one is mapped, kernel_destroy leaves the handler
   its own copy of the quarantine and faults fds. Not covered: a destructor that hangs at
   exit, and the objects a dead plugin adopted.
7. abort-catch (done, 2026-10-01): C++ plugins are wanted (decided 2026-09-30). SIGABRT is a
   fault signal now (chained like the others). glibc's abort raises SIGABRT before it takes
   any lock (read in 2.44's code; from 2.41, the gate), so an abort with only libc's frames
   between it and the plugin's own (a C assert) is unwound like fail. Past other code, such
   as libstdc++'s std::terminate, it dies, blamed on the plugin: an abort is on purpose,
   unlike a fault in an unadopted object. A SIGABRT sent from outside the process dies,
   blamed on nobody. Still to come with the C++ SDK: a shim that wraps each entry in
   `catch (...)` and calls `fail`, the same as Rust, so an exception never reaches
   std::terminate. It gets a stub when the SDK is started.

8. `cxx-runtime-frames`: a C++ plugin links libstdc++ and libgcc_s as shared objects. Blame
   looks through them as through libc (done, 2026-10-01: lues finds them by where a plugin's
   own lookup of `__cxa_throw` and `_Unwind_RaiseException` lands). lues.h compiles as C++
   now (LUES_SIZE). Open: the stack check treats their frames as foreign, so a fault on a
   `std::thread` (libstdc++'s trampoline under the plugin's frames) dies, blamed, and a reap
   never ends one. tests/cxxplug is the C++ fixture.

<!-- (skeleton :tags (fault loader sdk)) -->

_3 holes, 3 marks, 3 ready. Generated by `swiss sync`; edits inside this block are lost._

- **cxx-runtime-frames** · fault · ready
  - [src/lues/fault.odin:671](src/lues/fault.odin#L671) · wrong-behavior · a C++ runtime frame under the plugin's (libstdc++'s std::thread trampoline) counts as foreign, so a fault on a std::thread dies and its reap never ends it.
- **leaf-libc-faults** · fault · ready
  - [src/lues/fault.odin:518](src/lues/fault.odin#L518) · missing-system · a fault in memcpy or strlen the plugin called is blamed, not unwound: nothing here knows which libc code takes no lock.
- **pkey-tagging** · memory, fault · ready
  - [src/lues/fault.odin:289](src/lues/fault.odin#L289) · missing-system · kernel memory stays writable during plugin code; a stray plugin write corrupts it without a fault.

<!-- /skeleton -->

## Workstream A2: composition (the Emacs part)

Plugins reaching each other, not just the kernel. Every piece is a ledger record, so unloading
a plugin takes back its calls, hooks, advice and variables the same way it takes back kinds
and commands today.

1. nested-dispatch-blame (done, 2026-09-29): plugin-to-plugin calls nest dispatches, so the guard becomes
   a stack and a fault blames the innermost plugin.
2. `plugin-calls`: late-bound `call(name, args)` through the command table.
3. `plugin-hooks`: `hook_define`, `hook_add` and `hook_run`. The kernel owns the order, which
   keeps the frame layering that ruled out processes.
4. `advice`: wrappers stacked around a command (before, after, around).
5. `doc-vars`: named per-document state, plus a watch when a value changes.

<!-- (skeleton :tags (compose)) -->

_4 holes, 4 marks, 3 ready. Generated by `swiss sync`; edits inside this block are lost._

- **doc-vars** · compose, abi · ready
  - [src/lues/api.odin:43](src/lues/api.odin#L43) · missing-system · no per-document variables: plugins cannot share named state.
- **plugin-calls** · compose, abi · ready
  - [src/lues/api.odin:41](src/lues/api.odin#L41) · missing-system · no call arm: a plugin cannot run another plugin's command.
- **plugin-hooks** · compose, abi · ready
  - [src/lues/api.odin:42](src/lues/api.odin#L42) · missing-system · no hook arms: a plugin cannot declare a hook point for others to join.
- **advice** · compose, abi · needs **plugin-calls**
  - [src/lues/commands.odin:26](src/lues/commands.odin#L26) · missing-system · the command's own fn always runs; another plugin cannot wrap it.

<!-- /skeleton -->

### To investigate later (from Cordis)

Not planned yet and not marked in code. These are ideas taken from
[Cordis](https://github.com/cordiverse/cordis) ([paper](https://arxiv.org/abs/2608.25512)).
Cordis has two kinds of composability: *temporal*, where removing a component reverts its
effects (lues's ledger already does this), and *spatial*, where components declare
dependencies and are activated or deactivated as those come and go (lues has nothing for this).

- **Reactive plugin dependencies (`plugin-needs`).** Once A advises B's command, joins B's
  hook, or reads B's doc-vars, A depends on B. Today, if B faults, the tombstones keep A from
  crashing but leave it half-working and uninformed. If A declared "needs B", the kernel could
  revert A through its ledger when B goes and bring it back when B reloads, so a crash degrades
  exactly the plugins that depended on the one that crashed. Would build on `plugin-calls`,
  `plugin-hooks` and `advice`.
- **Instance scopes.** Hooks, watches and doc-vars registered inside a kind's `open` would be
  reverted automatically at `close`: the same ledger, one level down, instead of each plugin
  cleaning up by hand.
- **Services as named, versioned interfaces.** Depend on a capability ("formatter v1") instead
  of a plugin name, so another provider can stand in. `plugin-calls` by string name is the weak
  form of this.

The line to keep if any of this is taken up: **control-plane effects are reverted** (kinds,
commands, hooks, advice, watches, io jobs, span layers), and **data-plane effects persist**.
Text a plugin submitted is the user's document, with undo as the way back, and bind and
config requests stay in their files. Cordis reverts everything; lues shouldn't.

## Workstream A3: kernel memory

1. kernel-arenas (done, 2026-09-29): the kernel stops sharing libc `malloc` with plugins. A plugin's heap
   overrun can no longer surface as a crash in kernel code. This is worth doing even without
   pkeys. Covers `k.ctx`, the temp allocator, the docs store and the io pool.
   - oket's host-side C libraries need the same treatment. libvterm takes an allocator
     (`vterm_new_with_allocator`); harfbuzz only at build time (vendored, so doable);
     libgrapheme doesn't allocate.
2. `pkey-tagging`: kernel arenas carry one pkey, write-disabled while plugin code runs and
   writable inside api calls. The switch goes into the `fault_busy` bracket. A stray write
   faults right away, blamed on the right plugin. On hardware without pkeys, lues runs as it
   does today. Permissions are per thread: the io worker keeps write access, and threads a
   plugin starts inherit the locked-down state.
3. `plugin-arenas`: an optional arena per plugin, handed out through the api and freed whole
   on unload.

Also for oket: make `oket_block.ptr` const (`lues.h` already is), so writing into a snapshot
is a compile error rather than a pkey fault.

<!-- (skeleton :tags (memory)) -->

_2 holes, 2 marks, 2 ready. Generated by `swiss sync`; edits inside this block are lost._

- **pkey-tagging** · memory, fault · ready
  - [src/lues/fault.odin:289](src/lues/fault.odin#L289) · missing-system · kernel memory stays writable during plugin code; a stray plugin write corrupts it without a fault.
- **plugin-arenas** · memory, abi · ready
  - [src/lues/loader.odin:338](src/lues/loader.odin#L338) · missing-system · no arena per plugin; what a faulted plugin allocated leaks.

<!-- /skeleton -->

## Tooling

`abi-codegen`: generate `lues.h` and a Rust `sys` module from `abi.odin`, or at least check in
the test suite that the three agree field by field. Today only the size asserts catch drift,
and a field swapped for one of the same size passes them. Best done before A2 grows the api.

<!-- (skeleton :tags (abi) :goal abi-codegen) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **abi-codegen** · abi · ready
  - [src/lues/abi.odin:6](src/lues/abi.odin#L6) · missing-system · lues.h and rustplug's sys module are kept in step with this file by hand; nothing generates them or checks they agree.

<!-- /skeleton -->

## Once lues is "done"

Not planned yet and not marked in code (decided 2026-09-30).

- Plugins get lues's own mem* and str* copies (musl's, a few KB) through their GOT, patched
  at load and at adopt. Every libc leaf fault is then unwound on every machine, with no debug
  file. This is the fix for `leaf-libc-faults`; the symbols route fails on pinned distros. It costs about 200 lines of ELF relocation code, and large
  copies run 1.5 to 3 times slower than glibc's.

## Shelved: a Rust port of the kernel

Not planned (decided 2026-09-29); kept here in case it comes back. The port's holes were
marked in code until then, and are in git history before the commit that shelved it.

The shape it had: one crate per Odin package (`lues-pt`, `lues-docs`, `lues-work` absorbing
`wake`, `lues-conf`, `lues`), linked by oket as `liblues.a`, with the Odin kernel kept running
until the crate passed the same suite. What was learned about it:

- **Dispatch:** `sigsetjmp` returns twice, which Rust doesn't model. A C trampoline that calls
  the plugin itself (`if (sigsetjmp(env, 1)) return FAULTED; return fn(...);`) means a fault
  jumps over plugin frames only, never Rust ones; nested dispatch keeps that.
- **Fault handlers:** std installs its stack-overflow `SIGSEGV` handler only under a Rust
  `main`; under an Odin host there is nothing to take over.
- **Panics:** no kernel panic may unwind into plugin frames: every `extern "C"` arm catches its
  own, or the crate builds with `panic = "abort"`.
- **Arenas:** a staticlib's `#[global_allocator]` covers only that crate's code, so the kernel
  heap (TLSF over its own mappings) becomes the global allocator and the per-frame temp arena
  a `Bump` reset in `kernel_frame`. No per-collection allocators. Only one Rust staticlib may
  be in oket's final link.
- **Host ABI:** oket extends lues through Odin `Hooks`, `Spec` and the `Box` api tail, so a
  crate needs a second C ABI for the host. Port it only once A2's hook and advice surface is
  settled.
- **Testing:** check `pt` and `docs` early with differential tests (the same random edits,
  undos and spans fed to both, snapshots compared), not only once the whole host ABI exists.
- **The main gain wasn't memory safety:** it was one `#[repr(C)]` source for `lues.h` via
  cbindgen, instead of `lues.h`, `abi.odin` and rustplug's `sys` kept in step by hand.
