const std = @import("std");

const bytes = @import("bytes.zig");
const operation = @import("cli-operation.zig");

const result_join_delimiter = "\n";

/// Holds result information for Cli opereations.
pub const Result = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    host: []const u8,
    port: u16,

    operation_kind: operation.Kind,

    failed_indicators: ?[]const []const u8,

    inputs: std.ArrayList([]const u8),

    results_raw_journal: std.ArrayList([]const u8),
    results: std.ArrayList([]const u8),

    start_time_ns: i128,
    splits_ns: std.ArrayList(i128),

    // set to true at first failure indication, further failures would not be captured
    result_failure_indicated: bool,
    // index of the given failed when contains list so we dont need to bother managing possible
    // memory to hold the substring, < 0 means no failure
    result_failure_indicator: i16,

    /// Initializes a heap allocated Result object, this object *does not own* the failed_indicators
    /// slice and will *not* free any of that memory!
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        operation_kind: operation.Kind,
        failed_indicators: ?[]const []const u8,
    ) !*Result {
        const res = try allocator.create(Result);

        res.* = Result{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = port,
            .operation_kind = operation_kind,
            .failed_indicators = failed_indicators,
            .inputs = .empty,
            .results_raw_journal = .empty,
            .results = .empty,
            .start_time_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
            .splits_ns = .empty,
            .result_failure_indicated = false,
            .result_failure_indicator = -1,
        };

        return res;
    }

    /// Deinitializes the Result object, freeing all heap allocated bits.
    pub fn deinit(
        self: *Result,
    ) void {
        for (self.results_raw_journal.items) |result_raw| {
            self.allocator.free(result_raw);
        }

        for (self.results.items) |result| {
            self.allocator.free(result);
        }

        for (self.inputs.items) |input| {
            self.allocator.free(input);
        }

        self.results_raw_journal.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.splits_ns.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Records an entry in the parent result.
    pub fn record(
        self: *Result,
        data: struct {
            input: []const u8 = "",
            rets: [2][]const u8,
        },
    ) !void {
        try self.splits_ns.append(self.allocator, std.Io.Timestamp.now(self.io, .real).nanoseconds);
        try self.inputs.append(self.allocator, try self.allocator.dupe(u8, data.input));
        try self.results_raw_journal.append(self.allocator, data.rets[0]);

        try self.results.append(self.allocator, data.rets[1]);

        if (self.failed_indicators == null) {
            return;
        }

        for (0.., self.failed_indicators.?) |idx, failed_when| {
            if (std.mem.find(
                u8,
                self.results.items[self.results.items.len - 1],
                failed_when,
            ) != null) {
                self.result_failure_indicated = true;
                self.result_failure_indicator = @intCast(idx);

                // this can be slow if rets[1] is v large, and theres no reason continuing if we
                // failed, so we are done here.
                return;
            }
        }
    }

    /// Extends this Result object with the given result. Consumes the given Result.
    pub fn recordExtend(
        self: *Result,
        res: *Result,
    ) !void {
        for (0.., res.results_raw_journal.items) |idx, _| {
            try self.splits_ns.append(self.allocator, res.splits_ns.items[idx]);
            try self.inputs.append(self.allocator, res.inputs.items[idx]);
            try self.results_raw_journal.append(self.allocator, res.results_raw_journal.items[idx]);
            try self.results.append(self.allocator, res.results.items[idx]);

            if (!self.result_failure_indicated and res.result_failure_indicated) {
                self.result_failure_indicated = true;
                self.result_failure_indicator = res.result_failure_indicator;
            }
        }

        res.inputs.clearRetainingCapacity();
        res.results_raw_journal.clearRetainingCapacity();
        res.results.clearRetainingCapacity();
        res.splits_ns.clearRetainingCapacity();

        res.results_raw_journal.deinit(self.allocator);
        res.results.deinit(self.allocator);
        res.inputs.deinit(self.allocator);
        res.splits_ns.deinit(self.allocator);
        self.allocator.destroy(res);
    }

    /// Returns the elapsed time in seconds.
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

    /// Gets the raw result length -- the size of all *reconstructed* raw entries joined on
    /// newlines. Used for sizing the buffer passed to getResultRawPreAllocated.
    pub fn getResultRawLen(
        self: *Result,
    ) !usize {
        var out_size: usize = 0;

        for (0.., self.results_raw_journal.items) |idx, result_raw_journal| {
            // results_raw_journal holds each entry's *journaled* raw (see bytes.zig) -- the size
            // we report would be the full size of the "reconstructed" raw output.
            out_size += try bytes.reconstructedRawLen(
                result_raw_journal,
                self.results.items[idx].len,
            );

            if (idx != self.results_raw_journal.items.len - 1) {
                out_size += result_join_delimiter.len;
            }
        }

        return out_size;
    }

    /// Returns all raw results joined on newlines, caller owns joined string. Note that this
    /// *reconstructs* the raw output from each entry's (journaled raw, processed) pair -- raw
    /// is never retained anywhere, only rebuilt on demand.
    pub fn getResultRaw(
        self: *Result,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            try self.getResultRawLen(),
        );
        errdefer allocator.free(out);

        try self.getResultRawPreAllocated(out);

        return out;
    }

    /// Returns all raw results joined on newlines, but expects user to have already allocated
    /// buf to the appropriate size (hint: use getResultRawLen). Reconstructs each entry's raw
    /// from its (journaled raw, processed) pair.
    pub fn getResultRawPreAllocated(
        self: *Result,
        out: []u8,
    ) !void {
        var cur: usize = 0;

        for (0.., self.results_raw_journal.items) |idx, result_raw_journal| {
            const entry_raw = try bytes.reconstructRaw(
                self.allocator,
                result_raw_journal,
                self.results.items[idx],
            );
            defer self.allocator.free(entry_raw);

            @memcpy(out[cur..][0..entry_raw.len], entry_raw);
            cur += entry_raw.len;

            if (idx != self.results_raw_journal.items.len - 1) {
                for (result_join_delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }
    }

    /// Gets the result length -- all entries joined on newlines. Used for sizing the buffer
    /// passed to getResultPreAllocated.
    pub fn getResultLen(
        self: *Result,
    ) usize {
        var out_size: usize = 0;

        for (0.., self.results.items) |idx, result| {
            out_size += result.len;

            if (idx != self.results.items.len - 1) {
                out_size += result_join_delimiter.len;
            }
        }

        return out_size;
    }

    /// Returns all results joined on newlines, caller owns joined string.
    pub fn getResult(
        self: *Result,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            self.getResultLen(),
        );

        self.getResultPreAllocated(out);

        return out;
    }

    /// Returns all results joined on newlines, but expects user to have already allocated buf
    /// to the appropriate size (hint: use getResultLen).
    pub fn getResultPreAllocated(
        self: *Result,
        out: []u8,
    ) void {
        var cur: usize = 0;

        for (0.., self.results.items) |idx, result| {
            @memcpy(out[cur..][0..result.len], result);
            cur += result.len;

            if (idx != self.results.items.len - 1) {
                for (result_join_delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }
    }

    /// Total size of all inputs packed back-to-back (no delimiters) -- used for sizing the ffi
    /// layer's packed input buffer.
    pub fn getInputsPackedLen(
        self: *Result,
    ) usize {
        var out_size: usize = 0;

        for (self.inputs.items) |input| {
            out_size += input.len;
        }

        return out_size;
    }

    /// Total size of all raw journals packed back-to-back (no delimiters) -- used for sizing the
    /// ffi layer's packed raw journal buffer. Note this is the *journal* size, not the size of
    /// any reconstructed raw -- the ffi caller reconstructs raw on demand.
    pub fn getResultsRawJournalPackedLen(
        self: *Result,
    ) usize {
        var out_size: usize = 0;

        for (self.results_raw_journal.items) |result_raw_journal| {
            out_size += result_raw_journal.len;
        }

        return out_size;
    }

    /// Total size of all results packed back-to-back (no delimiters) -- used for sizing the ffi
    /// layer's packed result buffer.
    pub fn getResultsPackedLen(
        self: *Result,
    ) usize {
        var out_size: usize = 0;

        for (self.results.items) |result| {
            out_size += result.len;
        }

        return out_size;
    }

    /// Packs all inputs back-to-back into out (sized via getInputsPackedLen), recording each
    /// entry's length into lens (sized to the result count) so the caller can slice the packed
    /// buffer back apart.
    pub fn packInputs(
        self: *Result,
        out: []u8,
        lens: []u64,
    ) void {
        var cur: usize = 0;

        for (0.., self.inputs.items) |idx, input| {
            @memcpy(out[cur..][0..input.len], input);
            cur += input.len;

            lens[idx] = @intCast(input.len);
        }
    }

    /// Packs all raw journals back-to-back into out (sized via getResultsRawJournalPackedLen),
    /// recording each entry's length into lens (sized to the result count) so the caller can
    /// slice the packed buffer back apart.
    pub fn packResultsRawJournal(
        self: *Result,
        out: []u8,
        lens: []u64,
    ) void {
        var cur: usize = 0;

        for (0.., self.results_raw_journal.items) |idx, result_raw_journal| {
            @memcpy(out[cur..][0..result_raw_journal.len], result_raw_journal);
            cur += result_raw_journal.len;

            lens[idx] = @intCast(result_raw_journal.len);
        }
    }

    /// Packs all results back-to-back into out (sized via getResultsPackedLen), recording each
    /// entry's length into lens (sized to the result count) so the caller can slice the packed
    /// buffer back apart.
    pub fn packResults(
        self: *Result,
        out: []u8,
        lens: []u64,
    ) void {
        var cur: usize = 0;

        for (0.., self.results.items) |idx, result| {
            @memcpy(out[cur..][0..result.len], result);
            cur += result.len;

            lens[idx] = @intCast(result.len);
        }
    }
};

test "getResult and getResultRaw join on newlines" {
    var res = try Result.init(
        std.testing.allocator,
        std.testing.io,
        "localhost",
        22,
        operation.Kind.send_input,
        null,
    );
    defer res.deinit();

    // empty journals -> raw == result for each entry
    try res.record(
        .{
            .rets = [2][]const u8{
                try std.testing.allocator.dupe(u8, ""),
                try std.testing.allocator.dupe(u8, "foo"),
            },
        },
    );

    try res.record(
        .{
            .rets = [2][]const u8{
                try std.testing.allocator.dupe(u8, ""),
                try std.testing.allocator.dupe(u8, "bar"),
            },
        },
    );

    const actual = try res.getResult(std.testing.allocator);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("foo\nbar", actual);

    const actual_raw = try res.getResultRaw(std.testing.allocator);
    defer std.testing.allocator.free(actual_raw);

    try std.testing.expectEqualStrings("foo\nbar", actual_raw);
}
