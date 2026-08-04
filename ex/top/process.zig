const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const regent = @import("regent");
const Context = regent.ergo.Context;
const FileCursor = regent.fs.FileCursor;
const FileCursorConfig = regent.fs.FileCursorConfig;
const PolicyEntry = FileCursorConfig.PolicyEntry;

const ResBufAlignment: std.mem.Alignment = .fromByteUnits(std.atomic.cache_line);
const ResBuf = std.ArrayListAligned(u8, ResBufAlignment);

pub const Users = struct {
    buf: []align(ResBufAlignment.toByteUnits()) u8,
    uidMap: std.AutoHashMapUnmanaged(u32, []const u8),
    missMap: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    pub const PASSWD_PATH = "/etc/passwd";

    pub fn load(io: std.Io, allocator: Allocator) !Users {
        const passwdF = try std.Io.Dir.openFileAbsolute(io, PASSWD_PATH, .{ .mode = .read_only });
        defer passwdF.close(io);

        const context: Context = .{ .io = io, .allocator = allocator };
        var fs = try regent.fs.FileStream(.read).openStreamWithConfig(
            context,
            passwdF,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            null,
        );

        var buf: ResBuf = try .initCapacity(allocator, fs.stat.size);
        errdefer buf.deinit(allocator);
        fs.setBuffer(ResBufAlignment, buf.items);

        const content = try fs.readFileRetained(allocator, &buf);
        const entryCount = std.mem.countScalar(u8, content, '\n');

        var uidMap: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
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
            .buf = buf.allocatedSlice(),
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
        allocator.free(self.buf);
    }
};

