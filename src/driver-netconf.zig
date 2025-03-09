const std = @import("std");
const auth = @import("auth.zig");
const logging = @import("logging.zig");
const session = @import("session.zig");
const transport = @import("transport.zig");
const operation = @import("operation-netconf.zig");
const result = @import("result-netconf.zig");
const ascii = @import("ascii.zig");
const xml = @import("xml");
const test_helper = @import("test-helper.zig");

const ProcessThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
};

pub const Version = enum {
    version_1_0,
    version_1_1,
};

pub const Capability = struct {
    allocator: std.mem.Allocator,
    namespace: []const u8,
    name: []const u8,
    revision: []const u8,

    fn deinit(self: *Capability) void {
        self.allocator.free(self.namespace);
        self.allocator.free(self.name);
        self.allocator.free(self.revision);
    }
};

const default_netconf_port = 830;

pub const delimiter_Version_1_0 = "]]>]]>";
pub const delimiter_Version_1_1 = "##";

pub const version_1_0_capability_name = "urn:ietf:params:netconf:base:1.0";
pub const version_1_1_capability_name = "urn:ietf:params:netconf:base:1.1";

const version_1_0_capability =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    \\  <capabilities>
    \\      <capability>urn:ietf:params:netconf:base:1.0</capability>
    \\  </capabilities>
    \\</hello>]]>]]>
;
const version_1_1_capability =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    \\  <capabilities>
    \\      <capability>urn:ietf:params:netconf:base:1.1</capability>
    \\  </capabilities>
    \\</hello>]]>]]>
;

pub const default_rpc_error_tag = "rpc-error>";

const with_defaults_capability_name = "urn:ietf:params:netconf:capability:with-defaults:1.0";

const message_id_attribute_prefix = "message-id=\"";
const subscription_id_attribute_prefix = "subscription-id=\"";

const default_message_poll_interval_ns: u64 = 1_000_000;
const default_initial_operation_max_search_depth: u64 = 256;
const default_post_open_operation_max_search_depth: u64 = 32;

