const std = @import("std");

const ascii = @import("ascii.zig");
const auth = @import("auth.zig");
const bytes = @import("bytes.zig");
const bytes_check = @import("bytes-check.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const operation = @import("cli-operation.zig");
const queue = @import("queue.zig");
const re = @import("re.zig");
const transport = @import("transport.zig");

const default_return_char: []const u8 = "\n";

// default initial reserve for the per-session scratch buffers (~8x the default read size);
// in theory this should be large enough to hold lots of outputs from devices like show version
// or even show run from a not super wildly huge device (a simple 8 port 3560 w/ some generic
// config is ~7k chars, so... not going to hold a massive core router or stack config but its also
// big enough to be a good baseline).
const default_scratch_initial_size: u64 = 32_768;
// max space to retain in the scratch -- we dont want this to be too high because this is like a
// bare min floor our memory utilization will be at even if there is literally nothign happening,
// so... twice the default size seems ok.
const default_scratch_retain_max: u64 = 2 * default_scratch_initial_size;

const ReadThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
};

/// Defines possible destinations for "recording" session output.
pub const RecordDestination = union(enum) {
    writer: std.Io.File.Writer,
    f: []const u8,
    cb: *const fn (buf: *const []u8) callconv(.c) void,
    ffi: struct {
        user_data: usize,
        cb: *const fn (user_data: usize, buf: *const []u8) callconv(.c) void,
    },
};

const Recorder = struct {
    rd: ?RecordDestination,
    recorder: ?std.Io.File.Writer,

    fn init(io: std.Io, rd: ?RecordDestination, buf: []u8) !Recorder {
        const destination = rd orelse return Recorder{
            .rd = null,
            .recorder = null,
        };

        switch (destination) {
            .f => |path| {
                const out_f = try std.Io.Dir.cwd().createFile(
                    io,
                    path,
                    .{},
                );

                return Recorder{
                    .rd = destination,
                    .recorder = out_f.writer(io, buf),
                };
            },
            .writer => |writer| {
                return Recorder{
                    .rd = destination,
                    .recorder = writer,
                };
            },
            .cb, .ffi => {
                return Recorder{
                    .rd = destination,
                    .recorder = null,
                };
            },
        }
    }

    fn close(self: *Recorder, io: std.Io) !void {
        if (self.rd) |rd| {
            defer self.rd = null;

            switch (rd) {
                .f => {
                    // when just given a file path we'll "own" that lifecycle and close/cleanup
                    // as well as ensure we strip asci/ansi bits (so the file is easy to read etc.
                    // and especially for tests!); otherwise we'll leave it to the user
                    try self.recorder.?.interface.flush();
                    self.recorder.?.file.close(io);
                    self.recorder = null;

                    try ascii.stripAsciiAndAnsiControlCharsInFile(io, rd.f);
                },
                else => {},
            }
        }
    }

    fn write(self: *Recorder, buf: []u8) !void {
        if (self.rd) |rd| {
            switch (rd) {
                .f, .writer => {
                    const r = &self.recorder.?.interface;
                    try r.writeAll(buf);
                    try r.flush();
                },
                .cb => {
                    rd.cb(&buf);
                },
                .ffi => |f| {
                    f.cb(f.user_data, &buf);
                },
            }
        }
    }
};

/// Holds session options.
pub const Options = struct {
    read_size: u64 = 4_096,
    read_min_delay_ns: u64 = 5_000,
    read_max_delay_ns: u64 = 15_000_000,
    return_char: []const u8 = default_return_char,
    operation_timeout_ns: u64 = 10_000_000_000,
    operation_max_search_depth: u64 = 512,
    record_destination: ?RecordDestination = null,
    scratch_initial_size: u64 = default_scratch_initial_size,
    // scratch capacity is shrunk back to this many bytes when an operation leaves it larger,
    // so a single huge operation does not pin memory for the life of the session. should
    // generally be >= scratch_initial_size.
    scratch_retain_max: u64 = default_scratch_retain_max,

    normalize_line_feeds: bool = true,
    normalize_trailing_whitespace: bool = true,

    fn init(
        allocator: std.mem.Allocator,
        opts: Options,
    ) !Options {
        var o = opts;

        // reset the owned pointer fields so the owned copy only ever holds pointers this init
        // actually duped -- that way a failure partway through only frees memory we own, never
        // the caller's
        o.return_char = default_return_char;
        o.record_destination = null;

        errdefer o.deinit(allocator);

        if (opts.return_char.ptr != default_return_char.ptr) {
            o.return_char = try allocator.dupe(u8, opts.return_char);
        }

        if (opts.record_destination) |rd| {
            switch (rd) {
                .f => {
                    o.record_destination = RecordDestination{
                        .f = try allocator.dupe(u8, rd.f),
                    };
                },
                else => {
                    o.record_destination = rd;
                },
            }
        }

        return o;
    }

    fn deinit(self: Options, allocator: std.mem.Allocator) void {
        if (self.return_char.ptr != default_return_char.ptr) {
            allocator.free(self.return_char);
        }

        if (self.record_destination) |rd| {
            switch (rd) {
                .f => {
                    allocator.free(rd.f);
                },
                else => {},
            }
        }
    }
};

