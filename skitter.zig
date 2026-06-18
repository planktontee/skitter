const std = @import("std");
const builtin = @import("builtin");
const regent = @import("regent");
const linux = std.os.linux;

pub const CellMode = enum(u4) {
    glyph = 0,
    ansi = 1,
    trueColor = 2,
    imgRoot = 3,
    skip = 4,
};

pub const GlyphCell = packed struct(u124) {
    value: u32,
    _: u92 = 0,
};

pub const Style = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverseColors: bool = false,
    hidden: bool = false,
    strike: bool = false,
};

pub const AnsiSystemColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    brightBlack = 8,
    brightRed = 9,
    brightGreen = 10,
    brightYellow = 11,
    brightBlue = 12,
    brightMagenta = 13,
    brightCyan = 14,
    brightWhite = 15,
    _,

    pub fn toAnsiColor(self: @This()) AnsiColor {
        const value: u8 = @intFromEnum(self);
        std.debug.assert(value <= 15);
        return .{ .system = self };
    }
};

pub const CubeColorRGB = struct {
    r: u3,
    g: u3,
    b: u3,
};

pub const CubeColor = packed struct(u8) {
    value: u8,

    pub fn init(val: u8) CubeColor {
        // Strict boundary validation: 16 to 231 only
        std.debug.assert(val >= 16 and val <= 231);
        return .{ .value = val };
    }

    pub fn r(self: CubeColor) u3 {
        return @intCast((self.value - 16) / 36);
    }
    pub fn g(self: CubeColor) u3 {
        return @intCast(((self.value - 16) / 6) % 6);
    }
    pub fn b(self: CubeColor) u3 {
        return @intCast((self.value - 16) % 6);
    }

    pub fn toAnsiColor(rgb: CubeColorRGB) AnsiColor {
        std.debug.assert(rgb.r <= 5 and rgb.g <= 5 and rgb.b <= 5);
        const value = 16 + (@as(u8, rgb.r) * 36) + (@as(u8, rgb.g) * 6) + @as(u8, rgb.b);
        return .{ .cube = CubeColor{ .value = value } };
    }
};

pub const GrayScale = packed struct(u8) {
    value: u8,

    pub fn init(val: u8) GrayScale {
        // Strict boundary validation: 232 to 255 only
        std.debug.assert(val >= 232);
        return .{ .value = val };
    }

    // Normalized intensity step (0 to 23)
    pub fn level(self: GrayScale) u5 {
        return @intCast(self.value - 232);
    }

    pub fn toAnsiColor(scaleLevel: u5) AnsiColor {
        std.debug.assert(scaleLevel <= 23);
        const value = 232 + @as(u8, scaleLevel);
        return .{ .gray = GrayScale{ .value = value } };
    }
};

pub const AnsiColorTag = enum {
    system,
    cube,
    gray,
};

pub const AnsiColor = packed union {
    system: AnsiSystemColor,
    cube: CubeColor,
    gray: GrayScale,

    pub fn init(value: u8) @This() {
        return switch (value) {
            0...15 => .{ .system = @enumFromInt(value) },
            16...231 => .{ .cube = .init(value) },
            232...255 => .{ .gray = .init(value) },
        };
    }

    // This is done separately to avoid the payload wrapping in zig
    pub fn tag(self: @This()) AnsiColorTag {
        const value = @as(u8, @bitCast(self));
        return switch (value) {
            0...15 => .system,
            16...231 => .cube,
            232...255 => .gray,
        };
    }
};

pub const AnsiCell = packed struct(u124) {
    char: u32,
    style: Style,
    fg: AnsiColor,
    fgDefault: bool,
    bg: AnsiColor,
    bgDefault: bool,
    _: u66 = 0,
};

pub const RGB = packed struct(u24) {
    // This accounts for endian-ness
    b: u8,
    g: u8,
    r: u8,
};

pub const UnderlineDecoration = enum(u3) {
    none,
    line,
    double,
    wavy,
    dotted,
    dashed,
};

pub const TrueColorCell = packed struct(u124) {
    char: u32,
    style: Style,
    fg: RGB,
    fgDefault: bool,
    bg: RGB,
    bgDefault: bool,
    underlineStyle: UnderlineDecoration,
    underline: RGB,
    underlineDefault: bool,
    _: u6 = 0,
};

pub const ImageRootCell = packed struct(u124) {
    _: u124 = 0,
};

pub const SkipCell = packed struct(u124) {
    _: u124 = 0,
};

pub const CellData = packed union {
    glyph: GlyphCell,
    ansi: AnsiCell,
    trueColor: TrueColorCell,
    imageRoot: ImageRootCell,
    skip: SkipCell,
};

// This is not a tagged union to avoid padding
pub const Cell = packed struct(u128) {
    mode: CellMode,
    data: CellData,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    return try regent.trampoline.stackTrampoline(
        @typeInfo(@TypeOf(trampMain)).@"fn".return_type.?,
        u6,
        init,
        trampMain,
        if (builtin.mode == .Debug) 3 else 1,
    );
}

