const std = @import("std");
const zcasp = @import("zcasp");
const positionals = zcasp.positionals;
const help = zcasp.help;
const codec = zcasp.codec;
const regent = @import("regent");
const Cursor = regent.collections.Cursor;
const TermSize = @import("terminal.zig").TermSize;

pub fn TermSizeCodec(Spec: type) type {
    return struct {
        pub const Error = error{
            ZeroSizeHeight,
            ZeroSizeWidth,
            SyntaxError,
        } ||
            BaseCodec.Error;

        const BaseCodec = codec.ArgCodec(Spec);
        const SpecCodec = zcasp.codec.ArgCodec(Spec);

        pub fn supports(comptime T: type, comptime _: SpecCodec.SpecFieldEnum) bool {
            return T == TermSize;
        }

        pub fn parseByType(
            self: *@This(),
            comptime T: type,
            comptime tag: SpecCodec.SpecFieldEnum,
            allocator: *const std.mem.Allocator,
            cursor: *Cursor([]const u8),
        ) Error!T {
            if (T == TermSize) {
                return try parseTermSize(cursor);
            } else {
                return try BaseCodec.parseByType(self, T, tag, allocator, cursor);
            }
        }
    };
}

const TermSizeState = enum {
    init,
    width,
    separator,
    heightStart,
    height,
};

fn parseTermSize(
    cursor: *Cursor([]const u8),
) !TermSize {
    const s = cursor.peek() orelse return error.SyntaxError;
    defer cursor.consume();

    var w: TermSize = undefined;

    var i: usize = 0;
    loop: switch (@as(TermSizeState, .init)) {
        .init => {
            if (i >= s.len) return error.SyntaxError;

            switch (s[i]) {
                '0' => return error.ZeroSizeWidth,
                '1'...'9' => continue :loop .width,
                else => return error.SyntaxError,
            }
        },
        .width => {
            digit: while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    '0'...'9' => continue :digit,
                    'x' => {
                        w.cols = try std.fmt.parseInt(u16, s[0..i], 10);
                        continue :loop .separator;
                    },
                    else => return error.SyntaxError,
                }
            }
            return error.SyntaxError;
        },
        .separator => {
            i += 1;
            continue :loop .heightStart;
        },
        .heightStart => {
            if (i >= s.len) return error.SyntaxError;

            switch (s[i]) {
                '0' => return error.ZeroSizeHeight,
                '1'...'9' => continue :loop .height,
                else => return error.SyntaxError,
            }
        },
        .height => {
            // we are here: <height>x<_>, and _ is guaranteed non-zero (from .widthStart)
            const start = i;
            digit: while (i < s.len) : (i += 1) {
                switch (s[i]) {
                    '0'...'9' => continue :digit,
                    else => return error.SyntaxError,
                }
            }
            w.rows = try std.fmt.parseInt(u16, s[start..], 10);
            return w;
        },
    }
}

test "window codec test" {
    const testing = std.testing;

    var c: regent.collections.DebugCursor = .{
        .data = &.{
            "80x20",
            "a",
            "0",
            "",
            "1",
            "1y",
            "1x",
            "1x0",
            "1xa",
            "1x1",
            "1x1a",
        },
        .i = 0,
    };
    var cursor = c.asCursor();
    var wCodec: TermSizeCodec(DonutArgs) = .{};

    try testing.expectEqualDeep(
        TermSize{ .cols = 80, .rows = 20 },
        try wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.ZeroSizeWidth,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.ZeroSizeHeight,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectEqualDeep(
        TermSize{ .cols = 1, .rows = 1 },
        try wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
    try testing.expectError(
        error.SyntaxError,
        wCodec.parseByType(TermSize, .window, &testing.allocator, &cursor),
    );
}

pub const DonutArgs = struct {
    fullscreen: ?bool = null,
    window: ?TermSize = null,
    @"frames-by-second": usize = 60,
    fps: u16 = 60,

    pub const Short = .{
        .w = .window,
        .f = .fullscreen,
        .fR = .@"frames-by-second",
    };

    pub const Codec = TermSizeCodec(@This());

    pub const Positionals = positionals.EmptyPositionalsOf;

    pub const Help: help.HelpData(@This()) = .{
        .usage = &.{"skitter donut <options>"},
        .description = "Draw donut for a number of frames",
        .examples = &.{
            "skitter donut -w20x20",
            "skitter donut --fullscreen",
        },
        .optionsDescription = &.{
            .{ .field = .fullscreen, .description = "Claims entire tty screen. Either this or --window is required." },
            .{ .field = .window, .description = "Gives a window (WxH) size to draw the donut. Either this or --fullscreen is required." },
            .{ .field = .@"frames-by-second", .description = "Number of frames by second to play." },
            .{ .field = .fps, .typeHint = false, .defaultHint = false, .description = "FPS for the flush." },
        },
    };

    fn validateArgs(fbset: zcasp.validate.FieldBitSet(@This())) zcasp.validate.Error!void {
        if (fbset.allOf(.{ .fullscreen, .window })) return error.MutuallyExclusiveArgsPresent;
        if (!fbset.oneOf(.{ .fullscreen, .window })) return error.RequiredArgsMissing;
    }

    pub const GroupMatch: zcasp.validate.GroupMatchConfig(@This()) = .{
        .validateFn = @This().validateArgs,
    };
};

pub const TailArgs = struct {
    fullscreen: ?bool = null,
    window: ?TermSize = null,

    pub const Short = .{
        .w = .window,
        .f = .fullscreen,
    };

    pub const Codec = TermSizeCodec(@This());

    pub const Help: help.HelpData(@This()) = .{
        .usage = &.{"skitter tail <options>"},
        .description = "Tails file or stdin",
        .examples = &.{
            "skitter tail -w 40x80",
        },
        .optionsDescription = &.{
            .{ .field = .fullscreen, .description = "Claims entire tty screen. Either this or --window is required." },
            .{ .field = .window, .description = "Gives a window (WxH) size to poll file/stdin. Either this or --fullscreen is required." },
        },
    };

    fn validateArgs(fbset: zcasp.validate.FieldBitSet(@This())) zcasp.validate.Error!void {
        if (fbset.allOf(.{ .fullscreen, .window })) return error.MutuallyExclusiveArgsPresent;
        if (!fbset.oneOf(.{ .fullscreen, .window })) return error.RequiredArgsMissing;
    }

    pub const GroupMatch: zcasp.validate.GroupMatchConfig(@This()) = .{
        .validateFn = @This().validateArgs,
    };
};

pub const Args = struct {
    pub const Verb = union(enum) {
        donut: DonutArgs,
        tail: TailArgs,
    };

    pub const Help: help.HelpData(@This()) = .{
        .usage = &.{"skitter <verb>"},
        .description = "Runs specific tui cli in verb.",
    };

    pub const GroupMatch: zcasp.validate.GroupMatchConfig(@This()) = .{
        .mandatoryVerb = true,
    };
};

pub const ArgsResponse = zcasp.spec.SpecResponseWithConfig(Args, zcasp.help.HelpConf{
    .simpleTypes = true,
    .headerDelimiter = "",
}, true);
