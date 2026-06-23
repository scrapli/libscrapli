// zlinter-disable no_panic - ignoring as we do panic on things that *really* should not happen
const std = @import("std");

const ascii = @import("ascii.zig");
const errors = @import("errors.zig");
const ffi_args_to_options = @import("ffi-args-to-netconf-options.zig");
const ffi_common = @import("ffi-common.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const netconf_operation = @import("netconf-operation.zig");
const result = @import("netconf-result.zig");

/// For forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

fn dupeSlice(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try allocator.dupe(u8, value);
}

fn dupeOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| {
        return try dupeSlice(allocator, v);
    }

    return null;
}

fn ffiOwnedRawRpcOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.RawRpcOptions,
) !netconf_operation.RawRpcOptions {
    var owned = options;
    owned.payload = try dupeSlice(allocator, options.payload);
    errdefer allocator.free(owned.payload);
    owned.base_namespace_prefix = try dupeOptionalSlice(allocator, options.base_namespace_prefix);
    errdefer if (owned.base_namespace_prefix) |base_namespace_prefix| allocator.free(base_namespace_prefix);
    owned._extra_namespaces_ffi = try dupeOptionalSlice(allocator, options._extra_namespaces_ffi);

    return owned;
}

fn ffiOwnedGetConfigOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.GetConfigOptions,
) !netconf_operation.GetConfigOptions {
    var owned = options;
    owned.filter = try dupeOptionalSlice(allocator, options.filter);
    errdefer if (owned.filter) |filter| allocator.free(filter);
    owned.filter_namespace_prefix = try dupeOptionalSlice(allocator, options.filter_namespace_prefix);
    errdefer if (owned.filter_namespace_prefix) |prefix| allocator.free(prefix);
    owned.filter_namespace = try dupeOptionalSlice(allocator, options.filter_namespace);

    return owned;
}

fn ffiOwnedEditConfigOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.EditConfigOptions,
) !netconf_operation.EditConfigOptions {
    var owned = options;
    owned.config = try dupeSlice(allocator, options.config);

    return owned;
}

fn ffiOwnedGetOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.GetOptions,
) !netconf_operation.GetOptions {
    var owned = options;
    owned.filter = try dupeOptionalSlice(allocator, options.filter);
    errdefer if (owned.filter) |filter| allocator.free(filter);
    owned.filter_namespace_prefix = try dupeOptionalSlice(allocator, options.filter_namespace_prefix);
    errdefer if (owned.filter_namespace_prefix) |prefix| allocator.free(prefix);
    owned.filter_namespace = try dupeOptionalSlice(allocator, options.filter_namespace);

    return owned;
}

fn ffiOwnedCancelCommitOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.CancelCommitOptions,
) !netconf_operation.CancelCommitOptions {
    var owned = options;
    owned.persist_id = try dupeOptionalSlice(allocator, options.persist_id);

    return owned;
}

fn ffiOwnedGetSchemaOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.GetSchemaOptions,
) !netconf_operation.GetSchemaOptions {
    var owned = options;
    owned.identifier = try dupeSlice(allocator, options.identifier);
    errdefer allocator.free(owned.identifier);
    owned.version = try dupeOptionalSlice(allocator, options.version);

    return owned;
}

fn ffiOwnedGetDataOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.GetDataOptions,
) !netconf_operation.GetDataOptions {
    var owned = options;
    owned.filter = try dupeOptionalSlice(allocator, options.filter);
    errdefer if (owned.filter) |filter| allocator.free(filter);
    owned.filter_namespace_prefix = try dupeOptionalSlice(allocator, options.filter_namespace_prefix);
    errdefer if (owned.filter_namespace_prefix) |prefix| allocator.free(prefix);
    owned.filter_namespace = try dupeOptionalSlice(allocator, options.filter_namespace);
    errdefer if (owned.filter_namespace) |namespace| allocator.free(namespace);
    owned.origin_filters = try dupeOptionalSlice(allocator, options.origin_filters);

    return owned;
}

