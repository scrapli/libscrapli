const std = @import("std");

const ascii = @import("ascii.zig");
const errors = @import("errors.zig");

/// Convert all contents of buf to lower.
pub fn toLower(buf: []u8) void {
    for (buf) |*b| {
        b.* = std.ascii.toLower(b.*);
    }
}

test "toLower" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .input = "FOO",
            .expected = "foo",
        },
    };

    for (cases) |case| {
        const actual = try std.testing.allocator.alloc(u8, case.input.len);
        defer std.testing.allocator.free(actual);

        @memcpy(actual, case.input);

        toLower(actual);

        try std.testing.expectEqualStrings(
            actual,
            case.expected,
        );
    }
}

/// Return the start and end indexes of needle in the haystack -- do this "roughly" -- meaning that
/// all contents of needle must appear in order in haystack, but other chars may interleave
/// needle's chars.
pub fn roughlyContains(haystack: []const u8, needle: []const u8) [2]usize {
    if (needle.len > haystack.len) {
        return [2]usize{ 0, 0 };
    }

    const match_start_index = std.mem.find(u8, haystack, needle);
    if (match_start_index != null) {
        return [2]usize{ match_start_index.?, match_start_index.? + needle.len };
    }

    var start_index: ?usize = null;
    var end_index: usize = 0;

    var haystack_index: u64 = 0;

    needle_iter: for (needle) |needle_char| {
        var should_continue: bool = false;

        for (haystack[haystack_index..]) |haystack_char| {
            defer haystack_index += 1;

            if (needle_char == haystack_char) {
                if (start_index == null) {
                    start_index = @as(usize, haystack_index);
                }

                should_continue = true;
                continue :needle_iter;
            }
        }

        if (!should_continue) {
            return [2]usize{ 0, 0 };
        }

        start_index = null;
    }

    end_index = haystack_index;

    return [2]usize{ start_index.?, end_index };
}

test "roughlyContains" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        needle: []const u8,
        expected: [2]usize,
    }{
        .{
            .name = "simple",
            .haystack = "foo H bar I baz",
            .needle = "HI",
            .expected = [2]usize{ 4, 11 },
        },
        .{
            .name = "simple",
            .haystack = "foo H bar I baz",
            .needle = "BYE",
            .expected = [2]usize{ 0, 0 },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            roughlyContains(case.haystack, case.needle),
            case.expected,
        );
    }
}

/// Return true if needle is in haystack.
pub fn charIn(haystack: []const u8, needle: u8) bool {
    for (haystack) |haystack_char| {
        if (needle == haystack_char) {
            return true;
        }
    }

    return false;
}

test "charIn" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        needle: u8,
        expected: bool,
    }{
        .{
            .name = "simple",
            .haystack = "bar",
            .needle = 97, // "a"
            .expected = true,
        },
        .{
            .name = "simple not in",
            .haystack = "foo",
            .needle = 97, // "a"
            .expected = false,
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            charIn(case.haystack, case.needle),
            case.expected,
        );
    }
}

/// Return a view into the given buf that is depth sized at most, preferring of course the tail of
/// the buf.
pub fn getBufSearchView(
    buf: []u8,
    depth: u64,
) []u8 {
    if (buf.len < depth) {
        return buf[0..];
    }

    return buf[buf.len - depth ..];
}

// journal entries serialize as varint(pos delta) | varint(len) | content. positions are
// non-decreasing by construction, so each entry's pos is stored as the delta from the previous
// entry's pos (the first entry deltas from zero) -- deltas and lens are almost always tiny (a
// carriage return per line, a small whitespace run, etc.) so LEB128 varints keep the per entry
// overhead at ~2-3 bytes instead of a fixed 16. a nice side effect of delta encoding: out of
// order entries are unrepresentable, the decoder's position can only ever move forward.

/// Returns the number of bytes v occupies as a LEB128 varint.
fn varintLen(v: u64) usize {
    var n: usize = 1;
    var x = v;

    while (x >= 0x80) : (x >>= 7) {
        n += 1;
    }

    return n;
}

/// Writes v as a LEB128 varint into out at idx, returning the index after the written bytes.
fn writeVarint(out: []u8, idx: usize, v: u64) usize {
    var i = idx;
    var x = v;

    while (x >= 0x80) : (x >>= 7) {
        out[i] = @as(u8, @truncate(x)) | 0x80;
        i += 1;
    }

    out[i] = @truncate(x);

    return i + 1;
}

/// Reads a LEB128 varint from buf at idx, advancing idx past the read bytes. Errors on
/// truncated input or a value that would overflow u64.
fn readVarint(buf: []const u8, idx: *usize) !u64 {
    var v: u64 = 0;
    var shift: u7 = 0;

    while (true) {
        if (idx.* >= buf.len) {
            return errors.ScrapliError.Journal;
        }

        const b = buf[idx.*];
        idx.* += 1;

        if (shift == 63 and b > 1) {
            // 10th byte can only contribute a single bit for u64
            return errors.ScrapliError.Journal;
        }

        v |= @as(u64, b & 0x7F) << @intCast(shift);

        if (b & 0x80 == 0) {
            return v;
        }

        shift += 7;

        if (shift > 63) {
            return errors.ScrapliError.Journal;
        }
    }
}

const ProcessedBufRawJournalEntry = struct {
    pos: usize,
    len: usize,
};

const PendingRun = struct {
    // true means this run is whitespace that will be *kept* (appended to processed) if the
    // pending resolves as non-trailing; false means this run is journal-bound no matter what
    // (carriage returns / ansi junk that arrived behind pending whitespace)
    kept: bool,
    len: usize,
};

