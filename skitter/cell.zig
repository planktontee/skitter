const std = @import("std");
const TermStyleSeq = @import("control.zig").TermStyleSeq;
const control = @import("control.zig");

pub const CellMode = enum(u4) {
    skip = 0,
    glyph,
    ansi,
    trueColor,
    imgRoot,

    pub fn concreteType(self: @This()) type {
        return switch (self) {
            .skip => void,
            .glyph => u21,
            .ansi => AnsiCell,
            .trueColor => TrueColorCell,
            .imgRoot,
            => void,
        };
    }
};

pub const GlyphCell = packed struct(u124) {
    char: u21,
    _: u103 = 0,
};

pub const Style = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverseColors: bool = false,
    hidden: bool = false,
    strike: bool = false,

    pub fn writeDiff(to: @This(), w: *std.Io.Writer, seq: *TermStyleSeq, from: @This()) !void {
        const boldOff = from.bold and !to.bold;
        const dimOff = from.dim and !to.dim;
        if (boldOff or dimOff) {
            try seq.write(w, "22");
            if (to.bold) try seq.writeByte(w, '1');
            if (to.dim) try seq.writeByte(w, '2');
        } else {
            if (!from.bold and to.bold) try seq.writeByte(w, '1');
            if (!from.dim and to.dim) try seq.writeByte(w, '2');
        }

        inline for (.{
            .{ "italic", '3', "23" },
            .{ "underline", '4', "24" },
            .{ "blink", '5', "25" },
            .{ "reverseColors", '7', "27" },
            .{ "hidden", '8', "28" },
            .{ "strike", '9', "29" },
        }) |spec| {
            const field = spec.@"0";
            const on = spec.@"1";
            const off = spec.@"2";

            if (@field(from, field) and !@field(to, field))
                try seq.write(w, off)
            else if (!@field(from, field) and @field(to, field))
                try seq.writeByte(w, on);
        }
    }
};

pub const AnsiSystemColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    brightBlack = 8,
    brightRed = 9,
    brightGreen = 10,
    brightYellow = 11,
    brightBlue = 12,
    brightMagenta = 13,
    brightCyan = 14,
    brightWhite = 15,
    _,

    pub fn toAnsiColor(self: @This()) AnsiColor {
        const value: u8 = @intFromEnum(self);
        std.debug.assert(value <= 15);
        return .{ .system = self };
    }
};

pub const CubeColorRGB = struct {
    r: u3,
    g: u3,
    b: u3,
};

pub const CubeColor = packed struct(u8) {
    value: u8,

    pub fn init(val: u8) CubeColor {
        // Strict boundary validation: 16 to 231 only
        std.debug.assert(val >= 16 and val <= 231);
        return .{ .value = val };
    }

    pub fn r(self: CubeColor) u3 {
        return @intCast((self.value - 16) / 36);
    }
    pub fn g(self: CubeColor) u3 {
        return @intCast(((self.value - 16) / 6) % 6);
    }
    pub fn b(self: CubeColor) u3 {
        return @intCast((self.value - 16) % 6);
    }

    pub fn toAnsiColor(rgb: CubeColorRGB) AnsiColor {
        std.debug.assert(rgb.r <= 5 and rgb.g <= 5 and rgb.b <= 5);
        const value = 16 + (@as(u8, rgb.r) * 36) + (@as(u8, rgb.g) * 6) + @as(u8, rgb.b);
        return .{ .cube = CubeColor{ .value = value } };
    }
};

pub const GrayScale = packed struct(u8) {
    value: u8,

    pub fn init(val: u8) GrayScale {
        // Strict boundary validation: 232 to 255 only
        std.debug.assert(val >= 232);
        return .{ .value = val };
    }

    // Normalized intensity step (0 to 23)
    pub fn level(self: GrayScale) u5 {
        return @intCast(self.value - 232);
    }

    pub fn toAnsiColor(scaleLevel: u5) AnsiColor {
        std.debug.assert(scaleLevel <= 23);
        const value = 232 + @as(u8, scaleLevel);
        return .{ .gray = GrayScale{ .value = value } };
    }
};

pub const AnsiColorTag = enum {
    system,
    cube,
    gray,
};

