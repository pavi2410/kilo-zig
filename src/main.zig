const std = @import("std");
const kilo_zig = @import("kilo_zig");

const KILO_ZIG_VERSION = "0.0.1";
const KILO_TAB_STOP = 8;
const KILO_QUIT_TIMES = 3;
const SyntaxFlags = packed struct(u32) {
    highlight_numbers: bool = false,
    highlight_strings: bool = false,
    _: u30 = 0,
};

const EditorHighlight = enum(u8) {
    normal = 0,
    comment,
    ml_comment,
    keyword1,
    keyword2,
    string,
    number,
    match,
};

const EditorSyntax = struct {
    filetype: []const u8,
    filematch: []const []const u8,
    keywords: []const []const u8,
    singleline_comment_start: ?[]const u8,
    multiline_comment_start: ?[]const u8,
    multiline_comment_end: ?[]const u8,
    flags: SyntaxFlags,
};

const c_filematch = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc" };
const c_keywords = [_][]const u8{
    "switch", "if",      "while",     "for",     "break",   "continue",
    "return", "else",    "struct",    "union",   "typedef", "static",
    "enum",   "class",   "case",      "int|",    "long|",   "double|",
    "float|", "char|",   "unsigned|", "signed|", "void|",   "short|",
    "const|", "size_t|", "bool|",
};
const zig_filematch = [_][]const u8{ ".zig", ".zon" };
const zig_keywords = [_][]const u8{
    "addrspace",   "align",    "allowzero", "and",         "anyframe|",   "anytype|",
    "asm",         "async",    "await",     "break",       "callconv",    "catch",
    "comptime",    "const|",   "continue",  "defer",       "else",        "enum",
    "errdefer",    "error",    "export",    "extern",      "false|",      "fn",
    "for",         "if",       "inline",    "linksection", "noalias",     "noinline",
    "nosuspend",   "opaque",   "or",        "orelse",      "packed",      "pub",
    "resume",      "return",   "struct",    "suspend",     "switch",      "test",
    "threadlocal", "true|",    "try",       "union",       "unreachable", "usingnamespace",
    "var|",        "volatile", "while",     "void|",       "bool|",       "usize|",
    "isize|",      "u8|",      "u16|",      "u32|",        "u64|",        "u128|",
    "i8|",         "i16|",     "i32|",      "i64|",        "i128|",       "f16|",
    "f32|",        "f64|",     "f80|",      "f128|",
};
const hldb = [_]EditorSyntax{
    .{
        .filetype = "c",
        .filematch = &c_filematch,
        .keywords = &c_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = .{ .highlight_numbers = true, .highlight_strings = true },
    },
    .{
        .filetype = "zig",
        .filematch = &zig_filematch,
        .keywords = &zig_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = null,
        .multiline_comment_end = null,
        .flags = .{ .highlight_numbers = true, .highlight_strings = true },
    },
};

