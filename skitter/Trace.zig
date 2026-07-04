const std = @import("std");
const regent = @import("regent");

pub const Metric = union(enum) {
    draw: Duration,
    sleep: Duration,
    @"grid.buffer.size": usize,
    @"grid.full.size": usize,
    @"grid.full.serialize": Duration,
    @"grid.full.flush": Duration,
    @"grid.diff.size": usize,
    @"grid.diff.serialize": Duration,
    @"grid.diff.flush": Duration,

    pub const Duration = i96;
};

fs: regent.fs.FileStream(.write),
metrics: std.ArrayList(Metric),
timers: std.ArrayList(std.Io.Timestamp),
clock: std.Io.Clock,

// TODO: add flush period
// TODO: add limit

pub const DEFAULT_FILE_NAME: []const u8 = "metrics.log";

pub fn init(context: regent.ergo.Context) !@This() {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(context.io, DEFAULT_FILE_NAME, .{
        .read = true,
        .truncate = true,
    });
    const fs: regent.fs.FileStream(.write) = try regent.fs.FileStream(.write).openStream(context, file);

    return .{
        .fs = fs,
        .metrics = .empty,
        .timers = .empty,
        .clock = .awake,
    };
}

pub fn dump(self: *@This()) !void {
    for (self.metrics.items) |item|
        switch (item) {
            inline else => |number| try self.fs.stream.interface.print("{s},{d}\n", .{ @tagName(item), number }),
        };
    try self.fs.stream.interface.flush();
    self.metrics.clearRetainingCapacity();
}

pub fn pushTimer(self: *@This(), context: regent.ergo.Context) !void {
    try self.timers.append(context.allocator, self.clock.now(context.io));
}

pub fn popTimer(self: *@This(), context: regent.ergo.Context, comptime tag: std.meta.Tag(Metric)) !void {
    if (self.timers.pop()) |t| {
        try self.metrics.append(context.allocator, @unionInit(
            Metric,
            @tagName(tag),
            t.untilNow(context.io, self.clock).toNanoseconds(),
        ));
    }
}

pub fn deinit(self: *@This(), context: regent.ergo.Context) void {
    self.metrics.deinit(context.allocator);
    self.timers.deinit(context.allocator);
    self.fs.close(context);
    self.fs.deinit(context);
}
