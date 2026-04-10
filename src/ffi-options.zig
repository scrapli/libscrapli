const std = @import("std");

const auth = @import("auth.zig");
const cli = @import("cli.zig");
const ffi_common = @import("ffi-common.zig");
const logging = @import("logging.zig");
const netconf = @import("netconf.zig");
const netconf_operation = @import("netconf-operation.zig");
const session = @import("session.zig");
const transport = @import("transport.zig");

fn getTransport(transport_kind: []const u8) transport.Kind {
    if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.bin),
    )) {
        return transport.Kind.bin;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.telnet),
    )) {
        return transport.Kind.telnet;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.ssh2),
    )) {
        return transport.Kind.ssh2;
    } else if (std.mem.eql(
        u8,
        transport_kind,
        @tagName(transport.Kind.test_),
    )) {
        return transport.Kind.test_;
    } else {
        // zlinter-disable-next-line no_panic - should never happen
        @panic("unsupported transport");
    }
}

// zlinter-disable no_undefined
/// An options struct that can have fields set from a calling language (i.e. py/go).
/// note: many fields are optional pointers because we cant just have ?u64 on extern struct
/// for example. so for most things zero values are acutally valid options so this way we
/// can differentiate between zero value and unset easily. strings dont have this problem
/// because we check the length -- if the length is non zero then we know it was something,
/// there shouldnt be any fields here where an empty string is a valid user input
pub const FFIOptions = extern struct {
    loggerCallback: ?*const fn (
        level: u8,
        message: *const []u8,
    ) callconv(.c) void = null,
    logger_level: [*c]const u8 = undefined,
    logger_level_len: usize = 0,

    port: ?*u16 = null,
    transport_kind: [*c]const u8 = undefined,
    transport_kind_len: usize = 0,

    cli: extern struct {
        definition_str: [*c]const u8 = undefined,
        definition_str_len: usize = 0,
    },

    netconf: extern struct {
        error_tag: [*c]const u8 = undefined,
        error_tag_len: usize = 0,
        preferred_version: [*c]const u8 = undefined,
        preferred_version_len: usize = 0,
        message_poll_interval: ?*u64 = null,
        capabilitiesCallback: ?*const fn (
            cap_buf: *[]const u8,
        ) callconv(.c) *[]const u8 = null,
    },

    session: extern struct {
        read_size: ?*u64 = null,
        read_min_delay_ns: ?*u64 = null,
        read_max_delay_ns: ?*u64 = null,
        return_char: [*c]const u8 = undefined,
        return_char_len: usize = 0,
        operation_timeout_ns: ?*u64 = null,
        operation_max_search_depth: ?*u64 = null,
        record_destination: [*c]const u8 = undefined,
        record_destination_len: usize = 0,
        recordCallback: ?*const fn (
            buf: *const []u8,
        ) callconv(.c) void = null,
    },

    auth: extern struct {
        username: [*c]const u8 = undefined,
        username_len: usize = 0,
        password: [*c]const u8 = undefined,
        password_len: usize = 0,
        private_key_path: [*c]const u8 = undefined,
        private_key_path_len: usize = 0,
        private_key_passphrase: [*c]const u8 = undefined,
        private_key_passphrase_len: usize = 0,
        lookups: extern struct {
            keys: [*c][*c]const u8 = undefined,
            key_lens: [*c]u16 = undefined,
            vals: [*c][*c]const u8 = undefined,
            val_lens: [*c]u16 = undefined,
            count: usize = 0,
        },
        force_in_session_auth: ?*bool = null,
        bypass_in_session_auth: ?*bool = null,
        username_pattern: [*c]const u8 = undefined,
        username_pattern_len: usize = 0,
        password_pattern: [*c]const u8 = undefined,
        password_pattern_len: usize = 0,
        private_key_passphrase_pattern: [*c]const u8 = undefined,
        private_key_passphrase_pattern_len: usize = 0,
    },

    transport: extern struct {
        bin: extern struct {
            bin: [*c]const u8 = undefined,
            bin_len: usize = 0,
            extra_open_args: [*c]const u8 = undefined,
            extra_open_args_len: usize = 0,
            override_open_args: [*c]const u8 = undefined,
            override_open_args_len: usize = 0,
            ssh_config_path: [*c]const u8 = undefined,
            ssh_config_path_len: usize = 0,
            known_hosts_path: [*c]const u8 = undefined,
            known_hosts_path_len: usize = 0,
            enable_strict_key: ?*bool = null,
            term_height: ?*u16 = null,
            term_width: ?*u16 = null,
        },
        ssh2: extern struct {
            known_hosts_path: [*c]const u8 = undefined,
            known_hosts_path_len: usize = 0,
            libssh2trace: ?*bool = null,
            proxy_jump_host: [*c]const u8 = undefined,
            proxy_jump_host_len: usize = 0,
            proxy_jump_port: ?*u16 = null,
            proxy_jump_username: [*c]const u8 = undefined,
            proxy_jump_username_len: usize = 0,
            proxy_jump_password: [*c]const u8 = undefined,
            proxy_jump_password_len: usize = 0,
            proxy_jump_private_key_path: [*c]const u8 = undefined,
            proxy_jump_private_key_path_len: usize = 0,
            proxy_jump_private_key_passphrase: [*c]const u8 = undefined,
            proxy_jump_private_key_passphrase_len: usize = 0,
            proxy_jump_libssh2trace: ?*bool = null,
        },
        test_: extern struct {
            f: [*c]const u8 = undefined,
            f_len: usize = 0,
        },
    },
    // zlinter-enable no_undefined

    fn authOptionsInputs(self: *FFIOptions) auth.OptionsInputs {
        var o = auth.OptionsInputs{};

        if (self.auth.username_len > 0) {
            o.username = self.auth.username[0..self.auth.username_len];
        }

        if (self.auth.password_len > 0) {
            o.password = self.auth.password[0..self.auth.password_len];
        }

        if (self.auth.private_key_path_len > 0) {
            o.private_key_path = self.auth.private_key_path[0..self.auth.private_key_path_len];
        }

        if (self.auth.private_key_passphrase_len > 0) {
            o.private_key_passphrase = self.auth.private_key_passphrase[0..self.auth.private_key_passphrase_len];
        }

        for (0..self.auth.lookups.count) |idx| {
            const key_ptr = self.auth.lookups.keys[idx];
            const key_len = self.auth.lookups.key_lens[idx];
            const val_ptr = self.auth.lookups.vals[idx];
            const val_len = self.auth.lookups.val_lens[idx];

            o.lookups.items[idx] = .{
                .key = key_ptr[0..key_len],
                .value = val_ptr[0..val_len],
            };
        }

        o.lookups.count = self.auth.lookups.count;

        if (self.auth.force_in_session_auth) |v| {
            o.force_in_session_auth = v.*;
        }

        if (self.auth.bypass_in_session_auth) |v| {
            o.bypass_in_session_auth = v.*;
        }

        if (self.auth.username_pattern_len > 0) {
            o.username_pattern = self.auth.username_pattern[0..self.auth.username_pattern_len];
        }

        if (self.auth.password_pattern_len > 0) {
            o.password_pattern = self.auth.password_pattern[0..self.auth.password_pattern_len];
        }

        if (self.auth.private_key_passphrase_pattern_len > 0) {
            o.private_key_passphrase_pattern = self.auth.private_key_passphrase_pattern[0..self.auth.private_key_passphrase_pattern_len];
        }

        return o;
    }

    fn sessionOptionsInputs(self: *FFIOptions) session.OptionsInputs {
        var o = session.OptionsInputs{};

        if (self.session.read_size) |d| {
            o.read_size = d.*;
        }

        if (self.session.read_min_delay_ns) |d| {
            o.read_min_delay_ns = d.*;
        }

        if (self.session.read_max_delay_ns) |d| {
            o.read_max_delay_ns = d.*;
        }

        if (self.session.return_char_len > 0) {
            o.return_char = self.session.return_char[0..self.session.return_char_len];
        }

        if (self.session.operation_timeout_ns) |d| {
            o.operation_timeout_ns = d.*;
        }

        if (self.session.operation_max_search_depth) |d| {
            o.operation_max_search_depth = d.*;
        }

        if (self.session.record_destination_len > 0) {
            o.record_destination = .{
                .f = self.session.record_destination[0..self.session.record_destination_len],
            };
        } else if (self.session.recordCallback) |cb| {
            o.record_destination = .{
                .cb = cb,
            };
        }

        return o;
    }

    fn transportOptionsInputs(self: *FFIOptions) transport.OptionsInputs {
        switch (getTransport(self.transport_kind[0..self.transport_kind_len])) {
            transport.Kind.bin => {
                var o = transport.OptionsInputs{
                    .bin = .{},
                };

                if (self.transport.bin.bin_len > 0) {
                    o.bin.bin = self.transport.bin.bin[0..self.transport.bin.bin_len];
                }

                if (self.transport.bin.extra_open_args_len > 0) {
                    o.bin.extra_open_args = self.transport.bin.extra_open_args[0..self.transport.bin.extra_open_args_len];
                }

                if (self.transport.bin.override_open_args_len > 0) {
                    o.bin.override_open_args = self.transport.bin.override_open_args[0..self.transport.bin.override_open_args_len];
                }

                if (self.transport.bin.ssh_config_path_len > 0) {
                    o.bin.ssh_config_path = self.transport.bin.ssh_config_path[0..self.transport.bin.ssh_config_path_len];
                }

                if (self.transport.bin.known_hosts_path_len > 0) {
                    o.bin.known_hosts_path = self.transport.bin.known_hosts_path[0..self.transport.bin.known_hosts_path_len];
                }

                if (self.transport.bin.enable_strict_key) |v| {
                    o.bin.enable_strict_key = v.*;
                }

                if (self.transport.bin.term_height) |v| {
                    o.bin.term_height = v.*;
                }

                if (self.transport.bin.term_width) |v| {
                    o.bin.term_width = v.*;
                }

                return o;
            },
            transport.Kind.ssh2 => {
                var o = transport.OptionsInputs{
                    .ssh2 = .{},
                };

                if (self.transport.ssh2.known_hosts_path_len > 0) {
                    o.ssh2.known_hosts_path = self.transport.ssh2.known_hosts_path[0..self.transport.ssh2.known_hosts_path_len];
                }

                if (self.transport.ssh2.libssh2trace) |v| {
                    o.ssh2.libssh2_trace = v.*;
                }

                if (self.transport.ssh2.proxy_jump_host_len > 0) {
                    o.ssh2.proxy_jump_options = .{
                        .host = self.transport.ssh2.proxy_jump_host[0..self.transport.ssh2.proxy_jump_host_len],
                    };
                }

                if (self.transport.ssh2.proxy_jump_port) |v| {
                    o.ssh2.proxy_jump_options.?.port = v.*;
                }

                if (self.transport.ssh2.proxy_jump_username_len > 0) {
                    o.ssh2.proxy_jump_options.?.username = self.transport.ssh2.proxy_jump_username[0..self.transport.ssh2.proxy_jump_username_len];
                }

                if (self.transport.ssh2.proxy_jump_password_len > 0) {
                    o.ssh2.proxy_jump_options.?.password = self.transport.ssh2.proxy_jump_password[0..self.transport.ssh2.proxy_jump_password_len];
                }

                if (self.transport.ssh2.proxy_jump_private_key_path_len > 0) {
                    o.ssh2.proxy_jump_options.?.private_key_path = self.transport.ssh2.proxy_jump_private_key_path[0..self.transport.ssh2.proxy_jump_private_key_path_len];
                }

                if (self.transport.ssh2.proxy_jump_private_key_passphrase_len > 0) {
                    o.ssh2.proxy_jump_options.?.private_key_passphrase = self.transport.ssh2.proxy_jump_private_key_passphrase[0..self.transport.ssh2.proxy_jump_private_key_passphrase_len];
                }

                if (self.transport.ssh2.proxy_jump_libssh2trace) |v| {
                    o.ssh2.proxy_jump_options.?.libssh2_trace = v.*;
                }

                return o;
            },
            transport.Kind.test_ => {
                var o = transport.OptionsInputs{
                    .test_ = .{},
                };

                if (self.transport.test_.f_len > 0) {
                    o.test_.f = self.transport.test_.f[0..self.transport.test_.f_len];
                }

                return o;
            },
            transport.Kind.telnet => {
                return transport.OptionsInputs{
                    .telnet = .{},
                };
            },
        }
    }

    /// Returns a cli config from this ffi options struct.
    pub fn cliConfig(self: *FFIOptions, allocator: std.mem.Allocator) cli.Config {
        var l: ?logging.Logger = null;
        if (self.loggerCallback) |cb| {
            l = logging.Logger{
                .allocator = allocator,
                .f = cb,
                .level = logging.LogLevel.fromString(
                    self.logger_level[0..self.logger_level_len],
                ),
            };
        }

        return cli.Config{
            .logger = l,
            .definition = .{
                .string = self.cli.definition_str[0..self.cli.definition_str_len],
            },
            .port = if (self.port) |v| v.* else null,
            .auth = self.authOptionsInputs(),
            .session = self.sessionOptionsInputs(),
            .transport = self.transportOptionsInputs(),
        };
    }

    /// Returns a netconf config from this ffi options struct.
    pub fn netconfConfig(self: *FFIOptions, allocator: std.mem.Allocator) netconf.Config {
        var l: ?logging.Logger = null;
        if (self.loggerCallback) |cb| {
            l = logging.Logger{
                .allocator = allocator,
                .f = cb,
                .level = logging.LogLevel.fromString(
                    self.logger_level[0..self.logger_level_len],
                ),
            };
        }

        var c = netconf.Config{
            .logger = l,
            .port = if (self.port) |v| v.* else null,
            .auth = self.authOptionsInputs(),
            .session = self.sessionOptionsInputs(),
            .transport = self.transportOptionsInputs(),
            .capabilities_callback = if (self.netconf.capabilitiesCallback) |cb| .{
                .ffi = cb,
            } else null,
        };

        if (self.netconf.error_tag_len > 0) {
            c.error_tag = self.netconf.error_tag[0..self.netconf.error_tag_len];
        }

        if (self.netconf.preferred_version_len > 0) {
            if (std.mem.eql(
                u8,
                @tagName(netconf_operation.Version.version_1_0),
                self.netconf.preferred_version[0..self.netconf.preferred_version_len],
            )) {
                c.preferred_version = netconf_operation.Version.version_1_0;
            } else {
                c.preferred_version = netconf_operation.Version.version_1_1;
            }
        }

        if (self.netconf.message_poll_interval) |v| {
            c.message_poll_interval_ns = v.*;
        }

        return c;
    }
};

