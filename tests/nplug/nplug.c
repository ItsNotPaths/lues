/* The nesting test plugin: its commands call back into the kernel through the test app's api
 * tail, which runs another command inside this one. */
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

LUES_MAIN {
    if (strcmp(api->app, "test") != 0 || api->app_version < 1) {
        return 1;
    }
    api->register_command(api, self, LIT("nest"), LIT("run a command inside this one"), nest);
    api->register_command(api, self, LIT("die"), LIT("dereference null"), die);
    return 0;
}
