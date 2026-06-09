const std = @import("std");
const tape = @import("tape.zig");

/// Detailed report from a consistency scan of a tape file.
pub const ConsistencyReport = struct {
    /// Number of completely valid data blocks.
    valid_blocks: usize = 0,
    /// Number of blocks with checksum mismatch.
    corrupt_blocks: usize = 0,
    /// Number of incomplete blocks (file ends mid-block).
    truncated_blocks: usize = 0,
    /// Number of unexpected / unrecognised bytes between blocks.
    unexpected_bytes: usize = 0,
    /// Total file size in bytes.
    file_size: u64 = 0,
    /// Byte offset immediately after the last valid block.
    /// For a healthy file this equals file_size - 1 (the EOF marker).
    last_valid_offset: u64 = tape.header_size,
    /// True when the file ends with a valid EOF marker and contains
    /// no corruption or truncation.
    healthy: bool = false,

    pub fn format(
        self: ConsistencyReport,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("\nTape consistency report:\n");
        try writer.print("  File size:         {d} bytes\n", .{self.file_size});
        try writer.print("  Valid blocks:      {d}\n", .{self.valid_blocks});
        try writer.print("  Corrupt blocks:    {d}\n", .{self.corrupt_blocks});
        try writer.print("  Truncated blocks:  {d}\n", .{self.truncated_blocks});
        try writer.print("  Unexpected bytes:  {d}\n", .{self.unexpected_bytes});
        try writer.print("  Last valid offset: {d}\n", .{self.last_valid_offset});
        try writer.writeAll("\nHealth: ");
        if (self.healthy) {
            try writer.writeAll("HEALTHY\n\n");
        } else {
            try writer.writeAll("DAMAGED\n\n");
        }
    }
};

