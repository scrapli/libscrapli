const std = @import("std");
const auth = @import("auth.zig");
const file = @import("file.zig");
const logger = @import("logger.zig");
const strings = @import("strings.zig");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "500");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
});

extern fn setsid() callconv(.C) i32;
extern fn ioctl(fd: i32, request: u32, arg: usize) callconv(.C) i32;

const default_ssh_bin: []const u8 = "/usr/bin/ssh";
const default_term_height: u16 = 255;
const default_term_width: u16 = 80;

pub const OptionsInputs = struct {
    bin: []const u8 = default_ssh_bin,

    // extra means append to "standard" args, override overides everything except for the bin,
    // if you want to override the bin you can do that, just set .bin field. both of these options
    // should be space delimited values like you would pass on the cli -- i.e.
    // "-o ProxyCommand='foo' -P 1234" etc.
    extra_open_args: ?[]const u8 = null,
    override_open_args: ?[]const u8 = null,

    ssh_config_path: ?[]const u8 = null,
    known_hosts_path: ?[]const u8 = null,

    enable_strict_key: bool = false,

    term_height: u16 = default_term_height,
    term_width: u16 = default_term_width,

    netconf: bool = false,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    bin: []const u8,
    extra_open_args: ?[]const u8,
    override_open_args: ?[]const u8,
    ssh_config_path: ?[]const u8,
    known_hosts_path: ?[]const u8,
    enable_strict_key: bool,
    term_height: u16,
    term_width: u16,
    netconf: bool,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .bin = opts.bin,
            .extra_open_args = opts.extra_open_args,
            .override_open_args = opts.override_open_args,
            .ssh_config_path = opts.ssh_config_path,
            .known_hosts_path = opts.known_hosts_path,
            .enable_strict_key = opts.enable_strict_key,
            .term_height = opts.term_height,
            .term_width = opts.term_width,
            .netconf = opts.netconf,
        };

        if (&o.bin[0] != &default_ssh_bin[0]) {
            o.bin = try o.allocator.dupe(u8, o.bin);
        }

        if (o.extra_open_args != null) {
            o.extra_open_args = try o.allocator.dupe(u8, o.extra_open_args.?);
        }

        if (o.override_open_args != null) {
            o.override_open_args = try o.allocator.dupe(u8, o.override_open_args.?);
        }

        if (o.ssh_config_path != null) {
            o.ssh_config_path = try o.allocator.dupe(u8, o.ssh_config_path.?);
        }

        if (o.known_hosts_path != null) {
            o.known_hosts_path = try o.allocator.dupe(u8, o.known_hosts_path.?);
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        if (&self.bin[0] != &default_ssh_bin[0]) {
            self.allocator.free(self.bin);
        }

        if (self.extra_open_args != null) {
            self.allocator.free(self.extra_open_args.?);
        }

        if (self.override_open_args != null) {
            self.allocator.free(self.override_open_args.?);
        }

        if (self.ssh_config_path != null) {
            self.allocator.free(self.ssh_config_path.?);
        }

        if (self.known_hosts_path != null) {
            self.allocator.free(self.known_hosts_path.?);
        }

        self.allocator.destroy(self);
    }
};

pub fn NewTransport(
    allocator: std.mem.Allocator,
    log: logger.Logger,
    options: *Options,
) !*Transport {
    const t = try allocator.create(Transport);

    t.* = Transport{
        .allocator = allocator,
        .log = log,
        .options = options,
        .f = null,
        .reader = null,
        .writer = null,
        .open_args = std.ArrayList(strings.MaybeHeapString).init(allocator),
    };

    return t;
}

