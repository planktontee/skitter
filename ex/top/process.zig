const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const regent = @import("regent");
const Context = regent.ergo.Context;
const FileCursor = regent.fs.FileCursor;
const FileCursorConfig = regent.fs.FileCursorConfig;
const PolicyEntry = FileCursorConfig.PolicyEntry;
const top = @import("../top.zig");
const FileBuf = top.FileBuf;
const unpack = regent.fmt.unpack;
const pack = regent.fmt.pack;

const log = std.log.scoped(.process);

pub const Users = struct {
    buf: []u8,
    alignment: std.mem.Alignment,
    uidMap: std.HashMapUnmanaged(u32, []const u8, std.hash_map.AutoContext(u32), 99),
    missMap: std.HashMapUnmanaged(u32, []const u8, std.hash_map.AutoContext(u32), 99) = .empty,

    pub const PASSWD_PATH = "/etc/passwd";

    // TODO: inotify to reload users

    pub fn load(io: std.Io, allocator: Allocator) !Users {
        const passwdF = try std.Io.Dir.openFileAbsolute(io, PASSWD_PATH, .{ .mode = .read_only });
        defer passwdF.close(io);

        const context: Context = .{ .io = io, .allocator = allocator };
        var fs = try regent.fs.FileStream(.read).openStreamWithConfig(
            context,
            passwdF,
            .{},
            .full,
            .defaultReaderConfig,
            null,
        );
        std.debug.assert(fs.bufferType == .full);
        errdefer fs.deinit(.{ .io = io, .allocator = allocator });

        const content = try fs.readOnceAll();
        const entryCount = std.mem.countScalar(u8, content, '\n');

        var uidMap: @FieldType(@This(), "uidMap") = .empty;
        try uidMap.ensureTotalCapacity(allocator, std.math.cast(u32, entryCount) orelse std.math.maxInt(u32));
        errdefer uidMap.deinit(allocator);

        var lines = std.mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // user:pass:uid:...
            var column = std.mem.tokenizeScalar(u8, line, ':');
            const user = column.next() orelse continue;
            _ = column.next() orelse continue;
            const uid: u32 = std.fmt.parseInt(u32, (column.next() orelse continue), 10) catch continue;

            uidMap.putAssumeCapacity(uid, user);
        }

        return .{
            .buf = fs.stream.interface.buffer,
            .alignment = fs.alignment,
            .uidMap = uidMap,
        };
    }

    pub fn get(self: *@This(), allocator: Allocator, uid: u32) ![]const u8 {
        return self.uidMap.get(uid) orelse {
            return self.missMap.get(uid) orelse {
                const missUid = try std.fmt.allocPrint(allocator, "{d}", .{uid});
                try self.missMap.put(allocator, uid, missUid);
                return missUid;
            };
        };
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        var values = self.missMap.valueIterator();
        while (values.next()) |v| {
            allocator.free(v.*);
        }
        self.missMap.deinit(allocator);
        self.uidMap.deinit(allocator);
        regent.mem.freeAligned(allocator, self.alignment, self.buf);
    }
};

pub const ProcDirScanner = struct {
    procDir: std.Io.Dir,
    dirR: std.Io.Dir.Reader,

    pub fn init(dir: std.Io.Dir, buf: []align(@alignOf(usize)) u8) @This() {
        return .{
            .procDir = dir,
            .dirR = std.Io.Dir.Reader.init(dir, buf),
        };
    }

    pub fn nextPid(self: *@This(), io: std.Io) !?u32 {
        while (true) {
            const e = (try self.dirR.next(io)) orelse return null;
            return std.fmt.parseInt(u32, e.name, 10) catch continue;
        }
    }
};

