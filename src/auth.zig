const std = @import("std");
const bytes = @import("bytes.zig");
const re = @import("re.zig");

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
    Complete,
    UsernamePrompted,
    PasswordPrompted,
    PassphrasePrompted,
    Continue,
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
    lookup_map: ?[]const LookupKeyValue,
    in_session_auth_bypass: bool,
    username_pattern: []const u8,
    password_pattern: []const u8,
    passphrase_pattern: []const u8,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer o.deinit();

        o.* = Options{
            .allocator = allocator,
            .username = opts.username,
            .password = opts.password,
            .private_key_path = opts.private_key_path,
            .private_key_passphrase = opts.private_key_passphrase,
            .lookup_map = opts.lookup_map,
            .in_session_auth_bypass = opts.in_session_auth_bypass,
            .username_pattern = opts.username_pattern,
            .password_pattern = opts.password_pattern,
            .passphrase_pattern = opts.passphrase_pattern,
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

        if (o.lookup_map != null) {
            const lm = try o.allocator.alloc(
                LookupKeyValue,
                o.lookup_map.?.len,
            );

            for (0..o.lookup_map.?.len) |idx| {
                lm[idx] = .{
                    .key = try o.allocator.dupe(u8, o.lookup_map.?[idx].key),
                    .value = try o.allocator.dupe(u8, o.lookup_map.?[idx].value),
                };
            }

            o.lookup_map = lm;
        }

        if (&o.username_pattern[0] != &default_username_pattern[0]) {
            o.username_pattern = try o.allocator.dupe(u8, o.username_pattern);
        }

        if (&o.password_pattern[0] != &default_password_pattern[0]) {
            o.password_pattern = try o.allocator.dupe(u8, o.password_pattern);
        }

        if (&o.passphrase_pattern[0] != &default_passphrase_pattern[0]) {
            o.passphrase_pattern = try o.allocator.dupe(u8, o.passphrase_pattern);
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

        if (self.lookup_map != null) {
            for (self.lookup_map.?) |lookup_entry| {
                self.allocator.free(lookup_entry.key);
                self.allocator.free(lookup_entry.value);
            }

            self.allocator.free(self.lookup_map.?);
        }

        if (&self.username_pattern[0] != &default_username_pattern[0]) {
            self.allocator.free(self.username_pattern);
        }

        if (&self.password_pattern[0] != &default_password_pattern[0]) {
            self.allocator.free(self.password_pattern);
        }

        if (&self.passphrase_pattern[0] != &default_passphrase_pattern[0]) {
            self.allocator.free(self.passphrase_pattern);
        }

        self.allocator.destroy(self);
    }

    pub fn extendLookupMap(self: *Options, k: []const u8, v: []const u8) !void {
        var cur_size: usize = 0;

        if (self.lookup_map != null) {
            cur_size = self.lookup_map.?.len;
        }

        const lm = try self.allocator.alloc(LookupKeyValue, cur_size + 1);

        if (cur_size > 1) {
            @memcpy(lm[0..cur_size], self.lookup_map.?[0..]);
        }

        lm[cur_size] = .{
            .key = try self.allocator.dupe(u8, k),
            .value = try self.allocator.dupe(u8, v),
        };

        self.lookup_map = lm;
    }

    pub fn resolveAuthValue(self: *Options, v: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, v, lookup_prefix)) {
            return v;
        }

        if (self.lookup_map == null) {
            return error.LookupFailure;
        }

        var default_idx: ?usize = null;

        const lookup_key = v[lookup_prefix.len..];

        for (0.., self.lookup_map.?) |idx, lookup_item| {
            if (std.mem.eql(u8, lookup_item.key, lookup_default_key)) {
                default_idx = idx;
            }

            if (std.mem.eql(u8, lookup_key, lookup_item.key)) {
                return lookup_item.value;
            }
        }

        if (default_idx != null) {
            return self.lookup_map.?[default_idx.?].value;
        }

        return error.LookupFailure;
    }
};

pub fn processSearchableAuthBuf(
    allocator: std.mem.Allocator,
    searchable_buf: []const u8,
    compiled_prompt_pattern: ?*pcre2.pcre2_code_8,
    compiled_username_pattern: ?*pcre2.pcre2_code_8,
    compiled_password_pattern: ?*pcre2.pcre2_code_8,
    compiled_passphrase_pattern: ?*pcre2.pcre2_code_8,
) !State {
    try openMessageHandler(allocator, searchable_buf);

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
    "too many authentication failures",
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
        .{
            .name = "too many auth failures",
            .haystack = "blah: Too many authentication failures",
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
