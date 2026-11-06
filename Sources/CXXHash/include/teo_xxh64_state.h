#ifndef TEO_XXH64_STATE_H
#define TEO_XXH64_STATE_H

#include <stddef.h>
#include <stdint.h>
#include "xxhash.h"

/// Salvataggio/ripristino dello stato di un hash XXH64 in corso (per riprendere una copia da metà file).
/// Lo stato di XXH64 è una struttura piatta (nessun puntatore): si copia byte per byte.
size_t teo_xxh64_state_size(void);
/// Copia lo stato in `out` (almeno `teo_xxh64_state_size()` byte). Restituisce i byte scritti, 0 se `capacity` non basta.
size_t teo_xxh64_export_state(const XXH64_state_t *state, uint8_t *out, size_t capacity);
/// Ripristina lo stato da `in`. Restituisce 0 se `length` non coincide con la dimensione attesa.
int teo_xxh64_import_state(XXH64_state_t *state, const uint8_t *in, size_t length);

#endif
