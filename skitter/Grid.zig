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
            .int => ' ',
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

pub fn putAndSplatInRow(self: *@This(), x: usize, y: usize, comptime tag: lcell.CellMode, cell: tag.concreteType()) PutResult {
    const r = self.put(x, y, tag, cell);
    switch (r) {
        .putOne => {},
        .putMany => return r,
        .putToEndOfLine => return r,
    }

    if (self.splatCellInRow(x, y)) |pos|
        return .{ .putToEndOfLine = pos }
    else
        return .putOne;
}

pub fn splatCellInRow(self: *@This(), x: usize, y: usize) ?PutResult.Position {
    std.debug.assert(y < self.size.rows);
    if (x + 1 == self.size.cols) return null;

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

    return .{ .x = self.size.cols - 1, .y = y };
}

fn splatStyleTo(self: *@This(), idx: usize, end: usize) void {
    std.debug.assert(end <= self.bChar.len);

    const start = idx + 1;
    const fields = comptime simdFields()[2..];
    comptime var i: usize = 0;
    inline while (i < fields.len) : (i += 2) {
        @memset(
            @field(self, fields[i])[start..end],
            @field(self, fields[i])[idx],
        );
    }
}

const CharToPrint = union(enum) {
    c: u21,
    seq: []const u21,
    breakline,
    // TODO: those should be enabled by a mode
    backspace,
    del,
    // TODO: calculated relative tab spaces?
    tab,

    pub inline fn from(comptime tag: lcell.CellMode, cell: tag.concreteType()) @This() {
        const c: u21 = switch (tag) {
            .glyph => cell,
            .ansi, .trueColor => cell.char,
            .skip, .imgRoot => 0,
        };

        return switch (c) {
            0x08 => .backspace,
            '\t' => .tab,
            '\n' => .breakline,
            0x7F => .del,
            inline 0x00...0x07 => |x| .{
                .seq = &.{
                    '^',
                    @as(u8, @intCast(x)) + 0x40,
                },
            },
            inline 0x0B...0x1F => |x| .{
                .seq = &.{
                    '^',
                    @as(u8, @intCast(x)) + 0x40,
                },
            },
            else => .{ .c = c },
        };
    }

    pub fn char(self: @This()) u21 {
        return switch (self) {
            .c => self.c,
            .breakline => ' ',
            .seq => @intCast(self.seq[0]),
            // TODO: fix this, it's not a sane default for the ctrl chars
            else => ' ',
        };
    }
};

const PutResult = union(enum) {
    putOne,
    putMany: Position,
    putToEndOfLine: Position,

    pub const Position = struct {
        x: usize,
        y: usize,
    };
};

pub const PutError = error{
    OutOfBoundsInsertion,
};

pub fn putBlank(self: *@This(), x: usize, y: usize) PutError!PutResult {
    return self.put(x, y, .glyph, ' ');
}

pub fn putBreakLine(self: *@This(), x: usize, y: usize) PutError!PutResult {
    return self.put(x, y, .glyph, '\n');
}

pub fn put(self: *@This(), x: usize, y: usize, comptime tag: lcell.CellMode, cell: tag.concreteType()) PutError!PutResult {
    std.debug.assert(x < self.size.cols);
    std.debug.assert(y < self.size.rows);

    const idx = y * self.size.cols + x;

    std.debug.assert(idx < self.bChar.len);

    const cToP = CharToPrint.from(tag, cell);
    // NOTE: idx is already at seq[0], so len is -1
    if (cToP == .seq and cToP.seq.len + idx > self.bChar.len) return error.OutOfBoundsInsertion;

    switch (tag) {
        .glyph => {
            self.bChar[idx] = cToP.char();
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
            self.bChar[idx] = cToP.char();
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
            self.bChar[idx] = cToP.char();
            self.bStyle[idx] = tc.style;

            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));

            self.bFgTrue[idx] = .{ .color = tc.fg, .toggled = !tc.fgDefault };
            self.bBgTrue[idx] = .{ .color = tc.bg, .toggled = !tc.bgDefault };
            self.bUdTrue[idx] = .{ .color = tc.underline, .toggled = !tc.underlineDefault };
            self.bUdDeco[idx] = tc.underlineStyle;
        },
        .skip, .imgRoot => {
            self.bChar[idx] = cToP.char();
            self.bStyle[idx] = @bitCast(@as(u8, 0));
            self.bFgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bBgAnsi[idx] = @bitCast(@as(u9, 0));
            self.bFgTrue[idx] = @bitCast(@as(u25, 0));
            self.bBgTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdTrue[idx] = @bitCast(@as(u25, 0));
            self.bUdDeco[idx] = .none;
        },
    }

    return switch (cToP) {
        .c => .putOne,
        .breakline => r: {
            break :r if (self.splatCellInRow(x, y)) |pos|
                .{ .putToEndOfLine = pos }
            else
                .putOne;
        },
        .seq => |s| r: {
            const end = s.len + idx;
            self.splatStyleTo(idx, end);
            @memcpy(self.bChar[idx + 1 .. end], s[1 .. end - idx]);
            break :r .{ .putMany = self.idxToPos(end - 1) };
        },
        // TODO: fix this, it's not a sane default
        else => .putOne,
    };
}

fn idxToPos(self: *const @This(), i: usize) PutResult.Position {
    return .{ .x = i % self.size.cols, .y = i / self.size.cols };
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
    known: bool = false,
    x: usize = 0,
    y: usize = 0,

    pub fn save(self: *@This(), pos: PutResult.Position) void {
        self.known = true;
        self.x = pos.x;
        self.y = pos.y;
    }
};

fn resolveCellDiff(self: *@This(), fState: *FlushState, w: *std.Io.Writer, i: usize, hasDiff: bool) !void {
    if (!hasDiff) return;

    const tPos = self.idxToPos(i);

    if (fState.known and tPos.y == fState.y and tPos.x >= fState.x) {
        if (tPos.x > fState.x + 1)
            try control.forwardCursor(w, tPos.x - fState.x - 1);
    } else {
        try control.moveCursor(w, self.pos.x + tPos.x, self.pos.y + tPos.y);
    }
    fState.save(tPos);

    _ = try self.writeCellAt(w, i);
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
