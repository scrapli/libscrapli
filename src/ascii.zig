// zlint-disable unused-decls
// note: leaving consts in here for future sanity/to not have to look stuff up
const std = @import("std");
const arrays = @import("arrays.zig");
const thelper = @import("test-helper.zig");

pub const control_chars = struct {
    // Null | 0x00 | 0
    pub const nul = 0x00;
    // Start of heading | 0x01 | 1
    pub const soh = 0x01;
    // Start of text | 0x02 | 2
    pub const stx = 0x02;
    // End of text | 0x03 | 3 | also ctrl+c
    pub const etx = 0x03;
    // End of transmission | 0x04 | 4
    pub const eot = 0x04;
    // Enquiry | 0x05 | 5
    pub const enq = 0x05;
    // Acknowledge | 0x06 | 6
    pub const ack = 0x05;
    // Terminal Bell | 0x07 | 7
    pub const bel = 0x07;
    // Backspace | 0x08 | 8
    pub const bs = 0x08;
    // Horizontal tab | 0x09 | 9
    pub const tab = 0x09;
    // Line feed | \n | 0x0A | 10
    pub const lf = 0x0A;
    // Vertical tab | 0x0B | 11
    pub const vt = 0x0B;
    // New Page | 0x0C | 12
    pub const np = 0x0C;
    // Carriage return | \r | 0x0D | 13
    pub const cr = 0x0D;
    // Shift out | 0x0E | 14
    pub const so = 0x0E;
    // Shift in | 0x0F | 15
    pub const si = 0x0F;
    // Data link escape | 0x10 | 16
    pub const dle = 0x10;
    // Device control 1 | 0x11 | 17
    pub const dc1 = 0x11;
    // Device control 2 | 0x12 | 18
    pub const dc2 = 0x12;
    // Device control 3 | 0x13 | 19
    pub const dc3 = 0x13;
    // Device control 4 | 0x14 | 20
    pub const dc4 = 0x14;
    // Negative acknowledge | 0x15 | 21
    pub const nak = 0x15;
    // Synchronous idle | 0x16 | 22
    pub const syn = 0x16;
    // End of transmission block | 0x17 | 23
    pub const etb = 0x17;
    // Cancel | 0x18 | 24
    pub const can = 0x18;
    // End of medium | 0x19 | 25
    pub const em = 0x19;
    // Substitute | 0x1A | 26
    pub const sub = 0x1A;
    // Escape | 0x1B | 27
    pub const esc = 0x1B;
    // File seperator | 0x1C | 28
    pub const fs = 0x1C;
    // Group seperator | 0x1D | 29
    pub const gs = 0x1D;
    // Record seperator | 0x1E | 30
    pub const rs = 0x1E;
    // Unit seperator | 0x1F | 31
    pub const us = 0x1F;

    // CSI / Control Sequence Introducer *Device* / "P" / 0x50 / 80
    const control_sequence_introducer_device = 0x50;
    // CSI / Control Sequence Introducer / "[" / 0x5B / 91
    const control_sequence_introducer = 0x5B;
    // CSI / Control Sequence Introducer *Operating System* / "]" / 0x5D / 93
    const control_sequence_introducer_operating_system = 0x5D;

    // Delete | 0x7F | 127
    pub const del = 0x7F;

    // dec: 35 | hex: 0x23 | "#"
    pub const hash_char = 0x23;

    // dec: 60 | hex: 0x3C | "<"
    pub const open_element_char = 0x3C;
};