pub fn trampMain(init: std.process.Init.Minimal, optStackAlloc: ?std.mem.Allocator) !u8 {
    // if we ever handle args, it's here
    _ = init;

    const allocator = if (optStackAlloc) |stackAllocator| stackAllocator else std.heap.smp_allocator;

    const stdinFd = std.Io.File.stdin().handle;
    const beforeTtyAttr = try std.posix.tcgetattr(stdinFd);
    var ttyAttr = beforeTtyAttr;

    // disablex XON/XOFF ctrl flow
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

    // since we are using epoll min is 0 (non-blocking read) and no timeout
    ttyAttr.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    ttyAttr.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(stdinFd, .FLUSH, ttyAttr);
    defer std.posix.tcsetattr(stdinFd, .FLUSH, beforeTtyAttr) catch {};

    var ev: std.Io.Evented = undefined;
    try ev.init(allocator, .{});
    const io = ev.io();

    var mask: std.posix.sigset_t = @splat(0);
    std.posix.sigaddset(&mask, linux.SIG.WINCH);
    // Block the signal from interrupting our process normally
    _ = std.posix.sigprocmask(linux.SIG.BLOCK, &mask, null);

    const sigWinchFd = try std.posix.signalfd(-1, &mask, 0);

    const sigFile: std.Io.File = .{ .handle = sigWinchFd, .flags = .{ .nonblocking = true } };
    defer sigFile.close(io);

    const stdout = std.Io.File.stdout();
    // TODO: parse ansi commands into structs
    // those are unbuffered and thats fine for now
    try stdout.writeStreamingAll(io, "\x1b[2J\x1b[H\x1b[?25l");
    defer stdout.writeStreamingAll(io, "\x1b[?25h\x1b[2J\x1b[H") catch {};

    // Everything below here is bad
    // zig stdlib doesnt handle the error set for Evented correctly on some dir apis
    // so it's also unusable outside master
    // there are a billion problems with this api, I cant pin the buffers with iouring
    // i cant pick a good buffer size for the writer considering the even queue
    // (technically that's events.len + 1 * max size of read to ensure one pop and one queue)
    // but if I decide to make the code more free-flow, I will have to me insanely careful with this
    // the code is in fact more agnostic this way and I can leverage fibers this way and not really
    // stall on a central loop that handles one event at time, but idk how good of an idea that is
    // stdout events have to block new writes to stdout
    // stdin events have to be sequential
    // sigwinch has to be handle carefully because it can change the buffer for stdout as well
    // as other things
    const UEvents = union(enum) {
        sigWinch,
        inR: anyerror!u32,
        outW,
    };

    var buff: [16]UEvents = undefined;
    var select: std.Io.Select(UEvents) = .init(io, &buff);

    const RandCopy = struct {
        pub fn read(iio: std.Io, f: std.Io.File) !u32 {
            var b: [1][]u8 = undefined;
            var c: [4]u8 = @splat(0);
            b[0] = &c;
            _ = f.readStreaming(iio, &b) catch return std.Io.Evented.PipeError.Unexpected;
            return @bitCast(c);
        }
    };

    select.async(.inR, RandCopy.read, .{ io, std.Io.File.stdin() });

    switch (try select.await()) {
        .inR => |c| {
            var bbb: [200]u8 = undefined;
            var www = stdout.writer(io, &bbb);
            try www.interface.print("C: {x}\n", .{try c});
            try www.interface.flush();
        },
        else => {},
    }

    try io.sleep(.fromSeconds(10), .awake);

    return 0;
}

const testing = std.testing;
test "Cell layout size" {
    try testing.expectEqual(16, @sizeOf(Cell));
    try testing.expectEqual(128, @bitSizeOf(Cell));
    try testing.expectEqual(124, @bitSizeOf(CellData));
}

test "CharCell mode" {
    const cell: Cell = .{
        .mode = .glyph,
        .data = .{ .glyph = .{ .value = 'A' } },
    };
    try testing.expectEqual(.glyph, cell.mode);
    try testing.expectEqual('A', cell.data.glyph.value);
}

test "AnsiCell Layout & Exact Style Bitmask" {
    const cell = Cell{
        .mode = .ansi,
        .data = .{
            .ansi = .{
                .char = 'X',
                .style = .{
                    .bold = true,
                    .underline = true,
                },
                .fg = AnsiSystemColor.brightRed.toAnsiColor(),
                .fgDefault = false,
                .bg = AnsiSystemColor.black.toAnsiColor(),
                .bgDefault = true,
            },
        },
    };

    try testing.expectEqual(@as(u8, 0x09), @as(u8, @bitCast(cell.data.ansi.style)));
    try testing.expect(cell.data.ansi.bgDefault);
}

test "AnsiCell - Flavor Tagging" {
    const cube_color = CubeColor.toAnsiColor(.{ .r = 5, .g = 2, .b = 0 });
    try testing.expectEqual(.cube, cube_color.tag());
    try testing.expectEqual(@as(u8, 208), @as(u8, @bitCast(cube_color)));

    const gray_color = GrayScale.toAnsiColor(12);
    try testing.expectEqual(.gray, gray_color.tag());
    try testing.expectEqual(@as(u8, 244), @as(u8, @bitCast(gray_color)));
}

test "TrueColorCell Full Integer Hex Blasting" {
    const cell = Cell{
        .mode = .trueColor,
        .data = .{
            .trueColor = .{
                .char = '🔥',
                .style = @bitCast(@as(u8, 0x00)),
                .fg = @bitCast(@as(u24, 0xFF6400)),
                .fgDefault = false,
                .bg = @bitCast(@as(u24, 0x000000)),
                .bgDefault = false,
                .underlineStyle = .wavy,
                .underline = @bitCast(@as(u24, 0xFFFFFF)),
                .underlineDefault = false,
            },
        },
    };

    try testing.expectEqual(@as(u8, 0xFF), cell.data.trueColor.fg.r);
    try testing.expectEqual(@as(u8, 0x64), cell.data.trueColor.fg.g);
    try testing.expectEqual(@as(u8, 0x00), cell.data.trueColor.fg.b);

    try testing.expectEqual(@as(u24, 0xFF6400), @as(u24, @bitCast(cell.data.trueColor.fg)));
    try testing.expectEqual(@as(u24, 0xFFFFFF), @as(u24, @bitCast(cell.data.trueColor.underline)));
    try testing.expectEqual(.wavy, cell.data.trueColor.underlineStyle);
}
