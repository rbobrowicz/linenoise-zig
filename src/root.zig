const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
});

var in_raw_mode: bool = false;
var original_termios: c.termios = undefined;

pub const LinenoiseError = error{
    NotATty,
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