pub fn stripAsciiAndAnsiControlCharsInPlace(
    haystack: []u8,
    start_idx: usize,
) usize {
    var read_idx: usize = start_idx;
    var write_idx: usize = start_idx;

    var is_escaped = false;
    var is_control_sequence = false;
    var is_device_control_sequence = false;
    var is_operating_system_control_sequence = false;

    while (read_idx < haystack.len) {
        const char = haystack[read_idx];

        switch (char) {
            control_chars.esc => {
                is_escaped = true;
                read_idx += 1;
                continue;
            },
            control_chars.tab, control_chars.lf, control_chars.vt, control_chars.cr => {
                // Keep non-display chars we want to preserve.
                haystack[write_idx] = char;
                write_idx += 1;
                read_idx += 1;
                continue;
            },
            else => {},
        }

        if ((0x00 <= char and char <= 0x1F) or char == control_chars.del) {
            // all single byte control codes (minus escape since we care about that one
            // differently) also note that 0x00 -> 0x1F was specified then DEL (0x7F appened
            // for some reason) and newlines and carriage returns fall in this range which is why
            // they are handled above. could put this in the switch but a little nicer this way
            // than having multiple ranges to work around LF/CR in the switch (cant have dup cases)
            read_idx += 1;
            continue;
        }

        if (is_escaped and (char == control_chars.control_sequence_introducer or
            char == control_chars.control_sequence_introducer_device or
            char == control_chars.control_sequence_introducer_operating_system))
        {
            // increment past the csi char
            read_idx += 1;

            switch (char) {
                control_chars.control_sequence_introducer => {
                    is_control_sequence = true;
                },
                control_chars.control_sequence_introducer_device => {
                    is_device_control_sequence = true;
                },
                control_chars.control_sequence_introducer_operating_system => {
                    is_operating_system_control_sequence = true;
                },
                else => {},
            }

            while (read_idx < haystack.len) {
                var done = false;

                const csi_char = haystack[read_idx];

                if (is_control_sequence) {
                    if (0x30 <= csi_char and csi_char <= 0x3F) {
                        // nothing to do, this is a "parameter byte" we dont want it
                    } else if (0x20 <= csi_char and csi_char <= 0x2F) {
                        // still nothing to do, "intermediate byte", we also dont want it
                    }
                    if (0x40 <= csi_char and csi_char <= 0x7E) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        is_control_sequence = false;
                        done = true;
                    }
                } else if (is_device_control_sequence) {
                    // do we need to do things?
                } else if (is_operating_system_control_sequence) {
                    if (csi_char == control_chars.bel or csi_char == 0x9C) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        is_operating_system_control_sequence = false;
                        done = true;
                    }
                } else {
                    if (0x40 <= csi_char and csi_char <= 0x7E) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        done = true;
                    }
                }

                read_idx += 1;

                if (done) {
                    break;
                }
            }

            continue;
        }

        // after checking for the csi/ocs/dcs bits we can check for single char control sequences
        if (is_escaped and (0x20 < char and char < 0x7F)) {
            // standard one byte escape sequence, we don't really care about the
            // specific sequence, we just want to get rid of those bytes :)
            is_escaped = false;
            read_idx += 1;
            continue;
        }

        // if we've made it this far, hooray! we want this char!
        haystack[write_idx] = char;
        write_idx += 1;
        read_idx += 1;
    }

    return write_idx;
}

