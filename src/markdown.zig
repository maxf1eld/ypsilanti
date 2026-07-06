const std = @import("std");

const max_inline_depth = 64;

pub const Rendered = struct {
    html: []u8,
    toc: []u8,

    pub fn deinit(self: Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.html);
        allocator.free(self.toc);
    }
};

pub fn toHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const rendered = try render(allocator, input);
    allocator.free(rendered.toc);
    return rendered.html;
}

pub fn render(allocator: std.mem.Allocator, input: []const u8) !Rendered {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var toc_items: std.ArrayListUnmanaged(u8) = .empty;
    defer toc_items.deinit(allocator);

    var raw_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw_lines.deinit(allocator);
    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |raw_line| {
        try raw_lines.append(allocator, std.mem.trimRight(u8, raw_line, "\r"));
    }

    var footnotes = std.StringHashMap([]const u8).init(allocator);
    defer footnotes.deinit();

    var in_code_block = false;
    var code_lang: []const u8 = "";
    var code_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer code_buf.deinit(allocator);
    var in_list = false;
    var in_blockquote = false;
    var paragraph_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer paragraph_buf.deinit(allocator);

    var line_index: usize = 0;
    while (line_index < raw_lines.items.len) : (line_index += 1) {
        const line = raw_lines.items[line_index];

        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code_block) {
                try flushCodeBlock(allocator, &output, code_lang, code_buf.items);
                code_buf.clearRetainingCapacity();
                code_lang = "";
                in_code_block = false;
            } else {
                try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
                if (in_list) {
                    try output.appendSlice(allocator, "</ul>\n");
                    in_list = false;
                }
                if (in_blockquote) {
                    try output.appendSlice(allocator, "</blockquote>\n");
                    in_blockquote = false;
                }
                const lang = std.mem.trim(u8, line[3..], " \t");
                code_lang = if (isSafeLanguageClass(lang)) lang else "";
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            try code_buf.appendSlice(allocator, line);
            try code_buf.append(allocator, '\n');
            continue;
        }

        if (isShortcodeLine(line)) {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_list) {
                try output.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try output.appendSlice(allocator, "</blockquote>\n");
                in_blockquote = false;
            }
            if (try renderShortcodeLine(allocator, &output, line)) continue;
        }

        if (parseFootnoteDef(line)) |def| {
            try footnotes.put(def.id, def.text);
            continue;
        }

        if (line_index + 1 < raw_lines.items.len and isTableRow(line) and isTableDelimiter(raw_lines.items[line_index + 1])) {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_list) {
                try output.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try output.appendSlice(allocator, "</blockquote>\n");
                in_blockquote = false;
            }
            line_index = try renderTable(allocator, &output, raw_lines.items, line_index, &footnotes);
            continue;
        }

        if (line.len == 0) {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_list) {
                try output.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try output.appendSlice(allocator, "</blockquote>\n");
                in_blockquote = false;
            }
            continue;
        }

        if (line[0] == '#') {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_list) {
                try output.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            const level = countPrefix(line, '#');
            if (level <= 6 and level < line.len and line[level] == ' ') {
                const content = std.mem.trim(u8, line[level + 1 ..], " \t");
                const id = try headingId(allocator, content);
                defer allocator.free(id);
                try appendTocItem(allocator, &toc_items, level, id, content);
                try appendFmt(allocator, &output, "<h{d} id=\"", .{level});
                try appendEscaped(allocator, &output, id);
                try output.appendSlice(allocator, "\">");
                try appendInline(allocator, &output, content, &footnotes);
                try appendFmt(allocator, &output, "</h{d}>\n", .{level});
                continue;
            }
        }

        if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_blockquote) {
                try output.appendSlice(allocator, "</blockquote>\n");
                in_blockquote = false;
            }
            if (!in_list) {
                try output.appendSlice(allocator, "<ul>\n");
                in_list = true;
            }
            try output.appendSlice(allocator, "<li>");
            try appendInline(allocator, &output, line[2..], &footnotes);
            try output.appendSlice(allocator, "</li>\n");
            continue;
        }

        if (std.mem.startsWith(u8, line, "> ")) {
            try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
            if (in_list) {
                try output.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            if (!in_blockquote) {
                try output.appendSlice(allocator, "<blockquote>");
                in_blockquote = true;
            }
            try appendInline(allocator, &output, line[2..], &footnotes);
            try output.append(allocator, '\n');
            continue;
        }

        if (paragraph_buf.items.len > 0) {
            try paragraph_buf.append(allocator, ' ');
        }
        try paragraph_buf.appendSlice(allocator, line);
    }

    if (in_code_block) {
        try flushCodeBlock(allocator, &output, code_lang, code_buf.items);
    }
    try flushParagraph(allocator, &paragraph_buf, &output, &footnotes);
    if (in_list) {
        try output.appendSlice(allocator, "</ul>\n");
    }
    if (in_blockquote) {
        try output.appendSlice(allocator, "</blockquote>\n");
    }
    try appendFootnotes(allocator, &output, &footnotes);

    const toc = if (toc_items.items.len > 0) blk: {
        var toc: std.ArrayListUnmanaged(u8) = .empty;
        errdefer toc.deinit(allocator);
        try toc.appendSlice(allocator, "<nav class=\"toc\" aria-label=\"Table of contents\">\n<strong>contents</strong>\n<ol>\n");
        try toc.appendSlice(allocator, toc_items.items);
        try toc.appendSlice(allocator, "</ol>\n</nav>\n");
        break :blk try toc.toOwnedSlice(allocator);
    } else try allocator.dupe(u8, "");

    return .{ .html = try output.toOwnedSlice(allocator), .toc = toc };
}

