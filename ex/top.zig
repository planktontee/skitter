const std = @import("std");
const builtin = @import("builtin");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");
const proc = @import("top/process.zig");
const Users = proc.Users;
const PidInfo = proc.PidInfo;
const PidTracker = proc.PidTracker;
const PidWatcher = proc.PidWatcher;
const ProcDirScanner = proc.ProcDirScanner;
const RotType = regent.ergo.RotType;
const rotValue = regent.ergo.rotValue;
const traceEnabled = @import("bopts").trace;
const pack = regent.fmt.pack;
const unpack = regent.fmt.unpack;
const assert = std.debug.assert;
const assertM = regent.ergo.assertM;
const BUnit = regent.units.ByteUnit;
const Allocator = std.mem.Allocator;
const SimpleBorder = @import("../skitter/components.zig").SimpleBorder;

const PidRankKey = packed struct(u64) {
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

    pub fn from(pid: u32, pidInfo: *const PidInfo) !@This() {
        const cpu: u18 = @intFromFloat(@trunc(pidInfo.cpuPercent * 10));
        // max number ending with 9 with 18 bits
        assert(cpu <= 262139);
        const mem = pidInfo.mem;
        // max 999 * 10 + 9, technically 9999 is not possible by the alg
        // but supported by the number
        assertM(mem.value <= 9990, r: {
            var buf: [256]u8 = undefined;
            break :r try std.fmt.bufPrint(&buf, "Unexpected memory value {d}\n", .{mem.value});
        });
        assert(pid <= std.math.maxInt(u22));

        return .{
            .cpu = cpu,
            .unit = mem.unit,
            .mem = mem.value,
            .pid = @intCast(pid),
        };
    }
};

pub const PidStartTimeRankKey = packed struct(u64) {
    pid: u22,
    // 1.3k + years worth of granularity
    startTime: u42,

    pub fn from(pid: u32, pidInfo: *const PidInfo) @This() {
        return .fromStartTime(pid, pidInfo.currStat.startTime);
    }

    pub fn fromStartTime(pid: u32, startTime: usize) @This() {
        return .{
            .pid = @intCast(pid),
            .startTime = @intCast(startTime >> 22),
        };
    }
};

pub const FileBuf = []align(std.atomic.cache_line) u8;
const log = std.log.scoped(.top);

procDir: std.Io.Dir,
dentsBuf: []align(@alignOf(usize)) u8,
fdCache: regent.collections.STree(.gt, u64, void),
ioBuf: FileBuf,
users: Users,
pidMap: std.HashMapUnmanaged(u32, PidWatcher, std.hash_map.AutoContext(u32), 99),
pidRank: regent.collections.BPlusTree(.gt, u64, void),
clock: std.Io.Clock,

const Top = @This();

pub fn init(ctx: *const Ctx) !@This() {
    const io = ctx.io;
    const allocator = ctx.heapAlloc;
    const scrapAlloc = ctx.stackAlloc;

    const dir = try std.Io.Dir.openDirAbsolute(
        io,
        "/proc",
        .{ .iterate = true, .follow_symlinks = false, .access_sub_paths = false },
    );
    errdefer dir.close(io);

    const dentsBuf = try scrapAlloc.alignedAlloc(u8, .fromByteUnits(@sizeOf(usize)), 4 * BUnit.kb);
    errdefer scrapAlloc.free(dentsBuf);

    var fdCache: @FieldType(@This(), "fdCache") = try .init(scrapAlloc, 1000);
    errdefer fdCache.deinit(scrapAlloc);

    const ioBuf: FileBuf = try scrapAlloc.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 * BUnit.kb);
    errdefer scrapAlloc.free(ioBuf);

    return .{
        .procDir = dir,
        .dentsBuf = dentsBuf,
        .fdCache = fdCache,
        .ioBuf = ioBuf,
        .users = try Users.load(io, allocator),
        .pidMap = .empty,
        .pidRank = .empty,
        .clock = .awake,
    };
}

