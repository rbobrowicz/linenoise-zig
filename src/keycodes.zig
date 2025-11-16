const std = @import("std");
const linenoise = @import("linenoise");

pub fn main() !void {
    var quit_buf: [4]u8 = undefined;
    @memset(&quit_buf, ' ');

    linenoise.init(.{});

    try linenoise.print("Keycode debug utility.\nType 'quit' to exit.\n", .{});

    try linenoise.enableRawMode();
    defer linenoise.disableRawMode();

    while (true) {
        const b = try linenoise.takeByte();
        @memmove(quit_buf[0 .. quit_buf.len - 1], quit_buf[1..]);
        quit_buf[quit_buf.len - 1] = b;

        try linenoise.print("'{c}' 0x{x:02} {d:>3}\r\n", .{ if (std.ascii.isPrint(b)) b else '?', b, b });

        if (std.mem.eql(u8, &quit_buf, "quit"))
            break;
    }
}
