package tests

import "core:testing"

// cxxplug links libstdc++ as a shared object, as a C++ plugin usually does.

// A fault on a std::thread dies, blamed: libstdc++'s trampoline is under the plugin's frames,
// and the stack check does not unwind over it.
@(test)
cxx_thread_test :: proc(t: ^testing.T) {
    crash(t, "cxx-thread", "threadboom", .SIGSEGV, plug = "cxxplug")
}

// A fault in libc that libstdc++ called for the plugin is blamed on the plugin.
@(test)
cxx_blame_test :: proc(t: ^testing.T) {
    crash(t, "cxx-blame", "strboom", .SIGSEGV, plug = "cxxplug")
}

// An exception out of the entry ends in std::terminate: blamed on the plugin.
@(test)
cxx_throw_test :: proc(t: ^testing.T) {
    crash(t, "cxx-throw", "throw", .SIGABRT, plug = "cxxplug")
}