pub const AnsiColor = packed union {
    system: AnsiSystemColor,
    cube: CubeColor,
    gray: GrayScale,

    pub fn init(value: u8) @This() {
        return switch (value) {
            0...15 => .{ .system = @enumFromInt(value) },
            16...231 => .{ .cube = .init(value) },
            232...255 => .{ .gray = .init(value) },
        };
    }

    // This is done separately to avoid the payload wrapping in zig
    pub fn tag(self: @This()) AnsiColorTag {
        const value = @as(u8, @bitCast(self));
        return switch (value) {
            0...15 => .system,
            16...231 => .cube,
            232...255 => .gray,
        };
    }

    pub fn write(self: @This(), comptime isBg: bool, w: *std.Io.Writer) !void {
        switch (self.tag()) {
            .system => {
                const idx = @as(u8, @bitCast(self));
                const code = if (idx < 8)
                    (if (isBg) 40 else 30) + idx
                else
                    (if (isBg) 100 else 90) + (idx - 8);
                try w.print("{d}", .{code});
            },
            inline else => {
                try w.print(if (isBg)
                    "48;5;{d}"
                else
                    "38;5;{d}", .{@as(u8, @bitCast(self))});
            },
        }
    }
};

pub const FlaggedAnsiColor = packed struct(u9) {
    color: AnsiColor,
    toggled: bool,
};

pub const AnsiCell = packed struct(u124) {
    char: u21,
    style: Style,
    fg: AnsiColor,
    fgDefault: bool,
    bg: AnsiColor,
    bgDefault: bool,
    _: u77 = 0,
};

pub const RGB = packed struct(u24) {
    // This accounts for endian-ness
    b: u8,
    g: u8,
    r: u8,

    pub fn write(self: @This(), w: *std.Io.Writer) !void {
        try w.print("{d};{d};{d}", .{ self.r, self.g, self.b });
    }
};

pub const UnderlineDecoration = enum(u3) {
    none,
    line,
    double,
    wavy,
    dotted,
    dashed,

    pub fn writeDiff(to: @This(), w: *std.Io.Writer, seq: *TermStyleSeq, from: @This()) !void {
        if (to != from)
            if (to == .none)
                try seq.write(w, "4:0")
            else
                try seq.print(w, "4:{d}", .{@intFromEnum(to)});
    }
};

pub const FlaggedTrueColor = packed struct(u25) {
    color: RGB,
    toggled: bool,
};

pub const TrueColorCell = packed struct(u124) {
    char: u21,
    style: Style = @bitCast(@as(u8, 0)),
    fg: RGB = @bitCast(@as(u24, 0)),
    fgDefault: bool = true,
    bg: RGB = @bitCast(@as(u24, 0)),
    bgDefault: bool = true,
    underlineStyle: UnderlineDecoration = .none,
    underline: RGB = @bitCast(@as(u24, 0)),
    underlineDefault: bool = true,
    _: u17 = 0,
};

pub const ImageRootCell = packed struct(u124) {
    _: u124 = 0,
};

pub const SkipCell = packed struct(u124) {
    _: u124 = 0,
};

pub fn FmtColor(isBg: bool) type {
    return union(enum) {
        default,
        ansi: AnsiColor,
        rgb: RGB,

        pub fn eql(a: @This(), b: @This()) bool {
            if (@as(std.meta.Tag(@This()), a) != @as(std.meta.Tag(@This()), b)) return false;
            return switch (a) {
                .default => true,
                .ansi => |c| @as(u8, @bitCast(c)) == @as(u8, @bitCast(b.ansi)),
                .rgb => |c| @as(u24, @bitCast(c)) == @as(u24, @bitCast(b.rgb)),
            };
        }

        pub fn writeDiff(
            to: @This(),
            w: *std.Io.Writer,
            seq: *TermStyleSeq,
            from: @This(),
        ) !void {
            if (!to.eql(from)) {
                switch (to) {
                    .default => try seq.write(w, "39"),
                    .ansi => |color| {
                        try seq.nextToken(w);
                        try color.write(isBg, w);
                    },
                    .rgb => |rgb| {
                        try seq.write(w, (if (isBg) "48" else "38" ++ ";2;"));
                        try rgb.write(w);
                    },
                }
            }
        }
    };
}

pub const UnderlineColorFmt = union(enum) {
    none,
    rgb: RGB,

    pub fn eql(self: @This(), other: @This()) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .none => true,
            .rgb => |color| color == other.rgb,
        };
    }

    pub fn writeDiff(to: @This(), w: *std.Io.Writer, seq: *TermStyleSeq, from: @This()) !void {
        if (!to.eql(from))
            switch (to) {
                .none => try seq.write(w, "58"),
                .rgb => |rgb| {
                    try seq.write(w, "58;2;");
                    try rgb.write(w);
                },
            };
    }
};

