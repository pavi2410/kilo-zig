const std = @import("std");
const kilo_zig = @import("kilo_zig");

pub fn main() !void {
    const original_termios = enableRawMode() catch {
        std.log.err("Failed to enable raw mode.", .{});
        return;
    };
    defer disableRawMode(original_termios) catch {
        std.log.err("Failed to disable raw mode.", .{});
    };

    // read a byte at a time until 'q' is pressed
    var stdin = std.fs.File.stdin();
    var c: [1]u8 = undefined;
    while (true) {
        const bytes_read = try stdin.read(&c);
        if (bytes_read == 0) {
            std.debug.print("End of input.\r\n", .{});
        }
        if (std.ascii.isControl(c[0])) {
            std.debug.print("You pressed a control character: {d}\r\n", .{c[0]});
        } else {
            std.debug.print("You pressed: {d} ({c})\r\n", .{ c[0], c[0] });
        }
        if (c[0] == 'q') break;
    }

    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\r\n", .{"codebase"});
    try kilo_zig.bufferedPrint();
}

fn disableRawMode(original_termios: std.posix.termios) !void {
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original_termios);
}

fn enableRawMode() !std.posix.termios {
    // step1: get the current terminal attributes
    const original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw_termios = original_termios;

    // step2: modify the attributes to enable raw mode
    raw_termios.iflag.BRKINT = false;
    raw_termios.iflag.ICRNL = false;
    raw_termios.iflag.INPCK = false;
    raw_termios.iflag.ISTRIP = false;
    raw_termios.iflag.IXON = false;
    raw_termios.oflag.OPOST = false;
    raw_termios.cflag.CSIZE = .CS8;
    raw_termios.lflag.ECHO = false;
    raw_termios.lflag.ICANON = false;
    raw_termios.lflag.IEXTEN = false;
    raw_termios.lflag.ISIG = false;
    raw_termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw_termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    // step3: set the modified attributes
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw_termios);
    return original_termios;
}
