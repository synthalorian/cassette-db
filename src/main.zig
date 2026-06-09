const std = @import("std");
const tape = @import("tape.zig");
const writer = @import("writer.zig");
const reader = @import("reader.zig");

const usage =
    \\Usage: cassette-db <command> [options] [args...]
    \\
    \\Commands:
    \\  put <key> <value>     Store a key-value pair
    \\  get <key>             Retrieve the value for a key
    \\  scan <start> <end>    List key-value pairs in range [start, end)
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

fn parseArgs(argv: []const []const u8) !CliOptions {
    var opts: CliOptions = .{};
    var i: usize = 0;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.io.getStdOut().writeAll(usage);
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= argv.len) {
                try std.io.getStdErr().writeAll("error: --file requires an argument\n");
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
        try std.io.getStdErr().writeAll("error: put requires <key> <value>\n");
        return error.InvalidArgs;
    }

    var w = try writer.TapeWriter.open(allocator, io, file_path);
    defer w.close() catch {};
    try w.append(args[0], args[1]);
    try w.close();
}

fn cmdGet(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    if (args.len != 1) {
        try std.io.getStdErr().writeAll("error: get requires <key>\n");
        return error.InvalidArgs;
    }

    var r = try reader.TapeReader.open(allocator, io, file_path);
    defer r.close();

    const result = try r.get(args[0]);
    defer if (result) |b| b.deinit(allocator);

    if (result) |block| {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(block.value);
        try stdout.writeByte('\n');
    } else {
        try std.io.getStdErr().writeAll("error: key not found\n");
        return error.KeyNotFound;
    }
}

fn cmdScan(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, args: []const []const u8) !void {
    if (args.len != 2) {
        try std.io.getStdErr().writeAll("error: scan requires <start> <end>\n");
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

    const stdout = std.io.getStdOut().writer();
    for (results.items) |block| {
        try stdout.print("{s}\t{s}\n", .{ block.key, block.value });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Skip program name.
    if (argv.len < 2) {
        try std.io.getStdErr().writeAll(usage);
        return error.InvalidArgs;
    }

    const opts = parseArgs(argv[1..]) catch {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    };

    if (opts.command.len == 0) {
        try std.io.getStdErr().writeAll("error: no command specified\n");
        try std.io.getStdErr().writeAll(usage);
        return error.InvalidArgs;
    }

    if (std.mem.eql(u8, opts.command, "put")) {
        try cmdPut(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "get")) {
        try cmdGet(allocator, io, opts.file, opts.args);
    } else if (std.mem.eql(u8, opts.command, "scan")) {
        try cmdScan(allocator, io, opts.file, opts.args);
    } else {
        try std.io.getStdErr().writeAll("error: unknown command\n");
        try std.io.getStdErr().writeAll(usage);
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
