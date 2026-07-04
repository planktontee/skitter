const std = @import("std");
const Ctx = @import("../skitter.zig").Ctx;
const assert = std.debug.assert;
const lcell = @import("cell.zig");
const Cell = lcell.Cell;
const terminal = @import("terminal.zig");
const TermSize = terminal.TermSize;
const Terminal = terminal.Terminal;
const control = @import("control.zig");
const regent = @import("regent");

size: TermSize,

bChar: []align(alignmentBytes) u21,
sChar: []align(alignmentBytes) u21,

bStyle: []align(alignmentBytes) lcell.Style,
sStyle: []align(alignmentBytes) lcell.Style,

bFgAnsi: []align(alignmentBytes) lcell.FlaggedAnsiColor,
sFgAnsi: []align(alignmentBytes) lcell.FlaggedAnsiColor,

bBgAnsi: []align(alignmentBytes) lcell.FlaggedAnsiColor,
sBgAnsi: []align(alignmentBytes) lcell.FlaggedAnsiColor,

bFgTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,
sFgTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,

bBgTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,
sBgTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,

bUdTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,
sUdTrue: []align(alignmentBytes) lcell.FlaggedTrueColor,

bUdDeco: []align(alignmentBytes) lcell.UnderlineDecoration,
sUdDeco: []align(alignmentBytes) lcell.UnderlineDecoration,

rng: std.Random.IoSource,

state: CellFmt = .{},

const FmtColor = union(enum) {
    default,
    ansi: lcell.AnsiColor,
    rgb: lcell.RGB,

    fn eql(a: @This(), b: @This()) bool {
        if (@as(std.meta.Tag(@This()), a) != @as(std.meta.Tag(@This()), b)) return false;
        return switch (a) {
            .default => true,
            .ansi => |c| @as(u8, @bitCast(c)) == @as(u8, @bitCast(b.ansi)),
            .rgb => |c| @as(u24, @bitCast(c)) == @as(u24, @bitCast(b.rgb)),
        };
    }
};

const CellFmt = struct {
    style: lcell.Style = @bitCast(@as(u8, 0)),
    fg: FmtColor = .default,
    bg: FmtColor = .default,
    udDeco: lcell.UnderlineDecoration = .none,
    // Since ansi doesnt support this we get away with optional
    udColor: ?lcell.RGB = null,

    fn eql(a: *const @This(), b: *const @This()) bool {
        return a.fg.eql(b.fg) and
            a.bg.eql(b.bg) and
            @as(u8, @bitCast(a.style)) == @as(u8, @bitCast(b.style)) and
            a.udDeco == b.udDeco and
            if (a.udColor) |aUdC|
                if (b.udColor) |bUdC|
                    @as(u24, @bitCast(aUdC)) == @as(u24, @bitCast(bUdC))
                else
                    false
            else
                b.udColor == null;
    }
};

fn toCellFmt(self: *const @This(), target: *CellFmt, idx: usize) void {
    target.style = self.bStyle[idx];
    target.fg = if (self.bFgAnsi[idx].toggled) .{
        .ansi = self.bFgAnsi[idx].color,
    } else if (self.bFgTrue[idx].toggled) .{
        .rgb = self.bFgTrue[idx].color,
    } else .default;
    target.bg = if (self.bBgAnsi[idx].toggled) .{
        .ansi = self.bBgAnsi[idx].color,
    } else if (self.bBgTrue[idx].toggled) .{
        .rgb = self.bBgTrue[idx].color,
    } else .default;
    target.udDeco = self.bUdDeco[idx];
    target.udColor = if (self.bUdTrue[idx].toggled) self.bUdTrue[idx].color else null;
}

const alignmentBytes = if (std.simd.suggestVectorLength(u8)) |L| L else 8;
const alignment: std.mem.Alignment = .fromByteUnits(alignmentBytes);

