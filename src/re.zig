const std = @import("std");
const errors = @import("errors.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub fn pcre2Free(regexp: *pcre2.pcre2_code_8) void {
    pcre2.pcre2_code_free_8(regexp);
}

pub fn pcre2Compile(pattern: []const u8) ?*pcre2.pcre2_code_8 {
    // SAFETY: required for interop w/ C library
    var err_number: c_int = undefined;
    // SAFETY: required for interop w/ C library
    var err_offset: pcre2.PCRE2_SIZE = undefined;

    const regex: ?*pcre2.pcre2_code_8 = pcre2.pcre2_compile_8(
        &pattern[0],
        pattern.len,
        pcre2.PCRE2_CASELESS | pcre2.PCRE2_MULTILINE,
        &err_number,
        &err_offset,
        null,
    );

    if (regex == null) {
        // SAFETY: required for interop w/ C library
        var err_message_buf: [256]u8 = undefined;

        const err_message_len = pcre2.pcre2_get_error_message_8(
            err_number,
            &err_message_buf,
            err_message_buf.len,
        );

        std.log.err(
            "failed compiling pattern {s}, err: {s}",
            .{ pattern, err_message_buf[0..@intCast(err_message_len)] },
        );
    }

    return regex;
}

pub fn pcre2CompileMany(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
) ![]?*pcre2.pcre2_code_8 {
    var compiled_patterns = try allocator.alloc(
        ?*pcre2.pcre2_code_8,
        patterns.len,
    );

    for (0.., patterns) |idx, pattern| {
        compiled_patterns[idx] = pcre2Compile(pattern);
    }

    return compiled_patterns;
}

pub fn pcre2Find(
    regexp: *pcre2.pcre2_code_8,
    haystack: []const u8,
) ![]const u8 {
    const matches: ?*pcre2.pcre2_match_data_8 = pcre2.pcre2_match_data_create_from_pattern_8(
        regexp,
        null,
    );
    defer pcre2.pcre2_match_data_free_8(matches);

    const rc: c_int = pcre2.pcre2_match_8(
        regexp,
        &haystack[0],
        haystack.len,
        0,
        0,
        matches.?,
        null,
    );

    if (rc < 0) {
        var err_message_buf: [256]u8 = undefined;

        const err_message_len = pcre2.pcre2_get_error_message_8(
            rc,
            &err_message_buf,
            err_message_buf.len,
        );

        const err_message = err_message_buf[0..@intCast(err_message_len)];

        if (std.mem.indexOf(u8, err_message, "no match") != null) {
            return "";
        }

        std.log.err("failed executing match, err: {s}", .{
            err_message_buf[0..@intCast(err_message_len)],
        });

        return errors.ScrapliError.RegexError;
    } else if (rc == 0) {
        std.log.err(
            "match vectors was not big enough for all captured substrings",
            .{},
        );

        return errors.ScrapliError.RegexError;
    }

    const match_vectors = pcre2.pcre2_get_ovector_pointer_8(matches);

    if (match_vectors[0] > match_vectors[1]) {
        std.log.err("match vectors first match pointers invalid", .{});

        return errors.ScrapliError.RegexError;
    }

    const match = haystack[match_vectors[0]..match_vectors[1]];

    return match;
}

test "pcre2Find" {
    const cases = [_]struct {
        name: []const u8,
        pattern: []const u8,
        haystack: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple match",
            .pattern = "bar",
            .haystack = "foo bar baz",
            .expected = "bar",
        },
    };

    for (cases) |case| {
        const compiled_pattern = pcre2Compile(case.pattern);
        if (compiled_pattern == null) {
            return errors.ScrapliError.RegexError;
        }

        defer pcre2Free(compiled_pattern.?);

        const actual = try pcre2Find(
            compiled_pattern.?,
            case.haystack,
        );

        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

pub fn pcre2FindIndex(
    regexp: *pcre2.pcre2_code_8,
    haystack: []const u8,
) ![2]usize {
    const matches: ?*pcre2.pcre2_match_data_8 = pcre2.pcre2_match_data_create_from_pattern_8(
        regexp,
        null,
    );
    defer pcre2.pcre2_match_data_free_8(matches);

    const rc: c_int = pcre2.pcre2_match_8(
        regexp,
        &haystack[0],
        haystack.len,
        0,
        0,
        matches.?,
        null,
    );

    if (rc < 0) {
        var err_message_buf: [256]u8 = undefined;

        const err_message_len = pcre2.pcre2_get_error_message_8(
            rc,
            &err_message_buf,
            err_message_buf.len,
        );

        const err_message = err_message_buf[0..@intCast(err_message_len)];

        if (std.mem.indexOf(u8, err_message, "no match") != null) {
            return [2]usize{ 0, 0 };
        }

        std.log.err("failed executing match, err: {s}", .{
            err_message_buf[0..@intCast(err_message_len)],
        });

        return errors.ScrapliError.RegexError;
    } else if (rc == 0) {
        std.log.err(
            "match vectors was not big enough for all captured substrings",
            .{},
        );

        return errors.ScrapliError.RegexError;
    }

    const match_vectors = pcre2.pcre2_get_ovector_pointer_8(matches);

    if (match_vectors[0] > match_vectors[1]) {
        std.log.err("match vectors first match pointers invalid", .{});

        return errors.ScrapliError.RegexError;
    }

    return [2]usize{ match_vectors[0], match_vectors[1] };
}