pub const StatInfo = struct {
    state: State,
    utime: usize,
    stime: usize,
    threads: u32,
    startTime: usize,
    rss: usize,
    timeInMillis: i64,

    pub const State = enum {
        // Running
        R,
        // Sleeping
        S,
        // waitning on uninterruptable disk sleep
        D,
        // zombie
        Z,
        // stopped (on signal)
        T,
        // tracing stop
        t,
        // paging (linux < 2.6.0)
        W,
        // Dead (linux >= 2.60)
        X,
        // Dead (linux >= 2.6.33 to 3.13)
        x,
        // WakeKill (linux >= 2.6.33 to 3.13)
        K,
        // Parked (linux >= 3.9 to 3.13)
        P,
        // Idle (Linux 4.14)
        I,

        pub fn from(state: u8) ?@This() {
            return std.meta.stringToEnum(@This(), &.{state});
        }
    };
};

pub const PidTracker = struct {
    dir: std.Io.Dir,
    // cmdline is the biggest one, we start fro /proc, not having /proc and open absolute is because
    // we already have to scan /proc anyway and we can leverage the dir as a testing mechanism
    // this is not thread safe obviously
    // Tis is 18 len essentially
    pathBuf: [regent.fmt.decimalStrSize(u32) + PidFile.status.toStr().len + 1]u8,
    pidEnd: u8,

    // This avoid syscalls for long-running pids
    cacheFd: bool = true,
    statF: ?std.Io.File,

    pub const PidFile = enum {
        stat,
        cmdline,
        comm,
        status,

        pub fn toStr(self: @This()) []const u8 {
            return @tagName(self);
        }
    };

    pub fn init(dir: std.Io.Dir, pid: u32) @This() {
        var self: @This() = undefined;
        self.dir = dir;
        self.statF = null;

        const n = std.fmt.printInt(&self.pathBuf, pid, 10, .lower, .{});
        std.debug.assert(self.pathBuf.len > n + 1);
        self.pathBuf[n] = '/';
        self.pidEnd = @intCast(n + 1);

        return self;
    }

    pub fn close(self: *@This(), io: std.Io) void {
        if (self.statF) |f| {
            f.close(io);
            self.statF = null;
        }
    }

    pub fn pidAsStr(self: *const @This()) []const u8 {
        return self.pathBuf[0 .. self.pidEnd - 1];
    }

    fn makePidPath(self: *@This(), name: []const u8) []const u8 {
        const pEnd: usize = @intCast(self.pidEnd);
        const remainder: []u8 = self.pathBuf[pEnd..];
        @memcpy(remainder[0..name.len], name);
        std.debug.assert(std.mem.eql(u8, self.pathBuf[pEnd .. pEnd + name.len], name));
        return self.pathBuf[0 .. pEnd + name.len];
    }

    fn openFile(self: *@This(), io: std.Io, fileTag: PidFile) !std.Io.File {
        const fName = switch (fileTag) {
            .stat => r: {
                if (self.statF) |f| return f;
                break :r @tagName(fileTag);
            },
            .cmdline, .comm, .status => @tagName(fileTag),
        };

        const f = try self.dir.openFile(io, self.makePidPath(fName), .{ .mode = .read_only });
        return f;
    }

    fn pidFile(self: *@This(), io: std.Io, buf: FileBuf, fileTag: PidFile) ![]const u8 {
        const f = try self.openFile(io, fileTag);
        defer switch (fileTag) {
            .stat => {
                if (self.cacheFd) self.statF = f else f.close(io);
            },
            .cmdline, .comm, .status => f.close(io),
        };

        var fR = f.reader(io, buf);
        const r = &fR.interface;
        return try regent.fs.readOnceAll(r);
    }

    pub fn statInfo(self: *@This(), io: std.Io, buf: FileBuf) !StatInfo {
        // We are using millis because we need to multiply all tick unis by 1000 (10 * 100 for percent)
        // USER_HZ is historically 0.01 seconds
        const timeInMillis = std.Io.Clock.awake.now(io).toMilliseconds();
        const content = try self.pidFile(io, buf, .stat);

        var remainder = content;
        // \d+ ...
        const nameStart = std.mem.indexOfScalar(u8, remainder, ' ') orelse return error.BadStatFile;
        if (nameStart + 1 >= content.len) return error.BadStatFile;
        remainder = remainder[nameStart + 1 ..];
        // (<[16]u8>)
        const nameEnd = std.mem.lastIndexOfScalar(u8, remainder, ')') orelse return error.BadStatFile;
        // skip space too
        if (nameEnd + 2 >= content.len) return error.BadStatFile;
        remainder = remainder[nameEnd + 2 ..];

        var column = std.mem.tokenizeScalar(u8, remainder, ' ');
        var stat: StatInfo = undefined;
        stat.state = StatInfo.State.from((column.next() orelse return error.BadStatFile)[0]) orelse return error.BadStatFile;

        // skip to utime (at field 14)
        for (0..10) |_| _ = column.next() orelse return error.BadStatFile;
        stat.utime = std.fmt.parseInt(usize, column.next() orelse return error.BadStatFile, 10) catch return error.BadStatFile;
        stat.stime = std.fmt.parseInt(usize, column.next() orelse return error.BadStatFile, 10) catch return error.BadStatFile;

        // skip to threads (at field 20)
        for (0..4) |_| _ = column.next() orelse return error.BadStatFile;
        stat.threads = std.math.cast(
            u32,
            // this guy is i64 but negative numbers make no sense, so we attempt a safe u32 cast
            std.fmt.parseInt(
                i64,
                column.next() orelse return error.BadStatFile,
                10,
            ) catch return error.BadStatFile,
        ) orelse return error.BadStatFile;

        // skip to startTime (at field 22)
        _ = column.next() orelse return error.BadStatFile;
        stat.startTime = std.fmt.parseInt(usize, column.next() orelse return error.BadStatFile, 10) catch return error.BadStatFile;

        // skip to rss (at field 24)
        _ = column.next() orelse return error.BadStatFile;
        stat.rss = (std.fmt.parseInt(usize, column.next() orelse return error.BadStatFile, 10) catch return error.BadStatFile) * std.heap.pageSize();
        stat.timeInMillis = timeInMillis;

        return stat;
    }

    pub fn cmdline(self: *@This(), io: std.Io, allocator: Allocator, buf: FileBuf) !?[]const u8 {
        const content = try self.pidFile(io, buf, .cmdline);
        if (content.len == 0) return null;
        // file ends with \x00
        const line = try allocator.dupe(u8, content[0 .. content.len - 1]);
        std.mem.replaceScalar(u8, line, 0x00, ' ');
        return line;
    }

    pub fn comm(self: *@This(), io: std.Io, allocator: Allocator, buf: FileBuf) !?[]const u8 {
        const content = try self.pidFile(io, buf, .comm);
        if (content.len == 0) return null;
        // file ends with \n
        return try allocator.dupe(u8, content[0 .. content.len - 1]);
    }

    pub fn user(self: *@This(), io: std.Io, allocator: Allocator, buf: FileBuf, users: *Users) ![]const u8 {
        const content = try self.pidFile(io, buf, .status);

        const uidToken = "\nUid:\t";
        const optRowIdx = std.mem.indexOf(u8, content, uidToken);

        if (optRowIdx == null) return error.BadStatusFile;

        const idx = optRowIdx.?;
        const remainder = content[idx + uidToken.len ..];

        const optColIdx = std.mem.indexOfScalar(u8, remainder, '\t');
        if (optColIdx == null) return error.BadStatusFile;

        const uid = std.fmt.parseInt(u32, remainder[0..optColIdx.?], 10) catch return error.BadStatusFile;
        return try users.get(allocator, uid);
    }
};

