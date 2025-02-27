const std = @import("std");

const driver = @import("driver.zig");
const transport = @import("transport.zig");
const bin = @import("transport-bin.zig");
const telnet = @import("transport-telnet.zig");
const ssh2 = @import("transport-ssh2.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    variant_name: [*c]const u8,
    log: logger.Logger,
    transport_kind: [*c]const u8,
    port: u16,
    username: [*c]const u8,
    password: [*c]const u8,
    operation_timeout_ns: u64,
) driver.Options {
    var opts = driver.NewOptions();

    opts.variant_name = std.mem.span(variant_name);

    opts.logger = log;
    opts.transport.port = port;

    // transport kind will always be passed by the higher level lang as a valid string matching
    // one of the transport kinds; but before comparison cast to zig style from c style to make
    // life easy
    const _transport_kind = std.mem.span(transport_kind);

    if (std.mem.eql(u8, @tagName(transport.Kind.Bin), _transport_kind)) {
        opts.transport_implementation = bin.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.Telnet), _transport_kind)) {
        opts.transport_implementation = telnet.NewOptions();
    } else if (std.mem.eql(u8, @tagName(transport.Kind.SSH2), _transport_kind)) {
        opts.transport_implementation = ssh2.NewOptions();
    }

    opts.transport.username = std.mem.span(username);
    opts.transport.password = std.mem.span(password);

    opts.session.operation_timeout_ns = operation_timeout_ns;

    return opts;
}
