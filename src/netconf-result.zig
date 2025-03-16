const std = @import("std");
const ascii = @import("ascii.zig");
const operation = @import("netconf-operation.zig");
const netconf = @import("netconf.zig");

// dec: 35 | hex: 0x23 | "#"
const hashChar = 0x23;

// dec: 60 | hex: 0x3C | "<"
const openElementChar = 0x3C;

const rpcErrorTag = "rpc-error";
const rpcReplyTag = "rpc-reply";
const rpcErrorSeverityTag = "error-severity";
const rpcErrorSeverityWarning = "warning";
const rpcErrorSeverityError = "error";

const xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";

// https://datatracker.ietf.org/doc/html/rfc6242#section-4.2 max chunk size is 4294967295 so
// for us that is a max of 10 chars that the chunk size could be when we are parsing it out of
// raw bytes.
const maxNetconf1_1_Chunk_Size = 10;

pub fn NewResult(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    version: netconf.Version,
    error_tag: []const u8,
    operation_kind: operation.Kind,
) !*Result {
    const r = try allocator.create(Result);

    r.* = Result{
        .allocator = allocator,
        .host = host,
        .port = port,
        .version = version,
        .error_tag = error_tag,
        .operation_kind = operation_kind,
        .input = null,
        .results_raw = std.ArrayList([]const u8).init(allocator),
        .results = std.ArrayList([]const u8).init(allocator),
        .start_time_ns = std.time.nanoTimestamp(),
        .splits_ns = std.ArrayList(i128).init(allocator),
        .result_failure_indicated = false,
        .result_warning_messages = std.ArrayList([]const u8).init(allocator),
        .result_error_messages = std.ArrayList([]const u8).init(allocator),
    };

    return r;
}

