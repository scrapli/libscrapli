const std = @import("std");

const errors = @import("errors.zig");
const logging = @import("logging.zig");

/// Get a tcp Stream object for the given host/port.
pub fn getStream(
    io: std.Io,
    log: logging.Logger,
    cancel: ?*bool,
    start_time: std.Io.Timestamp,
    operation_timeout_ns: u64,
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

    const U = union(enum) {
        stream: ?std.Io.net.Stream,
        cancelled: errors.ScrapliError!void,
    };

    var select_buf: [2]U = undefined;
    var select = std.Io.Select(U).init(io, &select_buf);

    try select.concurrent(
        .stream,
        connectStream,
        .{
            io,
            log,
            &lookup_queue,
            host,
        },
    );

    try select.concurrent(
        .cancelled,
        handleConnectStreamCancel,
        .{
            io,
            cancel,
            start_time,
            operation_timeout_ns,
        },
    );

    const result = try select.await();

    std.debug.print("RESULT > {any}\n", .{result});

    while (true) {
        const cancelled_result = select.cancel();

        if (cancelled_result) |cr| {
            switch (cr) {
                .stream => |maybe_stream| {
                    if (maybe_stream) |s| {
                        // cancelled, close the stream if it was opened
                        s.close(io);
                    }
                },
                else => {},
            }
        } else {
            break;
        }
    }

    switch (result) {
        .stream => |maybe_stream| {
            if (maybe_stream) |s| {
                return s;
            }

            return errors.ScrapliError.Transport;
        },
        .cancelled => |maybe_error| {
            try maybe_error;

            // shouldn't ever hit this because the only way the stream cancel func returns void is
            // if the io signaled cancellation, which would mean we already got the result from the
            // connect stream func, so... if we are here i guess we are in error'd territory anyway!
            return errors.ScrapliError.Transport;
        },
    }
}

fn connectStream(
    io: std.Io,
    log: logging.Logger,
    lookup_queue: *std.Io.Queue(std.Io.net.HostName.LookupResult),
    host: []const u8,
) ?std.Io.net.Stream {
    while (true) {
        const addr = lookup_queue.getOne(io) catch |err| {
            log.warn(
                "socket: failed getting next address from lookup queue for host '{s}'," ++
                    " error: {any}",
                .{
                    host,
                    err,
                },
            );

            return null;
        };

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
}

fn handleConnectStreamCancel(
    io: std.Io,
    cancel: ?*bool,
    start_time: std.Io.Timestamp,
    operation_timeout_ns: u64,
) errors.ScrapliError!void {
    while (true) {
        if (cancel != null and cancel.?.*) {
            return errors.ScrapliError.Cancelled;
        }

        if (operation_timeout_ns != 0 and
            start_time.untilNow(io, .awake).nanoseconds > operation_timeout_ns)
        {
            return errors.ScrapliError.TimeoutExceeded;
        }

        io.sleep(.fromMilliseconds(50), .awake) catch {
            // we return *nothing* here because the user didnt cancel (via the bool), this was
            // cancellation via the io interface.
            return;
        };
    }
}
