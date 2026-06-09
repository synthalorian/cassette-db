# cassette-db — Implementation Plan

## Project Overview

Embedded key-value store with a cassette-tape inspired append-only log format. Zero dependencies, <1MB binary, ACID transactions.

**Language:** Zig  
**Constraint:** I mean, I GUESS you could store something that way  
**Stack:** pure Zig (no dependencies)

---

## Phase Breakdown

### Phase 1: Tape format spec — header, data block, EOF markers

**Goal:** Phase 1: Tape format spec — header, data block, EOF markers

**Deliverables:**
- [x] Core implementation (`src/tape.zig`)
- [x] Tests (header roundtrip, corruption detection, EOF marker, full tape write)
- [x] Documentation update

**Format v1 Specification:**

```
[Header]     5 bytes
  [0..4]     Magic: "CTDB"
  [4]        Version: 0x01

[Data Block] 11 + key_len + value_len bytes
  [0]        Block type: 0x01
  [1..3]     Key length: u16 big-endian
  [3..7]     Value length: u32 big-endian
  [7..k]     Key bytes
  [k..v]     Value bytes
  [v..v+4]   CRC32 (IEEE) of key || value, u32 big-endian

[EOF Block]  1 byte
  [0]        Block type: 0xFF
```

**Notes:**
- Checksum covers only key + value concatenation, not the block header.
- All multi-byte integers are big-endian for `xxd`-friendly inspection.
- `src/tape.zig` provides self-contained CRC32 to avoid std.hash.crc API churn.

---

### Phase 2: Low-level file I/O and append-only writer

**Goal:** Phase 2: Low-level file I/O and append-only writer

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 3: Read engine — seek, get, range scan

**Goal:** Phase 3: Read engine — seek, get, range scan

**Deliverables:**
- [x] Core implementation (`src/reader.zig`)
- [x] Tests (open, seek, readNext, get, scanRange, edge cases)
- [x] Documentation update

**Notes:**
- `TapeReader` opens existing tape files, verifies header, and provides:
  - `seek(offset)` — random access within the file
  - `readNext()` — sequential read of data blocks
  - `get(key)` — linear scan returning the last (most recent) value for a key
  - `scanRange(start, end, out)` — range scan returning latest values only, deduplicated
- All read operations preserve the reader's position; internal scans save/restore `read_offset`.
- `get` and `scanRange` implement append-only semantics: later writes shadow earlier ones for the same key. 

---

### Phase 4: CLI tool — get, put, scan commands

**Goal:** Phase 4: CLI tool — get, put, scan commands

**Deliverables:**
- [x] Core implementation (`src/main.zig`)
- [x] Tests (put/get roundtrip, latest value, scan range, missing key)
- [x] Documentation update

**Notes:**
- CLI supports `put <key> <value>`, `get <key>`, `scan <start> <end>`
- Default database file: `cassette.ctdb` (override with `-f`)
- `get` and `scan` use append-only semantics (latest value wins)
- Integration tests verify roundtrip, shadowing, range queries, and missing keys

---

### Phase 5: Crash recovery and consistency checks

**Goal:** Phase 5: Crash recovery and consistency checks

**Deliverables:**
- [x] Core implementation (`src/recovery.zig`)
- [x] Tests (healthy tape, truncated block, corrupt checksum, junk bytes, recovery, no-op)
- [x] Documentation update

**Features:**
- `verifyTape()` — scans entire file, validates every block checksum, detects truncation, counts unexpected bytes
- `recoverTape()` — truncates to last valid block, rewrites EOF marker, syncs to disk
- `ConsistencyReport` — detailed statistics (valid/corrupt/truncated blocks, unexpected bytes, health status)
- CLI commands: `check` (exits 1 if damaged) and `recover` (repairs in-place)

---

### Phase 6: Log compaction (garbage collection)

**Goal:** Phase 6: Log compaction (garbage collection)

**Deliverables:**
- [x] Core implementation (`src/compaction.zig`)
- [x] Tests (deduplication, order preservation, empty tape, single block, stats)
- [x] Documentation update

**Features:**
- `compactTape()` — reads the source tape, keeps only the latest value for each unique key,
  preserves the order of first appearance, writes a new temp file, and atomically renames it
  over the original.
- `CompactionReport` — reports bytes/blocks before and after, keys kept, and space saved.
- CLI command: `compact` — rewrites the database in-place removing stale versions.

**Notes:**
- Compaction calls `recoverTape()` first to ensure the source file ends cleanly before reading.
- The temp-file + rename approach makes compaction atomic: the original file is untouched until
  the compacted version is fully written and synced.

---

### Phase 7: C ABI header for FFI

**Goal:** Phase 7: C ABI header for FFI

**Deliverables:**
- [x] Core implementation (`src/cassette_c.zig`, `include/cassette.h`)
- [x] Tests (put/get roundtrip, missing key, scan range, check/compact)
- [x] Documentation update

**C ABI Surface:**

```c
CassetteDB* cassette_open(const char* path);
void        cassette_close(CassetteDB* db);
const char* cassette_last_error(void);

int cassette_put(CassetteDB* db, const char* key, size_t key_len,
                 const char* value, size_t value_len);
int cassette_get(CassetteDB* db, const char* key, size_t key_len,
                 char** value_out, size_t* value_len_out);
void cassette_free_value(char* value);

int cassette_scan(CassetteDB* db,
                  const char* start, size_t start_len,
                  const char* end, size_t end_len,
                  cassette_scan_callback_t cb, void* user_data);

int cassette_check(CassetteDB* db);
int cassette_recover(CassetteDB* db);
int cassette_compact(CassetteDB* db);
```

**Notes:**
- Static library `libcassette.a` is produced by `zig build` and installed to
  `zig-out/lib/` alongside the public header `zig-out/include/cassette.h`.
- The C ABI uses `std.heap.c_allocator` so that returned buffers can be freed
  with either `cassette_free_value()` or the host C runtime's `free()`.
- Error messages are stored in a thread-local buffer; `cassette_last_error()`
  returns a pointer valid until the next C ABI call on the same thread.

---

## Architecture Notes

### Key Decisions

- 

### Data Flow

```
[Input] → [Parse] → [Transform] → [Output]
```

### Error Handling Strategy

- 

---

## Testing Strategy

- Unit tests for core functions
- Integration tests for full pipeline
- Benchmarks for performance-critical paths

---

## Open Questions

1. 
2. 

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*
