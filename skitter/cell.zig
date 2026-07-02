const std = @import("std");

pub const CellMode = enum(u4) {
    skip = 0,
    glyph,
    ansi,
    trueColor,
    imgRoot,
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

    pub fn writeStyle(self: @This(), w: *std.Io.Writer) !void {
        var needTrail: bool = false;
        if (self.bold) {
            try w.writeAll("1");
            needTrail = true;
        }

        if (self.dim) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("2");
            needTrail = true;
        }

        if (self.italic) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("3");
            needTrail = true;
        }

        if (self.underline) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("4");
            needTrail = true;
        }

        if (self.blink) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("5");
            needTrail = true;
        }
        if (self.reverseColors) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("7");
            needTrail = true;
        }
        if (self.hidden) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("8");
            needTrail = true;
        }

        if (self.strike) {
            if (needTrail) try w.writeByte(';');
            try w.writeAll("9");
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
            .system => try w.print("{d}", .{@as(u8, @bitCast(self))}),
            inline else => {
                try w.print("{s}{d}", .{ if (isBg)
                    "48;5;"
                else
                    "38;5;", @as(u8, @bitCast(self)) });
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
};

pub const UnderlineDecoration = enum(u3) {
    none,
    line,
    double,
    wavy,
    dotted,
    dashed,
};

pub const FlaggedTrueColor = packed struct(u25) {
    color: RGB,
    toggled: bool,
};

pub const TrueColorCell = packed struct(u124) {
    char: u21,
    style: Style,
    fg: RGB,
    fgDefault: bool,
    bg: RGB,
    bgDefault: bool,
    underlineStyle: UnderlineDecoration,
    underline: RGB,
    underlineDefault: bool,
    _: u17 = 0,
};

pub const ImageRootCell = packed struct(u124) {
    _: u124 = 0,
};

pub const SkipCell = packed struct(u124) {
    _: u124 = 0,
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
