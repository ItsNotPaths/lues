/* Mirrors src/abi/abi.odin. An app header includes this and appends its calls after
 * `lues_api` in a struct of its own. */
#ifndef LUES_H
#define LUES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUES_API 5

#define LUES_EXPORT __attribute__((visibility("default")))

typedef uint64_t lues_self;
typedef uint64_t lues_doc;
typedef uint64_t lues_io;
typedef uint32_t lues_kind;
typedef uint16_t lues_token;

#define LUES_NO_DOC UINT64_MAX /* resolves to no doc */

typedef enum {
    LUES_CALL_RAN    = 0,
    LUES_CALL_ABSENT = 1, /* no such command, or its plugin is gone */
    LUES_CALL_FAILED = 2  /* it faulted, or calls nested too deep */
} lues_call_status;

typedef enum {
    LUES_HOOK_EMIT = 0, /* every listener runs */
    LUES_HOOK_BAIL = 1  /* stops at the first non-zero exit */
} lues_hook_mode;

typedef enum {
    LUES_ADVICE_BEFORE = 1,
    LUES_ADVICE_AFTER  = 2,
    LUES_ADVICE_AROUND = 3 /* runs the rest through advice_next */
} lues_advice;

#define LUES_PREPEND (1u << 0) /* runs before, or outside, the joins already there */

typedef enum {
    LUES_EVENT_CHORD  = 0,
    LUES_EVENT_TEXT   = 1,
    LUES_EVENT_MOVED  = 2,
    LUES_EVENT_IO     = 3, /* at->io names the job; text is gone after the call */
    LUES_EVENT_IO_END = 4  /* at->code is the exit status; never sent for a job you closed */
} lues_event;

/* --- the read view: good until released --- */

typedef struct {
    const char *ptr;
    size_t      len;
} lues_block;

typedef struct {
    ptrdiff_t block, off, len, doc_off;
} lues_piece;

/* starts[at .. at+n) + delta are the starts of lines first .. first+n. */
typedef struct {
    ptrdiff_t first, at, n, delta;
} lues_seg;

/* `app` is the app's side view; its header says what it points at. */
typedef struct {
    const lues_block *blocks;
    const ptrdiff_t  *starts;
    const lues_piece *pieces;
    const lues_seg   *segs;
    size_t            nblocks, nstarts, npieces, nsegs;
    size_t            size; /* bytes */
    size_t            lines;
    uint64_t          gen;
    lues_doc          doc;
    const void       *app;
} lues_snapshot;

/* `inst` is non-NULL only for your own instance. */
typedef struct {
    lues_doc             doc;
    void                *inst;
    const lues_snapshot *snap;
    lues_io     io;
    int32_t     code;
    char        _pad[4];
} lues_at;

struct lues_api;

typedef int32_t (*lues_event_fn)(const struct lues_api *api, lues_self self, const lues_at *at,
                                 lues_event ev, const char *text, size_t len);
typedef void *(*lues_open_fn)(const struct lues_api *api, lues_self self, lues_doc doc,
                              const char *args, size_t args_len);
typedef void (*lues_close_fn)(const struct lues_api *api, lues_self self, lues_doc doc,
                              void *inst);
typedef int32_t (*lues_command_fn)(const struct lues_api *api, lues_self self,
                                   const lues_at *at, const char *args, size_t args_len);

typedef struct {
    lues_open_fn  open;
    lues_close_fn close;
    lues_event_fn event;
} lues_kind_vt;

/* Set `size = sizeof(lues_kind_spec)`. */
typedef struct {
    size_t       size;
    const char  *name;
    size_t       name_len;
    const char  *ctx;
    size_t       ctx_len;
    lues_kind_vt vt;
} lues_kind_spec;

/* --- the write side: set `size = sizeof(...)` on each --- */

/* [lo, hi) of the doc as you read it becomes `text`. `tag` is the app's. */
typedef struct {
    size_t      size;
    size_t      lo, hi;
    const char *text;
    size_t      text_len;
    uint32_t    tag;
    char        _pad[4];
} lues_edit;

