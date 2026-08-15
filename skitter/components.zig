const std = @import("std");
const cell = @import("cell.zig");
const Grid = @import("Grid.zig");
const Cell = cell.Cell;
const assert = std.debug.assert;

// we will need a vtable for more complex border to not infect this
pub const SimpleBorder = struct {
    // for bottom, if this becomes a vtable caller must know how many rows are reserved
    // same applies for line start/end
    topRightCorner: Cell,
    topLeftCorner: Cell,
    bottomRightCorner: Cell,
    bottomLeftCorner: Cell,
    horizontal: Cell,
    vertical: Cell,

    // if this becomes a vtable, caller needs to know how many lines were drawn and were to jump to
    pub fn drawTop(self: *const @This(), grid: *Grid, x: usize, y: usize, cols: usize) !void {
        return self.drawEnds(.top, grid, x, y, cols);
    }

    pub fn drawBottom(self: *const @This(), grid: *Grid, x: usize, y: usize, cols: usize) !void {
        return self.drawEnds(.bottom, grid, x, y, cols);
    }

    pub const Ends = enum {
        top,
        bottom,
    };

    pub fn drawEnds(self: *const @This(), comptime end: Ends, grid: *Grid, x: usize, y: usize, cols: usize) !void {
        const leftCorner, const rightCorner = switch (end) {
            .top => .{ &self.topLeftCorner, &self.topRightCorner },
            .bottom => .{ &self.bottomLeftCorner, &self.bottomRightCorner },
        };

        var i: usize = x;
        assert((try grid.putCell(i, y, leftCorner)) == .putOne);
        i += 1;

        const r = try grid.putCellAndSplatUpTo(i, y, cols - i - 1, &self.horizontal);

        switch (r) {
            .putOne => return error.RowIsTooSmall,
            .putToEndOfLine => return error.RowIsTooSmall,
            .putMany => |pos| i = pos.x + 1,
        }

        assert((try grid.putCell(i, y, rightCorner)) == .putOne);
    }
};

pub const Box = struct {
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,

    border: ?SimpleBorder,
};
