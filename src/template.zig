const std = @import("std");

pub const TemplateError = error{
    PartialNotFound,
    LayoutNotFound,
    UnclosedTag,
    OutOfMemory,
    InvalidPath,
    PartialDepthExceeded,
};

const max_partial_depth = 32;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    layouts_dir: []const u8,
    partials_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, layouts_dir: []const u8, partials_dir: []const u8) Engine {
        return .{
            .allocator = allocator,
            .layouts_dir = layouts_dir,
            .partials_dir = partials_dir,
        };
    }

    pub fn render(self: *const Engine, tpl: []const u8, variables: std.StringHashMap([]const u8)) TemplateError![]u8 {
        return self.renderDepth(tpl, variables, 0);
    }

    fn renderDepth(self: *const Engine, tpl: []const u8, variables: std.StringHashMap([]const u8), depth: usize) TemplateError![]u8 {
        if (depth > max_partial_depth) return TemplateError.PartialDepthExceeded;

        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(self.allocator);

        var i: usize = 0;
        while (i < tpl.len) {
            if (i + 2 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{' and tpl[i + 2] == '{') {
                const tag_start = i + 3;
                const close_idx = std.mem.indexOf(u8, tpl[tag_start..], "}}}") orelse
                    return TemplateError.UnclosedTag;
                const tag_content = std.mem.trim(u8, tpl[tag_start .. tag_start + close_idx], " \t");

                if (variables.get(tag_content)) |value| {
                    if (isRawBuiltin(tag_content)) {
                        output.appendSlice(self.allocator, value) catch return TemplateError.OutOfMemory;
                    } else {
                        appendVariable(self.allocator, &output, value) catch return TemplateError.OutOfMemory;
                    }
                }
                i = tag_start + close_idx + 3;
            } else if (i + 1 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{') {
                const tag_start = i + 2;
                const close_idx = std.mem.indexOf(u8, tpl[tag_start..], "}}") orelse
                    return TemplateError.UnclosedTag;
                const tag_content = std.mem.trim(u8, tpl[tag_start .. tag_start + close_idx], " \t");

                if (tag_content.len > 0 and tag_content[0] == '>') {
                    const partial_name = std.mem.trim(u8, tag_content[1..], " \t");
                    const partial_content = self.loadPartial(partial_name) catch |err| {
                        if (err == error.FileNotFound) return TemplateError.PartialNotFound;
                        return TemplateError.OutOfMemory;
                    };
                    defer self.allocator.free(partial_content);
                    const rendered = try self.renderDepth(partial_content, variables, depth + 1);
                    defer self.allocator.free(rendered);
                    output.appendSlice(self.allocator, rendered) catch return TemplateError.OutOfMemory;
                } else {
                    if (variables.get(tag_content)) |value| {
                        if (isRawBuiltin(tag_content)) {
                            output.appendSlice(self.allocator, value) catch return TemplateError.OutOfMemory;
                        } else {
                            appendVariable(self.allocator, &output, value) catch return TemplateError.OutOfMemory;
                        }
                    }
                }
                i = tag_start + close_idx + 2;
            } else {
                output.append(self.allocator, tpl[i]) catch return TemplateError.OutOfMemory;
                i += 1;
            }
        }

        return output.toOwnedSlice(self.allocator) catch return TemplateError.OutOfMemory;
    }

    pub fn renderWithLayout(self: *const Engine, layout_name: []const u8, content: []const u8, variables: std.StringHashMap([]const u8)) TemplateError![]u8 {
        const layout = self.loadLayout(layout_name) catch |err| {
            if (err == error.FileNotFound) return TemplateError.LayoutNotFound;
            return TemplateError.OutOfMemory;
        };
        defer self.allocator.free(layout);

        var vars_with_content = std.StringHashMap([]const u8).init(self.allocator);
        defer vars_with_content.deinit();

        var iter = variables.iterator();
        while (iter.next()) |entry| {
            vars_with_content.put(entry.key_ptr.*, entry.value_ptr.*) catch return TemplateError.OutOfMemory;
        }
        vars_with_content.put("content", content) catch return TemplateError.OutOfMemory;

        return self.render(layout, vars_with_content);
    }

    fn loadPartial(self: *const Engine, name: []const u8) ![]u8 {
        if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "/") != null) {
            return TemplateError.InvalidPath;
        }
        const path = try std.fs.path.join(self.allocator, &.{ self.partials_dir, name });
        defer self.allocator.free(path);
        const path_with_ext = try std.mem.concat(self.allocator, u8, &.{ path, ".html" });
        defer self.allocator.free(path_with_ext);
        return readFile(self.allocator, path_with_ext) catch |err| {
            if (err == error.FileNotFound) return readFile(self.allocator, path);
            return err;
        };
    }

    fn loadLayout(self: *const Engine, name: []const u8) ![]u8 {
        if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "/") != null) {
            return TemplateError.InvalidPath;
        }
        const path = try std.fs.path.join(self.allocator, &.{ self.layouts_dir, name });
        defer self.allocator.free(path);
        const path_with_ext = try std.mem.concat(self.allocator, u8, &.{ path, ".html" });
        defer self.allocator.free(path_with_ext);
        return readFile(self.allocator, path_with_ext) catch |err| {
            if (err == error.FileNotFound) return readFile(self.allocator, path);
            return err;
        };
    }
};

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    try ensureNoSymlinkComponents(allocator, path);
    const file = openFileNoFollow(path) catch |err| return err;
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file) return error.InvalidPath;
    return file.readToEndAlloc(allocator, 1024 * 1024) catch |err| return err;
}

