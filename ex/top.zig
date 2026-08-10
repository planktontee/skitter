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
// const isDebug = regent.ergo.isDebug;
const pack = regent.fmt.pack;
const unpack = regent.fmt.unpack;
const assert = std.debug.assert;
const assertM = regent.ergo.assertM;
const BUnit = regent.units.ByteUnit;
const Allocator = std.mem.Allocator;

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
        const memVal: u14 = @intFromFloat(@trunc(mem.value * 10));
        assert(memVal <= 9990);
        assert(pid <= std.math.maxInt(u22));

        return .{
            .cpu = cpu,
            .unit = mem.unit,
            .mem = memVal,
            .pid = @intCast(pid),
        };
    }
};

pub const PidUptimeRankKey = packed struct(u64) {
    pid: u22,
    // highest 4 bits
    s: u4,
    m: u6,
    h: u32,

    pub fn from(pid: u32, pidInfo: *const PidInfo) @This() {
        return .fromUptime(pid, pidInfo.uptime);
    }

    pub fn fromUptime(pid: u32, uptime: proc.PidInfo.Uptime) @This() {
        return .{
            .pid = @intCast(pid),
            .s = @intCast((uptime.s & 0b111100) >> 2),
            .m = uptime.m,
            .h = uptime.h,
        };
    }
};

pub const ResBufAlignment: std.mem.Alignment = .fromByteUnits(std.atomic.cache_line);
pub const ResBuf = std.ArrayListAligned(u8, ResBufAlignment);
const log = std.log.scoped(.top);
const isDebug = regent.ergo.isDebug;

procDir: std.Io.Dir,
dentsBuf: []align(@alignOf(usize)) u8,
fdCache: regent.collections.STree(.lt, u64, void),
ioBuf: ResBuf,
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

    var ioBuf: ResBuf = try .initCapacity(allocator, 4 * BUnit.kb);
    errdefer ioBuf.deinit(allocator);

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

    const allocator = ctx.heapAlloc;
    self.ioBuf.deinit(allocator);
    self.users.deinit(allocator);

    var it = self.pidMap.iterator();
    while (it.next()) |e| e.value_ptr.deinit(io, allocator);
    self.pidMap.deinit(allocator);

    self.pidRank.deinit(allocator);
}

fn getPrevData(watcher: *const PidWatcher, pid: u32) !struct { ?PidRankKey, ?proc.PidInfo.Uptime } {
    return if (watcher.pidInfo == null)
        .{ null, null }
    else r: {
        const prevPidInfo = &watcher.pidInfo.?;
        break :r .{
            try PidRankKey.from(pid, prevPidInfo),
            prevPidInfo.uptime,
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
    const smallestK: PidUptimeRankKey = @bitCast(fdIt.next().?.key);
    if (newFdK > pack(smallestK)) {
        assert(self.fdCache.remove(@bitCast(smallestK)) != null);

        const tracker: *PidTracker = &self.pidMap.getPtr(smallestK.pid).?.pidTracker;
        tracker.cacheFd = false;
        tracker.close(io);
        assert(tracker.statF == null);
    }
}

fn toggleFdCache(self: *@This(), io: std.Io, watcher: *PidWatcher, pid: u32, optPrevUptime: ?proc.PidInfo.Uptime) !void {
    var wasFdCached = false;
    if (optPrevUptime) |prevUptime| {
        const oldFdK = PidUptimeRankKey.fromUptime(pid, prevUptime);

        if (self.fdCache.remove(@bitCast(oldFdK)) != null) {
            if (isDebug) {
                const tracker: *PidTracker = &self.pidMap.getPtr(oldFdK.pid).?.pidTracker;
                assert(tracker.cacheFd == true);
            }
            wasFdCached = true;
        }
    }

    const newFdK = PidUptimeRankKey.from(pid, &watcher.pidInfo.?);
    if (!wasFdCached and self.fdCache.isSaturated())
        self.lruFd(io, @bitCast(newFdK))
    else {
        watcher.pidTracker.cacheFd = true;
        assert((try self.fdCache.insert(@bitCast(newFdK), {})) == null);
    }
}

pub fn sweepPids(self: *@This(), io: std.Io, allocator: Allocator, term: *Terminal) !void {
    var delta: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, undefined);
    var elpPidSweep: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, std.Io.Timestamp.zero);
    var elpRank: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, std.Io.Timestamp.zero);
    var elpFdCache: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, std.Io.Timestamp.zero);

    var procDirScanner: ProcDirScanner = .init(self.procDir, self.dentsBuf);
    while (Terminal.isRunning()) {
        if (isDebug) delta = self.clock.now(io);
        const pid = (try procDirScanner.nextPid(io)) orelse break;

        const gopR = try self.pidMap.getOrPut(allocator, pid);
        if (!gopR.found_existing) gopR.value_ptr.init(self.procDir, pid);

        const watcher = gopR.value_ptr;
        const optPrevK: ?PidRankKey, const optPrevUptime: ?proc.PidInfo.Uptime = try getPrevData(watcher, pid);

        _ = watcher.update(io, allocator, &self.ioBuf, &self.users) catch |e| {
            watcher.survive = false;
            log.debug("{d}, Failed to load pid information - {s}", .{ pid, @errorName(e) });
            continue;
        };
        watcher.survive = true;
        if (isDebug) elpPidSweep = elpPidSweep.addDuration(delta.untilNow(io, self.clock));

        if (isDebug) delta = self.clock.now(io);
        try self.rankPid(allocator, watcher, pid, optPrevK);
        if (isDebug) elpRank = elpRank.addDuration(delta.untilNow(io, self.clock));

        if (isDebug) delta = self.clock.now(io);
        try self.toggleFdCache(io, watcher, pid, optPrevUptime);
        if (isDebug) elpFdCache = elpFdCache.addDuration(delta.untilNow(io, self.clock));
    }

    if (isDebug) {
        try term.trace.addMetric(.{ .@"top.pid.sweep" = elpPidSweep.nanoseconds });
        try term.trace.addMetric(.{ .@"top.rank" = elpRank.nanoseconds });
        try term.trace.addMetric(.{ .@"top.fdCache" = elpFdCache.nanoseconds });
    }
}