pub fn init(self: *@This(), size: TermSize, ctx: *Ctx) std.mem.Allocator.Error!void {
    self.size = size;
    const targetSize: usize = size.rows * size.cols;

    self.bChar = try ctx.heapAlloc.alignedAlloc(u21, alignment, targetSize);
    @memset(self.bChar, 0);
    self.sChar = try ctx.heapAlloc.alignedAlloc(u21, alignment, targetSize);
    @memset(self.sChar, 0);

    self.bStyle = try ctx.heapAlloc.alignedAlloc(lcell.Style, alignment, targetSize);
    @memset(self.bStyle, @as(lcell.Style, @bitCast(@as(u8, 0))));
    self.sStyle = try ctx.heapAlloc.alignedAlloc(lcell.Style, alignment, targetSize);
    @memset(self.sStyle, @as(lcell.Style, @bitCast(@as(u8, 0))));

    self.bFgAnsi = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedAnsiColor, alignment, targetSize);
    @memset(self.bFgAnsi, @as(lcell.FlaggedAnsiColor, @bitCast(@as(u9, 0))));
    self.sFgAnsi = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedAnsiColor, alignment, targetSize);
    @memset(self.sFgAnsi, @as(lcell.FlaggedAnsiColor, @bitCast(@as(u9, 0))));
    self.bBgAnsi = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedAnsiColor, alignment, targetSize);
    @memset(self.bBgAnsi, @as(lcell.FlaggedAnsiColor, @bitCast(@as(u9, 0))));
    self.sBgAnsi = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedAnsiColor, alignment, targetSize);
    @memset(self.sBgAnsi, @as(lcell.FlaggedAnsiColor, @bitCast(@as(u9, 0))));

    self.bFgTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.bFgTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));
    self.sFgTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.sFgTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));
    self.bBgTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.bBgTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));
    self.sBgTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.sBgTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));
    self.bUdTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.bUdTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));
    self.sUdTrue = try ctx.heapAlloc.alignedAlloc(lcell.FlaggedTrueColor, alignment, targetSize);
    @memset(self.sUdTrue, @as(lcell.FlaggedTrueColor, @bitCast(@as(u25, 0))));

    self.bUdDeco = try ctx.heapAlloc.alignedAlloc(lcell.UnderlineDecoration, alignment, targetSize);
    @memset(self.bUdDeco, .none);
    self.sUdDeco = try ctx.heapAlloc.alignedAlloc(lcell.UnderlineDecoration, alignment, targetSize);
    @memset(self.sUdDeco, .none);

    self.rng = std.Random.IoSource{ .io = ctx.io };
}

pub fn deinit(self: *@This(), ctx: *Ctx) void {
    ctx.heapAlloc.free(self.bChar);
    ctx.heapAlloc.free(self.sChar);
    ctx.heapAlloc.free(self.bStyle);
    ctx.heapAlloc.free(self.sStyle);
    ctx.heapAlloc.free(self.bFgAnsi);
    ctx.heapAlloc.free(self.sFgAnsi);
    ctx.heapAlloc.free(self.bBgAnsi);
    ctx.heapAlloc.free(self.sBgAnsi);
    ctx.heapAlloc.free(self.bFgTrue);
    ctx.heapAlloc.free(self.sFgTrue);
    ctx.heapAlloc.free(self.bBgTrue);
    ctx.heapAlloc.free(self.sBgTrue);
    ctx.heapAlloc.free(self.bUdTrue);
    ctx.heapAlloc.free(self.sUdTrue);
    ctx.heapAlloc.free(self.bUdDeco);
    ctx.heapAlloc.free(self.sUdDeco);
}

