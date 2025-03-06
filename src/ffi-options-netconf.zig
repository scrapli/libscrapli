const std = @import("std");

const driver = @import("driver-netconf.zig");
const transport = @import("transport.zig");
const bin = @import("transport-bin.zig");
const telnet = @import("transport-telnet.zig");
const ssh2 = @import("transport-ssh2.zig");
const logger = @import("logger.zig");

// TODO this should just go away, its same as the non netconf one no?
pub fn NewDriverOptionsFromAlloc(
    log: logger.Logger,
    transport_kind: [*c]const u8,
    port: u16,
    username: [*c]const u8,
    password: [*c]const u8,
    session_timeout_ns: u64,
) driver.Options {
    var opts = driver.NewOptions();

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

    // TODO TEMP
    _ = username;
    _ = password;
    // opts.auth.username = std.mem.span(username);
    // opts.auth.password = std.mem.span(password);

    opts.session.operation_timeout_ns = session_timeout_ns;

    return opts;
}
