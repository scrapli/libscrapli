const std = @import("std");

const driver = @import("driver-netconf.zig");
const transport = @import("transport.zig");
const logger = @import("logger.zig");

pub fn NewDriverOptionsFromAlloc(
    log: logger.Logger,
    transport_kind: [*c]const u8,
    port: u16,
) driver.OptionsInputs {
    var opts = driver.OptionsInputs{};

    opts.logger = log;
    opts.port = port;

    // transport kind will always be passed by the higher level lang as a valid string matching
    // one of the transport kinds; but before comparison cast to zig style from c style to make
    // life easy
    const _transport_kind = std.mem.span(transport_kind);

    if (std.mem.eql(u8, @tagName(transport.Kind.Bin), _transport_kind)) {
        opts.transport = .{ .Bin = .{} };
    } else if (std.mem.eql(u8, @tagName(transport.Kind.SSH2), _transport_kind)) {
        opts.transport = .{ .SSH2 = .{} };
    }

    return opts;
}