/// A type that holds the "raw" and "processed" buffers (array list) for scrapli session objects.
pub const ProcessedBuf = struct {
    raw: std.ArrayList(u8) = .empty,
    raw_journal: std.ArrayList(ProcessedBufRawJournalEntry) = .empty,

    pending: std.ArrayList(u8) = .empty,
    pending_runs: std.ArrayList(PendingRun) = .empty,

    processed: std.ArrayList(u8) = .empty,

    // when set, carriage returns are journaled away (rather than kept in processed) at append
    // time. off by default, probably only cli will use this, sessions opt in (via driver options).
    normalize_line_feeds: bool = false,

    // when set, whitespace (space/tab) runs that turn out to be *trailing* are journaled away
    // rather than kept. we cant know if its "trailing" till we know what comes after it though, so
    // we track it as "pending" -- along w/ any journal-bound content (carriage returns, ansi/ascii
    // junk) that shows up behind them, since *those* entries positions/order depend on whether
    // the pending whitespace ends up kept/journaled. off by default, same as normalize_line_feeds.
    normalize_trailing_whitespace: bool = false,

    /// Initialize the ProcessedBuf object.
    pub fn init() ProcessedBuf {
        return ProcessedBuf{};
    }

    /// Deinitialize the Processedbuf object.
    pub fn deinit(self: *ProcessedBuf, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.raw_journal.deinit(allocator);

        self.pending.deinit(allocator);
        self.pending_runs.deinit(allocator);

        self.processed.deinit(allocator);
    }

    fn getRawCap(n: usize) usize {
        // raw is 1/100th the size users request for "scratch" processed buf since raw only holds
        // things that we woulda stripped out of the processed buf
        return @divTrunc(n, 100);
    }

    fn getRawJournalCap(n: usize) usize {
        // raw *journal* is the index/journal of where things in raw go when rehydrating raw content
        // so this is even smaller since this is not *bytes* but indicies -- so w/ default numbers
        // its like 32_768 for scatch, then raw is 1/100 of that, then we will do half 1/10th that
        // again which gives us ~33 but obviously scaled/adjusted if/when users tweak the scrach
        // capacity.
        return @divTrunc(getRawCap(n), 10);
    }

    /// Reserve space in both buffers -- intended so that we dont have to grow from 0 when the
    /// session fires up basically.
    pub fn reserve(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        n: u64,
    ) !void {
        const cap: usize = @intCast(n);

        try self.raw.ensureTotalCapacity(allocator, getRawCap(cap));
        try self.raw_journal.ensureTotalCapacity(allocator, getRawJournalCap(cap));
        try self.processed.ensureTotalCapacity(allocator, cap);
    }

    /// Clear both the raw and processed bufs -- retain max lets us retain some space in the buffers
    /// so the idea is basically to start the bufs w/ some capacity (reserve) then never shrink them
    /// below the retained max. *But* importantly we have a *max* because if you do for example a
    /// show tech that is huge, we probably dont want to have that amount of memory just always
    /// allocated for us, so we can shrink back down to the max size.
    pub fn reset(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        retain_max: u64,
    ) !void {
        const cap: usize = @intCast(retain_max);

        try resetBuf(
            u8,
            &self.raw,
            allocator,
            getRawCap(cap),
        );

        try resetBuf(
            ProcessedBufRawJournalEntry,
            &self.raw_journal,
            allocator,
            getRawJournalCap(cap),
        );

        try resetBuf(
            u8,
            &self.processed,
            allocator,
            cap,
        );

        // pending has no fancy scratch capacity and wont ever be big so just clear w/out the
        // extra steps
        self.pending.clearRetainingCapacity();
        self.pending_runs.clearRetainingCapacity();
    }

    fn resetBuf(
        comptime T: type,
        list: *std.ArrayList(T),
        allocator: std.mem.Allocator,
        retain_max: usize,
    ) !void {
        if (list.capacity > retain_max) {
            list.clearAndFree(allocator);
            try list.ensureTotalCapacity(allocator, retain_max);

            return;
        }

        list.clearRetainingCapacity();
    }

    fn bufNeedsNormalization(
        self: *ProcessedBuf,
        buf: []u8,
    ) bool {
        if (self.normalize_line_feeds and
            std.mem.indexOfScalar(u8, buf, ascii.control_chars.cr) != null)
        {
            return true;
        }

        if (self.normalize_trailing_whitespace and
            (self.pending_runs.items.len > 0 or
                std.mem.indexOfAny(u8, buf, " \t") != null))
        {
            return true;
        }

        if (self.normalize_trailing_whitespace and
            self.processed.items.len == 0 and
            buf.len > 0 and
            buf[0] == ascii.control_chars.lf)
        {
            // a line feed arriving while processed is still empty is a *leading* line feed
            // (almost certainly left over from the preceding input/prompt) which gets journaled
            // away -- note we only need to check buf[0] here: a line feed deeper in the buf can
            // only still be "leading" if everything in front of it was whitespace/carriage
            // returns/junk, and any of those already force the processing path
            return true;
        }

        return false;
    }

    /// Append the given buf and store a journal of anything we trim/strip (ascii/ansii stuff,
    /// plus carriage returns when normalize_line_feeds is set). Called "appendWithProcessing"
    /// because it does the ascii/ansi stripping (if applicable).
    pub fn appendWithProcessing(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []u8,
    ) !void {
        const has_strippable = ascii.hasStrippableByte(buf);
        const needs_normalization = self.bufNeedsNormalization(buf);

        if (!has_strippable and !needs_normalization) {
            try self.processed.appendSlice(allocator, buf);

            return;
        }

        if (!has_strippable) {
            // nothing ansi/ascii to strip, only line feed and/or whitespace normalization
            try self.appendProcessedNormalized(allocator, buf);

            return;
        }

        var iter = ascii.AsciiAnsiControlStripIterator{
            .haystack = buf,
        };

        // the iterator compacts kept bytes in place at the front of buf as it goes, yielding
        // junk runs -- i.pos is the position of the junk in the *compacted* output, so at yield
        // time buf[0..i.pos] is final kept content. we consume kept segments as they finalize
        // (rather than all at once at .done) so that journal entries -- both the iterator's junk
        // *and* any carriage returns we journal out of the kept segments -- land at the live
        // processed position, in raw order.
        var kept_consumed: usize = 0;

        while (true) {
            switch (iter.next()) {
                .item => |i| {
                    try self.appendProcessedNormalized(allocator, buf[kept_consumed..i.pos]);
                    kept_consumed = i.pos;

                    // raw buf holds *only* the raw content, the "journal" (index kinda) thing holds
                    // where these go to repopulate a full "raw" output. if theres pending
                    // whitespace in front of this junk the junks journal position isnt knowable
                    // yet (depends how the pending resolves), so it queues behind the pending --
                    // note the pending copies the content, which matters because the iterators
                    // yielded content is only valid until the next iteration
                    if (self.pending_runs.items.len > 0) {
                        try self.pushPending(allocator, i.content, false);
                    } else {
                        try self.appendRaw(allocator, i.content);
                    }
                },
                .done => |n| {
                    try self.appendProcessedNormalized(allocator, buf[kept_consumed..n]);
                    break;
                },
            }
        }
    }

    /// Append kept bytes to processed, journaling away carriage returns (normalize_line_feeds)
    /// and trailing whitespace (normalize_trailing_whitespace). Whitespace runs cant be resolved
    /// until we see what follows them, so they (and any journal-bound content behind them) sit
    /// in pending until a line feed (whitespace was trailing, journal it) or any other content
    /// (whitespace was interior, keep it) shows up.
    fn appendProcessedNormalized(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []const u8,
    ) !void {
        var idx: usize = 0;

        while (idx < buf.len) {
            const c = buf[idx];

            if (self.normalize_trailing_whitespace and (c == ' ' or c == '\t')) {
                var run_end = idx + 1;

                while (run_end < buf.len and
                    (buf[run_end] == ' ' or buf[run_end] == '\t')) : (run_end += 1)
                {}

                try self.pushPending(allocator, buf[idx..run_end], true);

                idx = run_end;

                continue;
            }

            if (self.normalize_line_feeds and c == ascii.control_chars.cr) {
                var run_end = idx + 1;

                while (run_end < buf.len and
                    buf[run_end] == ascii.control_chars.cr) : (run_end += 1)
                {}

                if (self.pending_runs.items.len > 0) {
                    // position/order of this carriage returns journal entry depends on how the
                    // pending whitespace resolves, so queue it behind the pending
                    try self.pushPending(allocator, buf[idx..run_end], false);
                } else {
                    try self.appendRaw(allocator, buf[idx..run_end]);
                }

                idx = run_end;

                continue;
            }

            if (c == ascii.control_chars.lf and
                (self.pending_runs.items.len > 0 or
                    (self.normalize_trailing_whitespace and self.processed.items.len == 0)))
            {
                // a line feed resolves any pending whitespace as trailing (journal it) -- and if
                // processed is (still) empty after that, this is a *leading* line feed (left over
                // from the preceding input/prompt) so it gets journaled too rather than kept. we
                // only land in this branch when one of those two things is true -- a boring
                // interior line feed just flows through the plain content path below
                if (self.pending_runs.items.len > 0) {
                    try self.flushPending(allocator, false);
                }

                if (self.normalize_trailing_whitespace and self.processed.items.len == 0) {
                    var run_end = idx + 1;

                    while (run_end < buf.len and
                        buf[run_end] == ascii.control_chars.lf) : (run_end += 1)
                    {}

                    try self.appendRaw(allocator, buf[idx..run_end]);

                    idx = run_end;
                } else {
                    try self.processed.append(allocator, c);

                    idx += 1;
                }

                continue;
            }

            // any other content resolves pending whitespace: a line feed means the pending
            // whitespace was trailing (journal it), anything else means it was just normal and
            // we should retain it
            if (self.pending_runs.items.len > 0) {
                try self.flushPending(allocator, true);
            }

            // scan ahead to the next byte that needs special handling so we can append plain
            // content in slices rather than byte at a time
            var run_end = idx + 1;

            while (run_end < buf.len) : (run_end += 1) {
                const rc = buf[run_end];

                if ((self.normalize_trailing_whitespace and (rc == ' ' or rc == '\t')) or
                    (self.normalize_line_feeds and rc == ascii.control_chars.cr))
                {
                    break;
                }
            }

            try self.processed.appendSlice(allocator, buf[idx..run_end]);

            idx = run_end;
        }
    }

    /// Append content to the pending whitespace buffers -- kept indicates whether this content
    /// gets appended to processed (whitespace that may end up interior) or journaled (carriage
    /// returns / ansi junk) when the pending resolves. Merges into the previous run when the
    /// kind matches.
    fn pushPending(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        content: []const u8,
        kept: bool,
    ) !void {
        if (content.len == 0) {
            return;
        }

        try self.pending.appendSlice(allocator, content);

        if (self.pending_runs.items.len > 0) {
            const last = &self.pending_runs.items[self.pending_runs.items.len - 1];

            if (last.kept == kept) {
                last.len += content.len;

                return;
            }
        }

        try self.pending_runs.append(
            allocator,
            PendingRun{
                .kept = kept,
                .len = content.len,
            },
        );
    }

    /// Resolve the pending whitespace -- keep_whitespace true means the whitespace runs turned
    /// out to be interior (append them to processed), false means they were trailing (journal
    /// them). journal-bound runs (carriage returns/junk) are journaled either way, in raw order,
    /// at the live processed position.
    fn flushPending(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        keep_whitespace: bool,
    ) !void {
        var offset: usize = 0;

        for (self.pending_runs.items) |run| {
            const content = self.pending.items[offset..][0..run.len];

            if (run.kept and keep_whitespace) {
                try self.processed.appendSlice(allocator, content);
            } else {
                try self.appendRaw(allocator, content);
            }

            offset += run.len;
        }

        self.pending.clearRetainingCapacity();
        self.pending_runs.clearRetainingCapacity();
    }

    /// Append bytes that are kept -- i.e. the "processed" bytes -- this path is (currently?) just
    /// for netconf as we are appending directly to processed buf w/out any ascii clean up path like
    /// the cli bits do.
    pub fn appendProcessed(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []const u8,
    ) !void {
        try self.processed.appendSlice(allocator, buf);
    }

    /// Append to the raw journal -- this is (currently?) just for netconf as we are appending stuff
    /// we know that we don't want like the chunk framing and such.
    pub fn appendRaw(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []const u8,
    ) !void {
        if (buf.len == 0) {
            return;
        }

        try self.raw.appendSlice(allocator, buf);

        try self.raw_journal.append(
            allocator,
            ProcessedBufRawJournalEntry{
                .pos = self.processed.items.len,
                .len = buf.len,
            },
        );
    }

    // trims content off the right side of *processed* -- the stuff that gets trimmed gets put into
    // the journal though so the full "raw" bits can be reconstructed later.
    pub fn rightTrimProcessed(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        pos: usize,
    ) !void {
        if (pos >= self.processed.items.len) {
            return;
        }

        var raw_max_safe_entry_index: usize = 0;
        var raw_content_offset: usize = 0;

        for (self.raw_journal.items) |j| {
            if (j.pos >= pos) {
                break;
            }

            raw_content_offset += j.len;
            raw_max_safe_entry_index += 1;
        }

        const new_final_raw_len = (self.processed.items.len - pos) +
            (self.raw.items.len - raw_content_offset);

        const new_final_raw = try allocator.alloc(u8, new_final_raw_len);
        defer allocator.free(new_final_raw);

        // assemble the new final raw entry... so basically we collapse all the raw entries that
        // we had stored up to the position we are trimming and we collapse that into a single
        // entry. after that we can add the processed part that is being trimmed back in
        var new_final_raw_cur: usize = 0;
        var processed_read_idx: usize = pos;
        var post_trim_offset: usize = raw_content_offset;

        const post_trim_entries = self.raw_journal.items[raw_max_safe_entry_index..];

        for (post_trim_entries) |e| {
            const keep_len = e.pos - processed_read_idx;

            @memcpy(
                new_final_raw[new_final_raw_cur..][0..keep_len],
                self.processed.items[processed_read_idx..e.pos],
            );
            new_final_raw_cur += keep_len;
            processed_read_idx = e.pos;

            @memcpy(
                new_final_raw[new_final_raw_cur..][0..e.len],
                self.raw.items[post_trim_offset..][0..e.len],
            );
            new_final_raw_cur += e.len;
            post_trim_offset += e.len;
        }

        // remaining processed content after the last folded entry
        const tail_len = self.processed.items.len - processed_read_idx;

        @memcpy(
            new_final_raw[new_final_raw_cur..][0..tail_len],
            self.processed.items[processed_read_idx..],
        );
        new_final_raw_cur += tail_len;

        std.debug.assert(new_final_raw_cur == new_final_raw.len);

        // now its safe to cut all three, then stuff the new reshaped final raw entry in (w/ the
        // corresponding journal)
        self.processed.shrinkRetainingCapacity(pos);
        self.raw.shrinkRetainingCapacity(raw_content_offset);
        self.raw_journal.shrinkRetainingCapacity(raw_max_safe_entry_index);

        try self.raw.appendSlice(allocator, new_final_raw);
        try self.raw_journal.append(
            allocator,
            .{
                .pos = pos,
                .len = new_final_raw.len,
            },
        );
    }

    fn rawToJournaledOwnedSlice(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // size pass and fill pass must agree byte for byte, so both walk the entries the same
        // way (deltas from the previous entry's pos)
        var out_len: usize = 0;
        var prev_pos: usize = 0;

        for (self.raw_journal.items) |e| {
            out_len += varintLen(e.pos - prev_pos) + varintLen(e.len) + e.len;
            prev_pos = e.pos;
        }

        const out = try allocator.alloc(u8, out_len);

        var cur: usize = 0;
        var content_offset: usize = 0;

        prev_pos = 0;

        for (self.raw_journal.items) |e| {
            cur = writeVarint(out, cur, e.pos - prev_pos);
            prev_pos = e.pos;

            cur = writeVarint(out, cur, e.len);

            @memcpy(
                out[cur..][0..e.len],
                self.raw.items[content_offset..][0..e.len],
            );

            cur += e.len;
            content_offset += e.len;
        }

        return out;
    }

    /// Settle any in-flight normalization state before dumping -- whitespace still pending at
    /// dump time is trailing by definition (journal it), and, when normalizing trailing
    /// whitespace, any whitespace/line feeds sitting at the very end of processed get demoted
    /// into the journal too (the streaming rules keep interior line feeds, so a final trailing
    /// "\n" -- or a run of whitespace/newlines exposed by prompt removal -- only becomes
    /// journal-able once we know nothing else is coming).
    fn finalizeNormalized(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) !void {
        try self.flushPending(allocator, false);

        if (!self.normalize_trailing_whitespace) {
            return;
        }

        var end = self.processed.items.len;

        while (end > 0) : (end -= 1) {
            const c = self.processed.items[end - 1];

            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
                break;
            }
        }

        if (end < self.processed.items.len) {
            try self.rightTrimProcessed(allocator, end);
        }
    }

    /// Return the "raw" and "processed" buffers, caller owns memory.
    pub fn toOwnedSlices(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) ![2][]const u8 {
        try self.finalizeNormalized(allocator);

        const journaled_raw = try self.rawToJournaledOwnedSlice(allocator);
        errdefer allocator.free(journaled_raw);

        const processed = try self.processed.toOwnedSlice(allocator);

        self.raw.clearRetainingCapacity();
        self.raw_journal.clearRetainingCapacity();

        return [2][]const u8{ journaled_raw, processed };
    }

    /// Return owned copies of the (journaled) "raw" and "processed" buffers (caller owns the
    /// returned memory) without consuming this ProcessedBuf, so the (almost certainly) Session
    /// can continue using this object..
    pub fn dupeOwnedSlices(self: *ProcessedBuf, allocator: std.mem.Allocator) ![2][]const u8 {
        try self.finalizeNormalized(allocator);

        const journaled_raw = try self.rawToJournaledOwnedSlice(allocator);
        errdefer allocator.free(journaled_raw);

        const processed_copy = try allocator.dupe(u8, self.processed.items);

        return [2][]const u8{ journaled_raw, processed_copy };
    }
};

