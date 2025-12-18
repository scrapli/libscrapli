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

const ReadThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
};

/// Defines possible destinations for "recording" session output.
pub const RecordDestination = union(enum) {
    writer: std.fs.File.Writer,
    f: []const u8,
    cb: *const fn (buf: *const []u8) callconv(.c) void,
};

const Recorder = struct {
    rd: ?RecordDestination,
    recorder: ?std.fs.File.Writer,

    fn init(rd: ?RecordDestination, buf: []u8) !Recorder {
        if (rd == null) {
            return Recorder{
                .rd = rd,
                .recorder = null,
            };
        }

        switch (rd.?) {
            .f => {
                const out_f = try std.fs.cwd().createFile(
                    rd.?.f,
                    .{},
                );

                return Recorder{
                    .rd = rd,
                    .recorder = out_f.writer(buf),
                };
            },
            .writer => {
                return Recorder{
                    .rd = rd,
                    .recorder = rd.?.writer,
                };
            },
            .cb => {
                return Recorder{
                    .rd = rd,
                    .recorder = null,
                };
            },
        }
    }

    fn close(self: *Recorder, io: std.Io) !void {
        if (self.rd) |rd| {
            switch (rd) {
                .f => {
                    // when just given a file path we'll "own" that lifecycle and close/cleanup
                    // as well as ensure we strip asci/ansi bits (so the file is easy to read etc.
                    // and especially for tests!); otherwise we'll leave it to the user
                    try self.recorder.?.interface.flush();
                    self.recorder.?.file.close();

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
            }
        }
    }
};

/// Holds option inputs for the session.
pub const OptionsInputs = struct {
    read_size: u64 = 4_096,
    read_min_delay_ns: u64 = 5_000,
    read_max_delay_ns: u64 = 15_000_000,
    return_char: []const u8 = default_return_char,
    operation_timeout_ns: u64 = 10_000_000_000,
    operation_max_search_depth: u64 = 512,
    record_destination: ?RecordDestination = null,
};

/// Holds session options.
pub const Options = struct {
    allocator: std.mem.Allocator,
    read_size: u64 = 4_096,
    read_min_delay_ns: u64 = 5_000,
    read_max_delay_ns: u64 = 15_000_000,
    return_char: []const u8 = default_return_char,
    operation_timeout_ns: u64 = 10_000_000_000,
    operation_max_search_depth: u64 = 512,
    record_destination: ?RecordDestination = null,

    /// Initializes the session options. Heap allocating fields we need to live as long as the
    /// session object so we always have those available.
    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .read_size = opts.read_size,
            .read_min_delay_ns = opts.read_min_delay_ns,
            .read_max_delay_ns = opts.read_max_delay_ns,
            .return_char = opts.return_char,
            .operation_timeout_ns = opts.operation_timeout_ns,
            .operation_max_search_depth = opts.operation_max_search_depth,
            .record_destination = opts.record_destination,
        };

        if (&o.return_char[0] != &default_return_char[0]) {
            o.return_char = try o.allocator.dupe(u8, o.return_char);
        }

        if (o.record_destination) |rd| {
            switch (rd) {
                .f => {
                    o.record_destination = RecordDestination{
                        .f = try o.allocator.dupe(u8, rd.f),
                    };
                },
                else => {},
            }
        }

        return o;
    }

    /// Deinitializes the session options.
    pub fn deinit(self: *Options) void {
        if (&self.return_char[0] != &default_return_char[0]) {
            self.allocator.free(self.return_char);
        }

        if (self.record_destination) |rd| {
            switch (rd) {
                .f => {
                    self.allocator.free(rd.f);
                },
                else => {},
            }
        }

        self.allocator.destroy(self);
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
    options: *Options,
    auth_options: *auth.Options,

    transport: *transport.Transport,

    read_thread: ?std.Thread,
    read_stop: std.atomic.Value(ReadThreadState),
    read_lock: std.Thread.Mutex,
    read_queue: queue.LinearFifo(
        u8,
        .dynamic,
    ),
    read_thread_errored: bool = false,

    recorder_buf: [1024]u8 = undefined,
    recorder: Recorder,

    compiled_username_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_password_pattern: ?*re.pcre2CompiledPattern = null,
    compiled_private_key_passphrase_pattern: ?*re.pcre2CompiledPattern = null,

    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*re.pcre2CompiledPattern = null,

    last_consumed_prompt: std.ArrayList(u8),

    /// Initializes the session object.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        log: logging.Logger,
        prompt_pattern: []const u8,
        options: *Options,
        auth_options: *auth.Options,
        transport_options: *transport.Options,
    ) !*Session {
        logging.traceWithSrc(log, @src(), "session.Session initializing", .{});

        const t = try transport.Transport.init(
            allocator,
            io,
            log,
            transport_options,
        );
        errdefer t.deinit();

        const s = try allocator.create(Session);

        s.* = Session{
            .allocator = allocator,
            .io = io,
            .log = log,
            .options = options,
            .auth_options = auth_options,
            .transport = t,
            .read_thread = null,
            .read_stop = std.atomic.Value(ReadThreadState).init(ReadThreadState.uninitialized),
            .read_lock = std.Thread.Mutex{},
            .read_queue = queue.LinearFifo(
                u8,
                .dynamic,
            ).init(allocator),
            .recorder = try Recorder.init(options.record_destination, &s.recorder_buf),
            .prompt_pattern = prompt_pattern,
            .last_consumed_prompt = .{},
        };
        errdefer s.deinit();

        s.compiled_username_pattern = re.pcre2Compile(s.auth_options.username_pattern);
        if (s.compiled_username_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling username pattern {s}",
                .{s.auth_options.username_pattern},
            );
        }

        s.compiled_password_pattern = re.pcre2Compile(s.auth_options.password_pattern);
        if (s.compiled_password_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling password pattern {s}",
                .{s.auth_options.password_pattern},
            );
        }

        s.compiled_private_key_passphrase_pattern = re.pcre2Compile(
            s.auth_options.private_key_passphrase_pattern,
        );
        if (s.compiled_private_key_passphrase_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling passphrase pattern {s}",
                .{s.auth_options.private_key_passphrase_pattern},
            );
        }

        s.compiled_prompt_pattern = re.pcre2Compile(s.prompt_pattern);
        if (s.compiled_prompt_pattern == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                log,
                "session.Session init: failed compling prompt pattern {s}",
                .{s.prompt_pattern},
            );
        }

        return s;
    }

    /// Deinitializes the session object.
    pub fn deinit(self: *Session) void {
        logging.traceWithSrc(self.log, @src(), "session.Session deinitializing", .{});

        if (self.read_stop.load(std.builtin.AtomicOrder.acquire) == ReadThreadState.run) {
            // if for whatever reason (likely because a call to driver.open failed causing a defer
            // close to *not* trigger) the session didnt get "closed", ensure we do that...
            // but... we ignore errors here since we want deinit to return void and it really
            // shouldn't matter if something errors during close
            // zlint-disable-next-line suppressed-errors
            self.close() catch {};
        }

        // if close didnt happen and the read thread state was already set to stop, we may have not
        // shut down the read thread completely, so make sure we do that too
        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }

        self.last_consumed_prompt.deinit(self.allocator);

        if (self.compiled_username_pattern != null) {
            re.pcre2Free(self.compiled_username_pattern.?);
        }

        if (self.compiled_password_pattern != null) {
            re.pcre2Free(self.compiled_password_pattern.?);
        }

        if (self.compiled_private_key_passphrase_pattern != null) {
            re.pcre2Free(self.compiled_private_key_passphrase_pattern.?);
        }

        if (self.compiled_prompt_pattern != null) {
            re.pcre2Free(self.compiled_prompt_pattern.?);
        }

        self.transport.deinit();
        self.read_queue.deinit();

        self.allocator.destroy(self);
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

        var timer = try std.time.Timer.start();

        try self.transport.open(
            &timer,
            cancel,
            self.options.operation_timeout_ns,
            host,
            port,
            self.auth_options,
        );

        self.read_stop.store(ReadThreadState.run, std.builtin.AtomicOrder.unordered);

        self.read_thread = std.Thread.spawn(
            .{},
            Session.readLoop,
            .{self},
        ) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "session.Session open: failed spawning read thread",
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
            &timer,
            cancel,
        );
    }

    /// Closes the session, stopping the read thread, unblocking any in flight reads of the
    /// transport, flushing the recordre, and finally closing the transport object itself.
    pub fn close(self: *Session) !void {
        self.log.info("session.Session close requested", .{});

        self.read_stop.store(ReadThreadState.stop, std.builtin.AtomicOrder.unordered);

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            std.Io.Clock.Duration.sleep(
                .{
                    .clock = .awake,
                    .raw = .fromNanoseconds(self.options.read_min_delay_ns),
                },
                self.io,
            ) catch {};
        }

        // need to unblock the transport waiter after signaling the read thread to stop, this will
        // stop the waiter (which happens in transport.read), then the readloop can nicely exit
        try self.transport.unblock();

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }

        try self.recorder.close(self.io);

        self.transport.close();
    }

    fn readLoop(self: *Session) !void {
        self.log.info("session.Session read thread started", .{});

        errdefer self.read_thread_errored = true;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            const n = self.transport.read(buf) catch {
                self.read_thread_errored = true;

                return;
            };

            if (n == 0) {
                continue;
            }

            self.read_lock.lock();
            try self.read_queue.write(buf[0..n]);
            self.read_lock.unlock();

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
        self.read_lock.lock();
        defer self.read_lock.unlock();

        if (self.read_thread_errored and self.read_queue.readableLength() == 0) {
            // once the read thread is errored out and there is nothing else to
            // read
            return errors.ScrapliError.EOF;
        }

        return self.read_queue.read(buf);
    }

    /// Writes the given buffer to the transport -- redacted ensures we do not show the input in
    /// the logging output.
    pub fn write(self: *Session, buf: []const u8, redacted: bool) !void {
        self.log.info("session.Session write requested", .{});

        if (!redacted) {
            self.log.debug("session.Session write: '{f}'", .{std.ascii.hexEscape(buf, .lower)});
        } else {
            self.log.debug("session.Session write: <redacted>", .{});
        }

        try self.transport.write(buf);
    }

    /// Writes the configured return character to the transport.
    pub fn writeReturn(self: *Session) !void {
        self.log.info("session.Session writeReturn requested", .{});

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
        timer: *std.time.Timer,
        cancel: ?*bool,
    ) ![2][]const u8 {
        self.log.info("session.Session authenticate requested", .{});

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var cur_check_start_idx: usize = 0;

        var auth_username_prompt_seen_count: u8 = 0;
        var auth_password_prompt_seen_count: u8 = 0;
        var auth_passphrase_prompt_seen_count: u8 = 0;

        var buf = try allocator.alloc(u8, self.options.read_size);
        defer allocator.free(buf);

        // need to unblock the transport waiter after signaling the read thread to stop, this will
        // stop the waiter (which happens in transport.read), then the readloop can nicely exit;
        // we only need to do this here in addition to close because we
        errdefer self.transport.unblock() catch {};

        // in the case of auth, if we error out, we almost certainly need to stop the read loop
        // as the transport is probably gone from under our feet anyway.
        errdefer self.read_stop.store(ReadThreadState.stop, std.builtin.AtomicOrder.unordered);

        while (true) {
            if (cancel != null and cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "session.Session authenticate: operation cancelled",
                    .{},
                );
            }

            const elapsed_time = timer.read();

            if (self.options.operation_timeout_ns != 0 and
                elapsed_time >= self.options.operation_timeout_ns)
            {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "session.Session authenticate: operation timeout exceeded",
                    .{},
                );
            }

            const n = self.read(buf) catch |err| {
                switch (err) {
                    errors.ScrapliError.EOF => {
                        // hitting eof in auth/open means we likely got a connection refused or
                        // something similar. we gotta slurp up the buffer to read it and check so
                        // we can *hopefully* return a decent error message to the user
                        const error_message = try auth.openMessageHandler(
                            allocator,
                            bufs.processed.items,
                        );

                        if (error_message) |msg| {
                            return errors.wrapCriticalError(
                                errors.ScrapliError.Transport,
                                @src(),
                                self.log,
                                "session.Session authenticate: open failed, error: '{s}'",
                                .{msg},
                            );
                        }

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
                continue;
            }

            try bufs.appendSlice(buf[0..n]);

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[cur_check_start_idx..],
                self.options.operation_max_search_depth,
            );

            const error_message = try auth.openMessageHandler(
                allocator,
                bufs.processed.items,
            );

            if (error_message) |msg| {
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
                    return bufs.toOwnedSlices();
                },
                .username_prompted => {
                    if (self.auth_options.username == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: username prompt seen " ++
                                "but no username set",
                            .{},
                        );
                    }

                    auth_username_prompt_seen_count += 1;

                    if (auth_username_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: username prompt seen " ++
                                "multiple times, assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(self.auth_options.username.?, true);

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .password_prompted => {
                    if (self.auth_options.password == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: password prompt seen " ++
                                "but no password set",
                            .{},
                        );
                    }

                    auth_password_prompt_seen_count += 1;

                    if (auth_password_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: password prompt seen multiple times, " ++
                                "assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(
                        self.auth_options.resolveAuthValue(
                            self.auth_options.password.?,
                        ) catch |err| {
                            return errors.wrapCriticalError(
                                err,
                                @src(),
                                self.log,
                                "session.Session authenticate: failed resolving auth " ++
                                    "lookup value '{s}'",
                                .{self.auth_options.password.?},
                            );
                        },
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .passphrase_prompted => {
                    if (self.auth_options.private_key_passphrase == null) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: private key passphrase prompt " ++
                                "seen but no passphrase set",
                            .{},
                        );
                    }

                    auth_passphrase_prompt_seen_count += 1;

                    if (auth_passphrase_prompt_seen_count > 2) {
                        return errors.wrapCriticalError(
                            errors.ScrapliError.Session,
                            @src(),
                            self.log,
                            "session.Session authenticate: private key passphrase prompt " ++
                                "seen multiple times, assuming authentication failed",
                            .{},
                        );
                    }

                    try self.writeAndReturn(
                        self.auth_options.resolveAuthValue(
                            self.auth_options.private_key_passphrase.?,
                        ) catch |err| {
                            return errors.wrapCriticalError(
                                err,
                                @src(),
                                self.log,
                                "session.Session authenticate: failed resolving auth " ++
                                    "lookup value '{s}'",
                                .{self.auth_options.password.?},
                            );
                        },
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;
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
        timer: *std.time.Timer,
        cancel: ?*bool,
        checkF: bytes_check.CheckF,
        check_args: bytes_check.CheckArgs,
        bufs: *bytes.ProcessedBuf,
        search_depth: u64,
    ) !bytes_check.MatchPositions {
        self.log.info("session.Session readTimeout requested", .{});

        var cur_read_delay_ns: u64 = self.options.read_min_delay_ns;

        // to ensure the check_read_operation_done function doesnt think we are done "early" by
        // finding a match from an earlier prompt we snag the len of the processed buf then we
        // just send that to the end of the buffer to the check func, we have to make sure we
        // increase the found start/end positions by this value too!
        const op_processed_buf_starting_len = bufs.processed.items.len;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "session.Session readTimeout: operation cancelled",
                    .{},
                );
            }

            const elapsed_time = timer.read();

            // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
            // 2) to let the ffi layer via (go) context control it for example
            if (self.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) >= self.options.operation_timeout_ns)
            {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "session.Session readTimeout: operation timeout exceeded",
                    .{},
                );
            }

            defer {
                std.Io.Clock.Duration.sleep(
                    .{
                        .clock = .awake,
                        .raw = .fromNanoseconds(cur_read_delay_ns),
                    },
                    self.io,
                ) catch {};
            }

            const n = try self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = Session.getReadBackoff(
                    cur_read_delay_ns,
                    self.options.read_max_delay_ns,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_min_delay_ns;
            }

            try bufs.appendSlice(buf[0..n]);

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

            var match_indexes = try checkF(check_args, searchable_buf);

            if (!(match_indexes.start == 0 and match_indexes.end == 0)) {
                match_indexes.start += (bufs.processed.items.len - searchable_buf.len);
                match_indexes.end += (bufs.processed.items.len - searchable_buf.len) + 1;

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

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.nonZeroBuf,
            .{},
            &bufs,
            self.options.operation_max_search_depth,
        );

        return bufs.toOwnedSlices();
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

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            .{
                .pattern = self.compiled_prompt_pattern,
            },
            &bufs,
            self.options.operation_max_search_depth,
        );

        // pcre2Find returns a slice from the haystack, so we need to persist that in memory
        // through that function call (cant just return pcre2Find)
        const found_prompt = try re.pcre2Find(
            self.compiled_prompt_pattern.?,
            bufs.processed.items,
        );

        if (found_prompt == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.log,
                "session.Session getPrompt: no prompt found matching prompt pattern '{s}' in '{s}'",
                .{ self.prompt_pattern, bufs.processed.items },
            );
        }

        const owned_found_prompt = try allocator.alloc(u8, found_prompt.?.len);
        @memcpy(owned_found_prompt, found_prompt.?);

        // we want to ensure we are storing the last consumed prompt so that our send_input
        // buf is always "correct" when "retain_input" is true
        try self.last_consumed_prompt.resize(self.allocator, 0);
        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            owned_found_prompt,
        );

        return [2][]const u8{ try bufs.raw.toOwnedSlice(self.allocator), owned_found_prompt };
    }

    fn innerSendInput(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        input_handling: operation.InputHandling,
        bufs: *bytes.ProcessedBuf,
    ) !bytes_check.MatchPositions {
        const check_args = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = input,
        };

        try self.write(input, false);

        // SAFETY: will always be set or we'll error
        var match_indexes: bytes_check.MatchPositions = undefined;

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
                    timer,
                    cancel,
                    bytes_check.exactInBuf,
                    check_args,
                    bufs,
                    search_depth,
                );
            },
            .fuzzy => {
                match_indexes = try self.readTimeout(
                    timer,
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

                return bytes_check.MatchPositions{ .start = 0, .end = 0 };
            },
        }

        try self.writeReturn();

        return match_indexes;
    }

    /// Sends the given input to the transport, reading until the input is written, then sending
    /// return, then reading until the next prompt is read. It returns two buffers -- the "raw"
    /// buffer, that is the unprocessed content that we read from the device, and the "processed"
    /// buffer, that is the content that was processed -- i.e. had ascii/ansi control chars
    /// removed to give only human readable text output.
    pub fn sendInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendInputOptions,
    ) ![2][]const u8 {
        self.log.info("session.Session sendInput requested", .{});
        self.log.debug("session.Session sendInput: input '{s}'", .{options.input});

        var timer = try std.time.Timer.start();

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSlice(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(self.allocator, 0);
        }

        _ = try self.innerSendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        if (!options.retain_input) {
            // if we dont want to retain inputs, just resize the processed buffer to 0
            try bufs.processed.resize(self.allocator, 0);
        }

        const check_args = bytes_check.CheckArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = options.input,
        };

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            check_args,
            &bufs,
            self.options.operation_max_search_depth,
        );

        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                self.allocator,
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices();
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
            .{ options.input, options.response },
        );

        var timer = try std.time.Timer.start();

        var compiled_pattern: ?*re.pcre2CompiledPattern = null;

        if (options.prompt_pattern) |pattern| {
            if (pattern.len > 0) {
                compiled_pattern = re.pcre2Compile(pattern);
                if (compiled_pattern == null) {
                    return errors.wrapCriticalError(
                        errors.ScrapliError.Driver,
                        @src(),
                        self.log,
                        "session.Session sendPromptedInput: failed compiling pattern '{s}'",
                        .{pattern},
                    );
                }
            }
        }

        defer {
            if (compiled_pattern) |p| {
                re.pcre2Free(p);
            }
        }

        if (options.abort_input) |abort_input| {
            errdefer {
                self.writeAndReturn(abort_input, false) catch |err| {
                    self.log.critical(
                        "session.Session sendPromptedInput: failed sending abort sequence " ++
                            "after error in prompted input, err: {}",
                        .{err},
                    );
                };
            }
        }

        var bufs = bytes.ProcessedBuf.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSlice(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(self.allocator, 0);
        }

        _ = try self.innerSendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        var check_args = bytes_check.CheckArgs{
            .actual = options.prompt_exact,
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
            &timer,
            options.cancel,
            bytes_check.exactInBuf,
            check_args,
            &bufs,
            self.options.operation_max_search_depth,
        );

        if (!options.hidden_response) {
            try self.writeAndReturn(options.response, true);
        } else {
            _ = try self.innerSendInput(
                &timer,
                options.cancel,
                options.input,
                options.input_handling,
                &bufs,
            );
        }

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            bytes_check.patternInBuf,
            check_args,
            &bufs,
            self.options.operation_max_search_depth,
        );

        try self.last_consumed_prompt.appendSlice(
            self.allocator,
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                self.allocator,
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices();
    }
};

test "sessionInit" {
    const o = try Options.init(std.testing.allocator, .{});
    const a_o = try auth.Options.init(std.testing.allocator, .{});
    const t_o = try transport.Options.init(std.testing.allocator, .{ .bin = .{} });

    const s = try Session.init(
        std.testing.allocator,
        std.testing.io,
        logging.Logger{
            .allocator = std.testing.allocator,
        },
        ">",
        o,
        a_o,
        t_o,
    );

    s.deinit();
    o.deinit();
    a_o.deinit();
    t_o.deinit();
}