/// Session is the thing that wraps the transport and provides some logic for taking data from the
/// transport and storing it until a user requests that data. It also provides conveinence wrappers
/// for things like sending a return character, handling possible "in session" authentication,
/// and sending inputs and reading until the next "prompt" is available.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    log: logging.Logger,
    options: Options,
    auth_options: auth.Options,

    transport: transport.Transport,

    read_thread: ?std.Thread = null,
    read_stop: std.atomic.Value(ReadThreadState) = std.atomic.Value(ReadThreadState).init(
        ReadThreadState.uninitialized,
    ),
    read_lock: std.Io.Mutex,
    read_queue: queue.LinearFifo(u8),
    read_thread_errored: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    read_thread_error: ?anyerror = null,
    read_into_buf: []u8,
    read_loop_buf: []u8,

    recorder_buf: [1024]u8 = @splat(0),
    recorder: Recorder = .{
        .rd = null,
        .recorder = null,
    },

    compiled_username_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_password_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_private_key_passphrase_pattern: ?*re.pcre2CompiledPattern = null,

    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*re.pcre2CompiledPattern = null,
    prompt_excludes: ?[]const []const u8 = null,

    last_consumed_prompt: std.ArrayList(u8) = .empty,

    last_error: errors.LastError = .{},

    // reusable scratch buffers for building operation output; owned by the session and reset
    // at the start of each op so we dont reallocate every time
    scratch: bytes.ProcessedBuf,

    /// Initializes the session object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        log: logging.Logger,
        prompt_pattern: []const u8,
        prompt_excludes: ?[]const []const u8,
        options: Options,
        auth_options: auth.Options,
        transport_options: transport.Options,
    ) !Session {
        logging.traceWithSrc(log, @src(), "session.Session init requested", .{});

        var o = try Options.init(allocator, options);
        errdefer o.deinit(allocator);

        var t = try transport.Transport.init(
            allocator,
            io,
            log,
            transport_options,
        );
        errdefer t.deinit();

        var s = Session{
            .allocator = allocator,
            .io = io,
            .log = log,
            .options = o,
            .auth_options = auth_options,
            .transport = t,
            .read_lock = std.Io.Mutex.init,
            .read_queue = queue.LinearFifo(u8).init(allocator),
            .read_into_buf = &[_]u8{},
            .read_loop_buf = &[_]u8{},
            .prompt_pattern = prompt_pattern,
            .prompt_excludes = prompt_excludes,
            .scratch = .{
                .normalize_line_feeds = o.normalize_line_feeds,
                .normalize_trailing_whitespace = o.normalize_trailing_whitespace,
            },
        };
        errdefer s.deinit();

        s.read_into_buf = try allocator.alloc(u8, o.read_size);
        s.read_loop_buf = try allocator.alloc(u8, o.read_size);

        try s.scratch.reserve(allocator, s.options.scratch_initial_size);

        s.compiled_username_pattern = re.pcre2Compile(s.auth_options.username_pattern) orelse
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compiling username pattern {s}",
                .{s.auth_options.username_pattern},
            );

        s.compiled_password_pattern = re.pcre2Compile(s.auth_options.password_pattern) orelse
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compiling password pattern {s}",
                .{s.auth_options.password_pattern},
            );

        s.compiled_private_key_passphrase_pattern = re.pcre2Compile(
            s.auth_options.private_key_passphrase_pattern,
        ) orelse
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compiling passphrase pattern {s}",
                .{s.auth_options.private_key_passphrase_pattern},
            );

        s.compiled_prompt_pattern = re.pcre2Compile(s.prompt_pattern) orelse
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compiling prompt pattern {s}",
                .{s.prompt_pattern},
            );

        return s;
    }

    /// Deinitializes the session object.
    pub fn deinit(self: *Session) void {
        logging.traceWithSrc(self.log, @src(), "session.Session deinit requested", .{});

        // ensure we always call close to tidy up the recorder and transport, even if the session
        // never reached the "run" state, close is idempotent so its worst case an extra function
        // call but who cares
        // zlint-disable-next-line suppressed-errors
        self.close() catch |err| {
            self.log.warn(
                "session.Session deinit: close returned an error '{}', ignoring",
                .{err},
            );
        };

        self.last_consumed_prompt.deinit(self.allocator);

        self.allocator.free(self.read_into_buf);
        self.allocator.free(self.read_loop_buf);

        if (self.compiled_username_pattern) |compiled_pattern| {
            re.pcre2Free(compiled_pattern);
        }

        if (self.compiled_password_pattern) |compiled_pattern| {
            re.pcre2Free(compiled_pattern);
        }

        if (self.compiled_private_key_passphrase_pattern) |compiled_pattern| {
            re.pcre2Free(compiled_pattern);
        }

        if (self.compiled_prompt_pattern) |compiled_pattern| {
            re.pcre2Free(compiled_pattern);
        }

        self.transport.deinit();
        self.read_queue.deinit();
        self.scratch.deinit(self.allocator);
    }

    /// Opens the session object, starting the background read thread, and ensuring the underlying
    /// transport is opened, authenticated, and ready to accept reads/writes.
    pub fn open(
        self: *Session,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        cancel: ?*bool,
    ) ![2][]const u8 {
        self.log.info("session.Session open requested", .{});

        if (self.read_thread != null) {
            self.log.critical("session.Session open requested but session already opened", .{});

            return errors.ScrapliError.Session;
        }

        self.recorder = try Recorder.init(
            self.io,
            self.options.record_destination,
            &self.recorder_buf,
        );

        const start_time = std.Io.Timestamp.now(self.io, .awake);

        try self.transport.open(
            start_time,
            cancel,
            self.options.operation_timeout_ns,
            host,
            port,
            self.auth_options,
        );

        self.read_stop.store(ReadThreadState.run, std.lang.AtomicOrder.unordered);

        self.read_thread = std.Thread.spawn(
            .{},
            Session.readLoop,
            .{self},
        ) catch |err| {
            const last_error = "session.Session open: failed spawning read thread";

            self.last_error.set(last_error);

            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                last_error,
                .{},
            );
        };

        if (!self.auth_options.force_in_session_auth) {
            if (!self.transport.isInSessionAuth()) {
                // not forcing in session auth, and the transport is not requiring it, done
                return [2][]const u8{ "", "" };
            }

            if (self.auth_options.bypass_in_session_auth) {
                // not forcing, and user wants to bypass, done
                return [2][]const u8{ "", "" };
            }
        }

        return self.authenticate(
            allocator,
            start_time,
            cancel,
        );
    }

    /// Closes the session, stopping the read thread, unblocking any in flight reads of the
    /// transport, flushing the recorder, and finally closing the transport object itself.
    pub fn close(self: *Session) !void {
        self.log.info("session.Session close requested", .{});

        self.read_stop.store(ReadThreadState.stop, std.lang.AtomicOrder.unordered);

        var prepare_close_err: ?anyerror = null;

        // need to unblock the transport waiter after signaling the read thread to stop, this will
        // stop the waiter (which happens in transport.read), then the readloop can nicely exit
        self.transport.prepareClose() catch |err| {
            prepare_close_err = err;
        };

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }

        try self.recorder.close(self.io);

        self.transport.close();

        if (prepare_close_err) |err| {
            return err;
        }
    }

    fn readLoop(self: *Session) void {
        self.readLoopInner() catch |err| {
            self.read_thread_error = err;
            self.read_thread_errored.store(true, std.lang.AtomicOrder.release);
        };
    }

    fn readLoopInner(self: *Session) !void {
        self.log.info("session.Session read thread started", .{});

        const buf = self.read_loop_buf;

        while (self.read_stop.load(std.lang.AtomicOrder.acquire) == ReadThreadState.run) {
            const n = try self.transport.read(buf);

            if (self.read_stop.load(std.lang.AtomicOrder.acquire) != ReadThreadState.run) {
                // read was interrupted
                return;
            }

            if (n == 0) {
                continue;
            }

            {
                try self.read_lock.lock(self.io);
                defer self.read_lock.unlock(self.io);

                try self.read_queue.write(buf[0..n]);
            }

            // log all the reads w/ ascii unprintables shown
            logging.traceWithSrc(
                self.log,
                @src(),
                "session.Session readLoop: raw read '{f}'",
                .{std.ascii.hexEscape(buf[0..n], .lower)},
            );

            try self.recorder.write(buf[0..n]);
        }

        self.log.info("session.Session read thread stopped", .{});
    }

    /// Reads from the internal queue into the given buffer.
    pub fn read(self: *Session, buf: []u8) !usize {
        // the readableLength peek below is outside of the lock, it cant be concurrently accessed
        // rn, but... in the future if something changes it potentially could so just heads up
        if (self.read_thread_errored.load(std.lang.AtomicOrder.acquire) and
            self.read_queue.readableLength() == 0)
        {
            // once the read thread is errored out and there is nothing else to
            // read
            if (self.read_thread_error) |err| {
                return err;
            }

            return errors.ScrapliError.EOF;
        }

        try self.read_lock.lock(self.io);
        defer self.read_lock.unlock(self.io);

        return self.read_queue.read(buf);
    }

    /// Writes the given buffer to the transport -- redacted ensures we do not show the input in
    /// the logging output.
    pub fn write(self: *Session, buf: []const u8, redacted: bool) !void {
        if (!redacted) {
            self.log.debug(
                "session.Session write requested, buf: '{f}'",
                .{std.ascii.hexEscape(buf, .lower)},
            );
        } else {
            self.log.debug("session.Session write: buf: <redacted>", .{});
        }

        try self.transport.write(buf);
    }

    /// Writes the configured return character to the transport.
    pub fn writeReturn(self: *Session) !void {
        self.log.debug("session.Session writeReturn requested", .{});

        try self.write(self.options.return_char, false);
    }

    /// Writes the given buffer to the transport, then sends the return character.
    pub fn writeAndReturn(
        self: *Session,
        buf: []const u8,
        redacted: bool,
    ) !void {
        try self.write(buf, redacted);
        try self.writeReturn();
    }

    fn authenticate(
        self: *Session,
        allocator: std.mem.Allocator,
        start_timestamp: std.Io.Timestamp,
        cancel: ?*bool,
    ) ![2][]const u8 {
        self.log.info("session.Session authenticate requested", .{});

        var cur_read_delay_ns: u64 = self.options.read_min_delay_ns;

        const bufs = &self.scratch;
        try bufs.reset(self.allocator, self.options.scratch_retain_max);

        var cur_check_start_idx: usize = 0;

        var auth_username_prompt_seen_count: u8 = 0;
        var auth_password_prompt_seen_count: u8 = 0;
        var auth_passphrase_prompt_seen_count: u8 = 0;

        const buf = self.read_into_buf;

        errdefer {
            // need to unblock the transport waiter after signaling the read thread to stop, this
            // will stop the waiter (which happens in transport.read), then the readloop can nicely
            // exit; users should always be defering/calling deinit anyway but... this feels like
            // a nice extra layer of sanity
            self.read_stop.store(ReadThreadState.stop, std.lang.AtomicOrder.unordered);
            // zlinter-disable-next-line no_swallow_error - best effort
            self.transport.prepareClose() catch {};
        }

        while (true) {
            if (cancel != null and cancel.?.*) {
                const last_error = "session.Session authenticate: operation cancelled";

                self.last_error.set(last_error);

                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            }

            if (self.options.operation_timeout_ns != 0) {
                const ns_since_start = start_timestamp.untilNow(self.io, .awake).nanoseconds;

                if (ns_since_start > self.options.operation_timeout_ns) {
                    self.last_error.set("session.Session authenticate: operation timeout exceeded");

                    return errors.wrapCriticalError(
                        errors.ScrapliError.TimeoutExceeded,
                        @src(),
                        self.log,
                        "session.Session authenticate: operation timeout exceeded. " ++
                            "{d}ns since start, {d}ns timeout",
                        .{
                            ns_since_start,
                            self.options.operation_timeout_ns,
                        },
                    );
                }
            }

            const n = self.read(buf) catch |err| {
                switch (err) {
                    errors.ScrapliError.EOF => {
                        // hitting eof in auth/open means we likely got a connection refused or
                        // something similar. we gotta slurp up the buffer to read it and check so
                        // we can *hopefully* return a decent error message to the user
                        const error_message = try auth.openMessageHandler(bufs.processed.items);

                        if (error_message) |msg| {
                            self.last_error.setFmt(
                                "session.Session authenticate: open failed, error: '{s}'",
                                .{msg},
                                "session.Session authenticate: open failed, EOF",
                            );

                            return errors.wrapCriticalError(
                                errors.ScrapliError.Transport,
                                @src(),
                                self.log,
                                "session.Session authenticate: open failed, error: '{s}'",
                                .{msg},
                            );
                        }

                        self.last_error.set("session.Session authenticate: open failed");

                        return errors.wrapCriticalError(
                            errors.ScrapliError.Transport,
                            @src(),
                            self.log,
                            "session.Session authenticate: open failed",
                            .{},
                        );
                    },
                    else => {
                        return err;
                    },
                }
            };

            if (n == 0) {
                self.io.sleep(
                    .{
                        .nanoseconds = cur_read_delay_ns,
                    },
                    .awake,
                ) catch |err| {
                    self.log.warn(
                        "session.Session authenticate: sleep error '{}', ignoring",
                        .{err},
                    );
                };

                cur_read_delay_ns = Session.getReadBackoff(
                    cur_read_delay_ns,
                    self.options.read_max_delay_ns,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_min_delay_ns;
            }

            try bufs.appendWithProcessing(self.allocator, buf[0..n]);

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[cur_check_start_idx..],
                self.options.operation_max_search_depth,
            );

            const error_message = try auth.openMessageHandler(bufs.processed.items);

            if (error_message) |msg| {
                self.last_error.setFmt(
                    "session.Session authenticate: open failed, error: '{s}'",
                    .{msg},
                    "session.Session authenticate: error in stdout",
                );

                return errors.wrapCriticalError(
                    errors.ScrapliError.Session,
                    @src(),
                    self.log,
                    "session.Session authenticate: open failed, error: '{s}'",
                    .{msg},
                );
            }

            const state = try auth.processSearchableAuthBuf(
                searchable_buf,
                self.compiled_prompt_pattern,
                self.compiled_username_pattern,
                self.compiled_password_pattern,
                self.compiled_private_key_passphrase_pattern,
            );

            switch (state) {
                .complete => {
                    return bufs.dupeOwnedSlices(allocator);
                },
                .username_prompted => {
                    if (self.auth_options.username) |un| {
                        auth_username_prompt_seen_count += 1;

                        if (auth_username_prompt_seen_count > 2) {
                            const last_error = "session.Session authenticate: username prompt " ++
                                "seen multiple times, assuming authentication failed";

                            self.last_error.set(last_error);

                            return errors.wrapCriticalError(
                                errors.ScrapliError.Session,
                                @src(),
                                self.log,
                                last_error,
                                .{},
                            );
                        }

                        try self.writeAndReturn(un, true);

                        cur_check_start_idx = bufs.processed.items.len;

                        continue;
                    } else {
                        const last_error = "session.Session authenticate: username prompt seen " ++
                            "but no username set";

                        self.last_error.set(last_error);

                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            last_error,
                            .{},
                        );
                    }
                },
                .password_prompted => {
                    if (self.auth_options.password) |pw| {
                        auth_password_prompt_seen_count += 1;

                        if (auth_password_prompt_seen_count > 2) {
                            const last_error = "session.Session authenticate: password prompt  " ++
                                "seen multiple times, assuming authentication failed";

                            self.last_error.set(last_error);

                            return errors.wrapCriticalError(
                                errors.ScrapliError.Session,
                                @src(),
                                self.log,
                                last_error,
                                .{},
                            );
                        }

                        try self.writeAndReturn(
                            self.auth_options.resolveAuthValue(
                                pw,
                            ) catch |err| {
                                self.last_error.set(
                                    "session.Session authenticate: failed resolving auth " ++
                                        "lookup value",
                                );

                                return errors.wrapCriticalError(
                                    err,
                                    @src(),
                                    self.log,
                                    "session.Session authenticate: failed resolving auth " ++
                                        "lookup value '{s}'",
                                    .{pw},
                                );
                            },
                            true,
                        );

                        cur_check_start_idx = bufs.processed.items.len;

                        continue;
                    } else {
                        const last_error = "session.Session authenticate: password prompt seen " ++
                            "but no password set";

                        self.last_error.set(last_error);

                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            last_error,
                            .{},
                        );
                    }
                },
                .passphrase_prompted => {
                    if (self.auth_options.private_key_passphrase) |pk| {
                        auth_passphrase_prompt_seen_count += 1;

                        if (auth_passphrase_prompt_seen_count > 2) {
                            const last_error = "session.Session authenticate: private key " ++
                                "passphrase prompt seen multiple times, assuming authentication " ++
                                "failed";

                            self.last_error.set(last_error);

                            return errors.wrapCriticalError(
                                errors.ScrapliError.Session,
                                @src(),
                                self.log,
                                last_error,
                                .{},
                            );
                        }

                        try self.writeAndReturn(
                            self.auth_options.resolveAuthValue(
                                pk,
                            ) catch |err| {
                                self.last_error.set(
                                    "session.Session authenticate: failed resolving auth " ++
                                        "lookup value",
                                );

                                return errors.wrapCriticalError(
                                    err,
                                    @src(),
                                    self.log,
                                    "session.Session authenticate: failed resolving auth " ++
                                        "lookup value '{s}'",
                                    .{pk},
                                );
                            },
                            true,
                        );

                        cur_check_start_idx = bufs.processed.items.len;
                    } else {
                        const last_error = "session.Session authenticate: private key " ++
                            "passphrase prompt seen but no passphrase set";

                        self.last_error.set(last_error);

                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            last_error,
                            .{},
                        );
                    }
                },
                ._continue => {},
            }
        }
    }

    fn getReadBackoff(
        cur_val: u64,
        max_val: u64,
    ) u64 {
        var new_val: u64 = cur_val;

        if (new_val == 0) {
            new_val = 1;
        }

        new_val *= 2;
        if (new_val > max_val) {
            new_val = max_val;
        }

        return new_val;
    }

    /// Reads until cancellation or timeout exceeded, or, more preferrably, until the expected
    /// output is seen in the transport output.
    pub fn readTimeout(
        self: *Session,
        start_timestamp: std.Io.Timestamp,
        cancel: ?*bool,
        check_f: bytes_check.CheckF,
        check_args: bytes_check.CheckArgs,
        bufs: *bytes.ProcessedBuf,
        search_depth: u64,
    ) !bytes_check.MatchPositions {
        self.log.debug(
            "session.Session readTimeout requested. start timestamp ms: {d}, search depth: {d}",
            .{ start_timestamp.toNanoseconds(), search_depth },
        );

        var cur_read_delay_ns: u64 = self.options.read_min_delay_ns;

        // to ensure the check_read_operation_done function doesnt think we are done "early" by
        // finding a match from an earlier prompt we snag the len of the processed buf then we
        // just send that to the end of the buffer to the check func, we have to make sure we
        // increase the found start/end positions by this value too!
        const op_processed_buf_starting_len = bufs.processed.items.len;

        const buf = self.read_into_buf;

        while (true) {
            if (cancel != null and cancel.?.*) {
                const last_error = "session.Session readTimeout: operation cancelled";

                self.last_error.set(last_error);

                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    last_error,
                    .{},
                );
            }

            if (self.options.operation_timeout_ns != 0) {
                const ns_since_start = start_timestamp.untilNow(self.io, .awake).nanoseconds;

                if (ns_since_start > self.options.operation_timeout_ns) {
                    self.last_error.set("session.Session readTimeout: operation timeout exceeded");

                    return errors.wrapCriticalError(
                        errors.ScrapliError.TimeoutExceeded,
                        @src(),
                        self.log,
                        "session.Session readTimeout: operation timeout exceeded. " ++
                            "{d}ns since start, {d}ns timeout",
                        .{
                            ns_since_start,
                            self.options.operation_timeout_ns,
                        },
                    );
                }
            }

            const n = try self.read(buf);

            if (n == 0) {
                self.io.sleep(
                    .{
                        .nanoseconds = cur_read_delay_ns,
                    },
                    .awake,
                ) catch |err| {
                    self.log.warn(
                        "session.Session readTimeout: sleep error '{}', ignoring",
                        .{err},
                    );
                };

                cur_read_delay_ns = Session.getReadBackoff(
                    cur_read_delay_ns,
                    self.options.read_max_delay_ns,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_min_delay_ns;
            }

            try bufs.appendWithProcessing(self.allocator, buf[0..n]);

            // weve logged "raw" reads in the readloop, now that we have processed something
            // (ProcessedBuf handles ascii filtering on appendSlice) we can show the processed bits
            logging.traceWithSrc(
                self.log,
                @src(),
                "session.Session readTimeout: processed read: '{s}'",
                .{bufs.processed.items},
            );

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[op_processed_buf_starting_len..],
                search_depth,
            );

            var match_indexes = try check_f(check_args, searchable_buf);

            logging.traceWithSrc(
                self.log,
                @src(),
                "session.Session readTimeout: processed_len {d}, searchable_len {d}, " ++
                    "match start/end in searchable buf {d}/{d}, " ++
                    "searchable_buf '{s}'",
                .{
                    bufs.processed.items.len,
                    searchable_buf.len,
                    match_indexes.start,
                    match_indexes.end,
                    searchable_buf,
                },
            );

            if (!(match_indexes.start == 0 and match_indexes.end == 0)) {
                match_indexes.start += (bufs.processed.items.len - searchable_buf.len);
                match_indexes.end += (bufs.processed.items.len - searchable_buf.len);

                self.log.debug(
                    "session.Session readTimeout: found check match in " ++
                        "searchable buffer '{s}', match: '{s}'",
                    .{
                        searchable_buf,
                        // i think its only a test transport issue but we can have a processed
                        // items that is v short, so obviously, in order to be defensive we can
                        // just get min of either what we want or the buf we are looking into
                        bufs.processed.items[match_indexes.start..@min(
                            match_indexes.end,
                            bufs.processed.items.len,
                        )],
                    },
                );

                return match_indexes;
            }
        }
    }

    /// Reads any amount of content out of the transport.
    pub fn readAny(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.ReadAnyOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session readAny requested", .{});

        const bufs = &self.scratch;
        try bufs.reset(self.allocator, self.options.scratch_retain_max);

        // read_any is a raw window into the stream, *not* a complete operation result -- the
        // normalization "leading"/"trailing" rules only make sense when an operation is a whole
        // logical result, but a read_any op is an arbitrary slice of the stream (and callers,
        // like readWithCallbacks, concatenate those slices!). left on, every fragment-boundary
        // newline would get journaled away as "leading"/"trailing" and the concatenated output
        // would collapse into one giant line. so: no normalization at all for read_any.
        const normalize_line_feeds = bufs.normalize_line_feeds;
        const normalize_trailing_whitespace = bufs.normalize_trailing_whitespace;

        bufs.normalize_line_feeds = false;
        bufs.normalize_trailing_whitespace = false;

        defer {
            bufs.normalize_line_feeds = normalize_line_feeds;
            bufs.normalize_trailing_whitespace = normalize_trailing_whitespace;
        }

        const start_time = std.Io.Timestamp.now(self.io, .awake);

        _ = try self.readTimeout(
            start_time,
            options.cancel,
            bytes_check.nonZeroBuf,
            .{},
            bufs,
            self.options.operation_max_search_depth,
        );

        return bufs.dupeOwnedSlices(allocator);
    }

    /// Gets the current "prompt" from the device -- for Cli connections usually -- the prompt is
    /// defined by the prompt pattern passed in from the higher level Cli or Netconf object.
    pub fn getPrompt(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.GetPromptOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session getPrompt requested", .{});

        try self.writeReturn();

        const bufs = &self.scratch;
        try bufs.reset(self.allocator, self.options.scratch_retain_max);

        const start_time = std.Io.Timestamp.now(self.io, .awake);

        const match_indexes = try self.readTimeout(
            start_time,
            options.cancel,
            bytes_check.patternInBuf,
            .{
                .pattern = self.compiled_prompt_pattern,
                .excludes = self.prompt_excludes,
            },
            bufs,
            self.options.operation_max_search_depth,
        );

        // use the match positions readTimeout already found rather than re-searching -- a
        // re-search could land on an earlier (i.e. prompt exclude filtered) match. defensively
        // clamp the end since readTimeout positions are relative to the processed buf
        const found_prompt = bufs.processed.items[match_indexes.start..@min(
            match_indexes.end,
            bufs.processed.items.len,
        )];

        // the match is a view into the (reused) scratch buffer, and both consumers need their
        // own copy with their own allocator: the caller owns the returned prompt (operation
        // allocator), and the session retains its own (session allocator) for prepending to
        // the next operation's buf
        const owned_found_prompt = try allocator.dupe(u8, found_prompt);
        errdefer allocator.free(owned_found_prompt);

        // we want to ensure we are storing the last consumed prompt so that our send_input
        // buf is always "correct" when "retain_input" is true
        self.last_consumed_prompt.clearRetainingCapacity();
        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            found_prompt,
        );

        // TODO probably just return the found prompt here instead?
        // the "processed" side of a getPrompt result is only ever the prompt itself, so we just
        // return an empty string for the raw side of things.
        return [2][]const u8{ try allocator.dupe(u8, ""), owned_found_prompt };
    }

    fn innerSendInput(
        self: *Session,
        start_time: std.Io.Timestamp,
        cancel: ?*bool,
        input: []const u8,
        input_handling: operation.InputHandling,
        redact_input: bool,
        bufs: *bytes.ProcessedBuf,
    ) !bytes_check.MatchPositions {
        logging.traceWithSrc(
            self.log,
            @src(),
            "session.Session innerSendInput: input_handling '{s}', input_len {d}, input '{s}'",
            .{
                @tagName(input_handling),
                input.len,
                if (redact_input) "<redacted>" else input,
            },
        );

        const check_args = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = input,
        };

        try self.write(input, redact_input);

        var match_indexes: bytes_check.MatchPositions = .{ .start = 0, .end = 0 };

        var search_depth = self.options.operation_max_search_depth;
        if (input.len >= search_depth) {
            // if/when a user has an enormous input we obviously need to have a searchable buf that
            // is larger than that, but we *probably* also will end up having the device writing
            // backspace chars into what we read back from the device so we need to account for that
            // if this still doesnt work users can always set a really high max search depth *or*
            // use ignore input handling
            search_depth = input.len * 4;
        }

        switch (input_handling) {
            .exact => {
                match_indexes = try self.readTimeout(
                    start_time,
                    cancel,
                    bytes_check.exactInBuf,
                    check_args,
                    bufs,
                    search_depth,
                );
            },
            .fuzzy => {
                match_indexes = try self.readTimeout(
                    start_time,
                    cancel,
                    bytes_check.fuzzyInBuf,
                    check_args,
                    bufs,
                    search_depth,
                );
            },
            .ignore => {
                // ignore, not reading input; to not break our saftey rule above we return here
                // when in "ignore" handling mode
                try self.writeReturn();

                return match_indexes;
            },
        }

        try self.writeReturn();

        return match_indexes;
    }

    fn prependLastConsumedPrompt(self: *Session, bufs: *bytes.ProcessedBuf) !void {
        if (self.last_consumed_prompt.items.len == 0) {
            return;
        }

        try bufs.appendWithProcessing(self.allocator, self.last_consumed_prompt.items);
        try self.last_consumed_prompt.resize(self.allocator, 0);
    }

    fn storeLastConsumedPrompt(
        self: *Session,
        buf: []const u8,
    ) !void {
        try self.last_consumed_prompt.appendSlice(self.allocator, buf);
    }

    /// Sends the given input to the transport, reading until the input is written, then sending
    /// return, then reading until the next prompt is read. It returns two buffers -- the
    /// journaled "raw" buffer, from which the raw/unprocessed content read from the device can
    /// be reconstructed on demand (see bytes.reconstructRaw), and the "processed" buffer, that
    /// is the content that was processed -- i.e. had ascii/ansi control chars removed to give
    /// only human readable text output.
    pub fn sendInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendInputOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session sendInput requested", .{});
        self.log.debug("session.Session sendInput: input '{s}'", .{options.input});

        const start_time = std.Io.Timestamp.now(self.io, .awake);

        const bufs = &self.scratch;
        try bufs.reset(self.allocator, self.options.scratch_retain_max);

        try self.prependLastConsumedPrompt(bufs);

        _ = try self.innerSendInput(
            start_time,
            options.cancel,
            options.input,
            options.input_handling,
            false,
            bufs,
        );

        if (!options.retain_input) {
            // if we dont want to retain inputs trim *everything* read so far (the input
            // echo) out of the processed buf -- it lands in the raw journal so the raw
            // output still contains it
            try bufs.rightTrimProcessed(self.allocator, 0);
        }

        const check_args = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = options.input,
            .excludes = self.prompt_excludes,
        };

        const prompt_indexes = try self.readTimeout(
            start_time,
            options.cancel,
            bytes_check.patternInBuf,
            check_args,
            bufs,
            self.options.operation_max_search_depth,
        );

        try self.storeLastConsumedPrompt(
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // trim the trailing prompt (and anything after it, which should be nothing)
            // out of the processed buf -- it lands in the raw journal so the raw output
            // still contains it
            try bufs.rightTrimProcessed(
                self.allocator,
                prompt_indexes.start,
            );
        }

        return bufs.dupeOwnedSlices(allocator);
    }

    /// Sends an input to the device -- an input that initiates some kind of "prompted" response by
    /// the user. Typically this is used for writing something like "enable" or "sudo su" and
    /// handling the password prompt that the device returns, but it can be used to handle anything
    /// where a user sends input and a non-standard (meaning not matchable by the normal prompt
    /// pattern) is returned which then requires another input/action from the user.
    pub fn sendPromptedInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendPromptedInputOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session sendPromptedInput requested", .{});
        self.log.debug(
            "session.Session sendPromptedInput: input '{s}', response '{s}'",
            .{
                options.input,
                if (options.hidden_response) "<redacted>" else options.response,
            },
        );

        const start_time = std.Io.Timestamp.now(self.io, .awake);

        var compiled_pattern: ?*re.pcre2CompiledPattern = null;

        if (options.prompt_pattern) |pattern| {
            if (pattern.len > 0) {
                compiled_pattern = re.pcre2Compile(pattern) orelse {
                    self.last_error.set(
                        "session.Session sendPromptedInput: failed compiling pattern",
                    );

                    return errors.wrapCriticalError(
                        errors.ScrapliError.Driver,
                        @src(),
                        self.log,
                        "session.Session sendPromptedInput: failed compiling pattern '{s}'",
                        .{pattern},
                    );
                };
            }
        }

        defer {
            if (compiled_pattern) |p| {
                re.pcre2Free(p);
            }
        }

        errdefer if (options.abort_input) |abort_input| {
            self.writeAndReturn(abort_input, false) catch |err| {
                self.log.critical(
                    "session.Session sendPromptedInput: failed sending abort sequence " ++
                        "after error in prompted input, err: {}",
                    .{err},
                );
            };
        };

        const bufs = &self.scratch;
        try bufs.reset(self.allocator, self.options.scratch_retain_max);

        try self.prependLastConsumedPrompt(bufs);

        _ = try self.innerSendInput(
            start_time,
            options.cancel,
            options.input,
            options.input_handling,
            false,
            bufs,
        );

        const response_check_f: bytes_check.CheckF =
            if (compiled_pattern) |_| &bytes_check.anyPatternInBuf else &bytes_check.exactInBuf;

        var check_args = bytes_check.CheckArgs{
            .actual = options.prompt_exact,
            .excludes = self.prompt_excludes,
        };

        if (compiled_pattern) |cp| {
            check_args.patterns = &[_]?*re.pcre2CompiledPattern{
                self.compiled_prompt_pattern,
                cp,
            };
        } else {
            check_args.pattern = self.compiled_prompt_pattern;
        }

        _ = try self.readTimeout(
            start_time,
            options.cancel,
            response_check_f,
            check_args,
            bufs,
            self.options.operation_max_search_depth,
        );

        if (!options.hidden_response) {
            try self.writeAndReturn(options.response, options.hidden_response);
        } else {
            _ = try self.innerSendInput(
                start_time,
                options.cancel,
                options.response,
                options.input_handling,
                true,
                bufs,
            );
        }

        const prompt_indexes = try self.readTimeout(
            start_time,
            options.cancel,
            bytes_check.patternInBuf,
            check_args,
            bufs,
            self.options.operation_max_search_depth,
        );

        try self.storeLastConsumedPrompt(
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // trim the trailing prompt (and anything after it, which should be nothing)
            // out of the processed buf -- it lands in the raw journal so the raw output
            // still contains it
            try bufs.rightTrimProcessed(
                self.allocator,
                prompt_indexes.start,
            );
        }

        return bufs.dupeOwnedSlices(allocator);
    }
};

