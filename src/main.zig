const std = @import("std");

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

    fn color(self: EditorHighlight) []const u8 {
        return switch (self) {
            .comment, .ml_comment => "\x1b[36m",
            .keyword1 => "\x1b[33m",
            .keyword2 => "\x1b[32m",
            .string => "\x1b[35m",
            .number => "\x1b[31m",
            .match => "\x1b[34m",
            .normal => "\x1b[39m",
        };
    }
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

const Terminal = struct {
    original_termios: std.posix.termios,

    fn init() !Terminal {
        const original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original_termios;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .original_termios = original_termios };
    }

    fn deinit(self: Terminal) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {
            std.log.err("Failed to disable raw mode.", .{});
        };
    }

    fn readByte() !?u8 {
        var stdin = std.fs.File.stdin();
        var c: [1]u8 = undefined;
        const bytes_read = try stdin.read(&c);
        if (bytes_read == 0) return null;
        return c[0];
    }

    fn readKey() !?EditorKey {
        const first = (try readByte()) orelse return null;
        if (first == '\r') return .enter;
        if (first != '\x1b') return .{ .byte = first };

        const second = (try readByte()) orelse return .{ .byte = first };
        const third = (try readByte()) orelse return .{ .byte = first };

        if (second == '[') {
            if (third >= '0' and third <= '9') {
                const fourth = (try readByte()) orelse return .{ .byte = first };
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
            const c = (try readByte()) orelse continue;
            if (c == 'R') break;
            buf[i] = c;
            i += 1;
        }
        buf[i] = 0;

        if (buf[0] != '\x1b' or buf[1] != '[') return error.UnexpectedResponse;

        var iter = std.mem.splitScalar(u8, buf[2..i], ';');
        const rows = std.fmt.parseInt(u16, iter.next() orelse return error.UnexpectedResponse, 10) catch return error.UnexpectedResponse;
        const cols = std.fmt.parseInt(u16, iter.next() orelse return error.UnexpectedResponse, 10) catch return error.UnexpectedResponse;

        return .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
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

    fn ctrlKey(k: u8) u8 {
        return k & 0x1f;
    }
};

const EditorRow = struct {
    chars: std.ArrayList(u8),
    render: []u8,
    hl: []EditorHighlight,
    hl_open_comment: bool,

    fn deinit(self: *EditorRow, allocator: std.mem.Allocator) void {
        self.chars.deinit(allocator);
        allocator.free(self.render);
        allocator.free(self.hl);
    }

    fn len(self: EditorRow) usize {
        return self.chars.items.len;
    }

    fn renderLen(self: EditorRow) usize {
        return self.render.len;
    }

    fn cxToRx(self: EditorRow, cx: usize) usize {
        var rx: usize = 0;
        for (self.chars.items[0..@min(cx, self.len())]) |c| {
            if (c == '\t') {
                rx += (KILO_TAB_STOP - 1) - (rx % KILO_TAB_STOP);
            }
            rx += 1;
        }
        return rx;
    }

    fn rxToCx(self: EditorRow, rx: usize) usize {
        var cur_rx: usize = 0;
        var cx: usize = 0;
        while (cx < self.len()) : (cx += 1) {
            if (self.chars.items[cx] == '\t') {
                cur_rx += (KILO_TAB_STOP - 1) - (cur_rx % KILO_TAB_STOP);
            }
            cur_rx += 1;
            if (cur_rx > rx) return cx;
        }
        return cx;
    }
};

const Cursor = struct {
    x: usize = 0,
    y: usize = 0,
    rx: usize = 0,
};

const Viewport = struct {
    row_off: usize = 0,
    col_off: usize = 0,
    rows: usize = 24,
    cols: usize = 80,
};

const SearchState = struct {
    last_match: ?usize = null,
    direction: isize = 1,
    saved_hl_line: ?usize = null,
    saved_hl: ?[]EditorHighlight = null,
};

const Editor = struct {
    allocator: std.mem.Allocator,
    syntax: ?*const EditorSyntax = null,
    filename: ?[]u8 = null,
    statusMessage: ?[]u8 = null,
    dirty: bool = false,
    quitTimes: usize = KILO_QUIT_TIMES,
    cursor: Cursor = .{},
    view: Viewport = .{},
    search: SearchState = .{},
    rows: std.ArrayList(EditorRow),

    fn init(allocator: std.mem.Allocator) !Editor {
        const ws = try Terminal.getWindowSize();
        return .{
            .allocator = allocator,
            .view = .{ .rows = ws.row - 2, .cols = ws.col },
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
        if (self.search.saved_hl) |saved_hl| {
            self.allocator.free(saved_hl);
        }
        for (self.rows.items) |*row| {
            row.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);
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

    fn updateRow(self: *Editor, row_index: usize) !void {
        const row = &self.rows.items[row_index];
        var tabs: usize = 0;
        for (row.chars.items) |c| {
            if (c == '\t') tabs += 1;
        }

        self.allocator.free(row.render);
        row.render = try self.allocator.alloc(u8, row.len() + tabs * (KILO_TAB_STOP - 1));

        var idx: usize = 0;
        for (row.chars.items) |c| {
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
                if (std.mem.startsWith(u8, row.render[i..], scs)) {
                    @memset(row.hl[i..], .comment);
                    break;
                }
            }

            if (mcs.len > 0 and mce.len > 0 and in_string == 0) {
                if (in_comment) {
                    row.hl[i] = .ml_comment;
                    if (std.mem.startsWith(u8, row.render[i..], mce)) {
                        @memset(row.hl[i .. i + mce.len], .ml_comment);
                        i += mce.len;
                        in_comment = false;
                        prev_sep = true;
                        continue;
                    } else {
                        i += 1;
                        continue;
                    }
                } else if (std.mem.startsWith(u8, row.render[i..], mcs)) {
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
                    if (std.mem.startsWith(u8, row.render[i..], kw) and
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
        var chars = std.ArrayList(u8).empty;
        try chars.appendSlice(self.allocator, line);
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
        try row.chars.insert(self.allocator, @min(at, row.len()), c);
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn rowAppendString(self: *Editor, row_index: usize, s: []const u8) !void {
        const row = &self.rows.items[row_index];
        try row.chars.appendSlice(self.allocator, s);
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn rowDeleteChar(self: *Editor, row_index: usize, at: usize) !void {
        const row = &self.rows.items[row_index];
        if (row.len() == 0 or at >= row.len()) return;
        _ = row.chars.orderedRemove(at);
        try self.updateRow(row_index);
        self.dirty = true;
    }

    fn deleteRow(self: *Editor, at: usize) void {
        var row = self.rows.orderedRemove(at);
        row.deinit(self.allocator);
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

            const key = (try Terminal.readKey()) orelse continue;
            var should_cancel = false;
            var should_submit = false;
            switch (key) {
                .byte => |c| switch (c) {
                    '\x1b' => should_cancel = true,
                    Terminal.ctrlKey('h'), 127 => _ = input.pop(),
                    else => if (!std.ascii.isControl(c) and c < 128) {
                        try input.append(self.allocator, c);
                    },
                },
                .delete => _ = input.pop(),
                .enter => should_submit = true,
                else => {},
            }

            if (callback) |cb| try cb(self, input.items, key);
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

        const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
        defer file.close();

        var bytes: usize = 0;
        for (self.rows.items) |row| {
            try file.writeAll(row.chars.items);
            try file.writeAll("\n");
            bytes += row.chars.items.len + 1;
        }
        self.dirty = false;

        var status_buf: [80]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "{d} bytes written to disk", .{bytes});
        try self.setStatusMessage(status);
    }

    fn findCallback(self: *Editor, query: []const u8, key: EditorKey) !void {
        if (self.search.saved_hl_line) |saved_line| {
            if (self.search.saved_hl) |saved_hl| {
                @memcpy(self.rows.items[saved_line].hl, saved_hl);
                self.allocator.free(saved_hl);
                self.search.saved_hl = null;
            }
            self.search.saved_hl_line = null;
        }

        switch (key) {
            .arrow_right, .arrow_down => self.search.direction = 1,
            .arrow_left, .arrow_up => self.search.direction = -1,
            else => {
                self.search.last_match = null;
                self.search.direction = 1;
                if (key == .enter or (key == .byte and key.byte == '\x1b')) return;
            },
        }

        if (query.len == 0) return;

        var current: isize = if (self.search.last_match) |match| @intCast(match) else -1;

        for (0..self.rows.items.len) |_| {
            current += self.search.direction;
            if (current == -1) {
                current = @intCast(self.rows.items.len - 1);
            } else if (current == @as(isize, @intCast(self.rows.items.len))) {
                current = 0;
            }

            const row_index: usize = @intCast(current);
            const row = self.rows.items[row_index];
            if (std.mem.indexOf(u8, row.render, query)) |match_index| {
                self.search.last_match = row_index;
                self.cursor.y = row_index;
                self.cursor.x = row.rxToCx(match_index);
                self.view.row_off = self.rows.items.len;
                self.view.col_off = 0;
                self.search.saved_hl_line = row_index;
                self.search.saved_hl = try self.allocator.dupe(EditorHighlight, self.rows.items[row_index].hl[match_index .. match_index + query.len]);
                @memset(self.rows.items[row_index].hl[match_index .. match_index + query.len], .match);
                break;
            }
        }
    }

    fn find(self: *Editor) !void {
        const saved_cursor = self.cursor;
        const saved_view = self.view;

        const query = (try self.prompt("Search: {s} (ESC to cancel)", Editor.findCallback)) orelse {
            self.cursor = saved_cursor;
            self.view = saved_view;
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
        const rstatus = try std.fmt.bufPrint(&rstatus_buf, "{s} | {d}/{d}", .{ filetype, self.cursor.y + 1, self.rows.items.len });

        var len: usize = @min(status.len, self.view.cols);
        try ab.appendSlice(self.allocator, status[0..len]);

        while (len < self.view.cols) {
            if (self.view.cols - len == rstatus.len) {
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
            const len = @min(status_message.len, self.view.cols);
            try ab.appendSlice(self.allocator, status_message[0..len]);
        }
    }

    fn insertChar(self: *Editor, c: u8) !void {
        if (self.cursor.y == self.rows.items.len) {
            try self.appendRow("");
        }

        try self.rowInsertChar(self.cursor.y, self.cursor.x, c);
        self.cursor.x += 1;
    }

    fn insertNewline(self: *Editor) !void {
        if (self.cursor.x == 0) {
            try self.insertRow(self.cursor.y, "");
        } else {
            const split_at = self.cursor.x;
            const tail = self.rows.items[self.cursor.y].chars.items[split_at..];
            try self.insertRow(self.cursor.y + 1, tail);
            self.rows.items[self.cursor.y].chars.shrinkRetainingCapacity(split_at);
            try self.updateRow(self.cursor.y);
            self.dirty = true;
        }

        self.cursor.y += 1;
        self.cursor.x = 0;
    }

    fn deleteChar(self: *Editor) !void {
        if (self.cursor.y == self.rows.items.len) return;
        if (self.cursor.x == 0 and self.cursor.y == 0) return;

        if (self.cursor.x > 0) {
            try self.rowDeleteChar(self.cursor.y, self.cursor.x - 1);
            self.cursor.x -= 1;
        } else {
            const prev_row_len = self.rowLen(self.cursor.y - 1);
            const current_chars = self.rows.items[self.cursor.y].chars.items;
            try self.rowAppendString(self.cursor.y - 1, current_chars);
            self.deleteRow(self.cursor.y);
            self.cursor.y -= 1;
            self.cursor.x = prev_row_len;
        }
    }

    fn drawRows(self: *const Editor, ab: *std.ArrayList(u8)) !void {
        for (0..self.view.rows) |y| {
            const fileRow = y + self.view.row_off;
            if (fileRow < self.rows.items.len) {
                const row = self.rows.items[fileRow];
                if (self.view.col_off < row.renderLen()) {
                    const len = @min(row.renderLen() - self.view.col_off, self.view.cols);
                    const render_slice = row.render[self.view.col_off .. self.view.col_off + len];
                    const hl_slice = row.hl[self.view.col_off .. self.view.col_off + len];
                    var current_color: ?EditorHighlight = null;
                    var span_start: usize = 0;
                    for (hl_slice, 0..) |hl, i| {
                        if (current_color == null or current_color.? != hl) {
                            if (current_color != null) {
                                try ab.appendSlice(self.allocator, render_slice[span_start..i]);
                            }
                            try ab.appendSlice(self.allocator, hl.color());
                            current_color = hl;
                            span_start = i;
                        }
                    }
                    try ab.appendSlice(self.allocator, render_slice[span_start..]);
                    try ab.appendSlice(self.allocator, "\x1b[39m");
                }
            } else if (self.rows.items.len == 0 and y == self.view.rows / 3) {
                const welcome = "Kilo Zig -- version " ++ KILO_ZIG_VERSION;
                const padding = (self.view.cols - welcome.len) / 2;
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
            if (y < self.view.rows - 1) {
                try ab.appendSlice(self.allocator, "\r\n");
            }
        }
    }

    fn scroll(self: *Editor) void {
        self.cursor.rx = 0;
        if (self.cursor.y < self.rows.items.len) {
            self.cursor.rx = self.rows.items[self.cursor.y].cxToRx(self.cursor.x);
        }

        if (self.cursor.y < self.view.row_off) {
            self.view.row_off = self.cursor.y;
        }

        if (self.cursor.y >= self.view.row_off + self.view.rows) {
            self.view.row_off = self.cursor.y - self.view.rows + 1;
        }

        if (self.cursor.rx < self.view.col_off) {
            self.view.col_off = self.cursor.rx;
        }

        if (self.cursor.rx >= self.view.col_off + self.view.cols) {
            self.view.col_off = self.cursor.rx - self.view.cols + 1;
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

        try ab.writer(self.allocator).print("\x1b[{d};{d}H", .{ (self.cursor.y - self.view.row_off) + 1, (self.cursor.rx - self.view.col_off) + 1 });
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
                if (self.cursor.x != 0) {
                    self.cursor.x -= 1;
                } else if (self.cursor.y > 0) {
                    self.cursor.y -= 1;
                    self.cursor.x = self.rowLen(self.cursor.y);
                }
            },
            .arrow_right => {
                const row_len = self.rowLen(self.cursor.y);
                if (self.cursor.x < row_len) {
                    self.cursor.x += 1;
                } else if (self.cursor.y < self.rows.items.len) {
                    self.cursor.y += 1;
                    self.cursor.x = 0;
                }
            },
            .arrow_up => {
                if (self.cursor.y != 0) self.cursor.y -= 1;
            },
            .arrow_down => {
                if (self.cursor.y < self.rows.items.len) self.cursor.y += 1;
            },
            else => {},
        }

        const row_len = self.rowLen(self.cursor.y);
        if (self.cursor.x > row_len) {
            self.cursor.x = row_len;
        }
    }

    fn processKeypress(self: *Editor) !bool {
        const key = (try Terminal.readKey()) orelse return true;
        switch (key) {
            .byte => |c| switch (c) {
                Terminal.ctrlKey('q') => {
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
                Terminal.ctrlKey('s') => try self.save(),
                Terminal.ctrlKey('f') => try self.find(),
                Terminal.ctrlKey('h'), 127 => try self.deleteChar(),
                Terminal.ctrlKey('l'), '\x1b' => {},
                else => try self.insertChar(c),
            },
            .arrow_left, .arrow_right, .arrow_up, .arrow_down => self.moveCursor(key),
            .enter => try self.insertNewline(),
            .page_up => {
                self.cursor.y = self.view.row_off;
                for (0..self.view.rows) |_| {
                    self.moveCursor(.arrow_up);
                }
            },
            .page_down => {
                self.cursor.y = @min(self.view.row_off + self.view.rows - 1, self.rows.items.len);
                for (0..self.view.rows) |_| {
                    self.moveCursor(.arrow_down);
                }
            },
            .home => self.cursor.x = 0,
            .end => self.cursor.x = self.rowLen(self.cursor.y),
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

    const terminal = Terminal.init() catch {
        std.log.err("Failed to enable raw mode.", .{});
        return;
    };
    defer terminal.deinit();

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
}
