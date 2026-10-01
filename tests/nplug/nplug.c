/* The nesting test plugin: its commands call back into the kernel through the test app's api
 * tail, which runs another command inside this one. */
#include <stdio.h>
#include <string.h>
#include "../../include/lues.h"

#define LIT(s) s, sizeof(s) - 1

/* The test app's vtable, app_version 1 on: lues_api, then its own calls. */
typedef struct {
    lues_api base;
    /* Runs `line` ("name args") as a command, inside this call. 0 when it exited 0. */
    int32_t (*run)(const lues_api *api, lues_self self, const char *line, size_t len);
} test_api;

static int *volatile NOWHERE;

/* `nest <line>`: runs line nested, then says something, so a dead plugin's resume shows. */
static int32_t nest(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    int32_t code;
    (void)at;
    code = ((const test_api *)api)->run(api, self, args, args_len);
    api->message(api, self, LIT("back"));
    return code;
}

static int32_t die(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                   size_t args_len) {
    (void)api, (void)self, (void)at, (void)args, (void)args_len;
    *NOWHERE = 1;
    return 0;
}

/* Says how a call or a hook run went, and exits with the status. */
static int32_t said(const lues_api *api, lues_self self, lues_call_status st, int32_t code) {
    char buf[32];
    int  n = st == LUES_CALL_RAN      ? snprintf(buf, sizeof buf, "ran %d", code)
             : st == LUES_CALL_ABSENT ? snprintf(buf, sizeof buf, "absent")
                                      : snprintf(buf, sizeof buf, "failed");
    api->message(api, self, buf, (size_t)n);
    return (int32_t)st;
}

/* `call <name> <args>`: runs it through the api's call arm and says how that went. */
static int32_t call(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    const char      *sp = memchr(args, ' ', args_len);
    size_t           name_len = sp ? (size_t)(sp - args) : args_len;
    size_t           rest = sp ? args_len - name_len - 1 : 0;
    int32_t          code = -1;
    lues_call_status st;
    (void)at;
    st = api->call(api, self, LUES_NO_DOC, args, name_len, sp ? sp + 1 : "", rest, &code);
    return said(api, self, st, code);
}

/* The `greet` hook: `define-emit` or `define-bail` defines it, `fire <args>` runs it. */
static int32_t define_emit(const lues_api *api, lues_self self, const lues_at *at,
                           const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    return api->hook_define(api, self, LIT("greet"), LUES_HOOK_EMIT);
}

static int32_t define_bail(const lues_api *api, lues_self self, const lues_at *at,
                           const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    return api->hook_define(api, self, LIT("greet"), LUES_HOOK_BAIL);
}

static int32_t fire(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                    size_t args_len) {
    int32_t          code = -1;
    lues_call_status st;
    (void)at;
    st = api->hook_run(api, self, LUES_NO_DOC, LIT("greet"), args, args_len, &code);
    return said(api, self, st, code);
}

static int32_t greet_n(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                       size_t args_len) {
    char buf[64];
    int  n = snprintf(buf, sizeof buf, "n %.*s", (int)args_len, args);
    (void)at;
    api->message(api, self, buf, (size_t)n);
    return 0;
}

static int32_t join_n(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    (void)at, (void)args, (void)args_len;
    api->hook_add(api, self, LIT("greet"), greet_n, 0);
    return 0;
}

/* Advice on cplug's `hello`. The around passes 7 on in place of the args. */
static void say_args(const lues_api *api, lues_self self, const char *what, const char *args,
                     size_t args_len) {
    char buf[64];
    int  n = snprintf(buf, sizeof buf, "%s %.*s", what, (int)args_len, args);
    api->message(api, self, buf, (size_t)n);
}

static int32_t before(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    (void)at;
    say_args(api, self, "before", args, args_len);
    return 9;
}

static int32_t after(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                     size_t args_len) {
    (void)at;
    say_args(api, self, "after", args, args_len);
    return 9;
}

static int32_t around(const lues_api *api, lues_self self, const lues_at *at, const char *args,
                      size_t args_len) {
    int32_t code = -1;
    (void)at, (void)args, (void)args_len;
    api->message(api, self, LIT("around in"));
    api->advice_next(api, self, LIT("7"), &code);
    api->message(api, self, LIT("around out"));
    return code;
}

static int32_t advise_before(const lues_api *api, lues_self self, const lues_at *at,
                             const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    api->advise(api, self, LIT("hello"), before, LUES_ADVICE_BEFORE, 0);
    return 0;
}

static int32_t advise_after(const lues_api *api, lues_self self, const lues_at *at,
                            const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    api->advise(api, self, LIT("hello"), after, LUES_ADVICE_AFTER, 0);
    return 0;
}

static int32_t advise_around(const lues_api *api, lues_self self, const lues_at *at,
                             const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    api->advise(api, self, LIT("hello"), around, LUES_ADVICE_AROUND, 0);
    return 0;
}

/* advice_next outside any around. */
static int32_t next_bare(const lues_api *api, lues_self self, const lues_at *at,
                         const char *args, size_t args_len) {
    int32_t          code = -1;
    lues_call_status st;
    (void)at;
    st = api->advice_next(api, self, args, args_len, &code);
    return said(api, self, st, code);
}

static int32_t advise_die(const lues_api *api, lues_self self, const lues_at *at,
                          const char *args, size_t args_len) {
    (void)at, (void)args, (void)args_len;
    api->advise(api, self, LIT("hello"), die, LUES_ADVICE_AROUND, 0);
    return 0;
}

LUES_MAIN {
    if (strcmp(api->app, "test") != 0 || api->app_version < 1) {
        return 1;
    }
    api->register_command(api, self, LIT("nest"), LIT("run a command inside this one"), nest);
    api->register_command(api, self, LIT("call"), LIT("run a command through call"), call);
    api->register_command(api, self, LIT("define-emit"), LIT("define greet"), define_emit);
    api->register_command(api, self, LIT("define-bail"), LIT("define greet, bailing"), define_bail);
    api->register_command(api, self, LIT("fire"), LIT("run greet"), fire);
    api->register_command(api, self, LIT("join-n"), LIT("join greet"), join_n);
    api->register_command(api, self, LIT("advise-before"), LIT("advise hello"), advise_before);
    api->register_command(api, self, LIT("advise-after"), LIT("advise hello"), advise_after);
    api->register_command(api, self, LIT("advise-around"), LIT("advise hello"), advise_around);
    api->register_command(api, self, LIT("advise-die"), LIT("advise hello with a fault"), advise_die);
    api->register_command(api, self, LIT("next-bare"), LIT("advice_next from a command"), next_bare);
    api->register_command(api, self, LIT("die"), LIT("dereference null"), die);
    return 0;
}
