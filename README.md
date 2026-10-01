# lues

An application kernel in Odin. It loads `.so` plugins in one process, behind a fixed C ABI.

A document is bytes in a piece table that lues owns. A change is a byte splice, submitted
against a generation. Plugins read documents in place, through snapshots. The application
decides what the bytes mean and how to draw them.

cordis is heart, and lues is the heartworm. Composition is modeled on
[Cordis](https://github.com/cordiverse/cordis), over a unix "dataspace", all bytes.

## lues does:

- Documents: the piece table, splices, undo, the change log, spans and snapshots.
- The loader and a ledger per plugin. Unload reverts the ledger in reverse order.
- Kinds, commands, bind and config requests, tokens and watchers.
- An io thread. All waiting happens there.
- Fault recovery and quarantine.

## Plugins

A plugin includes `include/lues.h` and exports `lues_main`. Each application appends its own
calls after `lues_api`. Every struct that a plugin allocates starts with `size`, so the ABI
can grow at the end.

Plugins can use each other:

- `call` runs a command by name. If the command is gone, the result is `LUES_CALL_ABSENT`.
- Hooks: a plugin defines a hook point and runs it. Any plugin can join it.
- Advice: before, after and around a command, by name.
- Doc-vars: named bytes for each document. Only the definer writes them. Anyone can read and
  watch them.

Joins are by name, so a plugin can join before the target loads. Unload takes back hook
points, joins, advice and doc-var definitions. What a kind's `open` registers is taken back
when that document closes. Doc-var values stay after an unload, read-only, until a plugin
with the same name defines the doc-var again.

## Faults

The threat model is buggy plugins, not neccesarily hostile ones.

- A fault or a `fail` in plugin code unloads that plugin, and the process continues. If the
  application starts the watchdog, a hang does the same.
- Plugin threads run under the same rules. Unload stops them.
- Kernel memory is write-protected with a pkey while plugin code runs. A stray write faults
  at once, and the plugin is blamed.
- With `Spec.unguarded` there is no net: a fault kills the process, for a debugger or ASan.
- A fault in a place where an unwind is not safe kills the process. The plugin is blamed and
  quarantined, so the next start does not load it.

## Limits

- Linux, x86-64 and glibc only. Without pkey hardware, kernel memory is not protected.
- A thread that starts before `kernel_init` must call `kernel_thread()` before it uses lues.
- A fault in a libc function that the plugin called (`memcpy`, `strlen`) is blamed, not
  unwound.
- Memory that a plugin allocated and did not free leaks on each unload.

## Build and test

The tests need the Odin compiler, a C compiler, a C++ compiler, and Rust with cargo.

```
odin test tests
```

The tests build the plugins in `tests/` (C, C++ and Rust) and load them. `tests/abi_test.odin`
compares `lues.h` and the Rust mirror with `src/abi/abi.odin`.

## Layout

| Path | Contents |
|---|---|
| `src/abi` | the plugin ABI alone, for a plugin in Odin to import |
| `src/lues` | the kernel: loader, api, dispatch, faults, joins, doc-vars |
| `src/docs`, `src/pt` | the document store and the piece table |
| `src/work`, `src/wake` | the io worker, and the wakeup of the host's frame loop |
| `src/conf` | the `key = value` file format for binds and config |
| `include/lues.h` | the C ABI |
| `ws.md` | the plan, with open and parked work |
