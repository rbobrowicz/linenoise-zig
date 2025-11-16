const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
});

var in_raw_mode: bool = false;
var original_termios: c.termios = undefined;
var in: std.fs.File = undefined;
var out: std.fs.File = undefined;
var inbuf: [16]u8 = undefined;
var outbuf: [128]u8 = undefined;
var reader: std.fs.File.Reader = undefined;
var writer: std.fs.File.Writer = undefined;

pub const Keycodes = enum(u8) { ESC = 27, _ };

pub const Error = error{
    NotATty,
    InvalidEscapeSequence,
};

pub const Options = struct {
    in: ?std.fs.File = null,
    out: ?std.fs.File = null,
};

pub fn init(opts: Options) void {
    in = opts.in orelse std.fs.File.stdin();
    out = opts.out orelse std.fs.File.stdout();
    reader = in.reader(&inbuf);
    writer = out.writer(&outbuf);
}

pub fn enableRawMode() Error!void {
    if (in_raw_mode)
        return;

    if (!in.isTty())
        return error.NotATty;

    if (c.tcgetattr(in.handle, &original_termios) == -1)
        return error.NotATty;

    var raw: c.termios = original_termios;
    raw.c_iflag &= ~@as(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_uint, c.OPOST);
    raw.c_cflag |= @as(c_uint, c.CS8);
    raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(in.handle, c.TCSAFLUSH, &raw) < 0)
        return error.NotATty;

    in_raw_mode = true;
}

pub fn disableRawMode() void {
    if (!in_raw_mode)
        return;

    _ = c.tcsetattr(in.handle, c.TCSAFLUSH, &original_termios);
    in_raw_mode = false;
}

pub fn print(comptime fmt: []const u8, args: anytype) !void {
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn takeByte() !u8 {
    return try reader.interface.takeByte();
}

pub fn getCursorPosition() !usize {
    var arr: [32]u8 = undefined;
    var buf = std.Io.Writer.fixed(&arr);

    _ = try writer.interface.write("\x1b[6n");
    try writer.interface.flush();

    const readCount = try reader.interface.streamDelimiterLimit(&buf, 'R', .limited(arr.len));
    const b = try reader.interface.takeByte();

    if (b != 'R') return error.InvalidEscapeSequence;
    if (arr[0] != @intFromEnum(Keycodes.ESC)) return error.InvalidEscapeSequence;
    if (arr[1] != '[') return error.InvalidEscapeSequence;

    const positions = arr[2..readCount];
    const semi = std.mem.indexOfScalar(u8, positions, ';') orelse return error.InvalidEscapeSequence;
    const col = positions[semi + 1 ..];

    return try std.fmt.parseInt(usize, col, 10);
}