pub const Result = struct {
    allocator: std.mem.Allocator,

    host: []const u8,
    port: u16,

    version: netconf.Version,
    error_tag: []const u8,

    operation_kind: operation.Kind,
    input: ?[]const u8,

    results_raw: std.ArrayList([]const u8),
    results: std.ArrayList([]const u8),

    start_time_ns: i128,
    splits_ns: std.ArrayList(i128),

    // set to true at first failure indication
    result_failure_indicated: bool,
    result_warning_messages: std.ArrayList([]const u8),
    result_error_messages: std.ArrayList([]const u8),

    pub fn deinit(
        self: *Result,
    ) void {
        if (self.input != null) {
            self.allocator.free(self.input.?);
        }

        for (self.results_raw.items) |i| {
            self.allocator.free(i);
        }

        for (self.results.items) |i| {
            self.allocator.free(i);
        }

        // important note: we *do not* deallocate warnings/errors as we hold
        // views to the original result object (what we store in the "raw result" rather
        // than copies for them! so, we only need to deinit the array list that
        // holds those pointers!

        self.results_raw.deinit();
        self.results.deinit();

        self.result_warning_messages.deinit();
        self.result_error_messages.deinit();

        self.splits_ns.deinit();

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
            if (ret[iter_idx] != openElementChar) {
                iter_idx += 1;
                continue;
            }

            // check if the message is ending so we dont go out of bounds
            if (std.mem.eql(
                u8,
                ret[iter_idx + 2 .. iter_idx + 2 + rpcReplyTag.len],
                rpcReplyTag,
            )) {
                return;
            }

            // we havent found an error message yet, see if this tag is an error message starting
            if (message_start_idx == null) {
                if (std.mem.eql(
                    u8,
                    ret[iter_idx + 1 .. iter_idx + 1 + rpcErrorTag.len],
                    rpcErrorTag,
                )) {
                    message_start_idx = iter_idx - 1;
                    iter_idx = iter_idx + 2 + rpcErrorTag.len;
                } else {
                    iter_idx += 1;
                }

                continue;
            }

            // next we can check if the message is ending, so jump ahead 2 (to include the closing
            // "/" char when checking
            if (std.mem.eql(
                u8,
                ret[iter_idx + 2 .. iter_idx + 2 + rpcErrorTag.len],
                rpcErrorTag,
            )) {
                // default to error if we failed to parse the severity from the message
                var sev: []const u8 = rpcErrorSeverityError;

                if (message_severity_start_idx != null and message_severity_end_idx != null) {
                    if (std.mem.eql(
                        u8,
                        ret[message_severity_start_idx.?..message_severity_end_idx.?],
                        rpcErrorSeverityWarning,
                    )) {
                        sev = rpcErrorSeverityWarning;
                    }
                }

                if (std.mem.eql(u8, sev, rpcErrorSeverityError)) {
                    try self.result_error_messages.append(
                        ret[message_start_idx.? .. iter_idx + rpcErrorTag.len + 3],
                    );
                } else {
                    try self.result_warning_messages.append(
                        ret[message_start_idx.? .. iter_idx + rpcErrorTag.len + 3],
                    );
                }

                message_start_idx = null;
                message_severity_start_idx = null;
                message_severity_end_idx = null;

                iter_idx += 2 + rpcErrorTag.len;

                continue;
            }

            // otherwise we just need to find the severity element
            if (std.mem.eql(
                u8,
                ret[iter_idx + 1 .. iter_idx + 1 + rpcErrorSeverityTag.len],
                rpcErrorSeverityTag,
            )) {
                message_severity_start_idx = iter_idx + 2 + rpcErrorSeverityTag.len;

                iter_idx = iter_idx + 2 + rpcErrorSeverityTag.len;

                while (true) {
                    if (ret[iter_idx] != openElementChar) {
                        iter_idx += 1;

                        continue;
                    }

                    if (std.mem.eql(
                        u8,
                        ret[iter_idx + 2 .. iter_idx + 2 + rpcErrorSeverityTag.len],
                        rpcErrorSeverityTag,
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
        ret: []const u8,
    ) !void {
        try self.splits_ns.append(std.time.nanoTimestamp());
        try self.results_raw.append(ret);

        if (std.mem.indexOf(u8, ret, self.error_tag) != null) {
            self.result_failure_indicated = true;

            try self.parseRpcErrors(ret);
        }

        switch (self.version) {
            .version_1_0 => {
                try self.recordVersion1_0(ret);
            },
            .version_1_1 => {
                try self.recordVersion1_1(ret);
            },
        }
    }

    fn recordVersion1_0(
        self: *Result,
        ret: []const u8,
    ) !void {
        var declaration_index: usize = 0;

        const _declaration_index = std.mem.indexOf(
            u8,
            ret,
            xmlDeclaration,
        );
        if (_declaration_index != null) {
            declaration_index = _declaration_index.? + xmlDeclaration.len;
        }

        const delimiter_index = std.mem.indexOf(
            u8,
            ret,
            netconf.delimiter_Version_1_0,
        );

        try self.results.append(
            try self.allocator.dupe(
                u8,
                ret[declaration_index .. delimiter_index orelse ret.len],
            ),
        );
    }

    fn recordVersion1_1(
        self: *Result,
        ret: []const u8,
    ) !void {
        // rather than deal w/ an arraylist and a bunch of allocations, we'll allocate a single
        // slice since the final parsed result will always be smaller than the heap of chunks that
        // we need to parse. we'll track what we put into it so we can allcoate a right sized slice
        // when we're done. so two allocations rather than a zillion with array list basically.
        const _parsed = try self.allocator.alloc(u8, ret.len);
        defer self.allocator.free(_parsed);

        var parsed_idx: usize = 0;

        var iter_idx: usize = 0;

        while (iter_idx < ret.len) {
            if (std.ascii.isWhitespace(ret[iter_idx])) {
                iter_idx += 1;

                continue;
            }

            if (ret[iter_idx] != hashChar) {
                // we *must* have found a hash indicating a chunk size, but we didn't something
                // is wrong
                return error.ParseNetconf11ResponseFailed;
            }

            iter_idx += 1;

            if (ret[iter_idx] == hashChar) {
                // now we've found two consequtive hash signs, indicating end of message
                break;
            }

            var chunk_size_end_idx: usize = 0;

            for (0..maxNetconf1_1_Chunk_Size) |maybe_chunk_size_idx_offset| {
                if (!std.ascii.isDigit(ret[iter_idx + maybe_chunk_size_idx_offset])) {
                    chunk_size_end_idx = iter_idx + maybe_chunk_size_idx_offset;
                    break;
                }
            }

            var chunk_size: usize = 0;

            for (iter_idx..chunk_size_end_idx) |chunk_idx| {
                chunk_size = chunk_size * 10 + (ret[chunk_idx] - '0');
            }

            // now that we processed the size, consume any whitespace up to the chunk to read;
            // first move the iter_idx past the chunk size marker, then consume cr/lf before the
            // actual chunk content (whitespace like an actual space is valid for chunks!)
            iter_idx = chunk_size_end_idx;

            while (true) {
                if (ret[iter_idx] == ascii.control_chars.cr or
                    ret[iter_idx] == ascii.control_chars.lf)
                {
                    iter_idx += 1;

                    continue;
                }

                break;
            }

            if (chunk_size == 0) {
                return error.ParseNetconf11ResponseFailed;
            }

            var counted_chunk_iter: usize = 0;
            var final_chunk_size: usize = chunk_size;

            // i despise this but it seems like we get lf+cr in both bin and ssh2 transports and
            // at least srlinux only counts one of those, so... our chunk sizing is wrong if we
            // dont account for that
            while (counted_chunk_iter < chunk_size) {
                defer counted_chunk_iter += 1;
                if (ret[iter_idx + counted_chunk_iter] == ascii.control_chars.cr) {
                    final_chunk_size += 1;

                    continue;
                }
            }

            @memcpy(
                _parsed[parsed_idx .. parsed_idx + final_chunk_size],
                ret[iter_idx .. iter_idx + final_chunk_size],
            );
            parsed_idx += final_chunk_size;

            // finally increment iter_idx past this chunk
            iter_idx += final_chunk_size;
        }

        try self.results.append(try self.allocator.dupe(u8, _parsed[0..parsed_idx]));
    }

    pub fn elapsedTimeSeconds(
        self: *Result,
    ) f64 {
        const elapsed_time_ns = self.splits_ns.items[self.splits_ns.items.len - 1] - self.start_time_ns;

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

    pub fn getResultRawLen(self: *Result) usize {
        var out_size: usize = 0;

        for (0.., self.results_raw.items) |idx, result_raw| {
            out_size += result_raw.len + 1;

            if (idx != self.results.items.len - 1) {
                // not last result, add char for newline
                out_size += 1;
            }
        }

        return out_size;
    }

    /// Returns all raw results joined on a \n char, caller owns joined string.
    pub fn getResultRaw(
        self: *Result,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const out = try allocator.alloc(u8, self.getResultRawLen());

        var cur: usize = 0;
        for (0.., self.results_raw.items) |idx, result_raw| {
            @memcpy(out[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != self.results_raw.items.len - 1) {
                out[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        return out;
    }

    pub fn getResultLen(self: *Result) usize {
        var out_size: usize = 0;

        for (0.., self.results.items) |idx, result| {
            out_size += result.len;

            if (idx != self.results.items.len - 1) {
                // not last result, add char for newline
                out_size += 1;
            }
        }

        return out_size;
    }

    /// Returns all results joined on a \n char, caller owns joined string.
    pub fn getResult(
        self: *Result,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const out = try allocator.alloc(u8, self.getResultLen());

        var cur: usize = 0;
        for (0.., self.results.items) |idx, result| {
            @memcpy(out[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != self.results.items.len - 1) {
                out[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        return out;
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
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
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
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
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
                \\ <rpc-error>
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
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
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
                \\ <rpc-error>
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

test "recordVersion1_0" {
    const cases = [_]struct {
        name: []const u8,
        result: *Result,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
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
            .expected =
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
            .name = "simple-with-delim",
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
                operation.Kind.get,
            ),
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>]]>]]>
            ,
            .expected =
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
            .name = "simple-with-declaration",
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
                operation.Kind.get,
            ),
            .input =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
            .expected =
            \\
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
            .name = "simple-with-declaration-and-delim",
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_0,
                netconf.default_rpc_error_tag,
                operation.Kind.get,
            ),
            .input =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>]]>]]>
            ,
            .expected =
            \\
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
        },
    };

    for (cases) |case| {
        defer case.result.deinit();

        // dupe otherwise deinit of result will fail freeing the input
        try case.result.record(try std.testing.allocator.dupe(u8, case.input));
        try std.testing.expectEqualStrings(
            case.expected,
            case.result.results.items[0],
        );
    }
}

test "recordVersion1_1" {
    const cases = [_]struct {
        name: []const u8,
        result: *Result,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .result = try NewResult(
                std.testing.allocator,
                "1.2.3.4",
                830,
                netconf.Version.version_1_1,
                netconf.default_rpc_error_tag,
                operation.Kind.get,
            ),
            .input =
            \\#293
            \\<?xml version="1.0"?>
            \\<rpc-reply message-id="101" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <data>
            \\  <netconf-yang xmlns="http://cisco.com/ns/yang/Cisco-IOS-XR-man-netconf-cfg">
            \\   <agent>
            \\    <ssh>
            \\     <enable></enable>
            \\    </ssh>
            \\   </agent>
            \\  </netconf-yang>
            \\ </data>
            \\</rpc-reply>
            \\
            \\##
            ,
            .expected =
            \\<?xml version="1.0"?>
            \\<rpc-reply message-id="101" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <data>
            \\  <netconf-yang xmlns="http://cisco.com/ns/yang/Cisco-IOS-XR-man-netconf-cfg">
            \\   <agent>
            \\    <ssh>
            \\     <enable></enable>
            \\    </ssh>
            \\   </agent>
            \\  </netconf-yang>
            \\ </data>
            \\</rpc-reply>
            \\
            ,
        },
    };

    for (cases) |case| {
        defer case.result.deinit();

        // dupe otherwise deinit of result will fail freeing the input
        try case.result.record(try std.testing.allocator.dupe(u8, case.input));
        try std.testing.expectEqualStrings(
            case.expected,
            case.result.results.items[0],
        );
    }
}
