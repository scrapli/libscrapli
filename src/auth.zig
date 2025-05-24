const std = @import("std");
const bytes = @import("bytes.zig");
const re = @import("re.zig");
const errors = @import("errors.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

pub const default_username_pattern: []const u8 = "^(.*username:)|(.*login:)\\s?$";
pub const default_password_pattern: []const u8 = "(.*@.*)?password:\\s?$";
pub const default_passphrase_pattern: []const u8 = "enter passphrase for key";

pub const lookup_prefix = "__lookup::";
pub const lookup_default_key = "__default__";

pub const State = enum {
    complete,
    username_prompted,
    password_prompted,
    passphrase_prompted,
    _continue,
};

pub const LookupKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const OptionsInputs = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    private_key_path: ?[]const u8 = null,
    private_key_passphrase: ?[]const u8 = null,
    lookup_map: ?[]const LookupKeyValue = null,
    in_session_auth_bypass: bool = false,
    username_pattern: []const u8 = default_username_pattern,
    password_pattern: []const u8 = default_password_pattern,
    passphrase_pattern: []const u8 = default_passphrase_pattern,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    username: ?[]const u8,
    password: ?[]const u8,
    private_key_path: ?[]const u8,
    private_key_passphrase: ?[]const u8,
    lookups: ?[]const LookupKeyValue,
    in_session_auth_bypass: bool,
    username_pattern: []const u8,
    password_pattern: []const u8,
    private_key_passphrase_pattern: []const u8,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer o.deinit();

        o.* = Options{
            .allocator = allocator,
            .username = opts.username,
            .password = opts.password,
            .private_key_path = opts.private_key_path,
            .private_key_passphrase = opts.private_key_passphrase,
            .lookups = opts.lookup_map,
            .in_session_auth_bypass = opts.in_session_auth_bypass,
            .username_pattern = opts.username_pattern,
            .password_pattern = opts.password_pattern,
            .private_key_passphrase_pattern = opts.passphrase_pattern,
        };

        if (o.username != null) {
            o.username = try o.allocator.dupe(u8, o.username.?);
        }

        if (o.password != null) {
            o.password = try o.allocator.dupe(u8, o.password.?);
        }

        if (o.private_key_path != null) {
            o.private_key_path = try o.allocator.dupe(u8, o.private_key_path.?);
        }

        if (o.private_key_passphrase != null) {
            o.private_key_passphrase = try o.allocator.dupe(u8, o.private_key_passphrase.?);
        }

        if (o.lookups != null) {
            const lm = try o.allocator.alloc(
                LookupKeyValue,
                o.lookups.?.len,
            );

            for (0..o.lookups.?.len) |idx| {
                lm[idx] = .{
                    .key = try o.allocator.dupe(u8, o.lookups.?[idx].key),
                    .value = try o.allocator.dupe(u8, o.lookups.?[idx].value),
                };
            }

            o.lookups = lm;
        }

        if (&o.username_pattern[0] != &default_username_pattern[0]) {
            o.username_pattern = try o.allocator.dupe(u8, o.username_pattern);
        }

        if (&o.password_pattern[0] != &default_password_pattern[0]) {
            o.password_pattern = try o.allocator.dupe(u8, o.password_pattern);
        }

        if (&o.private_key_passphrase_pattern[0] != &default_passphrase_pattern[0]) {
            o.private_key_passphrase_pattern = try o.allocator.dupe(u8, o.private_key_passphrase_pattern);
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        if (self.username != null) {
            self.allocator.free(self.username.?);
        }

        if (self.password != null) {
            self.allocator.free(self.password.?);
        }

        if (self.private_key_path != null) {
            self.allocator.free(self.private_key_path.?);
        }

        if (self.private_key_passphrase != null) {
            self.allocator.free(self.private_key_passphrase.?);
        }

        if (self.lookups != null) {
            for (self.lookups.?) |lookup_entry| {
                self.allocator.free(lookup_entry.key);
                self.allocator.free(lookup_entry.value);
            }

            self.allocator.free(self.lookups.?);
        }

        if (&self.username_pattern[0] != &default_username_pattern[0]) {
            self.allocator.free(self.username_pattern);
        }

        if (&self.password_pattern[0] != &default_password_pattern[0]) {
            self.allocator.free(self.password_pattern);
        }

        if (&self.private_key_passphrase_pattern[0] != &default_passphrase_pattern[0]) {
            self.allocator.free(self.private_key_passphrase_pattern);
        }

        self.allocator.destroy(self);
    }

    pub fn extendLookupMap(self: *Options, k: []const u8, v: []const u8) !void {
        var cur_size: usize = 0;

        if (self.lookups != null) {
            cur_size = self.lookups.?.len;
        }

        const lm = try self.allocator.alloc(LookupKeyValue, cur_size + 1);

        if (cur_size > 1) {
            @memcpy(lm[0..cur_size], self.lookups.?[0..]);
        }

        lm[cur_size] = .{
            .key = try self.allocator.dupe(u8, k),
            .value = try self.allocator.dupe(u8, v),
        };

        self.lookups = lm;
    }

    pub fn resolveAuthValue(self: *Options, v: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, v, lookup_prefix)) {
            return v;
        }

        if (self.lookups == null) {
            return errors.ScrapliError.LookupFailed;
        }

        var default_idx: ?usize = null;

        const lookup_key = v[lookup_prefix.len..];

        for (0.., self.lookups.?) |idx, lookup_item| {
            if (std.mem.eql(u8, lookup_item.key, lookup_default_key)) {
                default_idx = idx;
            }

            if (std.mem.eql(u8, lookup_key, lookup_item.key)) {
                return lookup_item.value;
            }
        }

        if (default_idx != null) {
            return self.lookups.?[default_idx.?].value;
        }

        return errors.ScrapliError.LookupFailed;
    }
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
        return State.complete;
    }

    const password_match = try re.pcre2Find(
        compiled_password_pattern.?,
        searchable_buf,
    );
    if (password_match.len > 0) {
        return State.password_prompted;
    }

    const username_match = try re.pcre2Find(
        compiled_username_pattern.?,
        searchable_buf,
    );
    if (username_match.len > 0) {
        return State.username_prompted;
    }

    const passphrase_match = try re.pcre2Find(
        compiled_passphrase_pattern.?,
        searchable_buf,
    );
    if (passphrase_match.len > 0) {
        return State.passphrase_prompted;
    }

    return State._continue;
}