test "ProcessedBuf append journal" {
    const cases = [_]struct {
        name: []const u8,
        in_buf: []const u8,
        expected_processed: []const u8,
        expected_raw: []const u8,
        expected_journal: []const ProcessedBufRawJournalEntry,
    }{
        .{
            .name = "simple, no journal entry",
            .in_buf = "foo",
            .expected_processed = "foo",
            .expected_raw = "",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{},
        },
        .{
            .name = "simple journal entry remove at start",
            .in_buf = "\x1Bxfoo",
            .expected_processed = "foo",
            .expected_raw = "\x1Bx",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 0,
                    .len = 2,
                },
            },
        },
        .{
            .name = "simple journal entry remove at mid",
            .in_buf = "f\x1Bxoo",
            .expected_processed = "foo",
            .expected_raw = "\x1Bx",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 1,
                    .len = 2,
                },
            },
        },
        .{
            .name = "simple journal entry remove at end",
            .in_buf = "foo\x1Bx",
            .expected_processed = "foo",
            .expected_raw = "\x1Bx",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 3,
                    .len = 2,
                },
            },
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();

        defer pb.deinit(std.testing.allocator);

        const in_buf = try std.testing.allocator.dupe(u8, case.in_buf);
        defer std.testing.allocator.free(in_buf);

        const expected_processed = try std.testing.allocator.dupe(u8, case.expected_processed);
        defer std.testing.allocator.free(expected_processed);

        const expected_raw = try std.testing.allocator.dupe(u8, case.expected_raw);
        defer std.testing.allocator.free(expected_raw);

        try pb.appendWithProcessing(std.testing.allocator, in_buf);

        try std.testing.expectEqualStrings(expected_processed, pb.processed.items);
        try std.testing.expectEqualStrings(expected_raw, pb.raw.items);

        try std.testing.expectEqual(case.expected_journal.len, pb.raw_journal.items.len);

        for (0.., pb.raw_journal.items) |idx, i| {
            try std.testing.expectEqual(case.expected_journal[idx].pos, i.pos);
            try std.testing.expectEqual(case.expected_journal[idx].len, i.len);
        }
    }
}