export fn ls_fetch_options_size(
    o_ptr: usize,
    options_json_len: *u64,
) callconv(.c) u8 {
    const o: *FFIOptions = @ptrFromInt(o_ptr);

    const allocator = ffi_common.getAllocator();

    const opt_string = ffiOptionsToJSON(allocator, o) catch {
        return 1;
    };

    defer allocator.free(opt_string);

    options_json_len.* = opt_string.len;

    return 0;
}

export fn ls_fetch_options(
    o_ptr: usize,
    options_json: *[]u8,
) callconv(.c) u8 {
    const o: *FFIOptions = @ptrFromInt(o_ptr);

    const allocator = ffi_common.getAllocator();

    const opt_string = ffiOptionsToJSON(allocator, o) catch {
        return 1;
    };

    defer allocator.free(opt_string);

    @memcpy(options_json.*[0..], opt_string);

    return 0;
}

fn optU16(val: ?*const u16) ?u16 {
    return if (val) |v| v.* else null;
}

fn optU64(val: ?*const u64) ?u64 {
    return if (val) |v| v.* else null;
}

fn optBool(val: ?*const bool) ?bool {
    return if (val) |v| v.* else null;
}

fn cStr(ptr: [*c]const u8, len: usize) []const u8 {
    if (len == 0) return "";

    return ptr[0..len];
}

