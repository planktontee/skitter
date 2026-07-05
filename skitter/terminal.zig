const std = @import("std");
const builtin = @import("builtin");
const File = std.Io.File;
const linux = std.os.linux;
const regent = @import("regent");
const rlinux = regent.linux;
const is_debug = builtin.mode == .Debug;
const skitter = @import("../skitter.zig");
const Trace = @import("Trace.zig");
const Window = @import("args.zig").Window;
const control = @import("control.zig");

pub const TermSize = struct {
    rows: usize,
    cols: usize,
};

pub const GetTermSizeError = error{
    NotATerminal,
    BadFileDescriptor,
    UnsupportedOperation,
} || std.Io.UnexpectedError;

pub fn getTermSize(file: File) GetTermSizeError!TermSize {
    var size = std.c.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
    const rc = linux.ioctl(file.handle, linux.T.IOCGWINSZ, @intFromPtr(&size));
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        .NOTTY => return error.NotATerminal,
        // ptr cant be faulty at this point
        .FAULT => unreachable,
        .INVAL => return error.UnsupportedOperation,
        else => |err| return rlinux.errnoBug(err),
    }
    return .{ .rows = size.row, .cols = size.col };
}

pub const Mode = union(enum) {
    fullscreen,
    window: TermSize,
};

pub const Pos = struct {
    x: u16,
    y: u16,
};

pub threadlocal var stopRun: bool = false;

fn handleStop(sig: std.posix.SIG) callconv(.c) void {
    switch (sig) {
        std.posix.SIG.INT, std.posix.SIG.QUIT => stopRun = true,
        else => {},
    }
}

