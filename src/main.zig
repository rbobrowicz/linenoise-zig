const std = @import("std");
const linenoise = @import("linenoise");

pub fn main() !void {
    try linenoise.printKeyCodes();
}
