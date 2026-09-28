/* A second test plugin that asks for what cplug asks for. Its name sorts first. */
#include <string.h>
#include "../../include/lues.h"

#define LIT(s) s, sizeof(s) - 1

LUES_MAIN {
    if (strcmp(api->app, "test") != 0) {
        return 1;
    }
    api->request_bind(api, self, LIT("text"), LIT("alt+x"), LIT("bplug"));
    api->request_config(api, self, LIT("edit"), LIT("view"), LIT("bplug"));
    api->request_config(api, self, LIT("edit"), LIT("tab"), LIT("2"));
    return 0;
}