test "stripAsciiAndAnsiControlCharsInPlace" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        startIdx: usize,
        expectedNewSize: usize,
        expected: []const u8,
    }{
        .{
            .name = "no change",
            .haystack = "foo",
            .startIdx = 0,
            .expectedNewSize = 3,
            .expected = "foo",
        },
        .{
            .name = "no start not at beginning",
            .haystack = "foo bar baz",
            .startIdx = 3,
            .expectedNewSize = 11,
            .expected = "foo bar baz",
        },
        .{
            .name = "NUL",
            .haystack = "foo \x00 bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        .{
            .name = "BEL",
            .haystack = "foo \x07 bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        .{
            .name = "BS",
            .haystack = "foo \x08 bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        // we are *not* tabs, but we could :)
        .{
            .name = "HT",
            .haystack = "foo \x09 bar",
            .startIdx = 0,
            .expectedNewSize = 9,
            .expected = "foo \x09 bar",
        },
        // we are *not* stripping line feeds, but we could :)
        .{
            .name = "LF",
            .haystack = "foo \x0A bar",
            .startIdx = 0,
            .expectedNewSize = 9,
            .expected = "foo \x0A bar",
        },
        // we are *not* stripping (vertical) tabs, but we could :)
        .{
            .name = "VT",
            .haystack = "foo \x0B bar",
            .startIdx = 0,
            .expectedNewSize = 9,
            .expected = "foo \x0B bar",
        },
        .{
            .name = "FF",
            .haystack = "foo \x0C bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        // we are *not* stripping carriage returns
        .{
            .name = "CR",
            .haystack = "foo \x0D bar",
            .startIdx = 0,
            .expectedNewSize = 9,
            .expected = "foo \x0D bar",
        },
        .{
            .name = "DEL",
            .haystack = "foo \x7F bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        .{
            .name = "NEL",
            .haystack = "foo \x1BE bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        .{
            .name = "DEC",
            .haystack = "foo \x1B7 bar",
            .startIdx = 0,
            .expectedNewSize = 8,
            .expected = "foo  bar",
        },
        .{
            .name = "color text",
            .haystack = "\x1B[31mRedText\x1B[0m",
            .startIdx = 0,
            .expectedNewSize = 7,
            .expected = "RedText",
        },
        .{
            .name = "simple prompt",
            .haystack = "[admin@router: \x1b[1m/\x1b[0;0m]$",
            .startIdx = 0,
            .expectedNewSize = 18,
            .expected = "[admin@router: /]$",
        },
        .{
            .name = "simple save cursor position",
            .haystack = "somestuff\x1b7someotherstuff",
            .startIdx = 0,
            .expectedNewSize = 23,
            .expected = "somestuffsomeotherstuff",
        },
        .{
            .name = "simple dont mess with newlines",
            .haystack = "Hello\x1B[31mRed\x1B[0m\\nWorld\x07",
            .startIdx = 0,
            .expectedNewSize = 15,
            .expected = "HelloRed\\nWorld",
        },
        .{
            .name = "strip cursor controls",
            .haystack = "\x1B[m\x1B[27m\x1B[24mroot@server[~]# \x1B[K\x1B[?2004h",
            .startIdx = 0,
            .expectedNewSize = 16,
            .expected = "root@server[~]# ",
        },
        .{
            .name = "some pager output",
            .haystack = "\x1b[7mCTRL+C\x1b[0m \x1b[7mESC\x1b[0m \x1b[7mq\x1b[0m Quit \x1b[7mSPACE\x1b[0m \x1b[7mn\x1b[0m Next Page \x1b[7mENTER\x1b[0m Next Entry \x1b[7ma\x1b[0m All\x1b[1A\x1b[59C\x1b[27m",
            .startIdx = 0,
            .expectedNewSize = 58,
            .expected = "CTRL+C ESC q Quit SPACE n Next Page ENTER Next Entry a All",
        },
        .{
            .name = "underline",
            .haystack = "\x1B[4mcake\x1B[0m",
            .startIdx = 0,
            .expectedNewSize = 4,
            .expected = "cake",
        },
        .{
            .name = "underline with some leading stuff",
            .haystack = "foo\x1B[4mcake\x1B[0m",
            .startIdx = 0,
            .expectedNewSize = 7,
            .expected = "foocake",
        },
        .{
            .name = "lots of arguments",
            .haystack = "\x1B[00;38;5;244m\x1B[m\x1B[00;38;5;33mfoo\x1B[0m",
            .startIdx = 0,
            .expectedNewSize = 3,
            .expected = "foo",
        },
        .{
            .name = "lots of arguments with text at the end",
            .haystack = "foo\x1B[0;33;49;3;9;4mbar",
            .startIdx = 0,
            .expectedNewSize = 6,
            .expected = "foobar",
        },
        .{
            .name = "lots of save restore cursor",
            .haystack = "\x1b7c\x1b8\x1b[1C\x1b7o\x1b8\x1b[1C\x1b7n\x1b8\x1b[1C\x1b7f\x1b8\x1b[1C\x1b7i\x1b8\x1b[1C\x1b7g\x1b8\x1b[1C\x1b7u\x1b8\x1b[1C\x1b7r\x1b8\x1b[1C\x1b7e\x1b8\x1b[1C",
            .startIdx = 0,
            .expectedNewSize = 9,
            .expected = "configure",
        },
        .{
            .name = "terminal title",
            .haystack = "\x1b[?2004h\x1b]0;user@line5-cpe-0: ~\x07user@line5-cpe-0:~$",
            .startIdx = 0,
            .expectedNewSize = 19,
            .expected = "user@line5-cpe-0:~$",
        },
        .{
            .name = "more os control codes",
            .haystack = "\x1b[?6l\x1b[1;80r\x1b[?7h\x1b[2J\x1b[1;1H\x1b[1920;1920H\x1b[6n\x1b[1;1HYour previous successful login (as manager) was on 2024-05-24 11:29:02     \n from X.X.X.X\n\x1b[1;80r\x1b[80;1H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[80;1HHOSTNAME# \x1b[80;1H\x1b[80;20H\x1b[80;1H\x1b[?25h\x1b[80;20H\x1b[1;0H\x1b[1M\x1b[80;1H\x1b[1L\x1b[80;20H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[1;80r\x1b[80;1H\x1b[1;80r\x1b[80;1H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[80;1HHOSTNAME# \x1b[80;1H\x1b[80;20H\x1b[80;1H\x1b[?25h\x1b[80;20H",
            .startIdx = 0,
            .expectedNewSize = 110,
            .expected = "Your previous successful login (as manager) was on 2024-05-24 11:29:02     \n from X.X.X.X\nHOSTNAME# HOSTNAME# ",
        },
        .{
            .name = "clear screen",
            .haystack = "Last login: Thu Sep 26 10:29:38 2024 \nFOO BAR BAZ.\n\nroot@truenas[~]# \x1B[K\x1B[?2004h\x08ls -al",
            .startIdx = 0,
            .expectedNewSize = 75,
            .expected = "Last login: Thu Sep 26 10:29:38 2024 \nFOO BAR BAZ.\n\nroot@truenas[~]# ls -al",
        },
        .{
            .name = "powerlevel 10k prompt",
            .haystack = "\x1B[0m\x1B[27m\x1B[24m\x1B[J\x1B[0m\x1B[49m\x1B[39m\x1B[A\x1B[0m\x1B[48;5;238m\x1B[38;5;180m carl@c1-1\x1B[0m\x1B[38;5;180m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;180m \x1B[0m\x1B[38;5;180m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;246m|\x1B[0m\x1B[38;5;246m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m \x1B[1m\x1B[38;5;31m\x1B[48;5;238m\x1B[38;5;39m~\x1B[0m\x1B[38;5;39m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m\x1B[0m\x1B[38;5;31m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m \x1B[0m\x1B[38;5;31m\x1B[48;5;238m\x1B[49m\x1B[38;5;238m\x1B[0m\x1B[38;5;238m\x1B[49m\x1B[39m\x1B[38;5;242m...........................................\x1B[0m\x1B[38;5;242m\x1B[48;5;238m\x1B[38;5;134m kubernetes-admin@c1\x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;134m\x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;134m \x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[49m\x1B[39m\x1B[0m\x1B[49m\x1B[39m\x1B[0m\x1B[49m\x1B[38;5;76m\x1B[0m\x1B[38;5;76m\x1B[49m\x1B[38;5;76m\x1B[0m\x1B[38;5;76m\x1B[49m\x1B[30m\x1B[0m\x1B[30m\x1B[49m\x1B[39m \x1B[0m\x1B[49m\x1B[39m\x1B[K\x1B[?1h\x1B[?25h\x1B[?2004h",
            .startIdx = 0,
            .expectedNewSize = 80,
            .expected = " carl@c1-1 | ~ ........................................... kubernetes-admin@c1  ",
        },
        .{
            .name = "multi byte char",
            .haystack = "foo ❯ bar",
            .startIdx = 0,
            .expectedNewSize = 11,
            .expected = "foo ❯ bar",
        },
        .{
            .name = "eos prompt",
            .haystack = "\x0A\x1B\x5B\x35\x6e\x65\x6F\x73\x31\x3E",
            .startIdx = 0,
            .expectedNewSize = 6,
            .expected = "\neos1>",
        },
        .{
            .name = "more eos prompt/login",
            .haystack = "Warning: Permanently added '[localhost]:22022' (ED25519) to the list of known hosts.\x1B\x4D\x1B\x4D\x1B\x4C \x1B\x4D(admin@localhost) Password: \x1B\x4D\x1B\x4C Last login: Thu Dec 26 22:02:14 2024 from 172.20.20.1\x1B\x4D\x1B\x4D\x1B\x4C \x1B\x5B5neos1>\x1B\x4D\x1B\x4C eos1>",
            .startIdx = 0,
            .expectedNewSize = 179,
            .expected = "Warning: Permanently added '[localhost]:22022' (ED25519) to the list of known hosts. (admin@localhost) Password:  Last login: Thu Dec 26 22:02:14 2024 from 172.20.20.1 eos1> eos1>",
        },
    };

    for (cases) |case| {
        var haystack = try std.testing.allocator.alloc(u8, case.haystack.len);
        defer std.testing.allocator.free(haystack);

        @memcpy(haystack, case.haystack);

        const actualNewSize = stripAsciiAndAnsiControlCharsInPlace(
            haystack,
            case.startIdx,
        );

        try std.testing.expectEqual(case.expectedNewSize, actualNewSize);
        try thelper.testStrResult(
            "stripAsciiAndAnsiControlCharsInPlace",
            case.name,
            haystack[0..actualNewSize],
            case.expected,
        );
    }
}

pub fn stripAsciiControlCharsInPlace(
    haystack: *std.ArrayList(u8),
) !void {
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < haystack.items.len) {
        defer read_idx += 1;

        const char = haystack.items[read_idx];

        if (char == control_chars.esc) {
            // Ignore escapes; if there are escapes, stripAnsiiControlSequences will handle them.
            haystack.items[write_idx] = char;
            write_idx += 1;
            continue;
        }

        if ((0x1F < char and char < 0x7F) or char > 0x7F) {
            // Characters from "space" (~0x20) to "~" (~0x7E), excluding hidden chars (0x00-0x1F)
            // and DEL (0x7F). Also include anything after DEL (extended chars).
            haystack.items[write_idx] = char;
            write_idx += 1;
            continue;
        }

        switch (char) {
            control_chars.tab, control_chars.lf, control_chars.vt, control_chars.cr => {
                // Keep non-display chars we want to preserve.
                haystack.items[write_idx] = char;
                write_idx += 1;
                continue;
            },
            else => {},
        }
    }

    try haystack.resize(write_idx);
}

