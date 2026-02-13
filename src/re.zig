const std = @import("std");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const pcre2CompiledPattern = pcre2.pcre2_code_8;

/// Conveinence function to free a pcre2 compiled object.
pub fn pcre2Free(regexp: *pcre2CompiledPattern) void {
    pcre2.pcre2_code_free_8(regexp);
}

/// Conveinence function to compile pattern to a pcre2 compiled object..
pub fn pcre2Compile(pattern: []const u8) ?*pcre2CompiledPattern {
    // SAFETY: required for interop w/ C library
    var err_number: c_int = undefined;
    // SAFETY: required for interop w/ C library
    var err_offset: pcre2.PCRE2_SIZE = undefined;

    const compile_context = pcre2.pcre2_compile_context_create_8(null);
    defer pcre2.pcre2_compile_context_free_8(compile_context);

    const rc = pcre2.pcre2_set_newline_8(compile_context, pcre2.PCRE2_NEWLINE_ANYCRLF);
    if (rc != 0) {
        return null;
    }

    const regex: ?*pcre2CompiledPattern = pcre2.pcre2_compile_8(
        &pattern[0],
        pattern.len,
        pcre2.PCRE2_CASELESS | pcre2.PCRE2_MULTILINE,
        &err_number,
        &err_offset,
        compile_context,
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

/// Conveinence function to compile patterns into a list of pcre2 compiled objects.
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

/// Conveinence function to find the first match in haystack using the pcre2 pattern object.
pub fn pcre2Find(
    regexp: *pcre2.pcre2_code_8,
    haystack: []const u8,
) !?[]const u8 {
    // if we send a empty haystack pcre2 will not be happy, be defensive
    if (haystack.len == 0) {
        return null;
    }

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
            return null;
        }

        std.log.err("failed executing match, err: {s}", .{
            err_message_buf[0..@intCast(err_message_len)],
        });

        return error.Regex;
    } else if (rc == 0) {
        std.log.err(
            "match vectors was not big enough for all captured substrings",
            .{},
        );

        return error.Regex;
    }

    const match_vectors = pcre2.pcre2_get_ovector_pointer_8(matches);

    if (match_vectors[0] > match_vectors[1]) {
        std.log.err("match vectors first match pointers invalid", .{});

        return error.Regex;
    }

    const match = haystack[match_vectors[0]..match_vectors[1]];

    return match;
}

test "pcre2Find" {
    const cases = [_]struct {
        name: []const u8,
        pattern: []const u8,
        haystack: []const u8,
        expected: ?[]const u8,
    }{
        .{
            .name = "simple match",
            .pattern = "bar",
            .haystack = "foo bar baz",
            .expected = "bar",
        },
        .{
            .name = "no match",
            .pattern = "poo",
            .haystack = "foo bar baz",
            .expected = null,
        },
    };

    for (cases) |case| {
        const compiled_pattern = pcre2Compile(case.pattern);
        if (compiled_pattern == null) {
            return error.Regex;
        }

        defer pcre2Free(compiled_pattern.?);

        const actual = try pcre2Find(
            compiled_pattern.?,
            case.haystack,
        );

        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, actual.?);
        } else {
            try std.testing.expectEqual(null, actual);
        }
    }
}

/// Conveneince function to return the match indexes of the pattern in the given haystack.
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

        return error.Regex;
    } else if (rc == 0) {
        std.log.err(
            "match vectors was not big enough for all captured substrings",
            .{},
        );

        return error.Regex;
    }

    const match_vectors = pcre2.pcre2_get_ovector_pointer_8(matches);

    if (match_vectors[0] > match_vectors[1]) {
        std.log.err("match vectors first match pointers invalid", .{});

        return error.Regex;
    }

    return [2]usize{ match_vectors[0], match_vectors[1] };
}