pub fn updateCaches(self: *@This(), io: std.Io, allocator: Allocator, term: *Terminal) !void {
    if (isDebug) try term.trace.pushTimer(io);

    var it = self.pidMap.iterator();
    while (it.next()) |e| {
        // reset for next run or nuke
        if (!e.value_ptr.survive) {
            if (e.value_ptr.pidInfo != null) {
                const pid = e.key_ptr.*;
                const pidInfo = &e.value_ptr.pidInfo.?;
                const k = try PidRankKey.from(pid, pidInfo);
                const fdK = PidUptimeRankKey.from(pid, pidInfo);
                assert(self.pidRank.remove(@bitCast(k)) != null);
                _ = self.fdCache.remove(@bitCast(fdK));
            }

            e.value_ptr.deinit(io, allocator);
            self.pidMap.removeByPtr(e.key_ptr);
        } else e.value_ptr.survive = false;
    }
    assert(self.pidMap.size == self.pidRank.size);
    assert(@min(self.pidMap.size, self.fdCache.capacity) == self.fdCache.size);

    if (isDebug) {
        try term.trace.popTimer(io, .@"top.col.maint");
        try term.trace.addMetric(.{ .@"top.fd.size" = self.fdCache.size });
        try term.trace.addMetric(.{ .@"top.map.size" = self.pidMap.size });
        try term.trace.addMetric(.{ .@"top.rank.size" = self.pidRank.size });
    }
}

pub fn writeLineToGrid(allocator: std.mem.Allocator, grid: *Grid, lineN: usize, watcher: *const PidWatcher) !void {
    // TODO: make table
    const pidInfo = watcher.pidInfo.?;
    const uptime = pidInfo.uptime;
    const mem = pidInfo.mem;
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\t{s}\t{d}\t{d:.1}%\t{d}:{d:0>2}:{d:0>2}\t{d}{s}\t{s}\n", .{
        watcher.pidTracker.pidAsStr(),
        pidInfo.user,
        @tagName(pidInfo.currStat.state),
        pidInfo.currStat.threads,
        pidInfo.cpuPercent,
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

pub fn drawTopN(self: *@This(), io: std.Io, allocator: Allocator, grid: *Grid, term: *Terminal) !void {
    const topN = term.size.rows;

    var delta: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, undefined);
    var elpTopN: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, std.Io.Timestamp.zero);
    var elpDraw: RotType(isDebug, std.Io.Timestamp) = rotValue(isDebug, std.Io.Timestamp.zero);
    if (isDebug) delta = self.clock.now(io);

    var blockIt = self.pidRank.blockIterator();
    var remaining: usize = topN;
    while (blockIt.next()) |block| {
        const target = @min(remaining, block.keys.len);
        for (block.keys[0..target], 0..) |packedK, i| {
            const key = unpack(PidRankKey, packedK);
            if (isDebug) elpTopN = elpTopN.addDuration(delta.untilNow(io, self.clock));

            if (isDebug) delta = self.clock.now(io);
            try writeLineToGrid(allocator, grid, topN - remaining + i, self.pidMap.getPtr(key.pid).?);
            if (isDebug) {
                elpDraw = elpDraw.addDuration(delta.untilNow(io, self.clock));
                delta = self.clock.now(io);
            }
        }

        remaining -= target;
        if (remaining == 0) break;
    }

    if (isDebug) {
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

        if (isDebug) try term.trace.popTimer(io, .loop);

        // xxx micros
        try grid.flush(ctx, term);
        if (!Terminal.isRunning()) {
            @branchHint(.cold);
            break;
        }

        try io.sleep(.fromSeconds(2), top.clock);
    }
}
