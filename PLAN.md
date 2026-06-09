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

### Phase 4: Transaction log and ACID semantics

**Goal:** Phase 4: Transaction log and ACID semantics

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 5: Crash recovery and consistency checks

**Goal:** Phase 5: Crash recovery and consistency checks

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 6: Log compaction (garbage collection)

**Goal:** Phase 6: Log compaction (garbage collection)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 7: C ABI header for FFI

**Goal:** Phase 7: C ABI header for FFI

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

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
