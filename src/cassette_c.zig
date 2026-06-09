const std = @import("std");
const tape = @import("tape.zig");
const writer = @import("writer.zig");
const reader = @import("reader.zig");
const recovery = @import("recovery.zig");
const compaction = @import("compaction.zig");

/// Allocator used for all C ABI heap operations.
/// `c_allocator` is chosen so that C callers may also free small allocations
/// with the standard C `free` if they prefer. The exported `cassette_free`
/// functions use the same allocator for symmetry.
const allocator = std.heap.c_allocator;

fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// -----------------------------------------------------------------
// Error handling
// -----------------------------------------------------------------

const max_error_len = 256;

threadlocal var last_error_buffer: [max_error_len]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn recordError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_error_buffer, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => {
            @memcpy(last_error_buffer[0..3], "...");
            last_error_len = 3;
            return;
        },
    };
    last_error_len = written.len;
}

fn recordErrorFromErrSet(err: anyerror) void {
    recordError("{s}", .{@errorName(err)});
}

// -----------------------------------------------------------------
// Handle type
// -----------------------------------------------------------------

pub const CassetteDB = struct {
    path: [:0]const u8,
};

/// Open an existing cassette database or create a new one at `path`.
/// Returns a handle that must be closed with `cassette_close`.
export fn cassette_open(path: [*:0]const u8) ?*CassetteDB {
    const io = getIo();
    const path_slice = std.mem.span(path);

    // Ensure the file can be opened/created by touching it with TapeWriter.
    {
        var w = writer.TapeWriter.open(allocator, io, path_slice) catch |err| {
            recordErrorFromErrSet(err);
            return null;
        };
        w.close() catch |err| {
            recordErrorFromErrSet(err);
            return null;
        };
    }

    const path_copy = allocator.dupeZ(u8, path_slice) catch |err| {
        recordErrorFromErrSet(err);
        return null;
    };

    const db = allocator.create(CassetteDB) catch |err| {
        allocator.free(path_copy);
        recordErrorFromErrSet(err);
        return null;
    };

    db.* = .{ .path = path_copy };
    return db;
}

/// Close a database handle previously returned by `cassette_open`.
export fn cassette_close(db: ?*CassetteDB) void {
    const handle = db orelse return;
    allocator.free(handle.path);
    allocator.destroy(handle);
}

/// Return the last error message produced by a C ABI call on this thread.
/// The returned pointer remains valid until the next C ABI call on the same
/// thread. Do not free it.
export fn cassette_last_error() [*:0]const u8 {
    if (last_error_len == 0) {
        return "no error";
    }
    last_error_buffer[last_error_len] = 0;
    return @ptrCast(&last_error_buffer[0]);
}

// -----------------------------------------------------------------
// Write
// -----------------------------------------------------------------

/// Store a key-value pair in the database.
/// Returns 0 on success, non-zero on error.
export fn cassette_put(
    db: *CassetteDB,
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) c_int {
    const io = getIo();
    const key = key_ptr[0..key_len];
    const value = value_ptr[0..value_len];

    var w = writer.TapeWriter.open(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };
    defer w.close() catch {};

    w.append(key, value) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    w.close() catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    return 0;
}

// -----------------------------------------------------------------
// Read
// -----------------------------------------------------------------

/// Look up `key` in the database.
/// On success, 0 is returned and `value_out` points to a newly allocated
/// null-terminated buffer of length `value_len_out` (not including the
/// terminator). The caller must release the buffer with `cassette_free_value`.
/// If the key is not found, 1 is returned.
export fn cassette_get(
    db: *CassetteDB,
    key_ptr: [*]const u8,
    key_len: usize,
    value_out: *?[*:0]u8,
    value_len_out: *usize,
) c_int {
    const io = getIo();
    const key = key_ptr[0..key_len];

    var r = reader.TapeReader.open(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };
    defer r.close();

    const result = r.get(key) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    if (result) |block| {
        defer block.deinit(allocator);
        const value_copy = allocator.dupeZ(u8, block.value) catch |err| {
            recordErrorFromErrSet(err);
            return 1;
        };
        value_out.* = value_copy;
        value_len_out.* = block.value.len;
        return 0;
    } else {
        recordError("key not found", .{});
        return 1;
    }
}

/// Free a value buffer previously returned by `cassette_get`.
export fn cassette_free_value(value: ?[*:0]u8) void {
    const ptr = value orelse return;
    const len = std.mem.len(ptr);
    allocator.free(ptr[0..len]);
}

// -----------------------------------------------------------------
// Scan
// -----------------------------------------------------------------

pub const CassetteScanCallback = ?*const fn (
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
    user_data: ?*anyopaque,
) callconv(.c) void;

/// Scan key range `[start_key, end_key)` and invoke `callback` for each
/// latest unique key in the range. Returns 0 on success, non-zero on error.
export fn cassette_scan(
    db: *CassetteDB,
    start_ptr: [*]const u8,
    start_len: usize,
    end_ptr: [*]const u8,
    end_len: usize,
    callback: CassetteScanCallback,
    user_data: ?*anyopaque,
) c_int {
    const io = getIo();
    const start = start_ptr[0..start_len];
    const end = end_ptr[0..end_len];

    var r = reader.TapeReader.open(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };
    defer r.close();

    var results: std.ArrayList(tape.DataBlock) = .empty;
    defer {
        for (results.items) |*b| {
            b.deinit(allocator);
        }
        results.deinit(allocator);
    }

    r.scanRange(start, end, &results) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    if (callback) |cb| {
        for (results.items) |block| {
            cb(block.key.ptr, block.key.len, block.value.ptr, block.value.len, user_data);
        }
    }

    return 0;
}