const open_error_message_substrings = [_][2][]const u8{
    [2][]const u8{ "host key verification failed", "" },
    [2][]const u8{ "no matching key exchange", "" },
    [2][]const u8{ "no matching host key", "" },
    [2][]const u8{ "no matching cipher", "" },
    [2][]const u8{ "operation timed out", "" },
    [2][]const u8{ "connection timed out", "" },
    [2][]const u8{ "no route to host", "" },
    [2][]const u8{ "bad configuration", "" },
    [2][]const u8{ "could not resolve hostname", "" },
    [2][]const u8{ "permission denied", "" },
    [2][]const u8{ "unprotected private key file", "" },
    [2][]const u8{ "too many authentication failures", "" },
    [2][]const u8{ "connection refused", "" },
    [2][]const u8{ "escape character is '^]'.", "are you telnet'ing to an ssh port?" },
    [2][]const u8{ "ssh-2.0-openssh_", "are you telnet'ing to an ssh port?" },
};

pub fn openMessageHandler(allocator: std.mem.Allocator, buf: []const u8) !?[]const u8 {
    const copied_buf = try allocator.alloc(u8, buf.len);
    defer allocator.free(copied_buf);

    @memcpy(copied_buf, buf);

    bytes.toLower(copied_buf);

    for (open_error_message_substrings) |error_substring| {
        if (std.mem.indexOf(u8, copied_buf, error_substring[0]) != null) {
            if (error_substring[1].len > 0) {
                return error_substring[1];
            }

            return error_substring[0];
        }
    }

    return null;
}

test "openMessageHandler" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        expected: ?[]const u8,
    }{
        .{
            .name = "no error",
            .haystack = "",
            .expected = null,
        },
        .{
            .name = "host key verification failed",
            .haystack = "blah: host key verification failed",
            .expected = "host key verification failed",
        },
        .{
            .name = "no matching key exchange",
            .haystack = "blah: no matching key exchange",
            .expected = "no matching key exchange",
        },
        .{
            .name = "no matching host key",
            .haystack = "blah: no matching host key",
            .expected = "no matching host key",
        },
        .{
            .name = "no matching cipher",
            .haystack = "blah: no matching cipher",
            .expected = "no matching cipher",
        },
        .{
            .name = "operation timed out",
            .haystack = "blah: operation timed out",
            .expected = "operation timed out",
        },
        .{
            .name = "connection timed out",
            .haystack = "blah: connection timed out",
            .expected = "connection timed out",
        },
        .{
            .name = "no route to host",
            .haystack = "blah: no route to host",
            .expected = "no route to host",
        },
        .{
            .name = "bad configuration",
            .haystack = "blah: bad configuration",
            .expected = "bad configuration",
        },
        .{
            .name = "could not resolve hostname",
            .haystack = "blah: could not resolve hostname",
            .expected = "could not resolve hostname",
        },
        .{
            .name = "permission denied",
            .haystack = "blah: permission denied",
            .expected = "permission denied",
        },
        .{
            .name = "unprotected private key file",
            .haystack = "blah: unprotected private key file",
            .expected = "unprotected private key file",
        },
        .{
            .name = "too many auth failures",
            .haystack = "blah: Too many authentication failures",
            .expected = "too many authentication failures",
        },
        .{
            .name = "connection refused",
            .haystack = "blah: connection refused",
            .expected = "connection refused",
        },
        .{
            .name = "sshing to telnet port",
            .haystack = "Escape character is '^]'.",
            .expected = "are you telnet'ing to an ssh port?",
        },
        .{
            .name = "sshing to telnet port",
            .haystack = "blah SSH-2.0-OpenSSH_ blah blah",
            .expected = "are you telnet'ing to an ssh port?",
        },
    };

    for (cases) |case| {
        const actual = try openMessageHandler(std.testing.allocator, case.haystack);

        if (case.expected == null) {
            try std.testing.expect(actual == null);
        } else {
            try std.testing.expectEqualStrings(case.expected.?, actual.?);
        }
    }
}
