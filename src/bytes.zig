const std = @import("std");
const ascii = @import("ascii.zig");

// a string that is used to delimit multiple substrings -- used in a few places for passing things
// via ffi to not have to deal w/ c arrays and such
pub const libscrapli_delimiter = "__libscrapli__";

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

pub fn roughlyContains(haystack: []const u8, needle: []const u8) [2]usize {
    if (needle.len > haystack.len) {
        return [2]usize{ 0, 0 };
    }

    const match_start_index = std.mem.indexOf(u8, haystack, needle);
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

pub fn trimWhitespace(
    allocator: std.mem.Allocator,
    buf: []const u8,
) ![]const u8 {
    const trimmed_buf = std.mem.trim(u8, buf, " \t\n\r");
    const owned_trimmed_buf = try allocator.alloc(u8, trimmed_buf.len);

    @memcpy(owned_trimmed_buf, trimmed_buf);

    return owned_trimmed_buf;
}

test "trimWhitespace" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "nothing to trim",
            .input = "foo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim newline",
            .input = "\nfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim carriage return",
            .input = "\rfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim carriage return newline",
            .input = "\r\nfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim tab",
            .input = "\tfoo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "left trim spaces",
            .input = "  foo bar baz",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim newline",
            .input = "foo bar baz\n",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim carriage return",
            .input = "foo bar baz\r",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim carriage return newline",
            .input = "foo bar baz\r\n",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim tab",
            .input = "foo bar baz\t",
            .expected = "foo bar baz",
        },
        .{
            .name = "right trim spaces",
            .input = "foo bar baz  ",
            .expected = "foo bar baz",
        },
        .{
            .name = "trim all the things",
            .input = "\t \r\n foo bar baz\r\n \t ",
            .expected = "foo bar baz",
        },
    };

    for (cases) |case| {
        const actual = try trimWhitespace(
            std.testing.allocator,
            case.input,
        );
        defer std.testing.allocator.free(actual);

        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

pub fn getBufSearchView(
    buf: []u8,
    depth: u64,
) []u8 {
    if (buf.len < depth) {
        return buf[0..];
    }

    return buf[buf.len - depth ..];
}

pub const ProcessedBuf = struct {
    raw: std.ArrayList(u8),
    processed: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) ProcessedBuf {
        return ProcessedBuf{
            .raw = std.ArrayList(u8).init(allocator),
            .processed = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ProcessedBuf) void {
        self.raw.deinit();
        self.processed.deinit();
    }

    pub fn appendSlice(self: *ProcessedBuf, buf: []u8) !void {
        try self.raw.appendSlice(buf);

        if (std.mem.indexOf(u8, buf, &[_]u8{ascii.control_chars.esc}) != null) {
            // if ESC in the new buf look at last n of processed buf to replace if
            // necessary; this *feels* bad like we may miss sequences (if our read gets part
            // of a sequence, then a subsequent read gets the rest), however this has never
            // happened in 5+ years of scrapli/scrapligo only checking/cleaning the read buf
            // so we are going to roll with it and hope :)
            const n = ascii.stripAsciiAndAnsiControlCharsInPlace(
                buf,
                0,
            );
            try self.processed.appendSlice(buf[0..n]);
        } else {
            try self.processed.appendSlice(buf);
        }
    }

    pub fn toOwnedSlices(self: *ProcessedBuf) ![2][]const u8 {
        return [2][]const u8{
            try self.raw.toOwnedSlice(),
            try self.processed.toOwnedSlice(),
        };
    }
};
