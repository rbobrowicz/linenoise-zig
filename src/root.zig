const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
});

var in_raw_mode: bool = false;
var original_termios: c.termios = undefined;

pub const LinenoiseError = error{
    NotATty,
    InvalidEscapeSequence,
};

pub fn enableRawMode(file: std.fs.File) LinenoiseError!void {
    if (in_raw_mode)
        return;

    if (!file.isTty())
        return error.NotATty;

    if (c.tcgetattr(file.handle, &original_termios) == -1)
        return error.NotATty;

    var raw: c.termios = original_termios;
    raw.c_iflag &= ~@as(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_uint, c.OPOST);
    raw.c_cflag |= @as(c_uint, c.CS8);
    raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(file.handle, c.TCSAFLUSH, &raw) < 0)
        return error.NotATty;

    in_raw_mode = true;
}

pub fn disableRawMode(file: std.fs.File) void {
    if (!in_raw_mode)
        return;

    _ = c.tcsetattr(file.handle, c.TCSAFLUSH, &original_termios);
    in_raw_mode = false;
}

pub const Keycodes = enum(u8) {
    ESC = 27,
};

pub fn getCursorPosition(in: *std.Io.Reader, out: *std.Io.Writer) !usize {
    var arr: [32]u8 = undefined;
    var buf = std.Io.Writer.fixed(&arr);

    _ = try out.write("\x1b[6n");
    try out.flush();

    const readCount = try in.streamDelimiterLimit(&buf, 'R', .limited(arr.len));
    const b = try in.takeByte();

    if (b != 'R')
        return error.InvalidEscapeSequence;

    if (arr[0] != @intFromEnum(Keycodes.ESC) or arr[1] != '[')
        return error.InvalidEscapeSequence;

    const positions = arr[2..readCount];
    const semi = std.mem.indexOfScalar(u8, positions, ';') orelse return error.InvalidEscapeSequence;
    const col = positions[semi + 1 ..];

    return try std.fmt.parseInt(usize, col, 10);
}