pub const Terminal = struct {
    fsIn: regent.fs.FileStream(.read),
    fsOut: regent.fs.FileStream(.write),
    size: TermSize,
    trueSize: TermSize,
    trace: ?*Trace = null,
    startPos: Pos,
    mode: Mode = .fullscreen,

    beforeTtyAttr: linux.termios,

    pub const InitError = error{
        BadCursorPositionQueryResponse,
    } || std.posix.TermiosGetError ||
        std.posix.TermiosSetError ||
        ConfigureSignalsError ||
        regent.fs.OpenError ||
        std.Io.File.ReadStreamingError ||
        std.Io.File.Writer.Error ||
        std.Io.Writer.Error ||
        std.fmt.ParseIntError ||
        GetTermSizeError ||
        rlinux.FcntlGetFLError ||
        rlinux.FcntlSetFLError ||
        // epoll setup
        error{
            FdLimitReached,
            EpollFdAlreadyRegistered,
            NotRegisteredWithThisInstance,
            MaxEpollReached,
            SignalInterrupt,
            EpollTimeout,
        };

    pub fn init(context: regent.ergo.Context, mode: Mode) InitError!@This() {
        const cwd = std.Io.Dir.cwd();
        const ttyIn = try cwd.openFile(context.io, "/dev/tty", .{ .mode = .read_write });

        const ttyOut = try cwd.openFile(context.io, "/dev/tty", .{ .mode = .write_only });
        var fsOut = try regent.fs.FileStream(.write).openStreamWithConfig(
            context,
            ttyOut,
            .{},
            .byte,
            .initSame(regent.units.ByteUnit.mb),
            null,
        );

        const beforeTtyAttr = try std.posix.tcgetattr(ttyIn.handle);
        var ttyAttr = beforeTtyAttr;
        configureTtyAttr(&ttyAttr);

        try configureSignals();
        try std.posix.tcsetattr(ttyIn.handle, .FLUSH, ttyAttr);

        const trueSize = try getTermSize(ttyIn);

        const pos: Pos = switch (mode) {
            .fullscreen => .{ .x = 0, .y = 0 },
            .window => |w| try prepareWindow(
                context,
                ttyIn,
                &fsOut,
                trueSize,
                w,
                null,
            ),
        };

        return .{
            // TODO: test different buffer sizes later
            .fsIn = try regent.fs.FileStream(.read).openStream(context, ttyIn),
            .fsOut = fsOut,
            .size = if (mode == .window) .{
                .rows = mode.window.rows,
                .cols = mode.window.cols,
            } else trueSize,
            .trueSize = trueSize,
            .beforeTtyAttr = beforeTtyAttr,
            .startPos = pos,
            .mode = mode,
        };
    }

    pub fn isRunning() bool {
        return !stopRun;
    }

    // TODO: Move epoll syscalls to regent
    // TODO: prepare epoll for stdin for application use, not just this query
    fn prepareWindow(
        context: regent.ergo.Context,
        ttyIn: std.Io.File,
        fsOut: *regent.fs.FileStream(.write),
        trueSize: TermSize,
        window: TermSize,
        sigmasks: ?*const std.os.linux.sigset_t,
    ) !Pos {
        // prepare for epoll
        var flags = try rlinux.fcntlGetFL(context.io, ttyIn.handle);
        const originalFlags = flags;
        defer {
            rlinux.fcntlSetFL(context.io, ttyIn.handle, originalFlags) catch {};
        }

        flags.NONBLOCK = true;
        try rlinux.fcntlSetFL(context.io, ttyIn.handle, flags);

        try ttyIn.writeStreamingAll(context.io, "\x1b[6n");

        const epollFd = r: {
            const rc = std.os.linux.epoll_create1(0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => break :r rc,
                .INVAL => return error.UnsupportedOperation,
                .MFILE => return error.FdLimitReached,
                .NOMEM => return error.OutOfMemory,
                else => |e| return rlinux.errnoBug(e),
            }
        };
        defer _ = std.os.linux.close(@intCast(epollFd));

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = ttyIn.handle },
        };

        {
            const rc = std.os.linux.epoll_ctl(
                @intCast(epollFd),
                std.os.linux.EPOLL.CTL_ADD,
                ttyIn.handle,
                &event,
            );
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .BADF => return error.BadFileDescriptor,
                .EXIST => return error.EpollFdAlreadyRegistered,
                .NOENT => return error.NotRegisteredWithThisInstance,
                .PERM => return error.PermissionDenied,
                .NOSPC => return error.MaxEpollReached,
                .INVAL => return error.UnsupportedOperation,
                else => |e| return rlinux.errnoBug(e),
            }
        }

        var events: [1]std.os.linux.epoll_event = undefined;

        {
            const rc = std.os.linux.epoll_pwait(@intCast(epollFd), &events, 1, 100, sigmasks);

            if (rc == 0) return error.EpollTimeout;

            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => return error.SignalInterrupt,
                .BADF => return error.BadFileDescriptor,
                .INVAL => return error.UnsupportedOperation,
                else => |e| return rlinux.errnoBug(e),
            }
        }

        var buf: [32]u8 = undefined;
        const n = try ttyIn.readStreaming(context.io, &.{&buf});

        if (n == 0) return error.BadCursorPositionQueryResponse;
        var raw = buf[0..n];

        var pos: Pos = undefined;
        const header: []const u8 = "\x1b[";
        if (!std.mem.startsWith(u8, raw, header)) return error.BadCursorPositionQueryResponse;
        raw = raw[header.len..];

        if (std.mem.findScalar(u8, raw, ';')) |sepIdx| {
            pos.y = (try std.fmt.parseInt(u8, raw[0..sepIdx], 10)) - 1;
            raw = raw[sepIdx + 1 ..];
            if (std.mem.findScalar(u8, raw, 'R')) |endIdx| {
                pos.x = (try std.fmt.parseInt(u8, raw[0..endIdx], 10)) - 1;
            } else return error.BadCursorPositionQueryResponse;
        } else return error.BadCursorPositionQueryResponse;

        const delta = trueSize.rows - pos.y;
        if (delta < window.rows) {
            const newTarget = window.rows - delta;
            for (0..newTarget) |_|
                try fsOut.stream.interface.writeAll(comptime control.scrollDown());
            try fsOut.stream.interface.flush();
            pos.y -= @intCast(newTarget);
        }

        return pos;
    }

    pub fn start(self: *const @This(), io: std.Io, comptime hideCursor: bool) std.Io.File.Writer.Error!void {
        const s = switch (self.mode) {
            .fullscreen => comptime r: {
                var sb = regent.collections.ComptSb.initTup(.{
                    control.wipeEntireScreen(),
                    control.moveCursorToHome(),
                });

                if (hideCursor) sb.append(control.hideCursor());
                break :r sb.s;
            },
            .window => comptime r: {
                var sb = regent.collections.ComptSb.init("");
                if (hideCursor) sb.append(control.hideCursor());
                break :r sb.s;
            },
        };

        try self.fsOut.stream.file.writeStreamingAll(io, s);
    }

    pub fn stop(self: *const @This(), io: std.Io, comptime showCursor: bool) std.Io.File.Writer.Error!void {
        const s = switch (self.mode) {
            .fullscreen => comptime r: {
                var sb = regent.collections.ComptSb.initTup(.{
                    control.moveToMainBuffer(),
                    control.cleanFormat(),
                });
                if (showCursor) sb.append(control.showCursor());
                break :r sb.s;
            },
            .window => comptime r: {
                var sb = regent.collections.ComptSb.init(control.cleanFormat());
                if (showCursor) sb.append(control.showCursor());
                break :r sb.s;
            },
        };

        try self.fsOut.stream.file.writeStreamingAll(io, s);
    }

    pub fn deinit(self: *@This(), context: regent.ergo.Context) void {
        restoreSignals();
        std.posix.tcsetattr(self.fsIn.stream.file.handle, .FLUSH, self.beforeTtyAttr) catch |e|
            if (is_debug)
                std.debug.panic("Unable to restore tty attributes: {t}", .{e});
        self.fsIn.deinit(context);
        self.fsOut.deinit(context);
    }

    pub const ConfigureSignalsError = @typeInfo(@typeInfo(@TypeOf(std.posix.signalfd)).@"fn".return_type.?).error_union.error_set;

    // TODO: move to event-based
    fn configureSignals() ConfigureSignalsError!void {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleStop },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };

        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.QUIT, &act, null);
        std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
        std.posix.sigaction(std.posix.SIG.TSTP, &act, null);
    }

    // TODO: once we are event-based, this will be important
    fn restoreSignals() void {}

    fn configureTtyAttr(ttyAttr: *linux.termios) void {
        ttyAttr.iflag.IXON = false;
        ttyAttr.iflag.ICRNL = false;
        ttyAttr.iflag.IUTF8 = true;
        // This strips the 8th bit, which we need for utf-8
        ttyAttr.iflag.ISTRIP = false;

        // disable output post procesing
        ttyAttr.oflag.OPOST = false;

        // char size to 8bits
        ttyAttr.cflag.CSIZE = .CS8;

        // raw mode instead of line buffer mode
        ttyAttr.lflag.ICANON = false;
        // print back input to output
        ttyAttr.lflag.ECHO = false;
        // disable all signals
        // TODO: enable this once we have event-based
        // ttyAttr.lflag.ISIG = false;
        ttyAttr.lflag.ISIG = true;
        // disable extended sequence handling
        ttyAttr.lflag.IEXTEN = false;

        // since we are using epoll/iouring we dont need timeouts
        ttyAttr.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        ttyAttr.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    }
};
