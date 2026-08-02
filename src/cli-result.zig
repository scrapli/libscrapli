const std = @import("std");

const bytes = @import("bytes.zig");
const operation = @import("cli-operation.zig");

/// Holds options related to how a result should look.
pub const GetResultOptions = struct {
    delimiter: []const u8 = "\n",
    normalize_line_feeds: bool = true,
    normalize_trailing_whitespace: bool = true,
};

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

    /// Gets the input length, used for ensuring we have properly sized buffers when passing a
    /// result out of zig into the ffi layer.
    pub fn getInputLen(
        self: *Result,
        options: GetResultOptions,
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

    /// Gets the raw result length, used for ensuring we have properly sized buffers when passing a
    /// result out of zig into the ffi layer.
    pub fn getResultRawLen(
        self: *Result,
        options: GetResultOptions,
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
                // not last result, add spacing for the delimiter
                out_size += options.delimiter.len;
            }
        }

        return out_size;
    }

    /// Returns all raw results joined on a options.delim string, caller owns joined string.
    /// Note that this *reconstructs* the raw output from each entry's (journaled raw,
    /// processed) pair -- raw is never retained anywhere, only rebuilt on demand.
    pub fn getResultRaw(
        self: *Result,
        allocator: std.mem.Allocator,
        options: GetResultOptions,
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            try self.getResultRawLen(
                .{
                    .delimiter = options.delimiter,
                },
            ),
        );
        errdefer allocator.free(out);

        try self.getResultRawPreAllocated(out, options);

        return out;
    }

    /// Gets the result length, used for ensuring we have properly sized buffers when passing a
    /// result out of zig into the ffi layer.
    pub fn getResultLen(
        self: *Result,
        options: GetResultOptions,
    ) usize {
        return getJoinedLen(self.results.items, options);
    }

    /// Returns all results joined on options.delim string, caller owns joined string.
    pub fn getResult(
        self: *Result,
        allocator: std.mem.Allocator,
        options: GetResultOptions,
    ) ![]const u8 {
        const out = try allocator.alloc(
            u8,
            self.getResultLen(
                options,
            ),
        );

        try self.getResultPreAllocated(
            out,
            options,
        );

        return out;
    }

    /// Returns all results joined on options.delim string, but expects user to have already
    /// allocated buf to the appropriate size (hint: use getResultLen w/ the same options).
    pub fn getResultPreAllocated(
        self: *Result,
        out: []u8,
        options: GetResultOptions,
    ) !void {
        if (out.len == 0) return;

        var cur: usize = 0;

        for (0.., self.results.items) |idx, result| {
            cur = renderResult(result, options, out, cur);

            if (idx != self.results.items.len - 1) {
                for (options.delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }
    }

    /// Returns all raw results joined on options.delim string, but expects user to have already
    /// allocated buf to the appropriate size (hint: use getResultRawLen w/ the same options).
    /// Reconstructs each entry's raw from its (journaled raw, processed) pair.
    pub fn getResultRawPreAllocated(
        self: *Result,
        out: []u8,
        options: GetResultOptions,
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
                for (options.delimiter) |delimiter_char| {
                    out[cur] = delimiter_char;
                    cur += 1;
                }
            }
        }
    }
};

/// render means do line feed normalization (if set -- \r are removed) and trailing whitespace
/// normalization (if set) -- no other changes, scrapli shouldnt be messing w/ output from a
/// device in other situations (barring the ansi/ascii stuff that would already have happened).
fn renderResult(
    entry: []const u8,
    options: GetResultOptions,
    maybe_out: ?[]u8,
    start: usize,
) usize {
    const trimmed = if (options.normalize_trailing_whitespace)
        // trim leading newlines since if that exists its probably left over from the preceeding
        // input/prompt, but as the setting is *trailing whitespace* make sure we are only trimming
        // whitespace at the *end*
        std.mem.trimStart(u8, std.mem.trimEnd(u8, entry, " \t\n\r"), "\n\r")
    else
        entry;

    var cur = start;
    var idx: usize = 0;

    while (idx < trimmed.len) {
        const ch = trimmed[idx];

        if (options.normalize_line_feeds and ch == '\r') {
            // iterate past \r we are removing them
            idx += 1;

            continue;
        }

        if (options.normalize_trailing_whitespace and (ch == ' ' or ch == '\t')) {
            // cur character is whitespace -- go run up ahead and see when whitespace stops
            // and move our cursor to that position for the outer loop
            var run_end = idx;

            while (run_end < trimmed.len) : (run_end += 1) {
                const run_ch = trimmed[run_end];

                if (run_ch == ' ' or
                    run_ch == '\t' or
                    (options.normalize_line_feeds and run_ch == '\r'))
                {
                    continue;
                }

                break;
            }

            if (run_end == trimmed.len or trimmed[run_end] == '\n') {
                // end of the line or end of the full result, so we are done checking for whitespace
                // and can continue the *outer* loop while pushign the idx up past the whitespace we
                // just ran past; this shouldnt ever get hit since we do the trim at the start of
                // the func, but... just in case it can stay
                idx = run_end;

                continue;
            }

            // wasn't end of line, so write into the out buf (if provided -- it wont have been if
            // caller is just fetching length), and increment the total size cursor
            while (idx < run_end) : (idx += 1) {
                const run_ch = trimmed[idx];

                if (options.normalize_line_feeds and run_ch == '\r') {
                    continue;
                }

                if (maybe_out) |out| {
                    out[cur] = run_ch;
                }

                cur += 1;
            }

            continue;
        }

        if (maybe_out) |out| {
            out[cur] = ch;
        }

        cur += 1;
        idx += 1;
    }

    return cur;
}