const ffi_options_top_level_args_json_ish_placeholder =
    \\    "logger_level": "{s}",
    \\    "transport_kind": "{s}",
    \\    "port": {any}
;

fn ffiOptionsTopLevelToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_top_level_args_json_ish_placeholder,
        .{
            cStr(o.logger_level, o.logger_level_len),
            cStr(o.transport_kind, o.transport_kind_len),
            optU16(o.port),
        },
    );
}

const ffi_options_cli_args_json_ish_placeholder =
    \\    "definition_str": "{s}"
;

fn ffiOptionsCLIToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    const raw = cStr(
        o.cli.definition_str,
        o.cli.definition_str_len,
    );

    const encoder = std.base64.standard.Encoder;

    const out_len = encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, out_len);

    _ = encoder.encode(encoded, raw);

    return std.fmt.allocPrint(
        allocator,
        ffi_options_cli_args_json_ish_placeholder,
        .{encoded},
    );
}

const ffi_options_netconf_args_json_ish_placeholder =
    \\    "error_tag": "{s}",
    \\    "preferred_version": "{s}",
    \\    "message_poll_interval": {any}
;

fn ffiOptionsNETCONFToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_netconf_args_json_ish_placeholder,
        .{
            cStr(o.netconf.error_tag, o.netconf.error_tag_len),
            cStr(o.netconf.preferred_version, o.netconf.preferred_version_len),
            optU64(o.netconf.message_poll_interval),
        },
    );
}

