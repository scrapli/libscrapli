const std = @import("std");

const xml = @import("xml");

const ascii = @import("ascii.zig");
const auth = @import("auth.zig");
const bytes = @import("bytes.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const operation = @import("netconf-operation.zig");
const result = @import("netconf-result.zig");
const session = @import("session.zig");
const test_helper = @import("test-helper.zig");
const transport = @import("transport.zig");

const ProcessThreadState = enum(u8) {
    uninitialized,
    run,
    stop,
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

/// Defines possible callbacks for crafting client capabilities in response to the server's
/// hello message. This exists as a taggged union to more easily support native zig users with
/// nicer zig typing, as well as py/go/whatever other future ffi users w/ a callback with
/// a c compatible signature.
pub const ClientCapabilitiesCallback = union(enum) {
    z: *const fn (
        server_capabilities: std.ArrayList(Capability),
        negotiated_version: operation.Version,
    ) anyerror![]const u8,
    ffi: *const fn (
        cap_buf: *[]const u8,
    ) callconv(.c) *[]const u8,
};

const default_netconf_port = 830;

pub const delimiter_version_1_0 = "]]>]]>";
pub const delimiter_version_1_1 = "##";

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

const base_capability_name = "urn:ietf:params:xml:ns:netconf:base:1.0";
const with_defaults_capability_name = "urn:ietf:params:netconf:capability:with-defaults:1.0";
const validate_capability_name = "urn:ietf:params:xml:ns:netconf:capability:validate:1.0";
const get_schema_capability_name = "urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring";

const message_id_attribute_prefix = "message-id=\"";
pub const subscription_id_attribute_prefix = "<subscription-id>";
pub const notification_prefix = "<notification";

const default_message_poll_interval_ns: u64 = 1_000_000;
const default_initial_operation_max_search_depth: u64 = 256;
const default_post_open_operation_max_search_depth: u64 = 32;

pub const Config = struct {
    logger: ?logging.Logger = null,
    port: ?u16 = null,
    auth: auth.OptionsInputs = .{},
    session: session.OptionsInputs = .{},
    transport: transport.OptionsInputs = .{
        .bin = .{},
    },
    error_tag: ?[]const u8 = null,
    preferred_version: ?operation.Version = null,
    capabilities_callback: ?ClientCapabilitiesCallback = null,
    message_poll_interval_ns: u64 = default_message_poll_interval_ns,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    logger: ?logging.Logger,
    port: ?u16,
    auth: *auth.Options,
    session: *session.Options,
    transport: *transport.Options,
    error_tag: []const u8 = operation.default_rpc_error_tag,
    preferred_version: ?operation.Version = null,
    capabilities_callback: ?ClientCapabilitiesCallback,
    message_poll_interval_ns: u64 = default_message_poll_interval_ns,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Options {
        const o = try allocator.create(Options);
        errdefer allocator.destroy(o);

        o.* = Options{
            .allocator = allocator,
            .logger = config.logger,
            .port = config.port,
            .auth = try auth.Options.init(allocator, config.auth),
            .session = try session.Options.init(allocator, config.session),
            .transport = try transport.Options.init(
                allocator,
                config.transport,
            ),
            .preferred_version = config.preferred_version,
            .capabilities_callback = config.capabilities_callback,
            .message_poll_interval_ns = config.message_poll_interval_ns,
        };

        o.session.operation_max_search_depth = default_initial_operation_max_search_depth;

        if (&o.error_tag[0] != &operation.default_rpc_error_tag[0]) {
            o.error_tag = try o.allocator.dupe(u8, o.error_tag);
        }

        return o;
    }

    pub fn deinit(self: *Options) void {
        if (&self.error_tag[0] != &operation.default_rpc_error_tag[0]) {
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
    io: std.Io,

    log: logging.Logger,

    host: []const u8,

    options: *Options,

    session: *session.Session,

    server_capabilities: ?std.ArrayList(Capability),
    negotiated_version: operation.Version,
    session_id: ?u64,

    process_thread: ?std.Thread,
    process_stop: std.atomic.Value(ProcessThreadState),
    process_thread_exited: bool = false,

    message_id: u64,

    messages: std.HashMap(
        u64,
        [2][]const u8,
        std.hash_map.AutoContext(u64),
        std.hash_map.default_max_load_percentage,
    ),
    messages_lock: std.Thread.Mutex,

    notifications: std.ArrayList([]const u8),
    notifications_lock: std.Thread.Mutex,

    subscriptions: std.HashMap(
        u64,
        std.ArrayList([]const u8),
        std.hash_map.AutoContext(u64),
        std.hash_map.default_max_load_percentage,
    ),
    subscriptions_lock: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        config: Config,
    ) !*Driver {
        const opts = try Options.init(allocator, config);

        const log = opts.logger orelse logging.Logger{
            .allocator = allocator,
        };

        logging.traceWithSrc(log, @src(), "netconf.Driver object initializing", .{});

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
                return errors.wrapCriticalError(
                    errors.ScrapliError.Transport,
                    @src(),
                    log,
                    "netconf.Driver init: unsupported transport for netconf",
                    .{},
                );
            },
        }

        if (opts.port == null) {
            opts.port = default_netconf_port;
        }

        const s = try session.Session.init(
            allocator,
            io,
            log,
            delimiter_version_1_0,
            opts.session,
            opts.auth,
            opts.transport,
        );

        const d = try allocator.create(Driver);

        d.* = Driver{
            .allocator = allocator,
            .io = io,
            .log = log,
            .host = host,
            .options = opts,
            .session = s,
            .server_capabilities = .{},
            .negotiated_version = .version_1_0,
            .session_id = null,
            .process_thread = null,
            .process_stop = std.atomic.Value(ProcessThreadState).init(
                ProcessThreadState.uninitialized,
            ),
            .message_id = 101,
            .messages = std.HashMap(
                u64,
                [2][]const u8,
                std.hash_map.AutoContext(u64),
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .messages_lock = std.Thread.Mutex{},
            .notifications = .{},
            .notifications_lock = std.Thread.Mutex{},
            .subscriptions = std.HashMap(
                u64,
                std.ArrayList([]const u8),
                std.hash_map.AutoContext(u64),
                std.hash_map.default_max_load_percentage,
            ).init(allocator),
            .subscriptions_lock = std.Thread.Mutex{},
        };

        return d;
    }

    pub fn deinit(self: *Driver) void {
        logging.traceWithSrc(self.log, @src(), "netconf.Driver object deinitializing", .{});

        if (self.process_stop.load(std.builtin.AtomicOrder.acquire) == ProcessThreadState.run) {
            // same as session, for ignoring errors on close and just gracefully freeing things
            // zlint-disable suppressed-errors
            const ret = self.close(self.allocator, .{ .force = true }) catch null;
            if (ret) |r| {
                r.deinit();
            }
        }

        self.session.deinit();

        if (self.server_capabilities) |caps| {
            for (caps.items) |cap| {
                var mut_cap = cap;
                mut_cap.deinit();
            }

            self.server_capabilities.?.deinit(self.allocator);
        }

        // free any messages that were never fetched
        var messages_iterator = self.messages.valueIterator();
        while (messages_iterator.next()) |m| {
            self.allocator.free(m[0]);
            self.allocator.free(m[1]);
        }

        self.messages.deinit();

        // annnnd notifications
        for (self.notifications.items) |notif| {
            self.allocator.free(notif);
        }

        self.notifications.deinit(self.allocator);

        // and then subscriptions
        var subscriptions_iterator = self.subscriptions.valueIterator();
        while (subscriptions_iterator.next()) |sl| {
            for (sl.items) |s| {
                self.allocator.free(s);
            }

            sl.deinit(self.allocator);
        }

        self.subscriptions.deinit();

        self.options.deinit();

        self.allocator.destroy(self);
    }

    fn newResult(
        self: *Driver,
        allocator: std.mem.Allocator,
        input: []const u8,
        operation_kind: operation.Kind,
    ) !*result.Result {
        self.log.debug(
            "netconf.Driver creating new Result object for operation {s}",
            .{@tagName(operation_kind)},
        );

        return result.Result.init(
            allocator,
            self.io,
            self.host,
            self.options.port.?,
            self.negotiated_version,
            self.options.error_tag,
            input,
            operation_kind,
        );
    }

    pub fn open(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
    ) !*result.Result {
        self.log.info("netconf.Driver open requested", .{});

        var timer = try std.time.Timer.start();

        var res = try self.newResult(
            allocator,
            "",
            operation.Kind.open,
        );
        errdefer res.deinit();

        try res.record(
            try self.session.open(
                allocator,
                self.host,
                self.options.port.?,
                options.cancel,
            ),
        );

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
                    res.result,
                    "<hello ",
                );
                if (cap_start_index == null) {
                    return errors.wrapCriticalError(
                        errors.ScrapliError.Driver,
                        @src(),
                        self.log,
                        "netconf.Driver open: could not find start of server capabilities",
                        .{},
                    );
                }

                // session will have read up to (and consumed) the prompt (]]>]]> at this point),
                // so we just need find the end of the server hello/capabilities.
                const cap_end_index = std.mem.indexOf(
                    u8,
                    res.result,
                    "/hello>",
                );
                if (cap_end_index == null) {
                    return errors.wrapCriticalError(
                        errors.ScrapliError.Driver,
                        @src(),
                        self.log,
                        "netconf.Driver open: could not find end of server capabilities",
                        .{},
                    );
                }

                cap_buf = try allocator.dupe(
                    u8,
                    res.result[cap_start_index.? .. cap_end_index.? + "/hello>".len],
                );
            },
            else => {
                cap_buf = try self.receiveServerCapabilities(
                    allocator,
                    options,
                    &timer,
                );

                res.result = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n{s}",
                    .{
                        res.result,
                        cap_buf,
                    },
                );
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
        try self.sendClientCapabilities(cap_buf);

        self.process_stop.store(
            ProcessThreadState.run,
            std.builtin.AtomicOrder.unordered,
        );

        self.process_thread = std.Thread.spawn(
            .{},
            Driver.processLoop,
            .{self},
        ) catch |err| {
            return errors.wrapCriticalError(
                err,
                @src(),
                self.log,
                "netconf.Driver open: failed spawning message processing thread",
                .{},
            );
        };

        return res;
    }

    fn closeJoinProcessThread(self: *Driver) !void {
        self.process_stop.store(
            ProcessThreadState.stop,
            std.builtin.AtomicOrder.unordered,
        );

        if (self.process_thread != null) {
            self.process_thread.?.join();
        }

        try self.session.close();
    }

    pub fn close(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseOptions,
    ) !*result.Result {
        self.log.info("netconf.Driver close requested", .{});
        self.log.debug(
            "netconf.Driver close: force '{any}'",
            .{options.force},
        );

        if (options.force) {
            try self.closeJoinProcessThread();

            return self.newResult(allocator, "", operation.Kind.close);
        }

        const res = self.closeSession(
            allocator,
            .{
                .cancel = options.cancel,
            },
        ) catch |err| {
            switch (err) {
                // if we run into an EOF we basically failed successfully :)
                errors.ScrapliError.EOF => {
                    return self.newResult(allocator, "", operation.Kind.close);
                },
                else => {
                    return err;
                },
            }
        };
        errdefer res.deinit();

        try self.closeJoinProcessThread();

        return res;
    }

    fn receiveServerCapabilities(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.OpenOptions,
        timer: *std.time.Timer,
    ) ![]u8 {
        self.log.info("netconf.Driver receiveServerCapabilities requested", .{});

        var cap_buf: std.ArrayList([]u8) = .{};
        defer {
            for (cap_buf.items) |cap| {
                allocator.free(cap);
            }

            cap_buf.deinit(self.allocator);
        }

        var read_cap_buf = try allocator.alloc(u8, 1_024);
        defer allocator.free(read_cap_buf);

        var found_cap_start = false;

        while (true) {
            if (options.cancel != null and options.cancel.?.*) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Cancelled,
                    @src(),
                    self.log,
                    "netconf.Driver receiveServerCapabilities: operation cancelled",
                    .{},
                );
            }

            const elapsed_time = timer.read();

            if (self.session.options.operation_timeout_ns != 0 and
                elapsed_time >= self.session.options.operation_timeout_ns)
            {
                return errors.wrapCriticalError(
                    errors.ScrapliError.TimeoutExceeded,
                    @src(),
                    self.log,
                    "netconf.Driver receiveServerCapabilities: operation timeout exceeded",
                    .{},
                );
            }

            const n = try self.session.read(read_cap_buf);

            if (n == 0) {
                continue;
            }

            if (!found_cap_start) {
                const cap_start_index = std.mem.indexOf(
                    u8,
                    read_cap_buf,
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
                read_cap_buf,
                delimiter_version_1_0,
            );
            if (cap_end_index != null) {
                end_copy_index = cap_end_index.?;
            }

            try cap_buf.append(
                self.allocator,
                try allocator.dupe(u8, read_cap_buf[0..end_copy_index]),
            );

            if (cap_end_index == null) {
                continue;
            }

            var caps_len: usize = 0;

            for (cap_buf.items[0..]) |cap| {
                caps_len += cap.len;
            }

            const final_cap_buf = try allocator.alloc(u8, caps_len);

            var cur_idx: usize = 0;
            for (cap_buf.items[0..]) |cap| {
                @memcpy(final_cap_buf[cur_idx .. cur_idx + cap.len], cap);
                cur_idx += cap.len;
            }

            return final_cap_buf;
        }
    }

    fn processServerCapabilities(
        self: *Driver,
        cap_buf: []const u8,
    ) !void {
        self.log.info("netconf.Driver processServerCapabilities requested", .{});

        var input_stream = std.Io.Reader.fixed(cap_buf);

        var streaming_reader: xml.Reader.Streaming = .init(
            self.allocator,
            &input_stream,
            .{},
        );
        defer streaming_reader.deinit();

        const xml_reader = &streaming_reader.interface;

        while (true) {
            const node = try xml_reader.read();

            switch (node) {
                .eof => break,
                .element_start => {
                    const element_name = xml_reader.elementNameNs();

                    if (std.mem.eql(u8, element_name.local, "session-id")) {
                        const inner_node = try xml_reader.read();
                        switch (inner_node) {
                            .text => {
                                const text_content = try xml_reader.text();
                                self.session_id = try std.fmt.parseInt(
                                    u64,
                                    text_content,
                                    10,
                                );
                            },
                            else => {},
                        }

                        continue;
                    } else if (!std.mem.eql(u8, element_name.local, "capability")) {
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

                                if (std.mem.startsWith(
                                    u8,
                                    text_content,
                                    "http",
                                ) or
                                    std.mem.startsWith(
                                        u8,
                                        text_content,
                                        "urn",
                                    ))
                                {
                                    found_capability.name = try self.allocator.dupe(
                                        u8,
                                        text_content,
                                    );
                                } else if (std.mem.startsWith(
                                    u8,
                                    text_content,
                                    "revision",
                                )) {
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

                    try self.server_capabilities.?.append(self.allocator, found_capability);
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
        self.log.info("netconf.Driver hasCapability requested", .{});
        self.log.debug("netconf.Driver hasCapability: name '{s}'", .{name});

        if (self.server_capabilities == null) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.log,
                "netconf.Driver hasCapability: requested but capabilities unset",
                .{},
            );
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
        self.log.info("netconf.Driver determineVersion requested", .{});

        const has_version_1_0 = try self.hasCapability(
            null,
            version_1_0_capability_name,
            null,
        );
        const has_version_1_1 = try self.hasCapability(
            null,
            version_1_1_capability_name,
            null,
        );

        if (has_version_1_1) {
            // we default to preferring 1.1
            self.negotiated_version = .version_1_1;
        } else if (has_version_1_0) {
            self.negotiated_version = .version_1_0;
        } else {
            // we literally did not get a capability for 1.0 or 1.1, something is
            // wrong, bail.
            return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.log,
                "netconf.Driver determineVersion: capabilities negotiation failed",
                .{},
            );
        }

        if (self.options.preferred_version == null) {
            // user doesnt care, use default
            return;
        }

        switch (self.options.preferred_version.?) {
            .version_1_0 => {
                if (has_version_1_0) {
                    self.negotiated_version = .version_1_0;
                }

                return errors.wrapCriticalError(
                    errors.ScrapliError.Driver,
                    @src(),
                    self.log,
                    "netconf.Driver determineVersion: preferred capability unavailable",
                    .{},
                );
            },
            .version_1_1 => {
                if (has_version_1_1) {
                    self.negotiated_version = .version_1_1;
                }

                return errors.wrapCriticalError(
                    errors.ScrapliError.Driver,
                    @src(),
                    self.log,
                    "netconf.Driver determineVersion: preferred capability unavailable",
                    .{},
                );
            },
        }
    }

    fn sendClientCapabilities(
        self: *Driver,
        cap_buf: []const u8,
    ) !void {
        self.log.info("netconf.Driver sendClientCapabilities requested", .{});

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(
            self.allocator,
            &output.writer,
            .{
                .indent = "  ",
            },
        );
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try writer.elementStart("hello");
        try writer.bindNs("", base_capability_name);

        try writer.elementStart("capabilities");
        try writer.elementStart("capability");

        switch (self.negotiated_version) {
            .version_1_1 => {
                try writer.text(version_1_1_capability_name);
            },
            else => {
                try writer.text(version_1_0_capability_name);
            },
        }

        try writer.elementEnd();

        if (self.options.capabilities_callback) |cb_obj| {
            self.log.debug(
                "netconf.Driver sendClientCapabilities using user capabilities callback",
                .{},
            );

            switch (cb_obj) {
                .z => |cb| {
                    try writer.embed(
                        try cb(
                            self.server_capabilities.?,
                            self.negotiated_version,
                        ),
                    );
                },
                .ffi => |cb| {
                    var cap_buf_v = cap_buf;

                    const ffi_caps = cb(&cap_buf_v);

                    try writer.embed(ffi_caps.*);
                },
            }
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        const caps = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{
                output.written(),
                delimiter_version_1_0,
            },
        );
        defer self.allocator.free(caps);

        try self.session.writeAndReturn(caps, false);
    }

    fn processLoop(
        self: *Driver,
    ) !void {
        self.log.info("netconf.Driver mssage processing thread started", .{});

        const buf = try self.allocator.alloc(u8, self.session.options.read_size);
        defer self.allocator.free(buf);

        var message_buf: std.ArrayList(u8) = .{};
        defer message_buf.deinit(self.allocator);

        // SAFETY: will always be set in switch
        var message_complete_delim: []const u8 = undefined;
        switch (self.negotiated_version) {
            .version_1_0 => {
                message_complete_delim = delimiter_version_1_0;
            },
            .version_1_1 => {
                message_complete_delim = delimiter_version_1_1;
            },
        }

        while (self.process_stop.load(std.builtin.AtomicOrder.acquire) != ProcessThreadState.stop) {
            var n = self.session.read(buf) catch |err| {
                switch (err) {
                    errors.ScrapliError.EOF => {
                        // the session read thread has errored/closed and there is nothing remaining
                        // in the read queue, try one last time to parse out any remaining message(s)
                        const owned_buf = try message_buf.toOwnedSlice(self.allocator);
                        defer self.allocator.free(owned_buf);

                        defer {
                            self.log.debug(
                                "netconf.Driver processLoop: message processing thread " ++
                                    " stopping, session read queue drained and read thread stopped",
                                .{},
                            );

                            // dont set this to true till we processed any remaining messages
                            // otherwise we may bail out of dispatch rpc without seeing a close
                            // session response
                            self.process_thread_exited = true;
                        }

                        switch (self.negotiated_version) {
                            // we'll just squash any errors we get from processing as we maybe
                            // didnt even have valid data anyway
                            .version_1_0 => {
                                // zlint-disable suppressed-errors
                                self.processFoundMessageVersion1_0(owned_buf) catch {};
                            },
                            .version_1_1 => {
                                // zlint-disable suppressed-errors
                                self.processFoundMessageVersion1_1(owned_buf) catch {};
                            },
                        }

                        return;
                    },
                    else => {
                        self.process_thread_exited = true;

                        return err;
                    },
                }
            };

            if (n == 0) {
                continue;
            }

            try message_buf.appendSlice(self.allocator, buf[0..n]);

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
                    const owned_buf = try message_buf.toOwnedSlice(self.allocator);
                    defer self.allocator.free(owned_buf);

                    switch (self.negotiated_version) {
                        .version_1_0 => {
                            try self.processFoundMessageVersion1_0(owned_buf);
                        },
                        .version_1_1 => {
                            try self.processFoundMessageVersion1_1(owned_buf);
                        },
                    }

                    break;
                }
            }
        }

        self.log.info("netconf.Driver message processing thread stopped", .{});
    }

    fn processFoundMessageIds(
        message_view: []const u8,
    ) !struct {
        found: bool = false,
        is_subscription_message: bool = false,
        is_notification_message: bool = false,
        found_id: usize = 0,
    } {
        const index_of_message_id = std.mem.indexOf(
            u8,
            message_view,
            message_id_attribute_prefix,
        );

        const index_of_subscription_id = std.mem.indexOf(
            u8,
            message_view,
            subscription_id_attribute_prefix,
        );

        const index_of_notification = std.mem.indexOf(
            u8,
            message_view,
            notification_prefix,
        );

        if (index_of_message_id == null and
            index_of_subscription_id == null)
        {
            if (index_of_notification != null) {
                return .{
                    .found = true,
                    .is_notification_message = true,
                };
            }

            return .{};
        }

        var _start_index: usize = 0;
        if (index_of_message_id != null) {
            _start_index = index_of_message_id.? + message_id_attribute_prefix.len;
        } else if (index_of_subscription_id != null) {
            _start_index = index_of_subscription_id.? + subscription_id_attribute_prefix.len;
        }

        // max should be uint32, so 10 chars covers that
        var _idx: usize = 0;
        var _id_buf: [10]u8 = undefined;

        for (_start_index.._start_index + 10) |idx| {
            if (!std.ascii.isDigit(message_view[idx])) {
                break;
            }

            _id_buf[_idx] = message_view[idx];
            _idx += 1;
        }

        const _id = try std.fmt.parseInt(u64, _id_buf[0.._idx], 10);

        return .{
            .found = true,
            .is_subscription_message = index_of_subscription_id != null,
            .found_id = _id,
        };
    }

    fn storeMessageOrSubscription(
        self: *Driver,
        raw_buf: []const u8,
        processed_buf: []const u8,
    ) !void {
        const id_info = try Driver.processFoundMessageIds(processed_buf);

        if (!id_info.found) {
            self.log.warn(
                "netconf.Driver storeMessageOrSubscription: found message that had " ++
                    "neither message id or subscription id, ignoring",
                .{},
            );

            self.allocator.free(raw_buf);
            self.allocator.free(processed_buf);

            return;
        }

        if (id_info.is_subscription_message) {
            // we ignore raw buf of subscriptions/notifications
            self.allocator.free(raw_buf);

            self.subscriptions_lock.lock();
            defer self.subscriptions_lock.unlock();

            const ret = try self.subscriptions.getOrPut(id_info.found_id);
            if (!ret.found_existing) {
                ret.value_ptr.* = .{};
            }

            try ret.value_ptr.*.append(self.allocator, processed_buf);
        } else if (id_info.is_notification_message) {
            self.allocator.free(raw_buf);

            self.notifications_lock.lock();
            defer self.notifications_lock.unlock();

            try self.notifications.append(self.allocator, processed_buf);
        } else {
            self.messages_lock.lock();
            defer self.messages_lock.unlock();

            // message id will be unique, clobber away
            try self.messages.put(id_info.found_id, [2][]const u8{ raw_buf, processed_buf });
        }
    }

    // zlinter-disable-next-line function_naming - 1_0 is clearer for reading
    fn processFoundMessageVersion1_0(
        self: *Driver,
        buf: []const u8,
    ) !void {
        var delimiter_count = std.mem.count(u8, buf, delimiter_version_1_0);

        var message_start_idx: usize = 0;

        while (delimiter_count > 0) {
            const delimiter_index = std.mem.indexOf(
                u8,
                buf,
                delimiter_version_1_0,
            );

            const message_view = buf[message_start_idx..delimiter_index.?];

            const owned_raw = try self.allocator.alloc(u8, buf.len);
            @memcpy(owned_raw, buf);

            const owned_parsed = try self.allocator.alloc(u8, message_view.len);
            @memcpy(owned_parsed, message_view);

            try self.storeMessageOrSubscription(owned_raw, owned_parsed);

            delimiter_count -= 1;
            message_start_idx = delimiter_index.? + delimiter_version_1_0.len + 1;
        }
    }

    // zlinter-disable-next-line function_naming - 1_1 is clearer for reading
    fn processFoundMessageVersion1_1(
        self: *Driver,
        buf: []const u8,
    ) !void {
        // rather than deal w/ an arraylist and a bunch of allocations, we'll allocate a single
        // slice since the final parsed result will always be smaller than the heap of chunks that
        // we need to parse. we'll track what we put into it so we can allocate a right sized slice
        // when we're done. so two (or N for multiple messages found in the chunk we are processing)
        // allocations rather than a zillion with array list basically.
        const _parsed = try self.allocator.alloc(u8, buf.len);
        defer self.allocator.free(_parsed);

        var parsed_idx: usize = 0;

        var iter_idx: usize = 0;

        while (iter_idx < buf.len) {
            if (std.ascii.isWhitespace(buf[iter_idx])) {
                iter_idx += 1;

                continue;
            }

            if (buf[iter_idx] != ascii.control_chars.hash_char) {
                // we *must* have found a hash indicating a chunk size, but we didn't something
                // is wrong and/or we have trailing data like "Connection closed" kind of stuff
                return;
            }

            iter_idx += 1;

            if (buf[iter_idx] == ascii.control_chars.hash_char) {
                // now we've found two consequtive hash signs, indicating end of message we can
                // store the raw and processed bits in the messages map
                const owned_raw = try self.allocator.alloc(u8, iter_idx);
                @memcpy(owned_raw, buf[0..iter_idx]);

                const owned_parsed = try self.allocator.alloc(u8, parsed_idx);
                @memcpy(owned_parsed[0..parsed_idx], _parsed[0..parsed_idx]);

                try self.storeMessageOrSubscription(
                    owned_raw,
                    owned_parsed,
                );

                if (iter_idx + 1 >= buf.len) {
                    return;
                }

                return self.processFoundMessageVersion1_1(buf[iter_idx + 1 ..]);
            }

            var chunk_size_end_idx: usize = 0;

            // https://datatracker.ietf.org/doc/html/rfc6242#section-4.2 max chunk size is
            // 4294967295 so for us that is a max of 10 chars that the chunk size could be when we
            //  are parsing it out of raw bytes.
            for (0..10) |maybe_chunk_size_idx_offset| {
                if (!std.ascii.isDigit(buf[iter_idx + maybe_chunk_size_idx_offset])) {
                    chunk_size_end_idx = iter_idx + maybe_chunk_size_idx_offset;
                    break;
                }
            }

            var chunk_size: usize = 0;

            for (iter_idx..chunk_size_end_idx) |chunk_idx| {
                chunk_size = chunk_size * 10 + (buf[chunk_idx] - '0');
            }

            if (chunk_size == 0) {
                return errors.wrapCriticalError(
                    errors.ScrapliError.Driver,
                    @src(),
                    self.log,
                    "netconf.Driver processFoundMessageVersion1_1: failed parsing netconf " ++
                        "message, found chunk size of zero",
                    .{},
                );
            }

            // now that we processed the size, consume any whitespace up to the chunk to read;
            // first move the iter_idx past the chunk size marker, then consume cr/lf before the
            // actual chunk content (whitespace like an actual space is valid for chunks!)
            iter_idx = chunk_size_end_idx;

            if (iter_idx + chunk_size >= buf.len) {
                // just being defensive here, this should *not* happen in normal circumstances but
                // ya know... shit happens
                return errors.wrapCriticalError(
                    errors.ScrapliError.Driver,
                    @src(),
                    self.log,
                    "netconf.Driver processFoundMessageVersion1_1: failed parsing netconf " ++
                        "message, next index to check out of range",
                    .{},
                );
            }

            while (true) {
                if (buf[iter_idx] == ascii.control_chars.cr or
                    buf[iter_idx] == ascii.control_chars.lf)
                {
                    iter_idx += 1;

                    continue;
                }

                break;
            }

            @memcpy(
                _parsed[parsed_idx .. parsed_idx + chunk_size],
                buf[iter_idx .. iter_idx + chunk_size],
            );
            parsed_idx += chunk_size;

            // finally increment iter_idx past this chunk
            iter_idx += chunk_size;
        }
    }

    // caller owns returned memory -- w/ the allocator the netconf object was created with!
    pub fn getSubscriptionMessages(
        self: *Driver,
        id: u64,
    ) ![][]const u8 {
        self.subscriptions_lock.lock();
        defer self.subscriptions_lock.unlock();

        if (!self.subscriptions.contains(id)) {
            return &[_][]const u8{};
        }

        // we know key is present since we already checked
        var ret = self.subscriptions.fetchRemove(id);
        return ret.?.value.toOwnedSlice();
    }

    // caller owns returned memory -- w/ the allocator the netconf object was created with!
    pub fn getNotificationMessages(
        self: *Driver,
    ) ![][]const u8 {
        self.notifications_lock.lock();
        defer self.notifications_lock.unlock();

        return self.notifications.toOwnedSlice();
    }

    fn processCancelAndTimeout(
        self: *Driver,
        timer: *std.time.Timer,
        cancel: ?*bool,
    ) !void {
        if (cancel != null and cancel.?.*) {
            return errors.wrapCriticalError(
                errors.ScrapliError.Cancelled,
                @src(),
                self.log,
                "netconf.Driver processCancelAndTimeout: operation cancelled",
                .{},
            );
        }

        const elapsed_time = timer.read();

        // if timeout is 0 we dont timeout -- we do this to let users 1) disable it but also
        // 2) to let the ffi layer via (go) context control it for example
        if (self.session.options.operation_timeout_ns != 0 and
            (elapsed_time > self.session.options.operation_timeout_ns))
        {
            return errors.wrapCriticalError(
                errors.ScrapliError.TimeoutExceeded,
                @src(),
                self.log,
                "netconf.Driver processCancelAndTimeout: operation timeout exceeded",
                .{},
            );
        }
    }

    fn rpcStart(
        writer: *xml.Writer,
    ) !void {
        try writer.elementStart("rpc");
        try writer.bindNs("", base_capability_name);
    }

    fn addFilterElem(
        writer: *xml.Writer,
        filter: []const u8,
        filter_type: operation.FilterType,
        filter_namespace_prefix: ?[]const u8,
        filter_namespace: ?[]const u8,
    ) !void {
        try writer.elementStartNs(base_capability_name, "filter");
        try writer.attribute("type", filter_type.toString());

        if (filter_namespace != null and filter_namespace.?.len > 0) {
            try writer.bindNs(
                filter_namespace_prefix orelse "",
                filter_namespace.?,
            );
        }

        if (filter_type == operation.FilterType.xpath) {
            try writer.attribute("select", filter);
        } else {
            // we need to load the user's provided filter as an object so we can stuff it into
            // our rpc, mercifully zig-xml is dope and has this where we can just embed what they
            // give us directly. they do have to provide valid xml, but... ya know, the rest is not
            // our problem!
            try writer.embed(filter);
        }

        // finally close out the filter tag
        try writer.elementEnd();
    }

    // for at least get-data rpc that expects subtree-filter / xpath-filter tags rather than the
    // "traditional" filter tag
    fn addFilterElemExplicitTag(
        writer: *xml.Writer,
        filter: []const u8,
        filter_type: operation.FilterType,
        filter_namespace_prefix: ?[]const u8,
        filter_namespace: ?[]const u8,
    ) !void {
        if (filter_type == operation.FilterType.subtree) {
            try writer.elementStartNs(base_capability_name, "subtree-filter");

            if (filter_namespace != null and filter_namespace.?.len > 0) {
                try writer.bindNs(
                    filter_namespace_prefix orelse "",
                    filter_namespace.?,
                );
            }
        } else {
            try writer.elementStartNs(base_capability_name, "xpath-filter");

            if (filter_namespace != null and filter_namespace.?.len > 0) {
                try writer.bindNs(
                    filter_namespace_prefix orelse "",
                    filter_namespace.?,
                );
            }
        }

        // with either "outer" tag opened, we can write the filter
        try writer.embed(filter);

        // finally close out the filter tag
        try writer.elementEnd();
    }
    fn addTargetElem(
        writer: *xml.Writer,
        target: []const u8,
    ) !void {
        try writer.elementStartNs(base_capability_name, "target");
        try writer.elementStartNs(base_capability_name, target);
        try writer.elementEnd();
        try writer.elementEnd();
    }

    fn addSourceElem(
        writer: *xml.Writer,
        source: []const u8,
    ) !void {
        try writer.elementStartNs(base_capability_name, "source");
        try writer.elementStartNs(base_capability_name, source);
        try writer.elementEnd();
        try writer.elementEnd();
    }

    fn addDefaultsElem(
        writer: *xml.Writer,
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
        if (self.negotiated_version == .version_1_0) {
            return std.fmt.allocPrint(
                allocator,
                "{s}\n{s}",
                .{ elem_conent, delimiter_version_1_0 },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "#{d}\n{s}\n{s}",
                .{ elem_conent.len, elem_conent, delimiter_version_1_1 },
            );
        }
    }

    fn buildRawRpcElement(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.RawRpcOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(
            self.allocator,
            &output.writer,
            .{ .indent = "" },
        );
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);

        if (options.base_namespace_prefix) |prefix| {
            try writer.bindNs(
                prefix,
                base_capability_name,
            );
            try writer.elementStartNs(base_capability_name, "rpc");
        } else {
            try Driver.rpcStart(&writer);
        }

        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        if (options.extra_namespaces) |extra_namespaces| {
            for (extra_namespaces) |namespace| {
                try writer.bindNs(namespace[0], namespace[1]);
            }
        } else if (options._extra_namespaces_ffi) |extra_namespaces_str| {
            var extra_namespaces_iterator = std.mem.splitSequence(
                u8,
                extra_namespaces_str,
                bytes.libscrapli_delimiter,
            );

            var idx: usize = 0;

            while (extra_namespaces_iterator.next()) |extra_namespace| {
                defer idx += 1;

                var namespace_parts_iterator = std.mem.splitSequence(
                    u8,
                    extra_namespace,
                    "::",
                );

                try writer.bindNs(
                    namespace_parts_iterator.first(),
                    namespace_parts_iterator.rest(),
                );
            }
        }

        try writer.embed(options.payload);
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn rawRpc(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.RawRpcOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .raw_rpc = options,
            },
        );
    }

    fn buildGetConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        try writer.elementStartNs(base_capability_name, "get-config");
        try Driver.addSourceElem(&writer, options.source.toString());

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

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        try writer.elementStartNs(base_capability_name, "edit-config");

        try Driver.addTargetElem(&writer, options.target.toString());

        if (options.default_operation) |default_operation| {
            try writer.elementStartNs(base_capability_name, "default-operation");
            try writer.text(default_operation.toString());
            try writer.elementEnd();
        }

        if (options.test_option) |test_option| {
            try writer.elementStartNs(base_capability_name, "test-option");
            try writer.text(test_option.toString());
            try writer.elementEnd();
        }

        if (options.error_option) |error_option| {
            try writer.elementStartNs(base_capability_name, "error-option");
            try writer.text(error_option.toString());
            try writer.elementEnd();
        }

        try writer.elementStartNs(base_capability_name, "config");
        try writer.embed(options.config);
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "copy-config");

        try Driver.addSourceElem(&writer, options.source.toString());
        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn copyConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CopyConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .copy_config = options,
            },
        );
    }

    fn buildDeleteConfigElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteConfigOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "delete-config");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn deleteConfig(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.DeleteConfigOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .delete_config = options,
            },
        );
    }

    fn buildLockElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.LockUnlockOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "lock");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "unlock");

        try Driver.addTargetElem(&writer, options.target.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "get");

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

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "close-session");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn closeSession(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.CloseSessionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .close_session = options,
            },
        ) catch |err| {
            switch (err) {
                error.EOF, errors.ScrapliError.Transport, errors.ScrapliError.Driver => {
                    // we may read an EOF and miss the reply when using ssh2 transport (due i think
                    // in part or whole to being in non blocking mode). so... we lie. if we hit eof
                    // *or* a parsing error (which can happen when we only read part of the close
                    // reply from the server), we did indeed close the session... good enough...
                    // format up and send an appropriate response, allocate it and everything so
                    // normal deinit flow is as expected
                    const res = try self.newResult(
                        allocator,
                        "",
                        operation.Kind.close,
                    );

                    try res.record(
                        [2][]const u8{
                            try std.fmt.allocPrint(
                                allocator,
                                \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="{d}"><ok/></rpc-reply>
                            ,
                                .{self.message_id - 1},
                            ),
                            try std.fmt.allocPrint(
                                allocator,
                                \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="{d}"><ok/></rpc-reply>
                            ,
                                .{self.message_id - 1},
                            ),
                        },
                    );

                    return res;
                },
                else => {
                    return err;
                },
            }
        };
    }

    fn buildKillSessionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.KillSessionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "kill-session");

        try writer.elementStartNs(base_capability_name, "session-id");

        // see also getMessageId, same situation
        var session_id_buf: [20]u8 = undefined;
        try writer.text(try std.fmt.bufPrint(
            &session_id_buf,
            "{}",
            .{options.session_id},
        ));
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn killSession(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.KillSessionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .kill_session = options,
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "commit");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );
        try writer.elementStartNs(base_capability_name, "discard-changes");
        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        try writer.elementStartNs(base_capability_name, "cancel-commit");

        if (options.persist_id) |persist_id| {
            try writer.elementStartNs(base_capability_name, "persist-id");
            try writer.text(persist_id);
            try writer.elementEnd();
        }

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        try writer.elementStart("validate");
        try writer.bindNs("", validate_capability_name);

        try Driver.addSourceElem(&writer, options.source.toString());

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
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

    fn buildGetSchemaElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetSchemaOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
        try writer.attribute(
            "message-id",
            try std.fmt.bufPrint(
                &message_id_buf,
                "{}",
                .{self.message_id},
            ),
        );

        try writer.elementStart("get-schema");
        try writer.bindNs("", get_schema_capability_name);

        try writer.elementStartNs(get_schema_capability_name, "identifier");
        try writer.text(options.identifier);
        try writer.elementEnd();

        if (options.version != null and options.version.?.len > 0) {
            try writer.elementStartNs(get_schema_capability_name, "version");
            try writer.text(options.version.?);
            try writer.elementEnd();
        }

        try writer.elementStartNs(get_schema_capability_name, "format");
        try writer.text(options.format.toString());
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn getSchema(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetSchemaOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .get_schema = options,
            },
        );
    }

    fn buildGetDataElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetDataOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
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
        try writer.text(try std.fmt.bufPrint(
            &datastore_buf,
            "ds:{s}",
            .{options.datastore.toString()},
        ));
        try writer.elementEnd();

        if (options.filter != null and options.filter.?.len > 0) {
            try Driver.addFilterElemExplicitTag(
                &writer,
                options.filter.?,
                options.filter_type,
                options.filter_namespace_prefix,
                options.filter_namespace,
            );
        }

        if (options.config_filter) |cf| {
            try writer.elementStart("config-filter");
            if (cf) {
                try writer.text("true");
            } else {
                try writer.text("false");
            }
            try writer.elementEnd();
        }

        if (options.origin_filters != null and options.origin_filters.?.len > 0) {
            try writer.embed(options.origin_filters.?);
        }

        if (options.max_depth != null) {
            try writer.elementStart("max-depth");
            var session_id_buf: [20]u8 = undefined;
            try writer.text(try std.fmt.bufPrint(
                &session_id_buf,
                "{}",
                .{options.max_depth.?},
            ));
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

        return self.finalizeElem(allocator, output.written());
    }

    pub fn getData(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.GetDataOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .get_data = options,
            },
        );
    }

    fn buildEditDataElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditDataOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
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
        try writer.text(try std.fmt.bufPrint(
            &datastore_buf,
            "ds:{s}",
            .{options.datastore.toString()},
        ));
        try writer.elementEnd();

        if (options.default_operation) |default_operation| {
            try writer.elementStartNs(base_capability_name, "default-operation");
            try writer.text(default_operation.toString());
            try writer.elementEnd();
        }

        try writer.elementStart("config");
        try writer.embed(options.edit_content);
        try writer.elementEnd();

        try writer.elementEnd();
        try writer.elementEnd();
        try writer.eof();

        return self.finalizeElem(allocator, output.written());
    }

    pub fn editData(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.EditDataOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .edit_data = options,
            },
        );
    }

    fn buildActionElem(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ActionOptions,
    ) ![]const u8 {
        var message_id_buf: [20]u8 = undefined;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        var writer: xml.Writer = .init(self.allocator, &output.writer, .{ .indent = "" });
        defer writer.deinit();

        try writer.xmlDeclaration("UTF-8", null);
        try Driver.rpcStart(&writer);
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

        return self.finalizeElem(allocator, output.written());
    }

    pub fn action(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.ActionOptions,
    ) !*result.Result {
        return self.dispatchRpc(
            allocator,
            operation.RpcOptions{
                .action = options,
            },
        );
    }

    fn dispatchRpc(
        self: *Driver,
        allocator: std.mem.Allocator,
        options: operation.RpcOptions,
    ) !*result.Result {
        self.log.info("netconf.Driver dispatchRpc requested", .{});
        self.log.debug(
            "netconf.Driver dispatchRpc:  '{s}'",
            .{@tagName(options)},
        );

        var timer = try std.time.Timer.start();

        var cancel: ?*bool = null;

        // SAFETY: will always be set or we will have errored
        var input: []const u8 = undefined;

        switch (options) {
            .raw_rpc => |o| {
                cancel = o.cancel;
                input = try self.buildRawRpcElement(
                    allocator,
                    o,
                );
            },
            .get_config => |o| {
                cancel = o.cancel;
                input = try self.buildGetConfigElem(
                    allocator,
                    o,
                );
            },
            .edit_config => |o| {
                cancel = o.cancel;
                input = try self.buildEditConfigElem(
                    allocator,
                    o,
                );
            },
            .copy_config => |o| {
                cancel = o.cancel;
                input = try self.buildCopyConfigElem(
                    allocator,
                    o,
                );
            },
            .delete_config => |o| {
                cancel = o.cancel;
                input = try self.buildDeleteConfigElem(
                    allocator,
                    o,
                );
            },
            .lock => |o| {
                cancel = o.cancel;
                input = try self.buildLockElem(
                    allocator,
                    o,
                );
            },
            .unlock => |o| {
                cancel = o.cancel;
                input = try self.buildUnlockElem(
                    allocator,
                    o,
                );
            },
            .get => |o| {
                cancel = o.cancel;
                input = try self.buildGetElem(
                    allocator,
                    o,
                );
            },
            .close_session => |o| {
                cancel = o.cancel;
                input = try self.buildCloseSessionElem(
                    allocator,
                    o,
                );
            },
            .kill_session => |o| {
                cancel = o.cancel;
                input = try self.buildKillSessionElem(
                    allocator,
                    o,
                );
            },
            .commit => |o| {
                cancel = o.cancel;
                input = try self.buildCommitElem(
                    allocator,
                    o,
                );
            },
            .discard => |o| {
                cancel = o.cancel;
                input = try self.buildDiscardElem(
                    allocator,
                    o,
                );
            },
            .cancel_commit => |o| {
                cancel = o.cancel;
                input = try self.buildCancelCommitElem(
                    allocator,
                    o,
                );
            },
            .validate => |o| {
                cancel = o.cancel;
                input = try self.buildValidateElem(
                    allocator,
                    o,
                );
            },
            .get_schema => |o| {
                cancel = options.get_schema.cancel;
                input = try self.buildGetSchemaElem(
                    allocator,
                    o,
                );
            },
            .get_data => |o| {
                cancel = o.cancel;
                input = try self.buildGetDataElem(
                    allocator,
                    o,
                );
            },
            .edit_data => |o| {
                cancel = o.cancel;
                input = try self.buildEditDataElem(
                    allocator,
                    o,
                );
            },
            .action => |o| {
                cancel = o.cancel;
                input = try self.buildActionElem(
                    allocator,
                    o,
                );
            },
            else => return errors.wrapCriticalError(
                errors.ScrapliError.Driver,
                @src(),
                self.log,
                "netconf.Driver dispatchRpc: unsupported operation type",
                .{},
            ),
        }

        var res = try self.newResult(
            allocator,
            input,
            options.getKind(),
        );
        errdefer res.deinit();

        // before sending increment, but remember that in sendRpc we need to check for the
        // *previous* message id!
        self.message_id += 1;

        const ret = try self.sendRpc(
            &timer,
            cancel,
            res.input,
            self.message_id - 1,
        );

        try res.record(ret);

        return res;
    }

    pub fn sendRpc(
        self: *Driver,
        timer: *std.time.Timer,
        cancel: ?*bool,
        input: []const u8,
        message_id: u64,
    ) ![2][]const u8 {
        self.log.info("netconf.Driver sendRpc requested", .{});
        // trace because will be lots of output potentially
        self.log.trace(
            "netconf.Driver sendRpc: input '{s}', message_id '{d}'",
            .{
                input,
                message_id,
            },
        );

        try self.session.writeAndReturn(input, false);

        if (self.negotiated_version == .version_1_1) {
            try self.session.writeReturn();
        }

        while (true) {
            try self.processCancelAndTimeout(timer, cancel);

            self.messages_lock.lock();

            if (!self.messages.contains(message_id)) {
                self.messages_lock.unlock();

                if (self.process_thread_exited) {
                    return errors.ScrapliError.EOF;
                }

                std.Io.Clock.Duration.sleep(
                    .{
                        .clock = .awake,
                        .raw = .fromNanoseconds(self.options.message_poll_interval_ns),
                    },
                    self.io,
                ) catch {};

                continue;
            }

            const kv = self.messages.fetchRemove(message_id);

            self.messages_lock.unlock();

            return kv.?.value;
        }
    }
};

