const std = @import("std");

/// Cassette Tape Format v1
///
/// File layout:
///   Header (5 bytes)
///     [0..4] Magic: "CTDB"
///     [4]    Version: 0x01
///   Repeat:
///     Data Block (variable)
///       [0]        Block type: 0x01
///       [1..3]     Key length: u16 big-endian
///       [3..7]     Value length: u32 big-endian
///       [7..k]     Key bytes
///       [k..v]     Value bytes
///       [v..v+4]   CRC32 checksum (IEEE) of key || value, big-endian
///   EOF Block (1 byte)
///       [0]        Block type: 0xFF

pub const magic = [4]u8{ 'C', 'T', 'D', 'B' };
pub const version: u8 = 0x01;
pub const header_size = magic.len + 1;

pub const BlockType = enum(u8) {
    data = 0x01,
    eof = 0xFF,
};

pub const Header = extern struct {
    magic: [4]u8,
    version: u8,

    pub fn init() Header {
        return .{
            .magic = magic,
            .version = version,
        };
    }

    pub fn encode(self: Header, out: *[header_size]u8) void {
        out[0..4].* = self.magic;
        out[4] = self.version;
    }

    pub fn decode(bytes: *const [header_size]u8) Header {
        return .{
            .magic = bytes[0..4].*,
            .version = bytes[4],
        };
    }

    pub fn isValid(self: Header) bool {
        return std.mem.eql(u8, &self.magic, &magic) and self.version == version;
    }
};

pub const DataBlock = struct {
    key: []const u8,
    value: []const u8,

    pub fn encodedSize(self: DataBlock) usize {
        return 1 + 2 + 4 + self.key.len + self.value.len + 4;
    }

    pub fn encode(self: DataBlock, out: []u8) error{BufferTooSmall}!void {
        const size = self.encodedSize();
        if (out.len < size) return error.BufferTooSmall;

        out[0] = @intFromEnum(BlockType.data);
        std.mem.writeInt(u16, out[1..3], @intCast(self.key.len), .big);
        std.mem.writeInt(u32, out[3..7], @intCast(self.value.len), .big);

        @memcpy(out[7..][0..self.key.len], self.key);
        @memcpy(out[7 + self.key.len..][0..self.value.len], self.value);

        const checksum_offset = 7 + self.key.len + self.value.len;
        const cs = crc32(self.key, self.value);
        std.mem.writeInt(u32, out[checksum_offset..][0..4], cs, .big);
    }

    pub fn decode(allocator: std.mem.Allocator, in: []const u8) error{ InvalidBlock, OutOfMemory, Corrupt }!DataBlock {
        if (in.len < 11) return error.InvalidBlock;
        if (in[0] != @intFromEnum(BlockType.data)) return error.InvalidBlock;

        const key_len = std.mem.readInt(u16, in[1..3], .big);
        const val_len = std.mem.readInt(u32, in[3..7], .big);
        const total = 11 + key_len + val_len;
        if (in.len < total) return error.InvalidBlock;

        const key = try allocator.dupe(u8, in[7..][0..key_len]);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, in[7 + key_len..][0..val_len]);
        errdefer allocator.free(value);

        const expected = std.mem.readInt(u32, in[7 + key_len + val_len..][0..4], .big);
        const actual = crc32(key, value);
        if (expected != actual) return error.Corrupt;

        return .{ .key = key, .value = value };
    }

    pub fn deinit(self: DataBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const EofMarker = struct {
    pub const encoded_size = 1;

    pub fn encode(out: *[encoded_size]u8) void {
        out[0] = @intFromEnum(BlockType.eof);
    }

    pub fn decode(in: u8) error{InvalidBlock}!void {
        if (in != @intFromEnum(BlockType.eof)) return error.InvalidBlock;
    }
};

/// Append header + one data block + EOF marker to `writer`.
/// Convenience helper for Phase 1 smoke tests.
pub fn writeTape(
    allocator: std.mem.Allocator,
    writer: anytype,
    key: []const u8,
    value: []const u8,
) !void {
    var hdr: [header_size]u8 = undefined;
    Header.init().encode(&hdr);
    try writer.writeAll(&hdr);

    const block = DataBlock{ .key = key, .value = value };
    const size = block.encodedSize();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    try block.encode(buf);
    try writer.writeAll(buf);

    var eof: [EofMarker.encoded_size]u8 = undefined;
    EofMarker.encode(&eof);
    try writer.writeAll(&eof);
}

// -----------------------------------------------------------------------------
// CRC32 (IEEE 802.3) — small table-based implementation so we stay immune to
// std.hash.crc API churn across Zig versions.
// -----------------------------------------------------------------------------

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var c: u32 = @intCast(i);
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if ((c & 1) != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        entry.* = c;
    }
    break :blk table;
};

fn crc32(a: []const u8, b: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (a) |byte| c = crc_table[(c ^ byte) & 0xFF] ^ (c >> 8);
    for (b) |byte| c = crc_table[(c ^ byte) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "header roundtrip" {
    var buf: [header_size]u8 = undefined;
    const h = Header.init();
    h.encode(&buf);

    const h2 = Header.decode(&buf);
    try std.testing.expect(h2.isValid());
    try std.testing.expectEqualSlices(u8, &magic, &h2.magic);
    try std.testing.expectEqual(version, h2.version);
}

test "header rejects bad magic" {
    var buf = [_]u8{ 'X', 'X', 'X', 'X', version };
    const h = Header.decode(&buf);
    try std.testing.expect(!h.isValid());
}

test "data block roundtrip" {
    const allocator = std.testing.allocator;
    const key = "hello";
    const value = "world";
    const block = DataBlock{ .key = key, .value = value };

    const size = block.encodedSize();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    try block.encode(buf);

    const decoded = try DataBlock.decode(allocator, buf);
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings(key, decoded.key);
    try std.testing.expectEqualStrings(value, decoded.value);
}

test "data block detects corruption" {
    const allocator = std.testing.allocator;
    const key = "hello";
    const value = "world";
    const block = DataBlock{ .key = key, .value = value };

    const size = block.encodedSize();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    try block.encode(buf);
    buf[size - 1] ^= 0xFF; // corrupt checksum byte

    const result = DataBlock.decode(allocator, buf);
    try std.testing.expectError(error.Corrupt, result);
}

test "eof marker roundtrip" {
    var buf: [1]u8 = undefined;
    EofMarker.encode(&buf);
    try std.testing.expectEqual(@intFromEnum(BlockType.eof), buf[0]);
    try EofMarker.decode(buf[0]);
}

test "writeTape produces valid header + block + eof" {
    const allocator = std.testing.allocator;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    try writeTape(allocator, &aw.writer, "k", "v");
    list = aw.toArrayList();
    const bytes = list.items;

    // Header
    try std.testing.expectEqual(header_size, 5);
    const header = Header.decode(bytes[0..header_size]);
    try std.testing.expect(header.isValid());

    // Data block
    const block = try DataBlock.decode(allocator, bytes[header_size..]);
    defer block.deinit(allocator);
    try std.testing.expectEqualStrings("k", block.key);
    try std.testing.expectEqualStrings("v", block.value);

    // EOF
    const smoke_block = DataBlock{ .key = "k", .value = "v" };
    const block_size = smoke_block.encodedSize();
    const eof_offset = header_size + block_size;
    try std.testing.expectEqual(@intFromEnum(BlockType.eof), bytes[eof_offset]);
}
