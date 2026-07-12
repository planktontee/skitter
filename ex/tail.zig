const std = @import("std");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");

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

    var cursor: regent.fs.Utf8Cursor = .{ .reader = r };

    // first pass fils the grid
    var y: usize = 0;
    var cacheC: ?u21 = null;
    while (y < term.size.rows) : (y += 1) {
        var x: usize = 0;
        while (x < term.size.cols) : (x += 1) {
            const putR =
                if (cacheC) |c| r: {
                    cacheC = null;
                    break :r try grid.put(x, y, .glyph, c);
                } else if (v: {
                    while (true) break :v cursor.next() catch continue;
                }) |c|
                    grid.put(x, y, .glyph, c) catch |e| switch (e) {
                        error.OutOfBoundsInsertion => {
                            _ = grid.putBlank(x, y) catch {};
                            cacheC = c;
                            break;
                        },
                    }
                else
                    try grid.putBreakLine(x, y);

            switch (putR) {
                .putOne, .skipped => {},
                .putMany => |pos| {
                    x = pos.x;
                    defer y = pos.y;
                    if (y != pos.y) break;
                },
                .putToEndOfLine => break,
            }
        }
        try grid.flush(ctx, term);
    }

    // further passes shift
    tail: while (Terminal.isRunning()) {
        var needScroll: bool = true;
        var x: usize = 0;
        while (x < term.size.cols) : (x += 1) {
            y = term.size.rows - 1;

            const c = if (cacheC) |c| r: {
                cacheC = null;
                break :r c;
            } else v: {
                while (true) break :v cursor.next() catch continue orelse break :tail;
            };
            if (needScroll) {
                needScroll = false;
                grid.scrollUp();
            }

            const putR = grid.put(x, y, .glyph, c) catch |e| switch (e) {
                error.OutOfBoundsInsertion => {
                    _ = grid.putBlank(x, y) catch {};
                    cacheC = c;
                    break;
                },
            };

            switch (putR) {
                .putOne, .skipped => {},
                .putMany => |pos| {
                    x = pos.x;
                    defer y = pos.y;
                    if (y != pos.y) break;
                },
                .putToEndOfLine => break,
            }
        }
        try grid.flush(ctx, term);
    }
    try grid.flush(ctx, term);
}