pub const CellFmt = struct {
    style: Style = @bitCast(@as(u8, 0)),
    fg: FmtColor(false) = .default,
    bg: FmtColor(true) = .default,
    udDeco: UnderlineDecoration = .none,
    udColor: UnderlineColorFmt = .none,

    pub fn writeCharWithDiff(to: *const @This(), w: *std.Io.Writer, from: *const @This(), char: u21) !void {
        var seq: control.TermStyleSeq = .{};

        try to.style.writeDiff(w, &seq, from.style);
        try to.fg.writeDiff(w, &seq, from.fg);
        try to.bg.writeDiff(w, &seq, from.bg);
        try to.udDeco.writeDiff(w, &seq, from.udDeco);
        try to.udColor.writeDiff(w, &seq, from.udColor);

        try seq.finish(w);

        try w.print("{u}", .{char});
    }
};

pub const CellData = packed union {
    glyph: GlyphCell,
    ansi: AnsiCell,
    trueColor: TrueColorCell,
    imageRoot: ImageRootCell,
    skip: SkipCell,
};

// This is not a tagged union to avoid padding
pub const Cell = packed struct(u128) {
    mode: CellMode,
    data: CellData,
};

const testing = std.testing;
test "Cell layout size" {
    try testing.expectEqual(16, @sizeOf(Cell));
    try testing.expectEqual(128, @bitSizeOf(Cell));
    try testing.expectEqual(124, @bitSizeOf(CellData));
}

test "CharCell mode" {
    const cell: Cell = .{
        .mode = .glyph,
        .data = .{ .glyph = .{ .char = 'A' } },
    };
    try testing.expectEqual(.glyph, cell.mode);
    try testing.expectEqual('A', cell.data.glyph.char);
}

test "AnsiCell Layout & Exact Style Bitmask" {
    const cell = Cell{
        .mode = .ansi,
        .data = .{
            .ansi = .{
                .char = 'X',
                .style = .{
                    .bold = true,
                    .underline = true,
                },
                .fg = AnsiSystemColor.brightRed.toAnsiColor(),
                .fgDefault = false,
                .bg = AnsiSystemColor.black.toAnsiColor(),
                .bgDefault = true,
            },
        },
    };

    try testing.expectEqual(@as(u8, 0x09), @as(u8, @bitCast(cell.data.ansi.style)));
    try testing.expect(cell.data.ansi.bgDefault);
}

test "AnsiCell - Flavor Tagging" {
    const cube_color = CubeColor.toAnsiColor(.{ .r = 5, .g = 2, .b = 0 });
    try testing.expectEqual(.cube, cube_color.tag());
    try testing.expectEqual(@as(u8, 208), @as(u8, @bitCast(cube_color)));

    const gray_color = GrayScale.toAnsiColor(12);
    try testing.expectEqual(.gray, gray_color.tag());
    try testing.expectEqual(@as(u8, 244), @as(u8, @bitCast(gray_color)));
}

test "TrueColorCell Full Integer Hex Blasting" {
    const cell = Cell{
        .mode = .trueColor,
        .data = .{
            .trueColor = .{
                .char = '🔥',
                .style = @bitCast(@as(u8, 0x00)),
                .fg = @bitCast(@as(u24, 0xFF6400)),
                .fgDefault = false,
                .bg = @bitCast(@as(u24, 0x000000)),
                .bgDefault = false,
                .underlineStyle = .wavy,
                .underline = @bitCast(@as(u24, 0xFFFFFF)),
                .underlineDefault = false,
            },
        },
    };

    try testing.expectEqual(@as(u8, 0xFF), cell.data.trueColor.fg.r);
    try testing.expectEqual(@as(u8, 0x64), cell.data.trueColor.fg.g);
    try testing.expectEqual(@as(u8, 0x00), cell.data.trueColor.fg.b);

    try testing.expectEqual(@as(u24, 0xFF6400), @as(u24, @bitCast(cell.data.trueColor.fg)));
    try testing.expectEqual(@as(u24, 0xFFFFFF), @as(u24, @bitCast(cell.data.trueColor.underline)));
    try testing.expectEqual(.wavy, cell.data.trueColor.underlineStyle);
}