/// Scan a tape file from beginning to end and produce a consistency report.
/// Does not modify the file.
///
/// Returns `error.NotATapeFile` if the header is missing or invalid.
/// Returns other I/O errors on underlying read failures.
pub fn verifyTape(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ConsistencyReport {
    const dir = std.Io.Dir.cwd();
    const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotATapeFile,
        else => |e| return e,
    };
    defer file.close(io);

    const file_size = try file.length(io);

    // Verify header.
    if (file_size < tape.header_size) {
        return ConsistencyReport{
            .file_size = file_size,
            .healthy = false,
        };
    }

    var hdr: [tape.header_size]u8 = undefined;
    const hn = try file.readPositional(io, &.{&hdr}, 0);
    if (hn < tape.header_size) {
        return ConsistencyReport{
            .file_size = file_size,
            .healthy = false,
        };
    }

    const header = tape.Header.decode(&hdr);
    if (!header.isValid()) return error.NotATapeFile;

    var report = ConsistencyReport{
        .file_size = file_size,
        .last_valid_offset = tape.header_size,
    };

    var offset: u64 = tape.header_size;

    while (offset < file_size) {
        // Peek at block type.
        var type_byte: [1]u8 = undefined;
        const tn = try file.readPositional(io, &.{&type_byte}, offset);
        if (tn == 0) break;

        if (type_byte[0] == @intFromEnum(tape.BlockType.eof)) {
            // Valid EOF — only healthy if no prior damage and it's the very last byte.
            if (report.corrupt_blocks == 0 and
                report.truncated_blocks == 0 and
                report.unexpected_bytes == 0 and
                offset + 1 == file_size)
            {
                report.healthy = true;
            }
            report.last_valid_offset = offset + 1;
            break;
        }

        if (type_byte[0] != @intFromEnum(tape.BlockType.data)) {
            // Unexpected byte — skip it and keep scanning.
            report.unexpected_bytes += 1;
            offset += 1;
            continue;
        }

        // Need at least 6 more bytes for key_len + val_len.
        if (offset + 1 + 6 > file_size) {
            report.truncated_blocks += 1;
            break;
        }

        var len_buf: [6]u8 = undefined;
        const ln = try file.readPositional(io, &.{&len_buf}, offset + 1);
        if (ln < 6) {
            report.truncated_blocks += 1;
            break;
        }

        const key_len = std.mem.readInt(u16, len_buf[0..2], .big);
        const val_len = std.mem.readInt(u32, len_buf[2..6], .big);
        const block_size = 1 + 2 + 4 + key_len + val_len + 4;

        if (offset + block_size > file_size) {
            report.truncated_blocks += 1;
            break;
        }

        // Read full block and validate checksum.
        const block_buf = try allocator.alloc(u8, block_size);
        defer allocator.free(block_buf);

        const bn = try file.readPositional(io, &.{block_buf}, offset);
        if (bn < block_size) {
            report.truncated_blocks += 1;
            break;
        }

        // Decode validates the CRC32.
        const decoded = tape.DataBlock.decode(allocator, block_buf[0..block_size]) catch |err| switch (err) {
            error.Corrupt => {
                report.corrupt_blocks += 1;
                offset += block_size;
                continue;
            },
            error.InvalidBlock => {
                // Shouldn't happen after our size checks, but treat as corruption.
                report.corrupt_blocks += 1;
                offset += block_size;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer decoded.deinit(allocator);

        report.valid_blocks += 1;
        report.last_valid_offset = offset + block_size;
        offset += block_size;
    }

    return report;
}

/// Recover a potentially-damaged tape file.
///
/// 1. Scans the file with `verifyTape`.
/// 2. Truncates to `last_valid_offset` (removes partial / corrupt tail).
/// 3. Rewrites the EOF marker.
/// 4. Syncs to disk.
///
/// After recovery the file is guaranteed to end with a valid EOF marker
/// and contain only well-formed, checksum-validated blocks.
///
/// Returns `error.NotATapeFile` if the header is missing or invalid.
pub fn recoverTape(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ConsistencyReport {
    // First verify to understand the damage.
    var report = try verifyTape(allocator, io, path);

    if (report.healthy) {
        // Nothing to do.
        return report;
    }

    // Open for repair.
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);

    // Truncate to last_valid_offset.
    try file.setLength(io, report.last_valid_offset);

    // Write EOF marker.
    var eof: [tape.EofMarker.encoded_size]u8 = undefined;
    tape.EofMarker.encode(&eof);
    try file.writePositionalAll(io, &eof, report.last_valid_offset);
    try file.sync(io);

    // Update report to reflect recovery.
    report.file_size = report.last_valid_offset + 1;
    report.healthy = true;
    report.truncated_blocks = 0;
    report.corrupt_blocks = 0;
    report.unexpected_bytes = 0;

    return report;
}

// -----------------------------------------------------------------
// Tests
// -----------------------------------------------------------------

test "verifyTape reports healthy for valid tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_healthy.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k1", "v1");
        try w.append("k2", "v2");
        try w.close();
    }

    const report = try verifyTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 2), report.valid_blocks);
    try std.testing.expectEqual(@as(usize, 0), report.corrupt_blocks);
    try std.testing.expectEqual(@as(usize, 0), report.truncated_blocks);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "verifyTape detects truncated final block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_truncated.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k1", "v1");
        try w.close();
    }

    // Re-open and append garbage to simulate a partial write.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        // Strip EOF, append 3 bytes of incomplete block.
        try f.setLength(io, end - 1);
        const garbage = [_]u8{ 0x01, 0x00, 0x02 }; // data block type, key_len=2, incomplete
        try f.writePositionalAll(io, &garbage, end - 1);
    }

    const report = try verifyTape(allocator, io, path);
    try std.testing.expect(!report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);
    try std.testing.expectEqual(@as(usize, 1), report.truncated_blocks);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "verifyTape detects corrupt checksum" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_corrupt.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k1", "v1");
        try w.close();
    }

    // Corrupt the checksum of the single block.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        // Strip EOF.
        try f.setLength(io, end - 1);

        // Read the block, corrupt last byte (part of checksum), write back.
        const block_offset = tape.header_size;
        var buf: [64]u8 = undefined;
        const n = try f.readPositional(io, &.{&buf}, block_offset);
        buf[n - 1] ^= 0xFF;
        try f.writePositionalAll(io, buf[0..n], block_offset);
    }

    const report = try verifyTape(allocator, io, path);
    try std.testing.expect(!report.healthy);
    try std.testing.expectEqual(@as(usize, 0), report.valid_blocks);
    try std.testing.expectEqual(@as(usize, 1), report.corrupt_blocks);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "recoverTape repairs truncated file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_recover_truncated.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k1", "v1");
        try w.append("k2", "v2");
        try w.close();
    }

    // Truncate mid-second-block.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        // Strip EOF, then truncate into the second block.
        try f.setLength(io, end - 5);
    }

    const report = try recoverTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);
    try std.testing.expectEqual(@as(usize, 0), report.truncated_blocks);

    // Verify readable.
    const reader_mod = @import("reader.zig");
    var r = try reader_mod.TapeReader.open(allocator, io, path);
    defer r.close();

    const result = try r.get("k1");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v1", result.?.value);

    // k2 should be gone.
    const missing = try r.get("k2");
    try std.testing.expect(missing == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "recoverTape repairs corrupt block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_recover_corrupt.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("good", "data");
        try w.append("bad", "data");
        try w.close();
    }

    // Corrupt the second block.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        try f.setLength(io, end - 1); // strip EOF

        const first_block = tape.DataBlock{ .key = "good", .value = "data" };
        const second_offset = tape.header_size + first_block.encodedSize();

        var buf: [64]u8 = undefined;
        const n = try f.readPositional(io, &.{&buf}, second_offset);
        buf[n - 1] ^= 0xFF; // corrupt checksum
        try f.writePositionalAll(io, buf[0..n], second_offset);
    }

    const report = try recoverTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);

    // Verify only first block remains.
    const reader_mod = @import("reader.zig");
    var r = try reader_mod.TapeReader.open(allocator, io, path);
    defer r.close();

    const result = try r.get("good");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);

    const missing = try r.get("bad");
    try std.testing.expect(missing == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "recoverTape is no-op on healthy file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_recover_noop.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k", "v");
        try w.close();
    }

    const report = try recoverTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);

    // File should still be readable.
    const reader_mod = @import("reader.zig");
    var r = try reader_mod.TapeReader.open(allocator, io, path);
    defer r.close();

    const result = try r.get("k");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v", result.?.value);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "verifyTape handles missing EOF" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_no_eof.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k", "v");
        // Forget to close — no EOF.
    }

    const report = try verifyTape(allocator, io, path);
    try std.testing.expect(!report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "verifyTape detects unexpected bytes between blocks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_junk.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("k1", "v1");
        try w.close();
    }

    // Inject 2 garbage bytes between block and EOF.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        try f.setLength(io, end - 1); // strip EOF

        const block = tape.DataBlock{ .key = "k1", .value = "v1" };
        const junk_offset = tape.header_size + block.encodedSize();
        const junk = [_]u8{ 0xAB, 0xCD };
        try f.writePositionalAll(io, &junk, junk_offset);
    }

    const report = try verifyTape(allocator, io, path);
    try std.testing.expect(!report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);
    try std.testing.expectEqual(@as(usize, 2), report.unexpected_bytes);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "verifyTape rejects non-tape file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_verify_nontape.txt";

    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not a tape");
    }

    const result = verifyTape(allocator, io, path);
    try std.testing.expectError(error.NotATapeFile, result);

    try std.Io.Dir.cwd().deleteFile(io, path);
}
