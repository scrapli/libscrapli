const std = @import("std");

const ascii = @import("ascii.zig");
const operation = @import("netconf-operation.zig");

const rpc_error_tag = "rpc-error";
const rpc_reply_tag = "rpc-reply";
const rpc_error_severity_tag = "error-severity";
const rpc_error_severity_warning = "warning";
const rpc_error_severity_error = "error";

const subscription_id_close_tag = "</subscription-id>";

pub fn getSubscriptionId(buf: []const u8) !?u64 {
    const index_of_subscription_id = std.mem.indexOf(
        u8,
        buf,
        subscription_id_close_tag,
    );

    if (index_of_subscription_id == null) {
        return null;
    }

    // max should be uint32, so 10 chars covers that
    var _idx: usize = 0;
    var _id_buf: [10]u8 = undefined;

    for (0..10) |idx| {
        const reverse_idx = index_of_subscription_id.? - 1 - idx;

        if (!std.ascii.isDigit(buf[reverse_idx])) {
            break;
        }

        _id_buf[_idx] = buf[reverse_idx];
        _idx += 1;
    }

    var _id_buf_left: usize = 0;
    var _id_buf_right = _idx;

    while (_id_buf_left < _id_buf_right) {
        _id_buf_right -= 1;
        const tmp = _id_buf[_id_buf_left];
        _id_buf[_id_buf_left] = _id_buf[_id_buf_right];
        _id_buf[_id_buf_right] = tmp;
        _id_buf_left += 1;
    }

    return try std.fmt.parseInt(u64, _id_buf[0.._idx], 10);
}

test "getSubscriptionId" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?u64 = null,
    }{
        .{
            .name = "simple-no-subscription-id",
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
        },
        .{
            .name = "simple-no-subscription-id",
            .input =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><subscription-result xmlns='urn:ietf:params:xml:ns:yang:ietf-event-notifications' xmlns:notif-bis="urn:ietf:params:xml:ns:yang:ietf-event-notifications">notif-bis:ok</subscription-result>
            \\<subscription-id xmlns='urn:ietf:params:xml:ns:yang:ietf-event-notifications'>2147483728</subscription-id>
            \\</rpc-reply>
            ,
            .expected = 2147483728,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, try getSubscriptionId(case.input));
    }
}