const ffi_options_session_args_json_ish_placeholder =
    \\    "read_size": {any},
    \\    "read_min_delay_ns": {any},
    \\    "read_max_delay_ns": {any},
    \\    "return_char": "{s}",
    \\    "operation_timeout_ns": {any},
    \\    "operation_max_search_depth": {any},
    \\    "record_destination": "{s}"
;

fn ffiOptionsSessionToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_session_args_json_ish_placeholder,
        .{
            optU64(o.session.read_size),
            optU64(o.session.read_min_delay_ns),
            optU64(o.session.read_max_delay_ns),
            cStr(o.session.return_char, o.session.return_char_len),
            optU64(o.session.operation_timeout_ns),
            optU64(o.session.operation_max_search_depth),
            cStr(o.session.record_destination, o.session.record_destination_len),
        },
    );
}

const ffi_options_auth_args_json_ish_placeholder =
    \\    "username": "{s}",
    \\    "password": "{s}",
    \\    "private_key_path": "{s}",
    \\    "private_key_passphrase": "{s}",
    \\    "force_in_session_auth": {any},
    \\    "bypass_in_session_auth": {any},
    \\    "username_pattern": "{s}",
    \\    "password_pattern": "{s}",
    \\    "private_key_passphrase_pattern": "{s}",
    \\    "lookups": {{ "count": {d} }}