pub const PidInfo = struct {
    // lifecycle for this is Users cache
    user: []const u8,
    // this owns this guy
    cmd: []const u8,
    currStat: StatInfo,
    cpuPercent: f32,
    mem: MemRes,
    uptime: Uptime,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.cmd);
    }

    pub fn updateOrReload(self: *@This(), tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: FileBuf, users: *Users) !bool {
        var prevStat = self.currStat;
        self.currStat = tracker.statInfo(io, buf) catch |e| {
            log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
            return error.CantStatPid;
        };

        if (prevStat.startTime == self.currStat.startTime) {
            try self.updateStats(&prevStat, io);
            return true;
        }

        // wipe previous allocations
        // discover pid again
        // move on
        self.deinit(allocator);
        prevStat = self.currStat;

        self.user = tracker.user(io, allocator, buf, users) catch |e| {
            log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
            return error.CantStatPid;
        };
        self.cmd = try parseCmd(tracker, io, allocator, buf);
        errdefer self.deinit(allocator);

        try self.updateStats(&prevStat, io);
        return false;
    }

    fn updateStats(self: *@This(), prevStat: *const StatInfo, io: std.Io) !void {
        self.cpuPercent = self.calculateCpuPercent(prevStat);
        self.mem = try self.calculateMemoryTotal();
        self.uptime = self.calculateUptime(io);
    }

    fn parseCmd(tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: FileBuf) ![]const u8 {
        // var cmd: ?[]const u8 = tracker.cmdline(io, allocator, buf) catch |e| {
        //     log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
        //     return error.CantStatPid;
        // };
        // if (cmd == null) {
        // if (tracker.comm(io, allocator, buf) catch |e| {
        //     log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
        //     return error.CantStatPid;
        // }) |comm|
        //     // cmd = comm
        // else
        //     return error.CantStatPid;
        // }
        // return cmd.?;

        if (tracker.comm(io, allocator, buf) catch |e| {
            log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
            return error.CantStatPid;
        }) |comm|
            return comm
        else
            return error.CantStatPid;
    }

    pub fn init(tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: FileBuf, users: *Users) !@This() {
        const user = tracker.user(io, allocator, buf, users) catch |e| {
            log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
            return error.CantStatPid;
        };
        const stat = tracker.statInfo(io, buf) catch |e| {
            log.debug("{s}, error - {s}", .{ tracker.pidAsStr(), @errorName(e) });
            return error.CantStatPid;
        };
        const cmd = try parseCmd(tracker, io, allocator, buf);
        var self: @This() = .{
            .user = user,
            .cmd = cmd,
            .currStat = stat,
            // will be filled updateStats
            .mem = undefined,
            .cpuPercent = undefined,
            .uptime = undefined,
        };
        errdefer self.deinit(allocator);
        try self.updateStats(&stat, io);
        return self;
    }

    fn calculateCpuPercent(self: *const @This(), prevStat: *const StatInfo) f16 {
        const tDeltaMs = self.currStat.timeInMillis - prevStat.timeInMillis;
        if (tDeltaMs == 0) return 0.0;

        const tickDelta = (self.currStat.utime + self.currStat.stime) -
            (prevStat.utime + prevStat.stime);

        // standard Linux _SC_CLK_TCK
        const clkTck: f64 = 100.0;

        const cpuSeconds = @as(f64, @floatFromInt(tickDelta)) / clkTck;
        const intervalSeconds = @as(f64, @floatFromInt(tDeltaMs)) / 1000.0;

        const percent = (cpuSeconds / intervalSeconds) * 100.0;
        return @floatCast(percent);
    }

    pub const MemRes = struct {
        value: u14,
        unit: MemUnit,

        pub const MemUnit = enum(u3) {
            B,
            K,
            M,
            G,
            T,

            pub fn unit(self: @This()) usize {
                return @as(usize, 1) << (10 * @as(u6, @intFromEnum(self)));
            }
        };
    };

    fn calculateMemoryTotal(self: *const @This()) !MemRes {
        const rss: usize = self.currStat.rss;
        comptime var i = pack(MemRes.MemUnit.T);
        inline while (true) : (if (i > 0) {
            i -= 1;
        } else break) {
            var unit = comptime unpack(MemRes.MemUnit, i);
            // 0 doesnt fit 1b unit :p
            if (@max(1, rss) >= unit.unit()) {
                var v = @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(unit.unit()));
                var r: u14 = undefined;
                // Mibibytes / kibibytes can go up to 1k+ and not breach the next unit
                if (v >= 1000.0) {
                    if (comptime unpack(MemRes.MemUnit, i) == .T) return error.MemoryTooLarge;
                    unit = comptime unpack(MemRes.MemUnit, i + 1);
                    v = v / 1024.0;
                    // this is guaranteed to be < 1
                    r = @intFromFloat(@trunc(v * 10));
                } else if (v >= 10.0)
                    r = @as(u14, @intFromFloat(@trunc(v))) * 10
                else
                    r = @intFromFloat(@trunc(v * 10));

                return .{
                    .value = r,
                    .unit = unit,
                };
            }
        }
        return error.UnsupportedUnit;
    }

    pub const Uptime = packed struct(u64) {
        _: u20 = 0,
        s: u6,
        m: u6,
        h: u32,
    };

    fn calculateUptime(self: *const @This(), io: std.Io) Uptime {
        const currInSec: usize = @intCast(std.Io.Clock.boot.now(io).toSeconds());
        const startInSec = @divTrunc(self.currStat.startTime, 100);

        const delta = currInSec - startInSec;
        const s = delta % 60;
        const m = @divFloor(delta % 3600, 60);
        const h = @divFloor(delta, 3600);

        return .{
            .h = @intCast(h),
            .m = @intCast(m),
            .s = @intCast(s),
        };
    }
};

