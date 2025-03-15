const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");

const logging = @import("logging.zig");
const ascii = @import("ascii.zig");

// for forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

export fn netconfPollOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_done: *bool,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    // TODO all the other netconf result stuff
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, false) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during poll operation {any}",
            .{err},
        );

        return 1;
    };

    if (!ret.done) {
        operation_done.* = false;

        return 0;
    }

    operation_done.* = true;

    if (ret.err != null) {} else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => @panic("attempting to access non netconf result from netconf type"),
        };

        operation_result_raw_size.* = dret.getResultRawLen();
        operation_result_size.* = dret.getResultLen();
    }

    return 0;
}

// TODO ofc, only needed for python sync (not go, not py async), so lower prio
export fn netconfWaitOperation(
    d_ptr: usize,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    _ = d;

    return 0;
}

export fn netconfFetchOperation(
    d_ptr: usize,
    operation_id: u32,
    operation_start_time: *u64,
    operation_end_time: *u64,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    // TODO error things, see also netconfPollOperation
) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.pollOperation(operation_id, true) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during fetch operation {any}",
            .{err},
        );

        return 1;
    };

    defer {
        const dret = switch (ret.result) {
            .netconf => |r| r,
            else => @panic("attempting to access non netconf result from netconf type"),
        };
        if (dret != null) {
            dret.?.deinit();
        }
    }

    if (ret.err != null) {} else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => @panic("attempting to access non netconf result from netconf type"),
        };

        if (dret.splits_ns.items.len > 0) {
            operation_start_time.* = @intCast(dret.start_time_ns);
            operation_end_time.* = @intCast(dret.splits_ns.items[dret.splits_ns.items.len - 1]);
        } else {
            // was a noop -- like enterMode but where mode didn't change
            operation_start_time.* = @intCast(dret.start_time_ns);
            operation_end_time.* = @intCast(dret.start_time_ns);
        }

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;
        for (0.., dret.results_raw.items) |idx, result_raw| {
            @memcpy(operation_result_raw.*[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != dret.results_raw.items.len - 1) {
                operation_result_raw.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        cur = 0;

        for (0.., dret.results.items) |idx, result| {
            @memcpy(operation_result.*[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != dret.results.items.len - 1) {
                operation_result.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }
    }

    return 0;
}

export fn netconfGetConfig(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .netconf = .{
                .get_config = .{
                    .id = 0,
                    .options = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        d.log(
            logging.LogLevel.critical,
            "error during queue getConfig {any}",
            .{err},
        );

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}