fn flushCodeBlock(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), lang: []const u8, code: []const u8) !void {
    if (lang.len > 0) {
        try output.appendSlice(allocator, "<pre><code class=\"language-");
        try output.appendSlice(allocator, lang);
        try output.appendSlice(allocator, "\">");
    } else {
        try output.appendSlice(allocator, "<pre><code>");
    }
    try appendHighlightedCode(allocator, output, lang, code);
    try output.appendSlice(allocator, "</code></pre>\n");
}

fn appendHighlightedCode(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), lang: []const u8, code: []const u8) !void {
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try appendHighlightedLine(allocator, output, lang, line);
        try output.append(allocator, '\n');
    }
}

fn appendHighlightedLine(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), lang: []const u8, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (isLineCommentStart(lang, line[i..])) {
            try output.appendSlice(allocator, "<span class=\"tok-comment\">");
            try appendEscaped(allocator, output, line[i..]);
            try output.appendSlice(allocator, "</span>");
            return;
        }

        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            const start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (line[i] == quote) {
                    i += 1;
                    break;
                }
            }
            try output.appendSlice(allocator, "<span class=\"tok-string\">");
            try appendEscaped(allocator, output, line[start..i]);
            try output.appendSlice(allocator, "</span>");
            continue;
        }

        if (std.ascii.isDigit(line[i])) {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) : (i += 1) {}
            try output.appendSlice(allocator, "<span class=\"tok-number\">");
            try appendEscaped(allocator, output, line[start..i]);
            try output.appendSlice(allocator, "</span>");
            continue;
        }

        if (std.ascii.isAlphabetic(line[i]) or line[i] == '_') {
            const start = i;
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) : (i += 1) {}
            const word = line[start..i];
            if (isKeyword(lang, word)) {
                try output.appendSlice(allocator, "<span class=\"tok-keyword\">");
                try appendEscaped(allocator, output, word);
                try output.appendSlice(allocator, "</span>");
            } else {
                try appendEscaped(allocator, output, word);
            }
            continue;
        }

        switch (line[i]) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => try output.appendSlice(allocator, "&amp;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            else => try output.append(allocator, line[i]),
        }
        i += 1;
    }
}

fn isLineCommentStart(lang: []const u8, text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "//")) return true;
    if (std.ascii.eqlIgnoreCase(lang, "sh") or std.ascii.eqlIgnoreCase(lang, "bash") or std.ascii.eqlIgnoreCase(lang, "shell") or std.ascii.eqlIgnoreCase(lang, "zig")) {
        return std.mem.startsWith(u8, text, "#");
    }
    return false;
}