pub fn deinit(self: *@This(), ctx: *const Ctx) void {
    const io = ctx.io;
    self.procDir.close(io);

    const scrapAlloc = ctx.stackAlloc;
    scrapAlloc.free(self.dentsBuf);
    self.fdCache.deinit(scrapAlloc);
    scrapAlloc.free(self.ioBuf);

    const allocator = ctx.heapAlloc;
    self.users.deinit(allocator);

    var it = self.pidMap.iterator();
    while (it.next()) |e| e.value_ptr.deinit(io, allocator);
    self.pidMap.deinit(allocator);

    self.pidRank.deinit(allocator);
}

fn getPrevData(watcher: *const PidWatcher, pid: u32) !struct { ?PidRankKey, ?usize } {
    return if (watcher.pidInfo == null)
        .{ null, null }
    else r: {
        const prevPidInfo = &watcher.pidInfo.?;
        break :r .{
            try PidRankKey.from(pid, prevPidInfo),
            prevPidInfo.currStat.startTime,
        };
    };
}

fn rankPid(self: *@This(), allocator: Allocator, watcher: *const PidWatcher, pid: u32, optPrevK: ?PidRankKey) !void {
    const newK = try PidRankKey.from(pid, &watcher.pidInfo.?);

    if (optPrevK != null and optPrevK.? != newK)
        assert(self.pidRank.remove(@bitCast(optPrevK.?)) != null);

    const r = try self.pidRank.insert(allocator, @bitCast(newK), {});
    assertM(r == null or (optPrevK != null and newK == optPrevK.?), r: {
        var msgBuf: [regent.fmt.decimalStrSize(u64) * 2 + 14]u8 = undefined;
        break :r try std.fmt.bufPrint(&msgBuf, "Prev: {d}, New: {d}", .{
            if (optPrevK) |prevK| pack(prevK) else @as(u64, 0),
            pack(newK),
        });
    });
}

fn lruFd(
    self: *@This(),
    io: std.Io,
    newFdK: u64,
) void {
    var fdIt = self.fdCache.iterator();
    const biggestK: PidStartTimeRankKey = @bitCast(fdIt.next().?.key);
    if (newFdK < pack(biggestK)) {
        assert(self.fdCache.remove(@bitCast(biggestK)) != null);

        const tracker: *PidTracker = &self.pidMap.getPtr(biggestK.pid).?.pidTracker;
        tracker.cacheFd = false;
        tracker.close(io);
        assert(tracker.statF == null);
    }
}

fn toggleFdCache(self: *@This(), io: std.Io, watcher: *PidWatcher, pid: u32, optPrevStartTime: ?usize) !void {
    const newFdK = PidStartTimeRankKey.from(pid, &watcher.pidInfo.?);

    var wasFdCached = false;
    if (optPrevStartTime) |prevUptime| {
        const oldFdK = PidStartTimeRankKey.fromStartTime(pid, prevUptime);

        // no need to rebalance existing pids if it's in the cache
        if (oldFdK == newFdK and self.fdCache.contains(pack(newFdK))) return;

        if (self.fdCache.remove(@bitCast(oldFdK)) != null) {
            if (traceEnabled) {
                const tracker: *PidTracker = &self.pidMap.getPtr(oldFdK.pid).?.pidTracker;
                assert(tracker.cacheFd == true);
            }
            wasFdCached = true;
        }
    }

    if (!wasFdCached and self.fdCache.isSaturated())
        self.lruFd(io, @bitCast(newFdK))
    else {
        // we removed a previously cached entry, we can insert this one, it will be replaced in subsequent runs
        watcher.pidTracker.cacheFd = true;
        assert((try self.fdCache.insert(@bitCast(newFdK), {})) == null);
    }
}

