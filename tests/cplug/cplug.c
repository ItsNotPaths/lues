/* The C test plugin, against lues.h only. Each test adds the arms it needs. */
#define _POSIX_C_SOURCE 200809L

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <string.h>
#include "../../include/lues.h"

#define LIT(s) s, sizeof(s) - 1

/* Volatile, or the store folds into a trap instruction: SIGILL, not SIGSEGV. */
static int *volatile NOWHERE;

static int32_t boom(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)api, (void)self, (void)at, (void)args, (void)args_len;
    *NOWHERE = 1;
    return 0;
}

/* Faults in a qsort comparator: libc's frames sit between the fault and dispatch. */
static int boom_cmp(const void *a, const void *b) {
    (void)a, (void)b;
    *NOWHERE = 1;
    return 0;
}

static int32_t sortboom(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                        size_t args_len) {
    int two[2] = {2, 1};
    (void)api, (void)self, (void)at, (void)args, (void)args_len;
    qsort(two, 2, sizeof two[0], boom_cmp);
    return 0;
}

/* A garbage edits pointer: the kernel faults reading it, inside the api call. */
static int32_t badsubmit(const lues_api *api, lues_self self, const lues_at *at,
                         const char *args, size_t args_len) {
    (void)args, (void)args_len;
    api->submit(api, self, at->doc, 0, (const lues_edit *)8, 1, NULL, 0);
    return 0;
}

/* `fail <msg>`: never returns. */
static int32_t fail(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)at;
    api->fail(api, self, args, args_len);
    return 0; /* gcc drops noreturn on a pointer */
}

/* fail from a thread of the plugin's own: no net there, so the process dies. */
static const lues_api *FAIL_API;
static lues_self       FAIL_SELF;

static void *fail_thread(void *arg) {
    (void)arg;
    FAIL_API->fail(FAIL_API, FAIL_SELF, LIT("off the dispatch thread"));
    return NULL;
}

static int32_t failoff(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                       size_t args_len) {
    pthread_t t;
    (void)at, (void)args, (void)args_len;
    FAIL_SELF = self;
    FAIL_API = api;
    if (pthread_create(&t, NULL, fail_thread, NULL) != 0) {
        return 1;
    }
    pthread_join(t, NULL);
    return 0;
}

/* `scan <path>` dlopens the grammar at path and faults inside it; `adopt <path>` adopts it
 * first. Exits 1 when it can't be opened or adopted. */
typedef int (*scan_fn)(const int *at);

static int32_t grammar(const lues_api *api, lues_self self, const char *args, size_t args_len,
                       int adopt) {
    char    path[256];
    void   *lib;
    scan_fn scan;
    if (args_len >= sizeof path) {
        return 1;
    }
    memcpy(path, args, args_len);
    path[args_len] = 0;
    lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL || (scan = (scan_fn)dlsym(lib, "grammar_scan")) == NULL) {
        return 1;
    }
    if (adopt && api->adopt(api, self, (const void *)scan) != 0) {
        return 1;
    }
    return scan(NOWHERE);
}

static int32_t scan(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)at;
    return grammar(api, self, args, args_len, 0);
}

static int32_t adopt(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    (void)at;
    return grammar(api, self, args, args_len, 1);
}

/* Adopts its own .so, then the kernel's: exits with the second's answer. */
static int32_t adoptk(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    (void)at, (void)args, (void)args_len;
    if (api->adopt(api, self, (const void *)boom) != 0) {
        return 2;
    }
    return api->adopt(api, self, (const void *)api->submit);
}

/* Bounded, so a broken watchdog still lets the test finish. */
static int32_t hang(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    struct timespec t = {5, 0};
    (void)api, (void)self, (void)at, (void)args, (void)args_len;
    nanosleep(&t, NULL);
    return 0;
}

/* `hello <n>` exits with n. */
static int32_t hello(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    (void)at;
    api->message(api, self, args, args_len);
    return args_len == 1 ? args[0] - '0' : 0;
}

/* Exits 1 with no doc. */
static int32_t size(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    char buf[32];
    int  n;

    (void)args, (void)args_len;
    if (at->snap == NULL) {
        return 1;
    }
    n = snprintf(buf, sizeof buf, "%zu", at->snap->size);
    api->message(api, self, buf, (size_t)n);
    return 0;
}

static lues_edit edit_at_end(const lues_at *at, const char *text, size_t len) {
    lues_edit e = {sizeof(lues_edit), at->snap->size, at->snap->size, text, len, 0, {0}};
    return e;
}

/* `append <text>` at the end of the focused doc. */
static int32_t append(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    lues_edit e;
    if (at->snap == NULL) {
        return 1;
    }
    e = edit_at_end(at, args, args_len);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
    return 0;
}

