const std = @import("std");
const transport = @import("transport.zig");
const re = @import("re.zig");
const bytes = @import("bytes.zig");
const operation = @import("cli-operation.zig");
const logging = @import("logging.zig");
const ascii = @import("ascii.zig");
const time = @import("time.zig");
const auth = @import("auth.zig");
const file = @import("file.zig");
const errors = @import("errors.zig");

const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const defaults = struct {
    const read_size: u64 = 4_096;
    const read_delay_min_ns: u64 = 5_000;
    const read_delay_max_ns: u64 = 7_500_000;
    const read_delay_backoff_factor: u8 = 2;
    const return_char: []const u8 = "\n";
    const operation_timeout_ns: u64 = 10_000_000_000;
    const operation_max_search_depth: u64 = 512;
};

const ReadThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
};

const ReadArgs = struct {
    pattern: ?*pcre2.pcre2_code_8 = null,
    patterns: ?[]const ?*pcre2.pcre2_code_8 = null,
    actual: ?[]const u8 = null,
};

const ReadBufs = struct {
    raw: std.ArrayList(u8),
    processed: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) ReadBufs {
        return ReadBufs{
            .raw = std.ArrayList(u8).init(allocator),
            .processed = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *ReadBufs) void {
        self.raw.deinit();
        self.processed.deinit();
    }

    fn appendSliceBoth(self: *ReadBufs, buf: []const u8) !void {
        try self.raw.appendSlice(buf);
        try self.processed.appendSlice(buf);
    }

    /// returns array of raw and processed bufs, including doing a final trimming of whitespace
    /// on the processed buf
    fn toOwnedSlices(self: *ReadBufs, allocator: std.mem.Allocator) ![2][]const u8 {
        const processed = try self.processed.toOwnedSlice();
        defer allocator.free(processed);

        return [2][]const u8{
            try self.raw.toOwnedSlice(),
            try bytes.trimWhitespace(allocator, processed),
        };
    }
};

const MatchPositions = struct {
    start: usize,
    end: usize,

    fn len(self: *MatchPositions) usize {
        if (self.end == 0) {
            return 0;
        }

        return self.end - self.start + 1;
    }
};

pub const RecordDestination = union(enum) {
    writer: std.fs.File.Writer,
    f: []const u8,
};

