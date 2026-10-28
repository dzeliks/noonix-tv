// the rust core's c interface (core/src/ffi.rs). strings are utf-8 json, owned by the core and
// only valid inside the callback
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef void (*noonix_result_fn)(void *ctx, uint64_t id, bool ok, const char *json);
typedef void (*noonix_push_fn)(void *ctx, const char *name, const char *json);

bool noonix_start(void *ctx, noonix_result_fn on_result, noonix_push_fn on_push);
uint64_t noonix_call(const char *method, const char *args);
