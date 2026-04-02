const std = @import("std");
const kilo_zig = @import("kilo_zig");

const KILO_ZIG_VERSION = "0.0.1";

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

fn editorReadByte() !?u8 {
    var stdin = std.fs.File.stdin();
    var c: [1]u8 = undefined;
    const bytes_read = try stdin.read(&c);
    if (bytes_read == 0) {
        return null;
    }
    return c[0];
}

const EditorKey = union(enum) {
    byte: u8,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    page_up,
    page_down,
    home,
    end,
    delete,
};

fn editorReadKey() !?EditorKey {
    const first = (try editorReadByte()) orelse return null;
    if (first != '\x1b') {
        return .{ .byte = first };
    }

    const second = (try editorReadByte()) orelse return .{ .byte = first };
    const third = (try editorReadByte()) orelse return .{ .byte = first };

    if (second == '[') {
        if (third >= '0' and third <= '9') {
            const fourth = (try editorReadByte()) orelse return .{ .byte = first };
            if (fourth == '~') {
                return switch (third) {
                    '3' => .delete,
                    '5' => .page_up,
                    '6' => .page_down,
                    '1', '7' => .home,
                    '4', '8' => .end,
                    else => .{ .byte = first },
                };
            }
        }

        return switch (third) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            'H' => .home,
            'F' => .end,
            else => .{ .byte = first },
        };
    }

    if (second == 'O') {
        return switch (third) {
            'H' => .home,
            'F' => .end,
            else => .{ .byte = first },
        };
    }

    return .{ .byte = first };
}

fn getCursorPosition() !std.posix.winsize {
    _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[6n") catch {
        std.log.err("Failed to write escape sequence to stdout.", .{});
        return error.WriteFailed;
    };

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len - 1) {
        const c = (try editorReadByte()) orelse continue;
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

const AppendBuffer = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) AppendBuffer {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *AppendBuffer) void {
        self.buffer.deinit(self.allocator);
    }

    fn append(self: *AppendBuffer, slice: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, slice);
    }

    fn appendFmt(self: *AppendBuffer, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.writer(self.allocator).print(fmt, args);
    }

    fn items(self: *const AppendBuffer) []const u8 {
        return self.buffer.items;
    }
};

const EditorRow = struct {
    chars: []const u8,

    fn len(self: EditorRow) usize {
        return self.chars.len;
    }
};

const Editor = struct {
    allocator: std.mem.Allocator,
    cx: usize = 0,
    cy: usize = 0,
    rowOff: usize = 0,
    screenRows: usize = 24,
    screenCols: usize = 80,
    rows: std.ArrayList(EditorRow),

    fn init(allocator: std.mem.Allocator) !Editor {
        const ws = try getWindowSize();
        return .{
            .allocator = allocator,
            .cx = 0,
            .cy = 0,
            .rowOff = 0,
            .screenRows = ws.row,
            .screenCols = ws.col,
            .rows = .empty,
        };
    }

    fn appendRow(self: *Editor, line: []const u8) !void {
        const chars = try self.allocator.alloc(u8, line.len);
        @memcpy(chars, line);
        try self.rows.append(self.allocator, .{
            .chars = chars,
        });
    }

    fn open(self: *Editor, filename: []const u8) !void {
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(filename, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var line_slice = line;
            if (line_slice.len > 0 and line_slice[line_slice.len - 1] == '\r') {
                line_slice = line_slice[0 .. line_slice.len - 1];
            }

            try self.appendRow(line_slice);
        }
    }

    fn drawRows(self: *const Editor, ab: *AppendBuffer) !void {
        for (0..self.screenRows) |y| {
            const fileRow = y + self.rowOff;
            if (fileRow < self.rows.items.len) {
                const row = self.rows.items[fileRow];
                const len = @min(row.len(), self.screenCols);
                try ab.append(row.chars[0..len]);
            } else if (y == self.screenRows / 3) {
                const welcome = "Kilo Zig -- version " ++ KILO_ZIG_VERSION;
                const padding = (self.screenCols - welcome.len) / 2;
                if (padding > 0) {
                    try ab.append("~");
                    for (0..padding - 1) |_| {
                        try ab.append(" ");
                    }
                }
                try ab.append(welcome);
            } else {
                try ab.append("~");
            }

            try ab.append("\x1b[K");
            if (y < self.screenRows - 1) {
                try ab.append("\r\n");
            }
        }
    }

    fn scroll(self: *Editor) void {
        if (self.cy < self.rowOff) {
            self.rowOff = self.cy;
        }

        if (self.cy >= self.rowOff + self.screenRows) {
            self.rowOff = self.cy - self.screenRows + 1;
        }
    }

    fn refreshScreen(self: *Editor) !void {
        self.scroll();

        var ab = AppendBuffer.init(self.allocator);
        defer ab.deinit();

        // Build the full frame in memory first, then write it in one shot.
        try ab.append("\x1b[?25l");
        try ab.append("\x1b[H");

        try self.drawRows(&ab);

        try ab.appendFmt("\x1b[{d};{d}H", .{ (self.cy - self.rowOff) + 1, self.cx + 1 });
        try ab.append("\x1b[?25h");
        _ = try std.posix.write(std.posix.STDOUT_FILENO, ab.items());
    }

    fn moveCursor(self: *Editor, key: EditorKey) void {
        switch (key) {
            .arrow_left => {
                if (self.cx != 0) self.cx -= 1;
            },
            .arrow_right => {
                if (self.cx != self.screenCols - 1) self.cx += 1;
            },
            .arrow_up => {
                if (self.cy != 0) self.cy -= 1;
            },
            .arrow_down => {
                if (self.cy < self.rows.items.len) self.cy += 1;
            },
            else => {},
        }
    }

    fn processKeypress(self: *Editor) !bool {
        const key = (try editorReadKey()) orelse return true;
        switch (key) {
            .byte => |c| {
                if (c == ctrlKey('q')) {
                    return false;
                }
            },
            .arrow_left, .arrow_right, .arrow_up, .arrow_down => self.moveCursor(key),
            .page_up => {
                self.cy = 0;
                for (0..self.screenRows) |_| {
                    self.moveCursor(.arrow_up);
                }
            },
            .page_down => {
                self.cy = self.screenRows - 1;
                for (0..self.screenRows) |_| {
                    self.moveCursor(.arrow_down);
                }
            },
            .home => self.cx = 0,
            .end => self.cx = self.screenCols - 1,
            .delete => {},
        }

        return true;
    }
};

pub fn main() !void {
    const original_termios = enableRawMode() catch {
        std.log.err("Failed to enable raw mode.", .{});
        return;
    };
    defer disableRawMode(original_termios) catch {
        std.log.err("Failed to disable raw mode.", .{});
    };

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.skip();

    var editor = try Editor.init(std.heap.page_allocator);
    if (args.next()) |filename| {
        try editor.open(filename);
    }

    while (true) {
        editor.refreshScreen() catch {
            std.log.err("Error refreshing screen.", .{});
            break;
        };
        const should_continue = editor.processKeypress() catch {
            std.log.err("Error processing keypress.", .{});
            break;
        };
        if (!should_continue) break;
    }

    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\r\n", .{"codebase"});
    try kilo_zig.bufferedPrint();
}