pub const OptionsInputs = struct {
    read_size: u64 = defaults.read_size,
    read_delay_min_ns: u64 = defaults.read_delay_min_ns,
    read_delay_max_ns: u64 = defaults.read_delay_max_ns,
    read_delay_backoff_factor: u8 = defaults.read_delay_backoff_factor,
    return_char: []const u8 = defaults.return_char,
    operation_timeout_ns: u64 = defaults.operation_timeout_ns,
    operation_max_search_depth: u64 = defaults.operation_max_search_depth,
    record_destination: ?RecordDestination = null,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    read_size: u64,
    read_delay_min_ns: u64,
    read_delay_max_ns: u64,
    read_delay_backoff_factor: u8,
    return_char: []const u8,
    operation_timeout_ns: u64,
    operation_max_search_depth: u64,
    record_destination: ?RecordDestination,

    pub fn init(allocator: std.mem.Allocator, opts: OptionsInputs) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .read_size = opts.read_size,
            .read_delay_min_ns = opts.read_delay_min_ns,
            .read_delay_max_ns = opts.read_delay_max_ns,
            .read_delay_backoff_factor = opts.read_delay_backoff_factor,
            .return_char = opts.return_char,
            .operation_timeout_ns = opts.operation_timeout_ns,
            .operation_max_search_depth = opts.operation_max_search_depth,
            .record_destination = opts.record_destination,
        };

        if (&o.return_char[0] != &defaults.return_char[0]) {
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

    pub fn deinit(self: *Options) void {
        if (&self.return_char[0] != &defaults.return_char[0]) {
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

pub const Session = struct {
    allocator: std.mem.Allocator,
    log: logging.Logger,
    options: *Options,
    auth_options: *auth.Options,
    transport: *transport.Transport,

    read_thread: ?std.Thread,
    read_stop: std.atomic.Value(ReadThreadState),
    read_lock: std.Thread.Mutex,
    read_queue: std.fifo.LinearFifo(
        u8,
        std.fifo.LinearFifoBufferType.Dynamic,
    ),

    recorder: ?std.fs.File.Writer,

    compiled_username_pattern: ?*pcre2.pcre2_code_8,
    compiled_password_pattern: ?*pcre2.pcre2_code_8,
    compiled_private_key_passphrase_pattern: ?*pcre2.pcre2_code_8,

    prompt_pattern: []const u8,
    compiled_prompt_pattern: ?*pcre2.pcre2_code_8,

    last_consumed_prompt: std.ArrayList(u8),

    pub fn init(
        allocator: std.mem.Allocator,
        log: logging.Logger,
        prompt_pattern: []const u8,
        options: *Options,
        auth_options: *auth.Options,
        transport_options: *transport.Options,
    ) !*Session {
        const t = try transport.Transport.init(
            allocator,
            log,
            transport_options,
        );
        errdefer t.deinit();

        const s = try allocator.create(Session);

        var recorder: ?std.fs.File.Writer = null;
        if (options.record_destination) |rd| {
            switch (rd) {
                .f => {
                    const out_f = try std.fs.cwd().createFile(
                        rd.f,
                        .{},
                    );

                    recorder = out_f.writer();
                    recorder.?.context = out_f;
                },
                .writer => {
                    recorder = rd.writer;
                },
            }
        }

        s.* = Session{
            .allocator = allocator,
            .log = log,
            .options = options,
            .auth_options = auth_options,
            .transport = t,
            .read_thread = null,
            .read_stop = std.atomic.Value(ReadThreadState).init(ReadThreadState.uninitialized),
            .read_lock = std.Thread.Mutex{},
            .read_queue = std.fifo.LinearFifo(
                u8,
                std.fifo.LinearFifoBufferType.Dynamic,
            ).init(allocator),
            .recorder = recorder,
            .compiled_username_pattern = null,
            .compiled_password_pattern = null,
            .compiled_private_key_passphrase_pattern = null,
            .prompt_pattern = prompt_pattern,
            .compiled_prompt_pattern = null,
            .last_consumed_prompt = std.ArrayList(u8).init(allocator),
        };
        errdefer s.deinit();

        s.compiled_username_pattern = re.pcre2Compile(s.auth_options.username_pattern);
        if (s.compiled_username_pattern == null) {
            s.log.critical(
                "failed compling username pattern {s}",
                .{s.auth_options.username_pattern},
            );

            return errors.ScrapliError.RegexError;
        }

        s.compiled_password_pattern = re.pcre2Compile(s.auth_options.password_pattern);
        if (s.compiled_password_pattern == null) {
            s.log.critical(
                "failed compling password pattern {s}",
                .{s.auth_options.password_pattern},
            );

            return errors.ScrapliError.RegexError;
        }

        s.compiled_private_key_passphrase_pattern = re.pcre2Compile(
            s.auth_options.private_key_passphrase_pattern,
        );
        if (s.compiled_private_key_passphrase_pattern == null) {
            s.log.critical(
                "failed compling passphrase pattern {s}",
                .{s.auth_options.private_key_passphrase_pattern},
            );

            return errors.ScrapliError.RegexError;
        }

        s.compiled_prompt_pattern = re.pcre2Compile(s.prompt_pattern);
        if (s.compiled_prompt_pattern == null) {
            s.log.critical("failed compling prompt pattern {s}", .{s.prompt_pattern});

            return errors.ScrapliError.RegexError;
        }

        return s;
    }

    pub fn deinit(self: *Session) void {
        if (self.read_stop.load(std.builtin.AtomicOrder.acquire) == ReadThreadState.run) {
            // if for whatever reason (likely because a call to driver.open failed causing a defer
            // close to *not* trigger) the session didnt get "closed", ensure we do that...
            // but... we ignore errors here since we want deinit to return void and it really
            // shouldn't matter if something errors during close
            // zlint-disable suppressed-errors
            self.close() catch {};
        }

        self.last_consumed_prompt.deinit();

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

    pub fn open(
        self: *Session,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        options: operation.OpenOptions,
    ) ![2][]const u8 {
        var timer = std.time.Timer.start() catch |err| {
            self.log.critical(
                "failed initializing open/authentication timer, err: {}",
                .{err},
            );

            return errors.ScrapliError.AuthenticationFailed;
        };

        try self.transport.open(
            &timer,
            options.cancel,
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
            self.log.critical("failed spawning read thread, err: {}", .{err});

            return errors.ScrapliError.OpenFailed;
        };

        const is_in_session_auth = self.transport.isInSessionAuth();

        // check if we have auth bypass or the transport handles auth for us -- if yes we are done
        if (self.auth_options.in_session_auth_bypass or !is_in_session_auth) {
            return [2][]const u8{ "", "" };
        }

        return self.authenticate(
            allocator,
            &timer,
            options.cancel,
        );
    }

    pub fn close(self: *Session) !void {
        self.read_stop.store(ReadThreadState.stop, std.builtin.AtomicOrder.unordered);

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            std.time.sleep(self.options.read_delay_min_ns);
        }

        if (self.read_thread) |t| {
            t.join();
        }

        if (self.options.record_destination) |rd| {
            switch (rd) {
                .f => {
                    // when just given a file path we'll "own" that lifecycle and close/cleanup
                    // as well as ensure we strip asci/ansi bits (so the file is easy to read etc.
                    // and especially for tests!); otherwise we'll leave it to the user
                    self.recorder.?.context.close();

                    var f = try file.ReaderFromPath(
                        self.allocator,
                        rd.f,
                    );
                    const content = try f.readAllAlloc(
                        self.allocator,
                        std.math.maxInt(usize),
                    );
                    const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(
                        content,
                        0,
                    );
                    try file.writeToPath(
                        self.allocator,
                        rd.f,
                        content[0..new_size],
                    );
                },
                else => {},
            }
        }

        self.transport.close();
    }

    fn readLoop(self: *Session) !void {
        self.log.info("read thread started", .{});

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        while (self.read_stop.load(std.builtin.AtomicOrder.acquire) != ReadThreadState.stop) {
            defer std.time.sleep(cur_read_delay_ns);

            const n = try self.transport.read(buf);

            if (n == 0) {
                cur_read_delay_ns = time.getBackoffValue(
                    cur_read_delay_ns,
                    self.options.read_delay_max_ns,
                    self.options.read_delay_backoff_factor,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }

            if (self.recorder) |recorder| {
                try recorder.writeAll(buf[0..n]);
            }

            self.read_lock.lock();
            try self.read_queue.write(buf[0..n]);
            self.read_lock.unlock();
        }

        self.log.info("read thread stopped", .{});
    }

    pub fn read(self: *Session, buf: []u8) usize {
        self.read_lock.lock();
        defer self.read_lock.unlock();

        return self.read_queue.read(buf);
    }

    pub fn write(self: *Session, buf: []const u8, redacted: bool) !void {
        if (!redacted) {
            self.log.debug("write: '{s}'", .{std.fmt.fmtSliceEscapeLower(buf)});
        }

        try self.transport.write(buf);
    }

    pub fn writeReturn(self: *Session) !void {
        try self.write(self.options.return_char, false);
    }

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
        self.log.info("in session authentication starting...", .{});

        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        var bufs = ReadBufs.init(allocator);
        defer bufs.deinit();

        var cur_check_start_idx: usize = 0;

        var auth_username_prompt_seen_count: u8 = 0;
        var auth_password_prompt_seen_count: u8 = 0;
        var auth_passphrase_prompt_seen_count: u8 = 0;

        var buf = try allocator.alloc(u8, self.options.read_size);
        defer allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            if (self.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) > self.options.operation_timeout_ns)
            {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            defer std.time.sleep(cur_read_delay_ns);

            const n = self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = time.getBackoffValue(
                    cur_read_delay_ns,
                    self.options.read_delay_max_ns,
                    self.options.read_delay_backoff_factor,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }

            try bufs.appendSliceBoth(buf[0..n]);

            if (std.mem.indexOf(u8, buf[0..n], &[_]u8{ascii.control_chars.esc}) != null) {
                // same as readTimeout other than we dont bother limiting the search depth here
                // see readTimeout for some more info
                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(
                    bufs.processed.items,
                    bufs.processed.items.len - n,
                );
                try bufs.processed.resize(new_size);

                try auth.openMessageHandler(allocator, bufs.processed.items);
            }

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[cur_check_start_idx..],
                self.options.operation_max_search_depth,
            );

            const state = try auth.processSearchableAuthBuf(
                self.allocator,
                searchable_buf,
                self.compiled_prompt_pattern,
                self.compiled_username_pattern,
                self.compiled_password_pattern,
                self.compiled_private_key_passphrase_pattern,
            );

            switch (state) {
                .complete => {
                    return bufs.toOwnedSlices(allocator);
                },
                .username_prompted => {
                    if (self.auth_options.username == null) {
                        self.log.critical(
                            "username prompt seen but no username set",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    auth_username_prompt_seen_count += 1;

                    if (auth_username_prompt_seen_count > 2) {
                        self.log.critical(
                            "username prompt seen multiple times, assuming authentication failed",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    try self.writeAndReturn(self.auth_options.username.?, true);

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .password_prompted => {
                    if (self.auth_options.password == null) {
                        self.log.critical(
                            "password prompt seen but no password set",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    auth_password_prompt_seen_count += 1;

                    if (auth_password_prompt_seen_count > 2) {
                        self.log.critical(
                            "password prompt seen multiple times, assuming authentication failed",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    try self.writeAndReturn(
                        try self.auth_options.resolveAuthValue(
                            self.auth_options.password.?,
                        ),
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;

                    continue;
                },
                .passphrase_prompted => {
                    if (self.auth_options.private_key_passphrase == null) {
                        self.log.critical(
                            "private key passphrase prompt seen but no passphrase set",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    auth_passphrase_prompt_seen_count += 1;

                    if (auth_passphrase_prompt_seen_count > 2) {
                        self.log.critical(
                            "private key passphrase prompt seen multiple times, assuming authentication failed",
                            .{},
                        );

                        return errors.ScrapliError.AuthenticationFailed;
                    }

                    try self.writeAndReturn(
                        try self.auth_options.resolveAuthValue(
                            self.auth_options.private_key_passphrase.?,
                        ),
                        true,
                    );

                    cur_check_start_idx = bufs.processed.items.len;
                },
                ._continue => {},
            }
        }
    }

    fn readTimeout(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        check_read_operation_done: fn (buf: []u8, args: ReadArgs) anyerror!MatchPositions,
        args: ReadArgs,
        bufs: *ReadBufs,
    ) !MatchPositions {
        var cur_read_delay_ns: u64 = self.options.read_delay_min_ns;

        // to ensure the check_read_operation_done function doesnt think we are done "early" by
        // finding a match from an earlier prompt we snag the len of the processed buf then we
        // just send that to the end of the buffer to the check func, we have to make sure we
        // increase the found start/end positions by this value too!
        const op_processed_buf_starting_len = bufs.processed.items.len;

        var buf = try self.allocator.alloc(u8, self.options.read_size);
        defer self.allocator.free(buf);

        while (true) {
            if (cancel != null and cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return errors.ScrapliError.Cancelled;
            }

            const elapsed_time = timer.read();

            // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
            // 2) to let the ffi layer via (go) context control it for example
            if (self.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) > self.options.operation_timeout_ns)
            {
                self.log.critical("op timeout exceeded", .{});

                return errors.ScrapliError.TimeoutExceeded;
            }

            defer std.time.sleep(cur_read_delay_ns);

            const n = self.read(buf);

            if (n == 0) {
                cur_read_delay_ns = time.getBackoffValue(
                    cur_read_delay_ns,
                    self.options.read_delay_max_ns,
                    self.options.read_delay_backoff_factor,
                );

                continue;
            } else {
                cur_read_delay_ns = self.options.read_delay_min_ns;
            }
            // TODO -- could experiment w/ *not* doing the processing/check on every single read
            //  -- basically an inverse backoff where we check less times in the start of an op
            //  then more, maybe up till every time after some duration/amount of checks? the idea
            //  would be that every time we search we do a re and that is expensive/slow, so if we
            //  can save on that that would be a win

            try bufs.appendSliceBoth(buf[0..n]);

            if (std.mem.indexOf(u8, buf[0..n], &[_]u8{ascii.control_chars.esc}) != null) {
                // if ESC in the new buf look at last n of processed buf to replace if
                // necessary; this *feels* bad like we may miss sequences (if our read gets part
                // of a sequence, then a subsequent read gets the rest), however this has never
                // happened in 5+ years of scrapli/scrapligo only checking/cleaning the read buf
                // so we are going to roll with it and hope :)
                const new_size = ascii.stripAsciiAndAnsiControlCharsInPlace(
                    bufs.processed.items,
                    bufs.processed.items.len - n,
                );
                try bufs.processed.resize(new_size);
            }

            const searchable_buf = bytes.getBufSearchView(
                bufs.processed.items[op_processed_buf_starting_len..],
                self.options.operation_max_search_depth,
            );

            var match_indexes = try check_read_operation_done(
                searchable_buf,
                args,
            );

            if (!(match_indexes.start == 0 and match_indexes.end == 0)) {
                match_indexes.start += (bufs.processed.items.len - searchable_buf.len);
                match_indexes.end += (bufs.processed.items.len - searchable_buf.len);
                return match_indexes;
            }
        }
    }

    pub fn getPrompt(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.GetPromptOptions,
    ) ![2][]const u8 {
        self.log.info("get prompt requested", .{});

        try self.writeReturn();

        var bufs = ReadBufs.init(allocator);
        defer bufs.deinit();

        var timer = try std.time.Timer.start();

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilPatternCheckDone,
            .{
                .pattern = self.compiled_prompt_pattern,
            },
            &bufs,
        );

        // pcre2Find returns a slice from the haystack, so we need to persist that in memory
        // through that function call (cant just return pcre2Find)
        const found_prompt = try re.pcre2Find(
            self.compiled_prompt_pattern.?,
            bufs.processed.items,
        );

        const owned_found_prompt = try allocator.alloc(u8, found_prompt.len);
        @memcpy(owned_found_prompt, found_prompt);

        // we want to ensure we are storing the last consumed prompt so that our send_input
        // buf is always "correct" when "retain_input" is true
        try self.last_consumed_prompt.resize(0);
        try self.last_consumed_prompt.appendSlice(
            owned_found_prompt,
        );

        return [2][]const u8{ try bufs.raw.toOwnedSlice(), owned_found_prompt };
    }

    fn _sendInput(
        self: *Session,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        input_handling: operation.InputHandling,
        bufs: *ReadBufs,
    ) !MatchPositions {
        const args = ReadArgs{
            .pattern = self.compiled_prompt_pattern,
            .actual = input,
        };

        try self.write(input, false);

        // SAFETY: will always be set or we'll error
        var match_indexes: MatchPositions = undefined;

        switch (input_handling) {
            operation.InputHandling.exact => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    readUntilExactCheckDone,
                    args,
                    bufs,
                );
            },
            operation.InputHandling.fuzzy => {
                match_indexes = try self.readTimeout(
                    timer,
                    cancel,
                    readUntilFuzzyCheckDone,
                    args,
                    bufs,
                );
            },
            operation.InputHandling.ignore => {
                // ignore, not reading input; to not break our saftey rule above we return here
                // when in "ignore" handling mode
                try self.writeReturn();

                return MatchPositions{ .start = 0, .end = 0 };
            },
        }

        try self.writeReturn();

        return match_indexes;
    }

    pub fn sendInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendInputOptions,
    ) ![2][]const u8 {
        self.log.info("send input requested", .{});

        var timer = try std.time.Timer.start();

        var bufs = ReadBufs.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSliceBoth(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        if (!options.retain_input) {
            // if we dont want to retain inputs, just resize the processed buffer to 0
            try bufs.processed.resize(0);
        }

        var prompt_indexes = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilPatternCheckDone,
            .{
                .pattern = self.compiled_prompt_pattern,
                .actual = options.input,
            },
            &bufs,
        );

        try self.last_consumed_prompt.appendSlice(
            bufs.processed.items[prompt_indexes.start .. prompt_indexes.end + 1],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices(allocator);
    }

    pub fn sendPromptedInput(
        self: *Session,
        allocator: std.mem.Allocator,
        options: operation.SendPromptedInputOptions,
    ) ![2][]const u8 {
        self.log.info("send prompted input requested", .{});

        var timer = try std.time.Timer.start();

        var compiled_pattern: ?*pcre2.pcre2_code_8 = null;

        if (options.prompt_pattern) |pattern| {
            if (pattern.len > 0) {
                compiled_pattern = re.pcre2Compile(pattern);
                if (compiled_pattern == null) {
                    return errors.ScrapliError.RegexError;
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
                        "failed sending abort sequence after error in prompted input, err: {}",
                        .{err},
                    );
                };
            }
        }

        var bufs = ReadBufs.init(allocator);
        defer bufs.deinit();

        if (self.last_consumed_prompt.items.len != 0) {
            // if we had some prompt consumed, stuff it on the raw and processed buffers and then
            // re-zeroize
            try bufs.appendSliceBoth(self.last_consumed_prompt.items);
            try self.last_consumed_prompt.resize(0);
        }

        _ = try self._sendInput(
            &timer,
            options.cancel,
            options.input,
            options.input_handling,
            &bufs,
        );

        var args = ReadArgs{
            .actual = options.prompt,
        };

        if (compiled_pattern) |cp| {
            args.patterns = &[_]?*pcre2.pcre2_code_8{
                self.compiled_prompt_pattern,
                cp,
            };
        } else {
            args.pattern = self.compiled_prompt_pattern;
        }

        _ = try self.readTimeout(
            &timer,
            options.cancel,
            readUntilExactCheckDone,
            args,
            &bufs,
        );

        if (!options.hidden_response) {
            try self.writeAndReturn(options.response, true);
        } else {
            _ = try self._sendInput(
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
            readUntilPatternCheckDone,
            args,
            &bufs,
        );

        try self.last_consumed_prompt.appendSlice(
            bufs.processed.items[prompt_indexes.start..prompt_indexes.end],
        );

        if (!options.retain_trailing_prompt) {
            // using the prompt indexes, replace that range holding the trailing prompt out
            // of the processed buf
            try bufs.processed.replaceRange(
                prompt_indexes.start,
                prompt_indexes.len(),
                "",
            );
        }

        return bufs.toOwnedSlices(allocator);
    }
};

fn readUntilPatternCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_indexes = try re.pcre2FindIndex(args.pattern.?, buf);
    if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
        return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilPatternCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .read_args = ReadArgs{
                .pattern = re.pcre2Compile("foo"),
                .patterns = null,
                .actual = null,
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    defer {
        for (cases) |case| {
            re.pcre2Free(case.read_args.pattern.?);
        }
    }

    for (cases) |case| {
        const actual = try readUntilPatternCheckDone(case.haystack, case.read_args);

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilAnyPatternCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    for (args.patterns.?) |pattern| {
        const match_indexes = try re.pcre2FindIndex(pattern.?, buf);
        if (!(match_indexes[0] == 0 and match_indexes[1] == 0)) {
            return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
        }
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilAnyPatternCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "done first match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "done last match",
            .haystack = "bar",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = try re.pcre2CompileMany(
                    std.testing.allocator,
                    &[_][]const u8{
                        "foo",
                        "bar",
                        "baz",
                    },
                ),
                .actual = null,
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
    };

    defer {
        for (cases) |case| {
            for (case.read_args.patterns.?) |pattern| {
                re.pcre2Free(pattern.?);
            }

            std.testing.allocator.free(case.read_args.patterns.?);
        }
    }

    for (cases) |case| {
        const actual = try readUntilAnyPatternCheckDone(
            case.haystack,
            case.read_args,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilExactCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    if (buf.len == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    const match_start_index = std.mem.indexOf(u8, buf, args.actual.?);
    if (match_start_index != null) {
        return MatchPositions{
            .start = match_start_index.?,
            .end = match_start_index.? + args.actual.?.len - 1,
        };
    }

    return MatchPositions{ .start = 0, .end = 0 };
}

test "readUntilExactCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "foo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 2 },
        },
        .{
            .name = "simple not from start",
            .haystack = "abcfoo",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 3, .end = 5 },
        },
    };

    for (cases) |case| {
        const actual = try readUntilExactCheckDone(
            case.haystack,
            case.read_args,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}

fn readUntilFuzzyCheckDone(buf: []const u8, args: ReadArgs) !MatchPositions {
    const match_indexes = bytes.roughlyContains(buf, args.actual.?);

    if (match_indexes[0] == 0 and match_indexes[1] == 0) {
        return MatchPositions{ .start = 0, .end = 0 };
    }

    return MatchPositions{ .start = match_indexes[0], .end = match_indexes[1] - 1 };
}

test "readUntilFuzzyCheckDone" {
    const cases = [_]struct {
        name: []const u8,
        haystack: []const u8,
        read_args: ReadArgs,
        expected: MatchPositions,
    }{
        .{
            .name = "not done",
            .haystack = "",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 0 },
        },
        .{
            .name = "simple match",
            .haystack = "f X o X o",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 0, .end = 8 },
        },
        .{
            .name = "simple not from start",
            .haystack = "X o f X o X o",
            .read_args = ReadArgs{
                .pattern = null,
                .patterns = null,
                .actual = "foo",
            },
            .expected = MatchPositions{ .start = 4, .end = 12 },
        },
    };

    for (cases) |case| {
        const actual = try readUntilFuzzyCheckDone(
            case.haystack,
            case.read_args,
        );

        try std.testing.expectEqual(case.expected, actual);
    }
}