test "ProcessedBuf append journal multiple appends" {
    // positions in the journal are relative to the *whole* processed buffer, not the
    // chunk being appended -- this tests that since we have some non journaled chunks
    // preceeding journaled chunks so we gotta make sure the journal positions land where we
    // expect for proper reconstruction.
    var pb = ProcessedBuf.init();

    defer pb.deinit(std.testing.allocator);

    const chunk_one = try std.testing.allocator.dupe(u8, "foo");
    defer std.testing.allocator.free(chunk_one);

    const chunk_two = try std.testing.allocator.dupe(u8, "\x1Bxbar");
    defer std.testing.allocator.free(chunk_two);

    const chunk_three = try std.testing.allocator.dupe(u8, "\x1B[0mbaz");
    defer std.testing.allocator.free(chunk_three);

    try pb.appendWithProcessing(std.testing.allocator, chunk_one);
    try pb.appendWithProcessing(std.testing.allocator, chunk_two);
    try pb.appendWithProcessing(std.testing.allocator, chunk_three);

    try std.testing.expectEqualStrings("foobarbaz", pb.processed.items);

    // two records: "\x1Bx" removed at processed pos 3, "\x1B[0m" removed at processed
    // pos 6
    const expected_raw = "\x1Bx\x1B[0m";
    const expected_journal = &[_]ProcessedBufRawJournalEntry{
        .{
            .len = 2,
            .pos = 3,
        },
        .{
            .len = 4,
            .pos = 6,
        },
    };

    try std.testing.expectEqualStrings(expected_raw, pb.raw.items);

    try std.testing.expectEqual(expected_journal.len, pb.raw_journal.items.len);

    for (0.., pb.raw_journal.items) |idx, i| {
        try std.testing.expectEqual(expected_journal[idx].pos, i.pos);
        try std.testing.expectEqual(expected_journal[idx].len, i.len);
    }
}

