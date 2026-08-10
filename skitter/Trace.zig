const std = @import("std");
const regent = @import("regent");
const RotType = regent.ergo.RotType;
// const isDebug = regent.ergo.isDebug;
const BUnit = regent.units.ByteUnit;

const isDebug = regent.ergo.isDebug;
pub const Metric = union(enum) {
    draw: Duration,
    sleep: Duration,
    loop: Duration,
    @"grid.size": usize,
    @"grid.upload": usize,
    @"grid.serialize": Duration,
    @"grid.flush": Duration,
    @"top.pid.sweep": Duration,
    @"top.col.maint": Duration,
    @"top.rank": Duration,
    @"top.fdCache": Duration,
    @"top.top.n": Duration,
    @"top.fd.size": usize,
    @"top.rank.size": usize,
    @"top.map.size": usize,

    pub const Duration = i96;
};

fs: RotType(isDebug, regent.fs.FileStream(.write)),
metricsI: RotType(isDebug, usize),
metrics: RotType(isDebug, []Metric),
timersI: RotType(isDebug, usize),
timers: RotType(isDebug, []std.Io.Timestamp),
clock: RotType(isDebug, std.Io.Clock),

pub const DEFAULT_FILE_NAME: []const u8 = "metrics.log";

pub fn init(context: regent.ergo.Context, metrics: usize, timers: usize) !@This() {
    if (!isDebug) return undefined;

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(context.io, DEFAULT_FILE_NAME, .{
        .read = true,
        .truncate = true,
    });

    return .{
        .fs = try regent.fs.FileStream(.write).openStreamWithConfig(
            context,
            file,
            .{},
            .byte,
            .initSame(64 * BUnit.kb),
            null,
        ),
        .metricsI = 0,
        .metrics = try context.allocator.alloc(Metric, metrics),
        .timersI = 0,
        .timers = try context.allocator.alloc(std.Io.Timestamp, timers),
        .clock = .awake,
    };
}

pub fn dump(self: *@This()) !void {
    if (!isDebug) return;

    for (self.metrics) |metric|
        switch (metric) {
            inline else => |value| try self.fs.stream.interface.print("{s},{d}\n", .{ @tagName(metric), value }),
        };
    try self.fs.stream.interface.flush();
    self.metricsI = 0;
}

pub fn addMetric(self: *@This(), metric: Metric) !void {
    if (!isDebug) return;

    if (self.metricsI >= self.metrics.len) {
        try self.dump();
    }

    self.metrics[self.metricsI] = metric;
    self.metricsI += 1;
}

pub fn pushTimer(self: *@This(), io: std.Io) !void {
    if (!isDebug) return;

    if (self.timersI + 1 >= self.timers.len) return error.TimersCapacityFull;

    self.timers[self.timersI] = self.clock.now(io);
    self.timersI += 1;
}

pub fn popTimer(self: *@This(), io: std.Io, comptime tag: std.meta.Tag(Metric)) !void {
    if (!isDebug) return;

    if (self.timersI == 0) return;

    const t = self.timers[self.timersI - 1];
    self.timersI -= 1;
    try self.addMetric(@unionInit(
        Metric,
        @tagName(tag),
        t.untilNow(io, self.clock).toNanoseconds(),
    ));
}

pub fn deinit(self: *@This(), context: regent.ergo.Context) void {
    if (!isDebug) return;

    context.allocator.free(self.metrics);
    context.allocator.free(self.timers);
    self.fs.close(context);
    self.fs.deinit(context);
}