test "processFoundMessageIds" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            found: bool = false,
            is_notification_message: bool = false,
            is_subscription_message: bool = false,
            found_id: usize = 0,
        },
    }{
        .{
            .name = "simple-nothing-found",
            .input =
            \\#1097
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<zzzz xmlns="urn:ietf:params:xml:ns:netconf:notification:1.0"></zzzz>
            \\
            \\##
            ,
            .expected = .{},
        },
        .{
            .name = "simple-notification",
            .input =
            \\#1097
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<notification xmlns="urn:ietf:params:xml:ns:netconf:notification:1.0"></notification>
            \\
            \\##
            ,
            .expected = .{
                .found = true,
                .is_notification_message = true,
            },
        },
        .{
            .name = "simple-message-id",
            .input =
            \\#422
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><subscription-result xmlns='urn:ietf:params:xml:ns:yang:ietf-event-notifications' \\xmlns:notif-bis="urn:ietf:params:xml:ns:yang:ietf-event-notifications">notif-bis:ok</subscription-result>
            \\<subscription-id xmlns='urn:ietf:params:xml:ns:yang:ietf-event-notifications'>2147483729</subscription-id>
            \\</rpc-reply>
            \\#
            ,
            .expected = .{
                .found = true,
                .found_id = 101,
            },
        },
        .{
            .name = "simple-subscription-id",
            .input =
            \\#1097
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<notification xmlns="urn:ietf:params:xml:ns:netconf:notification:1.0"><eventTime>2025-03-29T00:37:34.12Z</eventTime><push-update xmlns="urn:ietf:params:xml:ns:yang:ietf-yang-push"><subscription-id>2147483680</subscription-id><datastore-contents-xml><mdt-oper-data xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-mdt-oper"><mdt-subscriptions><subscription-id>2147483680</subscription-id><base><stream>yang-push</stream><source-vrf></source-vrf><period>1000</period><xpath>/mdt-oper:mdt-oper-data/mdt-subscriptions</xpath></base><type>sub-type-dynamic</type><state>sub-state-valid</state><comments>Subscription validated</comments><mdt-receivers><address>10.0.0.2</address><port>44712</port><protocol>netconf</protocol><state>rcvr-state-connected</state><comments></comments><profile></profile><last-state-change-time>2025-03-29T00:37:34.113431+00:00</last-state-change-time></mdt-receivers><last-state-change-time>2025-03-29T00:37:34.111926+00:00</last-state-change-time></mdt-subscriptions></mdt-oper-data></datastore-contents-xml></push-update></notification>
            \\
            \\##
            ,
            .expected = .{
                .found = true,
                .is_subscription_message = true,
                .found_id = 2147483680,
            },
        },
    };

    for (cases) |case| {
        const actual = try Driver.processFoundMessageIds(case.input);
        try std.testing.expectEqual(case.expected.found, actual.found);
        try std.testing.expectEqual(case.expected.is_notification_message, actual.is_notification_message);
        try std.testing.expectEqual(case.expected.is_subscription_message, actual.is_subscription_message);
        try std.testing.expectEqual(case.expected.found_id, actual.found_id);
    }
}

