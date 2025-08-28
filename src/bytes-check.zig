const std = @import("std");
const bytes = @import("bytes.zig");
const re = @import("re.zig");

pub const CheckF = fn (args: CheckArgs, buf: []u8) anyerror!MatchPositions;

pub const MatchPositions = struct {
    start: usize,
    end: usize,

    pub fn len(self: *MatchPositions) usize {
        if (self.end == 0) {
            return 0;
        }

        return self.end - self.start + 1;
    }
};

pub const CheckArgs = struct {
    pattern: ?*re.pcre2CompiledPattern = null,
    patterns: ?[]const ?*re.pcre2CompiledPattern = null,
    actual: ?[]const u8 = null,
};

pub fn nonZeroBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    _ = args;

    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = 0, .end = buf.len };
}

pub fn patternInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_indexes = try re.pcre2FindIndex(args.pattern.?, buf);
    if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
        return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

pub fn anyPatternInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    for (args.patterns.?) |pattern| {
        const match_indexes = try re.pcre2FindIndex(pattern.?, buf);
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
        }
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

pub fn exactInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_start_index = std.mem.indexOf(u8, buf, args.actual.?);
    if (match_start_index != null) {
        return MatchPositions{
            .start = match_start_index.?,
            .end = match_start_index.? + args.actual.?.len - 1,
        };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

pub fn fuzzyInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    const match_indexes = bytes.roughlyContains(buf, args.actual.?);

    if (match_indexes[0] == 0 and match_indexes[1] == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
}

test "patternInBuf" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        args: CheckArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("foo"),
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("foo"),
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("foo"),
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    defer {
        for (cases) |case| {
            re.pcre2Free(case.args.pattern.?);
        }
    }

    for (cases) |case| {
        const actual = try patternInBuf(case.args, case.haystack);

        try std.testing.expectEqual(case.expected, actual);
    }
}

test "anyPatternInBuf" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        args: CheckArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .args = CheckArgs{
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "done first match",
            .haystack = "foo",
            .args = CheckArgs{
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "done last match",
            .haystack = "bar",
            .args = CheckArgs{
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
    };

    defer {
        for (cases) |case| {
            for (case.args.patterns.?) |pattern| {
                re.pcre2Free(pattern.?);
            }

            std.testing.allocator.free(case.args.patterns.?);
        }
    }

    for (cases) |case| {
        const actual = try anyPatternInBuf(
            case.args,
            case.haystack,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}

test "exactInBuf" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        args: CheckArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    for (cases) |case| {
        const actual = try exactInBuf(
            case.args,
            case.haystack,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}

test "fuzzyInBuf" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        args: CheckArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "f X o X o",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 8 },
        },
        .{
            .name = "simple not from start",
            .haystack = "X o f X o X o",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 4, .end = 12 },
        },
    };

    for (cases) |case| {
        const actual = try fuzzyInBuf(
            case.args,
            case.haystack,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}