fn isKeyword(lang: []const u8, word: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(lang, "zig")) {
        return isOneOf(word, &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "defer", "try", "catch", "struct", "enum", "union", "error", "comptime", "break", "continue", "true", "false", "null" });
    }
    if (std.ascii.eqlIgnoreCase(lang, "js") or std.ascii.eqlIgnoreCase(lang, "javascript") or std.ascii.eqlIgnoreCase(lang, "ts") or std.ascii.eqlIgnoreCase(lang, "typescript")) {
        return isOneOf(word, &.{ "const", "let", "var", "function", "return", "if", "else", "for", "while", "class", "new", "await", "async", "import", "export", "from", "true", "false", "null", "undefined" });
    }
    if (std.ascii.eqlIgnoreCase(lang, "css")) {
        return isOneOf(word, &.{ "display", "position", "color", "background", "border", "margin", "padding", "font", "grid", "flex" });
    }
    return false;
}

fn isOneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |candidate| if (std.mem.eql(u8, word, candidate)) return true;
    return false;
}

fn appendTocItem(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), level: usize, id: []const u8, title: []const u8) !void {
    try output.appendSlice(allocator, "<li class=\"toc-level-");
    try appendFmt(allocator, output, "{d}", .{level});
    try output.appendSlice(allocator, "\"><a href=\"#");
    try appendEscaped(allocator, output, id);
    try output.appendSlice(allocator, "\">");
    try appendEscaped(allocator, output, title);
    try output.appendSlice(allocator, "</a></li>\n");
}

fn flushParagraph(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), output: *std.ArrayListUnmanaged(u8), footnotes: *const std.StringHashMap([]const u8)) !void {
    if (buf.items.len == 0) return;
    try output.appendSlice(allocator, "<p>");
    try appendInline(allocator, output, buf.items, footnotes);
    try output.appendSlice(allocator, "</p>\n");
    buf.clearRetainingCapacity();
}

fn countPrefix(line: []const u8, char: u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == char) count += 1 else break;
    }
    return count;
}

fn appendEscaped(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => try output.appendSlice(allocator, "&amp;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            else => try output.append(allocator, c),
        }
    }
}

fn appendFmt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
    try output.appendSlice(allocator, formatted);
}

fn appendInline(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, footnotes: *const std.StringHashMap([]const u8)) !void {
    try appendInlineDepth(allocator, output, text, footnotes, 0);
}

fn appendInlineDepth(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8, footnotes: *const std.StringHashMap([]const u8), depth: usize) !void {
    if (depth > max_inline_depth) return error.InlineDepthExceeded;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (findClosing(text[i + 1 ..], '`')) |end| {
                try output.appendSlice(allocator, "<code>");
                try appendEscaped(allocator, output, text[i + 1 .. i + 1 + end]);
                try output.appendSlice(allocator, "</code>");
                i += end + 2;
                continue;
            }
        }

        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (findClosingDouble(text[i + 2 ..], '*')) |end| {
                try output.appendSlice(allocator, "<strong>");
                try appendInlineDepth(allocator, output, text[i + 2 .. i + 2 + end], footnotes, depth + 1);
                try output.appendSlice(allocator, "</strong>");
                i += end + 4;
                continue;
            }
        }

        if (text[i] == '*') {
            if (findClosing(text[i + 1 ..], '*')) |end| {
                if (end > 0 and text[i + 1] != '*') {
                    try output.appendSlice(allocator, "<em>");
                    try appendInlineDepth(allocator, output, text[i + 1 .. i + 1 + end], footnotes, depth + 1);
                    try output.appendSlice(allocator, "</em>");
                    i += end + 2;
                    continue;
                }
            }
        }

        if (i + 2 < text.len and text[i] == '[' and text[i + 1] == '^') {
            if (findClosing(text[i + 2 ..], ']')) |end| {
                const id = text[i + 2 .. i + 2 + end];
                if (footnotes.get(id) != null) {
                    try output.appendSlice(allocator, "<sup id=\"fnref-");
                    try appendEscaped(allocator, output, id);
                    try output.appendSlice(allocator, "\"><a href=\"#fn-");
                    try appendEscaped(allocator, output, id);
                    try output.appendSlice(allocator, "\">[ ");
                    try appendEscaped(allocator, output, id);
                    try output.appendSlice(allocator, " ]</a></sup>");
                    i += end + 3;
                    continue;
                }
            }
        }

        if (text[i] == '[') {
            if (parseLink(text[i..])) |link| {
                try output.appendSlice(allocator, "<a href=\"");
                if (isSafeUrl(link.url)) {
                    try appendEscaped(allocator, output, link.url);
                } else {
                    try output.append(allocator, '#');
                }
                try output.appendSlice(allocator, "\">");
                try appendInlineDepth(allocator, output, link.text, footnotes, depth + 1);
                try output.appendSlice(allocator, "</a>");
                i += link.total_len;
                continue;
            }
        }

        switch (text[i]) {
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '&' => try output.appendSlice(allocator, "&amp;"),
            else => try output.append(allocator, text[i]),
        }
        i += 1;
    }
}