// -----------------------------------------------------------------
// Maintenance
// -----------------------------------------------------------------

/// Run a consistency check on the database. Returns 0 if healthy, 1 if
/// damaged, and a negative value on error.
export fn cassette_check(db: *CassetteDB) c_int {
    const io = getIo();

    const report = recovery.verifyTape(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return -1;
    };

    if (!report.healthy) {
        recordError("tape consistency check failed", .{});
        return 1;
    }

    return 0;
}

/// Recover a damaged database file in place. Returns 0 on success,
/// non-zero on error.
export fn cassette_recover(db: *CassetteDB) c_int {
    const io = getIo();

    _ = recovery.recoverTape(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    return 0;
}

/// Compact the database, removing stale key versions. Returns 0 on success,
/// non-zero on error.
export fn cassette_compact(db: *CassetteDB) c_int {
    const io = getIo();

    _ = compaction.compactTape(allocator, io, db.path) catch |err| {
        recordErrorFromErrSet(err);
        return 1;
    };

    return 0;
}

// -----------------------------------------------------------------
// Tests
// -----------------------------------------------------------------

test "C ABI put and get roundtrip" {
    const io = std.testing.io;
    const path = "test_c_abi_put_get.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const db = cassette_open(path);
    try std.testing.expect(db != null);
    defer cassette_close(db);

    const key = "hello";
    const value = "world";
    const put_result = cassette_put(db.?, key.ptr, key.len, value.ptr, value.len);
    try std.testing.expectEqual(@as(c_int, 0), put_result);

    var value_out: ?[*:0]u8 = null;
    var value_len: usize = 0;
    const get_result = cassette_get(db.?, key.ptr, key.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(c_int, 0), get_result);
    try std.testing.expect(value_out != null);
    try std.testing.expectEqual(value.len, value_len);
    try std.testing.expectEqualStrings(value, std.mem.span(value_out.?));

    cassette_free_value(value_out);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "C ABI get missing key returns 1" {
    const io = std.testing.io;
    const path = "test_c_abi_missing.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const db = cassette_open(path);
    try std.testing.expect(db != null);
    defer cassette_close(db);

    const key = "missing";
    var value_out: ?[*:0]u8 = null;
    var value_len: usize = 0;
    const get_result = cassette_get(db.?, key.ptr, key.len, &value_out, &value_len);
    try std.testing.expectEqual(@as(c_int, 1), get_result);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "C ABI scan range" {
    const io = std.testing.io;
    const path = "test_c_abi_scan.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const db = cassette_open(path);
    try std.testing.expect(db != null);
    defer cassette_close(db);

    try std.testing.expectEqual(@as(c_int, 0), cassette_put(db.?, "aaa".ptr, 3, "1".ptr, 1));
    try std.testing.expectEqual(@as(c_int, 0), cassette_put(db.?, "bbb".ptr, 3, "2".ptr, 1));
    try std.testing.expectEqual(@as(c_int, 0), cassette_put(db.?, "ccc".ptr, 3, "3".ptr, 1));

    const Context = struct {
        count: usize = 0,
        found_bbb: bool = false,
        found_ccc: bool = false,

        fn callback(
            key_ptr: [*]const u8,
            key_len: usize,
            value_ptr: [*]const u8,
            value_len: usize,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user_data.?)));
            ctx.count += 1;
            const key = key_ptr[0..key_len];
            const value = value_ptr[0..value_len];
            if (std.mem.eql(u8, key, "bbb") and std.mem.eql(u8, value, "2")) {
                ctx.found_bbb = true;
            } else if (std.mem.eql(u8, key, "ccc") and std.mem.eql(u8, value, "3")) {
                ctx.found_ccc = true;
            }
        }
    };

    var ctx: Context = .{};
    const result = cassette_scan(db.?, "bbb".ptr, 3, "ddd".ptr, 3, Context.callback, &ctx);
    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    try std.testing.expect(ctx.found_bbb);
    try std.testing.expect(ctx.found_ccc);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "C ABI check and compact" {
    const io = std.testing.io;
    const path = "test_c_abi_check_compact.ctdb";

    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const db = cassette_open(path);
    try std.testing.expect(db != null);
    defer cassette_close(db);

    try std.testing.expectEqual(@as(c_int, 0), cassette_put(db.?, "key".ptr, 3, "old".ptr, 3));
    try std.testing.expectEqual(@as(c_int, 0), cassette_put(db.?, "key".ptr, 3, "new".ptr, 3));

    try std.testing.expectEqual(@as(c_int, 0), cassette_check(db.?));
    try std.testing.expectEqual(@as(c_int, 0), cassette_compact(db.?));
    try std.testing.expectEqual(@as(c_int, 0), cassette_check(db.?));

    var value_out: ?[*:0]u8 = null;
    var value_len: usize = 0;
    try std.testing.expectEqual(@as(c_int, 0), cassette_get(db.?, "key".ptr, 3, &value_out, &value_len));
    try std.testing.expectEqualStrings("new", std.mem.span(value_out.?));
    cassette_free_value(value_out);

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