test "processFoundMessageVersion1_0" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple-with-delim",
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>]]>]]>
            ,
            .expected =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
        },
        .{
            .name = "simple-with-declaration",
            .input =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>]]>]]>
            ,
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101">
            \\  <data>
            \\    <cli-config-data-block>
            \\    some cli output here
            \\    </cli-config-data-block>
            \\  </data>
            \\</rpc-reply>
            ,
        },
        .{
            .name = "erroneous-trailing-data",
            .input =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><ok/></rpc-reply>
            \\]]>]]>
            \\Connection to localhost closed by remote host.
            ,
            .expected =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><ok/></rpc-reply>
            \\
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = .version_1_0;

        try d.processFoundMessageVersion1_0(case.input);

        const actual_kv = d.messages.fetchRemove(101);
        defer d.allocator.free(actual_kv.?.value[0]);
        defer d.allocator.free(actual_kv.?.value[1]);

        try std.testing.expectEqualStrings(case.expected, actual_kv.?.value[1]);
    }
}

test "processFoundMessageVersion1_1" {
    const cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .input =
            \\#293
            \\<?xml version="1.0"?>
            \\<rpc-reply message-id="101" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <data>
            \\  <netconf-yang xmlns="http://cisco.com/ns/yang/Cisco-IOS-XR-man-netconf-cfg">
            \\   <agent>
            \\    <ssh>
            \\     <enable></enable>
            \\    </ssh>
            \\   </agent>
            \\  </netconf-yang>
            \\ </data>
            \\</rpc-reply>
            \\
            \\##
            ,
            .expected =
            \\<?xml version="1.0"?>
            \\<rpc-reply message-id="101" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
            \\ <data>
            \\  <netconf-yang xmlns="http://cisco.com/ns/yang/Cisco-IOS-XR-man-netconf-cfg">
            \\   <agent>
            \\    <ssh>
            \\     <enable></enable>
            \\    </ssh>
            \\   </agent>
            \\  </netconf-yang>
            \\ </data>
            \\</rpc-reply>
            \\
            ,
        },
        .{
            .name = "erroneous-trailing-data",
            .input =
            \\#93
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><ok/></rpc-reply>
            \\##
            \\Connection to localhost closed by remote host.
            ,
            .expected =
            \\<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><ok/></rpc-reply>
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            .{},
        );

        defer d.deinit();

        d.negotiated_version = .version_1_1;

        try d.processFoundMessageVersion1_1(case.input);

        const actual_kv = d.messages.fetchRemove(101);
        defer d.allocator.free(actual_kv.?.value[0]);
        defer d.allocator.free(actual_kv.?.value[1]);

        try std.testing.expectEqualStrings(case.expected, actual_kv.?.value[1]);
    }
}

