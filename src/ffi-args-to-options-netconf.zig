const std = @import("std");
const operation = @import("netconf-operation.zig");

fn getDatastoreType(
    datastore_type: [*c]const u8,
    default: operation.DatastoreType,
) operation.DatastoreType {
    const _datastore_type = std.mem.span(datastore_type);

    if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.conventional),
        _datastore_type,
    )) {
        return operation.DatastoreType.conventional;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.running),
        _datastore_type,
    )) {
        return operation.DatastoreType.running;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.candidate),
        _datastore_type,
    )) {
        return operation.DatastoreType.candidate;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.startup),
        _datastore_type,
    )) {
        return operation.DatastoreType.startup;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.intended),
        _datastore_type,
    )) {
        return operation.DatastoreType.intended;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.dynamic),
        _datastore_type,
    )) {
        return operation.DatastoreType.dynamic;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DatastoreType.operational),
        _datastore_type,
    )) {
        return operation.DatastoreType.operational;
    } else {
        return default;
    }
}

fn getFilterType(filter_type: [*c]const u8) operation.FilterType {
    const _filter_type = std.mem.span(filter_type);

    if (std.mem.eql(
        u8,
        @tagName(operation.FilterType.subtree),
        _filter_type,
    )) {
        return operation.FilterType.subtree;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.FilterType.xpath),
        _filter_type,
    )) {
        return operation.FilterType.xpath;
    } else {
        return operation.FilterType.subtree;
    }
}

fn getDefaultsType(defaults_type: [*c]const u8) ?operation.DefaultsType {
    const _defaults_type = std.mem.span(defaults_type);

    if (std.mem.eql(
        u8,
        @tagName(operation.DefaultsType.explicit),
        _defaults_type,
    )) {
        return operation.DefaultsType.explicit;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DefaultsType.report_all),
        _defaults_type,
    )) {
        return operation.DefaultsType.report_all;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DefaultsType.report_all_tagged),
        _defaults_type,
    )) {
        return operation.DefaultsType.report_all_tagged;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.DefaultsType.trim),
        _defaults_type,
    )) {
        return operation.DefaultsType.trim;
    } else {
        return null;
    }
}

fn getFormat(format: [*c]const u8) operation.SchemaFormat {
    const _format = std.mem.span(format);

    if (std.mem.eql(
        u8,
        @tagName(operation.SchemaFormat.rnc),
        _format,
    )) {
        return operation.SchemaFormat.rnc;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.SchemaFormat.rng),
        _format,
    )) {
        return operation.SchemaFormat.rng;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.SchemaFormat.xsd),
        _format,
    )) {
        return operation.SchemaFormat.xsd;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.SchemaFormat.yang),
        _format,
    )) {
        return operation.SchemaFormat.yang;
    } else if (std.mem.eql(
        u8,
        @tagName(operation.SchemaFormat.yin),
        _format,
    )) {
        return operation.SchemaFormat.yin;
    } else {
        return operation.SchemaFormat.yang;
    }
}