test "ProcessedBuf append journal normalize line feeds" {
    const cases = [_]struct {
        name: []const u8,
        in_buf: []const u8,
        expected_processed: []const u8,
        expected_raw: []const u8,
        expected_journal: []const ProcessedBufRawJournalEntry,
    }{
        .{
            .name = "simple crlf",
            .in_buf = "foo\r\nbar",
            .expected_processed = "foo\nbar",
            .expected_raw = "\r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 1 },
            },
        },
        .{
            .name = "consecutive crs coalesce to one entry",
            .in_buf = "foo\r\r\n",
            .expected_processed = "foo\n",
            .expected_raw = "\r\r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 2 },
            },
        },
        .{
            .name = "junk then cr, same pos, raw order",
            .in_buf = "foo\x1B[0m\r\nbar",
            .expected_processed = "foo\nbar",
            .expected_raw = "\x1B[0m\r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 4 },
                .{ .pos = 3, .len = 1 },
            },
        },
        .{
            .name = "cr then junk, same pos, raw order",
            .in_buf = "foo\r\x1B[0mbar",
            .expected_processed = "foobar",
            .expected_raw = "\r\x1B[0m",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 1 },
                .{ .pos = 3, .len = 4 },
            },
        },
        .{
            .name = "cr only buf",
            .in_buf = "\r",
            .expected_processed = "",
            .expected_raw = "\r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 0, .len = 1 },
            },
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();
        pb.normalize_line_feeds = true;

        defer pb.deinit(std.testing.allocator);

        const in_buf = try std.testing.allocator.dupe(u8, case.in_buf);
        defer std.testing.allocator.free(in_buf);

        try pb.appendWithProcessing(std.testing.allocator, in_buf);

        std.testing.expectEqualStrings(case.expected_processed, pb.processed.items) catch |err| {
            std.debug.print("normalize line feeds case failed: {s}\n", .{case.name});

            return err;
        };
        try std.testing.expectEqualStrings(case.expected_raw, pb.raw.items);

        try std.testing.expectEqual(case.expected_journal.len, pb.raw_journal.items.len);

        for (0.., pb.raw_journal.items) |idx, i| {
            try std.testing.expectEqual(case.expected_journal[idx].pos, i.pos);
            try std.testing.expectEqual(case.expected_journal[idx].len, i.len);
        }

        // and the whole point: the journal must reconstruct the true raw
        const owned = try pb.dupeOwnedSlices(std.testing.allocator);
        defer std.testing.allocator.free(owned[0]);
        defer std.testing.allocator.free(owned[1]);

        const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
        defer std.testing.allocator.free(reconstructed);

        std.testing.expectEqualStrings(case.in_buf, reconstructed) catch |err| {
            std.debug.print("normalize line feeds round trip failed: {s}\n", .{case.name});

            return err;
        };
    }
}

test "ProcessedBuf append journal normalize line feeds chunk boundary" {
    // a cr at the end of one chunk and its lf at the start of the next -- the cr must journal
    // at the right absolute position even though the appends are separate
    var pb = ProcessedBuf.init();
    pb.normalize_line_feeds = true;

    defer pb.deinit(std.testing.allocator);

    const chunk_one = try std.testing.allocator.dupe(u8, "foo\r");
    defer std.testing.allocator.free(chunk_one);

    const chunk_two = try std.testing.allocator.dupe(u8, "\nbar");
    defer std.testing.allocator.free(chunk_two);

    try pb.appendWithProcessing(std.testing.allocator, chunk_one);
    try pb.appendWithProcessing(std.testing.allocator, chunk_two);

    try std.testing.expectEqualStrings("foo\nbar", pb.processed.items);
    try std.testing.expectEqualStrings("\r", pb.raw.items);

    try std.testing.expectEqual(1, pb.raw_journal.items.len);
    try std.testing.expectEqual(3, pb.raw_journal.items[0].pos);
    try std.testing.expectEqual(1, pb.raw_journal.items[0].len);

    const owned = try pb.dupeOwnedSlices(std.testing.allocator);
    defer std.testing.allocator.free(owned[0]);
    defer std.testing.allocator.free(owned[1]);

    const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
    defer std.testing.allocator.free(reconstructed);

    try std.testing.expectEqualStrings("foo\r\nbar", reconstructed);
}

test "ProcessedBuf append journal normalize trailing whitespace" {
    const cases = [_]struct {
        name: []const u8,
        in_buf: []const u8,
        expected_processed: []const u8,
        expected_raw: []const u8,
        expected_journal: []const ProcessedBufRawJournalEntry,
    }{
        .{
            .name = "interior whitespace kept",
            .in_buf = "a \t b",
            .expected_processed = "a \t b",
            .expected_raw = "",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{},
        },
        .{
            .name = "eol trailing whitespace journaled per line",
            .in_buf = "line1 \t\nline2\t\nx",
            .expected_processed = "line1\nline2\nx",
            .expected_raw = " \t\t",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 5, .len = 2 },
                .{ .pos = 11, .len = 1 },
            },
        },
        .{
            .name = "trailing whitespace at dump journaled",
            .in_buf = "foo ",
            .expected_processed = "foo",
            .expected_raw = " ",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 1 },
            },
        },
        .{
            .name = "junk mid whitespace run, run kept",
            .in_buf = "a \x1B[0m b",
            .expected_processed = "a  b",
            .expected_raw = "\x1B[0m",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 2, .len = 4 },
            },
        },
        .{
            .name = "junk mid whitespace run, run trailed",
            .in_buf = "a \x1B[0m \nb",
            .expected_processed = "a\nb",
            .expected_raw = " \x1B[0m ",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 1, .len = 1 },
                .{ .pos = 1, .len = 4 },
                .{ .pos = 1, .len = 1 },
            },
        },
        .{
            .name = "cr interleaved in whitespace run is journaled, run preserved",
            .in_buf = "a \r\t b",
            .expected_processed = "a \t b",
            .expected_raw = "\r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 2, .len = 1 },
            },
        },
        .{
            .name = "crlf line ending w/ trailing whitespace",
            .in_buf = "foo \r\nbar",
            .expected_processed = "foo\nbar",
            .expected_raw = " \r",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 1 },
                .{ .pos = 3, .len = 1 },
            },
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();
        pb.normalize_line_feeds = true;
        pb.normalize_trailing_whitespace = true;

        defer pb.deinit(std.testing.allocator);

        const in_buf = try std.testing.allocator.dupe(u8, case.in_buf);
        defer std.testing.allocator.free(in_buf);

        try pb.appendWithProcessing(std.testing.allocator, in_buf);

        // dump (which resolves any still-pending whitespace as trailing) *before* asserting so
        // the buffers are in their final state -- this mirrors what record/fetch does
        const owned = try pb.dupeOwnedSlices(std.testing.allocator);
        defer std.testing.allocator.free(owned[0]);
        defer std.testing.allocator.free(owned[1]);

        std.testing.expectEqualStrings(case.expected_processed, pb.processed.items) catch |err| {
            std.debug.print("normalize trailing whitespace case failed: {s}\n", .{case.name});

            return err;
        };
        try std.testing.expectEqualStrings(case.expected_raw, pb.raw.items);

        try std.testing.expectEqual(case.expected_journal.len, pb.raw_journal.items.len);

        for (0.., pb.raw_journal.items) |idx, i| {
            try std.testing.expectEqual(case.expected_journal[idx].pos, i.pos);
            try std.testing.expectEqual(case.expected_journal[idx].len, i.len);
        }

        const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
        defer std.testing.allocator.free(reconstructed);

        std.testing.expectEqualStrings(case.in_buf, reconstructed) catch |err| {
            std.debug.print("normalize trailing whitespace round trip failed: {s}\n", .{case.name});

            return err;
        };
    }
}

