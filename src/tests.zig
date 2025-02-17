comptime {
    _ = @import("bytes.zig");
    _ = @import("driver.zig");
    _ = @import("ascii.zig");
    _ = @import("result-netconf.zig");
}

comptime {
    _ = @import("tests/integration/driver-tests.zig");
    _ = @import("tests/integration/driver-netconf-tests.zig");
}

comptime {
    _ = @import("tests/functional//driver-tests.zig");
    _ = @import("tests/functional/driver-netconf-tests.zig");
}
