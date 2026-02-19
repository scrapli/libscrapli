const std = @import("std");

const bytes = @import("bytes.zig");
const errors = @import("errors.zig");
const re = @import("re.zig");

/// The default pattern to find a ssh/telnet username prompt.
pub const default_username_pattern: []const u8 = "^(.*user(name)?:)|(.*login:)\\s?$";

/// The default pattern to find a ssh/telnet password prompt.
pub const default_password_pattern: []const u8 = "(.*@.*)?password:\\s?$";

/// The default pattern to find an ssh key passphrase prompt.
pub const default_passphrase_pattern: []const u8 = "enter passphrase for key";

/// The prefix that indicates the remaineder of a string is the name of a key to lookup in the
/// lookup mapping.
pub const lookup_prefix = "__lookup::";

/// The dfeault "key" to use when looking up a credential.
pub const lookup_default_key = "__default__";

/// State holds the possible states of the authenticaiton process.
pub const State = enum {
    complete,
    username_prompted,
    password_prompted,
    passphrase_prompted,
    _continue,
};

/// LookupItems is a struct that holds up to 16 LookupKeyValues (explicitly sized to not deal w/
/// allocations).
pub const LookupItems = struct {
    items: [16]LookupKeyValue = undefined,
    count: usize = 0,

    /// Init the lookup items object.
    pub fn init(kvs: []const LookupKeyValue) LookupItems {
        var out = LookupItems{
            .items = undefined,
            .count = 0,
        };

        for (kvs) |kv| {
            out.items[out.count] = kv;
            out.count += 1;
        }

        return out;
    }

    fn cloneOwned(self: *const LookupItems, allocator: std.mem.Allocator) !LookupItems {
        var out = LookupItems{
            .items = undefined,
            .count = self.count,
        };

        for (self.items[0..self.count], 0..) |kv, i| {
            const key_copy = try allocator.dupe(u8, kv.key);
            const value_copy = try allocator.dupe(u8, kv.value);

            out.items[i] = .{
                .key = key_copy,
                .value = value_copy,
            };
        }

        return out;
    }

    fn deinitOwned(self: *LookupItems, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
    }
};

/// LookupKeyValue is a simple kv store used with libscrapli authenticaiton.
pub const LookupKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// OptionsInputs holds the inputs to generate an (auth) Options struct.
/// it would be worth investigating not doing this weird input then option struct -- the main reason
/// for this is so that we can have easily passed, non-allocated, values here, then when we init the
/// "real" struct we do our duping and stuff, this is just to make it easier for users to pass things
/// and not think about what needs to be heap allocated vs not
pub const OptionsInputs = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    private_key_path: ?[]const u8 = null,
    private_key_passphrase: ?[]const u8 = null,
    // for now(? forever?) lookups are limited to 16 times. adding a lookup callback in the future
    // would be next step i think, but for now this should be more than ok and the fixed size and
    // the count indicator makes this very easy to work with on the ffi bits.
    lookups: LookupItems = .{},
    // when true, regardless of the transport, do the in session auth bits -- that means we check
    // for user/password/passphrase and finally for expected prompt. normally this would be skipped
    // when using libssh2 since we would auth in channel, but this flag can force this behavior. may
    // be useful for some weird devices that do ssh auth then also prompt for user/pass on login --
    // like cisco wlc for example.
    force_in_session_auth: bool = false,
    // when true fully skip the in session auth bits even when using telnet/bin transports. this
    // would let you write some custom on open function to handle banners or whatever even when
    // using the telnet/bin transports.
    bypass_in_session_auth: bool = false,
    username_pattern: ?[]const u8 = null,
    password_pattern: ?[]const u8 = null,
    private_key_passphrase_pattern: ?[]const u8 = null,
};

