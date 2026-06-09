const std = @import("std");
const tape = @import("tape.zig");

/// Append-only tape file writer.
///
/// Opens (or creates) a tape file, verifies/appends the CTDB header,
/// and provides `append` to write key-value blocks.  `close` writes the
/// EOF marker and syncs the file.
pub const TapeWriter = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    write_offset: u64,
    closed: bool = false,

    /// Open an existing tape for appending, or create a new one.
    /// When creating, the CTDB header is written immediately.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !TapeWriter {
        const dir = std.Io.Dir.cwd();
        const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => {
                const f = try dir.createFile(io, path, .{ .read = true, .truncate = false });
                errdefer f.close(io);

                var hdr: [tape.header_size]u8 = undefined;
                tape.Header.init().encode(&hdr);
                try f.writePositionalAll(io, &hdr, 0);
                try f.sync(io);

                return .{
                    .io = io,
                    .file = f,
                    .allocator = allocator,
                    .write_offset = tape.header_size,
                };
            },
            else => |e| return e,
        };
        errdefer file.close(io);

        // Verify header on existing file.
        var hdr: [tape.header_size]u8 = undefined;
        const n = try file.readPositional(io, &.{&hdr}, 0);
        if (n < tape.header_size) return error.NotATapeFile;

        const header = tape.Header.decode(&hdr);
        if (!header.isValid()) return error.NotATapeFile;

        // Get file length for append.
        const end = try file.length(io);

        // If the file ends with an EOF marker, overwrite it so we can append.
        var write_offset = end;
        if (end >= 1) {
            var last_byte: [1]u8 = undefined;
            const rn = try file.readPositional(io, &.{&last_byte}, end - 1);
            if (rn == 1 and last_byte[0] == @intFromEnum(tape.BlockType.eof)) {
                // Truncate the EOF marker — we'll rewrite it on close.
                try file.setLength(io, end - 1);
                write_offset = end - 1;
            }
        }

        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .write_offset = write_offset,
        };
    }

    /// Append a key-value block to the tape.
    pub fn append(self: *TapeWriter, key: []const u8, value: []const u8) !void {
        std.debug.assert(!self.closed);

        const block = tape.DataBlock{ .key = key, .value = value };
        const size = block.encodedSize();
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);

        try block.encode(buf);
        try self.file.writePositionalAll(self.io, buf, self.write_offset);
        self.write_offset += size;
    }

    /// Sync the file to disk (durability).
    pub fn sync(self: *TapeWriter) !void {
        std.debug.assert(!self.closed);
        try self.file.sync(self.io);
    }

    /// Write EOF marker, sync, and close the file.
    pub fn close(self: *TapeWriter) !void {
        if (self.closed) return;
        self.closed = true;

        var eof: [tape.EofMarker.encoded_size]u8 = undefined;
        tape.EofMarker.encode(&eof);
        try self.file.writePositionalAll(self.io, &eof, self.write_offset);
        try self.file.sync(self.io);
        self.file.close(self.io);
    }
};

// -----------------------------------------------------------------
// Tests
// -----------------------------------------------------------------

test "TapeWriter creates new file with header" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_tape_create.ctdb";
    {
        var writer = try TapeWriter.open(allocator, io, path);
        defer writer.close() catch {};
    }

    // Verify file exists and has valid header.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hdr: [tape.header_size]u8 = undefined;
    const n = try file.readStreaming(io, &.{&hdr});
    try std.testing.expectEqual(tape.header_size, n);

    const header = tape.Header.decode(&hdr);
    try std.testing.expect(header.isValid());

    // Cleanup
    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeWriter appends blocks and closes with EOF" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_tape_append.ctdb";
    {
        var writer = try TapeWriter.open(allocator, io, path);
        try writer.append("key1", "value1");
        try writer.append("key2", "value2");
        try writer.close();
    }

    // Read back and verify.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hdr: [tape.header_size]u8 = undefined;
    _ = try file.readStreaming(io, &.{&hdr});
    const header = tape.Header.decode(&hdr);
    try std.testing.expect(header.isValid());

    // First block
    var buf1: [256]u8 = undefined;
    const n1 = try file.readStreaming(io, &.{&buf1});
    const block1 = try tape.DataBlock.decode(allocator, buf1[0..n1]);
    defer block1.deinit(allocator);
    try std.testing.expectEqualStrings("key1", block1.key);
    try std.testing.expectEqualStrings("value1", block1.value);

    // Second block
    const offset2 = tape.header_size + block1.encodedSize();
    var buf2: [256]u8 = undefined;
    const n2 = try file.readPositional(io, &.{&buf2}, offset2);
    const block2 = try tape.DataBlock.decode(allocator, buf2[0..n2]);
    defer block2.deinit(allocator);
    try std.testing.expectEqualStrings("key2", block2.key);
    try std.testing.expectEqualStrings("value2", block2.value);

    // EOF marker
    const eof_offset = offset2 + block2.encodedSize();
    var eof_byte: [1]u8 = undefined;
    const rn = try file.readPositional(io, &.{&eof_byte}, eof_offset);
    try std.testing.expectEqual(@as(usize, 1), rn);
    try std.testing.expectEqual(@intFromEnum(tape.BlockType.eof), eof_byte[0]);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeWriter reopens and appends to existing tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_tape_reopen.ctdb";

    // First session: write one block and close.
    {
        var writer = try TapeWriter.open(allocator, io, path);
        try writer.append("first", "data");
        try writer.close();
    }

    // Second session: reopen and append.
    {
        var writer = try TapeWriter.open(allocator, io, path);
        try writer.append("second", "more");
        try writer.close();
    }

    // Read back both blocks.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hdr: [tape.header_size]u8 = undefined;
    _ = try file.readStreaming(io, &.{&hdr});

    var buf: [512]u8 = undefined;
    const n = try file.readStreaming(io, &.{&buf});
    const data = buf[0..n];

    // First block
    const block1 = try tape.DataBlock.decode(allocator, data);
    defer block1.deinit(allocator);
    try std.testing.expectEqualStrings("first", block1.key);
    try std.testing.expectEqualStrings("data", block1.value);

    // Second block
    const offset2 = block1.encodedSize();
    const block2 = try tape.DataBlock.decode(allocator, data[offset2..]);
    defer block2.deinit(allocator);
    try std.testing.expectEqualStrings("second", block2.key);
    try std.testing.expectEqualStrings("more", block2.value);

    // EOF after second block
    const eof_offset = offset2 + block2.encodedSize();
    try std.testing.expectEqual(@intFromEnum(tape.BlockType.eof), data[eof_offset]);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeWriter rejects non-tape file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "not_a_tape.txt";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "this is not a tape file");
    }

    const result = TapeWriter.open(allocator, io, path);
    try std.testing.expectError(error.NotATapeFile, result);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "TapeWriter sync does not error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const path = "test_tape_sync.ctdb";
    var writer = try TapeWriter.open(allocator, io, path);
    try writer.append("k", "v");
    try writer.sync();
    try writer.close();

    try std.Io.Dir.cwd().deleteFile(io, path);
}
