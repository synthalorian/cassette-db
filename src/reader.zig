const std = @import("std");
const tape = @import("tape.zig");

/// Read-only tape file reader.
///
/// Opens a tape file, verifies the CTDB header, and provides random access
/// to data blocks: seek, get by key, and range scan.
pub const TapeReader = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    read_offset: u64,
    file_size: u64,

    /// Open an existing tape file for reading.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !TapeReader {
        const dir = std.Io.Dir.cwd();
        const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.NotATapeFile,
            else => |e| return e,
        };
        errdefer file.close(io);

        // Verify header.
        var hdr: [tape.header_size]u8 = undefined;
        const n = try file.readPositional(io, &.{&hdr}, 0);
        if (n < tape.header_size) return error.NotATapeFile;

        const header = tape.Header.decode(&hdr);
        if (!header.isValid()) return error.NotATapeFile;

        const file_size = try file.length(io);

        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .read_offset = tape.header_size,
            .file_size = file_size,
        };
    }

    /// Close the file.
    pub fn close(self: *TapeReader) void {
        self.file.close(self.io);
    }

    /// Seek to a specific byte offset within the file.
    /// Offset 0 = start of file (before header).
    /// Offset `tape.header_size` = first data block.
    pub fn seek(self: *TapeReader, offset: u64) !void {
        if (offset > self.file_size) return error.SeekOutOfBounds;
        self.read_offset = offset;
    }

    /// Read the next data block at the current offset.
    /// Returns `null` if at EOF or beyond file end.
    /// Advances `read_offset` past the returned block.
    pub fn readNext(self: *TapeReader) !?tape.DataBlock {
        if (self.read_offset >= self.file_size) return null;

        // Peek at block type.
        var type_byte: [1]u8 = undefined;
        const tn = try self.file.readPositional(self.io, &.{&type_byte}, self.read_offset);
        if (tn == 0) return null;

        if (type_byte[0] == @intFromEnum(tape.BlockType.eof)) {
            return null;
        }

        if (type_byte[0] != @intFromEnum(tape.BlockType.data)) {
            return error.InvalidBlock;
        }

        // Read key_len and val_len to know total block size.
        var len_buf: [6]u8 = undefined;
        const ln = try self.file.readPositional(self.io, &.{&len_buf}, self.read_offset + 1);
        if (ln < 6) return error.InvalidBlock;

        const key_len = std.mem.readInt(u16, len_buf[0..2], .big);
        const val_len = std.mem.readInt(u32, len_buf[2..6], .big);
        const block_size = 1 + 2 + 4 + key_len + val_len + 4;

        // Read full block.
        const block_buf = try self.allocator.alloc(u8, block_size);
        defer self.allocator.free(block_buf);

        const bn = try self.file.readPositional(self.io, &.{block_buf}, self.read_offset);
        if (bn < block_size) return error.InvalidBlock;

        const block = try tape.DataBlock.decode(self.allocator, block_buf[0..block_size]);
        self.read_offset += block_size;
        return block;
    }

    /// Find the most recent (last) block with the given key.
    /// Scans from beginning. Returns `null` if key not found.
    /// The caller owns the returned DataBlock and must call `deinit`.
    pub fn get(self: *TapeReader, key: []const u8) !?tape.DataBlock {
        const saved_offset = self.read_offset;
        defer self.read_offset = saved_offset;
        self.read_offset = tape.header_size;

        var result: ?tape.DataBlock = null;

        while (try self.readNext()) |block| {
            if (std.mem.eql(u8, block.key, key)) {
                if (result) |prev| {
                    prev.deinit(self.allocator);
                }
                result = block;
            } else {
                block.deinit(self.allocator);
            }
        }

        return result;
    }

    /// Scan all blocks whose keys fall within [start_key, end_key).
    /// Returns only the latest value for each unique key (append-only semantics).
    /// Results are appended to `out`. The caller owns all DataBlocks in `out`
    /// and must call `deinit` on each.
    pub fn scanRange(
        self: *TapeReader,
        start_key: []const u8,
        end_key: []const u8,
        out: *std.ArrayList(tape.DataBlock),
    ) !void {
        const saved_offset = self.read_offset;
        defer self.read_offset = saved_offset;
        self.read_offset = tape.header_size;

        // Use a hash map to track latest value for each key in range.
        // Key: allocated copy of the block key
        // Value: index into `out` ArrayList
        var key_to_index = std.StringHashMap(usize).init(self.allocator);
        defer {
            // Free all keys we allocated for the hash map.
            var key_it = key_to_index.keyIterator();
            while (key_it.next()) |key_ptr| {
                self.allocator.free(key_ptr.*);
            }
            key_to_index.deinit();
        }

        while (try self.readNext()) |block| {
            const in_range = std.mem.order(u8, block.key, start_key).compare(.gte) and
                std.mem.order(u8, block.key, end_key).compare(.lt);

            if (in_range) {
                // Check if we already have this key.
                if (key_to_index.get(block.key)) |existing_idx| {
                    // Replace: free old, store new at same index.
                    out.items[existing_idx].deinit(self.allocator);
                    out.items[existing_idx] = block;
                } else {
                    // New key: append to output and record index.
                    const new_idx = out.items.len;
                    try out.append(self.allocator, block);
                    // Allocate a copy of the key for the hash map.
                    const key_copy = try self.allocator.dupe(u8, block.key);
                    try key_to_index.put(key_copy, new_idx);
                }
            } else {
                block.deinit(self.allocator);
            }
        }
    }
};

