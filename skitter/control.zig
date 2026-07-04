const std = @import("std");
const Writer = std.Io.Writer;

pub fn moveCursor(w: *Writer, x: usize, y: usize) Writer.Error!void {
    try w.print("\x1b[{d};{d}H", .{ x + 1, y + 1 });
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