test "stripAsciiControlCharsInPlace" {
    const cases = [_]struct {
        name: []const u8,
        haystack: std.ArrayList(u8),
        expected: []const u8,
    }{
        .{
            .name = "no change",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo"),
            .expected = "foo",
        },
        .{
            .name = "NUL",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x00 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "SOH",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x01 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "STX",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x02 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "ETX",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x03 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "EOT",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x04 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "ENQ",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x05 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "ACK",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x06 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "BEL",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x07 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "BS",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x08 bar"),
            .expected = "foo  bar",
        },
        // we are *not* stripping tabs
        .{
            .name = "TAB",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x09 bar"),
            .expected = "foo \x09 bar",
        },
        // we are *not* stripping line feeds
        .{
            .name = "LF",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0A bar"),
            .expected = "foo \x0A bar",
        },
        // we are *not* stripping vertical tabls
        .{
            .name = "VT",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0B bar"),
            .expected = "foo \x0B bar",
        },
        .{
            .name = "FF",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0C bar"),
            .expected = "foo  bar",
        },
        // we are *not* stripping line feeds, but we could :)
        .{
            .name = "LF",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0A bar"),
            .expected = "foo \x0A bar",
        },
        .{
            .name = "SO",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0E bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "SI",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x0F bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "DLE",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x10 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "DC1",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x11 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "DC2",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x12 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "DC3",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x13 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "DC4",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x14 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "NAK",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x15 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "SYN",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x16 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "ETB",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x17 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "CAN",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x18 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "EM",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x19 bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "SUB",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1A bar"),
            .expected = "foo  bar",
        },
        .{
            // we do *not* strip escapes! the ansii control seq stripper does that!
            .name = "ESC",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1B bar"),
            .expected = "foo \x1B bar",
        },
        .{
            .name = "FS",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1C bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "GS",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1D bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "RS",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1E bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "US",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo \x1F bar"),
            .expected = "foo  bar",
        },
        .{
            .name = "multi byte char",
            .haystack = try arrays.inlineInitArrayList(std.testing.allocator, u8, "foo ❯ bar"),
            .expected = "foo ❯ bar",
        },
    };

    for (cases) |case| {
        defer case.haystack.deinit();

        var haystack = case.haystack;

        try stripAsciiControlCharsInPlace(
            &haystack,
        );

        try thelper.testStrResult("stripAsciiControlCharsInPlace", case.name, haystack.items, case.expected);
    }
}