// -----------------------------------------------------------------
// Tests
// -----------------------------------------------------------------

test "TapeReader opens valid tape and reads header" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_header.ctdb";

    // Create a tape with writer.
    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k", "v");
        try w.close();
    }

    // Open with reader.
    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    // Should be positioned after header.
    try std.testing.expectEqual(tape.header_size, reader.read_offset);

    // Cleanup
    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader rejects non-tape file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "not_a_tape.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "this is not a tape file");
    }

    const result = TapeReader.open(allocator, io, path);
    try std.testing.expectError(error.NotATapeFile, result);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader seek and readNext" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_seek.ctdb";

    // Create tape with two blocks.
    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("key1", "value1");
        try w.append("key2", "value2");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    // Read first block.
    const block1 = try reader.readNext();
    defer if (block1) |b| b.deinit(allocator);
    try std.testing.expect(block1 != null);
    try std.testing.expectEqualStrings("key1", block1.?.key);
    try std.testing.expectEqualStrings("value1", block1.?.value);

    // Read second block.
    const block2 = try reader.readNext();
    defer if (block2) |b| b.deinit(allocator);
    try std.testing.expect(block2 != null);
    try std.testing.expectEqualStrings("key2", block2.?.key);
    try std.testing.expectEqualStrings("value2", block2.?.value);

    // Should hit EOF.
    const block3 = try reader.readNext();
    try std.testing.expect(block3 == null);

    // Seek back to first block.
    try reader.seek(tape.header_size);
    const block1_again = try reader.readNext();
    defer if (block1_again) |b| b.deinit(allocator);
    try std.testing.expect(block1_again != null);
    try std.testing.expectEqualStrings("key1", block1_again.?.key);

    // Seek out of bounds should error.
    const file_len = reader.file_size;
    const seek_result = reader.seek(file_len + 1);
    try std.testing.expectError(error.SeekOutOfBounds, seek_result);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader get finds key" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_get.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("alpha", "first");
        try w.append("beta", "second");
        try w.append("gamma", "third");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    const result = try reader.get("beta");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("beta", result.?.key);
    try std.testing.expectEqualStrings("second", result.?.value);

    // Non-existent key.
    const missing = try reader.get("delta");
    try std.testing.expect(missing == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader get returns last occurrence (append-only semantics)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_get_last.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("key", "old_value");
        try w.append("other", "x");
        try w.append("key", "new_value");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    const result = try reader.get("key");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("key", result.?.key);
    try std.testing.expectEqualStrings("new_value", result.?.value);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader scanRange returns blocks in range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_scan.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("aaa", "1");
        try w.append("bbb", "2");
        try w.append("ccc", "3");
        try w.append("ddd", "4");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    var results: std.ArrayList(tape.DataBlock) = .empty;
    defer {
        for (results.items) |*block| {
            block.deinit(allocator);
        }
        results.deinit(allocator);
    }

    try reader.scanRange("bbb", "ddd", &results);

    // Should get "bbb" and "ccc" (range is [bbb, ddd)).
    try std.testing.expectEqual(@as(usize, 2), results.items.len);

    // Keys should be in range.
    for (results.items) |block| {
        const ge_bbb = std.mem.order(u8, block.key, "bbb").compare(.gte);
        const lt_ddd = std.mem.order(u8, block.key, "ddd").compare(.lt);
        try std.testing.expect(ge_bbb);
        try std.testing.expect(lt_ddd);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader scanRange returns latest values only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_scan_dedup.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("aaa", "1");
        try w.append("bbb", "old");
        try w.append("ccc", "3");
        try w.append("bbb", "new");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    var results: std.ArrayList(tape.DataBlock) = .empty;
    defer {
        for (results.items) |*block| {
            block.deinit(allocator);
        }
        results.deinit(allocator);
    }

    try reader.scanRange("aaa", "zzz", &results);

    // Should have 3 unique keys.
    try std.testing.expectEqual(@as(usize, 3), results.items.len);

    // Find "bbb" and verify it's the latest value.
    var found_bbb = false;
    for (results.items) |block| {
        if (std.mem.eql(u8, block.key, "bbb")) {
            try std.testing.expectEqualStrings("new", block.value);
            found_bbb = true;
        }
    }
    try std.testing.expect(found_bbb);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader get preserves read position" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_pos.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("a", "1");
        try w.append("b", "2");
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    // Position at start.
    try reader.seek(tape.header_size);

    // Read first block.
    const block1 = try reader.readNext();
    defer if (block1) |b| b.deinit(allocator);

    // Call get - should not affect position.
    const result = try reader.get("b");
    defer if (result) |b| b.deinit(allocator);

    // readNext should continue from where we left off.
    const block2 = try reader.readNext();
    defer if (block2) |b| b.deinit(allocator);
    try std.testing.expect(block2 != null);
    try std.testing.expectEqualStrings("b", block2.?.key);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeReader readNext returns null on empty tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_reader_empty.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.close();
    }

    var reader = try TapeReader.open(allocator, io, path);
    defer reader.close();

    const block = try reader.readNext();
    try std.testing.expect(block == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}
