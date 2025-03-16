comptime {
    _ = @import("bytes.zig");
    _ = @import("cli.zig");
    _ = @import("ascii.zig");
    _ = @import("netconf-result.zig");
}

comptime {
    _ = @import("tests/integration/driver-tests.zig");
    _ = @import("tests/integration/driver-netconf-tests.zig");
}

comptime {
    _ = @import("tests/functional//driver-tests.zig");
    _ = @import("tests/functional/driver-netconf-tests.zig");
}