test "ProcessedBuf append journal normalize trailing whitespace chunk boundaries" {
    const cases = [_]struct {
        name: []const u8,
        chunks: []const []const u8,
        expected_processed: []const u8,
    }{
        .{
            .name = "pending resolves kept across chunks",
            .chunks = &.{ "foo ", "bar" },
            .expected_processed = "foo bar",
        },
        .{
            .name = "pending resolves trailed across chunks",
            .chunks = &.{ "foo ", "\nbar" },
            .expected_processed = "foo\nbar",
        },
        .{
            // note: the trailing \n itself also journals now (final suffix demote at dump)
            .name = "pending grows across chunks then trails",
            .chunks = &.{ "foo ", "\t", "\n" },
            .expected_processed = "foo",
        },
        .{
            .name = "junk chunk lands mid pending",
            .chunks = &.{ "foo ", "\x1B[0m", " bar" },
            .expected_processed = "foo  bar",
        },
        .{
            .name = "cr chunk lands mid pending then trails",
            .chunks = &.{ "foo ", "\r", "\nbar" },
            .expected_processed = "foo\nbar",
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();
        pb.normalize_line_feeds = true;
        pb.normalize_trailing_whitespace = true;

        defer pb.deinit(std.testing.allocator);

        var expected_raw_len: usize = 0;

        for (case.chunks) |chunk| {
            const in_buf = try std.testing.allocator.dupe(u8, chunk);
            defer std.testing.allocator.free(in_buf);

            try pb.appendWithProcessing(std.testing.allocator, in_buf);

            expected_raw_len += chunk.len;
        }

        const owned = try pb.dupeOwnedSlices(std.testing.allocator);
        defer std.testing.allocator.free(owned[0]);
        defer std.testing.allocator.free(owned[1]);

        std.testing.expectEqualStrings(case.expected_processed, pb.processed.items) catch |err| {
            std.debug.print("chunk boundary case failed: {s}\n", .{case.name});

            return err;
        };

        // round trip must equal the concatenation of every chunk exactly
        const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
        defer std.testing.allocator.free(reconstructed);

        try std.testing.expectEqual(expected_raw_len, reconstructed.len);

        var reconstructed_idx: usize = 0;

        for (case.chunks) |chunk| {
            try std.testing.expectEqualStrings(
                chunk,
                reconstructed[reconstructed_idx..][0..chunk.len],
            );

            reconstructed_idx += chunk.len;
        }
    }
}

test "ProcessedBuf append journal leading and final trailing normalization" {
    const cases = [_]struct {
        name: []const u8,
        in_buf: []const u8,
        expected_processed: []const u8,
        expected_raw: []const u8,
        expected_journal: []const ProcessedBufRawJournalEntry,
    }{
        .{
            .name = "leading line feed journaled",
            .in_buf = "\nfoo",
            .expected_processed = "foo",
            .expected_raw = "\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 0, .len = 1 },
            },
        },
        .{
            .name = "leading line feed run coalesces",
            .in_buf = "\n\nfoo",
            .expected_processed = "foo",
            .expected_raw = "\n\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 0, .len = 2 },
            },
        },
        .{
            .name = "leading crlf journaled",
            .in_buf = "\r\nfoo",
            .expected_processed = "foo",
            .expected_raw = "\r\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 0, .len = 1 },
                .{ .pos = 0, .len = 1 },
            },
        },
        .{
            .name = "final trailing line feed demoted at dump",
            .in_buf = "foo\n",
            .expected_processed = "foo",
            .expected_raw = "\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 1 },
            },
        },
        .{
            // the " " journals when the \n resolves it as trailing, then the \n itself demotes
            // at dump -- the fold must keep raw order (" " before "\n")
            .name = "trailing whitespace then line feed, order preserved",
            .in_buf = "foo \n",
            .expected_processed = "foo",
            .expected_raw = " \n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 3, .len = 2 },
            },
        },
        .{
            .name = "interior line feeds kept, only final trailing run demoted",
            .in_buf = "foo\nbar\n\n",
            .expected_processed = "foo\nbar",
            .expected_raw = "\n\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{ .pos = 7, .len = 2 },
            },
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();
        pb.normalize_line_feeds = true;
        pb.normalize_trailing_whitespace = true;

        defer pb.deinit(std.testing.allocator);

        const in_buf = try std.testing.allocator.dupe(u8, case.in_buf);
        defer std.testing.allocator.free(in_buf);

        try pb.appendWithProcessing(std.testing.allocator, in_buf);

        const owned = try pb.dupeOwnedSlices(std.testing.allocator);
        defer std.testing.allocator.free(owned[0]);
        defer std.testing.allocator.free(owned[1]);

        std.testing.expectEqualStrings(case.expected_processed, pb.processed.items) catch |err| {
            std.debug.print("leading/final trailing case failed: {s}\n", .{case.name});

            return err;
        };
        try std.testing.expectEqualStrings(case.expected_raw, pb.raw.items);

        try std.testing.expectEqual(case.expected_journal.len, pb.raw_journal.items.len);

        for (0.., pb.raw_journal.items) |idx, i| {
            try std.testing.expectEqual(case.expected_journal[idx].pos, i.pos);
            try std.testing.expectEqual(case.expected_journal[idx].len, i.len);
        }

        const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
        defer std.testing.allocator.free(reconstructed);

        std.testing.expectEqualStrings(case.in_buf, reconstructed) catch |err| {
            std.debug.print("leading/final trailing round trip failed: {s}\n", .{case.name});

            return err;
        };
    }
}

