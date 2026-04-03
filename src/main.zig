const std = @import("std");
const kilo_zig = @import("kilo_zig");

const KILO_ZIG_VERSION = "0.0.1";
const KILO_TAB_STOP = 8;
const KILO_QUIT_TIMES = 3;

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
    enter,
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
    if (first == '\r') {
        return .enter;
    }
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
    render: []u8,

    fn len(self: EditorRow) usize {
        return self.chars.len;
    }

    fn renderLen(self: EditorRow) usize {
        return self.render.len;
    }
};

const Editor = struct {
    allocator: std.mem.Allocator,
    filename: ?[]u8 = null,
    statusMessage: ?[]u8 = null,
    dirty: usize = 0,
    quitTimes: usize = KILO_QUIT_TIMES,
    cx: usize = 0,
    cy: usize = 0,
    rx: usize = 0,
    rowOff: usize = 0,
    colOff: usize = 0,
    screenRows: usize = 24,
    screenCols: usize = 80,
    rows: std.ArrayList(EditorRow),

    fn init(allocator: std.mem.Allocator) !Editor {
        const ws = try getWindowSize();
        return .{
            .allocator = allocator,
            .filename = null,
            .statusMessage = null,
            .dirty = 0,
            .quitTimes = KILO_QUIT_TIMES,
            .cx = 0,
            .cy = 0,
            .rx = 0,
            .rowOff = 0,
            .colOff = 0,
            .screenRows = ws.row - 2,
            .screenCols = ws.col,
            .rows = .empty,
        };
    }

    fn deinit(self: *Editor) void {
        if (self.filename) |filename| {
            self.allocator.free(filename);
        }
        if (self.statusMessage) |status_message| {
            self.allocator.free(status_message);
        }
        for (self.rows.items) |row| {
            self.allocator.free(row.chars);
            self.allocator.free(row.render);
        }
        self.rows.deinit(self.allocator);
    }

    fn rowCxToRx(_: *const Editor, row: EditorRow, cx: usize) usize {
        var rx: usize = 0;
        for (row.chars[0..@min(cx, row.len())]) |c| {
            if (c == '\t') {
                rx += (KILO_TAB_STOP - 1) - (rx % KILO_TAB_STOP);
            }
            rx += 1;
        }
        return rx;
    }

    fn updateRow(self: *Editor, row: *EditorRow) !void {
        var tabs: usize = 0;
        for (row.chars) |c| {
            if (c == '\t') tabs += 1;
        }

        self.allocator.free(row.render);
        row.render = try self.allocator.alloc(u8, row.len() + tabs * (KILO_TAB_STOP - 1));

        var idx: usize = 0;
        for (row.chars) |c| {
            if (c == '\t') {
                row.render[idx] = ' ';
                idx += 1;
                while (idx % KILO_TAB_STOP != 0) {
                    row.render[idx] = ' ';
                    idx += 1;
                }
            } else {
                row.render[idx] = c;
                idx += 1;
            }
        }
        row.render = row.render[0..idx];
    }

    fn appendRow(self: *Editor, line: []const u8) !void {
        const chars = try self.allocator.alloc(u8, line.len);
        @memcpy(chars, line);
        try self.rows.append(self.allocator, .{
            .chars = chars,
            .render = try self.allocator.alloc(u8, 0),
        });
        try self.updateRow(&self.rows.items[self.rows.items.len - 1]);
        self.dirty += 1;
    }

    fn rowInsertChar(self: *Editor, row: *EditorRow, at: usize, c: u8) !void {
        const insert_at = @min(at, row.len());
        const new_chars = try self.allocator.alloc(u8, row.len() + 1);
        @memcpy(new_chars[0..insert_at], row.chars[0..insert_at]);
        new_chars[insert_at] = c;
        @memcpy(new_chars[insert_at + 1 ..], row.chars[insert_at..]);

        self.allocator.free(row.chars);
        row.chars = new_chars;
        try self.updateRow(row);
        self.dirty += 1;
    }

    fn open(self: *Editor, filename: []const u8) !void {
        self.filename = try self.allocator.dupe(u8, filename);

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
        self.dirty = 0;
    }

    fn rowsToString(self: *Editor) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        for (self.rows.items) |row| {
            try buf.appendSlice(self.allocator, row.chars);
            try buf.append(self.allocator, '\n');
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    fn save(self: *Editor) !void {
        const filename = self.filename orelse {
            try self.setStatusMessage("Save aborted: no filename");
            return;
        };

        const contents = try self.rowsToString();
        defer self.allocator.free(contents);

        const cwd = std.fs.cwd();
        const file = try cwd.createFile(filename, .{ .truncate = true });
        defer file.close();

        try file.writeAll(contents);
        self.dirty = 0;

        var status_buf: [80]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "{d} bytes written to disk", .{contents.len});
        try self.setStatusMessage(status);
    }

    fn setStatusMessage(self: *Editor, message: []const u8) !void {
        if (self.statusMessage) |status_message| {
            self.allocator.free(status_message);
        }
        self.statusMessage = try self.allocator.dupe(u8, message);
    }

    fn drawStatusBar(self: *const Editor, ab: *AppendBuffer) !void {
        try ab.append("\x1b[7m");

        var status_buf: [80]u8 = undefined;
        const filename = self.filename orelse "[No Name]";
        const status = try std.fmt.bufPrint(
            &status_buf,
            "{s} - {d} lines {s}",
            .{ filename[0..@min(filename.len, 20)], self.rows.items.len, if (self.dirty > 0) "(modified)" else "" },
        );

        var rstatus_buf: [80]u8 = undefined;
        const rstatus = try std.fmt.bufPrint(&rstatus_buf, "{d}/{d}", .{ self.cy + 1, self.rows.items.len });

        var len: usize = @min(status.len, self.screenCols);
        try ab.append(status[0..len]);

        while (len < self.screenCols) {
            if (self.screenCols - len == rstatus.len) {
                try ab.append(rstatus);
                break;
            }

            try ab.append(" ");
            len += 1;
        }

        try ab.append("\x1b[m");
    }

    fn drawMessageBar(self: *const Editor, ab: *AppendBuffer) !void {
        try ab.append("\x1b[K");
        if (self.statusMessage) |status_message| {
            const len = @min(status_message.len, self.screenCols);
            try ab.append(status_message[0..len]);
        }
    }

    fn insertChar(self: *Editor, c: u8) !void {
        if (self.cy == self.rows.items.len) {
            try self.appendRow("");
        }

        try self.rowInsertChar(&self.rows.items[self.cy], self.cx, c);
        self.cx += 1;
    }

    fn drawRows(self: *const Editor, ab: *AppendBuffer) !void {
        for (0..self.screenRows) |y| {
            const fileRow = y + self.rowOff;
            if (fileRow < self.rows.items.len) {
                const row = self.rows.items[fileRow];
                if (self.colOff < row.renderLen()) {
                    const len = @min(row.renderLen() - self.colOff, self.screenCols);
                    try ab.append(row.render[self.colOff .. self.colOff + len]);
                }
            } else if (self.rows.items.len == 0 and y == self.screenRows / 3) {
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
        self.rx = 0;
        if (self.cy < self.rows.items.len) {
            self.rx = self.rowCxToRx(self.rows.items[self.cy], self.cx);
        }

        if (self.cy < self.rowOff) {
            self.rowOff = self.cy;
        }

        if (self.cy >= self.rowOff + self.screenRows) {
            self.rowOff = self.cy - self.screenRows + 1;
        }

        if (self.rx < self.colOff) {
            self.colOff = self.rx;
        }

        if (self.rx >= self.colOff + self.screenCols) {
            self.colOff = self.rx - self.screenCols + 1;
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
        try ab.append("\r\n");
        try self.drawStatusBar(&ab);
        try ab.append("\r\n");
        try self.drawMessageBar(&ab);

        try ab.appendFmt("\x1b[{d};{d}H", .{ (self.cy - self.rowOff) + 1, (self.rx - self.colOff) + 1 });
        try ab.append("\x1b[?25h");
        _ = try std.posix.write(std.posix.STDOUT_FILENO, ab.items());
    }

    fn rowLen(self: *const Editor, row_index: usize) usize {
        if (row_index >= self.rows.items.len) return 0;
        return self.rows.items[row_index].len();
    }

    fn moveCursor(self: *Editor, key: EditorKey) void {
        switch (key) {
            .arrow_left => {
                if (self.cx != 0) {
                    self.cx -= 1;
                } else if (self.cy > 0) {
                    self.cy -= 1;
                    self.cx = self.rowLen(self.cy);
                }
            },
            .arrow_right => {
                const row_len = self.rowLen(self.cy);
                if (self.cx < row_len) {
                    self.cx += 1;
                } else if (self.cy < self.rows.items.len) {
                    self.cy += 1;
                    self.cx = 0;
                }
            },
            .arrow_up => {
                if (self.cy != 0) self.cy -= 1;
            },
            .arrow_down => {
                if (self.cy < self.rows.items.len) self.cy += 1;
            },
            else => {},
        }

        const row_len = self.rowLen(self.cy);
        if (self.cx > row_len) {
            self.cx = row_len;
        }
    }

    fn processKeypress(self: *Editor) !bool {
        const key = (try editorReadKey()) orelse return true;
        switch (key) {
            .byte => |c| {
                if (c == ctrlKey('q')) {
                    if (self.dirty > 0 and self.quitTimes > 0) {
                        var status_buf: [128]u8 = undefined;
                        const status = try std.fmt.bufPrint(
                            &status_buf,
                            "WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.",
                            .{self.quitTimes},
                        );
                        try self.setStatusMessage(status);
                        self.quitTimes -= 1;
                        return true;
                    }
                    return false;
                }
                if (c == ctrlKey('s')) {
                    try self.save();
                    self.quitTimes = KILO_QUIT_TIMES;
                    return true;
                }
                if (c == ctrlKey('l') or c == '\x1b' or c == ctrlKey('h') or c == 127) {
                    self.quitTimes = KILO_QUIT_TIMES;
                    return true;
                }
                try self.insertChar(c);
            },
            .arrow_left, .arrow_right, .arrow_up, .arrow_down => self.moveCursor(key),
            .enter => {},
            .page_up => {
                self.cy = self.rowOff;
                for (0..self.screenRows) |_| {
                    self.moveCursor(.arrow_up);
                }
            },
            .page_down => {
                self.cy = @min(self.rowOff + self.screenRows - 1, self.rows.items.len);
                for (0..self.screenRows) |_| {
                    self.moveCursor(.arrow_down);
                }
            },
            .home => self.cx = 0,
            .end => self.cx = self.rowLen(self.cy),
            .delete => {},
        }

        self.quitTimes = KILO_QUIT_TIMES;
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
    defer editor.deinit();
    try editor.setStatusMessage("HELP: Ctrl-Q = quit");
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