pub const Transport = struct {
    allocator: std.mem.Allocator,
    log: logger.Logger,

    options: *Options,

    f: ?std.fs.File,
    reader: ?std.fs.File.Reader,
    writer: ?std.fs.File.Writer,

    open_args: std.ArrayList(strings.MaybeHeapString),

    pub fn init(self: *Transport) !void {
        _ = self;
    }

    pub fn deinit(self: *Transport) void {
        for (self.open_args.items) |*arg| {
            arg.deinit();
        }

        self.open_args.deinit();
        self.allocator.destroy(self);
    }

    fn buildArgs(
        self: *Transport,
        host: []const u8,
        port: u16,
        auth_options: *auth.Options,
        operation_timeout_ns: u64,
    ) !void {
        if (self.options.override_open_args != null) {
            var override_args_iterator = std.mem.splitSequence(
                u8,
                self.options.override_open_args.?,
                " ",
            );

            while (override_args_iterator.next()) |arg| {
                try self.open_args.append(
                    strings.MaybeHeapString{
                        .allocator = null,
                        .string = arg,
                    },
                );
            }

            return;
        }

        try self.open_args.append(
            strings.MaybeHeapString{
                .allocator = null,
                .string = self.options.bin,
            },
        );

        try self.open_args.append(
            strings.MaybeHeapString{
                .allocator = null,
                .string = host,
            },
        );

        try self.open_args.append(
            strings.MaybeHeapString{
                .allocator = null,
                .string = "-p",
            },
        );

        try self.open_args.append(
            strings.MaybeHeapString{
                .allocator = self.allocator,
                .string = try std.fmt.allocPrint(
                    self.allocator,
                    "{d}",
                    .{port},
                ),
            },
        );

        if (operation_timeout_ns != 0) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-o",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = self.allocator,
                    .string = try std.fmt.allocPrint(
                        self.allocator,
                        "ConnectTimeout={d}",
                        .{operation_timeout_ns / std.time.ns_per_s},
                    ),
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-o",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = self.allocator,
                    .string = try std.fmt.allocPrint(
                        self.allocator,
                        "ServerAliveInterval={d}",
                        .{operation_timeout_ns / std.time.ns_per_s},
                    ),
                },
            );
        }

        if (auth_options.username != null) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-l",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = auth_options.username.?,
                },
            );
        }

        if (auth_options.private_key_path != null) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-i",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = auth_options.private_key_path.?,
                },
            );
        }

        if (self.options.ssh_config_path != null) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-F",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = self.options.ssh_config_path.?,
                },
            );
        }

        if (self.options.enable_strict_key) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-o",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "StrictHostKeyChecking=yes",
                },
            );
        }

        if (self.options.known_hosts_path != null) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-o",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = self.allocator,
                    .string = try std.fmt.allocPrint(
                        self.allocator,
                        "UserKnownHostsFile={s}",
                        .{self.options.known_hosts_path.?},
                    ),
                },
            );
        }

        if (self.options.extra_open_args != null and self.options.extra_open_args.?.len > 0) {
            var extra_args_iterator = std.mem.splitSequence(
                u8,
                self.options.extra_open_args.?,
                " ",
            );

            while (extra_args_iterator.next()) |arg| {
                try self.open_args.append(
                    strings.MaybeHeapString{
                        .allocator = null,
                        .string = arg,
                    },
                );
            }
        }

        if (self.options.netconf) {
            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "-s",
                },
            );

            try self.open_args.append(
                strings.MaybeHeapString{
                    .allocator = null,
                    .string = "netconf",
                },
            );
        }
    }

    pub fn open(
        self: *Transport,
        operation_timeout_ns: u64,
        host: []const u8,
        port: u16,
        auth_options: *auth.Options,
    ) !void {
        self.buildArgs(host, port, auth_options, operation_timeout_ns) catch |err| {
            self.log.critical("failed generating open command, err: {}", .{err});

            return error.OpenFailed;
        };

        const open_args = self.allocator.alloc([]const u8, self.open_args.items.len) catch |err| {
            self.log.critical("failed preparing open command, err: {}", .{err});

            return error.OpenFailed;
        };
        defer self.allocator.free(open_args);

        for (self.open_args.items, 0..) |arg, idx| {
            open_args[idx] = arg.string;
        }

        self.log.debug("bin transport opening with args: {s}", .{open_args});

        self.f = openPty(
            self.allocator,
            open_args,
            self.options.term_width,
            self.options.term_height,
            self.options.netconf,
        ) catch |err| {
            self.log.critical("failed inizializing master_fd, err: {}", .{err});

            return error.OpenFailed;
        };

        self.reader = self.f.?.reader();
        self.writer = self.f.?.writer();
    }

    pub fn close(self: *Transport) void {
        if (self.f != null) {
            self.f.?.close();
        }

        self.f = null;
    }

    pub fn write(self: *Transport, buf: []const u8) !void {
        if (self.writer == null) {
            return error.NotOpened;
        }

        self.writer.?.writeAll(buf) catch |err| {
            self.log.critical("failed writing to pty, err: {}", .{err});

            return error.WriteFailed;
        };
    }

    pub fn read(self: *Transport, buf: []u8) !usize {
        if (self.reader == null) {
            return error.NotOpened;
        }

        const n = self.reader.?.read(buf) catch |err| {
            switch (err) {
                error.WouldBlock => {
                    return 0;
                },
                else => {
                    self.log.critical("failed reading from pty, err: {}", .{err});

                    return error.ReadFailed;
                },
            }
        };

        if (n == 0) {
            self.log.critical("read from pty returned zero bytes read", .{});

            // this should kill the read loop, but the main program will be killed from session
            return error.ReadFailed;
        }

        return n;
    }
};

