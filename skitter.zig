const std = @import("std");
const builtin = @import("builtin");
const regent = @import("regent");
const linux = std.os.linux;
const terminal = @import("skitter/terminal.zig");
const is_debug = builtin.mode == .Debug;
const Allocator = std.mem.Allocator;
const Grid = @import("skitter/Grid.zig");
const Donut = @import("ex/donut.zig");
const Trace = @import("skitter/Trace.zig");

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
    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };

    var trace = try Trace.init(rctx);
    defer trace.deinit(rctx);

    var term: terminal.Terminal = try .init(rctx);
    defer term.deinit(rctx);

    term.trace = &trace;

    const size = term.size;

    var grid: Grid = undefined;
    try grid.init(size, ctx);
    defer grid.deinit(ctx);

    try term.start(ctx.io);
    defer term.stop(ctx.io) catch {};

    try trace.pushTimer(rctx);
    for (0..size.rows) |row| {
        for (0..size.cols) |col| {
            grid.putCell(row, col, .{
                .mode = .glyph,
                .data = .{
                    .glyph = .{
                        .char = ' ',
                    },
                },
            });
        }
    }
    try trace.popTimer(rctx, .draw);

    try grid.flush(ctx, &term);

    try trace.pushTimer(rctx);
    try ctx.io.sleep(.fromMilliseconds(18), .awake);
    try trace.popTimer(rctx, .sleep);

    try Donut.run(ctx, &grid, &term);

    try trace.dump();
}
