// zlint-disable suppressed-errors
const std = @import("std");

const ascii = @import("ascii.zig");
const errors = @import("errors.zig");
const ffi_args_to_options = @import("ffi-args-to-netconf-options.zig");
const ffi_driver = @import("ffi-driver.zig");
const ffi_operations = @import("ffi-operations.zig");
const result = @import("netconf-result.zig");

// for forcing inclusion in the ffi-root.zig entrypoint we use for the ffi layer
pub const noop = true;

export fn ls_netconf_open(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.open() catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during driver open {any}",
            .{err},
        ) catch {};

        return 1;
    };

    switch (d.real_driver) {
        .cli => {
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to open non netconf driver",
                .{},
            ) catch {};

            return 1;
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
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue open {any}",
                    .{err},
                ) catch {};

                return 1;
            };
        },
    }

    while (true) {
        // weve already waited for the operation loop to start in the queue operation function,
        // but we also need to ensure we wait for the open operation to actually get put into
        // the queue before continuing
        d.operation_lock.lock();
        defer d.operation_lock.unlock();

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
        ) catch {};
    }

    return 0;
}

export fn ls_netconf_close(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    force: bool,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    switch (d.real_driver) {
        .cli => {
            errors.wrapCriticalError(
                errors.ScrapliError.Operation,
                @src(),
                d.getLogger(),
                "ffi: attempting to close non netconf driver",
                .{},
            ) catch {};

            return 1;
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
                errors.wrapCriticalError(
                    errors.ScrapliError.Operation,
                    @src(),
                    d.getLogger(),
                    "ffi: error during queue close {any}",
                    .{err},
                ) catch {};

                return 1;
            };
        },
    }

    return 0;
}

export fn ls_netconf_get_subscription_id(
    operation_result: [*c]const u8,
    subscription_id: *u64,
) callconv(.c) u8 {
    const maybe_subscription_id = result.getSubscriptionId(std.mem.span(operation_result)) catch {
        return 1;
    };

    if (maybe_subscription_id) |id| {
        subscription_id.* = id;

        return 0;
    }

    return 1;
}

export fn ls_netconf_fetch_operation_sizes(
    d_ptr: usize,
    operation_id: u32,
    operation_input_size: *u64,
    operation_result_raw_size: *u64,
    operation_result_size: *u64,
    operation_rpc_warnings_size: *u64,
    operation_rpc_errors_size: *u64,
    operation_error_size: *u64,
) callconv(.c) u8 {
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.dequeueOperation(operation_id, false) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during poll operation {any}",
            .{err},
        ) catch {};

        return 1;
    };

    if (ret.err != null) {
        const err_name = @errorName(ret.err.?);

        operation_result_size.* = 0;
        operation_error_size.* = err_name.len;
    } else {
        const dret = switch (ret.result) {
            .netconf => |r| r.?,
            else => @panic("attempting to access non netconf result from netconf type"),
        };

        operation_input_size.* = dret.input.len;
        operation_result_raw_size.* = dret.result_raw.len;
        operation_result_size.* = dret.result.len;

        if (dret.result_failure_indicated) {
            operation_rpc_warnings_size.* = dret.getWarningsLen();
            operation_rpc_errors_size.* = dret.getErrorsLen();
        }
    }

    return 0;
}

export fn ls_netconf_fetch_operation(
    d_ptr: usize,
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
    var d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const ret = d.dequeueOperation(
        operation_id,
        true,
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during fetch operation {any}",
            .{err},
        ) catch {};

        return 1;
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
            else => @panic("attempting to access non netconf result from netconf type"),
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

    return 0;
}

export fn ls_netconf_get_session_id(
    d_ptr: usize,
    session_id: *u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    if (d.real_driver.netconf.session_id) |s| {
        session_id.* = s;

        return 0;
    }

    return 1;
}

export fn ls_netconf_next_notification_message_size(
    d_ptr: usize,
    size: *u64,
) callconv(.c) void {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.netconf.notifications_lock.lock();
    defer d.real_driver.netconf.notifications_lock.unlock();

    if (d.real_driver.netconf.notifications.items.len > 0) {
        size.* = d.real_driver.netconf.notifications.items[0].len;
    }
}

export fn ls_netconf_next_notification_message(
    d_ptr: usize,
    notification: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.netconf.notifications_lock.lock();
    defer d.real_driver.netconf.notifications_lock.unlock();

    if (d.real_driver.netconf.notifications.items.len == 0) {
        // an error because they shoulda peeked at sizes first
        // to know there was something to read
        return 1;
    }

    const notif = d.real_driver.netconf.notifications.orderedRemove(0);

    @memcpy(notification.*, notif);

    d.real_driver.netconf.allocator.free(notif);

    return 0;
}