fn openPty(
    allocator: std.mem.Allocator,
    open_args: [][]const u8,
    term_width: u16,
    term_height: u16,
    netconf: bool,
) !std.fs.File {
    const master_fd = try std.fs.openFileAbsolute("/dev/ptmx", .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    if (c.grantpt(master_fd.handle) < 0) return error.PtyCreationFailed;
    if (c.unlockpt(master_fd.handle) < 0) return error.PtyCreationFailed;

    const s_name = c.ptsname(master_fd.handle);

    const slave_fd = try std.fs.openFileAbsoluteZ(s_name, .{
        .mode = .read_write,
        .allow_ctty = true,
    });

    // ensure the pty is non blocking
    try file.setNonBlocking(master_fd.handle);

    const pid = c.fork();

    if (pid < 0) {
        return error.ForkFailed;
    } else if (pid == 0) {
        // child process
        const args = try allocator.allocSentinel(?[*:0]const u8, open_args.len, null);
        defer allocator.free(args);

        for (open_args, 0..) |arg, i| {
            const duped_arg = try allocator.dupeZ(u8, arg);

            args[i] = duped_arg.ptr;
        }

        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        const envs = try allocator.allocSentinel(?[*:0]const u8, env_map.count(), null);
        var i: usize = 0;

        var env_map_iter = env_map.iterator();
        while (env_map_iter.next()) |pair| {
            envs[i] = try std.fmt.allocPrintZ(
                allocator,
                "{s}={s}",
                .{ pair.key_ptr.*, pair.value_ptr.* },
            );
            i += 1;
        }

        // if things fail it will be a little annoying but we'll just have to read the stdout/stderr
        // to see what happened
        try openPtyChild(
            master_fd,
            slave_fd,
            args,
            envs,
            term_width,
            term_height,
            netconf,
        );
    }

    // parent process, close the slave and return the master (pty) to read/write to
    std.posix.close(slave_fd.handle);

    return master_fd;
}

fn openPtyChild(
    master_fd: std.fs.File,
    slave_fd: std.fs.File,
    args: [:null]?[*:0]const u8,
    envs: [:null]?[*:0]const u8,
    term_width: u16,
    term_height: u16,
    netconf: bool,
) !void {
    std.posix.close(master_fd.handle);

    // calling setsid and ioctl to set ctty in zig os.linux functions does *not* work for...
    // reasons? but... the C bits work juuuuust fine
    if (setsid() == -1) {
        return error.PtyCreationFailedSetSid;
    }

    if (ioctl(slave_fd.handle, c.TIOCSCTTY, 0) == -1) {
        return error.PtyCreationFailedSetCtty;
    }

    if (!netconf) {
        const set_win_size_rc = ioctl(
            slave_fd.handle,
            c.TIOCSWINSZ,
            @intFromPtr(
                &c.winsize{
                    .ws_row = term_height,
                    .ws_col = term_width,
                    .ws_ypixel = 0,
                    .ws_xpixel = 0,
                },
            ),
        );
        if (set_win_size_rc != 0) {
            return error.PtyCreationFailedSetWinSize;
        }
    }

    try std.posix.dup2(slave_fd.handle, 0); // stdin
    try std.posix.dup2(slave_fd.handle, 1); // stdout
    try std.posix.dup2(slave_fd.handle, 2); // stderr

    std.posix.close(slave_fd.handle);

    // zlint-disable suppressed-errors
    std.posix.execvpeZ(args.ptr[0].?, args.ptr, envs.ptr) catch {};
}
