const std = @import("std");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");
const top = @import("top/process.zig");
const Users = top.Users;
const PidInfo = top.PidInfo;
const PidWatcher = top.PidWatcher;
const ProcDirScanner = top.ProcDirScanner;

const ResBufAlignment: std.mem.Alignment = .fromByteUnits(std.atomic.cache_line);
const ResBuf = std.ArrayListAligned(u8, ResBufAlignment);

const PidInfoKey = packed struct(u64) {
    _: u7 = 0,
    // pid is 22 bit big
    pid: u22,
    // max 999 * 10 + 9, 9 standalone being the float point
    mem: u14,
    // u3
    unit: PidInfo.MemRes.MemUnit,
    // max of 26213 * 10 + 9, 9 being the float point
    // that would mean we support up to 262 cores
    cpu: u18,

    pub fn from(pidInfo: *const PidInfo, pid: u32) !@This() {
        const cpu: u18 = @intFromFloat(@trunc(pidInfo.cpuPercent() * 10));
        // max number ending with 9 with 18 bits
        std.debug.assert(cpu <= 262139);
        const mem = try pidInfo.memoryTotal();
        // max 999 * 10 + 9, technically 9999 is not possible by the alg
        // but supported by the number
        const memVal: u14 = @intFromFloat(@trunc(mem.value * 10));
        std.debug.assert(memVal <= 9990);
        std.debug.assert(pid <= std.math.maxInt(u22));

        return .{
            .cpu = cpu,
            .unit = mem.unit,
            .mem = memVal,
            .pid = @intCast(pid),
        };
    }
};

pub fn run(ctx: *Ctx, grid: *Grid, term: *Terminal) !void {
    const topN = term.size.rows;

    const io = ctx.io;
    const allocator = ctx.heapAlloc;

    const path = "/proc";

    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false, .access_sub_paths = false });
    defer dir.close(io);

    var dentsBuf: [4 << 10]u8 align(@alignOf(usize)) = undefined;

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    var users = try Users.load(io, allocator);
    defer users.deinit(allocator);

    var pidMap: std.AutoHashMapUnmanaged(u32, PidWatcher) = .empty;
    try pidMap.ensureTotalCapacity(allocator, 100);

    // TODO: move to BPlusTree
    var st: regent.collections.STree(u64, void) = try .init(allocator, 4000);
    defer st.deinit(allocator);

    defer {
        var it = pidMap.iterator();
        while (it.next()) |e| e.value_ptr.deinit(io, allocator);
        pidMap.deinit(allocator);
    }

    while (Terminal.isRunning()) {
        var procDirScanner: ProcDirScanner = .init(dir, &dentsBuf);
        while (true) {
            const pid = (try procDirScanner.nextPid(io)) orelse break;
            const gop = try pidMap.getOrPut(allocator, pid);
            if (!gop.found_existing) {
                gop.value_ptr.init(dir, pid);
            }
            const watcher = gop.value_ptr;
            const prevKey: ?PidInfoKey = if (watcher.pidInfo == null)
                null
            else
                try PidInfoKey.from(&(watcher.pidInfo.?), pid);

            watcher.update(io, allocator, &buf, &users) catch continue;
            watcher.survive = true;

            const newKey = try PidInfoKey.from(&(watcher.pidInfo.?), pid);

            if (prevKey != null and prevKey.? != newKey) {
                _ = st.remove(@bitCast(prevKey.?));
            }

            _ = try st.insert(@bitCast(newKey), {});
        }

        var it = pidMap.iterator();
        while (it.next()) |e| {
            // reset for next run or nuke
            if (!e.value_ptr.survive) {
                if (e.value_ptr.pidInfo != null) {
                    const k = try PidInfoKey.from(&e.value_ptr.pidInfo.?, e.key_ptr.*);
                    std.debug.assert(st.remove(@bitCast(k)) != null);
                }

                e.value_ptr.deinit(io, allocator);
                pidMap.removeByPtr(e.key_ptr);
            } else e.value_ptr.survive = false;
        }

        var blockIt = st.blockIterator();
        var count: usize = 0;
        // TODO: handle count < topN
        const target: usize = st.count -| (topN - 1);
        var line: usize = 0;
        while (blockIt.next()) |block| {
            if (count + block.keys.len >= target) {
                for (block.keys) |key| {
                    count += 1;
                    if (count >= target) {
                        try writeLineToGrip(
                            io,
                            allocator,
                            grid,
                            topN - line - 1,
                            &pidMap.get(@as(PidInfoKey, @bitCast(key)).pid).?,
                        );
                        line += 1;
                    }
                }
            } else {
                count += block.keys.len;
                continue;
            }
        }
        std.debug.assert(count == st.count);
        std.debug.assert(line == topN);

        try grid.flush(ctx, term);

        try io.sleep(.fromSeconds(1), .awake);
    }
}

pub fn writeLineToGrip(io: std.Io, allocator: std.mem.Allocator, grid: *Grid, lineN: usize, watcher: *const PidWatcher) !void {
    const pidInfo = watcher.pidInfo.?;
    const uptime = pidInfo.uptime(io);
    const mem = try pidInfo.memoryTotal();
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\t{s}\t{d}\t{d:.1}%\t{d}:{d:0>2}:{d:0>2}\t{d}{s}\t{s}\n", .{
        watcher.pidTracker.pidAsStr(),
        pidInfo.user,
        @tagName(pidInfo.currStat.state),
        pidInfo.currStat.threads,
        pidInfo.cpuPercent(),
        uptime.h,
        uptime.m,
        uptime.s,
        mem.value,
        @tagName(mem.unit),
        pidInfo.cmd,
    });
    defer allocator.free(line);

    for (0..@min(line.len, grid.size.cols)) |x| {
        _ = try grid.put(x, lineN, .glyph, line[x]);
    }
}
