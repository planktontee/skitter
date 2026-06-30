const std = @import("std");
const builtin = @import("builtin");
const File = std.Io.File;
const linux = std.os.linux;
const regent = @import("regent");
const rlinux = regent.linux;
const is_debug = builtin.mode == .Debug;
const skitter = @import("../skitter.zig");

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

pub const Terminal = struct {
    fsIn: regent.fs.FileStream(.read),
    fsOut: regent.fs.FileStream(.write),
    sigwinch: File,
    size: TermSize,

    beforeTtyAttr: linux.termios,

    pub const InitError = std.posix.TermiosGetError ||
        std.posix.TermiosSetError ||
        ConfigureSignalsError ||
        regent.fs.OpenError ||
        GetTermSizeError;

    pub fn init(context: regent.ergo.Context) InitError!@This() {
        const stdin = File.stdin();
        const stdout = File.stdout();

        const beforeTtyAttr = try std.posix.tcgetattr(stdin.handle);
        var ttyAttr = beforeTtyAttr;
        configureTtyAttr(&ttyAttr);

        try std.posix.tcsetattr(stdin.handle, .FLUSH, ttyAttr);

        return .{
            // TODO: test different buffer sizes later
            .fsIn = try regent.fs.FileStream(.read).openStream(context, stdin),
            .fsOut = try regent.fs.FileStream(.write).openStreamWithConfig(
                context,
                stdout,
                .{},
                .byte,
                .initSame(regent.units.ByteUnit.mb),
                null,
            ),
            .sigwinch = try configureSignals(),
            .size = try getTermSize(stdin),
            .beforeTtyAttr = beforeTtyAttr,
        };
    }

    pub fn start(self: *const @This(), io: std.Io) std.Io.File.Writer.Error!void {
        try self.fsOut.stream.file.writeStreamingAll(io, "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    }

    pub fn stop(self: *const @This(), io: std.Io) std.Io.File.Writer.Error!void {
        try self.fsOut.stream.file.writeStreamingAll(io, "\x1b[?25h\x1b[?1049l");
    }

    pub fn deinit(self: *@This(), context: regent.ergo.Context) void {
        restoreSignals();
        self.sigwinch.close(context.io);
        std.posix.tcsetattr(self.fsIn.stream.file.handle, .FLUSH, self.beforeTtyAttr) catch |e|
            if (is_debug)
                std.debug.panic("Unable to restore tty attributes: {t}", .{e});
        self.fsIn.deinit(context);
        self.fsOut.deinit(context);
    }

    pub const ConfigureSignalsError = @typeInfo(@typeInfo(@TypeOf(std.posix.signalfd)).@"fn".return_type.?).error_union.error_set;

    fn configureSignals() ConfigureSignalsError!File {
        var mask: std.posix.sigset_t = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, linux.SIG.WINCH);
        // Block the signal from interrupting our process normally
        std.posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

        return .{
            .handle = try std.posix.signalfd(-1, &mask, 0),
            .flags = .{ .nonblocking = true },
        };
    }

    fn restoreSignals() void {
        var mask: std.posix.sigset_t = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, linux.SIG.WINCH);
        std.posix.sigprocmask(linux.SIG.UNBLOCK, &mask, null);
    }

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
        ttyAttr.lflag.ISIG = false;
        // disable extended sequence handling
        ttyAttr.lflag.IEXTEN = false;

        // since we are using epoll/iouring we dont need timeouts
        ttyAttr.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        ttyAttr.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    }
};
