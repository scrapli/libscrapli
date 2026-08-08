const std = @import("std");

const errors = @import("errors.zig");
const ffi_operations = @import("ffi-operations.zig");
const operation = @import("netconf-operation.zig");

/// Builds RawRpcOptions from given ffi inputs. Extra namespaces arrive packed back-to-back w/
/// a lens array to slice them apart, entries alternating prefix, namespace -- so lens.len must
/// be even, two entries per pair.
pub fn rawRpcOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    payload: [*c]const u8,
    base_namespace_prefix: [*c]const u8,
    extra_namespaces: []const u8,
    extra_namespace_lens: []const u64,
) !operation.RawRpcOptions {
    var options = operation.RawRpcOptions{
        .cancel = cancel,
        .payload = try allocator.dupe(u8, std.mem.span(payload)),
    };

    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (extra_namespace_lens.len > 0) {
        if (extra_namespace_lens.len % 2 != 0) {
            // entries must come in prefix, namespace pairs
            return errors.ScrapliError.IndexError;
        }

        const pairs = try allocator.alloc([2][]const u8, extra_namespace_lens.len / 2);

        var pairs_adopted: bool = false;
        var strings_populated: usize = 0;

        errdefer {
            if (!pairs_adopted) {
                for (0..strings_populated) |idx| {
                    allocator.free(pairs[idx / 2][idx % 2]);
                }

                allocator.free(pairs);
            }
        }

        var cur: usize = 0;

        for (0.., extra_namespace_lens) |idx, extra_namespace_len| {
            const l: usize = @intCast(extra_namespace_len);

            if (l > extra_namespaces.len - cur) {
                // lens claim more content than the packed buffer actually holds
                return errors.ScrapliError.Journal;
            }

            pairs[idx / 2][idx % 2] = try allocator.dupe(u8, extra_namespaces[cur..][0..l]);
            strings_populated += 1;

            cur += l;
        }

        options.extra_namespaces = pairs;

        pairs_adopted = true;
    }

    const spanned_base_namespace_prefix = std.mem.span(base_namespace_prefix);
    if (spanned_base_namespace_prefix.len > 0) {
        options.base_namespace_prefix = try allocator.dupe(u8, spanned_base_namespace_prefix);
    }

    return options;
}

/// Builds GetConfigOptions from given ffi inputs.
pub fn getConfigOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    source: ?*u8,
    filter: [*c]const u8,
    filter_type: ?*u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: ?*u8,
) !operation.GetConfigOptions {
    var options = operation.GetConfigOptions{
        .cancel = cancel,
    };

    // if a later dupe fails, free whatever the options already own
    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (source) |src| {
        options.source = @fromBackingInt(@intCast(src.*));
    }

    if (filter_type) |flt| {
        options.filter_type = @fromBackingInt(@intCast(flt.*));
    }

    if (defaults_type) |dfl| {
        options.defaults_type = @fromBackingInt(@intCast(dfl.*));
    }

    const spanned_filter = std.mem.span(filter);
    if (spanned_filter.len > 0) {
        options.filter = try allocator.dupe(u8, spanned_filter);
    }

    const spanned_filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (spanned_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = try allocator.dupe(u8, spanned_filter_namespace_prefix);
    }

    const spanned_filter_namespace = std.mem.span(filter_namespace);
    if (spanned_filter_namespace.len > 0) {
        options.filter_namespace = try allocator.dupe(u8, spanned_filter_namespace);
    }

    return options;
}

/// Builds EditConfigOptions from given ffi inputs.
pub fn editConfigOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    config: [*c]const u8,
    target: ?*u8,
    default_operation: ?*u8,
    test_option: ?*u8,
    error_option: ?*u8,
) !operation.EditConfigOptions {
    var options = operation.EditConfigOptions{
        .cancel = cancel,
        .config = try allocator.dupe(u8, std.mem.span(config)),
    };

    if (target) |tgt| {
        options.target = @fromBackingInt(@intCast(tgt.*));
    }

    if (default_operation) |dfo| {
        options.default_operation = @fromBackingInt(@intCast(dfo.*));
    }

    if (test_option) |tso| {
        options.test_option = @fromBackingInt(@intCast(tso.*));
    }

    if (error_option) |ero| {
        options.error_option = @fromBackingInt(@intCast(ero.*));
    }

    return options;
}

/// Builds CopyConfigOptions from given ffi inputs.
pub fn copyConfigOptionsFromArgs(
    cancel: *bool,
    target: ?*u8,
    source: ?*u8,
) operation.CopyConfigOptions {
    var options = operation.CopyConfigOptions{
        .cancel = cancel,
    };

    if (target) |tgt| {
        options.target = @fromBackingInt(@intCast(tgt.*));
    }

    if (source) |src| {
        options.source = @fromBackingInt(@intCast(src.*));
    }

    return options;
}

/// Builds DeleteConfigOptions from given ffi inputs.
pub fn deleteConfigOptionsFromArgs(
    cancel: *bool,
    target: ?*u8,
) operation.DeleteConfigOptions {
    var options = operation.DeleteConfigOptions{
        .cancel = cancel,
    };

    if (target) |tgt| {
        options.target = @fromBackingInt(@intCast(tgt.*));
    }

    return options;
}