fn isSeparator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == 0 or std.mem.indexOfScalar(u8, ",.()+-/*=~%<>[];", c) != null;
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

    if (buf[0] != '\x1b' or buf[1] != '[') return error.UnexpectedResponse;

    var rows: usize = 0;
    var cols: usize = 0;
    var num_buf: [16]u8 = undefined;
    var num_index: usize = 0;
    for (buf[2..i]) |c| {
        if (c == ';') {
            rows = std.fmt.parseInt(usize, num_buf[0..num_index], 10) catch return error.UnexpectedResponse;
            num_index = 0;
        } else {
            if (num_index < num_buf.len) {
                num_buf[num_index] = c;
                num_index += 1;
            } else {
                return error.UnexpectedResponse;
            }
        }
    }
    if (num_index > 0) {
        cols = std.fmt.parseInt(usize, num_buf[0..num_index], 10) catch return error.UnexpectedResponse;
    } else {
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


const EditorRow = struct {
    chars: []const u8,
    render: []u8,
    hl: []EditorHighlight,
    hl_open_comment: bool,

    fn len(self: EditorRow) usize {
        return self.chars.len;
    }

    fn renderLen(self: EditorRow) usize {
        return self.render.len;
    }
};

const Editor = struct {
    allocator: std.mem.Allocator,
    syntax: ?*const EditorSyntax = null,
    filename: ?[]u8 = null,
    statusMessage: ?[]u8 = null,
    dirty: bool = false,
    quitTimes: usize = KILO_QUIT_TIMES,
    searchLastMatch: ?usize = null,
    searchDirection: isize = 1,
    savedHlLine: ?usize = null,
    savedHl: ?[]EditorHighlight = null,
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
        if (self.savedHl) |saved_hl| {
            self.allocator.free(saved_hl);
        }
        for (self.rows.items) |row| {
            self.allocator.free(row.chars);
            self.allocator.free(row.render);
            self.allocator.free(row.hl);
        }
        self.rows.deinit(self.allocator);
    }

    fn syntaxToColor(hl: EditorHighlight) []const u8 {
        return switch (hl) {
            .comment, .ml_comment => "\x1b[36m",
            .keyword1 => "\x1b[33m",
            .keyword2 => "\x1b[32m",
            .string => "\x1b[35m",
            .number => "\x1b[31m",
            .match => "\x1b[34m",
            .normal => "\x1b[39m",
        };
    }

    fn selectSyntaxHighlight(self: *Editor) !void {
        self.syntax = null;
        const filename = self.filename orelse return;

        for (&hldb) |*syntax| {
            for (syntax.filematch) |pattern| {
                if (pattern.len == 0) continue;
                if (pattern[0] == '.') {
                    if (std.mem.endsWith(u8, filename, pattern)) {
                        self.syntax = syntax;
                        break;
                    }
                } else if (std.mem.indexOf(u8, filename, pattern) != null) {
                    self.syntax = syntax;
                    break;
                }
            }
            if (self.syntax != null) break;
        }

        for (0..self.rows.items.len) |i| {
            try self.updateSyntax(i);
        }
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

    fn rowRxToCx(_: *const Editor, row: EditorRow, rx: usize) usize {
        var cur_rx: usize = 0;
        var cx: usize = 0;
        while (cx < row.len()) : (cx += 1) {
            if (row.chars[cx] == '\t') {
                cur_rx += (KILO_TAB_STOP - 1) - (cur_rx % KILO_TAB_STOP);
            }
            cur_rx += 1;
            if (cur_rx > rx) return cx;
        }
        return cx;
    }

    fn updateRow(self: *Editor, row_index: usize) !void {
        const row = &self.rows.items[row_index];
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
        try self.updateSyntax(row_index);
    }

    fn updateSyntax(self: *Editor, row_index: usize) !void {
        const row = &self.rows.items[row_index];
        self.allocator.free(row.hl);
        row.hl = try self.allocator.alloc(EditorHighlight, row.renderLen());
        @memset(row.hl, .normal);

        const syntax = self.syntax orelse {
            row.hl_open_comment = false;
            return;
        };

        const scs = syntax.singleline_comment_start orelse "";
        const mcs = syntax.multiline_comment_start orelse "";
        const mce = syntax.multiline_comment_end orelse "";

        var prev_sep = true;
        var in_string: u8 = 0;
        var in_comment = row_index > 0 and self.rows.items[row_index - 1].hl_open_comment;
        var i: usize = 0;
        while (i < row.renderLen()) {
            const c = row.render[i];
            const prev_hl: EditorHighlight = if (i > 0) row.hl[i - 1] else .normal;

            if (scs.len > 0 and in_string == 0 and !in_comment) {
                if (i + scs.len <= row.renderLen() and std.mem.eql(u8, row.render[i .. i + scs.len], scs)) {
                    @memset(row.hl[i..], .comment);
                    break;
                }
            }

            if (mcs.len > 0 and mce.len > 0 and in_string == 0) {
                if (in_comment) {
                    row.hl[i] = .ml_comment;
                    if (i + mce.len <= row.renderLen() and std.mem.eql(u8, row.render[i .. i + mce.len], mce)) {
                        @memset(row.hl[i .. i + mce.len], .ml_comment);
                        i += mce.len;
                        in_comment = false;
                        prev_sep = true;
                        continue;
                    } else {
                        i += 1;
                        continue;
                    }
                } else if (i + mcs.len <= row.renderLen() and std.mem.eql(u8, row.render[i .. i + mcs.len], mcs)) {
                    @memset(row.hl[i .. i + mcs.len], .ml_comment);
                    i += mcs.len;
                    in_comment = true;
                    continue;
                }
            }

            if (syntax.flags.highlight_strings) {
                if (in_string != 0) {
                    row.hl[i] = .string;
                    if (c == '\\' and i + 1 < row.renderLen()) {
                        row.hl[i + 1] = .string;
                        i += 2;
                        prev_sep = true;
                        continue;
                    }
                    if (c == in_string) in_string = 0;
                    i += 1;
                    prev_sep = true;
                    continue;
                } else if (c == '"' or c == '\'') {
                    in_string = c;
                    row.hl[i] = .string;
                    i += 1;
                    continue;
                }
            }

            if (syntax.flags.highlight_numbers) {
                if ((std.ascii.isDigit(c) and (prev_sep or prev_hl == .number)) or
                    (c == '.' and prev_hl == .number))
                {
                    row.hl[i] = .number;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }

            if (prev_sep) {
                for (syntax.keywords) |kw_raw| {
                    const is_kw2 = kw_raw.len > 0 and kw_raw[kw_raw.len - 1] == '|';
                    const kw = if (is_kw2) kw_raw[0 .. kw_raw.len - 1] else kw_raw;
                    if (i + kw.len <= row.renderLen() and
                        std.mem.eql(u8, row.render[i .. i + kw.len], kw) and
                        (i + kw.len == row.renderLen() or isSeparator(row.render[i + kw.len])))
                    {
                        @memset(row.hl[i .. i + kw.len], if (is_kw2) .keyword2 else .keyword1);
                        i += kw.len;
                        prev_sep = false;
                        continue;
                    }
                }
            }

            prev_sep = isSeparator(c);
            i += 1;
        }

        const changed = row.hl_open_comment != in_comment;
        row.hl_open_comment = in_comment;
        if (changed and row_index + 1 < self.rows.items.len) {
            try self.updateSyntax(row_index + 1);
        }
    }

    fn appendRow(self: *Editor, line: []const u8) !void {
        try self.insertRow(self.rows.items.len, line);
    }

    fn insertRow(self: *Editor, at: usize, line: []const u8) !void {
        const chars = try self.allocator.alloc(u8, line.len);
        @memcpy(chars, line);
        try self.rows.insert(self.allocator, at, .{
            .chars = chars,
            .render = try self.allocator.alloc(u8, 0),
            .hl = try self.allocator.alloc(EditorHighlight, 0),
            .hl_open_comment = false,
        });
        try self.updateRow(at);
        self.dirty = true;
    }

    fn rowInsertChar(self: *Editor, row_index: usize, at: usize, c: u8) !void {
        const row = &self.rows.items[row_index];
        const insert_at = @min(at, row.len());
        const new_chars = try self.allocator.alloc(u8, row.len() + 1);
        @memcpy(new_chars[0..insert_at], row.chars[0..insert_at]);
        new_chars[insert_at] = c;
        @memcpy(new_chars[insert_at + 1 ..], row.chars[insert_at..]);

        self.allocator.free(row.chars);
        row.chars = new_chars;
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn rowAppendString(self: *Editor, row_index: usize, s: []const u8) !void {
        const row = &self.rows.items[row_index];
        const new_chars = try self.allocator.alloc(u8, row.len() + s.len);
        @memcpy(new_chars[0..row.len()], row.chars);
        @memcpy(new_chars[row.len()..], s);

        self.allocator.free(row.chars);
        row.chars = new_chars;
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn rowDeleteChar(self: *Editor, row_index: usize, at: usize) !void {
        const row = &self.rows.items[row_index];
        if (row.len() == 0 or at >= row.len()) return;

        const new_chars = try self.allocator.alloc(u8, row.len() - 1);
        @memcpy(new_chars[0..at], row.chars[0..at]);
        @memcpy(new_chars[at..], row.chars[at + 1 ..]);

        self.allocator.free(row.chars);
        row.chars = new_chars;
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn deleteRow(self: *Editor, at: usize) void {
        const row = self.rows.orderedRemove(at);
        self.allocator.free(row.chars);
        self.allocator.free(row.render);
        self.allocator.free(row.hl);
        self.dirty = true;
    }

    fn open(self: *Editor, filename: []const u8) !void {
        if (self.filename) |old_filename| {
            self.allocator.free(old_filename);
        }
        self.filename = try self.allocator.dupe(u8, filename);

        const cwd = std.fs.cwd();
        const file = try cwd.openFile(filename, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            try self.appendRow(std.mem.trimRight(u8, line, "\r"));
        }
        try self.selectSyntaxHighlight();
        self.dirty = false;
    }

    fn prompt(
        self: *Editor,
        comptime fmt: []const u8,
        callback: ?*const fn (*Editor, []const u8, EditorKey) anyerror!void,
    ) !?[]u8 {
        var input = std.ArrayList(u8).empty;
        defer input.deinit(self.allocator);

        while (true) {
            var prompt_buf: [256]u8 = undefined;
            const prompt_text = try std.fmt.bufPrint(&prompt_buf, fmt, .{input.items});
            try self.setStatusMessage(prompt_text);
            try self.refreshScreen();

            const key = (try editorReadKey()) orelse continue;
            var should_cancel = false;
            var should_submit = false;
            switch (key) {
                .byte => |c| {
                    if (c == '\x1b') {
                        should_cancel = true;
                    } else if (c == '\r') {
                        continue;
                    } else if (c == ctrlKey('h') or c == 127) {
                        _ = input.pop();
                    } else if (!std.ascii.isControl(c) and c < 128) {
                        try input.append(self.allocator, c);
                    }
                },
                .delete => {
                    _ = input.pop();
                },
                .enter => {
                    should_submit = true;
                },
                else => {},
            }

            if (callback) |cb| {
                try cb(self, input.items, key);
            }

            if (should_cancel) {
                try self.setStatusMessage("Save aborted");
                return null;
            }

            if (should_submit and input.items.len != 0) {
                try self.setStatusMessage("");
                return try input.toOwnedSlice(self.allocator);
            }
        }
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
        if (self.filename == null) {
            const filename = (try self.prompt("Save as: {s} (ESC to cancel)", null)) orelse {
                try self.setStatusMessage("Save aborted");
                return;
            };
            self.filename = filename;
            try self.selectSyntaxHighlight();
        }

        const filename = self.filename.?;

        const contents = try self.rowsToString();
        defer self.allocator.free(contents);

        const cwd = std.fs.cwd();
        const file = try cwd.createFile(filename, .{ .truncate = true });
        defer file.close();

        try file.writeAll(contents);
        self.dirty = false;

        var status_buf: [80]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "{d} bytes written to disk", .{contents.len});
        try self.setStatusMessage(status);
    }

    fn findCallback(self: *Editor, query: []const u8, key: EditorKey) !void {
        if (self.savedHlLine) |saved_line| {
            if (self.savedHl) |saved_hl| {
                @memcpy(self.rows.items[saved_line].hl, saved_hl);
                self.allocator.free(saved_hl);
                self.savedHl = null;
            }
            self.savedHlLine = null;
        }

        switch (key) {
            .arrow_right, .arrow_down => self.searchDirection = 1,
            .arrow_left, .arrow_up => self.searchDirection = -1,
            else => {
                self.searchLastMatch = null;
                self.searchDirection = 1;
                if (key == .enter or (key == .byte and key.byte == '\x1b')) return;
            },
        }

        if (query.len == 0) return;

        var current: isize = if (self.searchLastMatch) |match| @intCast(match) else -1;

        for (0..self.rows.items.len) |_| {
            current += self.searchDirection;
            if (current == -1) {
                current = @intCast(self.rows.items.len - 1);
            } else if (current == @as(isize, @intCast(self.rows.items.len))) {
                current = 0;
            }

            const row_index: usize = @intCast(current);
            const row = self.rows.items[row_index];
            if (std.mem.indexOf(u8, row.render, query)) |match_index| {
                self.searchLastMatch = row_index;
                self.cy = row_index;
                self.cx = self.rowRxToCx(row, match_index);
                self.rowOff = self.rows.items.len;
                self.colOff = 0;
                self.savedHlLine = row_index;
                self.savedHl = try self.allocator.dupe(EditorHighlight, self.rows.items[row_index].hl[match_index .. match_index + query.len]);
                @memset(self.rows.items[row_index].hl[match_index .. match_index + query.len], .match);
                break;
            }
        }
    }

    fn find(self: *Editor) !void {
        const saved_cx = self.cx;
        const saved_cy = self.cy;
        const saved_col_off = self.colOff;
        const saved_row_off = self.rowOff;

        const query = (try self.prompt("Search: {s} (ESC to cancel)", Editor.findCallback)) orelse {
            self.cx = saved_cx;
            self.cy = saved_cy;
            self.colOff = saved_col_off;
            self.rowOff = saved_row_off;
            try self.setStatusMessage("");
            return;
        };
        defer self.allocator.free(query);
    }

    fn setStatusMessage(self: *Editor, message: []const u8) !void {
        if (self.statusMessage) |status_message| {
            self.allocator.free(status_message);
        }
        self.statusMessage = try self.allocator.dupe(u8, message);
    }

    fn drawStatusBar(self: *const Editor, ab: *std.ArrayList(u8)) !void {
        try ab.appendSlice(self.allocator, "\x1b[7m");

        var status_buf: [80]u8 = undefined;
        const filename = self.filename orelse "[No Name]";
        const status = try std.fmt.bufPrint(
            &status_buf,
            "{s} - {d} lines {s}",
            .{ filename[0..@min(filename.len, 20)], self.rows.items.len, if (self.dirty) "(modified)" else "" },
        );

        var rstatus_buf: [80]u8 = undefined;
        const filetype = if (self.syntax) |syntax| syntax.filetype else "no ft";
        const rstatus = try std.fmt.bufPrint(&rstatus_buf, "{s} | {d}/{d}", .{ filetype, self.cy + 1, self.rows.items.len });

        var len: usize = @min(status.len, self.screenCols);
        try ab.appendSlice(self.allocator, status[0..len]);

        while (len < self.screenCols) {
            if (self.screenCols - len == rstatus.len) {
                try ab.appendSlice(self.allocator, rstatus);
                break;
            }

            try ab.append(self.allocator, ' ');
            len += 1;
        }

        try ab.appendSlice(self.allocator, "\x1b[m");
    }

    fn drawMessageBar(self: *const Editor, ab: *std.ArrayList(u8)) !void {
        try ab.appendSlice(self.allocator, "\x1b[K");
        if (self.statusMessage) |status_message| {
            const len = @min(status_message.len, self.screenCols);
            try ab.appendSlice(self.allocator, status_message[0..len]);
        }
    }

    fn insertChar(self: *Editor, c: u8) !void {
        if (self.cy == self.rows.items.len) {
            try self.appendRow("");
        }

        try self.rowInsertChar(self.cy, self.cx, c);
        self.cx += 1;
    }

    fn insertNewline(self: *Editor) !void {
        if (self.cx == 0) {
            try self.insertRow(self.cy, "");
        } else {
            const row = self.rows.items[self.cy];
            try self.insertRow(self.cy + 1, row.chars[self.cx..]);

            const new_chars = try self.allocator.alloc(u8, self.cx);
            @memcpy(new_chars, row.chars[0..self.cx]);

            self.allocator.free(self.rows.items[self.cy].chars);
            self.rows.items[self.cy].chars = new_chars;
            try self.updateRow(self.cy);
            self.dirty = true;
        }

        self.cy += 1;
        self.cx = 0;
    }

    fn deleteChar(self: *Editor) !void {
        if (self.cy == self.rows.items.len) return;
        if (self.cx == 0 and self.cy == 0) return;

        if (self.cx > 0) {
            try self.rowDeleteChar(self.cy, self.cx - 1);
            self.cx -= 1;
        } else {
            const prev_row_len = self.rowLen(self.cy - 1);
            const current_chars = self.rows.items[self.cy].chars;
            try self.rowAppendString(self.cy - 1, current_chars);
            self.deleteRow(self.cy);
            self.cy -= 1;
            self.cx = prev_row_len;
        }
    }

    fn drawRows(self: *const Editor, ab: *std.ArrayList(u8)) !void {
        for (0..self.screenRows) |y| {
            const fileRow = y + self.rowOff;
            if (fileRow < self.rows.items.len) {
                const row = self.rows.items[fileRow];
                if (self.colOff < row.renderLen()) {
                    const len = @min(row.renderLen() - self.colOff, self.screenCols);
                    const render_slice = row.render[self.colOff .. self.colOff + len];
                    const hl_slice = row.hl[self.colOff .. self.colOff + len];
                    var current_color: ?EditorHighlight = null;
                    var span_start: usize = 0;
                    for (hl_slice, 0..) |hl, i| {
                        if (current_color == null or current_color.? != hl) {
                            if (current_color != null) {
                                try ab.appendSlice(self.allocator, render_slice[span_start..i]);
                            }
                            try ab.appendSlice(self.allocator, Editor.syntaxToColor(hl));
                            current_color = hl;
                            span_start = i;
                        }
                    }
                    try ab.appendSlice(self.allocator, render_slice[span_start..]);
                    try ab.appendSlice(self.allocator, "\x1b[39m");
                }
            } else if (self.rows.items.len == 0 and y == self.screenRows / 3) {
                const welcome = "Kilo Zig -- version " ++ KILO_ZIG_VERSION;
                const padding = (self.screenCols - welcome.len) / 2;
                if (padding > 0) {
                    try ab.appendSlice(self.allocator, "~");
                    for (0..padding - 1) |_| {
                        try ab.append(self.allocator, ' ');
                    }
                }
                try ab.appendSlice(self.allocator, welcome);
            } else {
                try ab.appendSlice(self.allocator, "~");
            }

            try ab.appendSlice(self.allocator, "\x1b[K");
            if (y < self.screenRows - 1) {
                try ab.appendSlice(self.allocator, "\r\n");
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

        // Build the full frame in memory first, then write it in one shot.
        var ab = std.ArrayList(u8).empty;
        defer ab.deinit(self.allocator);

        try ab.appendSlice(self.allocator, "\x1b[?25l");
        try ab.appendSlice(self.allocator, "\x1b[H");

        try self.drawRows(&ab);
        try ab.appendSlice(self.allocator, "\r\n");
        try self.drawStatusBar(&ab);
        try ab.appendSlice(self.allocator, "\r\n");
        try self.drawMessageBar(&ab);

        try ab.writer(self.allocator).print("\x1b[{d};{d}H", .{ (self.cy - self.rowOff) + 1, (self.rx - self.colOff) + 1 });
        try ab.appendSlice(self.allocator, "\x1b[?25h");
        _ = try std.posix.write(std.posix.STDOUT_FILENO, ab.items);
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
            .byte => |c| switch (c) {
                ctrlKey('q') => {
                    if (self.dirty and self.quitTimes > 0) {
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
                },
                ctrlKey('s') => try self.save(),
                ctrlKey('f') => try self.find(),
                ctrlKey('h'), 127 => try self.deleteChar(),
                ctrlKey('l'), '\x1b' => {},
                else => try self.insertChar(c),
            },
            .arrow_left, .arrow_right, .arrow_up, .arrow_down => self.moveCursor(key),
            .enter => try self.insertNewline(),
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
            .delete => {
                self.moveCursor(.arrow_right);
                try self.deleteChar();
            },
        }

        self.quitTimes = KILO_QUIT_TIMES;
        return true;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_termios = enableRawMode() catch {
        std.log.err("Failed to enable raw mode.", .{});
        return;
    };
    defer disableRawMode(original_termios) catch {
        std.log.err("Failed to disable raw mode.", .{});
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    var editor = try Editor.init(allocator);
    defer editor.deinit();
    try editor.setStatusMessage("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");
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

    try kilo_zig.bufferedPrint();
}
