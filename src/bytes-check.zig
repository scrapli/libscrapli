const std = @import("std");

const bytes = @import("bytes.zig");
const re = @import("re.zig");

/// CheckF defines a check function that can be used with the in bytes check functions.
pub const CheckF = *const fn (args: CheckArgs, buf: []const u8) anyerror!MatchPositions;

/// MatchPositions holds the start and end positions of a match in some parent haystack -- it
/// includes a conveinence function to return the len of the match.
pub const MatchPositions = struct {
    start: usize,
    end: usize,

    /// Return the total len -- as in the distance between the start and end match positions.
    pub fn len(self: *MatchPositions) usize {
        return self.end - self.start;
    }
};

/// CheckArgs holds args that can be used with check functions.
pub const CheckArgs = struct {
    pattern: ?*re.pcre2CompiledPattern = null,
    patterns: ?[]const ?*re.pcre2CompiledPattern = null,
    actual: ?[]const u8 = null,
    // when set, pattern matches whose matched text contains any of these substrings are
    // skipped -- the search resumes after the excluded match rather than giving up
    excludes: ?[]const []const u8 = null,
};

fn matchExcluded(excludes: ?[]const []const u8, match: []const u8) bool {
    const exclusions = excludes orelse return false;

    for (exclusions) |exclusion| {
        if (std.mem.find(u8, match, exclusion) != null) {
            return true;
        }
    }

    return false;
}

/// Check if the buf is non-zero-len.
pub fn nonZeroBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    _ = args;

    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = 0, .end = buf.len };
}

/// Check if the check pattern is in the given buf. Matches whose matched text contains any of
/// the (optional) CheckArgs excludes are skipped and the search resumes after them.
pub fn patternInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    var offset: usize = 0;

    while (offset < buf.len) {
        const match_indexes = try re.pcre2FindIndexAt(args.pattern.?, buf, offset);
        if (match_indexes[0] == 0 and match_indexes[1] == 0) {
            break;
        }

        if (!matchExcluded(args.excludes, buf[match_indexes[0]..match_indexes[1]])) {
            return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] };
        }

        // resume searching after the excluded match, ensuring forward progress even if the
        // pattern produced a zero len match
        offset = @max(match_indexes[1], match_indexes[0] + 1);
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

/// Check if any pattern from the CheckArgs are in buf, return the first match position found.
/// Matches containing any of the (optional) CheckArgs excludes are skipped just like in
/// patternInBuf.
pub fn anyPatternInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    for (args.patterns.?) |pattern| {
        const found = try patternInBuf(
            .{
                .pattern = pattern,
                .excludes = args.excludes,
            },
            buf,
        );
        if (!(found.start == 0 and found.end == 0)) {
            return found;
        }
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

/// Return the positions of the exact CheckArgs content in the given buf.
pub fn exactInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_start_index = std.mem.find(u8, buf, args.actual.?);
    if (match_start_index != null) {
        return MatchPositions{
            .start = match_start_index.?,
            .end = match_start_index.? + args.actual.?.len,
        };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

/// Return the MatchPositions of what is in the CheckArgs in buf -- do this "fuzzily", meaning
/// all the contents of the check args must be in buf and in order in buf, but other chars may
/// be in the midst of the check buf.
pub fn fuzzyInBuf(args: CheckArgs, buf: []const u8) !MatchPositions {
    const match_indexes = bytes.roughlyContains(buf, args.actual.?);

    if (match_indexes[0] == 0 and match_indexes[1] == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] };
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
            .expected = MatchPositions{ .start = 0, .end = 3 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("foo"),
            },
            .expected = MatchPositions{ .start = 3, .end = 6 },
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

test "patternInBufExcludes" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        args: CheckArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "excluded match then real match",
            .haystack = "bar baz",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("ba[rz]"),
                .excludes = &[_][]const u8{"bar"},
            },
            .expected = MatchPositions{ .start = 4, .end = 7 },
        },
        .{
            .name = "all matches excluded",
            .haystack = "bar baz",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("ba[rz]"),
                .excludes = &[_][]const u8{"ba"},
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            // ensures resuming the search after an excluded match keeps multiline '^'
            // anchoring intact (the resumed match must only match at a real line start)
            .name = "anchored prompt with excluded line",
            .haystack = "tacocat(tacocat)#\ntacocat#",
            .args = CheckArgs{
                .pattern = re.pcre2Compile("^\\S+#\\s?$"),
                .excludes = &[_][]const u8{"(tacocat)"},
            },
            .expected = MatchPositions{ .start = 18, .end = 26 },
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
            .expected = MatchPositions{ .start = 0, .end = 3 },
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
            .expected = MatchPositions{ .start = 0, .end = 3 },
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
            .expected = MatchPositions{ .start = 0, .end = 3 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 3, .end = 6 },
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
            .expected = MatchPositions{ .start = 0, .end = 9 },
        },
        .{
            .name = "simple not from start",
            .haystack = "X o f X o X o",
            .args = CheckArgs{
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 4, .end = 13 },
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