/// Builds LockUnlockOptions from given ffi inputs.
pub fn lockUnlockOptionsFromArgs(
    cancel: *bool,
    target: ?*u8,
) operation.LockUnlockOptions {
    var options = operation.LockUnlockOptions{
        .cancel = cancel,
    };

    if (target) |tgt| {
        options.target = @fromBackingInt(@intCast(tgt.*));
    }

    return options;
}

/// Builds GetOptions from given ffi inputs.
pub fn getOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: ?*u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: ?*u8,
) !operation.GetOptions {
    var options = operation.GetOptions{
        .cancel = cancel,
    };

    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (filter_type) |flt| {
        options.filter_type = @fromBackingInt(@intCast(flt.*));
    }

    if (defaults_type) |dfl| {
        options.defaults_type = @fromBackingInt(@intCast(dfl.*));
    }

    const spanned_filter = std.mem.span(filter);
    if (spanned_filter.len > 0) {
        options.filter = try allocator.dupe(u8, spanned_filter);
    }

    const spanned_filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (spanned_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = try allocator.dupe(u8, spanned_filter_namespace_prefix);
    }

    const spanned_filter_namespace = std.mem.span(filter_namespace);
    if (spanned_filter_namespace.len > 0) {
        options.filter_namespace = try allocator.dupe(u8, spanned_filter_namespace);
    }

    return options;
}

/// Builds ValidateOptions from given ffi inputs.
pub fn validateOptionsFromArgs(
    cancel: *bool,
    source: ?*u8,
) operation.ValidateOptions {
    var options = operation.ValidateOptions{
        .cancel = cancel,
    };

    if (source) |src| {
        options.source = @fromBackingInt(@intCast(src.*));
    }

    return options;
}

/// Builds CancelCommitOptions from given ffi inputs.
pub fn cancelCommitOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    persist_id: [*c]const u8,
) !operation.CancelCommitOptions {
    var options = operation.CancelCommitOptions{
        .cancel = cancel,
    };

    const spanned_persist_id = std.mem.span(persist_id);
    if (spanned_persist_id.len > 0) {
        options.persist_id = try allocator.dupe(u8, spanned_persist_id);
    }

    return options;
}

/// Builds GetSchemaOptions from given ffi inputs.
pub fn getSchemaOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    identifier: [*c]const u8,
    version: [*c]const u8,
    format: ?*u8,
) !operation.GetSchemaOptions {
    var options = operation.GetSchemaOptions{
        .cancel = cancel,
        .identifier = "",
    };

    // string fields are duped one at a time below; if any dupe fails this frees whatever the
    // options owns up to that point
    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    options.identifier = try allocator.dupe(u8, std.mem.span(identifier));
    options.version = try allocator.dupe(u8, std.mem.span(version));

    if (format) |fmt| {
        options.format = @fromBackingInt(@intCast(fmt.*));
    }

    return options;
}

/// Builds GetDataOptions from given ffi inputs.
pub fn getDataOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    datastore: ?*u8,
    filter: [*c]const u8,
    filter_type: ?*u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    config_filter: ?*bool,
    origin_filters: [*c]const u8,
    max_depth: u32,
    with_origin: bool,
    defaults_type: ?*u8,
) !operation.GetDataOptions {
    var options = operation.GetDataOptions{
        .cancel = cancel,
    };

    errdefer ffi_operations.freeOwnedStrings(allocator, options);

    if (datastore) |str| {
        options.datastore = @fromBackingInt(@intCast(str.*));
    }

    if (filter_type) |flt| {
        options.filter_type = @fromBackingInt(@intCast(flt.*));
    }

    if (defaults_type) |dfl| {
        options.defaults_type = @fromBackingInt(@intCast(dfl.*));
    }

    if (config_filter) |cff| {
        options.config_filter = cff.*;
    }

    if (with_origin) {
        options.with_origin = true;

        const spanned_origin_filters = std.mem.span(origin_filters);
        if (spanned_origin_filters.len > 0) {
            options.origin_filters = try allocator.dupe(u8, spanned_origin_filters);
        }
    }

    const spanned_filter = std.mem.span(filter);
    if (spanned_filter.len > 0) {
        options.filter = try allocator.dupe(u8, spanned_filter);
    }

    const spanned_filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (spanned_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = try allocator.dupe(u8, spanned_filter_namespace_prefix);
    }

    const spanned_filter_namespace = std.mem.span(filter_namespace);
    if (spanned_filter_namespace.len > 0) {
        options.filter_namespace = try allocator.dupe(u8, spanned_filter_namespace);
    }

    if (max_depth > 0) {
        options.max_depth = max_depth;
    }

    return options;
}

/// Builds EditDataOptions from given ffi inputs.
pub fn editDataOptionsFromArgs(
    allocator: std.mem.Allocator,
    cancel: *bool,
    datastore: ?*u8,
    edit_content: [*c]const u8,
    default_operation: ?*u8,
) !operation.EditDataOptions {
    var options = operation.EditDataOptions{
        .cancel = cancel,
        .edit_content = try allocator.dupe(u8, std.mem.span(edit_content)),
    };

    if (datastore) |dst| {
        options.datastore = @fromBackingInt(@intCast(dst.*));
    }

    if (default_operation) |dfo| {
        options.default_operation = @fromBackingInt(@intCast(dfo.*));
    }

    return options;
}