fn getJoinedLen(
    items: []const []const u8,
    options: GetResultOptions,
) usize {
    var len: usize = 0;

    for (0.., items) |idx, result| {
        len = renderResult(result, options, null, len);

        if (idx != items.len - 1) {
            len += options.delimiter.len;
        }
    }

    return len;
}

test "getJoinedLen" {
    const cases = [_]struct {
        items: []const []const u8,
        options: GetResultOptions,
        expected: usize,
    }{
        .{
            // nothing to change
            .items = &.{ "foo", "bar" },
            .options = .{},
            .expected = 7,
        },
        .{
            // trailing whitespace
            .items = &.{ "foo ", "bar" },
            .options = .{},
            .expected = 7,
        },
        .{
            // crlf
            .items = &.{ "foo\x0D\x0A", "bar" },
            .options = .{},
            .expected = 7,
        },
        .{
            // crlf
            .items = &.{"\x0D\x0Afoo"},
            .options = .{},
            .expected = 3,
        },
        .{
            // trailing space
            .items = &.{"foo "},
            .options = .{},
            .expected = 3,
        },
    };

    for (cases) |case| {
        const actual = getJoinedLen(case.items, case.options);

        try std.testing.expectEqual(case.expected, actual);
    }
}

test "getResultPreservesWhitespace" {
    // this test case was created to ensure that we dont ever remove any kind of whitespace inside
    // the actual content we get from a device -- thats not something scrapli should do, it should
    // just present whatever the device gave us. we *do* trim trailing whitespace and we also do
    // line normalization and stuff but that shouldnt ever mess w/ content from the device we are
    // talking to.
    const cases = [_]struct {
        name: []const u8,
        entry: []const u8,
        options: GetResultOptions,
        expected: []const u8,
    }{
        .{
            .name = "interior tab preserved",
            .entry = "foo\tbar",
            .options = .{},
            .expected = "foo\tbar",
        },
        .{
            .name = "interior mixed whitespace preserved",
            .entry = "a \t b\r\n",
            .options = .{},
            .expected = "a \t b",
        },
        .{
            .name = "tab aligned columns preserved, trailing ws still dropped",
            .entry = "col1\t\tcol2  end \r\n",
            .options = .{},
            .expected = "col1\t\tcol2  end",
        },
        .{
            .name = "cr interleaved in whitespace run is stripped, run preserved",
            .entry = "a \r\t b",
            .options = .{},
            .expected = "a \t b",
        },
        .{
            .name = "eol trailing whitespace dropped per line",
            .entry = "line1 \t\nline2\t\n",
            .options = .{},
            .expected = "line1\nline2",
        },
        .{
            .name = "no normalization passes everything through",
            .entry = "a \t b\r\n",
            .options = .{
                .normalize_line_feeds = false,
                .normalize_trailing_whitespace = false,
            },
            .expected = "a \t b\r\n",
        },
    };

    for (cases) |case| {
        var res = try Result.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            22,
            operation.Kind.send_input,
            null,
        );
        defer res.deinit();

        try res.record(
            .{
                .rets = [2][]const u8{
                    try std.testing.allocator.dupe(u8, case.entry),
                    try std.testing.allocator.dupe(u8, case.entry),
                },
            },
        );

        const actual = try res.getResult(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        std.testing.expectEqualStrings(case.expected, actual) catch |err| {
            std.debug.print("getResultPreservesWhitespace case failed: {s}\n", .{case.name});

            return err;
        };
    }
}
