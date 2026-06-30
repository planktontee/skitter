const std = @import("std");
const Ctx = @import("../skitter.zig").Ctx;
const assert = std.debug.assert;
const lcell = @import("cell.zig");
const Cell = lcell.Cell;
const terminal = @import("terminal.zig");
const TermSize = terminal.TermSize;
const Terminal = terminal.Terminal;
const control = @import("control.zig");

size: TermSize,
buffer: []Cell,
grid: []Cell,

pub fn init(self: *@This(), size: TermSize, ctx: *Ctx) std.mem.Allocator.Error!void {
    // TODO: redo everything related to cell to split SIMD based on SoA
    var buff = try ctx.heapAlloc.alignedAlloc(Cell, .fromByteUnits(4096), size.rows * size.cols * 2);
    @memset(buff, @as(Cell, @bitCast(@as(u128, 0))));

    self.buffer = buff[0 .. buff.len / 2];
    self.grid = buff[buff.len / 2 ..];

    self.size = size;
}

pub fn deinit(self: *@This(), ctx: *Ctx) void {
    self.buffer.len *= 2;
    ctx.heapAlloc.free(self.buffer);
}

pub fn putCell(self: *@This(), row: usize, col: usize, cell: Cell) void {
    assert((row * self.size.cols + col) < self.buffer.len);
    self.buffer[row * self.size.cols + col] = cell;
}

pub const FlushError = error{
    TBA,
} || std.Io.Writer.Error;

pub fn fullFlush(self: *@This(), term: *Terminal) FlushError!void {
    const w: *std.Io.Writer = &term.fsOut.stream.interface;

    try control.moveCursor(w, 0, 0);

    for (self.buffer) |*cell| {
        switch (cell.mode) {
            .glyph => try w.print("{u}", .{@as(u21, @intCast(cell.data.glyph.value))}),
            .ansi => {
                try w.writeAll("\x1b[");
                try cell.data.ansi.style.writeStyle(w);
                try cell.data.ansi.fg.write(false, w);
                try w.writeByte(';');
                try cell.data.ansi.bg.write(true, w);

                try w.print("m{u}", .{
                    @as(u21, @intCast(cell.data.ansi.char)),
                });
            },
            .skip => {},
            else => return error.TBA,
        }
    }

    try w.flush();
    @memcpy(self.grid, self.buffer);
}

pub fn flush(self: *@This(), term: *Terminal) FlushError!void {
    // return self.fullFlush(term);

    const w: *std.Io.Writer = &term.fsOut.stream.interface;

    const cols = self.size.cols;

    var jumpCursor: bool = true;
    var i: usize = 0;

    if (std.simd.suggestVectorLength(Cell)) |VLen| {
        const V = @Vector(VLen, u128);

        if (self.buffer.len >= VLen) {
            while (i + VLen < self.buffer.len) : (i += VLen) {
                const buffered: V = @bitCast(self.buffer[i..][0..VLen].*);
                const inGrid: V = @bitCast(self.grid[i..][0..VLen].*);

                const diff: V = buffered ^ inGrid;

                inline for (0..VLen) |idx| {
                    if (diff[idx] != 0) {
                        const iIdx = i + idx;
                        if (jumpCursor) {
                            const x = iIdx / cols;
                            const y = iIdx % cols;
                            try control.moveCursor(w, x, y);

                            jumpCursor = false;
                        }
                        const cell: *const Cell = &self.buffer[iIdx];
                        switch (cell.mode) {
                            .glyph => try w.print("{u}", .{@as(u21, @intCast(cell.data.glyph.value))}),
                            .ansi => {
                                try w.writeAll("\x1b[");
                                try cell.data.ansi.style.writeStyle(w);
                                try cell.data.ansi.fg.write(false, w);
                                try w.writeByte(';');
                                try cell.data.ansi.bg.write(true, w);

                                try w.print("m{u}", .{
                                    @as(u21, @intCast(cell.data.ansi.char)),
                                });
                            },
                            .skip => {},
                            else => return error.TBA,
                        }
                    } else if (!jumpCursor) {
                        jumpCursor = true;
                    }
                }
            }
        }
    }

    while (i < self.buffer.len) : (i += 1) {
        const buffered: u128 = @bitCast(self.buffer[i]);
        const inGrid: u128 = @bitCast(self.grid[i]);

        if (buffered ^ inGrid != 0) {
            if (jumpCursor) {
                const x = i / cols;
                const y = i % cols;
                try control.moveCursor(w, x, y);

                jumpCursor = false;
            }
            const cell: Cell = @bitCast(buffered);
            switch (cell.mode) {
                .glyph => try w.print("{u}", .{@as(u21, @intCast(cell.data.glyph.value))}),
                .ansi => {
                    try w.writeAll("\x1b[");
                    try cell.data.ansi.style.writeStyle(w);

                    try w.print("{d};{d}m{u}", .{
                        @as(u8, @bitCast(cell.data.ansi.fg)),
                        @as(u8, @bitCast(cell.data.ansi.bg)),
                        @as(u21, @intCast(cell.data.ansi.char)),
                    });
                },
                .skip => {},
                else => return error.TBA,
            }
        } else if (!jumpCursor) {
            jumpCursor = true;
        }
    }

    const fold: bool = w.buffered().len > 0;
    try w.flush();
    if (fold) @memcpy(self.grid, self.buffer);
}
