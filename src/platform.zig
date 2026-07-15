const std = @import("std");

pub fn auto_worker_count() u16 {
    return cap_worker_count(
        std.Thread.getCpuCount() catch 1,
    );
}

fn cap_worker_count(count: usize) u16 {
    return @intCast(@max(
        @min(count, std.math.maxInt(u16)),
        1,
    ));
}

test "worker count is always usable" {
    try std.testing.expect(auto_worker_count() > 0);
    try std.testing.expect(
        auto_worker_count() <= (std.Thread.getCpuCount() catch 1),
    );
}
