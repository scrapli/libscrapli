const std = @import("std");

const errors = @import("errors.zig");

pub fn getStream(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    var lookup_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&lookup_buf);
    var canonica_name_buf: [255]u8 = undefined;

    try io.vtable.netLookup(
        io.userdata,
        try std.Io.net.HostName.init(host),
        &lookup_queue,
        .{
            .port = port,
            .canonical_name_buffer = &canonica_name_buf,
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
                ) catch {
                    // copying this note from OG scrapli as the same thing is true here
                    // It seems that very occasionally when resolving a hostname (i.e. localhost during
                    // functional tests against vrouter devices), a v6 address family will be the first
                    // af the socket getaddrinfo returns, in this case, because the qemu hostfwd is not
                    // listening on ::1, instead only listening on 127.0.0.1 the connection will fail.
                    // Presumably this is something that can happen in real life too... something gets
                    // resolved with a v6 address but is denying connections or just not listening on
                    // that ipv6 address. This little connect wrapper is intended to deal with these
                    //  weird scenarios.

                    continue;
                };

                return stream;
            },
            .canonical_name => {
                return errors.ScrapliError.Transport;
            },
        }
    }
}
