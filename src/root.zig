const std = @import("std");
const uni = std.unicode;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cDefine("__USE_XOPEN", "1"); // for wcwidth
    @cInclude("wchar.h");
});

var in_raw_mode: bool = false;
var original_termios: c.termios = undefined;
var in: std.fs.File = undefined;
var out: std.fs.File = undefined;
var inbuf: [16]u8 = undefined;
var outbuf: [4096]u8 = undefined;
var reader: std.fs.File.Reader = undefined;
var writer: std.fs.File.Writer = undefined;

pub const Keycode = enum(u8) {
    CTRL_A = 1,
    CTRL_B = 2,
    CTRL_C = 3,
    CTRL_D = 4,
    CTRL_E = 5,
    CTRL_F = 6,
    CTRL_H = 8,
    ENTER = 13,
    CTRL_T = 20,
    CTRL_W = 23,
    ESC = 27,
    BACKSPACE = 127,
    _,
};

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

fn write(str: []const u8) !void {
    _ = try writer.interface.write(str);
    try writer.interface.flush();
}

/// Returns a single byte from the input device.
/// Does not do any processing on the returned value. Should generally not be
/// called by library users unless you want to handle your own raw input.
pub fn takeByte() !u8 {
    return try reader.interface.takeByte();
}

/// Returns a single byte from the input device, but doesn't advance the stream.
/// Does not do any processing on the returned value. Should generally not be
/// called by library users unless you want to handle your own raw input.
pub fn peekByte() !u8 {
    return try reader.interface.peekByte();
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
    if (arr[0] != @intFromEnum(Keycode.ESC)) return Error.InvalidEscapeSequence;
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

pub const Result = union(enum) {
    /// If user presses Ctrl+c
    interrupt,
    /// End of stream or user pressed Ctrl+d
    eof,
    line: []u8,
};

pub fn getLine(gpa: Allocator, prompt: []const u8) !Result {
    // right now we only support reading from a (sane) TTY
    if (!in.isTty()) return error.NotImplemented;
    if (!in.getOrEnableAnsiEscapeSupport()) return error.NotImplemented;

    return getLineTty(gpa, prompt);
}

const EditState = enum(u8) {
    start,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_start,
    move_end,
    move_cursor,
    delete_forward,
    delete_backward,
    delete_word_backward,
    read_next,
    seen_esc,
    escape,
    escape_one,
    escape_one_semi,
    escape_one_semi_five,
    escape_three,
};

fn getLineTty(gpa: Allocator, prompt: []const u8) !Result {
    try enableRawMode();
    defer disableRawMode();

    // to get wcwidth to work
    const current_locale = std.c.setlocale(.CTYPE, "");
    defer _ = std.c.setlocale(.CTYPE, current_locale);

    // create a buffer that will hold the current line
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);
    try buf.ensureTotalCapacity(gpa, 80);

    var cursor: usize = 0;
    const promptLen = try getStringTerminalWidth(prompt);

    // goto is great, actually
    main: switch (EditState.start) {
        .start => {
            // 1. go to beginning of line \r
            // 2. print prompt {s}
            // 3. print buffer {s}
            // 4. erase anything after it \x1b[0K
            // 5. go to beginning of line \r
            // 6. move cursor to correct position \x1b[{d}C
            try print("\r{s}{s}\x1b[0K\r\x1b[{d}C", .{ prompt, buf.items, cursor + promptLen });
            continue :main .read_next;
        },
        .move_left => {
            cursor = @max(@as(isize, @intCast(cursor)) - 1, 0);
            continue :main .move_cursor;
        },
        .move_right => {
            cursor = @min(cursor + 1, buf.items.len);
            continue :main .move_cursor;
        },
        .move_start => {
            cursor = 0;
            continue :main .move_cursor;
        },
        .move_end => {
            cursor = buf.items.len;
            continue :main .move_cursor;
        },
        .move_word_left => {
            if (cursor == 0)
                continue :main .read_next;

            while (cursor > 0) : (cursor -= 1) {
                if (buf.items[cursor - 1] != ' ')
                    break;
            }

            while (cursor > 0) : (cursor -= 1) {
                if (buf.items[cursor - 1] == ' ')
                    break;
            }
            continue :main .move_cursor;
        },
        .move_word_right => {
            if (cursor == buf.items.len)
                continue :main .read_next;

            while (cursor < buf.items.len) : (cursor += 1) {
                if (buf.items[cursor] != ' ')
                    break;
            }

            while (cursor < buf.items.len) : (cursor += 1) {
                if (buf.items[cursor] == ' ')
                    break;
            }

            continue :main .move_cursor;
        },
        .delete_forward => {
            if (cursor < buf.items.len) {
                _ = buf.orderedRemove(cursor);
                continue :main .start;
            }
            continue :main .read_next;
        },
        .delete_backward => {
            if (cursor == 0)
                continue :main .read_next;

            if (cursor == buf.items.len) {
                _ = buf.pop();
            } else {
                _ = buf.orderedRemove(cursor - 1);
            }
            cursor -= 1;
            continue :main .start;
        },
        .delete_word_backward => {
            if (cursor == 0)
                continue :main .read_next;

            if (cursor == buf.items.len) {
                while (cursor > 0 and buf.items[cursor - 1] == ' ') : (cursor -= 1) {
                    _ = buf.pop();
                }

                while (cursor > 0 and buf.items[cursor - 1] != ' ') : (cursor -= 1) {
                    _ = buf.pop();
                }
            } else {
                while (cursor > 0 and buf.items[cursor - 1] == ' ') : (cursor -= 1) {
                    _ = buf.orderedRemove(cursor - 1);
                }

                while (cursor > 0 and buf.items[cursor - 1] != ' ') : (cursor -= 1) {
                    _ = buf.orderedRemove(cursor - 1);
                }
            }

            continue :main .start;
        },
        .move_cursor => {
            try print("\r\x1b[{d}C", .{cursor + promptLen});
            continue :main .read_next;
        },
        .read_next => {
            const b = try takeByte();

            switch (@as(Keycode, @enumFromInt(b))) {
                .CTRL_A => continue :main .move_start,
                .CTRL_B => continue :main .move_left,
                .CTRL_C => {
                    // move to right edge, write ^C and bail
                    try print("\r\x1b[{d}C^C\r\n", .{buf.items.len + promptLen});
                    return .interrupt;
                },
                .CTRL_D => {
                    if (buf.items.len == 0)
                        return .eof;
                    continue :main .delete_forward;
                },
                .CTRL_E => continue :main .move_end,
                .CTRL_F => continue :main .move_right,
                .CTRL_H, .BACKSPACE => continue :main .delete_backward,
                .CTRL_T => {
                    // transpose
                    const len = buf.items.len;
                    if (len < 2)
                        continue :main .read_next;

                    if (cursor == len) {
                        const temp = buf.items[len - 1];
                        buf.items[len - 1] = buf.items[len - 2];
                        buf.items[len - 2] = temp;
                    } else {
                        const temp = buf.items[cursor - 1];
                        buf.items[cursor - 1] = buf.items[cursor];
                        buf.items[cursor] = temp;
                        cursor += 1;
                    }

                    continue :main .start;
                },
                .CTRL_W => continue :main .delete_word_backward,
                .ENTER => {
                    try write("\r\n");

                    // return the line
                    const new_mem = try gpa.alloc(u8, buf.items.len);
                    @memcpy(new_mem, buf.items);
                    return .{ .line = new_mem };
                },
                .ESC => continue :main .seen_esc,
                else => {
                    // skip unrecognied control characters
                    if (std.ascii.isControl(b))
                        continue :main .read_next;

                    try buf.insert(gpa, cursor, b);
                    cursor += 1;
                    continue :main .start;
                },
            }
        },
        .seen_esc => {
            const b = try peekByte();
            switch (b) {
                '[' => {
                    _ = try takeByte();
                    continue :main .escape;
                },
                else => continue :main .read_next,
            }
        },
        .escape => {
            const b = try takeByte();
            switch (b) {
                '1' => continue :main .escape_one,
                '3' => continue :main .escape_three,
                'D' => continue :main .move_left, // left arrow
                'C' => continue :main .move_right, // right arrow
                'H' => continue :main .move_start, // home
                'F' => continue :main .move_end, // end
                else => {
                    // unhandled escape, add it to the line
                    try buf.insertSlice(gpa, cursor, &.{ '[', b });
                    cursor += 2;
                    continue :main .start;
                },
            }
        },
        .escape_one => {
            const b = try takeByte();
            switch (b) {
                ';' => continue :main .escape_one_semi,
                else => {
                    try buf.insertSlice(gpa, cursor, &.{ '[', '1', b });
                    cursor += 3;
                    continue :main .start;
                },
            }
        },
        .escape_one_semi => {
            const b = try takeByte();
            switch (b) {
                '5' => continue :main .escape_one_semi_five,
                else => {
                    try buf.insertSlice(gpa, cursor, &.{ '[', '1', ';', b });
                    cursor += 4;
                    continue :main .start;
                },
            }
        },
        .escape_one_semi_five => {
            const b = try takeByte();
            switch (b) {
                'C' => continue :main .move_word_right, // ctrl + right arrow
                'D' => continue :main .move_word_left, // ctrl + left arrow
                else => {
                    try buf.insertSlice(gpa, cursor, &.{ '[', '1', ';', '5', b });
                    cursor += 5;
                    continue :main .start;
                },
            }
        },
        .escape_three => {
            const b = try takeByte();
            switch (b) {
                '~' => continue :main .delete_forward, // delete
                else => {
                    try buf.insertSlice(gpa, cursor, &.{ '[', '3', b });
                    cursor += 3;
                    continue :main .start;
                },
            }
        },
    }
}

fn getStringTerminalWidth(str: []const u8) !usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const seqLen = try uni.utf8ByteSequenceLength(str[i]);
        var char: c_int = undefined;
        switch (seqLen) {
            1 => {
                width += 1;
                i += 1;
                continue;
            },
            2 => {
                char = try uni.utf8Decode2(.{ str[i], str[i + 1] });
            },
            3 => {
                char = try uni.utf8Decode3(.{ str[i], str[i + 1], str[i + 2] });
            },
            4 => {
                char = try uni.utf8Decode4(.{ str[i], str[i + 1], str[i + 2], str[i + 3] });
            },
            else => unreachable,
        }

        const cols = c.wcwidth(char);
        if (cols < 0) return error.InvalidCharacter;

        width += @intCast(cols);
        i += seqLen;
    }
    return width;
}
