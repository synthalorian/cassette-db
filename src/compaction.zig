const std = @import("std");
const tape = @import("tape.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const recovery = @import("recovery.zig");

/// Detailed report from a log compaction run.
pub const CompactionReport = struct {
    /// Original file size in bytes.
    bytes_before: u64 = 0,
    /// New file size in bytes after compaction.
    bytes_after: u64 = 0,
    /// Total data blocks read from the original file.
    blocks_before: usize = 0,
    /// Data blocks written to the compacted file.
    blocks_after: usize = 0,
    /// Number of unique keys preserved.
    keys_kept: usize = 0,

    pub fn format(
        self: CompactionReport,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const saved: i128 = @as(i128, self.bytes_before) - @as(i128, self.bytes_after);
        const saved_percent = if (self.bytes_before > 0)
            @as(f64, @floatFromInt(saved)) / @as(f64, @floatFromInt(self.bytes_before)) * 100.0
        else
            0.0;

        try out_writer.writeAll("\nCompaction report:\n");
        try out_writer.print("  Bytes before:      {d}\n", .{self.bytes_before});
        try out_writer.print("  Bytes after:       {d}\n", .{self.bytes_after});
        try out_writer.print("  Blocks before:     {d}\n", .{self.blocks_before});
        try out_writer.print("  Blocks after:      {d}\n", .{self.blocks_after});
        try out_writer.print("  Keys kept:         {d}\n", .{self.keys_kept});
        try out_writer.print("  Space saved:       {d} bytes ({d:.1}%)\n", .{ saved, saved_percent });
        try out_writer.writeAll("\n");
    }
};

/// Compact a tape file by rewriting it with only the latest value for each key.
///
/// 1. Recovers the source file to ensure it ends cleanly at the last valid block.
/// 2. Scans the source and keeps only the most recent block per unique key,
///    preserving the original order of first appearance.
/// 3. Writes a new temporary tape file containing the surviving blocks.
/// 4. Atomically replaces the original file with the compacted version.
///
/// Returns `error.NotATapeFile` if the source header is missing or invalid.
pub fn compactTape(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !CompactionReport {
    // Ensure the source file is in a clean state before reading.
    _ = try recovery.recoverTape(allocator, io, path);

    const dir = std.Io.Dir.cwd();

    // Determine original file size.
    const src_file = try dir.openFile(io, path, .{});
    defer src_file.close(io);
    const bytes_before = try src_file.length(io);

    // Read the source and retain only the latest block per key.
    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();

    var blocks: std.ArrayList(tape.DataBlock) = .empty;
    defer {
        for (blocks.items) |*b| {
            b.deinit(allocator);
        }
        blocks.deinit(allocator);
    }

    var key_to_index = std.StringHashMap(usize).init(allocator);
    defer {
        var key_it = key_to_index.keyIterator();
        while (key_it.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        key_to_index.deinit();
    }

    var blocks_before: usize = 0;
    while (try r.readNext()) |block| {
        blocks_before += 1;

        if (key_to_index.get(block.key)) |existing_idx| {
            // Replace stale value with the newer one at the same slot.
            blocks.items[existing_idx].deinit(allocator);
            blocks.items[existing_idx] = block;
        } else {
            const new_idx = blocks.items.len;
            try blocks.append(allocator, block);
            const key_copy = try allocator.dupe(u8, block.key);
            try key_to_index.put(key_copy, new_idx);
        }
    }

    // Write the surviving blocks to a temporary file.
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.compact", .{path});
    defer allocator.free(temp_path);

    // Remove any stale temp file left behind by an earlier failed run.
    dir.deleteFile(io, temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, temp_path);
        errdefer w.close() catch {};

        for (blocks.items) |block| {
            try w.append(block.key, block.value);
        }

        try w.close();
    }

    // Measure compacted file size before replacing the original.
    const tmp_file = try dir.openFile(io, temp_path, .{});
    defer tmp_file.close(io);
    const bytes_after = try tmp_file.length(io);

    // Atomically replace the original tape with the compacted version.
    try dir.rename(temp_path, dir, path, io);

    return .{
        .bytes_before = bytes_before,
        .bytes_after = bytes_after,
        .blocks_before = blocks_before,
        .blocks_after = blocks.items.len,
        .keys_kept = blocks.items.len,
    };
}

// -----------------------------------------------------------------
// Tests
// -----------------------------------------------------------------

test "compactTape removes stale versions and keeps latest values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_compact_dedup.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("a", "1");
        try w.append("b", "old");
        try w.append("a", "2");
        try w.append("b", "new");
        try w.append("c", "only");
        try w.close();
    }

    const report = try compactTape(allocator, io, path);
    try std.testing.expectEqual(@as(usize, 5), report.blocks_before);
    try std.testing.expectEqual(@as(usize, 3), report.blocks_after);
    try std.testing.expectEqual(@as(usize, 3), report.keys_kept);
    try std.testing.expect(report.bytes_after < report.bytes_before);

    // Verify readable contents.
    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();

    const a = try r.get("a");
    defer if (a) |b| b.deinit(allocator);
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("2", a.?.value);

    const b = try r.get("b");
    defer if (b) |blk| blk.deinit(allocator);
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("new", b.?.value);

    const c = try r.get("c");
    defer if (c) |blk| blk.deinit(allocator);
    try std.testing.expect(c != null);
    try std.testing.expectEqualStrings("only", c.?.value);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "compactTape preserves order of first appearance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_compact_order.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("z", "last");
        try w.append("a", "first");
        try w.append("m", "middle");
        try w.append("a", "updated");
        try w.close();
    }

    _ = try compactTape(allocator, io, path);

    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();

    // Read blocks sequentially and verify order: z, a, m.
    const z = try r.readNext();
    defer if (z) |blk| blk.deinit(allocator);
    try std.testing.expect(z != null);
    try std.testing.expectEqualStrings("z", z.?.key);

    const a = try r.readNext();
    defer if (a) |blk| blk.deinit(allocator);
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("a", a.?.key);
    try std.testing.expectEqualStrings("updated", a.?.value);

    const m = try r.readNext();
    defer if (m) |blk| blk.deinit(allocator);
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("m", m.?.key);

    const eof = try r.readNext();
    try std.testing.expect(eof == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "compactTape handles empty tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_compact_empty.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.close();
    }

    const report = try compactTape(allocator, io, path);
    try std.testing.expectEqual(@as(usize, 0), report.blocks_before);
    try std.testing.expectEqual(@as(usize, 0), report.blocks_after);
    try std.testing.expectEqual(@as(usize, 0), report.keys_kept);

    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();
    const block = try r.readNext();
    try std.testing.expect(block == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "compactTape handles single block" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_compact_single.ctdb";

    {
        const writer_mod = @import("writer.zig");
        var w = try writer_mod.TapeWriter.open(allocator, io, path);
        try w.append("solo", "value");
        try w.close();
    }

    const report = try compactTape(allocator, io, path);
    try std.testing.expectEqual(@as(usize, 1), report.blocks_before);
    try std.testing.expectEqual(@as(usize, 1), report.blocks_after);

    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();
    const result = try r.get("solo");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value", result.?.value);

    try std.Io.Dir.cwd().deleteFile(io, path);
}
