const std = @import("std");
const builtin = @import("builtin");
const regent = @import("regent");
const linux = std.os.linux;
const terminal = @import("skitter/terminal.zig");
const is_debug = builtin.mode == .Debug;
const Allocator = std.mem.Allocator;
const Grid = @import("skitter/grid.zig");

const DebugAlloctor = std.heap.DebugAllocator(.{});

pub const Ctx = struct {
    debugAlloc: if (is_debug) Allocator else void,
    heapAlloc: Allocator,
    stackAlloc: Allocator,

    io: std.Io,
};

pub fn main() !u8 {
    var dba: DebugAlloctor = .init;
    defer _ = dba.deinit();

    const debugAlloc = if (is_debug) dba.allocator() else {};
    const heapAlloc = if (is_debug) debugAlloc else std.heap.smp_allocator;
    const stackAlloc = if (is_debug) debugAlloc else null;

    var ctx: Ctx = .{
        .debugAlloc = debugAlloc,
        .heapAlloc = heapAlloc,
        // this will be set after trampolining
        .stackAlloc = undefined,
        .io = undefined,
    };

    try regent.trampoline.stackTrampoline(
        u6,
        1,
        trampMain,
        .{ stackAlloc, &ctx },
    );

    return 0;
}

pub const MainError = error{
    MissingStackAllocator,
} || RunTtyError || anyerror;

pub fn trampMain(args: struct { ?Allocator, *Ctx }) MainError!void {
    const optStackAlloc, const ctx = args;
    ctx.stackAlloc = if (optStackAlloc) |a| a else return error.MissingStackAllocator;

    // var evented: std.Io.Evented = undefined;
    // try evented.init(ctx.heapAlloc, .{ .thread_limit = 1 });
    // defer evented.deinit();

    // ctx.io = evented.io();

    var tIo = std.Io.Threaded.init_single_threaded;
    ctx.io = tIo.io();

    // From this point onwards Ctx is fully populated
    try runTty(ctx);
}

pub const RunTtyError = anyerror;

pub fn runTty(ctx: *Ctx) RunTtyError!void {
    const Telemetry = struct {
        tag: enum {
            flush,
            draw,
            sleep,
        },
        // in nanos
        value: i96,
    };

    var timer: std.ArrayList(Telemetry) = .empty;
    defer timer.deinit(ctx.heapAlloc);

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };
    var term: terminal.Terminal = try .init(rctx);
    defer term.deinit(rctx);

    const size = term.size;

    var grid: Grid = undefined;
    try grid.init(size, ctx);
    defer grid.deinit(ctx);

    const clock = std.Io.Clock.awake;

    try term.start(ctx.io);
    defer term.stop(ctx.io) catch {};

    var t0 = clock.now(ctx.io);

    for (0..size.rows) |row| {
        for (0..size.cols) |col| {
            grid.putCell(row, col, .{
                .mode = .glyph,
                .data = .{
                    .glyph = .{
                        .value = ' ',
                    },
                },
            });
        }
    }

    try timer.append(ctx.heapAlloc, .{
        .tag = .draw,
        .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
    });

    t0 = clock.now(ctx.io);
    try grid.flush(&term);
    try timer.append(ctx.heapAlloc, .{
        .tag = .flush,
        .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
    });

    t0 = clock.now(ctx.io);
    try ctx.io.sleep(.fromMilliseconds(18), .awake);
    try timer.append(ctx.heapAlloc, .{
        .tag = .sleep,
        .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
    });

    var frame: usize = 0;

    while (frame < 30 * 60) {
        t0 = clock.now(ctx.io);

        for (0..size.rows) |row| {
            for (0..size.cols) |col| {
                grid.putCell(row, col, .{
                    .mode = .ansi,
                    .data = .{
                        .ansi = .{
                            .char = @intCast((frame / 10 + row *% col) % ('z' - 'a') + 'a'),
                            .bg = .init(@intCast((frame / 10 + row *% col) % 0xFF)),
                            .fg = .init(@intCast(0xFF - ((frame / 10 + row *% col) % 0xFF))),
                            .bgDefault = false,
                            .fgDefault = false,
                            .style = @bitCast(@as(u8, @intCast((frame / 10 + row *% col) % 0xFF))),
                        },
                    },
                });
            }
        }

        try timer.append(ctx.heapAlloc, .{
            .tag = .draw,
            .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
        });

        t0 = clock.now(ctx.io);
        try grid.flush(&term);
        try timer.append(ctx.heapAlloc, .{
            .tag = .flush,
            .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
        });

        frame += 1;

        t0 = clock.now(ctx.io);
        try ctx.io.sleep(.fromMilliseconds(17), .awake);
        try timer.append(ctx.heapAlloc, .{
            .tag = .sleep,
            .value = t0.untilNow(ctx.io, clock).toNanoseconds(),
        });
    }

    var fs = try regent.fs.FileStream(.write).open(rctx, "metrics.log");
    defer {
        fs.close(rctx);
        fs.deinit(rctx);
    }
    for (timer.items) |item|
        try fs.stream.interface.print("tag: {s}, value: {d} ns\n", .{ @tagName(item.tag), item.value });
    try fs.stream.interface.flush();
}