pub const PidWatcher = struct {
    pidTracker: PidTracker,
    pidInfo: ?PidInfo,
    survive: bool,

    // value init to help with hash semantics
    pub fn init(self: *@This(), dir: std.Io.Dir, pid: u32) void {
        self.pidTracker = .init(dir, pid);
        self.survive = true;
        self.pidInfo = null;
    }

    pub fn update(self: *@This(), io: std.Io, allocator: Allocator, buf: FileBuf, users: *Users) !bool {
        if (self.pidInfo) |*pidInfo| {
            const before = pidInfo.*;
            errdefer pidInfo.* = before;

            return try pidInfo.updateOrReload(&self.pidTracker, io, allocator, buf, users);
        } else {
            self.pidInfo = try .init(&self.pidTracker, io, allocator, buf, users);
            return false;
        }
    }

    pub fn deinit(self: *@This(), io: std.Io, allocator: Allocator) void {
        self.pidTracker.close(io);
        if (self.pidInfo) |*pidInfo| pidInfo.deinit(allocator);
    }
};

const testing = std.testing;

test "PidWatcher reload" {
    const io = testing.io;
    const allocator = testing.allocator;

    const buf: FileBuf = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 << 10);
    defer allocator.free(buf);

    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});

    var watcher: PidWatcher = undefined;
    watcher.init(dir, @intCast(pid));
    defer watcher.deinit(io, allocator);
    try testing.expectEqual(null, watcher.pidInfo);

    // This is good enough tbh
    _ = try watcher.update(io, allocator, buf, &users);
    // same as
    const prevStat = watcher.pidInfo.?.currStat;
    try testing.expect(watcher.pidInfo.?.currStat.timeInMillis == prevStat.timeInMillis);
    try testing.expectEqual(0.0, watcher.pidInfo.?.cpuPercent);

    _ = try watcher.update(io, allocator, buf, &users);
    try testing.expect(watcher.pidInfo.?.currStat.timeInMillis >= prevStat.timeInMillis);
}