;

fn ffiOptionsAuthToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_auth_args_json_ish_placeholder,
        .{
            cStr(o.auth.username, o.auth.username_len),
            cStr(o.auth.password, o.auth.password_len),
            cStr(o.auth.private_key_path, o.auth.private_key_path_len),
            cStr(o.auth.private_key_passphrase, o.auth.private_key_passphrase_len),
            optBool(o.auth.force_in_session_auth),
            optBool(o.auth.bypass_in_session_auth),
            cStr(o.auth.username_pattern, o.auth.username_pattern_len),
            cStr(o.auth.password_pattern, o.auth.password_pattern_len),
            cStr(o.auth.private_key_passphrase_pattern, o.auth.private_key_passphrase_pattern_len),
            o.auth.lookups.count,
        },
    );
}

const ffi_options_transport_bin_args_json_ish_placeholder =
    \\    "bin": "{s}",
    \\    "extra_open_args": "{s}",
    \\    "override_open_args": "{s}",
    \\    "ssh_config_path": "{s}",
    \\    "known_hosts_path": "{s}",
    \\    "enable_strict_key": {any},
    \\    "term_height": {any},
    \\    "term_width": {any}
;

fn ffiOptionsTransportBinToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_transport_bin_args_json_ish_placeholder,
        .{
            cStr(o.transport.bin.bin, o.transport.bin.bin_len),
            cStr(o.transport.bin.extra_open_args, o.transport.bin.extra_open_args_len),
            cStr(o.transport.bin.override_open_args, o.transport.bin.override_open_args_len),
            cStr(o.transport.bin.ssh_config_path, o.transport.bin.ssh_config_path_len),
            cStr(o.transport.bin.known_hosts_path, o.transport.bin.known_hosts_path_len),
            optBool(o.transport.bin.enable_strict_key),
            optU16(o.transport.bin.term_height),
            optU16(o.transport.bin.term_width),
        },
    );
}