/* `derive <text>`: appended with nothing to undo. */
static int32_t derive(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    lues_edit e;
    if (at->snap == NULL) {
        return 1;
    }
    e = edit_at_end(at, args, args_len);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, LUES_SUBMIT_FORGET);
    return 0;
}

/* Two submits against one gen: the second is stale when it drains. */
static int32_t race(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    lues_edit e;
    if (at->snap == NULL) {
        return 1;
    }
    e = edit_at_end(at, args, args_len);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
    return 0;
}

/* One run with token 3 as fg over the whole doc. */
static int32_t paint(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    lues_span     sp;
    lues_span_pub pub;
    (void)args, (void)args_len;
    if (at->snap == NULL) {
        return 1;
    }
    sp = (lues_span){sizeof(lues_span), 0, at->snap->size, 3, 0, LUES_CHAN_FG, {0}};
    pub = (lues_span_pub){sizeof(lues_span_pub), 0, at->snap->size, &sp, 1};
    api->submit(api, self, at->doc, at->snap->gen, NULL, 0, &pub, 0);
    return 0;
}

/* A snapshot held past the call's own, then released: says its size. */
static int32_t peek(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    const lues_snapshot *s = api->snapshot(api, self, at->doc);
    char                 buf[32];
    int                  n;
    (void)args, (void)args_len;
    if (s == NULL) {
        return 1;
    }
    n = snprintf(buf, sizeof buf, "%zu", s->size);
    api->release(api, self, s);
    api->message(api, self, buf, (size_t)n);
    return 0;
}

/* An edit whose `size` is too short for its fields. */
static int32_t short_edit(const lues_api *api, lues_self self, const lues_at *at,
                          const char *args, size_t args_len) {
    lues_edit e;
    if (at->snap == NULL) {
        return 1;
    }
    e = edit_at_end(at, args, args_len);
    e.size = sizeof(size_t);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
    return 0;
}

static void say_n(const lues_api *api, lues_self self, const char *what, int n) {
    char buf[32];
    int  len = snprintf(buf, sizeof buf, "%s %d", what, n);
    api->message(api, self, buf, (size_t)len);
}

/* Says how many times it ran in this load: a fresh load starts from 1. */
static int COUNT;

static int32_t count(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    (void)at, (void)args, (void)args_len;
    say_n(api, self, "count", ++COUNT);
    return 0;
}

/* The `note` kind: open fills the doc with its args (`boom` faults), text appends, moved is
 * counted. */
static int MOVED, WATCHED, OPEN; /* &OPEN is the instance pointer */

static void *note_open(const lues_api *api, lues_self self, lues_doc doc, const char *args,
                       size_t args_len) {
    const lues_snapshot *s;
    lues_edit            e = {sizeof(lues_edit), 0, 0, args, args_len, 0, {0}};
    if (args_len == 4 && memcmp(args, "boom", 4) == 0) {
        *NOWHERE = 1;
    }
    s = api->snapshot(api, self, doc);
    api->submit(api, self, doc, s->gen, &e, 1, NULL, 0);
    api->release(api, self, s);
    return &OPEN;
}

static void note_close(const lues_api *api, lues_self self, lues_doc doc, void *inst) {
    (void)doc;
    if (inst == &OPEN) {
        api->message(api, self, LIT("closed"));
    }
}

static int32_t note_event(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                          const char *text, size_t len) {
    lues_edit e;
    if (ev == LUES_EVENT_MOVED) {
        say_n(api, self, "moved", ++MOVED);
        return 0;
    }
    if (ev != LUES_EVENT_TEXT || at->inst != &OPEN) {
        return 0;
    }
    e = edit_at_end(at, text, len);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
    return 1;
}

/* io: output of a job is appended to its doc; PIPE is the fd job's, read here when told. */
static int     PIPE[2] = {-1, -1};
static lues_io PIPE_IO;

static void append_bytes(const lues_api *api, lues_self self, const lues_at *at,
                         const char *bytes, size_t len) {
    lues_edit e;
    if (at->snap == NULL || len == 0) {
        return;
    }
    e = edit_at_end(at, bytes, len);
    api->submit(api, self, at->doc, at->snap->gen, &e, 1, NULL, 0);
}

/* Counts every .Moved it is told. Answers "call again" LATCH more times. */
static int LATCH;

static int32_t watch(const lues_api *api, lues_self self, const lues_at *at, lues_event ev,
                     const char *text, size_t len) {
    char    buf[64];
    ssize_t n;
    switch (ev) {
    case LUES_EVENT_IO:
        if (at->io == PIPE_IO) {
            n = read(PIPE[0], buf, sizeof buf);
            append_bytes(api, self, at, buf, n > 0 ? (size_t)n : 0);
        } else {
            append_bytes(api, self, at, text, len);
        }
        return 0;
    case LUES_EVENT_IO_END:
        say_n(api, self, "end", at->code);
        return 0;
    default:
        say_n(api, self, "watched", ++WATCHED);
        return LATCH-- > 0;
    }
}