pub fn putCell(self: *@This(), row: usize, col: usize, cell: lcell.Cell) void {
    if (row >= self.size.rows or col >= self.size.cols) return;
    const idx = row * self.size.cols + col;

    // Every mode uses the character slot (except skip/imageRoot padding)
    // We extract it dynamically or fall back to 0
    switch (cell.mode) {
        .glyph => {
            self.bChar[idx] = cell.data.glyph.char;
            self.bStyle[idx] = @bitCast(@as(u8, 0));
            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bFgTrue[idx] = @bitCast(@as(u25, 0));
            self.bBgTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdDeco[idx] = .none;
        },
        .ansi => {
            const ansi = cell.data.ansi;
            self.bChar[idx] = ansi.char;
            self.bStyle[idx] = ansi.style;

            self.bFgAnsi[idx] = .{ .color = ansi.fg, .toggled = !ansi.fgDefault };
            self.bBgAnsi[idx] = .{ .color = ansi.bg, .toggled = !ansi.bgDefault };

            self.bFgTrue[idx] = @bitCast(@as(u25, 0));
            self.bBgTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdDeco[idx] = .none;
        },
        .trueColor => {
            const tc = cell.data.trueColor;
            self.bChar[idx] = tc.char;
            self.bStyle[idx] = tc.style;

            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));

            self.bFgTrue[idx] = .{ .color = tc.fg, .toggled = !tc.fgDefault };
            self.bBgTrue[idx] = .{ .color = tc.bg, .toggled = !tc.bgDefault };
            self.bUdTrue[idx] = .{ .color = tc.underline, .toggled = !tc.underlineDefault };
            self.bUdDeco[idx] = tc.underlineStyle;
        },
        .skip, .imgRoot => {
            self.bChar[idx] = 0;
            self.bStyle[idx] = @bitCast(@as(u8, 0));
            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bFgTrue[idx] = @bitCast(@as(u25, 0));
            self.bBgTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdDeco[idx] = .none;
        },
    }
}
pub const FlushError = error{
    TBA,
} || std.Io.Writer.Error || anyerror;

