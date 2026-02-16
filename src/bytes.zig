const std = @import("std");

const ascii = @import("ascii.zig");

// a string that is used to delimit multiple substrings -- used in a few places for passing things
// via ffi to not have to deal w/ c arrays and such
pub const libscrapli_delimiter = "__libscrapli__";

/// Convert all contents of buf to lower.
pub fn toLower(buf: []u8) void {
    for (buf) |*b| {
        b.* = std.ascii.toLower(b.*);
    }
}

test "toLower" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .input = "FOO",
            .expected = "foo",
        },
    };

    for (cases) |case| {
        const actual = try std.testing.allocator.alloc(u8, case.input.len);
        defer std.testing.allocator.free(actual);

        @memcpy(actual, case.input);

        toLower(actual);

        try std.testing.expectEqualStrings(
            actual,
            case.expected,
        );
    }
}

/// Return the start and end indexes of needle in the haystack -- do this "roughly" -- meaning that
/// all contents of needle must appear in order in haystack, but other chars may interleave
/// needle's chars.
pub fn roughlyContains(haystack: []const u8, needle: []const u8) [2]usize {
    if (needle.len > haystack.len) {
        return [2]usize{ 0, 0 };
    }

    const match_start_index = std.mem.find(u8, haystack, needle);
    if (match_start_index != null) {
        return [2]usize{ match_start_index.?, match_start_index.? + needle.len };
    }

    var start_index: ?usize = null;
    var end_index: usize = 0;

    var haystack_index: u64 = 0;

    needle_iter: for (needle) |needle_char| {
        var should_continue: bool = false;

        for (haystack[haystack_index..]) |haystack_char| {
            defer haystack_index += 1;

            if (needle_char == haystack_char) {
                if (start_index == null) {
                    start_index = @as(usize, haystack_index);
                }

                should_continue = true;
                continue :needle_iter;
            }
        }

        if (!should_continue) {
            return [2]usize{ 0, 0 };
        }

        start_index = null;
    }

    end_index = haystack_index;

    return [2]usize{ start_index.?, end_index };
}

test "roughlyContains" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        needle: []const u8,
        expected: [2]usize,
    }{
        .{
            .name = "simple",
            .haystack = "foo H bar I baz",
            .needle = "HI",
            .expected = [2]usize{ 4, 11 },
        },
        .{
            .name = "simple",
            .haystack = "foo H bar I baz",
            .needle = "BYE",
            .expected = [2]usize{ 0, 0 },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            roughlyContains(case.haystack, case.needle),
            case.expected,
        );
    }
}

/// Return true if needle is in haystack.
pub fn charIn(haystack: []const u8, needle: u8) bool {
    for (haystack) |haystack_char| {
        if (needle == haystack_char) {
            return true;
        }
    }

    return false;
}

test "charIn" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        needle: u8,
        expected: bool,
    }{
        .{
            .name = "simple",
            .haystack = "bar",
            .needle = 97, // "a"
            .expected = true,
        },
        .{
            .name = "simple not in",
            .haystack = "foo",
            .needle = 97, // "a"
            .expected = false,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            charIn(case.haystack, case.needle),
            case.expected,
        );
    }
}

/// Conveinence function to trim newline chars from the given buf. Returns a new, trimmed, copy
/// that the user owns memory for.
pub fn trimNewlineWhitespace(
    allocator: std.mem.Allocator,
    buf: []const u8,
) ![]const u8 {
    const trimmed_buf = std.mem.trim(u8, buf, "\t\n\r");
    const owned_trimmed_buf = try allocator.alloc(u8, trimmed_buf.len);

    @memcpy(owned_trimmed_buf, trimmed_buf);

    return owned_trimmed_buf;
}

/// Return a view into the given buf that is depth sized at most, preferring of course the tail of
/// the buf.
pub fn getBufSearchView(
    buf: []u8,
    depth: u64,
) []u8 {
    if (buf.len < depth) {
        return buf[0..];
    }

    return buf[buf.len - depth ..];
}

/// A type that holds the "raw" and "processed" buffers (array list) for scrapli session objects.
pub const ProcessedBuf = struct {
    allocator: std.mem.Allocator,
    raw: std.ArrayList(u8),
    processed: std.ArrayList(u8),

    /// Initialize the ProcessedBuf object.
    pub fn init(allocator: std.mem.Allocator) ProcessedBuf {
        return ProcessedBuf{
            .allocator = allocator,
            .raw = .{},
            .processed = .{},
        };
    }

    /// Deinitialize the Processedbuf object.
    pub fn deinit(self: *ProcessedBuf) void {
        self.raw.deinit(self.allocator);
        self.processed.deinit(self.allocator);
    }

    /// Append the given buf to both raw and processed buffers, trimming asni/ascii chars before
    /// writing to the processed buf.
    pub fn appendSlice(self: *ProcessedBuf, buf: []u8) !void {
        try self.raw.appendSlice(self.allocator, buf);

        if (std.mem.find(u8, buf, &[_]u8{ascii.control_chars.esc}) != null) {
            // if ESC in the new buf look at last n of processed buf to replace if
            // necessary; this *feels* bad like we may miss sequences (if our read gets part
            // of a sequence, then a subsequent read gets the rest), however this has never
            // happened in 5+ years of scrapli/scrapligo only checking/cleaning the read buf
            // so we are going to roll with it and hope :)
            const n = ascii.stripAsciiAndAnsiControlCharsInPlace(
                buf,
                0,
            );
            try self.processed.appendSlice(self.allocator, buf[0..n]);
        } else {
            try self.processed.appendSlice(self.allocator, buf);
        }
    }

    /// Return the "raw" and "processed" buffers, caller owns memory.
    pub fn toOwnedSlices(self: *ProcessedBuf) ![2][]const u8 {
        return [2][]const u8{
            try self.raw.toOwnedSlice(self.allocator),
            try self.processed.toOwnedSlice(self.allocator),
        };
    }
};
