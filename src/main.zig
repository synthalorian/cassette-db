const std = @import("std");
const tape = @import("tape.zig");
const writer = @import("writer.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    // Phase 2 smoke test: write a tape file, reopen, and read back.
    const path = "smoke.ctdb";

    // Ensure clean state.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("hello", "world");
        try w.append("foo", "bar");
        try w.close();
    }

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("baz", "qux");
        try w.close();
    }

    // Verify by reading the file directly.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hdr: [tape.header_size]u8 = undefined;
    _ = try file.readPositional(io, &.{&hdr}, 0);
    if (!tape.Header.decode(&hdr).isValid()) {
        return error.SmokeTestFailed;
    }

    // Read all remaining bytes.
    const file_len = try file.length(io);
    const data_len = file_len - tape.header_size;
    const data_buf = try allocator.alloc(u8, data_len);
    defer allocator.free(data_buf);
    _ = try file.readPositional(io, &.{data_buf}, tape.header_size);
    const data = data_buf;

    const block1 = try tape.DataBlock.decode(allocator, data);
    defer block1.deinit(allocator);
    if (!std.mem.eql(u8, "hello", block1.key) or !std.mem.eql(u8, "world", block1.value)) {
        return error.SmokeTestFailed;
    }

    const off2 = block1.encodedSize();
    const block2 = try tape.DataBlock.decode(allocator, data[off2..]);
    defer block2.deinit(allocator);
    if (!std.mem.eql(u8, "foo", block2.key) or !std.mem.eql(u8, "bar", block2.value)) {
        return error.SmokeTestFailed;
    }

    const off3 = off2 + block2.encodedSize();
    const block3 = try tape.DataBlock.decode(allocator, data[off3..]);
    defer block3.deinit(allocator);
    if (!std.mem.eql(u8, "baz", block3.key) or !std.mem.eql(u8, "qux", block3.value)) {
        return error.SmokeTestFailed;
    }

    const eof_off = off3 + block3.encodedSize();
    if (data[eof_off] != @intFromEnum(tape.BlockType.eof)) {
        return error.SmokeTestFailed;
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}
