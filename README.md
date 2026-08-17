# cassette-db

> Embedded key-value store with a cassette-tape inspired append-only log format. Zero dependencies, <1MB binary, ACID transactions.

**Language:** Zig  
**Constraint:** I mean, I GUESS you could store something that way  
**Stack:** pure Zig (no dependencies)

---

## Features

- Append-only log format with tape-track headers
- ACID transactions via write-ahead log
- Zero external dependencies
- <1MB compiled binary
- Human-debuggable format (xxd-friendly)
- Crash recovery and log compaction
- C ABI for FFI bindings

---

## Development Plan

All phases complete. See `PLAN.md` for detailed architecture decisions.

- [x] Phase 1: Tape format spec — header, data block, EOF markers
- [x] Phase 2: Low-level file I/O and append-only writer
- [x] Phase 3: Read engine — seek, get, range scan
- [x] Phase 4: CLI tool with get, put, scan commands
- [x] Phase 5: Crash recovery and consistency checks
- [x] Phase 6: Log compaction (garbage collection)
- [x] Phase 7: C ABI header for FFI

---

## Getting Started

### Prerequisites

- Zig toolchain

### Build

```bash
zig build
```

### Run Tests

```bash
zig build test
```

### Run

```bash
zig build run
```

### Check / Recover / Compact

```bash
# Check consistency of a database file
zig build run -- check -f mydb.ctdb

# Recover a damaged database file (truncates to last valid block)
zig build run -- recover -f mydb.ctdb

# Compact the database (remove stale key versions)
zig build run -- compact -f mydb.ctdb
```

### C FFI

A static library with a C ABI is built automatically:

```bash
zig build
# Produces zig-out/lib/libcassette.a and zig-out/include/cassette.h
```

Example usage from C:

```c
#include <cassette.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    CassetteDB* db = cassette_open("example.ctdb");
    if (!db) {
        fprintf(stderr, "open failed: %s\n", cassette_last_error());
        return 1;
    }

    cassette_put(db, "hello", 5, "world", 5);

    char* value = NULL;
    size_t value_len = 0;
    if (cassette_get(db, "hello", 5, &value, &value_len) == 0) {
        printf("got: %.*s\n", (int)value_len, value);
        cassette_free_value(value);
    }

    cassette_close(db);
    return 0;
}
```

---

## Architecture

See `PLAN.md` for detailed architecture decisions and implementation notes.

---

## License

MIT

---

## ☕ Support the Developer

If this project saved you time, solved a problem, or just made your day a little more neon, you can fuel the next one:

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/synthalorian)