test "sessionInit" {
    var o = try Options.init(std.testing.allocator, .{});

    var s = try Session.init(
        std.testing.allocator,
        std.testing.io,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
        ">",
        null,
        o,
        .{},
        .{
            .bin = .{},
        },
    );

    s.deinit();
    o.deinit(std.testing.allocator);
}

test "refAllDecls" {
    std.testing.refAllDecls(Session);
}

fn sessionInitForAllocFailures(allocator: std.mem.Allocator) !void {
    var s = try Session.init(
        allocator,
        std.testing.io,
        logging.Logger{
            .allocator = allocator,
        },
        ">",
        null,
        .{},
        .{},
        .{
            .bin = .{},
        },
    );

    s.deinit();
}

test "sessionInitAllocationFailures" {
    // fail each allocation in the init path once, proving the errdefer/deinit unwind neither
    // leaks nor touches uninitialized state under real allocation failure
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        sessionInitForAllocFailures,
        .{},
    );
}

fn optionsInitForAllocFailures(allocator: std.mem.Allocator) !void {
    // options w/ all owned fields populated so allocation failures at any point during the
    // copy exercise the partial-failure cleanup path (and would catch any invalid free of
    // caller owned memory)
    const o = try Options.init(
        allocator,
        .{
            .return_char = "\r\n",
            .record_destination = .{
                .f = "record-out.log",
            },
        },
    );

    o.deinit(allocator);
}

test "optionsInitAllocationFailures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        optionsInitForAllocFailures,
        .{},
    );
}
