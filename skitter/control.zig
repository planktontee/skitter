const std = @import("std");
const Writer = std.Io.Writer;

pub fn moveCursor(w: *Writer, x: usize, y: usize) Writer.Error!void {
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}

pub fn hideCursor() []const u8 {
    return "\x1b[?25l";
}

pub fn showCursor() []const u8 {
    return "\x1b[?25h";
}

pub fn alternateScreenBuffer() []const u8 {
    return "\x1b[?1049h";
}

pub fn moveToMainBuffer() []const u8 {
    return "\x1b[?1049l";
}

pub fn wipeEntireScreen() []const u8 {
    return "\x1b[2J";
}

pub fn moveCursorToHome() []const u8 {
    return "\x1b[H";
}

pub fn restoreCursor() []const u8 {
    return "\x1b[u";
}

pub fn moveToNextLine() []const u8 {
    return "\x1b[1E";
}

pub fn cleanFormat() []const u8 {
    return "\x1b[0m";
}

pub const TermSeq = struct {
    started: bool = false,

    pub fn nextToken(self: *@This(), w: *Writer) !void {
        if (!self.started) {
            try w.writeAll("\x1b[");
            self.started = true;
        } else try w.writeAll(";");
    }

    pub fn writeByte(self: *@This(), w: *Writer, c: u8) !void {
        try self.nextToken(w);
        try w.writeByte(c);
    }

    pub fn write(self: *@This(), w: *Writer, value: []const u8) !void {
        try self.nextToken(w);
        try w.writeAll(value);
    }

    pub fn print(self: *@This(), w: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.nextToken(w);
        try w.print(fmt, args);
    }

    pub fn finish(self: @This(), w: *Writer) !void {
        if (self.started) try w.writeByte('m');
    }
};
