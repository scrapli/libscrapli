const std = @import("std");

const ascii = @import("ascii.zig");

/// A string that is used to delimit multiple substrings -- used in a few places for passing things
/// via ffi to not have to deal w/ c arrays and such
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
    raw: std.ArrayList(u8),
    journal: std.ArrayList(u8),
    processed: std.ArrayList(u8),

    /// Initialize the ProcessedBuf object.
    pub fn init() ProcessedBuf {
        return ProcessedBuf{
            .raw = .empty,
            .journal = .empty,
            .processed = .empty,
        };
    }

    /// Deinitialize the Processedbuf object.
    pub fn deinit(self: *ProcessedBuf, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.processed.deinit(allocator);
    }

    /// Append the given buf to both raw and processed buffers, trimming asni/ascii chars before
    /// writing to the processed buf.
    pub fn appendSlice(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []u8,
    ) !void {
        try self.raw.appendSlice(allocator, buf);

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
            try self.processed.appendSlice(allocator, buf[0..n]);
        } else {
            try self.processed.appendSlice(allocator, buf);
        }
    }

    /// Return the "raw" and "processed" buffers, caller owns memory.
    pub fn toOwnedSlices(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) ![2][]const u8 {
        return [2][]const u8{
            try self.raw.toOwnedSlice(allocator),
            try self.processed.toOwnedSlice(allocator),
        };
    }

    /// Reserve space in both buffers -- intended so that we dont have to grow from 0 when the
    /// session fires up basically.
    pub fn reserve(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        n: u64,
    ) !void {
        const cap: usize = @intCast(n);

        try self.raw.ensureTotalCapacity(allocator, cap);
        try self.processed.ensureTotalCapacity(allocator, cap);
    }

    /// Clear both the raw and processed bufs -- retain max lets us retain some space in the buffers
    /// so the idea is basically to start the bufs w/ some capacity (reserve) then never shrink them
    /// below the retained max. *But* importantly we have a *max* because if you do for example a
    /// show tech that is huge, we probably dont want to have that amount of memory just always
    /// allocated for us, so we can shrink back down to the max size.
    pub fn reset(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        retain_max: u64,
    ) !void {
        const cap: usize = @intCast(retain_max);

        try resetBuf(&self.raw, allocator, cap);
        try resetBuf(&self.processed, allocator, cap);
    }

    fn resetBuf(
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        retain_max: usize,
    ) !void {
        if (list.capacity > retain_max) {
            list.clearAndFree(allocator);
            try list.ensureTotalCapacity(allocator, retain_max);

            return;
        }

        list.clearRetainingCapacity();
    }

    /// Return owned copies of the "raw" and "processed" buffers (caller owns the returned memory)
    /// without consuming this ProcessedBuf, so the (almost certainly) Session can continue using
    /// this object..
    pub fn dupeOwnedSlices(self: *ProcessedBuf, allocator: std.mem.Allocator) ![2][]const u8 {
        const raw_copy = try allocator.dupe(u8, self.raw.items);
        errdefer allocator.free(raw_copy);

        const processed_copy = try allocator.dupe(u8, self.processed.items);

        return [2][]const u8{ raw_copy, processed_copy };
    }
};

test "ProcessedBuf append journal" {
    const cases = [_]struct {
        name: []const u8,
        in_buf: []const u8,
        expected_processed: []const u8,
        expected_journal: []const u8,
    }{
        .{
            .name = "simple, no journal entry",
            .in_buf = "foo",
            .expected_processed = "foo",
            .expected_journal = "",
        },
        .{
            .name = "simple journal entry",
            .in_buf = "\x1Bxfoo",
            .expected_processed = "foo",
            .expected_journal = "",
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();
        defer pb.deinit(std.testing.allocator);

        const in_buf = try std.testing.allocator.dupe(u8, case.in_buf);
        defer std.testing.allocator.free(in_buf);

        const expected_processed = try std.testing.allocator.dupe(u8, case.expected_processed);
        defer std.testing.allocator.free(expected_processed);

        const expected_journal = try std.testing.allocator.dupe(u8, case.expected_journal);
        defer std.testing.allocator.free(expected_journal);

        try pb.appendSlice(std.testing.allocator, in_buf);

        try std.testing.expectEqualStrings(expected_processed, pb.processed.items);
        try std.testing.expectEqualStrings(expected_journal, pb.journal.items);
    }
}