/* `spawn <sh -c script>` into the focused doc. */
static int32_t spawn(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    char        script[256];
    const char *argv[] = {"sh", "-c", script};
    if (args_len >= sizeof script) {
        return 1;
    }
    memcpy(script, args, args_len);
    script[args_len] = 0;
    return api->io_spawn(api, self, at->doc, argv, 3, NULL, 0) == 0;
}

/* A pipe whose read end the kernel polls for the focused doc. */
static int32_t pipe_cmd(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                        size_t args_len) {
    (void)args, (void)args_len;
    if (pipe(PIPE) != 0) {
        return 1;
    }
    PIPE_IO = api->io_fd(api, self, at->doc, PIPE[0]);
    return PIPE_IO == 0;
}

static int32_t poke(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    (void)api, (void)self, (void)at;
    return write(PIPE[1], args, args_len) != (ssize_t)args_len;
}

/* `watchfile <path>`: changes to it append its path to the focused doc. */
static int32_t watchfile(const lues_api *api, lues_self self, const lues_at *at,
                         const char *args, size_t args_len) {
    return api->io_watch(api, self, at->doc, args, args_len) == 0;
}

static int32_t latch(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    (void)api, (void)self, (void)at;
    LATCH = args_len == 1 ? args[0] - '0' : 0;
    return 0;
}

static lues_token COMMENT;

static int32_t tok(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                   size_t args_len) {
    (void)at, (void)args, (void)args_len;
    say_n(api, self, "token", COMMENT);
    return 0;
}

LUES_MAIN {
    if (strcmp(api->app, "test") != 0) {
        return 1;
    }
    static const lues_kind_spec NOTE = {sizeof(lues_kind_spec), LIT("note"), NULL, 0,
                                        {note_open, note_close, note_event}};
    if (api->register_kind(api, self, &NOTE) == 0) {
        return 1;
    }
    api->register_watch(api, self, watch);
    COMMENT = api->register_token(api, self, LIT("comment"));
    api->request_bind(api, self, LIT("text"), LIT("alt+x"), LIT("hello 1"));
    api->request_config(api, self, LIT("edit"), LIT("view"), LIT("cplug"));
    api->request_config(api, self, LIT("edit"), LIT("tab"), LIT("4"));
    api->register_command(api, self, LIT("hello"), LIT("say the args, exit with a digit"), hello);
    api->register_command(api, self, LIT("size"), LIT("say the focused doc's size"), size);
    api->register_command(api, self, LIT("boom"), LIT("dereference null"), boom);
    api->register_command(api, self, LIT("hang"), LIT("stop returning"), hang);
    api->register_command(api, self, LIT("sortboom"), LIT("fault under qsort"), sortboom);
    api->register_command(api, self, LIT("fail"), LIT("fail with the args"), fail);
    api->register_command(api, self, LIT("failoff"), LIT("fail from another thread"), failoff);
    api->register_command(api, self, LIT("badsubmit"), LIT("fault the kernel in submit"), badsubmit);
    api->register_command(api, self, LIT("append"), LIT("append the args"), append);
    api->register_command(api, self, LIT("derive"), LIT("append with nothing to undo"), derive);
    api->register_command(api, self, LIT("race"), LIT("append twice against one gen"), race);
    api->register_command(api, self, LIT("paint"), LIT("paint the doc with token 3"), paint);
    api->register_command(api, self, LIT("peek"), LIT("say the size from a held snapshot"), peek);
    api->register_command(api, self, LIT("latch"), LIT("answer call-again n times"), latch);
    api->register_command(api, self, LIT("spawn"), LIT("run sh -c into the doc"), spawn);
    api->register_command(api, self, LIT("pipe"), LIT("poll a pipe for the doc"), pipe_cmd);
    api->register_command(api, self, LIT("poke"), LIT("write into the pipe"), poke);
    api->register_command(api, self, LIT("watchfile"), LIT("watch a file for the doc"), watchfile);
    api->register_command(api, self, LIT("tok"), LIT("say the token it got"), tok);
    api->register_command(api, self, LIT("short"), LIT("submit a short edit"), short_edit);
    api->register_command(api, self, LIT("count"), LIT("say how many times it ran"), count);
    api->register_command(api, self, LIT("scan"), LIT("fault in a dlopened grammar"), scan);
    api->register_command(api, self, LIT("adopt"), LIT("adopt a grammar, then fault in it"), adopt);
    api->register_command(api, self, LIT("adoptk"), LIT("adopt the kernel's object"), adoptk);
    return 0;
}
