/* Not a plugin: a third-party object cplug dlopens itself, as a syntax plugin does a grammar. */
__attribute__((visibility("default"))) int grammar_scan(const int *at) {
    return *at;
}