pub fn stripAsciiControlChars(
    allocator: std.mem.Allocator,
    haystack: []const u8,
) ![]const u8 {
    const processed = try allocator.alloc(u8, haystack.len);
    var processed_idx: u64 = 0;

    var haystack_idx: usize = 0;

    while (haystack_idx < haystack.len) {
        defer haystack_idx += 1;

        const char = haystack[haystack_idx];

        if (char == control_chars.esc) {
            // firstly ignore escapes, *if* there are escapes the stripAnsiiControlSequences will
            // handle those
            processed[processed_idx] = char;
            processed_idx += 1;

            continue;
        }

        if ((0x1F < char and char < 0x7F) or char > 0x7F) {
            // this is everything from "space" through "~" -- so the full ascii table minus the
            // hidden chars (0x00-0x1F) and DEL (0x7F), we want these.
            // we'll also take anything after the DEL since its extended chars that we would want
            // to display
            processed[processed_idx] = char;
            processed_idx += 1;

            continue;
        }

        switch (char) {
            control_chars.tab, control_chars.lf, control_chars.vt, control_chars.cr => {
                // non "display" chars we want to keep
                processed[processed_idx] = char;
                processed_idx += 1;

                continue;
            },
            else => {},
        }
    }

    return allocator.realloc(processed, processed_idx);
}

