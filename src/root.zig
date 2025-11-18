const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
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

/// Initializes the library with the specified options.
/// Defaults `in` to standard input and `out` to standard output.
pub fn init(opts: Options) void {
    in = opts.in orelse std.fs.File.stdin();
    out = opts.out orelse std.fs.File.stdout();
    reader = in.reader(&inbuf);
    writer = out.writer(&outbuf);
}

/// Enable raw mode on the specified input device.
/// Library users will generally not need to use this manually.
/// Throws an error if the specified device is not a TTY as determined
/// by Zig's `std.fs.File.isTty`.
pub fn enableRawMode() error{NotATty}!void {
    if (in_raw_mode)
        return;

    if (!in.isTty())
        return Error.NotATty;

    if (c.tcgetattr(in.handle, &original_termios) == -1)
        return Error.NotATty;

    var raw: c.termios = original_termios;
    raw.c_iflag &= ~@as(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_uint, c.OPOST);
    raw.c_cflag |= @as(c_uint, c.CS8);
    raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 1;
    raw.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(in.handle, c.TCSAFLUSH, &raw) < 0)
        return Error.NotATty;

    in_raw_mode = true;
}

/// Disables raw mode on the specified input device.
/// Library users will generally not need to use this manually.
/// This doesn't throw an error even on failure, as it's probably already too
/// late to do anything about it.
pub fn disableRawMode() void {
    if (!in_raw_mode)
        return;

    _ = c.tcsetattr(in.handle, c.TCSAFLUSH, &original_termios);
    in_raw_mode = false;
}

/// Convenience method to print on the specified input device.
/// This function will automatically flush the write buffer after every print.
/// If the device is in raw mode you will need to add carriage returns (`\r`)
/// manually to restore the cursor position back to beginning of the line.
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn write(comptime str: []const u8) !void {
    _ = try writer.interface.write(str);
    try writer.interface.flush();
}

/// Returns a single byte from the input device.
/// Does not do any processing on the returned value. Should generally not be
/// called by library users unless you want to handle your own raw input.
pub fn takeByte() !u8 {
    return try reader.interface.takeByte();
}

/// Gets the column position of the cursor.
/// Assumes the input device is a TTY that understands ANSI escape sequences.
/// Position is 1-based (returns 1 for leftmost column).
pub fn getCursorPosition() !usize {
    var arr: [32]u8 = undefined;
    var buf = std.Io.Writer.fixed(&arr);

    try write("\x1b[6n");

    const readCount = try reader.interface.streamDelimiterLimit(&buf, 'R', .limited(arr.len));
    const b = try reader.interface.takeByte();

    if (b != 'R') return Error.InvalidEscapeSequence;
    if (arr[0] != @intFromEnum(Keycodes.ESC)) return Error.InvalidEscapeSequence;
    if (arr[1] != '[') return Error.InvalidEscapeSequence;

    const positions = arr[2..readCount];
    const semi = std.mem.indexOfScalar(u8, positions, ';') orelse return Error.InvalidEscapeSequence;
    const col = positions[semi + 1 ..];

    return try std.fmt.parseInt(usize, col, 10);
}

/// Gets the count of columns in the terminal.
/// Assumes the input device is a TTY that understands ANSI escape sequences.
pub fn getColumns() !usize {
    // try syscall first
    var ws: c.winsize = undefined;
    const ret = c.ioctl(in.handle, c.TIOCGWINSZ, &ws);
    if (ret == 0 and ws.ws_col > 0)
        return ws.ws_col;

    // fallback to using cursor position
    const start = try getCursorPosition();
    try write("\x1b[999C");
    const end = try getCursorPosition();

    if (end > start) {
        try print("\x1b[{d}D", .{end - start});
    }

    return end;
}
