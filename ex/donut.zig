const std = @import("std");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");

pub fn run(ctx: *Ctx, grid: *Grid, term: *Terminal, framesBySecond: usize, fps: u16) !void {
    const context: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    var A: f32 = 0.0;
    var B: f32 = 0.0;

    var b: [1760]u8 = undefined;
    var z: [1760]f32 = undefined;

    var frame: usize = 0;
    while (frame < framesBySecond * fps and Terminal.isRunning()) : (frame += 1) {
        if (term.trace) |t| try t.pushTimer(context);
        if (term.trace) |t| try t.pushTimer(context);

        @memset(&b, ' ');
        @memset(&z, 0.0);

        var j: f32 = 0.0;
        while (j < 6.28) : (j += 0.07) {
            var i: f32 = 0.0;
            while (i < 6.28) : (i += 0.02) {
                const c = std.math.sin(i);
                const d = std.math.cos(j);
                const e = std.math.sin(A);
                const f = std.math.sin(j);
                const g = std.math.cos(A);
                const h = d + 2.0;
                const D = 1.0 / (c * h * e + f * g + 5.0);
                const l = std.math.cos(i);
                const m = std.math.cos(B);
                const n = std.math.sin(B);
                const t = c * h * g - f * e;

                // Project onto 2D terminal screen
                const x: i32 = @intFromFloat(40.0 + 30.0 * D * (l * h * m - t * n));
                const y: i32 = @intFromFloat(12.0 + 15.0 * D * (l * h * n + t * m));
                const o: i32 = x + 80 * y;

                // Calculate luminance index
                const N: i32 = @intFromFloat(8.0 * ((f * e - c * d * g) * m - c * d * e - f * g - l * d * n));

                if (y >= 0 and y < 22 and x >= 0 and x < 80 and D > z[@intCast(o)]) {
                    z[@intCast(o)] = D;
                    const idx: usize = @intCast(if (N > 0) N else 0);
                    b[@intCast(o)] = ".,-~:;=!*#$ "[if (idx < 12) idx else 11];
                }
            }
        }

        // Render frame
        var y: usize = 0;
        while (y < 22) : (y += 1) {
            for (0..80) |x| {
                const c = b[y * 80 + x];

                // Calculate dynamic RGB waves based on grid position and frame time
                // Adjust multipliers to change color frequency / speed
                const rWave = std.math.sin(@as(f32, @floatFromInt(y)) * 0.15 + @as(f32, @floatFromInt(frame)) * 0.05) * 127.0 + 128.0;
                const gWave = std.math.sin(@as(f32, @floatFromInt(x)) * 0.05 + @as(f32, @floatFromInt(frame)) * 0.03) * 127.0 + 128.0;
                const bWave = std.math.cos(@as(f32, @floatFromInt(y + x)) * 0.1 + @as(f32, @floatFromInt(frame)) * 0.04) * 127.0 + 128.0;

                grid.put(x, y, .trueColor, .{
                    .char = c,
                    .fg = .{
                        .r = @intFromFloat(rWave),
                        .g = @intFromFloat(gWave),
                        .b = @intFromFloat(bWave),
                    },
                    .fgDefault = false,
                });
            }
        }
        if (term.trace) |t| try t.popTimer(context, .draw);

        try grid.flush(ctx, term);

        // Increment rotation angles
        A += 0.04;
        B += 0.02;

        if (term.trace) |t| try t.popTimer(context, .@"grid.loop");

        if (term.trace) |t| try t.pushTimer(context);

        // draw: 1.6 ms
        // serialize: 689 micro
        // flush: 64 micro
        // -2.5ms is good enough
        try ctx.io.sleep(.fromMicroseconds(@divTrunc(@as(i64, 1000 * 1000), @as(i64, @intCast(fps))) - 2500), .awake);
        if (term.trace) |t| try t.popTimer(context, .sleep);
    }
}
