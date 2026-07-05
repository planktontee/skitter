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
const mArgs = @import("skitter/args.zig");
const ArgsResponse = mArgs.ArgsResponse;

const DebugAlloctor = std.heap.DebugAllocator(.{});

pub const Ctx = struct {
    debugAlloc: if (is_debug) Allocator else void,
    heapAlloc: Allocator,
    stackAlloc: Allocator,

    io: std.Io,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
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
        .{ stackAlloc, &ctx, init },
    );

    return 0;
}

pub fn trampMain(args: struct { ?Allocator, *Ctx, std.process.Init.Minimal }) !void {
    const optStackAlloc, const ctx, const init = args;
    ctx.stackAlloc = if (optStackAlloc) |a| a else return error.MissingStackAllocator;

    var argsRes: ArgsResponse = .init(ctx.stackAlloc);
    defer argsRes.deinit();

    var tIo = std.Io.Threaded.init_single_threaded;
    ctx.io = tIo.io();

    // var evented: std.Io.Evented = undefined;
    // try evented.init(ctx.heapAlloc, .{ .thread_limit = 1 });
    // defer evented.deinit();

    // ctx.io = evented.io();

    if (argsRes.parseArgs(init.args)) |parseError| {
        const msg = try std.fmt.allocPrint(ctx.stackAlloc, "Last opt <{?s}>, Last token <{?s}>. {s}", .{
            parseError.lastOpt,
            parseError.lastToken,
            parseError.message orelse unreachable,
        });
        defer ctx.stackAlloc.free(msg);

        try std.Io.File.stderr().writeStreamingAll(ctx.io, msg);
        return parseError.err;
    }

    if (argsRes.verb.? == .donut)
        try runDonut(ctx, &argsRes);
}

pub const RunTtyError = anyerror;

pub fn runDonut(ctx: *Ctx, args: *const ArgsResponse) RunTtyError!void {
    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };

    var trace = try Trace.init(rctx);
    defer trace.deinit(rctx);

    var term: terminal.Terminal = try .init(
        rctx,
        if (args.verb.?.donut.options.fullscreen != null)
            .fullscreen
        else
            .{ .window = args.verb.?.donut.options.window.? },
    );
    defer term.deinit(rctx);

    term.trace = &trace;

    const size = term.size;

    var grid: Grid = undefined;
    // TODO: force scroll to make room for windowed
    try grid.init(term.startPos, size, ctx);
    defer grid.deinit(ctx);

    try term.start(ctx.io, true);
    defer term.stop(ctx.io, true) catch {};

    try trace.pushTimer(rctx);
    for (0..size.rows) |y| {
        for (0..size.cols) |x| {
            grid.putCell(y, x, .{
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

    try Donut.run(
        ctx,
        &grid,
        &term,
        args.verb.?.donut.options.@"frames-by-second",
        args.verb.?.donut.options.fps,
    );

    try trace.dump();
}

test {
    _ = mArgs;
}
