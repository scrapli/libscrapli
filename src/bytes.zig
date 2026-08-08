const std = @import("std");

const ascii = @import("ascii.zig");
const errors = @import("errors.zig");

/// A string that is used to delimit multiple substrings -- used in a few places for passing things
/// via ffi to not have to deal w/ c arrays and such
pub const libscrapli_delimiter = "__libscrapli__";

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

/// overhead for serializing journal entry pos+len as u64 little endian.
const journal_entry_header_len: usize = 16;
const journal_entry_header_element_len: usize = 8;

const ProcessedBufRawJournalEntry = struct {
    pos: usize,
    len: usize,
};

/// A type that holds the "raw" and "processed" buffers (array list) for scrapli session objects.
pub const ProcessedBuf = struct {
    raw: std.ArrayList(u8),
    raw_journal: std.ArrayList(ProcessedBufRawJournalEntry),
    processed: std.ArrayList(u8),

    /// Initialize the ProcessedBuf object.
    pub fn init() ProcessedBuf {
        return ProcessedBuf{
            .raw = .empty,
            .raw_journal = .empty,
            .processed = .empty,
        };
    }

    /// Deinitialize the Processedbuf object.
    pub fn deinit(self: *ProcessedBuf, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.raw_journal.deinit(allocator);
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

    /// Append the given buf and store a journal of anything we trim/strip (ascii/ansii stuff).
    /// Called "appendWithProcessing" because it does the ascii/ansi stripping (if applicable).
    pub fn appendWithProcessing(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []u8,
    ) !void {
        if (!ascii.hasStrippableByte(buf)) {
            try self.processed.appendSlice(allocator, buf);

            return;
        }

        var iter = ascii.AsciiAnsiControlStripIterator{
            .haystack = buf,
        };

        while (true) {
            switch (iter.next()) {
                .item => |i| {
                    // raw buf holds *only* the raw content, the "journal" (index?) thing holds
                    // where these go to repopulate a full "raw" output
                    try self.raw.appendSlice(allocator, i.content);

                    try self.raw_journal.append(
                        allocator,
                        ProcessedBufRawJournalEntry{
                            // have to increment the pos + the already processed len so its
                            // absolute
                            .pos = i.pos + self.processed.items.len,
                            .len = i.content.len,
                        },
                    );
                },
                .done => |n| {
                    try self.processed.appendSlice(allocator, buf[0..n]);
                    break;
                },
            }
        }
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
        const out = try allocator.alloc(
            u8,
            self.raw_journal.items.len * journal_entry_header_len + self.raw.items.len,
        );

        var cur: usize = 0;
        var content_offset: usize = 0;

        for (self.raw_journal.items) |e| {
            std.mem.writeInt(
                u64,
                out[cur..][0..journal_entry_header_element_len],
                e.pos,
                .little,
            );

            std.mem.writeInt(
                u64,
                out[cur + journal_entry_header_element_len ..][0..8],
                e.len,
                .little,
            );

            @memcpy(
                out[cur + journal_entry_header_len ..][0..e.len],
                self.raw.items[content_offset..][0..e.len],
            );

            cur += journal_entry_header_len + e.len;
            content_offset += e.len;
        }

        return out;
    }

    /// Return the "raw" and "processed" buffers, caller owns memory.
    pub fn toOwnedSlices(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) ![2][]const u8 {
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
            .name = "simple - leading raw journaled",
            .chunks = &.{"\x1Bxfoo"},
            .expected_raw_journaled_buf = "\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x1Bx",
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
        if (idx + journal_entry_header_len > raw_journal.len) {
            return errors.ScrapliError.IndexError;
        }

        const len = std.mem.readInt(
            u64,
            raw_journal[idx + journal_entry_header_element_len ..][0..8],
            .little,
        );

        if (len > raw_journal.len - idx - journal_entry_header_len) {
            return errors.ScrapliError.IndexError;
        }

        idx += journal_entry_header_len + len;

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

    while (raw_idx < raw_journal.len) {
        if (raw_idx + journal_entry_header_len > raw_journal.len) {
            return error.CorruptJournal;
        }

        const pos: usize = @intCast(std.mem.readInt(
            u64,
            raw_journal[raw_idx..][0..8],
            .little,
        ));

        if (pos < processed_idx or pos > processed.len) {
            // out of order or out of range entry -- if we didnt bail here the keep_len
            // math below would underflow/read garbage on a corrupt journal
            return error.CorruptJournal;
        }

        const len: usize = @intCast(std.mem.readInt(
            u64,
            raw_journal[raw_idx + journal_entry_header_element_len ..][0..8],
            .little,
        ));

        if (len > raw_journal.len - raw_idx - journal_entry_header_len) {
            return error.CorruptJournal;
        }

        const keep_len = pos - processed_idx;

        if (out_idx + keep_len + len > out.len) {
            return error.LengthMismatch;
        }

        @memcpy(
            out[out_idx..][0..keep_len],
            processed[processed_idx..pos],
        );

        out_idx += keep_len;
        processed_idx = pos;

        @memcpy(
            out[out_idx..][0..len],
            raw_journal[raw_idx + journal_entry_header_len ..][0..len],
        );

        out_idx += len;

        raw_idx += journal_entry_header_len + len;
    }

    const tail_len = processed.len - processed_idx;

    if (out.len - out_idx != tail_len) {
        return error.LengthMismatch;
    }

    @memcpy(out[out_idx..][0..tail_len], processed[processed_idx..]);
}
