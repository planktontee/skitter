const std = @import("std");
const Writer = std.Io.Writer;

pub fn moveCursor(w: *Writer, x: usize, y: usize) Writer.Error!void {
    try w.print("\x1b[{d};{d}H", .{ x + 1, y + 1 });
}
