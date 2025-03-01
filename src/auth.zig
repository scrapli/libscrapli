const std = @import("std");
const logger = @import("logger.zig");
const bytes = @import("bytes.zig");
const re = @import("re.zig");
const lookup = @import("lookup.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const default_username_pattern: []const u8 = "^(.*username:)|(.*login:)\\s?$";
const default_password_pattern: []const u8 = "(.*@.*)?password:\\s?$";
const default_passphrase_pattern: []const u8 = "enter passphrase for key";

pub const State = enum {
    Complete,
    UsernamePrompted,
    PasswordPrompted,
    PassphrasePrompted,
    Continue,
};

pub fn NewOptions() Options {
    return Options{
        .username = null,
        .password = null,
        .private_key_path = null,
        .private_key_passphrase = null,
        .lookup_fn = null,
        .in_session_auth_bypass = false,
        .username_pattern = default_username_pattern,
        .password_pattern = default_password_pattern,
        .passphrase_pattern = default_passphrase_pattern,
    };
}

pub const Options = struct {
    username: ?[]const u8,
    password: ?[]const u8,
    private_key_path: ?[]const u8,
    private_key_passphrase: ?[]const u8,
    lookup_fn: lookup.LookupFn,
    in_session_auth_bypass: bool,
    username_pattern: []const u8,
    password_pattern: []const u8,
    passphrase_pattern: []const u8,
};

pub fn processSearchableAuthBuf(
    searchable_buf: []const u8,
    compiled_prompt_pattern: ?*pcre2.pcre2_code_8,
    compiled_username_pattern: ?*pcre2.pcre2_code_8,
    compiled_password_pattern: ?*pcre2.pcre2_code_8,
    compiled_passphrase_pattern: ?*pcre2.pcre2_code_8,
) !State {
    const prompt_match = try re.pcre2Find(
        compiled_prompt_pattern.?,
        searchable_buf,
    );
    if (prompt_match.len > 0) {
        return State.Complete;
    }

    const password_match = try re.pcre2Find(
        compiled_password_pattern.?,
        searchable_buf,
    );
    if (password_match.len > 0) {
        return State.PasswordPrompted;
    }

    const username_match = try re.pcre2Find(
        compiled_username_pattern.?,
        searchable_buf,
    );
    if (username_match.len > 0) {
        return State.UsernamePrompted;
    }

    const passphrase_match = try re.pcre2Find(
        compiled_passphrase_pattern.?,
        searchable_buf,
    );
    if (passphrase_match.len > 0) {
        return State.PassphrasePrompted;
    }

    return State.Continue;
}

const openMessageErrorSubstrings = [_][]const u8{
    "host key verification failed",
    "no matching key exchange",
    "no matching host key",
    "no matching cipher",
    "operation timed out",
    "connection timed out",
    "no route to host",
    "bad configuration",
    "could not resolve hostname",
    "permission denied",
    "unprotected private key file",
};

fn openMessageHandler(allocator: std.mem.Allocator, buf: []const u8) !void {
    const copied_buf = allocator.alloc(u8, buf.len) catch {
        return error.OpenFailedMessageHandler;
    };
    defer allocator.free(copied_buf);

    @memcpy(copied_buf, buf);

    bytes.toLower(copied_buf);

    for (openMessageErrorSubstrings) |needle| {
        if (std.mem.indexOf(u8, copied_buf, needle) != null) {
            return error.OpenFailedMessageHandler;
        }
    }
}

test "openMessageHandler" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        expect_error: bool,
    }{
        .{
            .name = "no error",
            .haystack = "",
            .expect_error = false,
        },
        .{
            .name = "host key verification failed",
            .haystack = "blah: host key verification failed",
            .expect_error = true,
        },
        .{
            .name = "no matching key exchange",
            .haystack = "blah: no matching key exchange",
            .expect_error = true,
        },
        .{
            .name = "no matching host key",
            .haystack = "blah: no matching host key",
            .expect_error = true,
        },
        .{
            .name = "no matching cipher",
            .haystack = "blah: no matching cipher",
            .expect_error = true,
        },
        .{
            .name = "operation timed out",
            .haystack = "blah: operation timed out",
            .expect_error = true,
        },
        .{
            .name = "connection timed out",
            .haystack = "blah: connection timed out",
            .expect_error = true,
        },
        .{
            .name = "no route to host",
            .haystack = "blah: no route to host",
            .expect_error = true,
        },
        .{
            .name = "bad configuration",
            .haystack = "blah: bad configuration",
            .expect_error = true,
        },
        .{
            .name = "could not resolve hostname",
            .haystack = "blah: could not resolve hostname",
            .expect_error = true,
        },
        .{
            .name = "permission denied",
            .haystack = "blah: permission denied",
            .expect_error = true,
        },
        .{
            .name = "unprotected private key file",
            .haystack = "blah: unprotected private key file",
            .expect_error = true,
        },
    };

    for (cases) |case| {
        if (case.expect_error) {
            try std.testing.expectError(
                error.OpenFailedMessageHandler,
                openMessageHandler(
                    std.testing.allocator,
                    case.haystack,
                ),
            );
        } else {
            try openMessageHandler(std.testing.allocator, case.haystack);
        }
    }
}
