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

bChar: []u21,
sChar: []u21,

bStyle: []lcell.Style,
sStyle: []lcell.Style,

bFgAnsi: []lcell.FlaggedAnsiColor,
sFgAnsi: []lcell.FlaggedAnsiColor,

bBgAnsi: []lcell.FlaggedAnsiColor,
sBgAnsi: []lcell.FlaggedAnsiColor,

bFgTrue: []lcell.FlaggedTrueColor,
sFgTrue: []lcell.FlaggedTrueColor,

bBgTrue: []lcell.FlaggedTrueColor,
sBgTrue: []lcell.FlaggedTrueColor,

bUdTrue: []lcell.FlaggedTrueColor,
sUdTrue: []lcell.FlaggedTrueColor,

bUdDeco: []lcell.UnderlineDecoration,
sUdDeco: []lcell.UnderlineDecoration,

rng: std.Random.IoSource,

const alignment: std.mem.Alignment = .fromByteUnits(if (std.simd.suggestVectorLength(u8)) |L| L else 8);

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
    const idx = row * self.size.cols + col;
    assert(idx < (self.size.rows * self.size.cols));

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
        try self.writeCellAt(w, i);
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.full.serialize");

    const strictly_buffered = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.full.size" = strictly_buffered,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    // TODO: make this better
    if (strictly_buffered > 0) {
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
    const total_cells = self.size.rows * cols;

    var jumpCursor: bool = true;
    var i: usize = 0;

    // zig is annoying as hell about packed structs and sizes in vec, so this is needed
    const b_char_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bChar.ptr));
    const s_char_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sChar.ptr));

    const b_style_ptr: [*]const u8 = @ptrCast(self.bStyle.ptr);
    const s_style_ptr: [*]const u8 = @ptrCast(self.sStyle.ptr);

    const b_fg_ansi_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bFgAnsi.ptr));
    const s_fg_ansi_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sFgAnsi.ptr));

    const b_bg_ansi_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bBgAnsi.ptr));
    const s_bg_ansi_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sBgAnsi.ptr));

    const b_fg_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bFgTrue.ptr));
    const s_fg_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sFgTrue.ptr));

    const b_bg_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bBgTrue.ptr));
    const s_bg_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sBgTrue.ptr));

    const b_ud_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.bUdTrue.ptr));
    const s_ud_true_ptr: [*]align(@alignOf(u32)) const u32 = @ptrCast(@alignCast(self.sUdTrue.ptr));

    const b_deco_ptr: [*]const u8 = @ptrCast(self.bUdDeco.ptr);
    const s_deco_ptr: [*]const u8 = @ptrCast(self.sUdDeco.ptr);

    if (std.simd.suggestVectorLength(u32)) |VLen| {
        while (i + VLen <= total_cells) : (i += VLen) {
            const b_char_v: @Vector(VLen, u32) = b_char_ptr[i..][0..VLen].*;
            const s_char_v: @Vector(VLen, u32) = s_char_ptr[i..][0..VLen].*;

            const b_style_v: @Vector(VLen, u8) = b_style_ptr[i..][0..VLen].*;
            const s_style_v: @Vector(VLen, u8) = s_style_ptr[i..][0..VLen].*;

            const b_fg_ansi_v: @Vector(VLen, u32) = b_fg_ansi_ptr[i..][0..VLen].*;
            const s_fg_ansi_v: @Vector(VLen, u32) = s_fg_ansi_ptr[i..][0..VLen].*;

            const b_bg_ansi_v: @Vector(VLen, u32) = b_bg_ansi_ptr[i..][0..VLen].*;
            const s_bg_ansi_v: @Vector(VLen, u32) = s_bg_ansi_ptr[i..][0..VLen].*;

            const b_fg_true_v: @Vector(VLen, u32) = b_fg_true_ptr[i..][0..VLen].*;
            const s_fg_true_v: @Vector(VLen, u32) = s_fg_true_ptr[i..][0..VLen].*;

            const b_bg_true_v: @Vector(VLen, u32) = b_bg_true_ptr[i..][0..VLen].*;
            const s_bg_true_v: @Vector(VLen, u32) = s_bg_true_ptr[i..][0..VLen].*;

            const b_ud_true_v: @Vector(VLen, u32) = b_ud_true_ptr[i..][0..VLen].*;
            const s_ud_true_v: @Vector(VLen, u32) = s_ud_true_ptr[i..][0..VLen].*;

            const b_deco_v: @Vector(VLen, u8) = b_deco_ptr[i..][0..VLen].*;
            const s_deco_v: @Vector(VLen, u8) = s_deco_ptr[i..][0..VLen].*;

            const diff_char = b_char_v ^ s_char_v;
            const diff_style = b_style_v ^ s_style_v;
            const diff_fg_ansi = b_fg_ansi_v ^ s_fg_ansi_v;
            const diff_bg_ansi = b_bg_ansi_v ^ s_bg_ansi_v;
            const diff_fg_true = b_fg_true_v ^ s_fg_true_v;
            const diff_bg_true = b_bg_true_v ^ s_bg_true_v;
            const diff_ud_true = b_ud_true_v ^ s_ud_true_v;
            const diff_ud_deco = b_deco_v ^ s_deco_v;

            const changed: @Vector(VLen, bool) = (diff_char != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_style != @as(@Vector(VLen, u8), @splat(0))) |
                (diff_fg_ansi != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_bg_ansi != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_fg_true != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_bg_true != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_ud_true != @as(@Vector(VLen, u32), @splat(0))) |
                (diff_ud_deco != @as(@Vector(VLen, u8), @splat(0)));

            inline for (0..VLen) |idx| {
                const iIdx = i + idx;
                if (changed[idx]) {
                    if (jumpCursor) {
                        try control.moveCursor(w, iIdx / cols, iIdx % cols);
                        jumpCursor = false;
                    }
                    // TODO: style and color reset
                    try self.writeCellAt(w, iIdx);
                } else if (!jumpCursor) {
                    jumpCursor = true;
                }
            }
        }
    }

    while (i < total_cells) : (i += 1) {
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
            try self.writeCellAt(w, i);
        } else if (!jumpCursor) {
            jumpCursor = true;
        }
    }
    if (term.trace) |t| try t.popTimer(rctx, .@"grid.diff.serialize");

    const strictly_buffered = w.buffered().len;

    if (term.trace) |t| try t.metrics.append(ctx.heapAlloc, .{
        .@"grid.diff.size" = strictly_buffered,
    });

    if (term.trace) |t| try t.pushTimer(rctx);
    try w.flush();

    // TODO: make this better
    if (strictly_buffered > 0) {
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

fn writeCellAt(self: *@This(), w: *std.Io.Writer, idx: usize) !void {
    const char = self.bChar[idx];
    if (char == 0) return;

    try w.writeAll("\x1b[");

    try self.bStyle[idx].writeStyle(w);

    var needTrail: bool = false;
    const fg_ansi = self.bFgAnsi[idx];
    if (fg_ansi.toggled) {
        try fg_ansi.color.write(false, w);
        needTrail = true;
    }
    const bg_ansi = self.bBgAnsi[idx];
    if (bg_ansi.toggled) {
        if (needTrail) try w.writeByte(';');
        try bg_ansi.color.write(true, w);
        needTrail = true;
    }

    const fg_true = self.bFgTrue[idx];
    if (fg_true.toggled) {
        if (needTrail) try w.writeByte(';');
        try w.print("38;2;{d};{d};{d}", .{ fg_true.color.r, fg_true.color.g, fg_true.color.b });
        needTrail = true;
    }
    const bg_true = self.bBgTrue[idx];
    if (bg_true.toggled) {
        if (needTrail) try w.writeByte(';');
        try w.print("48;2;{d};{d};{d}", .{ bg_true.color.r, bg_true.color.g, bg_true.color.b });
        needTrail = true;
    }

    const ud_deco = self.bUdDeco[idx];
    if (ud_deco != .none) {
        if (needTrail) try w.writeByte(';');
        try w.print("4:{d};", .{@intFromEnum(ud_deco)});
        const ud_true = self.bUdTrue[idx];
        if (ud_true.toggled) {
            try w.print("58;2;{d};{d};{d}", .{ ud_true.color.r, ud_true.color.g, ud_true.color.b });
        }
    }

    try w.print("m{u}", .{char});
}