pub fn GetConfigOptionsFromArgs(
    cancel: *bool,
    source: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) operation.GetConfigOptions {
    var options = operation.GetConfigOptions{
        .cancel = cancel,
        .source = getDatastoreType(
            source,
            operation.DatastoreType.running,
        ),
        .filter_type = getFilterType(filter_type),
        .defaults_type = getDefaultsType(defaults_type),
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn EditConfigOptionsFromArgs(
    cancel: *bool,
    config: [*c]const u8,
    target: [*c]const u8,
) operation.EditConfigOptions {
    return operation.EditConfigOptions{
        .cancel = cancel,
        .config = std.mem.span(config),
        .target = getDatastoreType(
            target,
            operation.DatastoreType.running,
        ),
    };
}

pub fn CopyConfigOptionsFromArgs(
    cancel: *bool,
    target: [*c]const u8,
    source: [*c]const u8,
) operation.CopyConfigOptions {
    return operation.CopyConfigOptions{
        .cancel = cancel,
        .target = getDatastoreType(
            target,
            operation.DatastoreType.startup,
        ),
        .source = getDatastoreType(
            source,
            operation.DatastoreType.running,
        ),
    };
}

pub fn DeleteConfigOptionsFromArgs(
    cancel: *bool,
    target: [*c]const u8,
) operation.DeleteConfigOptions {
    return operation.DeleteConfigOptions{
        .cancel = cancel,
        .target = getDatastoreType(
            target,
            operation.DatastoreType.running,
        ),
    };
}

pub fn LockUnlockOptionsFromArgs(
    cancel: *bool,
    target: [*c]const u8,
) operation.LockUnlockOptions {
    return operation.LockUnlockOptions{
        .cancel = cancel,
        .target = getDatastoreType(
            target,
            operation.DatastoreType.running,
        ),
    };
}

pub fn GetOptionsFromArgs(
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) operation.GetOptions {
    var options = operation.GetOptions{
        .cancel = cancel,
        .filter_type = getFilterType(filter_type),
        .defaults_type = getDefaultsType(defaults_type),
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn ValidateOptionsFromArgs(
    cancel: *bool,
    source: [*c]const u8,
) operation.ValidateOptions {
    return operation.ValidateOptions{
        .cancel = cancel,
        .source = getDatastoreType(
            source,
            operation.DatastoreType.running,
        ),
    };
}

pub fn CreateSubscriptionOptionsFromArgs(
    cancel: *bool,
    stream: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    start_time: u64,
    stop_time: u64,
) operation.CreateSubscriptionOptions {
    var options = operation.CreateSubscriptionOptions{
        .cancel = cancel,
        .stream = std.mem.span(stream),
        .filter_type = getFilterType(filter_type),
        .start_time = start_time,
        .stop_time = stop_time,
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn EstablishSubscriptionOptionsFromArgs(
    cancel: *bool,
    stream: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    period: u64,
    stop_time: u64,
    dscp: u8,
    weighting: u8,
    dependency: u32,
    encoding: [*c]const u8,
) operation.EstablishSubscriptionOptions {
    var options = operation.EstablishSubscriptionOptions{
        .cancel = cancel,
        .stream = std.mem.span(stream),
        .filter_type = getFilterType(filter_type),
        .period = period,
        .stop_time = stop_time,
        .dscp = dscp,
        .weighting = weighting,
        .dependency = dependency,
        .encoding = std.mem.span(encoding),
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn ModifySubscriptionOptionsFromArgs(
    cancel: *bool,
    id: u64,
    stream: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    period: u64,
    stop_time: u64,
    dscp: u8,
    weighting: u8,
    dependency: u32,
    encoding: [*c]const u8,
) operation.ModifySubscriptionOptions {
    var options = operation.ModifySubscriptionOptions{
        .cancel = cancel,
        .id = id,
        .stream = std.mem.span(stream),
        .filter_type = getFilterType(filter_type),
        .period = period,
        .stop_time = stop_time,
        .dscp = dscp,
        .weighting = weighting,
        .dependency = dependency,
        .encoding = std.mem.span(encoding),
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn GetSchemaOptionsFromArgs(
    cancel: *bool,
    identifier: [*c]const u8,
    version: [*c]const u8,
    format: [*c]const u8,
) operation.GetSchemaOptions {
    return operation.GetSchemaOptions{
        .cancel = cancel,
        .identifier = std.mem.span(identifier),
        .version = std.mem.span(version),
        .format = getFormat(format),
    };
}

pub fn GetDataOptionsFromArgs(
    cancel: *bool,
    datastore: [*c]const u8,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    config_filter: bool,
    origin_filters: [*c]const u8,
    max_depth: i32, // TODO is uint so if we pass -1 can be null
    with_origin: bool,
    defaults_type: [*c]const u8,
) operation.GetDataOptions {
    var options = operation.GetDataOptions{
        .cancel = cancel,
        .datastore = getDatastoreType(
            datastore,
            operation.DatastoreType.running,
        ),
        .filter_type = getFilterType(filter_type),
        .config_filter = config_filter,
        .origin_filters = std.mem.span(origin_filters),
        .max_depth = @intCast(max_depth),
        .with_origin = with_origin,
        .defaults_type = getDefaultsType(defaults_type),
    };

    const _filter = std.mem.span(filter);
    if (_filter.len > 0) {
        options.filter = _filter;
    }

    const _filter_namespace_prefix = std.mem.span(filter_namespace_prefix);
    if (_filter_namespace_prefix.len > 0) {
        options.filter_namespace_prefix = _filter_namespace_prefix;
    }

    const _filter_namespace = std.mem.span(filter_namespace);
    if (_filter_namespace.len > 0) {
        options.filter_namespace = _filter_namespace;
    }

    return options;
}

pub fn EditDataOptionsFromArgs(
    cancel: *bool,
    datastore: [*c]const u8,
    edit_content: [*c]const u8,
) operation.EditDataOptions {
    return operation.EditDataOptions{
        .cancel = cancel,
        .datastore = getDatastoreType(
            datastore,
            operation.DatastoreType.running,
        ),
        .edit_content = std.mem.span(edit_content),
    };
}