pub fn fullFlush(self: *@This(), ctx: *Ctx, term: *Terminal) FlushError!void {
    const w: *std.Io.Writer = &term.fsOut.stream.interface;

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    if (term.trace) |t| try t.pushTimer(rctx);
    try control.moveCursor(w, 0, 0);
    for (0..self.size.rows * self.size.cols) |i| {
        _ = try self.writeCellAt(w, i);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.full.serialize");

    const bufferedLen = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.full.size" = bufferedLen,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    // TODO: make this better
    if (bufferedLen > 0) {
        @memcpy(self.sChar, self.bChar);
        @memcpy(self.sStyle, self.bStyle);
        @memcpy(self.sFgAnsi, self.bFgAnsi);
        @memcpy(self.sBgAnsi, self.bBgAnsi);
        @memcpy(self.sFgTrue, self.bFgTrue);
        @memcpy(self.sBgTrue, self.bBgTrue);
        @memcpy(self.sUdTrue, self.bUdTrue);
        @memcpy(self.sUdDeco, self.bUdDeco);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.full.flush");
}

pub fn flush(self: *@This(), ctx: *Ctx, term: *Terminal) FlushError!void {
    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.buffer.size" = self.size.rows * self.size.rows,
    });

    if (self.rng.interface().float(f32) >= 0.5) {
        return self.fullFlush(ctx, term);
    }

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    if (term.trace) |t| try t.pushTimer(rctx);

    const w: *std.Io.Writer = &term.fsOut.stream.interface;
    const cols = self.size.cols;
    const totalCells = self.size.rows * cols;

    var jumpCursor: bool = true;
    var i: usize = 0;

    // zig is annoying as hell about packed structs and sizes in vec, so this is needed
    const bCharPtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bChar.ptr));
    const sCharPtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sChar.ptr));

    const bStylePtr: [*]const u8 = @ptrCast(self.bStyle.ptr);
    const sStylePtr: [*]const u8 = @ptrCast(self.sStyle.ptr);

    const bFgAnsiPtr: [*]align(@alignOf(u16)) const u16 = @ptrCast(@alignCast(self.bFgAnsi.ptr));
    const sFgAnsiPtr: [*]align(@alignOf(u16)) const u16 = @ptrCast(@alignCast(self.sFgAnsi.ptr));

    const bBgAnsiPtr: [*]align(@alignOf(u16)) const u16 = @ptrCast(@alignCast(self.bBgAnsi.ptr));
    const sBgAnsiPtr: [*]align(@alignOf(u16)) const u16 = @ptrCast(@alignCast(self.sBgAnsi.ptr));

    const bFgTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bFgTrue.ptr));
    const sFgTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sFgTrue.ptr));

    const bBgTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bBgTrue.ptr));
    const sBgTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sBgTrue.ptr));

    const bUdTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bUdTrue.ptr));
    const sUdTruePtr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sUdTrue.ptr));

    const bDecoPtr: [*]const u8 = @ptrCast(self.bUdDeco.ptr);
    const sDecoPtr: [*]const u8 = @ptrCast(self.sUdDeco.ptr);

    if (std.simd.suggestVectorLength(u32)) |VLen| {
        while (i + VLen <= totalCells) : (i += VLen) {
            const bCharV: @Vector(VLen, u32) = bCharPtr[i..][0..VLen].*;
            const sCharV: @Vector(VLen, u32) = sCharPtr[i..][0..VLen].*;

            const bStyleV: @Vector(VLen, u8) = bStylePtr[i..][0..VLen].*;
            const sStyleV: @Vector(VLen, u8) = sStylePtr[i..][0..VLen].*;

            const bFgAnsiV: @Vector(VLen, u16) = bFgAnsiPtr[i..][0..VLen].*;
            const sFgAnsiV: @Vector(VLen, u16) = sFgAnsiPtr[i..][0..VLen].*;

            const bBgAnsiV: @Vector(VLen, u16) = bBgAnsiPtr[i..][0..VLen].*;
            const sBgAnsiV: @Vector(VLen, u16) = sBgAnsiPtr[i..][0..VLen].*;

            const bFgTrueV: @Vector(VLen, u32) = bFgTruePtr[i..][0..VLen].*;
            const sFgTrueV: @Vector(VLen, u32) = sFgTruePtr[i..][0..VLen].*;

            const bBgTrueV: @Vector(VLen, u32) = bBgTruePtr[i..][0..VLen].*;
            const sBgTrueV: @Vector(VLen, u32) = sBgTruePtr[i..][0..VLen].*;

            const bUdTrueV: @Vector(VLen, u32) = bUdTruePtr[i..][0..VLen].*;
            const sUdTrueV: @Vector(VLen, u32) = sUdTruePtr[i..][0..VLen].*;

            const bDecoV: @Vector(VLen, u8) = bDecoPtr[i..][0..VLen].*;
            const sDecoV: @Vector(VLen, u8) = sDecoPtr[i..][0..VLen].*;

            const diffChar = bCharV ^ sCharV;
            const diffStyle = bStyleV ^ sStyleV;
            const diffFgAnsi = bFgAnsiV ^ sFgAnsiV;
            const diffBgAnsi = bBgAnsiV ^ sBgAnsiV;
            const diffFgTrue = bFgTrueV ^ sFgTrueV;
            const diffBgTrue = bBgTrueV ^ sBgTrueV;
            const diffUdTrue = bUdTrueV ^ sUdTrueV;
            const diffUdDeco = bDecoV ^ sDecoV;

            const changed: @Vector(VLen, bool) = (diffChar != @as(@Vector(VLen, u32), @splat(0))) |
                (diffStyle != @as(@Vector(VLen, u8), @splat(0))) |
                (diffFgAnsi != @as(@Vector(VLen, u16), @splat(0))) |
                (diffBgAnsi != @as(@Vector(VLen, u16), @splat(0))) |
                (diffFgTrue != @as(@Vector(VLen, u32), @splat(0))) |
                (diffBgTrue != @as(@Vector(VLen, u32), @splat(0))) |
                (diffUdTrue != @as(@Vector(VLen, u32), @splat(0))) |
                (diffUdDeco != @as(@Vector(VLen, u8), @splat(0)));

            inline for (0..VLen) |idx| {
                const iIdx = i + idx;
                if (changed[idx]) {
                    if (jumpCursor) {
                        try control.moveCursor(w, iIdx / cols, iIdx % cols);
                        jumpCursor = false;
                    }
                    if (!try self.writeCellAt(w, iIdx)) jumpCursor = true;
                } else if (!jumpCursor) {
                    jumpCursor = true;
                }
            }
        }
    }

    while (i < totalCells) : (i += 1) {
        const has_diff = (self.bChar[i] != self.sChar[i]) or
            (@as(u8, @bitCast(self.bStyle[i])) != @as(u8, @bitCast(self.sStyle[i]))) or
            (@as(u9, @bitCast(self.bFgAnsi[i])) != @as(u9, @bitCast(self.sFgAnsi[i]))) or
            (@as(u9, @bitCast(self.bBgAnsi[i])) != @as(u9, @bitCast(self.sBgAnsi[i]))) or
            (@as(u25, @bitCast(self.bFgTrue[i])) != @as(u25, @bitCast(self.sFgTrue[i]))) or
            (@as(u25, @bitCast(self.bBgTrue[i])) != @as(u25, @bitCast(self.sBgTrue[i]))) or
            (@as(u25, @bitCast(self.bUdTrue[i])) != @as(u25, @bitCast(self.sUdTrue[i]))) or
            (self.bUdDeco[i] != self.sUdDeco[i]);

        if (has_diff) {
            if (jumpCursor) {
                try control.moveCursor(w, i / cols, i % cols);
                jumpCursor = false;
            }
            if (!try self.writeCellAt(w, i)) jumpCursor = true;
        } else if (!jumpCursor) {
            jumpCursor = true;
        }
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.diff.serialize");

    const bufferedLen = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.diff.size" = bufferedLen,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    // TODO: make this better
    if (bufferedLen > 0) {
        @memcpy(self.sChar, self.bChar);
        @memcpy(self.sStyle, self.bStyle);
        @memcpy(self.sFgAnsi, self.bFgAnsi);
        @memcpy(self.sBgAnsi, self.bBgAnsi);
        @memcpy(self.sFgTrue, self.bFgTrue);
        @memcpy(self.sBgTrue, self.bBgTrue);
        @memcpy(self.sUdTrue, self.bUdTrue);
        @memcpy(self.sUdDeco, self.bUdDeco);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.diff.flush");
}

fn writeCellAt(self: *@This(), w: *std.Io.Writer, idx: usize) !bool {
    const char = self.bChar[idx];
    if (char == 0) return false;

    const from = self.state;
    var newFmt: CellFmt = undefined;
    self.toCellFmt(&newFmt, idx);
    const to: *const CellFmt = &newFmt;

    var seq: control.TermSeq = .{};

    const lhStyle = from.style;
    const rhStyle = to.style;

    // TODO: move this inside CellFmt or cell.Style
    // bold and dim share the same turnoff code (22)
    // further turn-ons need to be done after
    const boldOff = lhStyle.bold and !rhStyle.bold;
    const dimOff = lhStyle.dim and !rhStyle.dim;
    if (boldOff or dimOff) {
        try seq.write(w, "22");
        if (rhStyle.bold) try seq.writeByte(w, '1');
        if (rhStyle.dim) try seq.writeByte(w, '2');
    } else {
        if (!lhStyle.bold and rhStyle.bold) try seq.writeByte(w, '1');
        if (!lhStyle.dim and rhStyle.dim) try seq.writeByte(w, '2');
    }

    // TODO: move this to inside Style
    inline for (.{
        .{ "italic", '3', "23" },
        .{ "underline", '4', "24" },
        .{ "blink", '5', "25" },
        .{ "reverseColors", '7', "27" },
        .{ "hidden", '8', "28" },
        .{ "strike", '9', "29" },
    }) |spec| {
        const field = spec.@"0";
        const on = spec.@"1";
        const off = spec.@"2";

        if (@field(lhStyle, field) and !@field(rhStyle, field))
            try seq.write(w, off)
        else if (!@field(lhStyle, field) and @field(rhStyle, field))
            try seq.writeByte(w, on);
    }

    if (!from.fg.eql(to.fg)) {
        switch (to.fg) {
            .default => try seq.write(w, "39"),
            .ansi => |c| {
                try seq.nextToken(w);
                try c.write(false, w);
            },
            .rgb => |c| try seq.print(w, "38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        }
    }

    if (!from.bg.eql(to.bg)) {
        switch (to.bg) {
            .default => try seq.write(w, "49"),
            .ansi => |c| {
                try seq.nextToken(w);
                try c.write(true, w);
            },
            .rgb => |c| try seq.print(w, "48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        }
    }

    if (from.udDeco != to.udDeco)
        if (to.udDeco == .none)
            try seq.write(w, "4:0")
        else
            try seq.print(w, "4:{d}", .{@intFromEnum(to.udDeco)});

    if (if (from.udColor) |fC|
        if (to.udColor) |tC|
            @as(u24, @bitCast(fC)) != @as(u24, @bitCast(tC))
        else
            true
    else
        to.udColor != null)
        if (to.udColor) |c|
            try seq.print(w, "58;2;{d};{d};{d}", .{ c.r, c.g, c.b })
        else
            try seq.write(w, "58");

    try seq.finish(w);

    self.state = newFmt;
    try w.print("{u}", .{char});

    return true;
}
