const std = @import("std");
const linenoise = @import("linenoise");

pub fn main() !void {
    linenoise.init(.{});

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    while (true) {
        const res = try linenoise.getLine(allocator, "おはよう>");

        switch (res) {
            .eof => break,
            .interrupt => {},
            .line => |l| {
                try linenoise.print("got line: {s}\r\n", .{l});
                allocator.free(l);
            },
        }
    }
}
