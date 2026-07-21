const std = @import("std");
const regent = @import("regent");
const FileCursor = regent.fs.FileCursor;
const FileCursorConfig = regent.fs.FileCursorConfig;
const PolicyEntry = FileCursorConfig.PolicyEntry;

pid: u32,
user: []const u8,
program: []const u8,
command: []const u8,
threads: u32,
cpu: f16,
memory: usize,

pub fn fromFile() @This() {}

pub const StatsPolicy = struct {
    pub fn open(_: *anyopaque, entry: PolicyEntry) bool {
        return switch (entry) {
            .stderr, .stdout, .stdin => false,
            .preWalkerEntry => false,
            .entry => |pEntry| r: {
                // this assumes enter handles the fact that we should only enter /proc and /proc/{digits}
                // I could lower the 2nd comparison, but we have SIMD :)
                if (std.mem.eql(u8, pEntry.basename, "stat") or
                    std.mem.eql(u8, pEntry.basename, "status") or
                    std.mem.eql(u8, pEntry.basename, "comm") or
                    std.mem.eql(u8, pEntry.basename, "cmdline"))
                    break :r true
                else
                    break :r false;
            },
        };
    }

    pub fn enter(_: *anyopaque, entry: PolicyEntry) bool {
        return switch (entry) {
            .stderr, .stdout, .stdin => false,
            .preWalkerEntry => |pEntry| std.mem.eql(u8, pEntry.path, "/proc"),
            // This is not re-checking the stub and this is fine for this driver
            .entry => |pEntry| regent.str.isNumber(pEntry.basename),
        };
    }
};

test "parse stat" {
    var fc: FileCursor(.read) = .initWithConfig(&.{"/proc"}, .{
        .policy = .{
            .data = @ptrCast(@constCast(&StatsPolicy{})),
            .interface = &.{
                .open = &StatsPolicy.open,
                .enter = &StatsPolicy.enter,
            },
        },
    });
    defer fc.deinit();

    const ctx: regent.ergo.Context = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    };

    const alignment: std.mem.Alignment = comptime .fromByteUnits(std.heap.page_size_min);
    var arr: std.ArrayListAlignedUnmanaged(u8, alignment) = try .initCapacity(ctx.allocator, 5);
    defer arr.deinit(ctx.allocator);

    while (true) {
        var fstream = fc.nextWithConfig(
            ctx,
            .{ .followSymlink = false },
            .unmanaged,
            .defaultReaderConfig,
        ) catch continue orelse break;
        defer fstream.close(ctx);

        fstream.setBuffer(alignment, arr.allocatedSlice());

        const path = fc.currentPath().?;
        const content = try fstream.readFileRetained(ctx.allocator, &arr);

        // TODO: parse files
        if (std.mem.endsWith(u8, path, "/stat")) {} else if (std.mem.endsWith(u8, path, "/status")) {} else if (std.mem.endsWith(u8, path, "/comm")) {} else if (std.mem.endsWith(u8, path, "/cmdline")) {} else unreachable;

        std.debug.print("{s}\n", .{content});
    }
}