pub fn sweepPids(self: *@This(), io: std.Io, allocator: Allocator, term: *Terminal) !void {
    var delta: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, undefined);
    var elpPidSweep: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, std.Io.Timestamp.zero);
    var elpRank: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, std.Io.Timestamp.zero);
    var elpFdCache: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, std.Io.Timestamp.zero);

    var procDirScanner: ProcDirScanner = .init(self.procDir, self.dentsBuf);
    while (Terminal.isRunning()) {
        if (traceEnabled) delta = self.clock.now(io);
        const pid = (try procDirScanner.nextPid(io)) orelse break;

        const gopR = try self.pidMap.getOrPut(allocator, pid);
        if (!gopR.found_existing) gopR.value_ptr.init(self.procDir, pid);

        const watcher = gopR.value_ptr;
        const optPrevK: ?PidRankKey, const optPrevStartTime: ?usize = try getPrevData(watcher, pid);

        _ = watcher.update(io, allocator, self.ioBuf, &self.users) catch |e| {
            watcher.survive = false;
            log.debug("{d}, Failed to load pid information - {s}", .{ pid, @errorName(e) });
            continue;
        };
        watcher.survive = true;
        if (traceEnabled) elpPidSweep = elpPidSweep.addDuration(delta.untilNow(io, self.clock));

        if (traceEnabled) delta = self.clock.now(io);
        try self.rankPid(allocator, watcher, pid, optPrevK);
        if (traceEnabled) elpRank = elpRank.addDuration(delta.untilNow(io, self.clock));

        if (traceEnabled) delta = self.clock.now(io);
        try self.toggleFdCache(io, watcher, pid, optPrevStartTime);
        if (traceEnabled) elpFdCache = elpFdCache.addDuration(delta.untilNow(io, self.clock));
    }

    if (traceEnabled) {
        try term.trace.addMetric(.{ .@"top.pid.sweep" = elpPidSweep.nanoseconds });
        try term.trace.addMetric(.{ .@"top.rank" = elpRank.nanoseconds });
        try term.trace.addMetric(.{ .@"top.fdCache" = elpFdCache.nanoseconds });
    }
}

pub fn updateCaches(self: *@This(), io: std.Io, allocator: Allocator, term: *Terminal) !void {
    if (traceEnabled) try term.trace.pushTimer(io);

    var it = self.pidMap.iterator();
    while (it.next()) |e| {
        // reset for next run or nuke
        if (!e.value_ptr.survive) {
            if (e.value_ptr.pidInfo != null) {
                const pid = e.key_ptr.*;
                const pidInfo = &e.value_ptr.pidInfo.?;
                const k = try PidRankKey.from(pid, pidInfo);
                const fdK = PidStartTimeRankKey.from(pid, pidInfo);
                assert(self.pidRank.remove(@bitCast(k)) != null);
                _ = self.fdCache.remove(@bitCast(fdK));
            }

            e.value_ptr.deinit(io, allocator);
            self.pidMap.removeByPtr(e.key_ptr);
        } else e.value_ptr.survive = false;
    }
    assert(self.pidMap.size == self.pidRank.size);
    assert(@min(self.pidMap.size, self.fdCache.capacity) == self.fdCache.size);

    if (traceEnabled) {
        try term.trace.popTimer(io, .@"top.col.maint");
        try term.trace.addMetric(.{ .@"top.fd.size" = self.fdCache.size });
        try term.trace.addMetric(.{ .@"top.map.size" = self.pidMap.size });
        try term.trace.addMetric(.{ .@"top.rank.size" = self.pidRank.size });
    }
}

