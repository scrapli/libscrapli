const std = @import("std");

const errors = @import("errors.zig");
const logging = @import("logging.zig");

/// Get a tcp Stream object for the given host/port.
pub fn getStream(
    io: std.Io,
    log: logging.Logger,
    host: []const u8,
    port: u16,
) !std.Io.net.Stream {
    var lookup_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&lookup_buf);
    var canonical_name_buf: [255]u8 = undefined;

    try io.vtable.netLookup(
        io.userdata,
        try std.Io.net.HostName.init(host),
        &lookup_queue,
        .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buf,
        },
    );

    while (true) {
        const addr = try lookup_queue.getOne(io);

        switch (addr) {
            .address => {
                const stream = addr.address.connect(
                    io,
                    .{
                        .mode = .stream,
                        .protocol = .tcp,
                    },
                ) catch |err| {
                    log.debug(
                        "socket: failed connecting to resolved address {any} for host '{s}'," ++
                            " trying next candidate. error: {any}",
                        .{
                            addr.address,
                            host,
                            err,
                        },
                    );
                    continue;
                };

                return stream;
            },
            .canonical_name => {
                continue;
            },
        }
    }

    return errors.ScrapliError.Transport;
}