fn findClosing(text: []const u8, char: u8) ?usize {
    for (text, 0..) |c, idx| {
        if (c == char) return idx;
    }
    return null;
}

fn findClosingDouble(text: []const u8, char: u8) ?usize {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == char and text[i + 1] == char) return i;
    }
    return null;
}

fn isSafeLanguageClass(lang: []const u8) bool {
    if (lang.len == 0) return false;
    for (lang) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
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

const Link = struct {
    text: []const u8,
    url: []const u8,
    total_len: usize,
};

const FootnoteDef = struct {
    id: []const u8,
    text: []const u8,
};

fn parseFootnoteDef(line: []const u8) ?FootnoteDef {
    if (!std.mem.startsWith(u8, line, "[^")) return null;
    const close = std.mem.indexOf(u8, line, "]:") orelse return null;
    if (close <= 2) return null;
    return .{ .id = line[2..close], .text = std.mem.trim(u8, line[close + 2 ..], " \t") };
}

fn appendFootnotes(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), footnotes: *const std.StringHashMap([]const u8)) !void {
    if (footnotes.count() == 0) return;
    try output.appendSlice(allocator, "<section class=\"footnotes\">\n<ol>\n");
    var iter = footnotes.iterator();
    while (iter.next()) |entry| {
        try output.appendSlice(allocator, "<li id=\"fn-");
        try appendEscaped(allocator, output, entry.key_ptr.*);
        try output.appendSlice(allocator, "\">");
        try appendInline(allocator, output, entry.value_ptr.*, footnotes);
        try output.appendSlice(allocator, "</li>\n");
    }
    try output.appendSlice(allocator, "</ol>\n</section>\n");
}

fn isTableRow(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn isTableDelimiter(line: []const u8) bool {
    var saw_dash = false;
    for (std.mem.trim(u8, line, " \t|")) |c| {
        if (c == '-') saw_dash = true else if (c != ':' and c != ' ' and c != '\t' and c != '|') return false;
    }
    return saw_dash and isTableRow(line);
}

fn renderTable(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), lines: []const []const u8, start: usize, footnotes: *const std.StringHashMap([]const u8)) !usize {
    try output.appendSlice(allocator, "<table>\n<thead><tr>");
    try renderTableCells(allocator, output, lines[start], "th", footnotes);
    try output.appendSlice(allocator, "</tr></thead>\n<tbody>\n");

    var i = start + 2;
    while (i < lines.len and isTableRow(lines[i]) and lines[i].len > 0) : (i += 1) {
        try output.appendSlice(allocator, "<tr>");
        try renderTableCells(allocator, output, lines[i], "td", footnotes);
        try output.appendSlice(allocator, "</tr>\n");
    }
    try output.appendSlice(allocator, "</tbody>\n</table>\n");
    return i - 1;
}

