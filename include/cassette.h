#ifndef CASSETTE_H
#define CASSETTE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque handle to an open cassette database.
 *
 * Obtain with `cassette_open()` and release with `cassette_close()`.
 */
typedef struct CassetteDB CassetteDB;

/**
 * Scan callback invoked once for each unique key in the requested range.
 *
 * `key_ptr` / `key_len` and `value_ptr` / `value_len` point into temporary
 * buffers that are only valid for the duration of the callback. Copy them
 * if you need to keep them around.
 */
typedef void (*cassette_scan_callback_t)(
    const char* key_ptr,
    size_t key_len,
    const char* value_ptr,
    size_t value_len,
    void* user_data
);

/* ---------------- Open / close ---------------- */

/**
 * Open an existing cassette database or create a new one at `path`.
 *
 * Returns `NULL` on error. Use `cassette_last_error()` to inspect the
 * failure reason.
 */
CassetteDB* cassette_open(const char* path);

/**
 * Close a database handle and release associated resources.
 *
 * Passing `NULL` is a no-op.
 */
void cassette_close(CassetteDB* db);

/**
 * Return the most recent error message for the calling thread.
 *
 * The returned string is null-terminated and remains valid only until the
 * next C ABI call on the same thread. Do not free it.
 */
const char* cassette_last_error(void);

/* ---------------- Write ---------------- */

/**
 * Store a key-value pair in the database.
 *
 * Returns 0 on success, non-zero on error.
 */
int cassette_put(
    CassetteDB* db,
    const char* key,
    size_t key_len,
    const char* value,
    size_t value_len
);

/* ---------------- Read ---------------- */

/**
 * Retrieve the most recent value for `key`.
 *
 * On success returns 0, writes a pointer to a newly allocated,
 * null-terminated buffer to `*value_out`, and writes the value length
 * (not including the terminator) to `*value_len_out`.
 *
 * The caller must release `*value_out` with `cassette_free_value()`.
 *
 * Returns 1 if the key was not found, or another non-zero value on error.
 */
int cassette_get(
    CassetteDB* db,
    const char* key,
    size_t key_len,
    char** value_out,
    size_t* value_len_out
);

/**
 * Release a value buffer previously returned by `cassette_get()`.
 *
 * Passing `NULL` is a no-op.
 */
void cassette_free_value(char* value);

/* ---------------- Scan ---------------- */

/**
 * Scan the key range `[start, end)` and invoke `callback` once for each
 * latest unique key in that range.
 *
 * Returns 0 on success, non-zero on error.
 */
int cassette_scan(
    CassetteDB* db,
    const char* start,
    size_t start_len,
    const char* end,
    size_t end_len,
    cassette_scan_callback_t callback,
    void* user_data
);

/* ---------------- Maintenance ---------------- */

/**
 * Run a consistency check on the database.
 *
 * Returns 0 if healthy, 1 if damaged, and a negative value on error.
 */
int cassette_check(CassetteDB* db);

/**
 * Recover a damaged database file in place.
 *
 * Truncates to the last valid block and rewrites the EOF marker.
 *
 * Returns 0 on success, non-zero on error.
 */
int cassette_recover(CassetteDB* db);

/**
 * Compact the database, removing stale key versions.
 *
 * Returns 0 on success, non-zero on error.
 */
int cassette_compact(CassetteDB* db);

#ifdef __cplusplus
}
#endif

#endif /* CASSETTE_H */