const ffi_options_transport_ssh2_args_json_ish_placeholder =
    \\    "known_hosts_path": "{s}",
    \\    "libssh2trace": {any},
    \\    "proxy_jump_host": "{s}",
    \\    "proxy_jump_port": {any},
    \\    "proxy_jump_username": "{s}",
    \\    "proxy_jump_password": "{s}",
    \\    "proxy_jump_private_key_path": "{s}",
    \\    "proxy_jump_private_key_passphrase": "{s}",
    \\    "proxy_jump_libssh2trace": {any}
;

fn ffiOptionsTransportSSH2ToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_transport_ssh2_args_json_ish_placeholder,
        .{
            cStr(o.transport.ssh2.known_hosts_path, o.transport.ssh2.known_hosts_path_len),
            optBool(o.transport.ssh2.libssh2trace),
            cStr(o.transport.ssh2.proxy_jump_host, o.transport.ssh2.proxy_jump_host_len),
            optU16(o.transport.ssh2.proxy_jump_port),
            cStr(o.transport.ssh2.proxy_jump_username, o.transport.ssh2.proxy_jump_username_len),
            cStr(o.transport.ssh2.proxy_jump_password, o.transport.ssh2.proxy_jump_password_len),
            cStr(o.transport.ssh2.proxy_jump_private_key_path, o.transport.ssh2.proxy_jump_private_key_path_len),
            cStr(o.transport.ssh2.proxy_jump_private_key_passphrase, o.transport.ssh2.proxy_jump_private_key_passphrase_len),
            optBool(o.transport.ssh2.proxy_jump_libssh2trace),
        },
    );
}

const ffi_options_transport_test_args_json_ish_placeholder =
    \\    "f": "{s}"
;

fn ffiOptionsTransportTestToJSON(allocator: std.mem.Allocator, o: *const FFIOptions) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ffi_options_transport_test_args_json_ish_placeholder,
        .{
            cStr(o.transport.test_.f, o.transport.test_.f_len),
        },
    );
}

const ffi_options_json_ish_placeholder =
    \\{{
    \\  "root": {{
    \\{s}
    \\  }},
    \\  "cli": {{
    \\{s}
    \\  }},
    \\  "netconf": {{
    \\{s}
    \\  }},
    \\  "session": {{
    \\{s}
    \\  }},
    \\  "auth": {{
    \\{s}
    \\  }},
    \\  "transportBin": {{
    \\{s}
    \\  }},
    \\  "transportSSH2": {{
    \\{s}
    \\  }},
    \\  "transportTest": {{
    \\{s}
    \\  }}
    \\}}
;

fn ffiOptionsToJSON(
    allocator: std.mem.Allocator,
    o: *const FFIOptions,
) ![]u8 {
    const top = try ffiOptionsTopLevelToJSON(allocator, o);
    defer allocator.free(top);

    const c = try ffiOptionsCLIToJSON(allocator, o);
    defer allocator.free(c);

    const n = try ffiOptionsNETCONFToJSON(allocator, o);
    defer allocator.free(n);

    const s = try ffiOptionsSessionToJSON(allocator, o);
    defer allocator.free(s);

    const a = try ffiOptionsAuthToJSON(allocator, o);
    defer allocator.free(a);

    const bt = try ffiOptionsTransportBinToJSON(allocator, o);
    defer allocator.free(bt);

    const st = try ffiOptionsTransportSSH2ToJSON(allocator, o);
    defer allocator.free(st);

    const tt = try ffiOptionsTransportTestToJSON(allocator, o);
    defer allocator.free(tt);

    const final_json = try std.fmt.allocPrint(
        allocator,
        ffi_options_json_ish_placeholder,
        .{
            top,
            c,
            n,
            s,
            a,
            bt,
            st,
            tt,
        },
    );

    return final_json;
}