test "stripAsciiControlChars" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "no change",
            .haystack = "foo",
            .expected = "foo",
        },
        .{
            .name = "NUL",
            .haystack = "foo \x00 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "SOH",
            .haystack = "foo \x01 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "STX",
            .haystack = "foo \x02 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "ETX",
            .haystack = "foo \x03 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "EOT",
            .haystack = "foo \x04 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "ENQ",
            .haystack = "foo \x05 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "ACK",
            .haystack = "foo \x06 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "BEL",
            .haystack = "foo \x07 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "BS",
            .haystack = "foo \x08 bar",
            .expected = "foo  bar",
        },
        // we are *not* stripping tabs
        .{
            .name = "TAB",
            .haystack = "foo \x09 bar",
            .expected = "foo \x09 bar",
        },
        // we are *not* stripping line feeds
        .{
            .name = "LF",
            .haystack = "foo \x0A bar",
            .expected = "foo \x0A bar",
        },
        // we are *not* stripping vertical tabls
        .{
            .name = "VT",
            .haystack = "foo \x0B bar",
            .expected = "foo \x0B bar",
        },
        .{
            .name = "FF",
            .haystack = "foo \x0C bar",
            .expected = "foo  bar",
        },
        // we are *not* stripping line feeds, but we could :)
        .{
            .name = "LF",
            .haystack = "foo \x0A bar",
            .expected = "foo \x0A bar",
        },
        .{
            .name = "SO",
            .haystack = "foo \x0E bar",
            .expected = "foo  bar",
        },
        .{
            .name = "SI",
            .haystack = "foo \x0F bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DLE",
            .haystack = "foo \x10 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DC1",
            .haystack = "foo \x11 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DC2",
            .haystack = "foo \x12 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DC3",
            .haystack = "foo \x13 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DC4",
            .haystack = "foo \x14 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "NAK",
            .haystack = "foo \x15 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "SYN",
            .haystack = "foo \x16 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "ETB",
            .haystack = "foo \x17 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "CAN",
            .haystack = "foo \x18 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "EM",
            .haystack = "foo \x19 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "SUB",
            .haystack = "foo \x1A bar",
            .expected = "foo  bar",
        },
        .{
            // we do *not* strip escapes! the ansii control seq stripper does that!
            .name = "ESC",
            .haystack = "foo \x1B bar",
            .expected = "foo \x1B bar",
        },
        .{
            .name = "FS",
            .haystack = "foo \x1C bar",
            .expected = "foo  bar",
        },
        .{
            .name = "GS",
            .haystack = "foo \x1D bar",
            .expected = "foo  bar",
        },
        .{
            .name = "RS",
            .haystack = "foo \x1E bar",
            .expected = "foo  bar",
        },
        .{
            .name = "US",
            .haystack = "foo \x1F bar",
            .expected = "foo  bar",
        },
        .{
            .name = "multi byte char",
            .haystack = "foo ❯ bar",
            .expected = "foo ❯ bar",
        },
    };

    for (cases) |case| {
        const actual = try stripAsciiControlChars(
            std.testing.allocator,
            case.haystack,
        );
        defer std.testing.allocator.free(actual);

        try thelper.testStrResult("stripAsciiControlChars", case.name, actual, case.expected);
    }
}

pub fn stripAnsiiControlSequences(
    allocator: std.mem.Allocator,
    haystack: []const u8,
) ![]const u8 {
    var processed = try allocator.alloc(u8, haystack.len);
    var processed_idx: u64 = 0;

    var is_escaped = false;
    var is_control_sequence = false;
    var is_device_control_sequence = false;
    var is_operating_system_control_sequence = false;
    var haystack_idx: usize = 0;

    while (haystack_idx < haystack.len) {
        const char = haystack[haystack_idx];

        switch (char) {
            control_chars.esc => {
                is_escaped = true;

                haystack_idx += 1;

                continue;
            },
            control_chars.lf, control_chars.cr => {
                processed[processed_idx] = char;
                processed_idx += 1;

                haystack_idx += 1;

                continue;
            },
            else => {},
        }

        if ((0x00 <= char and char <= 0x1F) or char == control_chars.del) {
            // all single byte control codes (minus escape since we care about that one
            // differently) also note that 0x00 -> 0x1F was specified then DEL (0x7F appened
            // for some reason) and newlines and carriage returns fall in this range which is why
            // they are handled above. could put this in the switch but a little nicer this way
            // than having multiple ranges to work around LF/CR in the switch (cant have dup cases)
            haystack_idx += 1;

            continue;
        }

        if (is_escaped and (char == control_chars.control_sequence_introducer or
            char == control_chars.control_sequence_introducer_device or
            char == control_chars.control_sequence_introducer_operating_system))
        {
            // increment past the csi char
            haystack_idx += 1;

            switch (char) {
                control_chars.control_sequence_introducer => {
                    is_control_sequence = true;
                },
                control_chars.control_sequence_introducer_device => {
                    is_device_control_sequence = true;
                },
                control_chars.control_sequence_introducer_operating_system => {
                    is_operating_system_control_sequence = true;
                },
                else => {},
            }

            while (haystack_idx < haystack.len) {
                var done = false;

                const csi_char = haystack[haystack_idx];

                if (is_control_sequence) {
                    if (0x30 <= csi_char and csi_char <= 0x3F) {
                        // nothing to do, this is a "parameter byte" we dont want it
                    } else if (0x20 <= csi_char and csi_char <= 0x2F) {
                        // still nothing to do, "intermediate byte", we also dont want it
                    }
                    if (0x40 <= csi_char and csi_char <= 0x7E) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        is_control_sequence = false;
                        done = true;
                    }
                } else if (is_device_control_sequence) {
                    // do we need to do things?
                } else if (is_operating_system_control_sequence) {
                    if (csi_char == control_chars.bel or csi_char == 0x9C) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        is_operating_system_control_sequence = false;
                        done = true;
                    }
                } else {
                    if (0x40 <= csi_char and csi_char <= 0x7E) {
                        // sequence is complete, continue iterating through haystack at csi_idx
                        is_escaped = false;
                        done = true;
                    }
                }

                haystack_idx += 1;

                if (done) {
                    break;
                }
            }

            continue;
        }

        // after checking for the csi/ocs/dcs bits we can check for single char control sequences
        if (is_escaped and (0x20 < char and char < 0x7F)) {
            // standard one byte escape sequence, we don't really care about the
            // specific sequence, we just want to get rid of those bytes :)
            is_escaped = false;

            haystack_idx += 1;
            continue;
        }

        // if we've made it this far, hooray! we want this char!
        haystack_idx += 1;

        processed[processed_idx] = char;
        processed_idx += 1;
    }

    return allocator.realloc(processed, processed_idx);
}