pub const ProcDirScanner = struct {
    procDir: std.Io.Dir,
    dirR: std.Io.Dir.Reader,

    pub const PROC_PATH = "/proc";

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
    pathBuf: [regent.fmt.decimalStrSize(u32) + PidFile.loginuid.toStr().len]u8,
    pidEnd: u8,

    // This avoid syscalls for long-running pids
    statF: ?std.Io.File,
    cmdlineF: ?std.Io.File,
    commF: ?std.Io.File,
    loginuidF: ?std.Io.File,

    pub const PidFile = enum {
        stat,
        cmdline,
        comm,
        loginuid,

        pub fn toStr(self: @This()) []const u8 {
            return @tagName(self);
        }
    };

    pub fn init(dir: std.Io.Dir, pid: u32) @This() {
        var self: @This() = undefined;
        self.dir = dir;
        self.statF = null;
        self.cmdlineF = null;
        self.commF = null;
        self.loginuidF = null;

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
        if (self.cmdlineF) |f| {
            f.close(io);
            self.cmdlineF = null;
        }
        if (self.commF) |f| {
            f.close(io);
            self.commF = null;
        }
        if (self.loginuidF) |f| {
            f.close(io);
            self.loginuidF = null;
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
            .cmdline => r: {
                if (self.cmdlineF) |f| return f;
                break :r @tagName(fileTag);
            },
            .comm => r: {
                if (self.commF) |f| return f;
                break :r @tagName(fileTag);
            },
            .loginuid => r: {
                if (self.loginuidF) |f| return f;
                break :r @tagName(fileTag);
            },
        };

        const f = try self.dir.openFile(io, self.makePidPath(fName), .{ .mode = .read_only });
        switch (fileTag) {
            .stat => self.statF = f,
            .cmdline => self.cmdlineF = f,
            .comm => self.commF = f,
            .loginuid => self.loginuidF = f,
        }
        return f;
    }

    fn pidFile(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf, fileTag: PidFile) ![]const u8 {
        const f = try self.openFile(io, fileTag);
        const context: Context = .{ .io = io, .allocator = allocator };
        var fs = try regent.fs.FileStream(.read).openStreamWithConfig(
            context,
            f,
            .{},
            .unmanaged,
            .defaultReaderConfig,
            // This tells regent to not stat this file, all pid files
            // are regular files with 0 size, they are special and
            // actually live in memory, there's no point in getting statx info
            // for them
            .{
                .inode = 0,
                .nlink = 0,
                .size = 0,
                .permissions = .default_file,
                .kind = .file,
                .atime = null,
                .mtime = .zero,
                .ctime = .zero,
                .block_size = std.heap.pageSize(),
            },
        );
        fs.setBuffer(ResBufAlignment, buf.allocatedSlice());

        return try fs.readFileRetained(allocator, buf);
    }

    pub fn statInfo(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf) !StatInfo {
        // We are using millis because we need to multiply all tick unis by 1000 (10 * 100 for percent)
        // USER_HZ is historically 0.01 seconds
        const timeInMillis = std.Io.Clock.awake.now(io).toMilliseconds();
        const content = try self.pidFile(io, allocator, buf, .stat);

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

    pub fn cmdline(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf) !?[]const u8 {
        const content = try self.pidFile(io, allocator, buf, .cmdline);
        if (content.len == 0) return null;
        // file ends with \x00
        const line = try allocator.dupe(u8, content[0 .. content.len - 1]);
        std.mem.replaceScalar(u8, line, 0x00, ' ');
        return line;
    }

    pub fn comm(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf) !?[]const u8 {
        const content = try self.pidFile(io, allocator, buf, .comm);
        if (content.len == 0) return null;
        // file ends with \n
        return try allocator.dupe(u8, content[0 .. content.len - 1]);
    }

    pub fn loginuid(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf, users: *Users) ![]const u8 {
        const content = try self.pidFile(io, allocator, buf, .loginuid);
        // 0 goes to root
        var uid = std.fmt.parseInt(u32, content, 10) catch 0;
        if (uid == std.math.maxInt(u32)) uid = 0;
        return try users.get(allocator, uid);
    }
};

pub const PidInfo = struct {
    // lifecycle for this is Users cache
    user: []const u8,
    // this owns this guy
    cmd: []const u8,
    // TODO: calculate stat and drop prev
    prevStat: StatInfo,
    currStat: StatInfo,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.cmd);
    }

    pub fn updateOrReload(self: *@This(), tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: *ResBuf, users: *Users) !void {
        self.prevStat = self.currStat;
        self.currStat = tracker.statInfo(io, allocator, buf) catch return error.CantStatPid;

        if (self.prevStat.startTime == self.currStat.startTime) {
            return;
        }

        // wipe previous allocations
        // discover pid again
        // move on
        self.deinit(allocator);
        self.prevStat = self.currStat;

        self.user = tracker.loginuid(io, allocator, buf, users) catch return error.CantStatPid;
        self.cmd = try parseCmd(tracker, io, allocator, buf);
    }

    pub fn parseCmd(tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: *ResBuf) ![]const u8 {
        var cmd: ?[]const u8 = tracker.cmdline(io, allocator, buf) catch return error.CantStatPid;
        if (cmd == null) {
            if (tracker.comm(io, allocator, buf) catch return error.CantStatPid) |comm|
                cmd = comm
            else
                return error.CantStatPid;
        }
        return cmd.?;
    }

    pub fn init(tracker: *PidTracker, io: std.Io, allocator: Allocator, buf: *ResBuf, users: *Users) !@This() {
        const user = tracker.loginuid(io, allocator, buf, users) catch return error.CantStatPid;
        const stat = tracker.statInfo(io, allocator, buf) catch return error.CantStatPid;
        const cmd = try parseCmd(tracker, io, allocator, buf);
        return .{
            .user = user,
            .cmd = cmd,
            .prevStat = stat,
            .currStat = stat,
        };
    }

    pub fn cpuPercent(self: *const @This()) f16 {
        const tDeltaMs = self.currStat.timeInMillis - self.prevStat.timeInMillis;
        if (tDeltaMs == 0) return 0.0;

        const tickDelta = (self.currStat.utime + self.currStat.stime) -
            (self.prevStat.utime + self.prevStat.stime);

        // standard Linux _SC_CLK_TCK
        const clkTck: f64 = 100.0;

        const cpuSeconds = @as(f64, @floatFromInt(tickDelta)) / clkTck;
        const intervalSeconds = @as(f64, @floatFromInt(tDeltaMs)) / 1000.0;

        const percent = (cpuSeconds / intervalSeconds) * 100.0;
        return @floatCast(percent);
    }

    pub const MemRes = struct {
        value: f16,
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

    pub fn memoryTotal(self: *const @This()) !MemRes {
        const rss: usize = self.currStat.rss;
        var i: i8 = @intFromEnum(MemRes.MemUnit.T);
        while (i >= 0) : (i -= 1) {
            var unit = @as(MemRes.MemUnit, @enumFromInt(i));
            // 0 doesnt fit 1b unit :p
            if (@max(1, rss) >= unit.unit()) {
                var r = @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(unit.unit()));
                // Mibibytes / kibibytes can go up to 1k+ and not breach the next unit
                if (r >= 1000) {
                    unit = @as(MemRes.MemUnit, @enumFromInt(i + 1));
                    r = r / 1024.0;
                    r = regent.fmt.floatTrunc(f64, r, 1);
                } else if (r >= 10.0) {
                    r = @trunc(r);
                } else {
                    r = regent.fmt.floatTrunc(f64, r, 1);
                }
                return .{
                    .value = @floatCast(r),
                    .unit = unit,
                };
            }
        }
        return error.UnsupportedUnit;
    }

    pub const Uptime = struct {
        h: u32,
        m: u8,
        s: u8,
    };

    pub fn uptime(self: *const @This(), io: std.Io) Uptime {
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

    pub fn update(self: *@This(), io: std.Io, allocator: Allocator, buf: *ResBuf, users: *Users) !void {
        errdefer self.pidInfo = null;

        if (self.pidInfo) |*pidInfo| {
            try pidInfo.updateOrReload(&self.pidTracker, io, allocator, buf, users);
        } else {
            self.pidInfo = try .init(&self.pidTracker, io, allocator, buf, users);
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

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});

    var watcher: PidWatcher = undefined;
    watcher.init(dir, @intCast(pid));
    defer watcher.deinit(io, allocator);
    try testing.expectEqual(null, watcher.pidInfo);

    // This is good enough tbh
    try watcher.update(io, allocator, &buf, &users);
    try testing.expect(watcher.pidInfo.?.currStat.timeInMillis == watcher.pidInfo.?.prevStat.timeInMillis);

    try watcher.update(io, allocator, &buf, &users);
    try testing.expect(watcher.pidInfo.?.currStat.timeInMillis >= watcher.pidInfo.?.prevStat.timeInMillis);
}