/// Holds result information for Netconf opereations.
pub const Result = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    host: []const u8,
    port: u16,

    version: operation.Version,
    error_tag: []const u8,

    operation_kind: operation.Kind,
    input: []const u8,

    result_raw: []const u8,
    result: []const u8,

    start_time_ns: i128,
    end_time_ns: i128,

    // set to true at first failure indication
    result_failure_indicated: bool,
    result_warning_messages: std.ArrayList([]const u8),
    result_error_messages: std.ArrayList([]const u8),

    /// Initializes the result object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        version: operation.Version,
        error_tag: []const u8,
        input: []const u8,
        operation_kind: operation.Kind,
    ) !*Result {
        const now = try std.Io.Clock.real.now(io);

        const r = try allocator.create(Result);

        r.* = Result{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = port,
            .version = version,
            .error_tag = error_tag,
            .operation_kind = operation_kind,
            .input = input,
            .result_raw = "",
            .result = "",
            .start_time_ns = now.toNanoseconds(),
            .end_time_ns = 0,
            .result_failure_indicated = false,
            .result_warning_messages = .{},
            .result_error_messages = .{},
        };

        return r;
    }

    /// Deinitializes the reuslt object freeing all allocated bits.
    pub fn deinit(
        self: *Result,
    ) void {
        self.allocator.free(self.input);

        self.allocator.free(self.result_raw);
        self.allocator.free(self.result);

        // important note: we *do not* deallocate warnings/errors as we hold
        // views to the original result object (what we store in the "raw result" rather
        // than copies for them! so, we only need to deinit the array list that
        // holds those pointers!

        self.result_warning_messages.deinit(self.allocator);
        self.result_error_messages.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    fn parseRpcErrors(
        self: *Result,
        ret: []const u8,
    ) !void {
        // we dont want to regex and we dont want to load a full document, so we'll do a single
        // forward pass through to find all errors, once we see a "rpc-error" open tag we will start
        // "looking" for the severity to know which bucket to dump the error in.
        var iter_idx: usize = 0;
        var message_start_idx: ?usize = null;
        var message_severity_start_idx: ?usize = null;
        var message_severity_end_idx: ?usize = null;

        while (iter_idx < ret.len) {
            if (ret[iter_idx] != ascii.control_chars.open_element_char) {
                iter_idx += 1;
                continue;
            }

            // check if the message is ending so we dont go out of bounds
            if (std.mem.eql(
                u8,
                ret[iter_idx + 2 .. iter_idx + 2 + rpc_reply_tag.len],
                rpc_reply_tag,
            )) {
                return;
            }

            // we havent found an error message yet, see if this tag is an error message starting
            if (message_start_idx == null) {
                if (std.mem.eql(
                    u8,
                    ret[iter_idx + 1 .. iter_idx + 1 + rpc_error_tag.len],
                    rpc_error_tag,
                )) {
                    message_start_idx = iter_idx;
                    iter_idx = iter_idx + 2 + rpc_error_tag.len;
                } else {
                    iter_idx += 1;
                }

                continue;
            }

            // next we can check if the message is ending, so jump ahead 2 (to include the closing
            // "/" char when checking
            if (std.mem.eql(
                u8,
                ret[iter_idx + 2 .. iter_idx + 2 + rpc_error_tag.len],
                rpc_error_tag,
            )) {
                // default to error if we failed to parse the severity from the message
                var sev: []const u8 = rpc_error_severity_error;

                if (message_severity_start_idx != null and message_severity_end_idx != null) {
                    if (std.mem.eql(
                        u8,
                        ret[message_severity_start_idx.?..message_severity_end_idx.?],
                        rpc_error_severity_warning,
                    )) {
                        sev = rpc_error_severity_warning;
                    }
                }

                if (std.mem.eql(u8, sev, rpc_error_severity_error)) {
                    try self.result_error_messages.append(
                        self.allocator,
                        ret[message_start_idx.? .. iter_idx + rpc_error_tag.len + 3],
                    );
                } else {
                    try self.result_warning_messages.append(
                        self.allocator,
                        ret[message_start_idx.? .. iter_idx + rpc_error_tag.len + 3],
                    );
                }

                message_start_idx = null;
                message_severity_start_idx = null;
                message_severity_end_idx = null;

                iter_idx += 2 + rpc_error_tag.len;

                continue;
            }

            // otherwise we just need to find the severity element
            if (std.mem.eql(
                u8,
                ret[iter_idx + 1 .. iter_idx + 1 + rpc_error_severity_tag.len],
                rpc_error_severity_tag,
            )) {
                message_severity_start_idx = iter_idx + 2 + rpc_error_severity_tag.len;

                iter_idx = iter_idx + 2 + rpc_error_severity_tag.len;

                while (true) {
                    if (ret[iter_idx] != ascii.control_chars.open_element_char) {
                        iter_idx += 1;

                        continue;
                    }

                    if (std.mem.eql(
                        u8,
                        ret[iter_idx + 2 .. iter_idx + 2 + rpc_error_severity_tag.len],
                        rpc_error_severity_tag,
                    )) {
                        message_severity_end_idx = iter_idx;

                        break;
                    }
                }
            }

            iter_idx += 1;
        }
    }

    pub fn record(
        self: *Result,
        ret: [2][]const u8,
    ) !void {
        const now = try std.Io.Clock.real.now(self.io);

        self.end_time_ns = now.toNanoseconds();
        self.result_raw = ret[0];
        self.result = ret[1];

        if (std.mem.indexOf(u8, ret[1], self.error_tag) != null) {
            self.result_failure_indicated = true;

            try self.parseRpcErrors(ret[1]);
        }
    }

    pub fn elapsedTimeSeconds(
        self: *Result,
    ) f64 {
        const elapsed_time_ns = self.end_time_ns - self.start_time_ns;

        // so we get two decimal places, if the result would be 0.00, we'll manually change it
        // to 0.01 and we'll have just lost precision, no biggie, can always look at elapsed ns
        const round_mul_div = 100.0;

        // get seconds from the i128, then remainder -- do this so we avoid any (improbable as it
        // may be) overflow situations
        const secs: i128 = @divTrunc(elapsed_time_ns, std.time.ns_per_s);
        const secs_remainder: i128 = @rem(elapsed_time_ns, std.time.ns_per_s);
        const secs_fractional: f64 = @as(
            f64,
            @floatFromInt(secs_remainder),
        ) / @as(
            f64,
            @floatFromInt(std.time.ns_per_s),
        );
        const secs_fractional_rounded: f64 = @as(
            f64,
            (std.math.round(secs_fractional * round_mul_div) / round_mul_div),
        );

        var secs_rounded = @as(f64, @floatFromInt(secs)) + secs_fractional_rounded;

        if (secs_rounded == 0.00) {
            secs_rounded += 0.01;
        }

        return secs_rounded;
    }

    /// Gets the warnings size, used for ensuring we have properly sized buffers when passing a
    /// result out of zig into the ffi layer.
    pub fn getWarningsLen(self: *Result) usize {
        var out_size: usize = 0;

        for (0.., self.result_warning_messages.items) |idx, warning| {
            out_size += warning.len;

            if (idx != self.result_warning_messages.items.len - 1) {
                // not last result, add char for newline
                out_size += 1;
            }
        }

        return out_size;
    }

    /// Gets the errors size, used for ensuring we have properly sized buffers when passing a
    /// result out of zig into the ffi layer.
    pub fn getErrorsLen(self: *Result) usize {
        var out_size: usize = 0;

        for (0.., self.result_error_messages.items) |idx, err| {
            out_size += err.len;

            if (idx != self.result_error_messages.items.len - 1) {
                // not last result, add char for newline
                out_size += 1;
            }
        }

        return out_size;
    }
};