test "PidInfo uptime" {
    const timeInSec: usize = @intCast(std.Io.Clock.boot.now(testing.io).toSeconds());
    var info: PidInfo = undefined;
    info.currStat.startTime = 200;

    const up = info.calculateUptime(testing.io);

    try testing.expectEqual(@divFloor(timeInSec, 3600) / 4, up.h / 4);
    try testing.expectEqual(@divFloor(timeInSec % 3600, 60) / 10, up.m / 10);
    try testing.expectEqual(up.s % 60, up.s);
}

test "PidInfo cpuPercent" {
    const timeInMillis = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    var info: PidInfo = undefined;
    info.currStat.stime = 200;
    info.currStat.utime = 200;
    info.currStat.timeInMillis = timeInMillis;

    var prevStat: StatInfo = undefined;
    prevStat.stime = 100;
    prevStat.utime = 100;
    prevStat.timeInMillis = timeInMillis;

    try testing.expectEqual(0.0, info.calculateCpuPercent(&prevStat));

    prevStat.timeInMillis = timeInMillis - 1000;
    try testing.expectEqual(200, info.calculateCpuPercent(&prevStat));
}

test "PidInfo memoryTotal" {
    var info: PidInfo = undefined;
    info.currStat.rss = 0;

    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 0, .unit = .B }, try info.calculateMemoryTotal());
    info.currStat.rss = 1;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 10, .unit = .B }, try info.calculateMemoryTotal());
    info.currStat.rss = 10;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 100, .unit = .B }, try info.calculateMemoryTotal());
    info.currStat.rss = 999;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 9990, .unit = .B }, try info.calculateMemoryTotal());
    info.currStat.rss = 1000;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 9, .unit = .K }, try info.calculateMemoryTotal());
    info.currStat.rss = 1025;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 10, .unit = .K }, try info.calculateMemoryTotal());
    info.currStat.rss = 2000;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 19, .unit = .K }, try info.calculateMemoryTotal());
}

