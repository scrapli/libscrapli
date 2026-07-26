// vendored (and heavily trimmed) from the old/deprecated std.fifo.LinearFifo -- only the
// dynamic-buffer flavor survives, and only the operations libscrapli actually uses: the session
// read queue needs write/read/readableLength, and the ffi driver operation queue needs
// writeItem/readItem/count.
const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub fn LinearFifo(T: type) type {
    return struct {
        allocator: Allocator,
        buf: []T,
        head: usize,
        count: usize,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .buf = &.{},
                .head = 0,
                .count = 0,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.buf);
        }

        fn realign(self: *Self) void {
            if (self.buf.len - self.head >= self.count) {
                mem.copyForwards(T, self.buf[0..self.count], self.buf[self.head..][0..self.count]);
                self.head = 0;
            } else {
                var tmp: [4096 / 2 / @sizeOf(T)]T = undefined;

                while (self.head != 0) {
                    const n = @min(self.head, tmp.len);
                    const m = self.buf.len - n;
                    @memcpy(tmp[0..n], self.buf[0..n]);
                    mem.copyForwards(T, self.buf[0..m], self.buf[n..][0..m]);
                    @memcpy(self.buf[m..][0..n], tmp[0..n]);
                    self.head -= n;
                }
            }
            { // set unused area to undefined
                const unused = mem.sliceAsBytes(self.buf[self.count..]);
                @memset(unused, undefined);
            }
        }

        /// Ensure that the buffer can fit at least `size` items.
        fn ensureTotalCapacity(self: *Self, size: usize) error{OutOfMemory}!void {
            if (self.buf.len >= size) return;

            self.realign();

            const new_size = math.ceilPowerOfTwo(usize, size) catch return error.OutOfMemory;

            self.buf = try self.allocator.realloc(self.buf, new_size);
        }

        /// Makes sure at least `size` items are unused.
        fn ensureUnusedCapacity(self: *Self, size: usize) error{OutOfMemory}!void {
            if (self.writableLength() >= size) return;

            return try self.ensureTotalCapacity(
                math.add(usize, self.count, size) catch return error.OutOfMemory,
            );
        }

        /// Returns number of items currently in the fifo.
        pub fn readableLength(self: Self) usize {
            return self.count;
        }

        /// Returns a mutable slice from the 'read' end of the fifo.
        fn readableSliceMut(self: Self, offset: usize) []T {
            if (offset > self.count) return &[_]T{};

            var start = self.head + offset;
            if (start >= self.buf.len) {
                start -= self.buf.len;
                return self.buf[start .. start + (self.count - offset)];
            } else {
                const end = @min(self.head + self.count, self.buf.len);
                return self.buf[start..end];
            }
        }

        /// Discard first `count` items in the fifo.
        fn discard(self: *Self, count: usize) void {
            assert(count <= self.count);
            { // set old range to undefined. Note: may be wrapped around
                const slice = self.readableSliceMut(0);
                if (slice.len >= count) {
                    const unused = mem.sliceAsBytes(slice[0..count]);
                    @memset(unused, undefined);
                } else {
                    const unused = mem.sliceAsBytes(slice[0..]);
                    @memset(unused, undefined);
                    const unused2 = mem.sliceAsBytes(
                        self.readableSliceMut(slice.len)[0 .. count - slice.len],
                    );
                    @memset(unused2, undefined);
                }
            }

            var head = self.head + count;
            // note it is safe to do a wrapping subtract as bitwise & with all 1s is a noop
            head &= self.buf.len -% 1;
            self.head = head;
            self.count -= count;
        }

        /// Read the next item from the fifo.
        pub fn readItem(self: *Self) ?T {
            if (self.count == 0) return null;

            const c = self.buf[self.head];
            self.discard(1);
            return c;
        }

        /// Read data from the fifo into `dst`, returns number of items copied.
        pub fn read(self: *Self, dst: []T) usize {
            var dst_left = dst;

            while (dst_left.len > 0) {
                const slice = self.readableSliceMut(0);
                if (slice.len == 0) break;
                const n = @min(slice.len, dst_left.len);
                @memcpy(dst_left[0..n], slice[0..n]);
                self.discard(n);
                dst_left = dst_left[n..];
            }

            return dst.len - dst_left.len;
        }

        /// Returns number of items available in the fifo.
        fn writableLength(self: Self) usize {
            return self.buf.len - self.count;
        }

        /// Returns the first section of writable buffer. Note that this may be of length 0.
        fn writableSlice(self: Self, offset: usize) []T {
            if (offset > self.buf.len) return &[_]T{};

            const tail = self.head + offset + self.count;
            if (tail < self.buf.len) {
                return self.buf[tail..];
            } else {
                return self.buf[tail - self.buf.len ..][0 .. self.writableLength() - offset];
            }
        }

        /// Write a single item to the fifo, allocating more memory as necessary.
        pub fn writeItem(self: *Self, item: T) error{OutOfMemory}!void {
            try self.ensureUnusedCapacity(1);

            var tail = self.head + self.count;
            tail &= self.buf.len - 1;
            self.buf[tail] = item;
            self.count += 1;
        }

        /// Appends the data in `src` to the fifo, allocating more memory as necessary.
        pub fn write(self: *Self, src: []const T) error{OutOfMemory}!void {
            try self.ensureUnusedCapacity(src.len);

            var src_left = src;
            while (src_left.len > 0) {
                const writable_slice = self.writableSlice(0);
                assert(writable_slice.len != 0);
                const n = @min(writable_slice.len, src_left.len);
                @memcpy(writable_slice[0..n], src_left[0..n]);
                self.count += n;
                src_left = src_left[n..];
            }
        }
    };
}

test "linearFifoBytes" {
    var fifo = LinearFifo(u8).init(std.testing.allocator);
    defer fifo.deinit();

    try fifo.write("hello ");
    try fifo.write("world");

    try std.testing.expectEqual(11, fifo.readableLength());

    var buf: [16]u8 = undefined;

    try std.testing.expectEqual(5, fifo.read(buf[0..5]));
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    try fifo.write(" again");

    const n = fifo.read(&buf);
    try std.testing.expectEqual(12, n);
    try std.testing.expectEqualStrings(" world again", buf[0..n]);

    try std.testing.expectEqual(0, fifo.readableLength());
    try std.testing.expectEqual(null, fifo.readItem());
}

test "linearFifoItems" {
    const Item = struct {
        id: u32,
    };

    var fifo = LinearFifo(Item).init(std.testing.allocator);
    defer fifo.deinit();

    var next_read_id: u32 = 0;
    var next_write_id: u32 = 0;

    for (0..10) |_| {
        for (0..7) |_| {
            try fifo.writeItem(.{ .id = next_write_id });
            next_write_id += 1;
        }

        for (0..5) |_| {
            const item = fifo.readItem().?;
            try std.testing.expectEqual(next_read_id, item.id);
            next_read_id += 1;
        }
    }

    while (fifo.readItem()) |item| {
        try std.testing.expectEqual(next_read_id, item.id);
        next_read_id += 1;
    }

    try std.testing.expectEqual(next_write_id, next_read_id);
}
