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

    var linesFilled: usize = 0;
    var cursor: regent.fs.Utf8Cursor = .{ .reader = r };

    // first pass fils the grid
    while (Terminal.isRunning()) {
        for (linesFilled..term.size.rows) |y| {
            for (0..term.size.cols) |x| {
                const optC = try cursor.next();

                if (optC == null or optC.? == '\n') {
                    grid.splatRow(x, y, .glyph, ' ');
                    break;
                }

                grid.put(x, y, .glyph, optC.?);
            }
            linesFilled += 1;
        }
        try grid.flush(ctx, term);
        if (linesFilled == term.size.rows) break;
    }

    // further passes shift
    tail: while (Terminal.isRunning()) {
        var needScroll: bool = true;
        for (0..term.size.cols) |x| {
            const y = term.size.rows - 1;

            const c = try cursor.next() orelse break :tail;
            if (needScroll) {
                grid.scrollUp();
                needScroll = false;
            }

            if (c == '\n') {
                grid.splatRow(x, y, .glyph, ' ');
                break;
            }

            grid.put(x, y, .glyph, c);
        }
        try grid.flush(ctx, term);
    }
    try grid.flush(ctx, term);
}