test "parse user" {
    const io = testing.io;
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});
    var tracker = PidTracker.init(dir, @intCast(pid));

    const buf: FileBuf = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 << 10);
    defer allocator.free(buf);

    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    const user = try tracker.user(io, allocator, buf, &users);
    const expectUid, const expectUser = try getPidUserFromCmd(testing.io, testing.allocator);
    defer testing.allocator.free(expectUid);
    defer testing.allocator.free(expectUser);

    try testing.expectEqualStrings(expectUser, user);
}

test "parse comm" {
    const io = testing.io;
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});
    var tracker = PidTracker.init(dir, @intCast(pid));

    const buf: FileBuf = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 << 10);
    defer allocator.free(buf);

    const line = (try tracker.comm(io, allocator, buf)).?;
    defer allocator.free(line);

    // a bit too ligth for my taste, but better than nothing
    try testing.expectEqualStrings("test", line);
}

test "parse cmdline" {
    const io = testing.io;
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});
    var tracker = PidTracker.init(dir, @intCast(pid));

    const buf: FileBuf = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 << 10);
    defer allocator.free(buf);

    const line = (try tracker.cmdline(io, allocator, buf)).?;
    defer allocator.free(line);

    // a bit too ligth for my taste, but better than nothing
    try testing.expect(std.mem.findScalar(u8, line, ' ') != null);
}

test "parse statusInfo" {
    const io = testing.io;
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});
    var tracker = PidTracker.init(dir, @intCast(pid));

    const buf: FileBuf = try allocator.alignedAlloc(u8, .fromByteUnits(std.atomic.cache_line), 4 << 10);
    defer allocator.free(buf);

    const stat = try tracker.statInfo(io, buf);

    try testing.expectEqual(StatInfo.State.R, stat.state);
    try testing.expect(stat.utime >= 0);
    try testing.expect(stat.stime >= 0);
    try testing.expectEqual(1, stat.threads);
    try testing.expect(stat.startTime > 0);
    try testing.expect(stat.rss > 0);
}

fn getPidUserFromCmd(io: std.Io, allocator: Allocator) !struct { []const u8, []const u8 } {
    const idProcessR = try std.process.run(allocator, io, .{
        .argv = &.{"id"},
        .stderr_limit = .nothing,
    });
    defer allocator.free(idProcessR.stdout);
    defer allocator.free(idProcessR.stderr);

    if (idProcessR.term.exited != 0) return error.FailedCmdRun;

    const out = idProcessR.stdout;
    const userStart = std.mem.indexOfScalar(u8, out, '(').?;
    const userEnd = std.mem.indexOfScalar(u8, out, ')').?;

    // uid=\d+(\w+)
    const expectUid = out["uid=".len..userStart];
    const expectUser = out[userStart + 1 .. userEnd];
    return .{ try allocator.dupe(u8, expectUid), try allocator.dupe(u8, expectUser) };
}

test "parse passwd" {
    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    const expectUid, const expectUser = try getPidUserFromCmd(testing.io, testing.allocator);
    defer testing.allocator.free(expectUid);
    defer testing.allocator.free(expectUser);

    try testing.expectEqualStrings(
        expectUser,
        try users.get(testing.allocator, try std.fmt.parseInt(u32, expectUid, 10)),
    );
}