pub const Config = struct {
    logger: ?logging.Logger = null,
    port: ?u16 = null,
    auth: auth.OptionsInputs = .{},
    session: session.OptionsInputs = .{},
    transport: transport.OptionsInputs = .{ .bin = .{} },
    error_tag: []const u8 = default_rpc_error_tag,
    preferred_version: ?Version = null,
    message_poll_interval_ns: u64 = default_message_poll_interval_ns,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    logger: ?logging.Logger,
    port: ?u16,
    auth: *auth.Options,
    session: *session.Options,
    transport: *transport.Options,
    error_tag: []const u8,
    preferred_version: ?Version,
    message_poll_interval_ns: u64,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .logger = config.logger,
            .port = config.port,
            .auth = try auth.Options.init(allocator, config.auth),
            .session = try session.Options.init(allocator, config.session),
            .transport = try transport.Options.init(allocator, config.transport),
            .error_tag = config.error_tag,
            .preferred_version = config.preferred_version,
            .message_poll_interval_ns = config.message_poll_interval_ns,
        };

        o.session.operation_max_search_depth = default_initial_operation_max_search_depth;

        if (&o.error_tag[0] != &default_rpc_error_tag[0]) {
            o.error_tag = try o.allocator.dupe(u8, o.error_tag);
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        if (&self.error_tag[0] != &default_rpc_error_tag[0]) {
            self.allocator.free(self.error_tag);
        }

        self.auth.deinit();
        self.session.deinit();
        self.transport.deinit();

        self.allocator.destroy(self);
    }
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    log: logging.Logger,

    host: []const u8,

    options: *Options,

    session: *session.Session,

    server_capabilities: ?std.ArrayList(Capability),
    negotiated_version: Version,

    process_thread: ?std.Thread,
    process_stop: std.atomic.Value(ProcessThreadState),

    message_id: u64,

    messages: std.HashMap(
        u64,
        []const u8,
        std.hash_map.AutoContext(u64),
        std.hash_map.default_max_load_percentage,
    ),
    messages_lock: std.Thread.Mutex,

    subscriptions: std.HashMap(
        u64,
        []const u8,
        std.hash_map.AutoContext(u64),
        std.hash_map.default_max_load_percentage,
    ),
    subscriptions_lock: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        config: Config,
    ) !*Driver {
        const opts = try Options.init(allocator, config);

        const log = opts.logger orelse logging.Logger{
            .allocator = allocator,
            .f = logging.noopLogf,
        };

        switch (opts.transport.*) {
            .bin => {
                opts.transport.bin.netconf = true;
            },
            .ssh2 => {
                opts.transport.ssh2.netconf = true;
            },
            .test_ => {
                // nothing to do for test transport, but its "allowed" so dont return an error
            },
            else => {
                return error.UnsupportedTransport;
            },
        }

        if (opts.port == null) {
            opts.port = default_netconf_port;
        }

        const sess = try session.Session.init(
            allocator,
            log,
            delimiter_Version_1_0,
            opts.session,
            opts.auth,
            opts.transport,
        );

        const d = try allocator.create(Driver);

        d.* = Driver{
            .allocator = allocator,
            .log = log,

            .host = host,

            .options = opts,

            .session = sess,

            .server_capabilities = std.ArrayList(Capability).init(allocator),
            .negotiated_version = Version.version_1_0,

            .process_thread = null,
            .process_stop = std.atomic.Value(ProcessThreadState).init(ProcessThreadState.uninitialized),

            .message_id = 101,

            .messages = std.HashMap(
                u64,
                []const u8,
                std.hash_map.AutoContext(u64),
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .messages_lock = std.Thread.Mutex{},

            .subscriptions = std.HashMap(
                u64,
                []const u8,
                std.hash_map.AutoContext(u64),
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .subscriptions_lock = std.Thread.Mutex{},
        };

        return d;
    }

    pub fn deinit(self: *Driver) void {
        self.session.deinit();

        if (self.server_capabilities != null) {
            for (self.server_capabilities.?.items) |cap| {
                var mut_cap = cap;
                mut_cap.deinit();
            }

            self.server_capabilities.?.deinit();
        }

        self.messages.deinit();
        self.subscriptions.deinit();

        self.options.deinit();

        self.allocator.destroy(self);
    }

    fn NewResult(
        self: *Driver,
        allocator: std.mem.Allocator,
        operation_kind: operation.Kind,
    ) !*result.Result {
        return result.NewResult(
            allocator,
            self.host,
            self.options.port.?,
            self.negotiated_version,
            self.options.error_tag,
            operation_kind,
        );
    }

    pub fn open(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
    ) !*result.Result {
        var timer = try std.time.Timer.start();

        var res = try self.NewResult(
            allocator,
            operation.Kind.open,
        );
        errdefer res.deinit();

        const rets = try self.session.open(
            allocator,
            self.host,
            self.options.port.?,
            options,
        );
        allocator.free(rets[0]);

        try res.record(rets[1]);

        // SAFETY: undefined now but will always be set before use (below) or we will have
        // errored out.
        var cap_buf: []u8 = undefined;

        switch (self.session.transport.implementation) {
            .bin, .test_ => {
                // bin will have already consumed the caps, anything else we will need
                // to read the caps off the channel! (and by anything else == ssh2)
                // bin will need to clean up the open buf though so we only send a valid
                // xml doc to processServerCapabilities!
                // note that this all applies to the test transport as well (reading from file)
                const cap_start_index = std.mem.indexOf(
                    u8,
                    res.results.items[0],
                    "<hello ",
                );
                if (cap_start_index == null) {
                    return error.CapabilitiesExchange;
                }

                // session will have read up to (and consumed) the prompt (]]>]]> at this point),
                // so we just need find the end of the server hello/capabilities.
                const cap_end_index = std.mem.indexOf(
                    u8,
                    res.results.items[0],
                    "/hello>",
                );
                if (cap_end_index == null) {
                    return error.CapabilitiesExchange;
                }

                cap_buf = try allocator.dupe(
                    u8,
                    res.results.items[0][cap_start_index.? .. cap_end_index.? + "/hello>".len],
                );
            },
            else => {
                cap_buf = try self.receiveServerCapabilities(
                    allocator,
                    options,
                    &timer,
                );
                try res.results.append(try allocator.dupe(u8, cap_buf));
            },
        }

        // netconf uses a super small search depth since we only need to find a 2 or 6 char delim,
        // but that can be problematic for the "open" (for in channel auth) as we can miss password
        // or passphrase prompts, so the "initial" depth is much deeper, then post in channel auth
        // we set it to a shallower search
        self.session.options.operation_max_search_depth = default_post_open_operation_max_search_depth;

        // receive caps for non bin transport can obvoiusly fail, so we'll wait to defer the free
        // till down here otherwise we may try to free something that was not allocated
        defer allocator.free(cap_buf);

        try self.processServerCapabilities(cap_buf);
        try self.determineVersion();
        try self.sendClientCapabilities(allocator, options, &timer);

        self.process_stop.store(
            ProcessThreadState.run,
            std.builtin.AtomicOrder.unordered,
        );

        self.process_thread = std.Thread.spawn(
            .{},
            Driver.processLoop,
            .{self},
        ) catch |err| {
            self.log.critical("failed spawning message processing thread, err: {}", .{err});

            return error.OpenFailed;
        };

        return res;
    }

    pub fn close(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseOptions,
    ) !*result.Result {
        // TODO send CloseSession rpc and then we will care about options for cancel
        _ = options;

        self.process_stop.store(ProcessThreadState.stop, std.builtin.AtomicOrder.unordered);

        if (self.process_thread != null) {
            self.process_thread.?.join();
        }

        self.session.close();

        return self.NewResult(allocator, operation.Kind.close_session);
    }

    fn receiveServerCapabilities(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
        timer: *std.time.Timer,
    ) ![]u8 {
        var cur_read_delay_ns: u64 = self.session.options.read_delay_min_ns;

        var _cap_buf = std.ArrayList([]u8).init(allocator);
        defer {
            for (_cap_buf.items) |cap| {
                allocator.free(cap);
            }

            _cap_buf.deinit();
        }

        var _read_cap_buf = try allocator.alloc(u8, 1_024);
        defer allocator.free(_read_cap_buf);

        var found_cap_start = false;

        while (true) {
            if (options.cancel != null and options.cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (self.session.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) > self.session.options.operation_timeout_ns)
            {
                self.log.critical("op timeout exceeded", .{});

                return error.Timeout;
            }

            const n = self.session.read(_read_cap_buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.session.options.read_delay_min_ns;
            }

            if (!found_cap_start) {
                const cap_start_index = std.mem.indexOf(
                    u8,
                    _read_cap_buf,
                    "<hello ",
                );
                if (cap_start_index != null) {
                    found_cap_start = true;
                } else {
                    continue;
                }
            }

            var end_copy_index: usize = n;

            const cap_end_index = std.mem.indexOf(
                u8,
                _read_cap_buf,
                delimiter_Version_1_0,
            );
            if (cap_end_index != null) {
                end_copy_index = cap_end_index.?;
            }

            try _cap_buf.append(try allocator.dupe(u8, _read_cap_buf[0..end_copy_index]));

            if (cap_end_index == null) {
                continue;
            }

            var caps_len: usize = 0;

            for (_cap_buf.items[0..]) |cap| {
                caps_len += cap.len;
            }

            const cap_buf = try allocator.alloc(u8, caps_len);

            var cur_idx: usize = 0;
            for (_cap_buf.items[0..]) |cap| {
                @memcpy(cap_buf[cur_idx .. cur_idx + cap.len], cap);
                cur_idx += cap.len;
            }

            return cap_buf;
        }
    }

    fn processServerCapabilities(
        self: *Driver,
        cap_buf: []const u8,
    ) !void {
        var input_stream = std.io.fixedBufferStream(cap_buf);
        const input_stream_reader = input_stream.reader();

        var xml_doc = xml.streamingDocument(self.allocator, input_stream_reader);
        defer xml_doc.deinit();

        var xml_reader = xml_doc.reader(self.allocator, .{});
        defer xml_reader.deinit();

        while (true) {
            const node = try xml_reader.read();

            switch (node) {
                .eof => break,
                .element_start => {
                    const element_name = xml_reader.elementNameNs();
                    if (!std.mem.eql(u8, element_name.local, "capability")) {
                        continue;
                    }

                    var found_capability = Capability{
                        .allocator = self.allocator,
                        .name = "",
                        .namespace = try self.allocator.dupe(u8, element_name.ns),
                        .revision = "",
                    };

                    while (true) {
                        const inner_node = try xml_reader.read();
                        switch (inner_node) {
                            .text => {
                                const text_content = try xml_reader.text();

                                if (std.mem.startsWith(u8, text_content, "http") or
                                    std.mem.startsWith(u8, text_content, "urn"))
                                {
                                    found_capability.name = try self.allocator.dupe(
                                        u8,
                                        text_content,
                                    );
                                } else if (std.mem.startsWith(u8, text_content, "revision")) {
                                    found_capability.revision = try self.allocator.dupe(
                                        u8,
                                        text_content[9..],
                                    );
                                }
                            },
                            .element_end => {
                                break;
                            },
                            else => {},
                        }
                    }

                    try self.server_capabilities.?.append(found_capability);
                },
                else => {},
            }
        }
    }

    pub fn hasCapability(
        self: *Driver,
        namespace: ?[]const u8,
        name: []const u8,
        revision: ?[]const u8,
    ) !bool {
        if (self.server_capabilities == null) {
            return error.CapabilitiesNotProcessed;
        }

        for (self.server_capabilities.?.items) |cap| {
            if (namespace != null and !std.mem.eql(u8, namespace.?, cap.namespace)) {
                continue;
            }

            if (!std.mem.eql(u8, name, cap.name)) {
                continue;
            }

            if (revision != null and !std.mem.eql(u8, revision.?, cap.revision)) {
                continue;
            }

            return true;
        }

        return false;
    }

    fn determineVersion(
        self: *Driver,
    ) !void {
        const hasVersion_1_0 = try self.hasCapability(null, version_1_0_capability_name, null);
        const hasVersion_1_1 = try self.hasCapability(null, version_1_1_capability_name, null);

        if (hasVersion_1_1) {
            // we default to preferring 1.1
            self.negotiated_version = Version.version_1_1;
        } else if (hasVersion_1_0) {
            self.negotiated_version = Version.version_1_0;
        } else {
            // we literally did not get a capability for 1.0 or 1.1, something is
            // wrong, bail.
            return error.CapabilitiesExchange;
        }

        if (self.options.preferred_version == null) {
            // user doesnt care, use default
            return;
        }

        switch (self.options.preferred_version.?) {
            Version.version_1_0 => {
                if (hasVersion_1_0) {
                    self.negotiated_version = Version.version_1_0;
                }

                return error.PreferredCapabilityUnavailable;
            },
            Version.version_1_1 => {
                if (hasVersion_1_1) {
                    self.negotiated_version = Version.version_1_1;
                }

                return error.PreferredCapabilityUnavailable;
            },
        }
    }

    fn sendClientCapabilities(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
        timer: *std.time.Timer,
    ) !void {
        var cur_read_delay_ns: u64 = self.session.options.read_delay_min_ns;

        var caps: []const u8 = version_1_0_capability;

        if (self.negotiated_version == Version.version_1_1) {
            caps = version_1_1_capability;
        }

        try self.session.writeAndReturn(caps, false);

        const _read_cap_buf = try allocator.alloc(u8, 64);
        defer allocator.free(_read_cap_buf);

        // drain the channel of our sent caps
        while (true) {
            if (options.cancel != null and options.cancel.?.*) {
                self.log.critical("operation cancelled", .{});

                return error.Cancelled;
            }

            const elapsed_time = timer.read();

            if (self.session.options.operation_timeout_ns != 0 and
                (elapsed_time + cur_read_delay_ns) > self.session.options.operation_timeout_ns)
            {
                self.log.critical("op timeout exceeded", .{});

                return error.Timeout;
            }

            const n = self.session.read(_read_cap_buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.session.options.read_delay_min_ns;
            }

            const delim_index = std.mem.indexOf(
                u8,
                _read_cap_buf,
                delimiter_Version_1_0,
            );

            if (delim_index != null) {
                if (delim_index.? + delimiter_Version_1_0.len < _read_cap_buf.len) {
                    // almost certainly in an integration test and we overshot the delim
                    // which would cause a test to fail later on as we'll never be able to find
                    // the start of the next message, just put back whatever we over read
                    try self.session.read_queue.unget(
                        _read_cap_buf[delim_index.? + delimiter_Version_1_0.len ..],
                    );
                }

                return;
            }
        }
    }

    fn getReadDelay(self: *Driver, cur_read_delay_ns: u64) u64 {
        var new_read_delay_ns: u64 = cur_read_delay_ns;

        new_read_delay_ns *= self.session.options.read_delay_backoff_factor;
        if (new_read_delay_ns > self.session.options.read_delay_max_ns) {
            new_read_delay_ns = self.session.options.read_delay_max_ns;
        }

        return new_read_delay_ns;
    }

    fn processLoop(
        self: *Driver,
    ) !void {
        // TODO what happens when this fails (same for session... somehow that error needs to
        // be propogated up) -- can a field be an error? if yeah we can just set that ?error and
        // then set it and we just always check that before doing anything in the netconf driver
        // and the session, once that change is in place this and the readLoop return value would
        // change to `void` instead and we just have to catch everything and set the error'd field
        self.log.info("message processing thread started", .{});

        const buf = try self.allocator.alloc(u8, self.session.options.read_size);
        defer self.allocator.free(buf);

        var message_buf = std.ArrayList(u8).init(self.allocator);
        defer message_buf.deinit();

        var cur_read_delay_ns: u64 = self.session.options.read_delay_min_ns;

        // SAFETY: will always be set in switch
        var message_complete_delim: []const u8 = undefined;
        switch (self.negotiated_version) {
            Version.version_1_0 => {
                message_complete_delim = delimiter_Version_1_0;
            },
            Version.version_1_1 => {
                message_complete_delim = delimiter_Version_1_1;
            },
        }

        while (self.process_stop.load(std.builtin.AtomicOrder.acquire) != ProcessThreadState.stop) {
            defer std.time.sleep(cur_read_delay_ns);

            var n = self.session.read(buf);

            if (n == 0) {
                cur_read_delay_ns = self.getReadDelay(cur_read_delay_ns);

                continue;
            } else {
                cur_read_delay_ns = self.session.options.read_delay_min_ns;
            }

            try message_buf.appendSlice(buf[0..n]);

            if (n < 10 and message_buf.items.len > 10) {
                // probably we are using the file/test transport, in which case we need to look back
                // further than our reads (which are always 1), either way this was a small read and
                // we want to ensure that when we look back for the prompt we are looking back far
                // enough to ensure we find it
                n = 10;
            }

            // here we will look through the last batch of the buffer backwards ignoring
            // whitespace (ascii.LF (line feed), ascii.CR (carriage return)) and checking if
            // the last chars of the buf are either nc1.0 or nc1.1 delimiter. we'll count each
            // non whitespace char we see, if/when we have seen as many chars as the delimiter
            // would be without seeing the delimiter itself we know this is not the end of a
            // message and we can break
            var seen_chars: usize = 0;
            var matched_chars: usize = 0;

            for (0..n) |forward_idx| {
                if (seen_chars > message_complete_delim.len) {
                    break;
                }

                const reverse_idx = message_buf.items.len - forward_idx - 1;

                if (message_buf.items[reverse_idx] == ascii.control_chars.lf or
                    message_buf.items[reverse_idx] == ascii.control_chars.cr)
                {
                    continue;
                }

                seen_chars += 1;

                if (message_buf.items[reverse_idx] != message_complete_delim[message_complete_delim.len - matched_chars - 1]) {
                    continue;
                }

                matched_chars += 1;

                if (matched_chars == message_complete_delim.len) {
                    try self.processFoundMessage(try message_buf.toOwnedSlice());
                    break;
                }
            }
        }

        self.log.info("message processing thread stopped", .{});
    }

    fn processFoundMessage(
        self: *Driver,
        buf: []const u8,
    ) !void {
        if (std.mem.indexOf(u8, buf, "</rpc>") != null) {
            // found echo from an input, ignore
            self.allocator.free(buf);
            return;
        }

        const index_of_message_id = std.mem.indexOf(u8, buf, message_id_attribute_prefix);
        const index_of_subscription_id = std.mem.indexOf(u8, buf, subscription_id_attribute_prefix);

        if (index_of_message_id == null and
            index_of_subscription_id == null)
        {
            // TODO not message/subscription, ignore (this probably should not happen ever?)
            // printing for now to see if this ever happens
            std.debug.print("GOT NOT A MESSAGE/SUB? {s}\n", .{buf[0..100]});
            self.allocator.free(buf);
            return;
        }

        var _start_index: usize = 0;
        if (index_of_message_id != null) {
            _start_index = index_of_message_id.? + message_id_attribute_prefix.len;
        } else if (index_of_subscription_id != null) {
            _start_index = index_of_subscription_id.? + subscription_id_attribute_prefix.len;
        }

        // 32 chars *should* absolutely be enough to capture any messages/sub id?
        var _idx: usize = 0;
        var _id_buf: [32]u8 = undefined;

        for (_start_index.._start_index + 32) |idx| {
            if (!std.ascii.isDigit(buf[idx])) {
                break;
            }

            _id_buf[_idx] = buf[idx];
            _idx += 1;
        }

        const _id = try std.fmt.parseInt(u64, _id_buf[0.._idx], 10);

        if (index_of_message_id != null) {
            self.messages_lock.lock();
            defer self.messages_lock.unlock();

            try self.messages.put(_id, buf);
        } else if (index_of_subscription_id != null) {
            self.subscriptions_lock.lock();
            defer self.subscriptions_lock.unlock();

            try self.subscriptions.put(_id, buf);
        }
    }

    fn processCancelAndTimeout(
        self: *Driver,
        timer: *std.time.Timer,
        cancel: ?*bool,
    ) !void {
        if (cancel != null and cancel.?.*) {
            self.log.critical("operation cancelled", .{});

            return error.Cancelled;
        }

        const elapsed_time = timer.read();

        // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
        // 2) to let the ffi layer via (go) context control it for example
        if (self.session.options.operation_timeout_ns != 0 and
            (elapsed_time > self.session.options.operation_timeout_ns))
        {
            self.log.critical("op timeout exceeded", .{});

            return error.Timeout;
        }
    }

    fn addFilterElem(
        writer: *xml.GenericWriter(error{OutOfMemory}),
        filter: []const u8,
        filter_type: operation.FilterType,
        filter_namespace_prefix: ?[]const u8,
        filter_namespace: ?[]const u8,
    ) !void {
        try writer.elementStart("filter");
        try writer.attribute("type", filter_type.toString());

        if (filter_namespace != null and filter_namespace.?.len > 0) {
            try writer.bindNs(
                filter_namespace_prefix orelse "",
                filter_namespace.?,
            );
        }

        // we need to load the user's provided filter as an object so we can stuff it into
        // our rpc, mercifully zig-xml is dope and has this where we can just embed what they
        // give us directly. they do have to provide valid xml, but... ya know, the rest is not
        // our problem!
        try writer.embed(filter);

        // finally close out the filter tag
        try writer.elementEnd();
    }

    fn addTargetElem(
        writer: *xml.GenericWriter(error{OutOfMemory}),
        target: []const u8,
    ) !void {
        try writer.elementStart("target");
        try writer.elementStart(target);
        try writer.elementEnd();
        try writer.elementEnd();
    }

    fn addSourceElem(
        writer: *xml.GenericWriter(error{OutOfMemory}),
        source: []const u8,
    ) !void {
        try writer.elementStart("source");
        try writer.elementStart(source);
        try writer.elementEnd();
        try writer.elementEnd();
    }

    fn addDefaultsElem(
        writer: *xml.GenericWriter(error{OutOfMemory}),
        default_type: operation.DefaultsType,
    ) !void {
        try writer.elementStart("with-defaults");
        try writer.bindNs(
            "",
            with_defaults_capability_name,
        );
        try writer.text(default_type.toString());

        // finally close out the with-defaults tag
        try writer.elementEnd();
    }

    fn finalizeElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        elem_conent: []const u8,
    ) ![]const u8 {
        if (self.negotiated_version == Version.version_1_0) {
            return std.fmt.allocPrint(
                allocator,
                "{s}\n{s}",
                .{ elem_conent, delimiter_Version_1_0 },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "#{d}\n{s}\n{s}",
                .{ elem_conent.len, elem_conent, delimiter_Version_1_1 },
            );
        }
    }

    fn buildGetConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("get-config");
        try writer.elementStart("source");
        try writer.elementStart(options.source.toString());
        try writer.elementEnd();
        try writer.elementEnd();

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        if (options.defaults_type != null) {
            try Driver.addDefaultsElem(
                &writer,
                options.defaults_type.?,
            );
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn getConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .get_config = options,
            },
        );
    }

    fn buildEditConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("edit-config");

        try Driver.addTargetElem(&writer, options.target.toString());
        try writer.elementStart("config");
        try writer.embed(options.config);

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn editConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .edit_config = options,
            },
        );
    }

    fn buildCopyConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CopyConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("copy-config");

        try Driver.addSourceElem(&writer, options.source.toString());
        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn copyConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CopyConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .CopyConfig = options,
            },
        );
    }

    fn buildDeleteConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("delete-config");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn deleteConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .CopyConfig = options,
            },
        );
    }

    fn buildLockElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.LockUnlockOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("lock");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn lock(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.LockUnlockOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .lock = options,
            },
        );
    }

    fn buildUnlockElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.LockUnlockOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("unlock");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn unlock(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.LockUnlockOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .unlock = options,
            },
        );
    }

    fn buildGetElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("get");

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        try writer.elementEnd();

        if (options.defaults_type != null) {
            try Driver.addDefaultsElem(
                &writer,
                options.defaults_type.?,
            );
        }

        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn get(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .get = options,
            },
        );
    }

    fn buildCloseSessionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseSessionOptions,
    ) ![]const u8 {
        _ = options;

        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("close-session");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn closeSession(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseSessionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .CloseSession = options,
            },
        );
    }

    fn buildKillSessionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.KillSessionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("kill-session");

        try writer.elementStart("session-id");

        // see also getMessageId, same situation
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.session_id}));
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn killSession(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseSessionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .close_session = options,
            },
        );
    }

    fn buildCommitElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CommitOptions,
    ) ![]const u8 {
        _ = options;

        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("commit");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn commit(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CommitOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .commit = options,
            },
        );
    }

    fn buildDiscardElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DiscardOptions,
    ) ![]const u8 {
        _ = options;

        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("discard-changes");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn discard(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DiscardOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .discard = options,
            },
        );
    }

    fn buildCancelCommitElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CancelCommitOptions,
    ) ![]const u8 {
        _ = options;

        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("cancel-commit");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn cancelCommit(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CancelCommitOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .cancel_commit = options,
            },
        );
    }

    fn buildValidateElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ValidateOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("validate");

        try Driver.addSourceElem(&writer, options.source.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn validate(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ValidateOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .validate = options,
            },
        );
    }

    fn buildCreateSubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CreateSubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("create-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:notification:1.0");

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        if (options.start_time != null) {
            // TODO
        }

        if (options.stop_time != null) {
            // TODO
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn createSubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CreateSubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .CreateSubscription = options,
            },
        );
    }

    fn buildEstablishSubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EstablishSubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("establish-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications");
        try writer.bindNs("yp", "urn:ietf:params:xml:ns:yang:ietf-yang-push");

        // TODO stream and other options/settings

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        if (options.stop_time != null) {
            // TODO
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn establishSubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EstablishSubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .EstablishSubscription = options,
            },
        );
    }

    fn buildModifySubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ModifySubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("modify-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications");
        try writer.bindNs("yp", "urn:ietf:params:xml:ns:yang:ietf-yang-push");

        // see also getMessageId, same situation
        try writer.elementStart("id");
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.id}));
        try writer.elementEnd();

        // TODO stream and other options/settings

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        if (options.stop_time != null) {
            // TODO
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn modifySubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ModifySubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .ModifySubscription = options,
            },
        );
    }

    fn buildDeleteSubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteSubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("delete-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications");
        try writer.bindNs("yp", "urn:ietf:params:xml:ns:yang:ietf-yang-push");

        // see also getMessageId, same situation
        try writer.elementStart("id");
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.id}));
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn deleteSubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteSubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .DeleteSubscription = options,
            },
        );
    }

    fn buildResyncSubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ResyncSubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("resync-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications");
        try writer.bindNs("yp", "urn:ietf:params:xml:ns:yang:ietf-yang-push");

        // see also getMessageId, same situation
        try writer.elementStart("id");
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.id}));
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn resyncSubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ResyncSubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .ResyncSubscriptionOptions = options,
            },
        );
    }

    fn buildKillSubscriptionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.KillSubscriptionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("kill-subscription");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications");
        try writer.bindNs("yp", "urn:ietf:params:xml:ns:yang:ietf-yang-push");

        // see also getMessageId, same situation
        try writer.elementStart("id");
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.id}));
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn killSubscription(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.KillSubscriptionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .KillSubscriptionOptions = options,
            },
        );
    }

    fn buildGetSchemaElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetSchemaOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("get-schema");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring");

        try writer.elementStart("identifier");
        try writer.text(options.identifier);
        try writer.elementEnd();

        if (options.version != null and options.version.?.len > 0) {
            try writer.elementStart("version");
            try writer.text(options.version.?);
            try writer.elementEnd();
        }

        try writer.elementStart("format");
        try writer.text(options.format.toString());
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn getSchema(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetSchemaOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .GetSchemaOptions = options,
            },
        );
    }

    fn buildGetDataElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetDataOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("get-data");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-netconf-nmda");
        try writer.bindNs("ds", "urn:ietf:params:xml:ns:yang:ietf-datastores");
        try writer.bindNs("or", "urn:ietf:params:xml:ns:yang:ietf-origin");

        try writer.elementStart("datastore");
        // like the message id and such, but for datastore, longest (currently) is 12, so 20
        // just for consistency and overhead
        var datastore_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&datastore_buf, "ds:{s}", .{options.datastore.toString()}));
        try writer.elementEnd();

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElem(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        try writer.elementStart("config-filter");
        if (options.config_filter) {
            try writer.text("true");
        } else {
            try writer.text("false");
        }
        try writer.elementEnd();

        if (options.origin_filters != null and options.origin_filters.?.len > 0) {
            try writer.embed(options.origin_filters.?);
        }

        if (options.max_depth != null) {
            try writer.elementStart("max-depth");
            var session_id_buf: [20]u8 = undefined;
            try writer.text(try std.fmt.bufPrint(&session_id_buf, "{}", .{options.max_depth.?}));
            try writer.elementEnd();
        }

        if (options.with_origin != null) {
            try writer.elementStart("with-origin");
            try writer.elementEnd();
        }

        if (options.defaults_type != null) {
            try Driver.addDefaultsElem(
                &writer,
                options.defaults_type.?,
            );
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn getData(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetDataOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .GetData = options,
            },
        );
    }

    fn buildEditDataElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditDataOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("edit-data");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:ietf-netconf-nmda");
        try writer.bindNs("ds", "urn:ietf:params:xml:ns:yang:ietf-datastores");

        try writer.elementStart("datastore");
        // like the message id and such, but for datastore, longest (currently) is 12, so 20
        // just for consistency and overhead
        var datastore_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(&datastore_buf, "ds:{s}", .{options.datastore.toString()}));
        try writer.elementEnd();
        try writer.embed(options.edit_content);

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn editData(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditDataOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .EditData = options,
            },
        );
    }

    fn buildActionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ActionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var sink = std.ArrayList(u8).init(allocator);
        defer sink.deinit();

        var out = xml.streamingOutput(sink.writer());

        var writer = out.writer(allocator, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("rpc");
        try writer.bindNs("", "urn:ietf:params:xml:ns:netconf:base:1.0");
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStart("action");
        try writer.bindNs("", "urn:ietf:params:xml:ns:yang:1");

        try writer.embed(options.action);

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, sink.items);
    }

    pub fn action(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ActionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .Action = options,
            },
        );
    }

    fn dispatchRpc(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.RpcOptions,
    ) !*result.Result {
        var timer = try std.time.Timer.start();

        var res = try self.NewResult(allocator, options.getKind());
        errdefer res.deinit();

        var cancel: ?*bool = null;

        switch (options) {
            .get_config => {
                cancel = options.get_config.cancel;
                res.input = try self.buildGetConfigElem(allocator, options.get_config);
            },
            .edit_config => {
                cancel = options.edit_config.cancel;
                res.input = try self.buildEditConfigElem(allocator, options.edit_config);
            },
            .copy_config => {
                cancel = options.copy_config.cancel;
                res.input = try self.buildCopyConfigElem(allocator, options.copy_config);
            },
            .delete_config => {
                cancel = options.delete_config.cancel;
                res.input = try self.buildDeleteConfigElem(allocator, options.delete_config);
            },
            .lock => {
                cancel = options.lock.cancel;
                res.input = try self.buildLockElem(allocator, options.lock);
            },
            .unlock => {
                cancel = options.unlock.cancel;
                res.input = try self.buildUnlockElem(allocator, options.unlock);
            },
            .get => {
                cancel = options.get.cancel;
                res.input = try self.buildGetElem(allocator, options.get);
            },
            .close_session => {
                cancel = options.close_session.cancel;
                res.input = try self.buildCloseSessionElem(allocator, options.close_session);
            },
            .kill_session => {
                cancel = options.kill_session.cancel;
                res.input = try self.buildKillSessionElem(allocator, options.kill_session);
            },
            .commit => {
                cancel = options.commit.cancel;
                res.input = try self.buildCommitElem(allocator, options.commit);
            },
            .discard => {
                cancel = options.discard.cancel;
                res.input = try self.buildDiscardElem(allocator, options.discard);
            },
            .cancel_commit => {
                cancel = options.cancel_commit.cancel;
                res.input = try self.buildCancelCommitElem(allocator, options.cancel_commit);
            },
            .validate => {
                cancel = options.validate.cancel;
                res.input = try self.buildValidateElem(allocator, options.validate);
            },
            .create_subscription => {
                cancel = options.create_subscription.cancel;
                res.input = try self.buildCreateSubscriptionElem(allocator, options.create_subscription);
            },
            .establish_subscription => {
                cancel = options.establish_subscription.cancel;
                res.input = try self.buildEstablishSubscriptionElem(allocator, options.establish_subscription);
            },
            .modify_subscription => {
                cancel = options.modify_subscription.cancel;
                res.input = try self.buildModifySubscriptionElem(allocator, options.modify_subscription);
            },
            .delete_subscription => {
                cancel = options.delete_subscription.cancel;
                res.input = try self.buildDeleteSubscriptionElem(allocator, options.delete_subscription);
            },
            .resync_subscription => {
                cancel = options.resync_subscription.cancel;
                res.input = try self.buildResyncSubscriptionElem(allocator, options.resync_subscription);
            },
            .kill_subscription => {
                cancel = options.kill_subscription.cancel;
                res.input = try self.buildKillSubscriptionElem(allocator, options.kill_subscription);
            },
            .get_schema => {
                cancel = options.get_schema.cancel;
                res.input = try self.buildGetSchemaElem(allocator, options.get_schema);
            },
            .get_data => {
                cancel = options.get_data.cancel;
                res.input = try self.buildGetDataElem(allocator, options.get_data);
            },
            .edit_data => {
                cancel = options.edit_data.cancel;
                res.input = try self.buildEditDataElem(allocator, options.edit_data);
            },
            .action => {
                cancel = options.action.cancel;
                res.input = try self.buildActionElem(allocator, options.action);
            },
            else => return error.UnsupportedOperation,
        }

        // before sending increment, but remember that in sendRpc we need to check for the
        // *previous* message id!
        self.message_id += 1;

        const ret = try self.sendRpc(&timer, cancel, res.input.?, self.message_id - 1);

        try res.record(ret);

        return res;
    }

    pub fn sendRpc(
        self: *Driver,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        message_id: u64,
    ) ![]const u8 {
        try self.session.writeAndReturn(input, false);

        if (self.negotiated_version == Version.version_1_1) {
            try self.session.writeReturn();
        }

        while (true) {
            try self.processCancelAndTimeout(timer, cancel);

            self.messages_lock.lock();

            if (!self.messages.contains(message_id)) {
                self.messages_lock.unlock();
                std.time.sleep(self.options.message_poll_interval_ns);

                continue;
            }

            self.messages_lock.unlock();

            return self.messages.get(message_id).?;
        }
    }
};

