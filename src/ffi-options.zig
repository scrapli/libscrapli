const std = @import("std");
const ffi_driver = @import("ffi-driver.zig");
const driver = @import("driver.zig");
const transport = @import("transport.zig");
const bin = @import("transport-bin.zig");
const telnet = @import("transport-telnet.zig");
const ssh2 = @import("transport-ssh2.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    // generic stuff
    definition_variant: [*c]const u8,
    log: logger.Logger,
    port: u16,
    // auth
    username: [*c]const u8,
    password: [*c]const u8,
    private_key_path: [*c]const u8,
    private_key_passphrase: [*c]const u8,
    in_session_auth_bypass: bool,
    username_pattern: [*c]const u8,
    password_pattern: [*c]const u8,
    passphrase_pattern: [*c]const u8,
    // session
    read_size: u64,
    read_delay_min_ns: u64,
    read_delay_max_ns: u64,
    read_delay_backoff_factor: u8,
    return_char: [*c]const u8,
    operation_timeout_ns: u64,
    operation_max_search_depth: u64,
    // transport
    transport_kind: [*c]const u8,
    // bin transport
    bin_transport_bin: [*c]const u8,
    bin_transport_extra_open_args: [*c]const [*c]const u8,
    bin_transport_override_open_args: [*c]const [*c]const u8,
    bin_transport_ssh_config_file: [*c]const u8,
    bin_transport_known_hosts_file: [*c]const u8,
    bin_transport_enable_strict_key: bool,
    bin_transport_term_width: u16,
    bin_transport_term_height: u16,
) driver.Options {
    var opts = driver.NewOptions();

    opts.variant_name = std.mem.span(definition_variant);

    opts.logger = log;
    opts.port = port;

    // transport kind will always be passed by the higher level lang as a valid string matching
    // one of the transport kinds; but before comparison cast to zig style from c style to make
    // life easy
    const _transport_kind = std.mem.span(transport_kind);

    if (std.mem.eql(u8, @tagName(transport.Kind.Bin), _transport_kind)) {
        opts.transport = bin.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.Telnet), _transport_kind)) {
        opts.transport = telnet.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.SSH2), _transport_kind)) {
        opts.transport = ssh2.NewOptions();
    }

    opts.auth.username = std.mem.span(username);
    opts.auth.password = std.mem.span(password);

    opts.session.operation_timeout_ns = operation_timeout_ns;

    // TOOD
    _ = private_key_path;
    _ = private_key_passphrase;
    _ = in_session_auth_bypass;
    _ = username_pattern;
    _ = password_pattern;
    _ = passphrase_pattern;

    _ = read_size;
    _ = read_delay_min_ns;
    _ = read_delay_max_ns;
    _ = read_delay_backoff_factor;
    _ = return_char;
    _ = operation_max_search_depth;

    _ = bin_transport_bin;
    _ = bin_transport_extra_open_args;
    _ = bin_transport_override_open_args;
    _ = bin_transport_ssh_config_file;
    _ = bin_transport_known_hosts_file;
    _ = bin_transport_enable_strict_key;
    _ = bin_transport_term_width;
    _ = bin_transport_term_height;

    return opts;
}

/// Closes the driver, does *not* free/deinit.
export fn setDriverOptionAuthUsername(
    d_ptr: usize,
    value: [*c]const u8,
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.session.auth_options.username = std.mem.span(value);

    return 0;
}
