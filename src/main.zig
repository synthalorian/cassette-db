const std = @import("std");
const tape = @import("tape.zig");
const writer = @import("writer.zig");
const reader = @import("reader.zig");
const recovery = @import("recovery.zig");
const compaction = @import("compaction.zig");
const cassette_c = @import("cassette_c.zig");

const usage =
    \\Usage: cassette-db <command> [options] [args...]
    \\
    \\Commands:
    \\  put <key> <value>     Store a key-value pair
    \\  get <key>             Retrieve the value for a key
    \\  scan <start> <end>    List key-value pairs in range [start, end)
    \\  check                 Run consistency check on the database file
    \\  recover               Repair a damaged database file (truncate to last valid block)
    \\  compact               Rewrite the database keeping only the latest value per key
    \\
    \\Options:
    \\  -f, --file <path>     Database file (default: cassette.ctdb)
    \\  -h, --help            Show this help message
    \\
;

const CliOptions = struct {
    file: []const u8 = "cassette.ctdb",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
};

fn parseArgs(argv: []const []const u8, io: std.Io) !CliOptions {
    var opts: CliOptions = .{};
    var i: usize = 0;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= argv.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "error: --file requires an argument\n");
                return error.InvalidArgs;
            }
            opts.file = argv[i];
        } else if (opts.command.len == 0) {
            opts.command = arg;
        } else {
            // Collect remaining positional args.
            const start = i;
            const end = argv.len;
            opts.args = argv[start..end];
            break;
        }
    }

    return opts;
}

fn cmdPut(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: put requires <key> <value>\n");
        return error.InvalidArgs;
    }

    var w = try writer.TapeWriter.open(allocator, io, file_path);
    defer w.close() catch {};
    try w.append(args[0], args[1]);
    try w.close();
}

fn cmdGet(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    if (args.len != 1) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: get requires <key>\n");
        return error.InvalidArgs;
    }

    var r = try reader.TapeReader.open(allocator, io, file_path);
    defer r.close();

    const result = try r.get(args[0]);
    defer if (result) |b| b.deinit(allocator);

    if (result) |block| {
        var stdout_buf: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        defer stdout.interface.flush() catch {};
        try stdout.interface.writeAll(block.value);
        try stdout.interface.writeByte('\n');
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, "error: key not found\n");
        return error.KeyNotFound;
    }
}

fn cmdScan(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    if (args.len != 2) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: scan requires <start> <end>\n");
        return error.InvalidArgs;
    }

    var r = try reader.TapeReader.open(allocator, io, file_path);
    defer r.close();

    var results: std.ArrayList(tape.DataBlock) = .empty;
    defer {
        for (results.items) |*b| {
            b.deinit(allocator);
        }
        results.deinit(allocator);
    }

    try r.scanRange(args[0], args[1], &results);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    for (results.items) |block| {
        try stdout.interface.print("{s}\t{s}\n", .{ block.key, block.value });
    }
}

fn cmdCheck(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    _ = args;

    const report = try recovery.verifyTape(allocator, io, file_path);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("{}", .{report});

    if (!report.healthy) {
        std.process.exit(1);
    }
}

fn cmdRecover(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    _ = args;

    const report = try recovery.recoverTape(allocator, io, file_path);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("Recovery complete.\n{}", .{report});
}

fn cmdCompact(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    _ = args;

    const report = try compaction.compactTape(allocator, io, file_path);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("Compaction complete.{}", .{report});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Skip program name.
    if (argv.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return error.InvalidArgs;
    }

    const opts = parseArgs(argv[1..], io) catch {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(1);
    };

    if (opts.command.len == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: no command specified\n");
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return error.InvalidArgs;
    }

    if (std.mem.eql(u8, opts.command, "put")) {
        try cmdPut(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "get")) {
        try cmdGet(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "scan")) {
        try cmdScan(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "check")) {
        try cmdCheck(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "recover")) {
        try cmdRecover(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "compact")) {
        try cmdCompact(allocator, io, opts.file, opts.args);
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, "error: unknown command\n");
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return error.InvalidArgs;
    }
}

