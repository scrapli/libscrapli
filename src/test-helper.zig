const std = @import("std");
const flags = @import("flags.zig");
const file = @import("file.zig");
const re = @import("re.zig");

const timestamp_pattern = "((mon)|(tue)|(wed)|(thu)|(fri)|(sat)|(sun))\\s+((jan)|(feb)|(mar)|(apr)|(may)|(jun)|(jul)|(aug)|(sep)|(oct)|(nov)|(dec))\\s+\\d+\\s+\\d+:\\d+:\\d+ \\d+";
const last_login_pattern = "^last login.*$";
const netconf_timestamp_pattern = "\\d{4}-\\d{2}-\\d{2}T\\d+:\\d+:\\d+.\\d+Z";
const netconf_session_id_pattern = "<session-id>\\d+</session-id>";

const normalize_funcs = [3]*const fn (
    allocator: std.mem.Allocator,
    haystack: []const u8,
) anyerror![]const u8{
    normalizeTimestamps,
    normalizeLastLogin,
    normalizeNetconfSessionId,
};

pub fn processFixutreTestStrResult(
    test_name: []const u8,
    case_name: []const u8,
    golden_filename: []const u8,
    actual: []const u8,
) !void {
    const update = flags.parseCustomFlag("--update", false);

    var _actual = try std.testing.allocator.alloc(u8, actual.len);
    defer std.testing.allocator.free(_actual);
    @memcpy(_actual, actual);

    for (normalize_funcs) |f| {
        const ret = try f(std.testing.allocator, _actual);
        defer std.testing.allocator.free(ret);

        std.testing.allocator.free(_actual);
        _actual = try std.testing.allocator.alloc(u8, ret.len);

        @memcpy(_actual, ret);
    }

    if (update) {
        try file.writeToPath(std.testing.allocator, golden_filename, actual);

        return;
    }

    const expected = try file.readFromPath(
        std.testing.allocator,
        golden_filename,
    );
    defer std.testing.allocator.free(expected);

    var _expected = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(_expected);
    @memcpy(_expected, expected);

    // normalize expected
    for (normalize_funcs) |f| {
        const ret = try f(std.testing.allocator, _expected);
        defer std.testing.allocator.free(ret);

        std.testing.allocator.free(_expected);
        _expected = try std.testing.allocator.alloc(u8, ret.len);

        @memcpy(_expected, ret);
    }

    try testStrResult(
        test_name,
        case_name,
        _actual,
        _expected,
    );
}

pub fn testStrResult(
    test_name: []const u8,
    case_name: []const u8,
    actual: []const u8,
    expected: []const u8,
) !void {
    var display_name = test_name;
    if (case_name.len > 0) {
        display_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s} {s}",
            .{ test_name, case_name },
        );
    }

    defer if (case_name.len > 0) {
        std.testing.allocator.free(display_name);
    };

    const diff_index = std.mem.indexOfDiff(u8, actual, expected);

    if (diff_index == null) {
        return;
    }

    std.debug.print("test {s} failed...\n", .{display_name});
    std.debug.print("===========================\n\n", .{});
    std.debug.print("actual ------------------->\n", .{});
    printWithVisibleNewlines(actual);
    std.debug.print("<-actual---------expected->\n", .{});
    printWithVisibleNewlines(expected);
    std.debug.print("<----------------- expected\n\n", .{});

    var diff_line_number: usize = 1;
    for (expected[0..diff_index.?]) |value| {
        if (value == '\n') diff_line_number += 1;
    }
    std.debug.print("\nFirst difference occurs on line {d}:\n", .{diff_line_number});

    std.debug.print("expected:\n", .{});
    printIndicatorLine(expected, diff_index.?);

    std.debug.print("found:\n", .{});
    printIndicatorLine(actual, diff_index.?);

    std.debug.print("===========================\n", .{});

    return error.AssertionFailed;
}

fn normalizeTimestamps(
    allocator: std.mem.Allocator,
    haystack: []const u8,
) anyerror![]const u8 {
    if (haystack.len != 0) {
        // SAFETY: will always be set;
        var pattern: []const u8 = undefined;

        if (std.mem.indexOf(u8, haystack, "<rpc") != null) {
            pattern = netconf_timestamp_pattern;
        } else {
            pattern = timestamp_pattern;
        }

        const compiled_timestamp_pattern = re.pcre2Compile(pattern);
        defer re.pcre2Free(compiled_timestamp_pattern.?);

        const match_indexes = try re.pcre2FindIndex(
            compiled_timestamp_pattern.?,
            haystack,
        );
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            const replace = "Mon Jan 1 00:00:00 2025";

            const replace_size = std.mem.replacementSize(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                replace,
            );

            const out = try allocator.alloc(u8, replace_size);

            _ = std.mem.replace(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                replace,
                out,
            );

            return out;
        }
    }

    const out = try allocator.alloc(u8, haystack.len);
    @memcpy(out, haystack);

    return out;
}

fn normalizeLastLogin(
    allocator: std.mem.Allocator,
    haystack: []const u8,
) anyerror![]const u8 {
    if (haystack.len != 0) {
        const compiled_last_login_pattern = re.pcre2Compile(
            last_login_pattern,
        );
        defer re.pcre2Free(compiled_last_login_pattern.?);

        const match_indexes = try re.pcre2FindIndex(
            compiled_last_login_pattern.?,
            haystack,
        );
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            const replace_size = std.mem.replacementSize(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                "",
            );

            const out = try allocator.alloc(u8, replace_size);

            _ = std.mem.replace(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                "",
                out,
            );

            return out;
        }
    }

    const out = try allocator.alloc(u8, haystack.len);
    @memcpy(out, haystack);

    return out;
}

fn normalizeNetconfSessionId(
    allocator: std.mem.Allocator,
    haystack: []const u8,
) anyerror![]const u8 {
    if (haystack.len != 0 and std.mem.indexOf(u8, haystack, "<session-id>") != null) {
        const compiled_netconf_session_id_pattern = re.pcre2Compile(
            netconf_session_id_pattern,
        );
        defer re.pcre2Free(compiled_netconf_session_id_pattern.?);

        const match_indexes = try re.pcre2FindIndex(
            compiled_netconf_session_id_pattern.?,
            haystack,
        );
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            const replace_size = std.mem.replacementSize(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                "",
            );

            const out = try allocator.alloc(u8, replace_size);

            _ = std.mem.replace(
                u8,
                haystack,
                haystack[match_indexes[0]..match_indexes[1]],
                "",
                out,
            );

            return out;
        }
    }

    const out = try allocator.alloc(u8, haystack.len);
    @memcpy(out, haystack);

    return out;
}

// taken from std lib
fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i..][0..nl]);
    }
    std.debug.print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}

// taken from std lib
fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return std.debug.print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    std.debug.print("{s}\n", .{line});
}

// taken from std lib
fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(u8, source[0..indicator_index], '\n')) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(u8, source[indicator_index..], '\n')) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    for (line_begin_index..indicator_index) |_|
        std.debug.print(" ", .{});
    if (indicator_index >= source.len)
        std.debug.print("^ (end of string)\n", .{})
    else
        std.debug.print("^ ('\\x{x:0>2}')\n", .{source[indicator_index]});
}