test "buildGetConfigElem" {
    const test_name = "buildGetConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.GetConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#175
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetConfigElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "builEditConfigElem" {
    const test_name = "builEditConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.EditConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = operation.EditConfigOptions{
                .cancel = null,
                .config = "<top xmlns=\"http://example.com/schema/1.2/config\"><interface><name>Ethernet0/0</name></interface></top>",
                .target = operation.DatastoreType.running,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-config><target><running></running></target><config><top xmlns="http://example.com/schema/1.2/config"><interface><name>Ethernet0/0</name></interface></top></config></edit-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = operation.EditConfigOptions{
                .cancel = null,
                .config = "<top xmlns=\"http://example.com/schema/1.2/config\"><interface><name>Ethernet0/0</name></interface></top>",
                .target = operation.DatastoreType.running,
            },
            .expected =
            \\#297
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-config><target><running></running></target><config><top xmlns="http://example.com/schema/1.2/config"><interface><name>Ethernet0/0</name></interface></top></config></edit-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildEditConfigElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "builCopyConfigElem" {
    const test_name = "builCopyConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.CopyConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><copy-config><source><running></running></source><target><startup></startup></target></copy-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#213
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><copy-config><source><running></running></source><target><startup></startup></target></copy-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCopyConfigElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "builDeleteConfigElem" {
    const test_name = "builDeleteConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.DeleteConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><delete-config><target><running></running></target></delete-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#181
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><delete-config><target><running></running></target></delete-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildDeleteConfigElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildLockElem" {
    const test_name = "buildLockElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.LockUnlockOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><lock><target><running></running></target></lock></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#163
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><lock><target><running></running></target></lock></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildLockElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildUnlockElem" {
    const test_name = "buildUnlockElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.LockUnlockOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><unlock><target><running></running></target></unlock></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#167
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><unlock><target><running></running></target></unlock></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildUnlockElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildGetElem" {
    const test_name = "buildGetElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.GetOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get></get></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#125
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get></get></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildCloseSessionElem" {
    const test_name = "buildCloseSessionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.CloseSessionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><close-session></close-session></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#145
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><close-session></close-session></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCloseSessionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildKillSessionElem" {
    const test_name = "buildKillSessionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.KillSessionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = operation.KillSessionOptions{
                .cancel = null,
                .session_id = 1234,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><kill-session><session-id>1234</session-id></kill-session></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = operation.KillSessionOptions{
                .cancel = null,
                .session_id = 1234,
            },
            .expected =
            \\#172
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><kill-session><session-id>1234</session-id></kill-session></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildKillSessionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildCommitElem" {
    const test_name = "buildCommitElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.CommitOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><commit></commit></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#131
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><commit></commit></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCommitElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildDiscardElem" {
    const test_name = "buildDiscardElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.DiscardOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><discard-changes></discard-changes></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#149
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><discard-changes></discard-changes></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildDiscardElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildCancelCommitElem" {
    const test_name = "buildCancelCommitElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.CancelCommitOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><cancel-commit></cancel-commit></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#145
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><cancel-commit></cancel-commit></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCancelCommitElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildValidateElem" {
    const test_name = "buildValidateElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.ValidateOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><validate><source><running></running></source></validate></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#171
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><validate><source><running></running></source></validate></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildValidateElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildCreateSubscriptionElem" {
    const test_name = "buildCreateSubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.CreateSubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><create-subscription xmlns="urn:ietf:params:xml:ns:netconf:notification:1.0"></create-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#213
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><create-subscription xmlns="urn:ietf:params:xml:ns:netconf:notification:1.0"></create-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCreateSubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildEstablishSubscriptionElem" {
    const test_name = "buildEstablishSubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.EstablishSubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .stream = "NETCONF" },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><establish-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"></establish-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .stream = "NETCONF" },
            .expected =
            \\#283
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><establish-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"></establish-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildEstablishSubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildModifySubscriptionElem" {
    const test_name = "buildModifySubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.ModifySubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .id = 0, .stream = "NETCONF'" },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><modify-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></modify-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .id = 0, .stream = "NETCONF'" },
            .expected =
            \\#287
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><modify-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></modify-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildModifySubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildDeleteSubscriptionElem" {
    const test_name = "buildDeleteSubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.DeleteSubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .id = 0 },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><delete-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></delete-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .id = 0 },
            .expected =
            \\#287
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><delete-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></delete-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildDeleteSubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildResyncSubscriptionElem" {
    const test_name = "buildResyncSubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.ResyncSubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .id = 0 },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><resync-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></resync-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .id = 0 },
            .expected =
            \\#287
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><resync-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></resync-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildResyncSubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildKillSubscriptionElem" {
    const test_name = "buildKillSubscriptionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.KillSubscriptionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .id = 0 },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><kill-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></kill-subscription></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .id = 0 },
            .expected =
            \\#283
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><kill-subscription xmlns="urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications" xmlns:yp="urn:ietf:params:xml:ns:yang:ietf-yang-push"><id>0</id></kill-subscription></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildKillSubscriptionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildGetSchemaElem" {
    const test_name = "buildGetSchemaElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.GetSchemaOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{
                .identifier = "foo",
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-schema xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring"><identifier>foo</identifier><format>yang</format></get-schema></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{
                .identifier = "foo",
            },
            .expected =
            \\#248
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-schema xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring"><identifier>foo</identifier><format>yang</format></get-schema></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetSchemaElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "buildGetDataElem" {
    const test_name = "buildGetDataElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.GetDataOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores" xmlns:or="urn:ietf:params:xml:ns:yang:ietf-origin"><datastore>ds:running</datastore><config-filter>true</config-filter></get-data></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{},
            .expected =
            \\#363
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores" xmlns:or="urn:ietf:params:xml:ns:yang:ietf-origin"><datastore>ds:running</datastore><config-filter>true</config-filter></get-data></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetDataElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "builEditDataElem" {
    const test_name = "buildEditDataElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.EditDataOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .edit_content = "foo" },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores"><datastore>ds:running</datastore>foo</edit-data></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .edit_content = "foo" },
            .expected =
            \\#282
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores"><datastore>ds:running</datastore>foo</edit-data></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildEditDataElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}

test "builActionElem" {
    const test_name = "builActionElem";

    const cases = [_]struct {
        name: []const u8,
        version: Version,
        options: operation.ActionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = Version.version_1_0,
            .options = .{ .action = "foo" },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><action xmlns="urn:ietf:params:xml:ns:yang:1">foo</action></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = Version.version_1_1,
            .options = .{ .action = "foo" },
            .expected =
            \\#172
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><action xmlns="urn:ietf:params:xml:ns:yang:1">foo</action></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildActionElem(std.testing.allocator, case.options);
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(test_name, case.name, actual, case.expected);
    }
}