fn openFileNoFollow(path: []const u8) !std.fs.File {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(std.posix.O, "NOFOLLOW")) flags.NOFOLLOW = true;
    const fd = try std.posix.openat(std.fs.cwd().fd, path, flags, 0);
    return .{ .handle = fd };
}

fn appendHtmlEscaped(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => try output.appendSlice(allocator, "&amp;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#39;"),
            else => try output.append(allocator, c),
        }
    }
}

fn isRawBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "content") or std.mem.eql(u8, name, "nav_html") or std.mem.eql(u8, name, "toc");
}

fn appendVariable(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    if (isUrlAttributeContext(output.items)) {
        if (isSafeUrl(value)) {
            try appendHtmlEscaped(allocator, output, value);
        } else {
            try output.append(allocator, '#');
        }
    } else {
        try appendHtmlEscaped(allocator, output, value);
    }
}

fn isUrlAttributeContext(output: []const u8) bool {
    const trimmed = std.mem.trimRight(u8, output, " \t\r\n");
    if (trimmed.len == 0) return false;
    const quote = trimmed[trimmed.len - 1];
    if (quote != '"' and quote != '\'') return false;

    const before_quote = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    if (before_quote.len == 0 or before_quote[before_quote.len - 1] != '=') return false;

    const before_equals = std.mem.trimRight(u8, before_quote[0 .. before_quote.len - 1], " \t\r\n");
    if (before_equals.len < 3) return false;

    return endsWithAttributeName(before_equals, "href") or endsWithAttributeName(before_equals, "src");
}

fn endsWithAttributeName(text: []const u8, name: []const u8) bool {
    if (text.len < name.len) return false;
    const start = text.len - name.len;
    if (!std.ascii.eqlIgnoreCase(text[start..], name)) return false;
    if (start == 0) return true;
    const prev = text[start - 1];
    return std.ascii.isWhitespace(prev) or prev == '<';
}

fn isSafeUrl(url: []const u8) bool {
    if (url.len == 0) return false;

    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }

    if (url[0] == '#') return true;
    if (url[0] == '/') return url.len == 1 or url[1] != '/';
    if (std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../")) return true;

    const colon_idx = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    const first_delim = firstUrlDelimiter(url) orelse url.len;
    if (colon_idx > first_delim) return true;

    const scheme = url[0..colon_idx];
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto");
}

fn firstUrlDelimiter(url: []const u8) ?usize {
    var result: ?usize = null;
    for ([_]u8{ '/', '?', '#' }) |delimiter| {
        if (std.mem.indexOfScalar(u8, url, delimiter)) |idx| {
            if (result == null or idx < result.?) result = idx;
        }
    }
    return result;
}

fn ensureNoSymlinkComponents(allocator: std.mem.Allocator, path: []const u8) !void {
    const resolved = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved);

    if (std.mem.eql(u8, resolved, std.fs.path.sep_str)) return;

    var current = if (std.fs.path.isAbsolute(resolved)) try allocator.dupe(u8, std.fs.path.sep_str) else try allocator.dupe(u8, ".");
    defer allocator.free(current);

    var parts = std.mem.tokenizeScalar(u8, resolved, std.fs.path.sep);
    while (parts.next()) |part| {
        const next = try std.fs.path.join(allocator, &.{ current, part });
        defer allocator.free(next);

        const kind = entryKind(current, part) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(current);
                current = try allocator.dupe(u8, next);
                continue;
            },
            else => return err,
        };
        if (kind == .sym_link) return error.SymlinkInTemplatePath;

        allocator.free(current);
        current = try allocator.dupe(u8, next);
    }
}

fn entryKind(dir_path: []const u8, name: []const u8) !std.fs.File.Kind {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.kind;
    }

    return error.FileNotFound;
}

test "template escapes double braces and only renders content triple braces raw" {
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("title", "<script>alert(1)</script>");
    try vars.put("content", "<p>safe html</p>");

    const engine = Engine.init(std.testing.allocator, "", "");
    const rendered = try engine.render("<title>{{title}}</title>{{{title}}}{{{content}}}", vars);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<p>safe html</p>") != null);
}

test "template renders built-in content raw with double braces" {
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("content", "<h1>notes</h1>");

    const engine = Engine.init(std.testing.allocator, "", "");
    const rendered = try engine.render("<main>{{content}}</main>", vars);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<h1>notes</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "&lt;h1&gt;") == null);
}

test "template sanitizes unsafe url attribute variables" {
    var vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer vars.deinit();
    try vars.put("link", "javascript:alert(1)");

    const engine = Engine.init(std.testing.allocator, "", "");
    const rendered = try engine.render("<a href=\"{{link}}\">x</a>", vars);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "href=\"#\"") != null);
}