fn renderTableCells(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), line: []const u8, comptime tag: []const u8, footnotes: *const std.StringHashMap([]const u8)) !void {
    const trimmed = std.mem.trim(u8, line, " \t|");
    var cells = std.mem.splitScalar(u8, trimmed, '|');
    while (cells.next()) |cell| {
        try output.appendSlice(allocator, "<" ++ tag ++ ">");
        try appendInline(allocator, output, std.mem.trim(u8, cell, " \t"), footnotes);
        try output.appendSlice(allocator, "</" ++ tag ++ ">");
    }
}

fn renderShortcodeLine(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), raw_line: []const u8) !bool {
    const line = std.mem.trim(u8, raw_line, " \t");
    if (!isShortcodeLine(line)) return false;

    const inner = std.mem.trim(u8, line[3 .. line.len - 3], " \t");
    if (inner.len == 0) return false;
    const name_end = std.mem.indexOfAny(u8, inner, " \t") orelse inner.len;
    const name = inner[0..name_end];
    const args = std.mem.trim(u8, inner[name_end..], " \t");

    if (std.ascii.eqlIgnoreCase(name, "figure")) {
        try renderFigureShortcode(allocator, output, args);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "youtube")) {
        try renderYoutubeShortcode(allocator, output, args);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "vimeo")) {
        try renderVimeoShortcode(allocator, output, args);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(name, "callout")) {
        try renderCalloutShortcode(allocator, output, args);
        return true;
    }

    return false;
}

fn isShortcodeLine(raw_line: []const u8) bool {
    const line = std.mem.trim(u8, raw_line, " \t");
    return std.mem.startsWith(u8, line, "{{<") and std.mem.endsWith(u8, line, ">}}");
}

fn renderFigureShortcode(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), args: []const u8) !void {
    const src = findArg(args, "src") orelse firstPositionalArg(args) orelse "";
    if (!isSafeUrl(src)) return;
    const alt = findArg(args, "alt") orelse "";
    const caption = findArg(args, "caption") orelse "";

    try output.appendSlice(allocator, "<figure>\n<img src=\"");
    try appendEscaped(allocator, output, src);
    try output.appendSlice(allocator, "\" alt=\"");
    try appendEscaped(allocator, output, alt);
    try output.appendSlice(allocator, "\">\n");
    if (caption.len > 0) {
        try output.appendSlice(allocator, "<figcaption>");
        try appendEscaped(allocator, output, caption);
        try output.appendSlice(allocator, "</figcaption>\n");
    }
    try output.appendSlice(allocator, "</figure>\n");
}

fn renderYoutubeShortcode(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), args: []const u8) !void {
    const id = findArg(args, "id") orelse firstPositionalArg(args) orelse "";
    if (!isSafeMediaId(id)) return;
    try output.appendSlice(allocator, "<div class=\"embed\"><iframe src=\"https://www.youtube-nocookie.com/embed/");
    try appendEscaped(allocator, output, id);
    try output.appendSlice(allocator, "\" title=\"YouTube video\" loading=\"lazy\" allowfullscreen></iframe></div>\n");
}

fn renderVimeoShortcode(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), args: []const u8) !void {
    const id = findArg(args, "id") orelse firstPositionalArg(args) orelse "";
    if (!isSafeMediaId(id)) return;
    try output.appendSlice(allocator, "<div class=\"embed\"><iframe src=\"https://player.vimeo.com/video/");
    try appendEscaped(allocator, output, id);
    try output.appendSlice(allocator, "\" title=\"Vimeo video\" loading=\"lazy\" allowfullscreen></iframe></div>\n");
}

fn renderCalloutShortcode(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), args: []const u8) !void {
    const kind = findArg(args, "type") orelse "note";
    const title = findArg(args, "title") orelse kind;
    const text = findArg(args, "text") orelse firstPositionalArg(args) orelse "";
    if (!isSafeLanguageClass(kind)) return;

    try output.appendSlice(allocator, "<aside class=\"callout callout-");
    try appendEscaped(allocator, output, kind);
    try output.appendSlice(allocator, "\"><strong>");
    try appendEscaped(allocator, output, title);
    try output.appendSlice(allocator, "</strong>");
    if (text.len > 0) {
        try output.appendSlice(allocator, "<p>");
        try appendEscaped(allocator, output, text);
        try output.appendSlice(allocator, "</p>");
    }
    try output.appendSlice(allocator, "</aside>\n");
}

