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
pos: terminal.Pos,
trueSize: TermSize,

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

state: lcell.CellFmt = .{},

const alignmentBytes = if (std.simd.suggestVectorLength(u8)) |L| L else 8;
const alignment: std.mem.Alignment = .fromByteUnits(alignmentBytes);

fn simdFields() []const []const u8 {
    return &.{
        "bChar",
        "sChar",

        "bStyle",
        "sStyle",

        "bFgAnsi",
        "sFgAnsi",

        "bBgAnsi",
        "sBgAnsi",

        "bFgTrue",
        "sFgTrue",

        "bBgTrue",
        "sBgTrue",

        "bUdTrue",
        "sUdTrue",

        "bUdDeco",
        "sUdDeco",
    };
}

pub fn init(self: *@This(), pos: terminal.Pos, size: TermSize, ctx: *Ctx) std.mem.Allocator.Error!void {
    self.size = size;
    self.pos = pos;

    const targetSize: usize = size.rows * size.cols;

    inline for (comptime simdFields()) |fieldName| {
        const T = @FieldType(@This(), fieldName);
        const PtrType = @typeInfo(T).pointer.child;
        const PtrTypeInfo = @typeInfo(PtrType);
        @field(self, fieldName) = try ctx.heapAlloc.alignedAlloc(PtrType, alignment, targetSize);
        @memset(@field(self, fieldName), switch (PtrTypeInfo) {
            .int => 0,
            .@"enum" => @enumFromInt(0),
            .@"struct" => @bitCast(@as(PtrTypeInfo.@"struct".backing_integer.?, 0)),
            else => unreachable,
        });
    }

    self.rng = std.Random.IoSource{ .io = ctx.io };
}

pub fn deinit(self: *@This(), ctx: *Ctx) void {
    inline for (comptime simdFields()) |fieldName| {
        ctx.heapAlloc.free(@field(self, fieldName));
    }
}

pub fn scrollUp(self: *@This()) void {
    const fields = comptime simdFields();
    comptime var i: usize = 0;
    const targetSize = self.size.cols * self.size.rows - self.size.cols;
    inline while (i < fields.len) : (i += 2) {
        @memmove(
            @field(self, fields[i])[0..targetSize],
            @field(self, fields[i])[self.size.cols..],
        );
    }
}

pub fn splatRow(self: *@This(), x: usize, y: usize, comptime tag: lcell.CellMode, cell: tag.concreteType()) void {
    std.debug.assert(x < self.size.cols);
    self.put(x, y, tag, cell);

    if (x + 1 == self.size.cols) return;

    const idx = y * self.size.cols + x;
    const start = idx + 1;
    const end = (y + 1) * self.size.cols;
    const fields = comptime simdFields();
    comptime var i: usize = 0;
    inline while (i < fields.len) : (i += 2) {
        @memset(
            @field(self, fields[i])[start..end],
            @field(self, fields[i])[idx],
        );
    }
}

// NOTE: putCell may be necessary in the future in case I want to support tags that are runtime
// computed
pub fn put(self: *@This(), x: usize, y: usize, comptime tag: lcell.CellMode, cell: tag.concreteType()) void {
    if (y >= self.size.rows or x >= self.size.cols) return;
    const idx = y * self.size.cols + x;

    // Every mode uses the character slot (except skip/imageRoot padding)
    // We extract it dynamically or fall back to 0
    switch (tag) {
        .glyph => {
            self.bChar[idx] = @as(u21, cell);
            self.bStyle[idx] = @bitCast(@as(u8, 0));
            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bFgTrue[idx] = @bitCast(@as(u25, 0));
            self.bBgTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdDeco[idx] = .none;
        },
        .ansi => {
            const ansi = @as(lcell.AnsiCell, cell);
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
            const tc = @as(lcell.TrueColorCell, cell);
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

pub fn commit(self: *@This()) void {
    comptime var i: usize = 0;
    const fields = comptime simdFields();
    inline while (comptime i < fields.len) : (i += 2) {
        @memcpy(@field(self, fields[i + 1]), @field(self, fields[i]));
    }
}

pub fn fullFlush(self: *@This(), ctx: *Ctx, term: *Terminal) FlushError!void {
    const w: *std.Io.Writer = &term.fsOut.stream.interface;

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    if (term.trace) |t| try t.pushTimer(rctx);
    try control.moveCursor(w, self.pos.x, self.pos.y);
    var line: usize = 0;
    for (0..self.size.rows * self.size.cols) |i| {
        if (i / self.size.cols > line) {
            try w.writeAll(control.moveToNextLine());
            line += 1;
        }
        _ = try self.writeCellAt(w, i);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.full.serialize");

    const bufferedLen = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.full.size" = bufferedLen,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    if (bufferedLen > 0) self.commit();
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.full.flush");
}

const FlushState = struct {
    line: usize = 0,
    jumpCursor: bool = true,
};

fn resolveCellDiff(self: *@This(), fState: *FlushState, w: *std.Io.Writer, i: usize, hasDiff: bool) !void {
    if (fState.line != i / self.size.cols) fState.jumpCursor = true;
    if (hasDiff) {
        if (fState.jumpCursor) {
            try control.moveCursor(
                w,
                self.pos.x + (i % self.size.cols),
                self.pos.y + (i / self.size.cols),
            );
            fState.jumpCursor = false;
            fState.line = i / self.size.cols;
        }
        if (!try self.writeCellAt(w, i)) fState.jumpCursor = true;
    } else if (!fState.jumpCursor) {
        fState.jumpCursor = true;
    }
}

pub fn flush(self: *@This(), ctx: *Ctx, term: *Terminal) FlushError!void {
    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.buffer.size" = self.size.rows * self.size.rows,
    });

    // This is here for comparison at the moment
    if (self.rng.interface().float(f32) >= 0.5) {
        return self.fullFlush(ctx, term);
    }

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    if (term.trace) |t| try t.pushTimer(rctx);

    const w: *std.Io.Writer = &term.fsOut.stream.interface;
    const totalCells = self.size.rows * self.size.cols;

    var fState: FlushState = .{};
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

            inline for (0..VLen) |vecIdx| {
                try self.resolveCellDiff(&fState, w, i + vecIdx, changed[vecIdx]);
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

        try self.resolveCellDiff(&fState, w, i, has_diff);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.diff.serialize");

    const bufferedLen = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.diff.size" = bufferedLen,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    if (bufferedLen > 0) self.commit();
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.diff.flush");
}

fn toCellFmt(self: *const @This(), target: *lcell.CellFmt, idx: usize) void {
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
    target.udColor = if (self.bUdTrue[idx].toggled) .{
        .rgb = self.bUdTrue[idx].color,
    } else .none;
}

fn writeCellAt(self: *@This(), w: *std.Io.Writer, idx: usize) !bool {
    const char = self.bChar[idx];
    if (char == 0) return false;

    const from = self.state;
    var newFmt: lcell.CellFmt = undefined;
    self.toCellFmt(&newFmt, idx);
    const to: *const lcell.CellFmt = &newFmt;

    try to.writeCharWithDiff(w, &from, char);
    self.state = newFmt;
    return true;
}