/// Options holds the options for authentication bits -- things like prompts to know when to send
/// a username/password/passphrase, the inputs for those things, and more.
pub const Options = struct {
    allocator: std.mem.Allocator,
    username: ?[]const u8,
    password: ?[]const u8,
    private_key_path: ?[]const u8,
    private_key_passphrase: ?[]const u8,
    lookups: LookupItems,
    force_in_session_auth: bool,
    bypass_in_session_auth: bool,
    username_pattern: []const u8 = default_username_pattern,
    password_pattern: []const u8 = default_password_pattern,
    private_key_passphrase_pattern: []const u8 = default_passphrase_pattern,

    /// Initialize the auth options.
    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer o.deinit();

        o.* = Options{
            .allocator = allocator,
            .username = opts.username,
            .password = opts.password,
            .private_key_path = opts.private_key_path,
            .private_key_passphrase = opts.private_key_passphrase,
            .lookups = try opts.lookups.cloneOwned(allocator),
            .force_in_session_auth = opts.force_in_session_auth,
            .bypass_in_session_auth = opts.bypass_in_session_auth,
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

        if (opts.username_pattern) |p| {
            o.username_pattern = try o.allocator.dupe(u8, p);
        }

        if (opts.password_pattern) |p| {
            o.password_pattern = try o.allocator.dupe(u8, p);
        }

        if (opts.private_key_passphrase_pattern) |p| {
            o.private_key_passphrase_pattern = try o.allocator.dupe(u8, p);
        }

        return o;
    }

    /// Deinitialize the auth options.
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

        self.lookups.deinitOwned(self.allocator);

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

    /// Resolve the given auth input -- checks if the string begins with the "lookup prefix" -- if
    /// not, simply return the value, otherwise check all the lookups to see if we can find the
    /// value.
    pub fn resolveAuthValue(self: *Options, v: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, v, lookup_prefix)) {
            return v;
        }

        var default_idx: ?usize = null;

        const lookup_key = v[lookup_prefix.len..];

        for (0..self.lookups.count) |idx| {
            if (std.mem.eql(u8, self.lookups.items[idx].key, lookup_default_key)) {
                default_idx = idx;
            }

            if (std.mem.eql(u8, lookup_key, self.lookups.items[idx].key)) {
                return self.lookups.items[idx].value;
            }
        }

        if (default_idx) |idx| {
            return self.lookups.items[idx].value;
        }

        return errors.ScrapliError.Driver;
    }
};

test "optionsInit" {
    const o = try Options.init(
        std.testing.allocator,
        .{},
    );

    o.deinit();
}

/// Processes the "searchable buf" for in session auth by checking if any of the auth patterns
/// show up.
pub fn processSearchableAuthBuf(
    searchable_buf: []const u8,
    compiled_prompt_pattern: ?*re.pcre2CompiledPattern,
    compiled_username_pattern: ?*re.pcre2CompiledPattern,
    compiled_password_pattern: ?*re.pcre2CompiledPattern,
    compiled_passphrase_pattern: ?*re.pcre2CompiledPattern,
) !State {
    const prompt_match = try re.pcre2Find(
        compiled_prompt_pattern.?,
        searchable_buf,
    );
    if (prompt_match != null) {
        return State.complete;
    }

    const password_match = try re.pcre2Find(
        compiled_password_pattern.?,
        searchable_buf,
    );
    if (password_match != null) {
        return State.password_prompted;
    }

    const username_match = try re.pcre2Find(
        compiled_username_pattern.?,
        searchable_buf,
    );
    if (username_match != null) {
        return State.username_prompted;
    }

    const passphrase_match = try re.pcre2Find(
        compiled_passphrase_pattern.?,
        searchable_buf,
    );
    if (passphrase_match != null) {
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

/// Checks the buf to see if any known error messages show up in the contents.
pub fn openMessageHandler(allocator: std.mem.Allocator, buf: []const u8) !?[]const u8 {
    const copied_buf = try allocator.alloc(u8, buf.len);
    defer allocator.free(copied_buf);

    @memcpy(copied_buf, buf);

    bytes.toLower(copied_buf);

    for (open_error_message_substrings) |error_substring| {
        if (std.mem.find(u8, copied_buf, error_substring[0]) != null) {
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
