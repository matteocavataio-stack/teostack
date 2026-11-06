#define XXH_STATIC_LINKING_ONLY
#include <string.h>
#include "teo_xxh64_state.h"

size_t teo_xxh64_state_size(void) { return sizeof(XXH64_state_t); }

size_t teo_xxh64_export_state(const XXH64_state_t *state, uint8_t *out, size_t capacity) {
    if (state == NULL || out == NULL || capacity < sizeof(XXH64_state_t)) return 0;
    memcpy(out, state, sizeof(XXH64_state_t));
    return sizeof(XXH64_state_t);
}

int teo_xxh64_import_state(XXH64_state_t *state, const uint8_t *in, size_t length) {
    if (state == NULL || in == NULL || length != sizeof(XXH64_state_t)) return 0;
    memcpy(state, in, sizeof(XXH64_state_t));
    return 1;
}
