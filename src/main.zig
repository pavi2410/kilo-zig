const std = @import("std");
const kilo_zig = @import("kilo_zig");

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

fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

fn editorReadKey() !u8 {
    var stdin = std.fs.File.stdin();
    var c: [1]u8 = undefined;
    const bytes_read = try stdin.read(&c);
    if (bytes_read == 0) {
        std.debug.print("End of input.\r\n", .{});
        return 0;
    }
    return c[0];
}

fn getCursorPosition() !std.posix.winsize {
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[6n") catch {
        std.log.err("Failed to write escape sequence to stdout.", .{});
        return error.WriteFailed;
    };

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len - 1) {
        const c = try editorReadKey();
        if (c == 'R') break;
        buf[i] = c;
        i += 1;
    }
    buf[i] = 0; // Null-terminate the buffer

    std.debug.print("\r\nbuf[1] = {c}\r\n", .{buf[1]});

    // if (buf[0] != '\x1b' || buf[1] != '[') return -1;
//   if (sscanf(&buf[2], "%d;%d", rows, cols) != 2) return -1;

    if (buf[0] != '\x1b' or buf[1] != '[') {
        std.debug.print("Unexpected response format: {s}\r\n", .{buf[0..i]});
        return error.UnexpectedResponse;
    }

    var rows: usize = 0;
    var cols: usize = 0;
    var num_buf: [16]u8 = undefined;
    var num_index: usize = 0;
    for (buf[2..i]) |c| {
        if (c == ';') {
            rows = std.fmt.parseInt(usize, num_buf[0..num_index], 10) catch {
                std.debug.print("Failed to parse rows: {s}\r\n", .{num_buf[0..num_index]});
                return error.UnexpectedResponse;
            };
            num_index = 0;
        } else {
            if (num_index < num_buf.len) {
                num_buf[num_index] = c;
                num_index += 1;
            } else {
                std.debug.print("Number buffer overflow while parsing: {s}\r\n", .{num_buf});
                return error.UnexpectedResponse;
            }
        }
    }
    if (num_index > 0) {
        cols = std.fmt.parseInt(usize, num_buf[0..num_index], 10) catch {
            std.debug.print("Failed to parse columns: {s}\r\n", .{num_buf[0..num_index]});
            return error.UnexpectedResponse;
        };
    } else {
        std.debug.print("No columns data found in response: {s}\r\n", .{buf[0..i]});
        return error.UnexpectedResponse;
    }

    return .{
        .row = @intCast(rows),
        .col = @intCast(cols),
        .xpixel = 0,
        .ypixel = 0,
    };
}

fn getWindowSize() !std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    switch (std.posix.errno(std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        &ws,
    ))) {
        .SUCCESS => return ws,
        else => |err| {
            // if (write(STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[999C\x1b[999B") catch {
                std.log.err("Failed to write escape sequence to stdout.", .{});
                return std.posix.unexpectedErrno(err);
            };
            return getCursorPosition() catch {
                std.log.err("Failed to get cursor position.", .{});
                return std.posix.unexpectedErrno(err);
            };
        },
    }
}

fn editorDrawRows(editorConfig: EditorConfig) !void {
    for (0..editorConfig.screenRows) |y| {
        std.debug.print("~", .{});

        if (y < editorConfig.screenRows - 1) {
            std.debug.print("\r\n", .{});
        }
    }
}

fn editorRefreshScreen(editorConfig: EditorConfig) !void {
    // Clear the screen and move the cursor to the top-left corner
    std.debug.print("\x1b[2J\x1b[H", .{});

    editorDrawRows(editorConfig) catch {
        std.log.err("Error drawing rows.", .{});
    };

    std.debug.print("\x1b[H", .{});
}

fn editorProcessKeypress() !void {
    const c = try editorReadKey();
    if (c == ctrlKey('q')) {
        std.debug.print("Exiting...\r\n", .{});
        std.posix.exit(0);
    }
}

const EditorConfig = struct {
    screenRows: usize = 24,
    screenCols: usize = 80,
    origTermios: std.posix.termios,
};

fn initEditor() !EditorConfig {
    const ws = try getWindowSize();
    return EditorConfig{
        .screenRows = ws.row,
        .screenCols = ws.col,
        .origTermios = undefined, // This will be set in main after enabling raw mode
    };
}

pub fn main() !void {
    const original_termios = enableRawMode() catch {
        std.log.err("Failed to enable raw mode.", .{});
        return;
    };
    defer disableRawMode(original_termios) catch {
        std.log.err("Failed to disable raw mode.", .{});
    };

    var editorConfig = try initEditor();
    editorConfig.origTermios = original_termios;

    while (true) {
        editorRefreshScreen(editorConfig) catch {
            std.log.err("Error refreshing screen.", .{});
            break;
        };
        editorProcessKeypress() catch {
            std.log.err("Error processing keypress.", .{});
            break;
        };
    }

    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\r\n", .{"codebase"});
    try kilo_zig.bufferedPrint();
}
