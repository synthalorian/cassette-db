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
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

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
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

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