fn findArg(args: []const u8, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (nextArg(args, &index)) |token| {
        const eq_idx = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const token_key = token[0..eq_idx];
        if (!std.mem.eql(u8, token_key, key)) continue;
        return stripQuotes(token[eq_idx + 1 ..]);
    }
    return null;
}

fn firstPositionalArg(args: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (nextArg(args, &index)) |token| {
        if (std.mem.indexOfScalar(u8, token, '=') == null) return stripQuotes(token);
    }
    return null;
}

fn nextArg(args: []const u8, index: *usize) ?[]const u8 {
    while (index.* < args.len and std.ascii.isWhitespace(args[index.*])) index.* += 1;
    if (index.* >= args.len) return null;

    const start = index.*;
    var quote: ?u8 = null;
    while (index.* < args.len) : (index.* += 1) {
        const c = args[index.*];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (std.ascii.isWhitespace(c)) break;
    }

    const end = index.*;
    while (index.* < args.len and std.ascii.isWhitespace(args[index.*])) index.* += 1;
    return args[start..end];
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn isSafeMediaId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn headingId(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_dash = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(allocator, std.ascii.toLower(c));
            last_dash = false;
        } else if (!last_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_dash = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "section");
    return out.toOwnedSlice(allocator);
}

fn parseLink(text: []const u8) ?Link {
    if (text.len < 4 or text[0] != '[') return null;
    const text_end = findClosing(text[1..], ']') orelse return null;
    const after_bracket = 1 + text_end + 1;
    if (after_bracket >= text.len or text[after_bracket] != '(') return null;
    const url_end = findClosing(text[after_bracket + 1 ..], ')') orelse return null;
    return Link{
        .text = text[1 .. 1 + text_end],
        .url = text[after_bracket + 1 .. after_bracket + 1 + url_end],
        .total_len = after_bracket + 1 + url_end + 1,
    };
}

test "markdown rejects unsafe code language attributes" {
    const html = try toHtml(std.testing.allocator,
        \\\`\`\`\" onmouseover=\"alert(1)
        \\code
        \\\`\`\`
    );
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "onmouseover") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<pre><code>") != null);
}

test "markdown replaces unsafe link URLs" {
    const html = try toHtml(std.testing.allocator, "[bad](javascript:alert(1))");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"#\"") != null);
}

test "markdown rejects protocol-relative link URLs" {
    const html = try toHtml(std.testing.allocator, "[bad](//attacker.example/path)");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "//attacker.example") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"#\"") != null);
}

test "markdown adds heading ids" {
    const html = try toHtml(std.testing.allocator, "## Hello World!");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<h2 id=\"hello-world\">") != null);
}

test "markdown exposes table of contents" {
    const rendered = try render(std.testing.allocator,
        \\## First
        \\### Second
    );
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, rendered.toc, "class=\"toc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.toc, "#first") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.toc, "toc-level-3") != null);
}

test "markdown renders safe shortcodes" {
    const html = try toHtml(std.testing.allocator,
        \\{{< figure src="/photo.jpg" alt="Photo" caption="Caption" >}}
        \\{{< youtube dQw4w9WgXcQ >}}
    );
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<figure>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "youtube-nocookie.com/embed/dQw4w9WgXcQ") != null);
}

test "markdown adds syntax highlight spans" {
    const html = try toHtml(std.testing.allocator,
        \\```zig
        \\const x = 1;
        \\```
    );
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "tok-keyword") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "tok-number") != null);
}

test "markdown renders tables" {
    const html = try toHtml(std.testing.allocator,
        \\| a | b |
        \\| - | - |
        \\| 1 | 2 |
    );
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<td>1</td>") != null);
}

test "markdown renders footnotes" {
    const html = try toHtml(std.testing.allocator,
        \\note[^1]
        \\
        \\[^1]: footnote text
    );
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"footnotes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "footnote text") != null);
}
