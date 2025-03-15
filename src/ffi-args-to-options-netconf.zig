const std = @import("std");
const operation = @import("operation-netconf.zig");

fn getFilterType(filter_type: [*c]const u8) operation.FilterType {
    const _filter_type = std.mem.span(filter_type);

    if (std.mem.eql(u8, @tagName(operation.FilterType.subtree), _filter_type)) {
        return operation.FilterType.subtree;
    } else if (std.mem.eql(u8, @tagName(operation.FilterType.xpath), _filter_type)) {
        return operation.FilterType.xpath;
    } else {
        return operation.FilterType.subtree;
    }
}

fn getDefaultsType(defaults_type: [*c]const u8) ?operation.DefaultsType {
    const _defaults_type = std.mem.span(defaults_type);

    if (std.mem.eql(u8, @tagName(operation.DefaultsType.explicit), _defaults_type)) {
        return operation.DefaultsType.explicit;
    } else if (std.mem.eql(u8, @tagName(operation.DefaultsType.report_all), _defaults_type)) {
        return operation.DefaultsType.report_all;
    } else if (std.mem.eql(u8, @tagName(operation.DefaultsType.report_all_tagged), _defaults_type)) {
        return operation.DefaultsType.report_all_tagged;
    } else if (std.mem.eql(u8, @tagName(operation.DefaultsType.trim), _defaults_type)) {
        return operation.DefaultsType.trim;
    } else {
        return null;
    }
}

pub fn GetConfigOptionsFromArgs(
    cancel: *bool,
    filter: [*c]const u8,
    filter_type: [*c]const u8,
    filter_namespace_prefix: [*c]const u8,
    filter_namespace: [*c]const u8,
    defaults_type: [*c]const u8,
) operation.GetConfigOptions {
    var options = operation.GetConfigOptions{
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
