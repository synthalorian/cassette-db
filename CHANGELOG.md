# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-10

### Added

- Phase 1: Tape format specification with magic header, versioned data blocks, and EOF markers. Self-contained CRC32 implementation for stable API across Zig versions.
- Phase 2: Low-level file I/O and append-only writer (`src/writer.zig`). Sequential block appending with checksums and atomic sync.
- Phase 3: Read engine (`src/reader.zig`) supporting seek, get, and range scan. Implements append-only shadow semantics where later writes overwrite earlier values for the same key.
- Phase 4: CLI tool (`src/main.zig`) with `put`, `get`, `scan`, `check`, `recover`, and `compact` commands. Default database file: `cassette.ctdb`.
- Phase 5: Crash recovery and consistency checks (`src/recovery.zig`). `verifyTape()` validates every block checksum; `recoverTape()` truncates to last valid block and rewrites EOF marker.
- Phase 6: Log compaction / garbage collection (`src/compaction.zig`). `compactTape()` rewrites the database keeping only the latest value per key, preserving first-appearance order. Atomic temp-file + rename for safety.
- Phase 7: C ABI for FFI bindings (`src/cassette_c.zig`, `include/cassette.h`). Exported functions: `cassette_open/close/last_error`, `cassette_put/get/free_value`, `cassette_scan` with callback, `cassette_check/recover/compact`. Produces `libcassette.a` static library.
- 77 unit tests covering all modules (40 main + 37 C ABI).

[1.0.0]: https://github.com/synthalorian/cassette-db/releases/tag/v1.0.0
