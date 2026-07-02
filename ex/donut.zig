const std = @import("std");
const Terminal = @import("../skitter/terminal.zig").Terminal;
const Grid = @import("../skitter/Grid.zig");
const Cell = @import("../skitter/cell.zig").Cell;
const Ctx = @import("../skitter.zig").Ctx;
const Trace = @import("../skitter/Trace.zig");
const regent = @import("regent");

pub fn run(ctx: *Ctx, grid: *Grid, term: *Terminal) !void {
    const context: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    var A: f32 = 0.0;
    var B: f32 = 0.0;

    var b: [1760]u8 = undefined;
    var z: [1760]f32 = undefined;

    var frame: usize = 0;
    while (frame < 30 * 60) : (frame += 1) {
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
        var row: usize = 0;
        while (row < 22) : (row += 1) {
            for (0..80) |col| {
                const char_val = b[row * 80 + col];

                // Calculate dynamic RGB waves based on grid position and frame time
                // Adjust multipliers to change color frequency / speed
                const r_wave = std.math.sin(@as(f32, @floatFromInt(row)) * 0.15 + @as(f32, @floatFromInt(frame)) * 0.05) * 127.0 + 128.0;
                const g_wave = std.math.sin(@as(f32, @floatFromInt(col)) * 0.05 + @as(f32, @floatFromInt(frame)) * 0.03) * 127.0 + 128.0;
                const b_wave = std.math.cos(@as(f32, @floatFromInt(row + col)) * 0.1 + @as(f32, @floatFromInt(frame)) * 0.04) * 127.0 + 128.0;

                grid.putCell(row, col, .{
                    .mode = .trueColor,
                    .data = .{
                        .trueColor = .{
                            .char = char_val,
                            .style = @bitCast(@as(u8, 0)),
                            .fg = .{
                                .r = @intFromFloat(r_wave),
                                .g = @intFromFloat(g_wave),
                                .b = @intFromFloat(b_wave),
                            },
                            .bg = .{ .r = 0, .g = 0, .b = 0 },
                            .underline = .{ .r = 0, .g = 0, .b = 0 },
                            .fgDefault = false,
                            .bgDefault = true,
                            .underlineDefault = true,
                            .underlineStyle = .none,
                        },
                    },
                });
            }
        }
        if (term.trace) |t| try t.popTimer(context, .draw);

        try grid.flush(ctx, term);

        // Increment rotation angles
        A += 0.04;
        B += 0.02;

        if (term.trace) |t| try t.pushTimer(context);
        try ctx.io.sleep(.fromMilliseconds(18), .awake);
        if (term.trace) |t| try t.popTimer(context, .sleep);
    }
}