test "ProcessedBuf prompt removal then final trailing demote" {
    // mimics the session flow: prompt gets demoted via rightTrimProcessed, which exposes a
    // trailing line feed that then demotes at dump -- the demote-after-demote fold must keep
    // raw order so reconstruction is exact
    var pb = ProcessedBuf.init();
    pb.normalize_line_feeds = true;
    pb.normalize_trailing_whitespace = true;

    defer pb.deinit(std.testing.allocator);

    const in_buf = try std.testing.allocator.dupe(u8, "foo\nprompt>");
    defer std.testing.allocator.free(in_buf);

    try pb.appendWithProcessing(std.testing.allocator, in_buf);

    // "remove" the trailing prompt like session does
    try pb.rightTrimProcessed(std.testing.allocator, 4);

    const owned = try pb.dupeOwnedSlices(std.testing.allocator);
    defer std.testing.allocator.free(owned[0]);
    defer std.testing.allocator.free(owned[1]);

    try std.testing.expectEqualStrings("foo", pb.processed.items);

    const reconstructed = try reconstructRaw(std.testing.allocator, owned[0], owned[1]);
    defer std.testing.allocator.free(reconstructed);

    try std.testing.expectEqualStrings("foo\nprompt>", reconstructed);
}

test "ProcessedBuf rightTrimFrom" {
    const cases = [_]struct {
        name: []const u8,
        chunks: []const []const u8,
        trim_from: usize,
        expected_processed: []const u8,
        expected_raw: []const u8,
        expected_journal: []const ProcessedBufRawJournalEntry,
    }{
        .{
            // the "retain_trailing_prompt = false" case: trim the prompt off the end,
            // that content gets tsuffed into raw w/ a journal entry where to put it when
            // doing reconstruction.
            .name = "plain suffix demote",
            .chunks = &.{"show version\nrouter#"},
            .trim_from = 13,
            .expected_processed = "show version\n",
            .expected_raw = "router#",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 13,
                    .len = 7,
                },
            },
        },
        .{
            // junk that was already journaled *inside* the demoted range must weave into
            // the demoted blob in wire order, and its old record must be gone from the
            // journal -- one record total afterwards
            .name = "suffix demote weaves existing record in range",
            .chunks = &.{ "show version\n", "\x1B[0mrouter#" },
            .trim_from = 13,
            .expected_processed = "show version\n",
            .expected_raw = "\x1B[0mrouter#",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 13,
                    .len = 11,
                },
            },
        },
        .{
            // records entirely before the demote position are untouched, byte for byte
            .name = "record before demote position survives",
            .chunks = &.{"f\x1Bxoo"},
            .trim_from = 2,
            .expected_processed = "fo",
            .expected_raw = "\x1Bxo",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 1,
                    .len = 2,
                },
                .{
                    .pos = 2,
                    .len = 1,
                },
            },
        },
        .{
            // the "retain_input = false" case: demote *everything* -- processed goes
            // empty and the journal's single record at pos 0 is the entire raw input
            .name = "demote everything",
            .chunks = &.{"show ver\x1B[K\n"},
            .trim_from = 0,
            .expected_processed = "",
            .expected_raw = "show ver\x1B[K\n",
            .expected_journal = &[_]ProcessedBufRawJournalEntry{
                .{
                    .pos = 0,
                    .len = 12,
                },
            },
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();

        defer pb.deinit(std.testing.allocator);

        for (case.chunks) |chunk| {
            const mut_chunk = try std.testing.allocator.dupe(u8, chunk);
            defer std.testing.allocator.free(mut_chunk);

            try pb.appendWithProcessing(std.testing.allocator, mut_chunk);
        }

        try pb.rightTrimProcessed(std.testing.allocator, case.trim_from);

        try std.testing.expectEqualStrings(case.expected_processed, pb.processed.items);
        try std.testing.expectEqualStrings(case.expected_raw, pb.raw.items);

        try std.testing.expectEqual(case.expected_journal.len, pb.raw_journal.items.len);

        for (0.., pb.raw_journal.items) |idx, i| {
            try std.testing.expectEqual(case.expected_journal[idx].pos, i.pos);
            try std.testing.expectEqual(case.expected_journal[idx].len, i.len);
        }
    }
}

