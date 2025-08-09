const std = @import("std");
const bytes = @import("bytes.zig");
const operation = @import("cli-operation.zig");

pub const Result = struct {
    allocator: std.mem.Allocator,

    host: []const u8,
    port: u16,

    operation_kind: operation.Kind,

    failed_indicators: ?std.ArrayList([]const u8),

    inputs: std.ArrayList([]const u8),

    results_raw: std.ArrayList([]const u8),
    results: std.ArrayList([]const u8),

    start_time_ns: i128,
    splits_ns: std.ArrayList(i128),

    // set to true at first failure indication, further failures would not be captured
    result_failure_indicated: bool,
    // index of the given failed when contains list so we dont need to bother managing possible
    // memory to hold the substring, < 0 means no failure
    result_failure_indicator: i16,

    /// Initializes a heap allocated Result object, this object *does not own* the failed_indicators
    /// arraylist and will *not* free any of that memory!
    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        operation_kind: operation.Kind,
        failed_indicators: ?std.ArrayList([]const u8),
    ) !*Result {
        const res = try allocator.create(Result);

        res.* = Result{
            .allocator = allocator,
            .host = host,
            .port = port,
            .operation_kind = operation_kind,
            .failed_indicators = failed_indicators,
            .inputs = std.ArrayList([]const u8).init(allocator),
            .results_raw = std.ArrayList([]const u8).init(allocator),
            .results = std.ArrayList([]const u8).init(allocator),
            .start_time_ns = std.time.nanoTimestamp(),
            .splits_ns = std.ArrayList(i128).init(allocator),
            .result_failure_indicated = false,
            .result_failure_indicator = -1,
        };

        return res;
    }

    pub fn deinit(
        self: *Result,
    ) void {
        for (self.results_raw.items) |result_raw| {
            self.allocator.free(result_raw);
        }

        for (self.results.items) |result| {
            self.allocator.free(result);
        }

        self.results_raw.deinit();
        self.results.deinit();
        self.inputs.deinit();
        self.splits_ns.deinit();

        self.allocator.destroy(self);
    }

    pub fn record(
        self: *Result,
        data: struct {
            input: []const u8 = "",
            rets: [2][]const u8,
            trim_processed: bool = true,
        },
    ) !void {
        try self.splits_ns.append(std.time.nanoTimestamp());
        try self.inputs.append(data.input);
        try self.results_raw.append(data.rets[0]);

        if (data.trim_processed) {
            // trimWhitespace allocates new memory properly sized, so we can then free
            // up the original "processed" buf (it is "processed" becuase ansi/ascii stuff is
            // removed, but we still trim whitespace to get rid of leading/trailing junk)
            const trimmed = try bytes.trimNewlineWhitespace(self.allocator, data.rets[1]);
            self.allocator.free(data.rets[1]);
            try self.results.append(trimmed);
        } else {
            try self.results.append(data.rets[1]);
        }

        if (self.failed_indicators == null) {
            return;
        }

        for (0.., self.failed_indicators.?.items) |idx, failed_when| {
            if (std.mem.indexOf(u8, self.results.items[self.results.items.len - 1], failed_when) != null) {
                self.result_failure_indicated = true;
                self.result_failure_indicator = @intCast(idx);

                // this can be slow if rets[1] is v large, and theres no reason continuing if we
                // failed, so we are done here.
                break;
            }
        }
    }

    /// Extends this Result object with the given result. Consumes the given Result.
    pub fn recordExtend(
        self: *Result,
        res: *Result,
    ) !void {
        const owned_inputs = try res.inputs.toOwnedSlice();
        defer self.allocator.free(owned_inputs);
        const owned_results_raw = try res.results_raw.toOwnedSlice();
        defer self.allocator.free(owned_results_raw);
        const owned_results = try res.results.toOwnedSlice();
        defer self.allocator.free(owned_results);

        for (0.., owned_results_raw) |idx, _| {
            try self.splits_ns.append(res.splits_ns.items[idx]);
            try self.inputs.append(owned_inputs[idx]);
            try self.results_raw.append(owned_results_raw[idx]);
            try self.results.append(owned_results[idx]);

            if (!self.result_failure_indicated and res.result_failure_indicated) {
                self.result_failure_indicated = true;
                self.result_failure_indicator = res.result_failure_indicator;
            }
        }

        res.results_raw.deinit();
        res.results.deinit();
        res.inputs.deinit();
        res.splits_ns.deinit();
        self.allocator.destroy(res);
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

    pub fn getInputLen(
        self: *Result,
        options: struct {
            delimiter: []const u8 = "\n",
        },
    ) usize {
        var out_size: usize = 0;

        for (0.., self.inputs.items) |idx, input| {
            out_size += input.len;

            if (idx != self.inputs.items.len - 1) {
                // not last result, add spacing for the delimiter
                out_size += options.delimiter.len;
            }
        }

        return out_size;
    }

    pub fn getResultRawLen(
        self: *Result,
        options: struct {
            delimiter: []const u8 = "\n",
        },
    ) usize {
        var out_size: usize = 0;

        for (0.., self.results_raw.items) |idx, result_raw| {
            out_size += result_raw.len;

            if (idx != self.results_raw.items.len - 1) {
                // not last result, add spacing for the delimiter
                out_size += options.delimiter.len;
            }
        }

        return out_size;
    }

    /// Returns all raw results joined on a options.delim string, caller owns joined string.
    pub fn getResultRaw(
        self: *Result,
        allocator: std.mem.Allocator,
        options: struct {
            delimiter: []const u8 = "\n",
        },
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            self.getResultRawLen(
                .{
                    .delimiter = options.delimiter,
                },
            ),
        );

        var cur: usize = 0;
        for (0.., self.results_raw.items) |idx, result_raw| {
            @memcpy(out[cur .. cur + result_raw.len], result_raw);
            cur += result_raw.len;

            if (idx != self.results_raw.items.len - 1) {
                for (options.delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        return out;
    }

    pub fn getResultLen(
        self: *Result,
        options: struct {
            delimiter: []const u8 = "\n",
        },
    ) usize {
        var out_size: usize = 0;

        for (0.., self.results.items) |idx, result| {
            out_size += result.len;

            if (idx != self.results.items.len - 1) {
                // not last result, add spacing for the delimiter
                out_size += options.delimiter.len;
            }
        }

        return out_size;
    }

    /// Returns all results joined on options.delim string, caller owns joined string.
    pub fn getResult(
        self: *Result,
        allocator: std.mem.Allocator,
        options: struct {
            delimiter: []const u8 = "\n",
        },
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            self.getResultLen(
                .{
                    .delimiter = options.delimiter,
                },
            ),
        );

        var cur: usize = 0;
        for (0.., self.results.items) |idx, result| {
            @memcpy(out[cur .. cur + result.len], result);
            cur += result.len;

            if (idx != self.results.items.len - 1) {
                for (options.delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }

        return out;
    }
};
