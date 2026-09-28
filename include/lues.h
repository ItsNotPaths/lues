/* Mirrors src/lues/abi.odin. An app header includes this and appends its calls after
 * `lues_api` in a struct of its own. */
#ifndef LUES_H
#define LUES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUES_API 2

#define LUES_EXPORT __attribute__((visibility("default")))

typedef uint64_t lues_self;
typedef uint64_t lues_doc;
typedef uint64_t lues_io;
typedef uint32_t lues_kind;
typedef uint16_t lues_token;

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

/* Channels not in `set` come from the layer below. `attrs` are the app's bits. */
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
     * (none installed, another thread, or inside a call from the kernel), the process dies
     * and you are quarantined. */
    void (*fail)(const struct lues_api *api, lues_self self, const char *msg, size_t msg_len)
        __attribute__((noreturn));
} lues_api;

_Static_assert(sizeof(lues_block) == 16, "lues_block");
_Static_assert(sizeof(lues_piece) == 32, "lues_piece");
_Static_assert(sizeof(lues_seg) == 32, "lues_seg");
_Static_assert(sizeof(lues_snapshot) == 104, "lues_snapshot");
_Static_assert(sizeof(lues_at) == 40, "lues_at");
_Static_assert(sizeof(lues_edit) == 48, "lues_edit");
_Static_assert(sizeof(lues_span) == 32, "lues_span");
_Static_assert(sizeof(lues_span_pub) == 40, "lues_span_pub");
_Static_assert(sizeof(lues_kind_vt) == 24, "lues_kind_vt");
_Static_assert(sizeof(lues_kind_spec) == 64, "lues_kind_spec");
_Static_assert(sizeof(lues_api) == 144, "lues_api");

/* Non-zero refuses the load and reverts what you registered. */
#define LUES_MAIN LUES_EXPORT int32_t lues_main(const lues_api *api, lues_self self)

typedef int32_t (*lues_entry_fn)(const lues_api *api, lues_self self);

#ifdef __cplusplus
}
#endif
#endif /* LUES_H */
