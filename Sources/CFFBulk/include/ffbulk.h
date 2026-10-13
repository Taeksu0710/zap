#ifndef FFBULK_H
#define FFBULK_H

#include <stdint.h>
#include <stddef.h>

#define FF_NAME_MAX 1024

typedef struct {
    uint64_t file_id;
    int64_t mtime_sec;
    int64_t crtime_sec; // creation (birth) time
    uint64_t size;      // 0 for directories
    uint8_t is_dir;     // 1 if directory, 0 otherwise
    uint16_t name_len;  // byte length of name, not including NUL
    char name[FF_NAME_MAX];
} ff_entry_t;

// Called once per batch of entries read from a single getattrlistbulk() call.
// `entries` is only valid for the duration of the callback.
typedef void (*ff_entry_callback)(const ff_entry_t *entries, int count, void *context);

// Enumerates the immediate children of `path` using getattrlistbulk().
// Returns 0 on success, -1 on error (errno set by the failing syscall).
int ff_scan_dir(const char *path, ff_entry_callback callback, void *context);

#endif