/* Channels not in `set` come from the layer below. `attrs` are the app's bits. A run with a
 * `key` is DATA, not a look: the app reads it by name, and tok, attrs and set are ignored. */
#define LUES_CHAN_FG    (1u << 0)
#define LUES_CHAN_BG    (1u << 1)
#define LUES_CHAN_ATTRS (1u << 2)

typedef struct {
    size_t     size;
    size_t     lo, hi;
    lues_token tok;
    uint8_t    attrs;
    uint8_t    set; /* LUES_CHAN_* */
    char       _pad[4];
    /* LUES_API 5. */
    lues_token  key;  /* an interned name; 0 is a look */
    uint8_t     open; /* text typed at lo joins the run, as it always does at hi */
    char        _pad2[5];
    const char *text; /* NULL: the run's own bytes are its value */
    size_t      text_len;
} lues_span;

/* Replaces your runs in [lo, hi). */
typedef struct {
    size_t           size;
    size_t           lo, hi;
    const lues_span *spans;
    size_t           nspans;
} lues_span_pub;

#define LUES_SUBMIT_FORGET (1u << 0) /* derived bytes: nothing to undo */
#define LUES_SUBMIT_JOIN   (1u << 1) /* into the last undo step */

typedef struct lues_api {
    uint32_t    version; /* LUES_API */
    uint32_t    app_version;
    const char *app; /* refuse an app you are not for */

    lues_kind (*register_kind)(const struct lues_api *api, lues_self self,
                               const lues_kind_spec *spec);
    void (*register_command)(const struct lues_api *api, lues_self self,
                             const char *name, size_t name_len,
                             const char *doc, size_t doc_len, lues_command_fn fn);
    void (*request_bind)(const struct lues_api *api, lues_self self,
                         const char *ctx, size_t ctx_len,
                         const char *chord, size_t chord_len,
                         const char *line, size_t line_len);
    void (*request_config)(const struct lues_api *api, lues_self self,
                           const char *section, size_t section_len,
                           const char *key, size_t key_len,
                           const char *value, size_t value_len);
    lues_token (*register_token)(const struct lues_api *api, lues_self self,
                                 const char *name, size_t name_len);
    void (*register_watch)(const struct lues_api *api, lues_self self, lues_event_fn fn);

    /* Copied at the call; dropped whole if the doc moved past `gen` first. */
    void (*submit)(const struct lues_api *api, lues_self self, lues_doc doc, uint64_t gen,
                   const lues_edit *edits, size_t nedits, const lues_span_pub *spans,
                   uint32_t flags);
    const lues_snapshot *(*snapshot)(const struct lues_api *api, lues_self self, lues_doc doc);
    void (*release)(const struct lues_api *api, lues_self self, const lues_snapshot *snap);

    void (*message)(const struct lues_api *api, lues_self self, const char *text,
                    size_t text_len);

    lues_io (*io_spawn)(const struct lues_api *api, lues_self self, lues_doc doc,
                        const char *const *argv, size_t nargv,
                        const char *cwd, size_t cwd_len);
    void (*io_write)(const struct lues_api *api, lues_self self, lues_io io,
                     const char *bytes, size_t len);
    lues_io (*io_watch)(const struct lues_api *api, lues_self self, lues_doc doc,
                        const char *path, size_t path_len);
    /* Readable = LUES_EVENT_IO with no text; read the fd yourself. Never closed by the kernel. */
    lues_io (*io_fd)(const struct lues_api *api, lues_self self, lues_doc doc, int32_t fd);
    void (*io_close)(const struct lues_api *api, lues_self self, lues_io io);

    /* LUES_API 2. Unloads you the way a fault does: the call in progress is abandoned and
     * dispatch gets it back. Call it from the plugin's own thread. With no net to catch it
     * (none installed, or another thread), the process dies and you are quarantined. */
    void (*fail)(const struct lues_api *api, lues_self self, const char *msg, size_t msg_len)
        __attribute__((noreturn));

    /* LUES_API 3. For an object you dlopened yourself: `addr` is anything inside it, such as a
     * function it exports. A fault there then unloads you, as one in your own .so does, instead
     * of killing the process. Returns 0 when adopted. Refused for the kernel's object, libc and
     * another plugin's .so. Adopt before the first call into it, and keep it open while you are
     * loaded: the kernel keeps counting whatever is mapped at its base as yours. */
    int32_t (*adopt)(const struct lues_api *api, lues_self self, const void *addr);

    /* LUES_API 4. Runs the command `name` inside this call, on `doc`, as a bind would. `code`
     * gets its exit when it ran. A fault in it unloads its plugin, not you. */
    lues_call_status (*call)(const struct lues_api *api, lues_self self, lues_doc doc,
                             const char *name, size_t name_len,
                             const char *args, size_t args_len, int32_t *code);

    /* LUES_API 4. A hook point is yours to run once defined; 0 when defined. Anyone may join
     * it, before or after it is defined. A listener gets `args` as a command does. */
    int32_t (*hook_define)(const struct lues_api *api, lues_self self,
                           const char *name, size_t name_len, lues_hook_mode mode);
    void (*hook_add)(const struct lues_api *api, lues_self self, const char *name,
                     size_t name_len, lues_command_fn fn, uint32_t flags);
    /* `code` gets 0, or under BAIL the exit that stopped it. ABSENT: not a point you defined.
     * A listener that faults is unloaded and the rest still run. */
    lues_call_status (*hook_run)(const struct lues_api *api, lues_self self, lues_doc doc,
                                 const char *name, size_t name_len,
                                 const char *args, size_t args_len, int32_t *code);

    /* LUES_API 4. Joins the command `name`, before or after it is registered, and wraps every
     * run of it: a bind, a call. The first joined is outermost. Advice gets the command's args;
     * a before or after's exit is ignored, and an around's is the command's. */
    void (*advise)(const struct lues_api *api, lues_self self, const char *name,
                   size_t name_len, lues_command_fn fn, lues_advice how, uint32_t flags);
    /* From an around: runs the rest of the chain with `args`, and `code` gets its exit.
     * ABSENT: no around of yours is running. */
    lues_call_status (*advice_next)(const struct lues_api *api, lues_self self,
                                    const char *args, size_t args_len, int32_t *code);

    /* LUES_API 4. Doc-vars: named bytes per doc. Only the definer sets one; anyone gets and
     * watches it. When the definer unloads, the values stay, read-only, until a plugin of the
     * same name defines it again. 0 when done. */
    int32_t (*var_define)(const struct lues_api *api, lues_self self, const char *name,
                          size_t name_len);
    int32_t (*var_set)(const struct lues_api *api, lues_self self, lues_doc doc,
                       const char *name, size_t name_len, const char *value, size_t value_len);
    /* The value's length, with as much as fits copied into buf; -1 when it has none. */
    ptrdiff_t (*var_get)(const struct lues_api *api, lues_self self, lues_doc doc,
                         const char *name, size_t name_len, char *buf, size_t cap);
    /* fn runs on each change, on that doc, with the new value as its args. */
    void (*var_watch)(const struct lues_api *api, lues_self self, const char *name,
                      size_t name_len, lues_command_fn fn);
} lues_api;

#ifdef __cplusplus
#define LUES_SIZE(t, n) static_assert(sizeof(t) == n, #t)
#else
#define LUES_SIZE(t, n) _Static_assert(sizeof(t) == n, #t)
#endif
LUES_SIZE(lues_block, 16);
LUES_SIZE(lues_piece, 32);
LUES_SIZE(lues_seg, 32);
LUES_SIZE(lues_snapshot, 104);
LUES_SIZE(lues_at, 40);
LUES_SIZE(lues_edit, 48);
LUES_SIZE(lues_span, 56);
LUES_SIZE(lues_span_pub, 40);
LUES_SIZE(lues_kind_vt, 24);
LUES_SIZE(lues_kind_spec, 64);
LUES_SIZE(lues_api, 232);

/* Non-zero refuses the load and reverts what you registered. */
#define LUES_MAIN LUES_EXPORT int32_t lues_main(const lues_api *api, lues_self self)

typedef int32_t (*lues_entry_fn)(const lues_api *api, lues_self self);

#ifdef __cplusplus
}
#endif
#endif /* LUES_H */
