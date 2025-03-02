const std = @import("std");
const driver = @import("driver.zig");
const mode = @import("mode.zig");
const result = @import("result.zig");

pub const BoundOnXCallback = struct {
    ptr: *anyopaque,
    callback: *const fn (
        p: *anyopaque,
        d: *driver.Driver,
        allocator: std.mem.Allocator,
        cancel: ?*bool,
    ) anyerror!*result.Result,
};

pub const Definition = struct {
    allocator: std.mem.Allocator,
    prompt_pattern: []const u8,
    default_mode: []const u8,
    modes: std.StringHashMap(mode.Mode),
    failure_indicators: std.ArrayList([]const u8),
    on_open_callback: ?*const fn (
        d: *driver.Driver,
        allocator: std.mem.Allocator,
        cancel: ?*bool,
    ) anyerror!*result.Result,
    bound_on_open_callback: ?BoundOnXCallback,
    on_close_callback: ?*const fn (
        d: *driver.Driver,
        allocator: std.mem.Allocator,
        cancel: ?*bool,
    ) anyerror!*result.Result,
    bound_on_close_callback: ?BoundOnXCallback,
    ntc_templates_platform: ?[]const u8,
    genie_platform: ?[]const u8,

    pub fn deinit(self: *Definition) void {
        var mode_iter = self.modes.iterator();

        while (mode_iter.next()) |m| {
            m.value_ptr.deinit();
        }

        self.modes.deinit();
        self.failure_indicators.deinit();
    }
};