test "buildRawRpcElement" {
    const test_name = "buildRawRpcElement";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.RawRpcOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
            },
            .expected =
            \\#175
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\##
            ,
        },
        .{
            .name = "simple-1.0-with-extra-namespaces",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
                .extra_namespaces = &[1][2][]const u8{
                    [2][]const u8{ "bar", "urn:example:bar" },
                },
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101" xmlns:bar="urn:example:bar"><get-config><source><running></running></source></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1-with-extra-namespaces",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
                .extra_namespaces = &[1][2][]const u8{
                    [2][]const u8{ "bar", "urn:example:bar" },
                },
            },
            .expected =
            \\#203
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101" xmlns:bar="urn:example:bar"><get-config><source><running></running></source></get-config></rpc>
            \\##
            ,
        },
        .{
            .name = "simple-1.0-with-prefix-and-extra-namespaces",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
                .base_namespace_prefix = "foo",
                .extra_namespaces = &[1][2][]const u8{
                    [2][]const u8{ "bar", "urn:example:bar" },
                },
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><foo:rpc xmlns:foo="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101" xmlns:bar="urn:example:bar"><get-config><source><running></running></source></get-config></foo:rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1-with-prefix-and-extra-namespaces",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .payload =
                \\<get-config><source><running></running></source></get-config>
                ,
                .base_namespace_prefix = "foo",
                .extra_namespaces = &[1][2][]const u8{
                    [2][]const u8{ "bar", "urn:example:bar" },
                },
            },
            .expected =
            \\#215
            \\<?xml version="1.0" encoding="UTF-8"?><foo:rpc xmlns:foo="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101" xmlns:bar="urn:example:bar"><get-config><source><running></running></source></get-config></foo:rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildRawRpcElement(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildGetConfigElem" {
    const test_name = "buildGetConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.GetConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\#175
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source></get-config></rpc>
            \\##
            ,
        },
        .{
            .name = "filtered-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .filter = "<foo:interface/>",
                .filter_type = operation.FilterType.subtree,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="subtree"><foo:interface/></filter></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "filtered-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .filter = "<foo:interface/>",
                .filter_type = operation.FilterType.subtree,
            },
            .expected =
            \\#223
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="subtree"><foo:interface/></filter></get-config></rpc>
            \\##
            ,
        },
        .{
            .name = "filtered-1.0-with-defaults",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .filter = "<foo:interface/>",
                .filter_type = operation.FilterType.subtree,
                .defaults_type = operation.DefaultsType.report_all,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="subtree"><foo:interface/></filter><with-defaults xmlns="urn:ietf:params:netconf:capability:with-defaults:1.0">report-all</with-defaults></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "filtered-1.1-with-defaults",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .filter = "<foo:interface/>",
                .filter_type = operation.FilterType.subtree,
                .defaults_type = operation.DefaultsType.report_all,
            },
            .expected =
            \\#325
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="subtree"><foo:interface/></filter><with-defaults xmlns="urn:ietf:params:netconf:capability:with-defaults:1.0">report-all</with-defaults></get-config></rpc>
            \\##
            ,
        },
        .{
            .name = "filtered-1.0-xpath",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .filter = "/interfaces/interface[name='Management0']/state",
                .filter_type = operation.FilterType.xpath,
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="xpath" select="/interfaces/interface[name='Management0']/state"></filter></get-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "filtered-1.1-xpath",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .filter = "/interfaces/interface[name='Management0']/state",
                .filter_type = operation.FilterType.xpath,
            },
            .expected =
            \\#262
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-config><source><running></running></source><filter type="xpath" select="/interfaces/interface[name='Management0']/state"></filter></get-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetConfigElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "builEditConfigElem" {
    const test_name = "builEditConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.EditConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = Config{},
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
            .version = .version_1_1,
            .driver_config = Config{},
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
        .{
            .name = "1.1-with-defaults-operation",
            .version = .version_1_1,
            .driver_config = Config{},
            .options = operation.EditConfigOptions{
                .cancel = null,
                .config = "<top xmlns=\"http://example.com/schema/1.2/config\"><interface><name>Ethernet0/0</name></interface></top>",
                .target = operation.DatastoreType.running,
                .default_operation = operation.DefaultOperation.merge,
            },
            .expected =
            \\#341
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-config><target><running></running></target><default-operation>merge</default-operation><config><top xmlns="http://example.com/schema/1.2/config"><interface><name>Ethernet0/0</name></interface></top></config></edit-config></rpc>
            \\##
            ,
        },
        .{
            .name = "1.1-with-test-option",
            .version = .version_1_1,
            .driver_config = Config{},
            .options = operation.EditConfigOptions{
                .cancel = null,
                .config = "<top xmlns=\"http://example.com/schema/1.2/config\"><interface><name>Ethernet0/0</name></interface></top>",
                .target = operation.DatastoreType.running,
                .test_option = operation.TestOption.set,
            },
            .expected =
            \\#327
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-config><target><running></running></target><test-option>set</test-option><config><top xmlns="http://example.com/schema/1.2/config"><interface><name>Ethernet0/0</name></interface></top></config></edit-config></rpc>
            \\##
            ,
        },
        .{
            .name = "1.1-with-error-option",
            .version = .version_1_1,
            .driver_config = Config{},
            .options = operation.EditConfigOptions{
                .cancel = null,
                .config = "<top xmlns=\"http://example.com/schema/1.2/config\"><interface><name>Ethernet0/0</name></interface></top>",
                .target = operation.DatastoreType.running,
                .error_option = operation.ErrorOption.continue_on_error,
            },
            .expected =
            \\#343
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-config><target><running></running></target><error-option>continue-on-error</error-option><config><top xmlns="http://example.com/schema/1.2/config"><interface><name>Ethernet0/0</name></interface></top></config></edit-config></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildEditConfigElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "builCopyConfigElem" {
    const test_name = "builCopyConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.CopyConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><copy-config><source><running></running></source><target><startup></startup></target></copy-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCopyConfigElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "builDeleteConfigElem" {
    const test_name = "builDeleteConfigElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.DeleteConfigOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><delete-config><target><running></running></target></delete-config></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildDeleteConfigElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildLockElem" {
    const test_name = "buildLockElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.LockUnlockOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><lock><target><running></running></target></lock></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildLockElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildUnlockElem" {
    const test_name = "buildUnlockElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.LockUnlockOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><unlock><target><running></running></target></unlock></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildUnlockElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildGetElem" {
    const test_name = "buildGetElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.GetOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get></get></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildCloseSessionElem" {
    const test_name = "buildCloseSessionElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.CloseSessionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><close-session></close-session></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCloseSessionElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildKillSessionElem" {
    const test_name = "buildKillSessionElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.KillSessionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
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
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildKillSessionElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildCommitElem" {
    const test_name = "buildCommitElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.CommitOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><commit></commit></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCommitElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildDiscardElem" {
    const test_name = "buildDiscardElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.DiscardOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><discard-changes></discard-changes></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildDiscardElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildCancelCommitElem" {
    const test_name = "buildCancelCommitElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.CancelCommitOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><cancel-commit></cancel-commit></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\#145
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><cancel-commit></cancel-commit></rpc>
            \\##
            ,
        },
        .{
            .name = "persist-id",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .persist_id = "1234",
            },
            .expected =
            \\#174
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><cancel-commit><persist-id>1234</persist-id></cancel-commit></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildCancelCommitElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildValidateElem" {
    const test_name = "buildValidateElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.ValidateOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><validate xmlns="urn:ietf:params:xml:ns:netconf:capability:validate:1.0"><source><running></running></source></validate></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\#234
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><validate xmlns="urn:ietf:params:xml:ns:netconf:capability:validate:1.0"><source><running></running></source></validate></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildValidateElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildGetSchemaElem" {
    const test_name = "buildGetSchemaElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.GetSchemaOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
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
            .version = .version_1_1,
            .driver_config = .{},
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetSchemaElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "buildGetDataElem" {
    const test_name = "buildGetDataElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.GetDataOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores" xmlns:or="urn:ietf:params:xml:ns:yang:ietf-origin"><datastore>ds:running</datastore></get-data></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{},
            .expected =
            \\#328
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><get-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores" xmlns:or="urn:ietf:params:xml:ns:yang:ietf-origin"><datastore>ds:running</datastore></get-data></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildGetDataElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "builEditDataElem" {
    const test_name = "buildEditDataElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.EditDataOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .edit_content = "foo",
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores"><datastore>ds:running</datastore><config>foo</config></edit-data></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .edit_content = "foo",
            },
            .expected =
            \\#299
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores"><datastore>ds:running</datastore><config>foo</config></edit-data></rpc>
            \\##
            ,
        },
        .{
            .name = "default-operation",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .edit_content = "foo",
                .default_operation = operation.DefaultOperation.merge,
            },
            .expected =
            \\#343
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><edit-data xmlns="urn:ietf:params:xml:ns:yang:ietf-netconf-nmda" xmlns:ds="urn:ietf:params:xml:ns:yang:ietf-datastores"><datastore>ds:running</datastore><default-operation>merge</default-operation><config>foo</config></edit-data></rpc>
            \\##
            ,
        },
    };

    for (cases) |case| {
        const d = try Driver.init(
            std.testing.allocator,
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildEditDataElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}

test "builActionElem" {
    const test_name = "builActionElem";

    const cases = [_]struct {
        name: []const u8,
        version: operation.Version,
        driver_config: Config,
        options: operation.ActionOptions,
        expected: []const u8,
    }{
        .{
            .name = "simple-1.0",
            .version = .version_1_0,
            .driver_config = .{},
            .options = .{
                .action = "foo",
            },
            .expected =
            \\<?xml version="1.0" encoding="UTF-8"?><rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="101"><action xmlns="urn:ietf:params:xml:ns:yang:1">foo</action></rpc>
            \\]]>]]>
            ,
        },
        .{
            .name = "simple-1.1",
            .version = .version_1_1,
            .driver_config = .{},
            .options = .{
                .action = "foo",
            },
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
            std.testing.io,
            "localhost",
            case.driver_config,
        );

        defer d.deinit();

        d.negotiated_version = case.version;

        const actual = try d.buildActionElem(
            std.testing.allocator,
            case.options,
        );
        defer std.testing.allocator.free(actual);

        try test_helper.testStrResult(
            test_name,
            case.name,
            actual,
            case.expected,
        );
    }
}
