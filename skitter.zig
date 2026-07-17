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
const Tail = @import("ex/tail.zig");

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

    const rctx: regent.ergo.Context = .{ .io = ctx.io, .allocator = ctx.heapAlloc };

    var trace = try Trace.init(rctx);
    defer trace.deinit(rctx);
    defer trace.dump() catch {};

    var term: terminal.Terminal = try .init(
        rctx,
        switch (argsRes.verb.?) {
            inline else => |opt| if (opt.options.fullscreen != null)
                .fullscreen
            else
                .{ .window = opt.options.window.? },
        },
    );
    defer term.deinit(rctx);

    term.trace = &trace;

    const size = term.size;

    var grid: Grid = undefined;
    try grid.init(term.startPos, size, ctx);
    defer grid.deinit(ctx);

    try term.start(ctx.io, true);
    defer term.stop(ctx.io, true) catch {};

    switch (argsRes.verb.?) {
        .donut => try Donut.run(
            ctx,
            &grid,
            &term,
            argsRes.verb.?.donut.options.@"frames-by-second",
            argsRes.verb.?.donut.options.fps,
        ),
        .tail => try Tail.run(ctx, &grid, &term, argsRes.verb.?.tail.positionals.reminder),
    }
}

test {
    std.testing.refAllDecls(@This());
}