export fn ls_netconf_next_subscription_message_size(
    d_ptr: usize,
    subscription_id: u64,
    size: *u64,
) callconv(.c) void {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.netconf.subscriptions_lock.lock();
    defer d.real_driver.netconf.subscriptions_lock.unlock();

    if (!d.real_driver.netconf.subscriptions.contains(subscription_id)) {
        return;
    }

    if (d.real_driver.netconf.subscriptions.get(subscription_id)) |sub| {
        if (sub.items.len == 0) {
            return;
        }

        size.* = sub.items[0].len;
    }
}

export fn ls_netconf_next_subscription_message(
    d_ptr: usize,
    subscription_id: u64,
    subscription: *[]u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    d.real_driver.netconf.subscriptions_lock.lock();
    defer d.real_driver.netconf.subscriptions_lock.unlock();

    var subs = d.real_driver.netconf.subscriptions.get(subscription_id);

    if (subs == null or subs.?.items.len == 0) {
        // an error because they shoulda peeked at sizes first
        // to know there was something to read
        return 1;
    }

    const sub = subs.?.orderedRemove(0);

    @memcpy(subscription.*, sub);

    d.real_driver.netconf.allocator.free(sub);

    // we got a copy of the arraylist, so clobber/put back the updated copy that has our
    // element removed; probably sohould have a pointer to it instead but for now this is ok
    d.real_driver.netconf.subscriptions.put(subscription_id, subs.?) catch {
        return 1;
    };

    return 0;
}

export fn ls_netconf_raw_rpc(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    payload: [*c]const u8,
    base_namespace_prefix: [*c]const u8,
    extra_namespaces: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .raw_rpc = ffi_args_to_options.RawRpcOptionsFromArgs(
                        cancel,
                        payload,
                        base_namespace_prefix,
                        extra_namespaces,
                    ),
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue raw {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_get_config(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.GetConfigOptionsFromArgs(
        cancel,
        source,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_config = options,
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getConfig {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_edit_config(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    config: [*c]const u8,
    target: [*c]const u8,
    default_operation: [*c]const u8,
    test_option: [*c]const u8,
    error_option: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.EditConfigOptionsFromArgs(
        cancel,
        config,
        target,
        default_operation,
        test_option,
        error_option,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .edit_config = options,
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue editConfig {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_copy_config(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
    source: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.CopyConfigOptionsFromArgs(
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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue copyConfig {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_delete_config(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.DeleteConfigOptionsFromArgs(
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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue deleteConfig {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_lock(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.LockUnlockOptionsFromArgs(
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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue lock {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_unlock(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    target: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.LockUnlockOptionsFromArgs(
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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_get(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const options = ffi_args_to_options.GetOptionsFromArgs(
        cancel,
        filter,
        filter_type,
        filter_namespace_prefix,
        filter_namespace,
        defaults_type,
    );

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get = options,
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_close_session(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_kill_session(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    session_id: u64,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue unlock {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_commit(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue commit {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_discard(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

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
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue discard {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_cancel_commit(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    persist_id: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .cancel_commit = ffi_args_to_options.CancelCommitOptionsFromArgs(
                        cancel,
                        persist_id,
                    ),
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue cancelCommit {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_validate(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    source: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{ .validate = ffi_args_to_options.ValidateOptionsFromArgs(
                    cancel,
                    source,
                ) },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue validate {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_get_schema(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    identifier: [*c]const u8,
    version: [*c]const u8,
    format: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_schema = ffi_args_to_options.GetSchemaOptionsFromArgs(
                        cancel,
                        identifier,
                        version,
                        format,
                    ),
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getSchema {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_get_data(
    d_ptr: usize,
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
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .get_data = ffi_args_to_options.GetDataOptionsFromArgs(
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
                    ),
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue getData {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_edit_data(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    datastore: [*c]const u8,
    edit_content: [*c]const u8,
    default_operation: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .edit_data = ffi_args_to_options.EditDataOptionsFromArgs(
                        cancel,
                        datastore,
                        edit_content,
                        default_operation,
                    ),
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue editData {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}

export fn ls_netconf_action(
    d_ptr: usize,
    operation_id: *u32,
    cancel: *bool,
    action: [*c]const u8,
) callconv(.c) u8 {
    const d: *ffi_driver.FfiDriver = @ptrFromInt(d_ptr);

    const _operation_id = d.queueOperation(
        ffi_operations.OperationOptions{
            .id = 0,
            .operation = .{
                .netconf = .{
                    .action = .{
                        .cancel = cancel,
                        .action = std.mem.span(action),
                    },
                },
            },
        },
    ) catch |err| {
        errors.wrapCriticalError(
            errors.ScrapliError.Operation,
            @src(),
            d.getLogger(),
            "ffi: error during queue action {any}",
            .{err},
        ) catch {};

        return 1;
    };

    operation_id.* = _operation_id;

    return 0;
}
