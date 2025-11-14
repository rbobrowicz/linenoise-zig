const std = @import("std");
const linenoise = @import("linenoise");

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var reader_buf: [16]u8 = undefined;
    var stdin_reader = stdin.reader(&reader_buf);

    var writer_buf: [64]u8 = undefined;
    var stdout_writer = stdout.writer(&writer_buf);

    var quit_buf: [4]u8 = undefined;
    @memset(&quit_buf, ' ');

    try stdout_writer.interface.print("Keycode debug utility.\nType 'quit' to exit.\n", .{});
    try stdout_writer.interface.flush();

    try linenoise.enableRawMode(stdin);
    defer linenoise.disableRawMode(stdin);

    while (true) {
        const b = try stdin_reader.interface.takeByte();
        @memmove(quit_buf[0 .. quit_buf.len - 1], quit_buf[1..]);
        quit_buf[quit_buf.len - 1] = b;

        try stdout_writer.interface.print("'{c}' 0x{x:02} {d:>3}\r\n", .{ if (std.ascii.isPrint(b)) b else '?', b, b });
        try stdout_writer.interface.flush();

        if (std.mem.eql(u8, &quit_buf, "quit"))
            break;
    }
}