fn ffiOwnedEditDataOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.EditDataOptions,
) !netconf_operation.EditDataOptions {
    var owned = options;
    owned.edit_content = try dupeSlice(allocator, options.edit_content);

    return owned;
}

fn ffiOwnedActionOptions(
    allocator: std.mem.Allocator,
    options: netconf_operation.ActionOptions,
) !netconf_operation.ActionOptions {
    var owned = options;
    owned.action = try dupeSlice(allocator, options.action);

    return owned;
}

export fn ls_netconf_open(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.open() catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver open {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    switch (d.real_driver) {
        .cli => {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to open non netconf driver",
                .{},
            ) catch {};

            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
        .netconf => {
            operation_id.* = d.queueOperation(
                ffi_operations.OperationOptions{
                    .id = 0,
                    .operation = .{
                        .netconf = .{
                            .open = .{
                                .cancel = cancel,
                            },
                        },
                    },
                },
            ) catch |err| {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue open {any}",
                    .{err},
                ) catch {};

                return ffi_common.toFfiResult(err);
            };
        },
    }

    while (true) {
        // weve already waited for the operation loop to start in the queue operation function,
        // but we also need to ensure we wait for the open operation to actually get put into
        // the queue before continuing
        d.operation_lock.lock(d.io) catch |err| {
            return ffi_common.toFfiResult(err);
        };
        defer d.operation_lock.unlock(d.io);

        const op = d.operation_results.get(operation_id.*);
        if (op != null) {
            break;
        }

        std.Io.Clock.Duration.sleep(
            .{
                .clock = .awake,
                .raw = .fromNanoseconds(ffi_driver.operation_thread_ready_sleep),
            },
            d.io,
        ) catch |err| {
            d.getLogger().warn(
                "ffirootnetconf ls_netconf_open: sleep error '{}', ignoring",
                .{err},
            );
        };
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_close(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    force: bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    switch (d.real_driver) {
        .cli => {
            // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to close non netconf driver",
                .{},
            ) catch {};

            return @intFromEnum(ffi_common.FfiResult.invalid_argument);
        },
        .netconf => {
            operation_id.* = d.queueOperation(
                ffi_operations.OperationOptions{
                    .id = 0,
                    .operation = .{
                        .netconf = .{
                            .close = .{
                                .cancel = cancel,
                                .force = force,
                            },
                        },
                    },
                },
            ) catch |err| {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue close {any}",
                    .{err},
                ) catch {};

                return ffi_common.toFfiResult(err);
            };
        },
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get_subscription_id(
    operation_result: [*c]const u8,
    subscription_id: *u64,
) callconv(.c) u8 {
    if (operation_result == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const maybe_subscription_id = result.getSubscriptionId(std.mem.span(operation_result)) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    if (maybe_subscription_id) |id| {
        subscription_id.* = id;

        return @intFromEnum(ffi_common.FfiResult.success);
    }

    return @intFromEnum(ffi_common.FfiResult.operation);
}

export fn ls_netconf_fetch_operation_sizes(
    d_ptr: *ffi_common.LsDriver,
    operation_id: u32,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_rpc_warnings_size: *u64,
    operation_rpc_errors_size: *u64,
    operation_error_size: *u64,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const ret = d.dequeueOperation(operation_id, false) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during poll operation {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: attempting to access non netconf result from netconf driver",
                    .{},
                ) catch {};

                return @intFromEnum(ffi_common.FfiResult.invalid_argument);
            },
        };

        operation_input_size.* = dret.input.len;
        operation_result_raw_size.* = dret.result_raw.len;
        operation_result_size.* = dret.result.len;

        if (dret.result_failure_indicated) {
            operation_rpc_warnings_size.* = dret.getWarningsLen();
            operation_rpc_errors_size.* = dret.getErrorsLen();
        }
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_fetch_operation(
    d_ptr: *ffi_common.LsDriver,
    operation_id: u32,
    operation_start_time: *u64,
    operation_end_time: *u64,
    operation_input: *[]u8,
    operation_result_raw: *[]u8,
    operation_result: *[]u8,
    operation_rpc_warnings: *[]u8,
    operation_rpc_errors: *[]u8,
    operation_error: *[]u8,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const ret = d.dequeueOperation(
        operation_id,
        true,
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during fetch operation {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    defer {
        const dret = switch (ret.result) {
            .netconf => |r| r,
            else => @panic("attempting to access non netconf result from netconf type"),
        };
        if (dret != null) {
            dret.?.deinit();
        }
    }

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        @memcpy(operation_error.*.ptr, err_name);
    } else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => {
                // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: attempting to access non netconf result from netconf driver",
                    .{},
                ) catch {};

                return @intFromEnum(ffi_common.FfiResult.invalid_argument);
            },
        };

        operation_start_time.* = @intCast(dret.start_time_ns);

        if (dret.end_time_ns == 0 or (dret.start_time_ns == dret.end_time_ns)) {
            // close for example can be a noop if force is set, altenratively sometimes in testing
            // this may end up being so fast its somehow the same ns (in ns??? wild right?), so lets
            // just say the op took 1ns
            operation_end_time.* = @intCast(dret.start_time_ns + 1);
        } else {
            operation_end_time.* = @intCast(dret.end_time_ns);
        }

        @memcpy(operation_input.*, dret.input);
        @memcpy(operation_result_raw.*, dret.result_raw);
        @memcpy(operation_result.*, dret.result);

        // to avoid a pointless allocation since we are already copying from the result into the
        // given string pointers, we'll do basically the same thing the result does in normal (zig)
        // operations in getResult/getResultRaw by iterating over the underlying array list and
        // copying from there, inserting newlines between results, into the given pointer(s)
        var cur: usize = 0;
        for (0.., dret.result_warning_messages.items) |idx, warning| {
            @memcpy(operation_rpc_warnings.*[cur .. cur + warning.len], warning);
            cur += warning.len;

            if (idx != dret.result_warning_messages.items.len - 1) {
                operation_rpc_warnings.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }

        cur = 0;

        for (0.., dret.result_error_messages.items) |idx, err| {
            @memcpy(operation_rpc_errors.*[cur .. cur + err.len], err);
            cur += err.len;

            if (idx != dret.result_error_messages.items.len - 1) {
                operation_rpc_errors.*[cur] = ascii.control_chars.lf;
                cur += 1;
            }
        }
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get_session_id(
    d_ptr: *ffi_common.LsDriver,
    session_id: *u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    if (d.real_driver.netconf.session_id) |s| {
        session_id.* = s;

        return @intFromEnum(ffi_common.FfiResult.success);
    }

    return @intFromEnum(ffi_common.FfiResult.operation);
}

export fn ls_netconf_next_notification_message_size(
    d_ptr: *ffi_common.LsDriver,
    size: *u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.real_driver.netconf.notifications_lock.lock(d.io) catch |err| {
        return ffi_common.toFfiResult(err);
    };
    defer d.real_driver.netconf.notifications_lock.unlock(d.io);

    if (d.real_driver.netconf.notifications.items.len > 0) {
        size.* = d.real_driver.netconf.notifications.items[0].len;
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_next_notification_message(
    d_ptr: *ffi_common.LsDriver,
    notification: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.real_driver.netconf.notifications_lock.lock(d.io) catch |err| {
        return ffi_common.toFfiResult(err);
    };
    defer d.real_driver.netconf.notifications_lock.unlock(d.io);

    if (d.real_driver.netconf.notifications.items.len == 0) {
        // an error because they shoulda peeked at sizes first
        // to know there was something to read
        return @intFromEnum(ffi_common.FfiResult.operation);
    }

    const notif = d.real_driver.netconf.notifications.orderedRemove(0);

    @memcpy(notification.*, notif);

    d.real_driver.netconf.allocator.free(notif);

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_next_subscription_message_size(
    d_ptr: *ffi_common.LsDriver,
    subscription_id: u64,
    size: *u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.real_driver.netconf.subscriptions_lock.lock(d.io) catch |err| {
        return ffi_common.toFfiResult(err);
    };
    defer d.real_driver.netconf.subscriptions_lock.unlock(d.io);

    if (d.real_driver.netconf.subscriptions.getPtr(subscription_id)) |sub| {
        if (sub.items.len == 0) {
            return @intFromEnum(ffi_common.FfiResult.success);
        }

        size.* = sub.items[0].len;
    }

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_next_subscription_message(
    d_ptr: *ffi_common.LsDriver,
    subscription_id: u64,
    subscription: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    d.real_driver.netconf.subscriptions_lock.lock(d.io) catch |err| {
        return ffi_common.toFfiResult(err);
    };
    defer d.real_driver.netconf.subscriptions_lock.unlock(d.io);

    const subs = d.real_driver.netconf.subscriptions.getPtr(subscription_id);

    if (subs == null or subs.?.items.len == 0) {
        // an error because they shoulda peeked at sizes first
        // to know there was something to read
        return @intFromEnum(ffi_common.FfiResult.operation);
    }

    const sub = subs.?.orderedRemove(0);

    @memcpy(subscription.*, sub);

    d.real_driver.netconf.allocator.free(sub);

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_raw_rpc(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    payload: [*c]const u8,
    base_namespace_prefix: [*c]const u8,
    extra_namespaces: [*c]const u8,
) callconv(.c) u8 {
    if (payload == null or
        base_namespace_prefix == null or
        extra_namespaces == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedRawRpcOptions(d.allocator, ffi_args_to_options.rawRpcOptionsFromArgs(
        cancel,
        payload,
        base_namespace_prefix,
        extra_namespaces,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .raw_rpc = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue raw {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get_config(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) callconv(.c) u8 {
    if (source == null or
        filter == null or
        filter_type == null or
        filter_namespace_prefix == null or
        filter_namespace == null or
        defaults_type == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedGetConfigOptions(d.allocator, ffi_args_to_options.getConfigOptionsFromArgs(
        cancel,
        source,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .get_config = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getConfig {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_edit_config(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    config: [*c]const u8,
    target: [*c]const u8,
    default_operation: [*c]const u8,
    test_option: [*c]const u8,
    error_option: [*c]const u8,
) callconv(.c) u8 {
    if (config == null or
        target == null or
        default_operation == null or
        test_option == null or
        error_option == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedEditConfigOptions(d.allocator, ffi_args_to_options.editConfigOptionsFromArgs(
        cancel,
        config,
        target,
        default_operation,
        test_option,
        error_option,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .edit_config = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue editConfig {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_copy_config(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
    source: [*c]const u8,
) callconv(.c) u8 {
    if (target == null or source == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.copyConfigOptionsFromArgs(
        cancel,
        source,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .copy_config = options,
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue copyConfig {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_delete_config(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    if (target == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.deleteConfigOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .delete_config = options,
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue deleteConfig {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_lock(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    if (target == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.lockUnlockOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .lock = options,
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue lock {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_unlock(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    if (target == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffi_args_to_options.lockUnlockOptionsFromArgs(
        cancel,
        target,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .unlock = options,
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) callconv(.c) u8 {
    if (filter == null or
        filter_type == null or
        filter_namespace_prefix == null or
        filter_namespace == null or
        defaults_type == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedGetOptions(d.allocator, ffi_args_to_options.getOptionsFromArgs(
        cancel,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .get = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_close_session(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .close_session = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_kill_session(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    session_id: u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .kill_session = .{
                        .cancel = cancel,
                        .session_id = session_id,
                    },
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_commit(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .commit = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue commit {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_discard(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .discard = .{
                        .cancel = cancel,
                    },
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue discard {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_cancel_commit(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    persist_id: [*c]const u8,
) callconv(.c) u8 {
    if (persist_id == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedCancelCommitOptions(d.allocator, ffi_args_to_options.cancelCommitOptionsFromArgs(
        cancel,
        persist_id,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .cancel_commit = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue cancelCommit {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_validate(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
) callconv(.c) u8 {
    if (source == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .validate = ffi_args_to_options.validateOptionsFromArgs(
                        cancel,
                        source,
                    ),
                },
            },
        },
    ) catch |err| {
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue validate {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get_schema(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    identifier: [*c]const u8,
    version: [*c]const u8,
    format: [*c]const u8,
) callconv(.c) u8 {
    if (identifier == null or
        version == null or
        format == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedGetSchemaOptions(d.allocator, ffi_args_to_options.getSchemaOptionsFromArgs(
        cancel,
        identifier,
        version,
        format,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .get_schema = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getSchema {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_get_data(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    datastore: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    config_filter: [*c]const u8,
    origin_filters: [*c]const u8,
    max_depth: u32,
    with_origin: bool,
    defaults_type: [*c]const u8,
) callconv(.c) u8 {
    if (datastore == null or
        filter == null or
        filter_type == null or
        filter_namespace_prefix == null or
        filter_namespace == null or
        config_filter == null or
        origin_filters == null or
        defaults_type == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedGetDataOptions(d.allocator, ffi_args_to_options.getDataOptionsFromArgs(
        cancel,
        datastore,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        config_filter,
        origin_filters,
        max_depth,
        with_origin,
        defaults_type,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .get_data = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getData {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_edit_data(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    datastore: [*c]const u8,
    edit_content: [*c]const u8,
    default_operation: [*c]const u8,
) callconv(.c) u8 {
    if (datastore == null or
        edit_content == null or
        default_operation == null)
    {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedEditDataOptions(d.allocator, ffi_args_to_options.editDataOptionsFromArgs(
        cancel,
        datastore,
        edit_content,
        default_operation,
    )) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .edit_data = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue editData {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

export fn ls_netconf_action(
    d_ptr: *ffi_common.LsDriver,
    operation_id: *u32,
    cancel: *bool,
    action: [*c]const u8,
) callconv(.c) u8 {
    if (action == null) {
        return @intFromEnum(ffi_common.FfiResult.invalid_argument);
    }

    const d: *ffi_driver.FfiDriver = @ptrCast(@alignCast(d_ptr));

    const options = ffiOwnedActionOptions(d.allocator, .{
        .cancel = cancel,
        .action = std.mem.span(action),
    }) catch |err| {
        return ffi_common.toFfiResult(err);
    };

    const operation_options = ffi_operations.OperationOptions{
        .id = 0,
        .ffi_owned = true,
        .operation = .{
            .netconf = .{
                .action = options,
            },
        },
    };

    const _operation_id = d.queueOperation(operation_options) catch |err| {
        ffi_operations.deinitFfiOwnedOperationOptions(d.allocator, operation_options);
        // zlinter-disable-next-line no_swallow_error - returning status code for ffi ops
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue action {any}",
            .{err},
        ) catch {};

        return ffi_common.toFfiResult(err);
    };

    operation_id.* = _operation_id;

    return @intFromEnum(ffi_common.FfiResult.success);
}

test "ffi: ls_netconf_raw_rpc null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_netconf_raw_rpc(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "",
            "",
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_netconf_raw_rpc(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "payload",
            null,
            "",
        ),
    );

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_netconf_raw_rpc(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            "payload",
            "",
            null,
        ),
    );
}

test "ffi: ls_netconf_get_config null arguments" {
    var op_id: u32 = 0;
    var cancel: bool = false;

    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_netconf_get_config(
            @ptrFromInt(0xDEADBEEF),
            &op_id,
            &cancel,
            null,
            "",
            "",
            "",
            "",
            "",
        ),
    );
}

test "ffi: ls_netconf_get_subscription_id null result" {
    var sub_id: u64 = 0;
    try std.testing.expectEqual(
        @intFromEnum(ffi_common.FfiResult.invalid_argument),
        ls_netconf_get_subscription_id(null, &sub_id),
    );
}
