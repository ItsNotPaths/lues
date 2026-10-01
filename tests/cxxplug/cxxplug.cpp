// The C++ test plugin, against lues.h only, with libstdc++ linked as a shared object.
#include <stdexcept>
#include <string>
#include <thread>
#include "../../include/lues.h"

#define LIT(s) s, sizeof(s) - 1

static int *volatile NOWHERE;

// Faults on a std::thread: libstdc++'s trampoline sits under the plugin's frames.
static int32_t threadboom(const lues_api *, lues_self, const lues_at *, const char *, size_t) {
    std::thread([] { *NOWHERE = 1; }).join();
    return 0;
}

// Faults in libc's memcpy, called from libstdc++'s std::string, called from the plugin. Not
// null: libstdc++ throws for that.
static const char *volatile BAD = reinterpret_cast<const char *>(8);

static int32_t strboom(const lues_api *, lues_self, const lues_at *, const char *, size_t) {
    std::string s("x");
    s.append(BAD, 4096); // out of line, in libstdc++.so; a constructor's copy is inlined
    return int32_t(s.size());
}

// Throws out of the entry: no handler above it, so std::terminate aborts.
static int32_t throw_cmd(const lues_api *, lues_self, const lues_at *, const char *, size_t) {
    throw std::runtime_error("out of the entry");
}

extern "C" LUES_MAIN {
    api->register_command(api, self, LIT("threadboom"), LIT("fault on a std::thread"), threadboom);
    api->register_command(api, self, LIT("strboom"), LIT("fault under std::string"), strboom);
    api->register_command(api, self, LIT("throw"), LIT("throw out of the entry"), throw_cmd);
    api->register_command(api, self, LIT("hello"), LIT("exit 0"),
                          [](const lues_api *, lues_self, const lues_at *, const char *, size_t) -> int32_t {
                              return 0;
                          });
    return 0;
}
