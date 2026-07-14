const std = @import("std");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");

pub const PutResult = enum {
    forwarded,
    nextLine,
    overflow,
};

pub const GridCursor = struct {
    grid: *Grid,
    x: usize = 0,
    y: usize = 0,

    pub fn toLastRow(self: *@This()) void {
        self.y = self.grid.size.rows - 1;
        self.x = 0;
    }

    fn wrap(self: *@This()) bool {
        if (self.x == self.grid.size.cols) {
            self.x = 0;
            self.y += 1;
            return true;
        }
        return false;
    }

    pub fn putChar(self: *@This(), c: u21) PutResult {
        // TODO: there's a bug here in case the cols are too small and cant fit a sequence translation
        // and we end up going into overflow loop if c is not dropped at the caller level
        if (self.y >= self.grid.size.rows) return .overflow;

        const putR = self.grid.put(self.x, self.y, .glyph, c) catch |e| switch (e) {
            error.OutOfBoundsInsertion => {
                _ = self.grid.putBlank(self.x, self.y) catch {};
                self.y += 1;
                self.x = 0;
                return .overflow;
            },
        };

        return switch (putR) {
            .putOne => r: {
                self.x += 1;
                break :r if (self.wrap()) .nextLine else .forwarded;
            },
            .putMany => |pos| r: {
                self.x = pos.x + 1;
                self.y = pos.y;
                break :r if (self.wrap()) .nextLine else .forwarded;
            },
            .putToEndOfLine => |pos| r: {
                self.x = pos.x + 1;
                const wrapped = self.wrap();
                std.debug.assert(wrapped);
                break :r .nextLine;
            },
        };
    }
};

pub fn run(ctx: *Ctx, grid: *Grid, term: *Terminal, fPath: ?[]const []const u8) !void {
    const path = if (fPath) |p|
        p[0]
    else
        "-";

    var fc = regent.fs.FileCursor(.read).init(&.{path});
    defer fc.deinit();

    const context: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };

    var fs = (try fc.next(context)) orelse return;
    defer {
        fs.deinit(context);
        fs.close(context);
    }
    const r = &fs.stream.interface;

    var charCursor: regent.fs.Utf8Cursor = .{ .reader = r };
    var gridCursor: GridCursor = .{ .grid = grid };

    var char: ?u21 = null;
    loop: while (Terminal.isRunning()) {
        if (char == null) {
            char = r: {
                while (true) break :r charCursor.next() catch continue orelse break :loop;
            };
        }

        switch (gridCursor.putChar(char.?)) {
            .forwarded => char = null,
            .nextLine => {
                try grid.flush(ctx, term);
                char = null;
            },
            .overflow => {
                grid.scrollUp();
                gridCursor.toLastRow();
            },
        }
    }
}