test "stripAnsiiControlSequences" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "no change",
            .haystack = "foo",
            .expected = "foo",
        },
        .{
            .name = "BEL",
            .haystack = "foo \x07 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "BS",
            .haystack = "foo \x08 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "HT",
            .haystack = "foo \x09 bar",
            .expected = "foo  bar",
        },
        // we are *not* stripping line feeds, but we could :)
        .{
            .name = "LF",
            .haystack = "foo \x0A bar",
            .expected = "foo \x0A bar",
        },
        .{
            .name = "VT",
            .haystack = "foo \x0B bar",
            .expected = "foo  bar",
        },
        .{
            .name = "FF",
            .haystack = "foo \x0C bar",
            .expected = "foo  bar",
        },
        // we are *not* stripping carriage returns
        .{
            .name = "CR",
            .haystack = "foo \x0D bar",
            .expected = "foo \x0D bar",
        },
        .{
            .name = "DEL",
            .haystack = "foo \x7F bar",
            .expected = "foo  bar",
        },
        .{
            .name = "NEL",
            .haystack = "foo \x1BE bar",
            .expected = "foo  bar",
        },
        .{
            .name = "DEC",
            .haystack = "foo \x1B7 bar",
            .expected = "foo  bar",
        },
        .{
            .name = "color text",
            .haystack = "\x1B[31mRedText\x1B[0m",
            .expected = "RedText",
        },
        .{
            .name = "simple prompt",
            .haystack = "[admin@router: \x1b[1m/\x1b[0;0m]$",
            .expected = "[admin@router: /]$",
        },
        .{
            .name = "simple save cursor position",
            .haystack = "somestuff\x1b7someotherstuff",
            .expected = "somestuffsomeotherstuff",
        },
        .{
            .name = "simple dont mess with newlines",
            .haystack = "Hello\x1B[31mRed\x1B[0m\\nWorld\x07",
            .expected = "HelloRed\\nWorld",
        },
        .{
            .name = "strip cursor controls",
            .haystack = "\x1B[m\x1B[27m\x1B[24mroot@server[~]# \x1B[K\x1B[?2004h",
            .expected = "root@server[~]# ",
        },
        .{
            .name = "some pager output",
            .haystack = "\x1b[7mCTRL+C\x1b[0m \x1b[7mESC\x1b[0m \x1b[7mq\x1b[0m Quit \x1b[7mSPACE\x1b[0m \x1b[7mn\x1b[0m Next Page \x1b[7mENTER\x1b[0m Next Entry \x1b[7ma\x1b[0m All\x1b[1A\x1b[59C\x1b[27m",
            .expected = "CTRL+C ESC q Quit SPACE n Next Page ENTER Next Entry a All",
        },
        .{
            .name = "underline",
            .haystack = "\x1B[4mcake\x1B[0m",
            .expected = "cake",
        },
        .{
            .name = "underline with some leading stuff",
            .haystack = "foo\x1B[4mcake\x1B[0m",
            .expected = "foocake",
        },
        .{
            .name = "lots of arguments",
            .haystack = "\x1B[00;38;5;244m\x1B[m\x1B[00;38;5;33mfoo\x1B[0m",
            .expected = "foo",
        },
        .{
            .name = "lots of arguments with text at the end",
            .haystack = "foo\x1B[0;33;49;3;9;4mbar",
            .expected = "foobar",
        },
        .{
            .name = "lots of save restore cursor",
            .haystack = "\x1b7c\x1b8\x1b[1C\x1b7o\x1b8\x1b[1C\x1b7n\x1b8\x1b[1C\x1b7f\x1b8\x1b[1C\x1b7i\x1b8\x1b[1C\x1b7g\x1b8\x1b[1C\x1b7u\x1b8\x1b[1C\x1b7r\x1b8\x1b[1C\x1b7e\x1b8\x1b[1C",
            .expected = "configure",
        },
        .{
            .name = "terminal title",
            .haystack = "\x1b[?2004h\x1b]0;user@line5-cpe-0: ~\x07user@line5-cpe-0:~$",
            .expected = "user@line5-cpe-0:~$",
        },
        .{
            .name = "more os control codes",
            .haystack = "\x1b[?6l\x1b[1;80r\x1b[?7h\x1b[2J\x1b[1;1H\x1b[1920;1920H\x1b[6n\x1b[1;1HYour previous successful login (as manager) was on 2024-05-24 11:29:02     \n from X.X.X.X\n\x1b[1;80r\x1b[80;1H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[80;1HHOSTNAME# \x1b[80;1H\x1b[80;20H\x1b[80;1H\x1b[?25h\x1b[80;20H\x1b[1;0H\x1b[1M\x1b[80;1H\x1b[1L\x1b[80;20H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[1;80r\x1b[80;1H\x1b[1;80r\x1b[80;1H\x1b[80;1H\x1b[2K\x1b[80;1H\x1b[?25h\x1b[80;1H\x1b[80;1HHOSTNAME# \x1b[80;1H\x1b[80;20H\x1b[80;1H\x1b[?25h\x1b[80;20H",
            .expected = "Your previous successful login (as manager) was on 2024-05-24 11:29:02     \n from X.X.X.X\nHOSTNAME# HOSTNAME# ",
        },
        .{
            .name = "clear screen",
            .haystack = "Last login: Thu Sep 26 10:29:38 2024 \nFOO BAR BAZ.\n\nroot@truenas[~]# \x1B[K\x1B[?2004h\x08ls -al",
            .expected = "Last login: Thu Sep 26 10:29:38 2024 \nFOO BAR BAZ.\n\nroot@truenas[~]# ls -al",
        },
        .{
            .name = "powerlevel 10k prompt",
            .haystack = "\x1B[0m\x1B[27m\x1B[24m\x1B[J\x1B[0m\x1B[49m\x1B[39m\x1B[A\x1B[0m\x1B[48;5;238m\x1B[38;5;180m carl@c1-1\x1B[0m\x1B[38;5;180m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;180m \x1B[0m\x1B[38;5;180m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;246m|\x1B[0m\x1B[38;5;246m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m \x1B[1m\x1B[38;5;31m\x1B[48;5;238m\x1B[38;5;39m~\x1B[0m\x1B[38;5;39m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m\x1B[0m\x1B[38;5;31m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;31m \x1B[0m\x1B[38;5;31m\x1B[48;5;238m\x1B[49m\x1B[38;5;238m\x1B[0m\x1B[38;5;238m\x1B[49m\x1B[39m\x1B[38;5;242m...........................................\x1B[0m\x1B[38;5;242m\x1B[48;5;238m\x1B[38;5;134m kubernetes-admin@c1\x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;134m\x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[48;5;238m\x1B[38;5;134m \x1B[0m\x1B[38;5;134m\x1B[48;5;238m\x1B[49m\x1B[39m\x1B[0m\x1B[49m\x1B[39m\x1B[0m\x1B[49m\x1B[38;5;76m\x1B[0m\x1B[38;5;76m\x1B[49m\x1B[38;5;76m\x1B[0m\x1B[38;5;76m\x1B[49m\x1B[30m\x1B[0m\x1B[30m\x1B[49m\x1B[39m \x1B[0m\x1B[49m\x1B[39m\x1B[K\x1B[?1h\x1B[?25h\x1B[?2004h",
            .expected = " carl@c1-1 | ~ ........................................... kubernetes-admin@c1  ",
        },
        .{
            .name = "multi byte char",
            .haystack = "foo ❯ bar",
            .expected = "foo ❯ bar",
        },
        .{
            .name = "eos prompt",
            .haystack = "\x0A\x1B\x5B\x35\x6e\x65\x6F\x73\x31\x3E",
            .expected = "\neos1>",
        },
        .{
            .name = "more eos prompt/login",
            .haystack = "Warning: Permanently added '[localhost]:22022' (ED25519) to the list of known hosts.\x1B\x4D\x1B\x4D\x1B\x4C \x1B\x4D(admin@localhost) Password: \x1B\x4D\x1B\x4C Last login: Thu Dec 26 22:02:14 2024 from 172.20.20.1\x1B\x4D\x1B\x4D\x1B\x4C \x1B\x5B5neos1>\x1B\x4D\x1B\x4C eos1>",
            .expected = "Warning: Permanently added '[localhost]:22022' (ED25519) to the list of known hosts. (admin@localhost) Password:  Last login: Thu Dec 26 22:02:14 2024 from 172.20.20.1 eos1> eos1>",
        },
    };

    for (cases) |case| {
        const actual = try stripAnsiiControlSequences(
            std.testing.allocator,
            case.haystack,
        );
        defer std.testing.allocator.free(actual);

        try thelper.testStrResult("stripAnsiiControlSequences", case.name, actual, case.expected);
    }
}
