package rc

import "core:sync"

// Atomic: the last release may come from another thread.

retain :: proc(count: ^int) {
    sync.atomic_add(count, 1)
}

// True when this took the last reference. atomic_sub answers the count before the subtraction.
release :: proc(count: ^int) -> bool {
    return sync.atomic_sub(count, 1) == 1
}
