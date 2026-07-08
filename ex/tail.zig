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
    // Both passes assume fill will fill > grid

    // first pass fils the grid
    while (Terminal.isRunning()) {
        r.fill(1) catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return e,
        };

        const buff = r.buffered();
        var i: usize = 0;
        for (linesFilled..term.size.rows) |y| {
            var skipX: bool = false;
            for (0..term.size.cols) |x| {
                if (skipX or i >= buff.len) {
                    grid.putCell(x, y, .{
                        .mode = .glyph,
                        .data = .{ .glyph = @bitCast(@as(u124, @intCast(' '))) },
                    });
                    continue;
                }
                if (buff[i] == '\n') {
                    skipX = true;
                    grid.putCell(x, y, .{
                        .mode = .glyph,
                        .data = .{ .glyph = @bitCast(@as(u124, @intCast(' '))) },
                    });
                    i += 1;
                    continue;
                }
                // TODO: utf8
                grid.putCell(x, y, .{
                    .mode = .glyph,
                    .data = .{ .glyph = @bitCast(@as(u124, @intCast(buff[i]))) },
                });
                i += 1;
            }
            linesFilled += 1;
            if (i >= buff.len) break;
        }
        r.toss(i);
        try grid.flush(ctx, term);
        if (linesFilled == term.size.rows) break;
    }

    // further passes shift
    while (Terminal.isRunning()) {
        r.fill(1) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return e,
        };
        var i: usize = 0;
        const buff = r.buffered();

        const targetSize: usize = term.size.cols * term.size.rows - term.size.cols;
        @memmove(
            grid.bChar[0..targetSize],
            grid.bChar[term.size.cols..],
        );

        var skipX: bool = false;
        for (0..term.size.cols) |x| {
            const y = term.size.rows - 1;
            if (skipX or i >= buff.len) {
                grid.putCell(x, y, .{
                    .mode = .glyph,
                    .data = .{ .glyph = @bitCast(@as(u124, @intCast(' '))) },
                });
                continue;
            }
            if (buff[i] == '\n') {
                skipX = true;
                grid.putCell(x, y, .{
                    .mode = .glyph,
                    .data = .{ .glyph = @bitCast(@as(u124, @intCast(' '))) },
                });
                i += 1;
                continue;
            }
            // TODO: utf8
            grid.putCell(x, y, .{
                .mode = .glyph,
                .data = .{ .glyph = @bitCast(@as(u124, @intCast(buff[i]))) },
            });
            i += 1;
        }
        r.toss(i);
        try grid.flush(ctx, term);
    }
}
