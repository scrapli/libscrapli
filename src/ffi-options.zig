const std = @import("std");

const driver = @import("driver.zig");
const transport = @import("transport.zig");
const bin = @import("transport-bin.zig");
const telnet = @import("transport-telnet.zig");
const ssh2 = @import("transport-ssh2.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    // generic stuff
    variant_name: [*c]const u8,
    log: logger.Logger,
    port: u16,
    // auth
    username: [*c]const u8,
    password: [*c]const u8,
    // session
    read_size: u64,
    read_delay_min_ns: u64,
    read_delay_max_ns: u64,
    read_delay_backoff_factor: u8,
    return_char: [*c]const u8,
    username_pattern: [*c]const u8,
    password_pattern: [*c]const u8,
    passphrase_pattern: [*c]const u8,
    in_session_auth_bypass: bool,
    operation_timeout_ns: u64,
    operation_max_search_depth: u64,
    // transport
    transport_kind: [*c]const u8,
    term_width: u16,
    term_height: u16,
) driver.Options {
    var opts = driver.NewOptions();

    opts.variant_name = std.mem.span(variant_name);

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
    _ = read_size;
    _ = read_delay_min_ns;
    _ = read_delay_max_ns;
    _ = read_delay_backoff_factor;
    _ = return_char;
    _ = username_pattern;
    _ = password_pattern;
    _ = passphrase_pattern;
    _ = in_session_auth_bypass;
    _ = operation_max_search_depth;
    _ = term_width;
    _ = term_height;

    return opts;
}