test "parseRpcErrors" {
    const cases = [_]struct {
        name: []const u8,
        result: *Result,
        input: []const u8,
        expected_warnings: []const []const u8,
        expected_errors: []const []const u8,
    }{
        .{
            .name = "simple-no-errors",
            .result = try Result.init(
                std.testing.allocator,
                std.testing.io,
                "1.2.3.4",
                830,
                .version_1_0,
                operation.default_rpc_error_tag,
                "", // important: this cant be a global const as itll panic when being freed
                //  in normal cases a user would never be setting this directly as the element
                //  will be being built by -- or even in the case of rawRpc at least wrapped in
                //  the xml heap allocated magic
                operation.Kind.get,
            ),
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
            .expected_warnings = &[_][]const u8{},
            .expected_errors = &[_][]const u8{},
        },
        .{
            .name = "simple-with-single-error",
            .result = try Result.init(
                std.testing.allocator,
                std.testing.io,
                "1.2.3.4",
                830,
                .version_1_0,
                operation.default_rpc_error_tag,
                "",
                operation.Kind.get,
            ),
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <rpc-error>
            \\   <error-type>rpc</error-type>
            \\   <error-tag>missing-attribute</error-tag>
            \\   <error-severity>error</error-severity>
            \\   <error-info>
            \\     <bad-attribute>message-id</bad-attribute>
            \\     <bad-element>rpc</bad-element>
            \\   </error-info>
            \\ </rpc-error>
            \\</rpc-reply>
            ,
            .expected_warnings = &[_][]const u8{},
            .expected_errors = &[_][]const u8{
                \\<rpc-error>
                \\   <error-type>rpc</error-type>
                \\   <error-tag>missing-attribute</error-tag>
                \\   <error-severity>error</error-severity>
                \\   <error-info>
                \\     <bad-attribute>message-id</bad-attribute>
                \\     <bad-element>rpc</bad-element>
                \\   </error-info>
                \\ </rpc-error>
            },
        },
        .{
            .name = "simple-with-single-warning",
            .result = try Result.init(
                std.testing.allocator,
                std.testing.io,
                "1.2.3.4",
                830,
                .version_1_0,
                operation.default_rpc_error_tag,
                "",
                operation.Kind.get,
            ),
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <rpc-error>
            \\   <error-type>rpc</error-type>
            \\   <error-tag>missing-attribute</error-tag>
            \\   <error-severity>warning</error-severity>
            \\   <error-info>
            \\     <bad-attribute>message-id</bad-attribute>
            \\     <bad-element>rpc</bad-element>
            \\   </error-info>
            \\ </rpc-error>
            \\</rpc-reply>
            ,
            .expected_warnings = &[_][]const u8{
                \\<rpc-error>
                \\   <error-type>rpc</error-type>
                \\   <error-tag>missing-attribute</error-tag>
                \\   <error-severity>warning</error-severity>
                \\   <error-info>
                \\     <bad-attribute>message-id</bad-attribute>
                \\     <bad-element>rpc</bad-element>
                \\   </error-info>
                \\ </rpc-error>
                ,
            },
            .expected_errors = &[_][]const u8{},
        },
        .{
            .name = "simple-not-pretty-with-single-warning",
            .result = try Result.init(
                std.testing.allocator,
                std.testing.io,
                "1.2.3.4",
                830,
                .version_1_0,
                operation.default_rpc_error_tag,
                "",
                operation.Kind.get,
            ),
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><rpc-error><error-type>application</error-type><error-tag>invalid-value</error-tag><error-severity>error</error-severity><error-message xml:lang="en">No pending confirmed commit to cancel.</error-message></rpc-error></rpc-reply>
            ,
            .expected_warnings = &[_][]const u8{},
            .expected_errors = &[_][]const u8{
                \\<rpc-error><error-type>application</error-type><error-tag>invalid-value</error-tag><error-severity>error</error-severity><error-message xml:lang="en">No pending confirmed commit to cancel.</error-message></rpc-error>
                ,
            },
        },
    };

    for (cases) |case| {
        defer case.result.deinit();

        try case.result.parseRpcErrors(case.input);

        for (0.., case.result.result_error_messages.items) |idx, actual| {
            try std.testing.expectEqualStrings(case.expected_errors[idx], actual);
        }

        for (0.., case.result.result_warning_messages.items) |idx, actual| {
            try std.testing.expectEqualStrings(case.expected_warnings[idx], actual);
        }
    }
}