// -----------------------------------------------------------------
// CLI integration tests
// -----------------------------------------------------------------

test "CLI put and get roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_put_get.ctdb";

    // Clean up any leftover file.
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // put
    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("hello", "world");
        try w.close();
    }

    // get
    {
        var r = try reader.TapeReader.open(allocator, io, path);
        defer r.close();
        const result = try r.get("hello");
        defer if (result) |b| b.deinit(allocator);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("world", result.?.value);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI get returns latest value" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_get_latest.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("key", "old");
        try w.close();
    }

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("key", "new");
        try w.close();
    }

    {
        var r = try reader.TapeReader.open(allocator, io, path);
        defer r.close();
        const result = try r.get("key");
        defer if (result) |b| b.deinit(allocator);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("new", result.?.value);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI scan range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_scan.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("aaa", "1");
        try w.append("bbb", "2");
        try w.append("ccc", "3");
        try w.close();
    }

    {
        var r = try reader.TapeReader.open(allocator, io, path);
        defer r.close();

        var results: std.ArrayList(tape.DataBlock) = .empty;
        defer {
            for (results.items) |*b| {
                b.deinit(allocator);
            }
            results.deinit(allocator);
        }

        try r.scanRange("bbb", "ddd", &results);
        try std.testing.expectEqual(@as(usize, 2), results.items.len);

        var found_bbb = false;
        var found_ccc = false;
        for (results.items) |block| {
            if (std.mem.eql(u8, block.key, "bbb")) {
                try std.testing.expectEqualStrings("2", block.value);
                found_bbb = true;
            } else if (std.mem.eql(u8, block.key, "ccc")) {
                try std.testing.expectEqualStrings("3", block.value);
                found_ccc = true;
            }
        }
        try std.testing.expect(found_bbb);
        try std.testing.expect(found_ccc);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI get missing key returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_missing.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("exists", "yes");
        try w.close();
    }

    {
        var r = try reader.TapeReader.open(allocator, io, path);
        defer r.close();
        const result = try r.get("missing");
        try std.testing.expect(result == null);
    }

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI check reports healthy tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_check.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("k", "v");
        try w.close();
    }

    const report = try recovery.verifyTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI compact removes stale key versions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_compact.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("key", "old");
        try w.append("other", "x");
        try w.append("key", "new");
        try w.close();
    }

    const report = try compaction.compactTape(allocator, io, path);
    try std.testing.expectEqual(@as(usize, 3), report.blocks_before);
    try std.testing.expectEqual(@as(usize, 2), report.blocks_after);
    try std.testing.expect(report.bytes_after < report.bytes_before);

    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();

    const result = try r.get("key");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("new", result.?.value);

    const other = try r.get("other");
    defer if (other) |b| b.deinit(allocator);
    try std.testing.expect(other != null);
    try std.testing.expectEqualStrings("x", other.?.value);

    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "CLI recover repairs damaged tape" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = "test_cli_recover.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    {
        var w = try writer.TapeWriter.open(allocator, io, path);
        try w.append("keep", "this");
        try w.append("lose", "that");
        try w.close();
    }

    // Corrupt the second block.
    {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        const end = try f.length(io);
        try f.setLength(io, end - 1); // strip EOF

        const first_block = tape.DataBlock{ .key = "keep", .value = "this" };
        const second_offset = tape.header_size + first_block.encodedSize();

        var buf: [64]u8 = undefined;
        const n = try f.readPositional(io, &.{&buf}, second_offset);
        buf[n - 1] ^= 0xFF;
        try f.writePositionalAll(io, buf[0..n], second_offset);
    }

    const report = try recovery.recoverTape(allocator, io, path);
    try std.testing.expect(report.healthy);
    try std.testing.expectEqual(@as(usize, 1), report.valid_blocks);

    // Verify only first block remains.
    var r = try reader.TapeReader.open(allocator, io, path);
    defer r.close();

    const result = try r.get("keep");
    defer if (result) |b| b.deinit(allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("this", result.?.value);

    const missing = try r.get("lose");
    try std.testing.expect(missing == null);

    try std.Io.Dir.cwd().deleteFile(io, path);
}