test "ProcessedBuf buildJournalBuf" {
    // 200 chars of filler then a 2 byte escape then a keeper -- gives the buildJournalBuf test a
    // journal entry at pos 200 so the pos delta needs a multi byte varint
    const multi_byte_delta_chunk = @as([200]u8, @splat('a')) ++ [_]u8{ 0x1B, 'x', 'b' };

    const cases = [_]struct {
        name: []const u8,
        chunks: []const []const u8,
        expected_raw_journaled_buf: []const u8,
    }{
        .{
            .name = "simple - nothing journaled",
            .chunks = &.{"show version\nrouter#"},
            .expected_raw_journaled_buf = "",
        },
        .{
            // varint(pos delta 0) | varint(len 2) | content
            .name = "simple - leading raw journaled",
            .chunks = &.{"\x1Bxfoo"},
            .expected_raw_journaled_buf = "\x00\x02\x1Bx",
        },
        .{
            // pos 200 needs a two byte varint delta (0xC8 0x01 = 200 LEB128)
            .name = "multi byte varint delta",
            .chunks = &.{&multi_byte_delta_chunk},
            .expected_raw_journaled_buf = "\xC8\x01\x02\x1Bx",
        },
        .{
            // two entries -- second entry's pos stores as delta from the first
            .name = "delta between entries",
            .chunks = &.{"foo\x1Bxbar\x1Byb"},
            .expected_raw_journaled_buf = "\x03\x02\x1Bx\x03\x02\x1By",
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();

        defer pb.deinit(std.testing.allocator);

        for (case.chunks) |chunk| {
            const mut_chunk = try std.testing.allocator.dupe(u8, chunk);
            defer std.testing.allocator.free(mut_chunk);

            try pb.appendWithProcessing(std.testing.allocator, mut_chunk);
        }

        const owned_bufs = try pb.toOwnedSlices(std.testing.allocator);

        defer std.testing.allocator.free(owned_bufs[0]);
        std.testing.allocator.free(owned_bufs[1]);

        try std.testing.expectEqualStrings(case.expected_raw_journaled_buf, owned_bufs[0]);
    }
}

test "reconstructRaw round trip" {
    const cases = [_]struct {
        name: []const u8,
        chunks: []const []const u8,
        trim_from: ?usize = null,
        expected_raw: []const u8,
    }{
        .{
            .name = "clean, empty journal",
            .chunks = &.{"show version\nrouter#"},
            .expected_raw = "show version\nrouter#",
        },
        .{
            .name = "junk at the start",
            .chunks = &.{"\x1Bxfoo"},
            .expected_raw = "\x1Bxfoo",
        },
        .{
            .name = "junk in the middle",
            .chunks = &.{"f\x1Bxoo"},
            .expected_raw = "f\x1Bxoo",
        },
        .{
            .name = "junk at end",
            .chunks = &.{"foo\x1Bx"},
            .expected_raw = "foo\x1Bx",
        },
        .{
            .name = "two entries at the same position (junk split across chunks)",
            .chunks = &.{ "foo\x1B[0m", "\x1B[Kbar" },
            .expected_raw = "foo\x1B[0m\x1B[Kbar",
        },
        .{
            .name = "csi soup",
            .chunks = &.{"\x1B[m\x1B[27m\x1B[24mroot@server[~]# \x1B[K\x1B[?2004h"},
            .expected_raw = "\x1B[m\x1B[27m\x1B[24mroot@server[~]# \x1B[K\x1B[?2004h",
        },
        .{
            .name = "trimmed trailing prompt still reconstructs",
            .chunks = &.{ "show version\n", "uptime 4 weeks\n\x1B[0mrouter#" },
            .trim_from = 28,
            .expected_raw = "show version\nuptime 4 weeks\n\x1B[0mrouter#",
        },
        .{
            .name = "trim everything (retain_input false style)",
            .chunks = &.{"show ver\x1B[K\n"},
            .trim_from = 0,
            .expected_raw = "show ver\x1B[K\n",
        },
    };

    for (cases) |case| {
        var pb = ProcessedBuf.init();

        defer pb.deinit(std.testing.allocator);

        for (case.chunks) |chunk| {
            const mut_chunk = try std.testing.allocator.dupe(u8, chunk);
            defer std.testing.allocator.free(mut_chunk);

            try pb.appendWithProcessing(std.testing.allocator, mut_chunk);
        }

        if (case.trim_from) |trim_from| {
            try pb.rightTrimProcessed(std.testing.allocator, trim_from);
        }

        const owned_bufs = try pb.toOwnedSlices(std.testing.allocator);
        defer std.testing.allocator.free(owned_bufs[0]);
        defer std.testing.allocator.free(owned_bufs[1]);

        const reconstructed = try reconstructRaw(
            std.testing.allocator,
            owned_bufs[0],
            owned_bufs[1],
        );

        defer std.testing.allocator.free(reconstructed);

        try std.testing.expectEqualStrings(case.expected_raw, reconstructed);
    }
}

test "reconstructRaw corrupt journals" {
    const cases = [_]struct {
        name: []const u8,
        raw_journal: []const u8,
        processed: []const u8,
    }{
        .{
            // continuation bit set but nothing follows
            .name = "truncated varint",
            .raw_journal = "\x80",
            .processed = "foo",
        },
        .{
            // entry claims 5 content bytes, only 1 present
            .name = "len exceeds journal",
            .raw_journal = "\x00\x05x",
            .processed = "foo",
        },
        .{
            // delta walks past the end of processed
            .name = "delta beyond processed",
            .raw_journal = "\x7F\x01x",
            .processed = "ab",
        },
        .{
            // valid first entry then a truncated second
            .name = "truncated second entry",
            .raw_journal = "\x00\x01x\x02",
            .processed = "ab",
        },
    };

    for (cases) |case| {
        std.testing.expectError(
            errors.ScrapliError.Journal,
            reconstructRaw(std.testing.allocator, case.raw_journal, case.processed),
        ) catch |err| {
            std.debug.print("corrupt journal case failed: {s}\n", .{case.name});

            return err;
        };
    }
}

/// Returns the size of the raw output that reconstructRaw will produce for the given
/// (journaled) raw and processed pair -- used for sizing buffers for ffi bits to know how big of
/// a string to pre allocate.
pub fn reconstructedRawLen(
    raw_journal: []const u8,
    processed_len: usize,
) !usize {
    var out_len: usize = processed_len;

    var idx: usize = 0;

    while (idx < raw_journal.len) {
        // pos delta -- not needed for sizing but must be consumed (and validated) to walk
        _ = try readVarint(raw_journal, &idx);

        const len: usize = @intCast(try readVarint(raw_journal, &idx));

        if (len > raw_journal.len - idx) {
            return errors.ScrapliError.Journal;
        }

        idx += len;

        out_len += len;
    }

    return out_len;
}

pub fn reconstructRaw(
    allocator: std.mem.Allocator,
    raw_journal: []const u8,
    processed: []const u8,
) ![]const u8 {
    const out = try allocator.alloc(
        u8,
        try reconstructedRawLen(raw_journal, processed.len),
    );
    errdefer allocator.free(out);

    try reconstructRawInto(raw_journal, processed, out);

    return out;
}

/// Reconstructs raw from the given (journaled) raw and processed pair into the given
/// pre allocated out buffer (sized via reconstructedRawLen) -- used by the ffi layer
/// which fills caller provided buffers.
pub fn reconstructRawInto(
    raw_journal: []const u8,
    processed: []const u8,
    out: []u8,
) !void {
    var raw_idx: usize = 0;
    var processed_idx: usize = 0;
    var out_idx: usize = 0;
    var pos: usize = 0;

    while (raw_idx < raw_journal.len) {
        const delta: usize = @intCast(try readVarint(raw_journal, &raw_idx));

        if (delta > processed.len - pos) {
            // entry lands past the end of processed -- if we didnt bail here the pos math
            // below would overflow/read garbage on a corrupt journal. note that *out of order*
            // entries are unrepresentable with delta encoding, so thats one whole class of
            // corruption we no longer have to check for
            return errors.ScrapliError.Journal;
        }

        pos += delta;

        const len: usize = @intCast(try readVarint(raw_journal, &raw_idx));

        if (len > raw_journal.len - raw_idx) {
            return errors.ScrapliError.Journal;
        }

        const keep_len = pos - processed_idx;

        if (out_idx + keep_len + len > out.len) {
            return errors.ScrapliError.Journal;
        }

        @memcpy(
            out[out_idx..][0..keep_len],
            processed[processed_idx..pos],
        );

        out_idx += keep_len;
        processed_idx = pos;

        @memcpy(
            out[out_idx..][0..len],
            raw_journal[raw_idx..][0..len],
        );

        out_idx += len;

        raw_idx += len;
    }

    const tail_len = processed.len - processed_idx;

    if (out.len - out_idx != tail_len) {
        return errors.ScrapliError.Journal;
    }

    @memcpy(out[out_idx..][0..tail_len], processed[processed_idx..]);
}
