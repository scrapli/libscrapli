const std = @import("std");

const ascii = @import("ascii.zig");

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

    /// Append the given buf to both raw and processed buffers, trimming asni/ascii chars before
    /// writing to the processed buf.
    pub fn appendSlice(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
        buf: []u8,
    ) !void {
        // TODO is this check acceptable?
        if (std.mem.find(u8, buf, &[_]u8{ascii.control_chars.esc}) != null) {
            // if ESC in the new buf look at last n of processed buf to replace if
            // necessary; this *feels* bad like we may miss sequences (if our read gets part
            // of a sequence, then a subsequent read gets the rest), however this has never
            // happened in 5+ years of scrapli/scrapligo only checking/cleaning the read buf
            // so we are going to roll with it and hope :)

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
        } else {
            try self.processed.appendSlice(allocator, buf);
        }
    }

    /// Return the "raw" and "processed" buffers, caller owns memory.
    pub fn toOwnedSlices(
        self: *ProcessedBuf,
        allocator: std.mem.Allocator,
    ) ![2][]const u8 {
        return [2][]const u8{
            try self.raw.toOwnedSlice(allocator),
            try self.processed.toOwnedSlice(allocator),
        };
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

    /// Return owned copies of the "raw" and "processed" buffers (caller owns the returned memory)
    /// without consuming this ProcessedBuf, so the (almost certainly) Session can continue using
    /// this object..
    pub fn dupeOwnedSlices(self: *ProcessedBuf, allocator: std.mem.Allocator) ![2][]const u8 {
        const raw_copy = try allocator.dupe(u8, self.raw.items);
        errdefer allocator.free(raw_copy);

        const processed_copy = try allocator.dupe(u8, self.processed.items);

        return [2][]const u8{ raw_copy, processed_copy };
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

        try pb.appendSlice(std.testing.allocator, in_buf);

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

    try pb.appendSlice(std.testing.allocator, chunk_one);
    try pb.appendSlice(std.testing.allocator, chunk_two);
    try pb.appendSlice(std.testing.allocator, chunk_three);

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

// test "ProcessedBuf demote from" {
//     const cases = [_]struct {
//         name: []const u8,
//         chunks: []const []const u8,
//         demote_from: usize,
//         expected_processed: []const u8,
//         expected_journal: []const u8,
//     }{
//         .{
//             // the "retain_trailing_prompt = false" case: trim the prompt off the end,
//             // its bytes move into the journal at the trim position
//             .name = "plain suffix demote",
//             .chunks = &.{"show version\nrouter#"},
//             .demote_from = 13,
//             .expected_processed = "show version\n",
//             .expected_journal = "\x0D\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00router#",
//         },
//         .{
//             // junk that was already journaled *inside* the demoted range must weave into
//             // the demoted blob in wire order, and its old record must be gone from the
//             // journal -- one record total afterwards
//             .name = "suffix demote weaves existing record in range",
//             .chunks = &.{ "show version\n", "\x1B[0mrouter#" },
//             .demote_from = 13,
//             .expected_processed = "show version\n",
//             .expected_journal = "\x0D\x00\x00\x00\x00\x00\x00\x00\x0B\x00\x00\x00\x00\x00\x00\x00\x1B[0mrouter#",
//         },
//         .{
//             // records entirely before the demote position are untouched, byte for byte
//             .name = "record before demote position survives",
//             .chunks = &.{"f\x1Bxoo"},
//             .demote_from = 2,
//             .expected_processed = "fo",
//             .expected_journal = "\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x1Bx" ++
//                 "\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00o",
//         },
//         .{
//             // the "retain_input = false" case: demote *everything* -- processed goes
//             // empty and the journal's single record at pos 0 is the entire raw input
//             .name = "demote everything",
//             .chunks = &.{"show ver\x1B[K\n"},
//             .demote_from = 0,
//             .expected_processed = "",
//             .expected_journal = "\x00\x00\x00\x00\x00\x00\x00\x00\x0C\x00\x00\x00\x00\x00\x00\x00show ver\x1B[K\n",
//         },
//     };

//     for (cases) |case| {
//         var pb = ProcessedBuf.init();

//         defer pb.deinit(std.testing.allocator);

//         for (case.chunks) |chunk| {
//             const mut_chunk = try std.testing.allocator.dupe(u8, chunk);
//             defer std.testing.allocator.free(mut_chunk);

//             try pb.appendSlice(std.testing.allocator, mut_chunk);
//         }

//         try pb.demoteFrom(std.testing.allocator, case.demote_from);

//         std.testing.expectEqualStrings(case.expected_processed, pb.processed.items) catch |err| {
//             std.debug.print("demote from case failed (processed): {s}\n", .{case.name});

//             return err;
//         };

//         std.testing.expectEqualStrings(case.expected_journal, pb.journal.items) catch |err| {
//             std.debug.print("demote from case failed (journal): {s}\n", .{case.name});

//             return err;
//         };
//     }
// }
