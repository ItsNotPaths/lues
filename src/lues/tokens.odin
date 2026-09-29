package lues

import "core:slice"
import "core:strings"
import "../docs"

TOKEN_MAX :: 1024

// One name, one id; base_tokens come first. 0 when the table is full or the name is empty.
token_intern :: proc(k: ^Kernel, name: string) -> Token {
    context = k.ctx
    if name == "" {
        return 0
    }
    if i, found := slice.linear_search(k.tokens[:], name); found {
        return Token(i)
    }
    if len(k.tokens) >= TOKEN_MAX {
        return 0
    }
    append(&k.tokens, strings.clone(name))
    return Token(len(k.tokens) - 1)
}

// For the app's palette. "" for an id nobody interned.
token_name :: proc(k: ^Kernel, tok: Token) -> string {
    context = k.ctx
    return k.tokens[tok] if int(tok) < len(k.tokens) else ""
}

tokens_seed :: proc(k: ^Kernel) {
    context = k.ctx
    for base in k.base_tokens {
        append(&k.tokens, strings.clone(base))
    }
}

tokens_destroy :: proc(k: ^Kernel) {
    context = k.ctx
    for t in k.tokens {
        delete(t)
    }
    delete(k.tokens)
}

// One per plugin name, so a reload publishes into the same buckets.
producer_intern :: proc(k: ^Kernel, name: string) -> docs.Producer {
    context = k.ctx
    if who, known := producer_find(k, name); known {
        return who
    }
    append(&k.producers, strings.clone(name))
    return docs.Producer(len(k.producers) - 1)
}

producer_find :: proc(k: ^Kernel, name: string) -> (docs.Producer, bool) {
    context = k.ctx
    for p, i in k.producers {
        if p == name {
            return docs.Producer(i), true
        }
    }
    return 0, false
}

producer_name :: proc(k: ^Kernel, who: docs.Producer) -> string {
    context = k.ctx
    i := int(who)
    return k.producers[i] if i < len(k.producers) else ""
}

producers_destroy :: proc(k: ^Kernel) {
    context = k.ctx
    for p in k.producers {
        delete(p)
    }
    delete(k.producers)
}