pub fn writeLineToGrid(allocator: std.mem.Allocator, grid: *Grid, lineN: usize, watcher: *const PidWatcher) !void {
    if (lineN == grid.size.rows - 1) return;

    var l = lineN;
    const sborder: SimpleBorder = .{
        .topLeftCorner = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '+' } },
        },
        .topRightCorner = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '+' } },
        },
        .bottomLeftCorner = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '+' } },
        },
        .bottomRightCorner = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '+' } },
        },
        .horizontal = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '-' } },
        },
        .vertical = .{
            .mode = .glyph,
            .data = .{ .glyph = .{ .char = '|' } },
        },
    };

    if (l == 0) {
        try sborder.drawTop(grid, 0, l, grid.size.cols);
        l += 1;
    } else l += 1;

    if (l == grid.size.rows - 1) {
        try sborder.drawBottom(grid, 0, l, grid.size.cols);
        return;
    }

    // TODO: make table
    const pidInfo = watcher.pidInfo.?;
    const uptime = pidInfo.uptime;
    const mem = pidInfo.mem;
    const line = try std.fmt.allocPrint(allocator, " {d}\t{s}\t{s}\t{s}\t{d}\t{d:.1}%\t{d}:{d:0>2}:{d:0>2}\t{d}{s}\t{s} \n", .{
        l,
        watcher.pidTracker.pidAsStr(),
        pidInfo.user,
        @tagName(pidInfo.currStat.state),
        pidInfo.currStat.threads,
        pidInfo.cpuPercent,
        uptime.h,
        uptime.m,
        uptime.s,
        // this is fine for now
        @as(f32, @floatFromInt(mem.value)) / 10,
        @tagName(mem.unit),
        pidInfo.cmd,
    });
    defer allocator.free(line);

    _ = try grid.putCell(0, l, &sborder.vertical);
    for (1..@min(line.len + 1, grid.size.cols - 1)) |x| {
        _ = try grid.put(x, l, .glyph, line[x - 1]);
    }
    _ = try grid.putCell(grid.size.cols - 1, l, &sborder.vertical);
}

pub fn drawTopN(self: *@This(), io: std.Io, allocator: Allocator, grid: *Grid, term: *Terminal) !void {
    const topN = term.size.rows;

    var delta: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, undefined);
    var elpTopN: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, std.Io.Timestamp.zero);
    var elpDraw: RotType(traceEnabled, std.Io.Timestamp) = rotValue(traceEnabled, std.Io.Timestamp.zero);
    if (traceEnabled) delta = self.clock.now(io);

    var blockIt = self.pidRank.blockIterator();
    var remaining: usize = topN;
    while (blockIt.next()) |block| {
        const target = @min(remaining, block.keys.len);
        for (block.keys[0..target], 0..) |packedK, i| {
            const key = unpack(PidRankKey, packedK);
            if (traceEnabled) elpTopN = elpTopN.addDuration(delta.untilNow(io, self.clock));

            if (traceEnabled) delta = self.clock.now(io);
            try writeLineToGrid(allocator, grid, topN - remaining + i, self.pidMap.getPtr(key.pid).?);
            if (traceEnabled) {
                elpDraw = elpDraw.addDuration(delta.untilNow(io, self.clock));
                delta = self.clock.now(io);
            }
        }

        remaining -= target;
        if (remaining == 0) break;
    }

    if (traceEnabled) {
        elpTopN = elpTopN.addDuration(delta.untilNow(io, self.clock));
        try term.trace.addMetric(.{ .@"top.top.n" = elpTopN.nanoseconds });
        try term.trace.addMetric(.{ .draw = elpDraw.nanoseconds });
    }
}

pub fn run(ctx: *const Ctx, grid: *Grid, term: *Terminal) !void {
    var top: Top = try .init(ctx);
    defer top.deinit(ctx);

    const io = ctx.io;
    const allocator = ctx.heapAlloc;

    while (Terminal.isRunning()) {
        try term.trace.pushTimer(io);

        // xx ms
        try top.sweepPids(io, allocator, term);
        if (!Terminal.isRunning()) {
            @branchHint(.cold);
            break;
        }

        // xxx micros
        try top.updateCaches(io, allocator, term);
        if (!Terminal.isRunning()) {
            @branchHint(.cold);
            break;
        }

        // xxx micros to x ms
        try top.drawTopN(io, allocator, grid, term);
        if (!Terminal.isRunning()) {
            @branchHint(.cold);
            break;
        }

        if (traceEnabled) try term.trace.popTimer(io, .loop);

        // xxx micros
        try grid.flush(ctx, term);
        if (!Terminal.isRunning()) {
            @branchHint(.cold);
            break;
        }

        try io.sleep(.fromSeconds(2), top.clock);
    }
}