test "PidInfo uptime" {
    const timeInSec: usize = @intCast(std.Io.Clock.boot.now(testing.io).toSeconds());
    var info: PidInfo = undefined;
    info.currStat.startTime = 200;

    const up = info.uptime(testing.io);

    try testing.expectEqual(@divFloor(timeInSec, 3600), up.h);
    try testing.expectEqual(@divFloor(timeInSec % 3600, 60) -| 10, up.m -| 10);
    try testing.expectEqual(up.s % 60, up.s);
}

test "PidInfo cpuPercent" {
    const timeInMillis = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    var info: PidInfo = undefined;
    info.currStat.stime = 200;
    info.currStat.utime = 200;
    info.currStat.timeInMillis = timeInMillis;

    info.prevStat.stime = 100;
    info.prevStat.utime = 100;
    info.prevStat.timeInMillis = timeInMillis;

    try testing.expectEqual(0.0, info.cpuPercent());

    info.prevStat.timeInMillis = timeInMillis - 1000;
    try testing.expectEqual(200, info.cpuPercent());
}

test "PidInfo memoryTotal" {
    var info: PidInfo = undefined;
    info.currStat.rss = 0;

    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 0, .unit = .B }, try info.memoryTotal());
    info.currStat.rss = 1;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 1, .unit = .B }, try info.memoryTotal());
    info.currStat.rss = 10;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 10, .unit = .B }, try info.memoryTotal());
    info.currStat.rss = 999;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 999, .unit = .B }, try info.memoryTotal());
    info.currStat.rss = 1000;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 0.9, .unit = .K }, try info.memoryTotal());
    info.currStat.rss = 1025;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 1, .unit = .K }, try info.memoryTotal());
    info.currStat.rss = 2000;
    try regent.testing.expectEqualDeep(PidInfo.MemRes, .{ .value = 1.9, .unit = .K }, try info.memoryTotal());
}

test "parse loginuid" {
    const io = testing.io;
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();
    const dir = try std.Io.Dir.openDirAbsolute(io, "/proc", .{});
    var tracker = PidTracker.init(dir, @intCast(pid));

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    const user = try tracker.loginuid(io, allocator, &buf, &users);
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

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    const line = (try tracker.comm(io, allocator, &buf)).?;
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

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    const line = (try tracker.cmdline(io, allocator, &buf)).?;
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

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    const stat = try tracker.statInfo(io, allocator, &buf);

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

test "parse stat" {
    const io = testing.io;
    const allocator = testing.allocator;

    const path = "/proc";

    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false, .access_sub_paths = false });
    defer dir.close(io);

    var dentsBuf: [4 << 10]u8 align(@alignOf(usize)) = undefined;

    var buf: ResBuf = try .initCapacity(allocator, 4 << 10);
    defer buf.deinit(allocator);

    var users = try Users.load(testing.io, testing.allocator);
    defer users.deinit(testing.allocator);

    var pidMap: std.AutoHashMapUnmanaged(u32, PidWatcher) = .empty;
    try pidMap.ensureTotalCapacity(allocator, 100);
    defer {
        var it = pidMap.iterator();
        while (it.next()) |e| e.value_ptr.deinit(io, allocator);
        pidMap.deinit(allocator);
    }

    for (0..60) |_| {
        var procDirScanner: ProcDirScanner = .init(dir, &dentsBuf);
        while (true) {
            const pid = (try procDirScanner.nextPid(io)) orelse break;
            const gop = try pidMap.getOrPut(allocator, pid);
            if (!gop.found_existing) {
                gop.value_ptr.init(dir, pid);
            }
            const watcher = gop.value_ptr;
            watcher.update(io, allocator, &buf, &users) catch continue;
            const pidInfo = &watcher.pidInfo.?;
            const mem = try pidInfo.memoryTotal();
            const uptime = pidInfo.uptime(io);

            std.debug.print("{s}\t{s}\t{s}\t{d}\t{d:.1}%\t{d}:{d:0>2}:{d:0>2}\t{d}{s}\t{s}\n", .{
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

            watcher.survive = true;
        }

        var it = pidMap.iterator();
        while (it.next()) |e| {
            // reset for next run or nuke
            if (!e.value_ptr.survive) {
                e.value_ptr.deinit(io, allocator);
                pidMap.removeByPtr(e.key_ptr);
            } else e.value_ptr.survive = false;
        }
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}
