const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const markdown = @import("markdown.zig");
const template = @import("template.zig");
const server = @import("server.zig");

const max_directory_depth = 128;
const max_pages = 10_000;
const max_static_files = 10_000;
const max_static_file_size = 100 * 1024 * 1024;
const max_total_static_size = 1024 * 1024 * 1024;
const max_total_markdown_input_size = 100 * 1024 * 1024;
const max_total_generated_output_size = 250 * 1024 * 1024;

const Page = struct {
    url: []const u8,
    title: []const u8,
    date: []const u8,
    description: []const u8,
    tags: []const u8,
    categories: []const u8,

    fn deinit(self: Page, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.title.len > 0) allocator.free(self.title);
        if (self.date.len > 0) allocator.free(self.date);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.tags.len > 0) allocator.free(self.tags);
        if (self.categories.len > 0) allocator.free(self.categories);
    }
};

const Config = struct {
    title: []const u8,
    url: []const u8,
    author: []const u8,
    description: []const u8,
    theme: []const u8,
    nav_html: []const u8,
    paginate: usize,

    fn deinit(self: Config, allocator: std.mem.Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        if (self.url.len > 0) allocator.free(self.url);
        if (self.author.len > 0) allocator.free(self.author);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.theme.len > 0) allocator.free(self.theme);
        if (self.nav_html.len > 0) allocator.free(self.nav_html);
    }
};

const TemplateVars = struct {
    map: std.StringHashMap([]const u8),
    permalink: []u8,

    fn deinit(self: *TemplateVars, allocator: std.mem.Allocator) void {
        self.map.deinit();
        if (self.permalink.len > 0) allocator.free(self.permalink);
    }
};

const StaticCopyStats = struct {
    count: usize = 0,
    bytes: u64 = 0,
};

const OpenParent = struct {
    dir: std.fs.Dir,
    name: []u8,

    fn deinit(self: *OpenParent, allocator: std.mem.Allocator) void {
        self.dir.close();
        allocator.free(self.name);
    }
};

const BuildStats = struct {
    pages: usize = 0,
    markdown_bytes: u64 = 0,
    generated_bytes: u64 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "build")) {
        if (args.len < 3) {
            std.debug.print("usage: ypsilanti build <site_dir> [output_dir]\n", .{});
            return;
        }
        const site_dir = args[2];
        const output_dir = if (args.len > 3) args[3] else "output";
        try build(allocator, site_dir, output_dir, false);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        if (args.len < 3) {
            std.debug.print("usage: ypsilanti serve <site_dir> [port]\n", .{});
            return;
        }
        const site_dir = args[2];
        const port: u16 = if (args.len > 3) std.fmt.parseInt(u16, args[3], 10) catch 3000 else 3000;
        try serve(allocator, site_dir, port);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\ypsilanti - static site generator
        \\
        \\commands:
        \\  build <site_dir> [output_dir]   generate site
        \\  serve <site_dir> [port]         dev server with live reload
        \\
    , .{});
}

pub fn build(allocator: std.mem.Allocator, site_dir: []const u8, output_dir: []const u8, inject_reload: bool) !void {
    const content_dir = try std.fs.path.join(allocator, &.{ site_dir, "content" });
    defer allocator.free(content_dir);
    const layouts_dir = try std.fs.path.join(allocator, &.{ site_dir, "layouts" });
    defer allocator.free(layouts_dir);
    const partials_dir = try std.fs.path.join(allocator, &.{ site_dir, "partials" });
    defer allocator.free(partials_dir);
    const static_dir = try std.fs.path.join(allocator, &.{ site_dir, "static" });
    defer allocator.free(static_dir);

    try ensureNoSymlinkComponents(allocator, content_dir);
    try ensureNoSymlinkComponents(allocator, layouts_dir);
    try ensureNoSymlinkComponents(allocator, partials_dir);
    try ensureNoSymlinkComponents(allocator, static_dir);
    try ensureNoSymlinkComponents(allocator, output_dir);
    if (try isSameOrChildPath(allocator, static_dir, output_dir)) {
        return error.OutputInsideStaticDir;
    }

    std.fs.cwd().makePath(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    try ensureNoSymlinkComponents(allocator, output_dir);

    const config = try loadConfig(allocator, site_dir);
    defer config.deinit(allocator);

    const engine = template.Engine.init(allocator, layouts_dir, partials_dir);

    var pages: std.ArrayListUnmanaged(Page) = .empty;
    defer {
        for (pages.items) |page| page.deinit(allocator);
        pages.deinit(allocator);
    }

    var stats: BuildStats = .{};
    try processDirectory(allocator, &engine, content_dir, content_dir, output_dir, inject_reload, config, &pages, &stats, 0);
    std.debug.print("{d} pages\n", .{stats.pages});

    try generatePostIndex(allocator, &engine, output_dir, inject_reload, config, &pages, &stats);
    try generateTaxonomy(allocator, &engine, output_dir, inject_reload, config, &pages, &stats, "tags", "tags");
    try generateTaxonomy(allocator, &engine, output_dir, inject_reload, config, &pages, &stats, "categories", "categories");
    try generateSitemap(allocator, output_dir, config.url, pages.items);
    try generateRss(allocator, output_dir, config, pages.items);

    const static_copied = copyStaticFiles(allocator, static_dir, output_dir) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    std.debug.print("{d} static files\n", .{static_copied});
    try validateInternalLinks(allocator, output_dir);
}

fn loadConfig(allocator: std.mem.Allocator, site_dir: []const u8) !Config {
    var title: []const u8 = "ypsilanti";
    var url: []const u8 = "";
    var author: []const u8 = "";
    var description: []const u8 = "";
    var theme: []const u8 = "darkode";
    var nav: []const u8 = "home=/,about=/about/,posts=/posts/,rss=/feed.xml";
    var paginate: usize = 10;
    var config_content: ?[]u8 = null;
    defer if (config_content) |content| allocator.free(content);
    var url_content: ?[]u8 = null;
    defer if (url_content) |content| allocator.free(content);

    const config_path = try std.fs.path.join(allocator, &.{ site_dir, "config" });
    defer allocator.free(config_path);
    if (readFile(allocator, config_path)) |content| {
        config_content = content;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon_idx], " \t");
            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
            if (std.mem.eql(u8, key, "title")) title = value;
            if (std.mem.eql(u8, key, "url")) url = value;
            if (std.mem.eql(u8, key, "author")) author = value;
            if (std.mem.eql(u8, key, "description")) description = value;
            if (std.mem.eql(u8, key, "theme")) theme = value;
            if (std.mem.eql(u8, key, "nav")) nav = value;
            if (std.mem.eql(u8, key, "paginate")) paginate = std.fmt.parseInt(usize, value, 10) catch paginate;
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            const url_path = try std.fs.path.join(allocator, &.{ site_dir, "url" });
            defer allocator.free(url_path);
            url_content = readFile(allocator, url_path) catch null;
            if (url_content) |content| url = std.mem.trim(u8, content, " \t\r\n");
        },
        else => return err,
    }

    if (!isSafeBaseUrl(url)) return error.InvalidBaseUrl;

    return .{
        .title = try allocator.dupe(u8, title),
        .url = try allocator.dupe(u8, url),
        .author = try allocator.dupe(u8, author),
        .description = try allocator.dupe(u8, description),
        .theme = try allocator.dupe(u8, theme),
        .nav_html = try buildNavHtml(allocator, nav),
        .paginate = if (paginate == 0) 10 else paginate,
    };
}

fn isSafeBaseUrl(url: []const u8) bool {
    if (url.len == 0) return true;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

fn buildNavHtml(allocator: std.mem.Allocator, nav: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var items = std.mem.splitScalar(u8, nav, ',');
    while (items.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const label = std.mem.trim(u8, item[0..eq_idx], " \t");
        const href = std.mem.trim(u8, item[eq_idx + 1 ..], " \t");
        if (!isSafeTemplateUrl(href)) continue;
        try buf.appendSlice(allocator, "<a href=\"");
        try appendHtmlEscaped(allocator, &buf, href);
        try buf.appendSlice(allocator, "\">");
        try appendHtmlEscaped(allocator, &buf, label);
        try buf.appendSlice(allocator, "</a>\n");
    }

    return buf.toOwnedSlice(allocator);
}

fn isSafeTemplateUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    if (url[0] == '#') return true;
    if (url[0] == '/') return url.len == 1 or url[1] != '/';
    if (std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../")) return true;
    const colon_idx = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    const first_delim = firstUrlDelimiter(url) orelse url.len;
    if (colon_idx > first_delim) return true;
    const scheme = url[0..colon_idx];
    return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "mailto");
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

fn appendHtmlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    var tmp: [96]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch return error.OutOfMemory;
    try buf.appendSlice(allocator, formatted);
}

test "base url validation requires http or https" {
    try std.testing.expect(isSafeBaseUrl(""));
    try std.testing.expect(isSafeBaseUrl("https://example.com"));
    try std.testing.expect(isSafeBaseUrl("http://example.com"));
    try std.testing.expect(!isSafeBaseUrl("//example.com"));
    try std.testing.expect(!isSafeBaseUrl("javascript:alert(1)"));
    try std.testing.expect(!isSafeBaseUrl("https://exa mple.com"));
}

fn generateSitemap(allocator: std.mem.Allocator, output_dir: []const u8, base_url: []const u8, pages: []const Page) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try buf.appendSlice(allocator, "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    for (pages) |page| {
        try buf.appendSlice(allocator, "  <url><loc>");
        try appendAbsoluteXmlUrl(allocator, &buf, base_url, page.url);
        try buf.appendSlice(allocator, "</loc></url>\n");
    }

    try buf.appendSlice(allocator, "</urlset>\n");

    const path = try std.fs.path.join(allocator, &.{ output_dir, "sitemap.xml" });
    defer allocator.free(path);
    try writeFileAtomic(allocator, path, buf.items);
}

fn generateRss(allocator: std.mem.Allocator, output_dir: []const u8, config: Config, pages: []const Page) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try buf.appendSlice(allocator, "<rss version=\"2.0\">\n<channel>\n");
    try buf.appendSlice(allocator, "  <title>");
    try appendXmlEscaped(allocator, &buf, config.title);
    try buf.appendSlice(allocator, "</title>\n");
    try buf.appendSlice(allocator, "  <link>");
    try appendXmlEscaped(allocator, &buf, config.url);
    try buf.appendSlice(allocator, "</link>\n");
    try buf.appendSlice(allocator, "  <description>");
    try appendXmlEscaped(allocator, &buf, config.description);
    try buf.appendSlice(allocator, "</description>\n");

    for (pages) |page| {
        if (page.date.len == 0) continue;
        try buf.appendSlice(allocator, "  <item>\n");
        try buf.appendSlice(allocator, "    <title>");
        try appendXmlEscaped(allocator, &buf, page.title);
        try buf.appendSlice(allocator, "</title>\n");
        try buf.appendSlice(allocator, "    <link>");
        try appendAbsoluteXmlUrl(allocator, &buf, config.url, page.url);
        try buf.appendSlice(allocator, "</link>\n");
        if (page.description.len > 0) {
            try buf.appendSlice(allocator, "    <description>");
            try appendXmlEscaped(allocator, &buf, page.description);
            try buf.appendSlice(allocator, "</description>\n");
        }
        try buf.appendSlice(allocator, "  </item>\n");
    }

    try buf.appendSlice(allocator, "</channel>\n</rss>\n");

    const path = try std.fs.path.join(allocator, &.{ output_dir, "feed.xml" });
    defer allocator.free(path);
    try writeFileAtomic(allocator, path, buf.items);
}

fn appendAbsoluteXmlUrl(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), base_url: []const u8, page_url: []const u8) !void {
    const url = try absoluteUrl(allocator, base_url, page_url);
    defer allocator.free(url);
    try appendXmlEscaped(allocator, buf, url);
}

fn appendXmlEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        if (!isValidXmlByte(c)) return error.InvalidXmlCharacter;
        switch (c) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
}

fn isValidXmlByte(c: u8) bool {
    return c == 0x09 or c == 0x0a or c == 0x0d or c >= 0x20;
}

fn serve(allocator: std.mem.Allocator, site_dir: []const u8, port: u16) !void {
    const output_dir = ".ypsilanti_serve";

    var listener: ?std.net.Server = try server.listen(port);
    errdefer if (listener) |*srv| srv.deinit();

    std.fs.cwd().deleteTree(output_dir) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try build(allocator, site_dir, output_dir, true);

    const server_thread = try std.Thread.spawn(.{}, server.run, .{ allocator, output_dir, listener.? });
    listener = null;
    defer server_thread.join();

    std.debug.print("\nserving at http://localhost:{d}\n", .{port});
    std.debug.print("watching for changes...\n\n", .{});

    try watch(allocator, site_dir, output_dir);
}

fn watch(allocator: std.mem.Allocator, site_dir: []const u8, output_dir: []const u8) !void {
    const dirs = [_][]const u8{ "content", "layouts", "partials", "static" };
    var last_mod: i128 = 0;

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        var current_mod: i128 = 0;
        for (dirs) |sub| {
            const path = try std.fs.path.join(allocator, &.{ site_dir, sub });
            defer allocator.free(path);
            const mod = getLatestMod(allocator, path, 0) catch 0;
            if (mod > current_mod) current_mod = mod;
        }

        if (current_mod > last_mod and last_mod != 0) {
            std.debug.print("rebuilding...\n", .{});
            std.fs.cwd().deleteTree(output_dir) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.print("build error: {}\n", .{err});
                    last_mod = current_mod;
                    continue;
                }
            };
            build(allocator, site_dir, output_dir, true) catch |err| {
                std.debug.print("build error: {}\n", .{err});
            };
            server.bump_version();
        }
        last_mod = current_mod;
    }
}

fn getLatestMod(allocator: std.mem.Allocator, dir_path: []const u8, depth: usize) !i128 {
    if (depth > max_directory_depth) return error.DirectoryDepthExceeded;

    var latest: i128 = 0;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true, .no_follow = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;
        if (mtime > latest) latest = mtime;

        if (entry.kind == .directory) {
            const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(child_path);
            const child_mod = getLatestMod(allocator, child_path, depth + 1) catch 0;
            if (child_mod > latest) latest = child_mod;
        }
    }
    return latest;
}

fn processDirectory(
    allocator: std.mem.Allocator,
    engine: *const template.Engine,
    base_dir: []const u8,
    current_dir: []const u8,
    output_dir: []const u8,
    inject_reload: bool,
    config: Config,
    pages: *std.ArrayListUnmanaged(Page),
    stats: *BuildStats,
    depth: usize,
) !void {
    if (depth > max_directory_depth) return error.DirectoryDepthExceeded;

    var dir = std.fs.cwd().openDir(current_dir, .{ .iterate = true, .no_follow = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try processDirectory(allocator, engine, base_dir, full_path, output_dir, inject_reload, config, pages, stats, depth + 1);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            if (stats.pages >= max_pages) return error.PageLimitExceeded;
            if (try processMarkdownFile(allocator, engine, base_dir, full_path, output_dir, inject_reload, config, stats)) |page| {
                try pages.append(allocator, page);
                stats.pages += 1;
            }
        }
    }
}

fn processMarkdownFile(
    allocator: std.mem.Allocator,
    engine: *const template.Engine,
    base_dir: []const u8,
    file_path: []const u8,
    output_dir: []const u8,
    inject_reload: bool,
    config: Config,
    stats: *BuildStats,
) !?Page {
    const content = try readFile(allocator, file_path);
    defer allocator.free(content);
    stats.markdown_bytes += content.len;
    if (stats.markdown_bytes > max_total_markdown_input_size) return error.MarkdownInputLimitExceeded;

    var fm = try frontmatter.parse(allocator, content);
    defer fm.deinit();
    if (isTruthy(fm.get("draft") orelse "")) return null;

    const rendered_markdown = try markdown.render(allocator, fm.content);
    defer rendered_markdown.deinit(allocator);

    const relative_path = file_path[base_dir.len..];
    const relative_trimmed = if (relative_path.len > 0 and relative_path[0] == '/') relative_path[1..] else relative_path;

    const output_filename = try outputPathForMarkdown(allocator, relative_trimmed);
    defer allocator.free(output_filename);

    const page_url = try urlForMarkdown(allocator, relative_trimmed);
    errdefer allocator.free(page_url);

    const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_filename });
    defer allocator.free(output_path);

    try ensureOutputParentSafe(allocator, output_dir, output_filename);

    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    try ensureOutputParentSafe(allocator, output_dir, output_filename);

    var vars = try buildTemplateVars(allocator, fm.meta, config, page_url, rendered_markdown.toc);
    defer vars.deinit(allocator);

    const rendered = if (fm.get("layout")) |layout_name|
        try engine.renderWithLayout(layout_name, rendered_markdown.html, vars.map)
    else
        try engine.render(rendered_markdown.html, vars.map);
    defer allocator.free(rendered);

    const final_html = if (inject_reload) try injectLiveReload(allocator, rendered) else rendered;
    defer if (inject_reload) allocator.free(final_html);
    stats.generated_bytes += final_html.len;
    if (stats.generated_bytes > max_total_generated_output_size) return error.GeneratedOutputLimitExceeded;

    try writeFileAtomic(allocator, output_path, final_html);

    if (fm.get("aliases") orelse fm.get("alias")) |aliases| {
        try writeAliases(allocator, output_dir, aliases, page_url, stats);
    }

    return Page{
        .url = page_url,
        .title = try allocator.dupe(u8, fm.get("title") orelse ""),
        .date = try allocator.dupe(u8, fm.get("date") orelse ""),
        .description = try allocator.dupe(u8, fm.get("description") orelse ""),
        .tags = try allocator.dupe(u8, fm.get("tags") orelse ""),
        .categories = try allocator.dupe(u8, fm.get("categories") orelse fm.get("category") orelse ""),
    };
}

fn writeAliases(allocator: std.mem.Allocator, output_dir: []const u8, aliases: []const u8, target_url: []const u8, stats: *BuildStats) !void {
    var split = std.mem.tokenizeAny(u8, aliases, ",");
    while (split.next()) |raw_alias| {
        const alias = std.mem.trim(u8, raw_alias, " \t");
        if (alias.len == 0) continue;
        if (!isSafeLocalUrl(alias)) return error.InvalidAliasUrl;

        const filename = try outputPathForAlias(allocator, alias);
        defer allocator.free(filename);
        try ensureOutputParentSafe(allocator, output_dir, filename);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, filename });
        defer allocator.free(output_path);
        if (std.fs.path.dirname(output_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        var html: std.ArrayListUnmanaged(u8) = .empty;
        defer html.deinit(allocator);
        try html.appendSlice(allocator, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"robots\" content=\"noindex\">\n<meta http-equiv=\"refresh\" content=\"0; url=");
        try appendHtmlEscaped(allocator, &html, target_url);
        try html.appendSlice(allocator, "\">\n<link rel=\"canonical\" href=\"");
        try appendHtmlEscaped(allocator, &html, target_url);
        try html.appendSlice(allocator, "\">\n<title>redirecting</title>\n</head>\n<body>\n<a href=\"");
        try appendHtmlEscaped(allocator, &html, target_url);
        try html.appendSlice(allocator, "\">redirecting</a>\n</body>\n</html>\n");

        stats.generated_bytes += html.items.len;
        if (stats.generated_bytes > max_total_generated_output_size) return error.GeneratedOutputLimitExceeded;
        try writeFileAtomic(allocator, output_path, html.items);
    }
}

fn isSafeLocalUrl(url: []const u8) bool {
    if (url.len == 0 or url[0] != '/') return false;
    if (url.len > 1 and url[1] == '/') return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f or c == '\\') return false;
    var segments = std.mem.splitScalar(u8, url, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn outputPathForAlias(allocator: std.mem.Allocator, alias: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, alias, "/");
    if (trimmed.len == 0) return error.InvalidAliasUrl;
    if (std.mem.endsWith(u8, trimmed, ".html")) return allocator.dupe(u8, trimmed);
    return std.mem.concat(allocator, u8, &.{ trimmed, "/index.html" });
}

fn generatePostIndex(allocator: std.mem.Allocator, engine: *const template.Engine, output_dir: []const u8, inject_reload: bool, config: Config, pages: *std.ArrayListUnmanaged(Page), stats: *BuildStats) !void {
    var posts: std.ArrayListUnmanaged(Page) = .empty;
    defer posts.deinit(allocator);
    for (pages.items) |page| if (page.date.len > 0) try posts.append(allocator, page);
    std.sort.insertion(Page, posts.items, {}, pageDateDesc);

    const page_size = config.paginate;
    const page_count = paginatedPageCount(posts.items.len, page_size);
    var page_number: usize = 1;
    while (page_number <= page_count) : (page_number += 1) {
        const start = (page_number - 1) * page_size;
        const end = @min(start + page_size, posts.items.len);
        const page_url = try paginatedUrl(allocator, "/posts/", page_number);
        defer allocator.free(page_url);
        const page_title = if (page_number == 1)
            try allocator.dupe(u8, "posts")
        else
            try std.fmt.allocPrint(allocator, "posts page {d}", .{page_number});
        defer allocator.free(page_title);

        var html: std.ArrayListUnmanaged(u8) = .empty;
        defer html.deinit(allocator);
        try html.appendSlice(allocator, "<h1>posts</h1>\n<ul class=\"post-list\">\n");
        for (posts.items[start..end]) |post| try appendPostListItem(allocator, &html, post, true);
        try html.appendSlice(allocator, "</ul>\n");
        try appendPagination(allocator, &html, "/posts/", page_number, page_count);

        try writeGeneratedPage(allocator, engine, output_dir, inject_reload, config, page_url, page_title, "", html.items, stats);
        try pages.append(allocator, try makePage(allocator, page_url, page_title, "", "", "", ""));
    }
}

fn generateTaxonomy(allocator: std.mem.Allocator, engine: *const template.Engine, output_dir: []const u8, inject_reload: bool, config: Config, pages: *std.ArrayListUnmanaged(Page), stats: *BuildStats, comptime field: []const u8, root: []const u8) !void {
    var terms: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (terms.items) |term| allocator.free(term);
        terms.deinit(allocator);
    }

    for (pages.items) |page| {
        const raw = if (std.mem.eql(u8, field, "tags")) page.tags else page.categories;
        try collectTerms(allocator, &terms, raw);
    }
    if (terms.items.len == 0) return;
    std.sort.insertion([]u8, terms.items, {}, stringLessThan);

    var index_html: std.ArrayListUnmanaged(u8) = .empty;
    defer index_html.deinit(allocator);
    try index_html.appendSlice(allocator, "<h1>");
    try appendHtmlEscaped(allocator, &index_html, root);
    try index_html.appendSlice(allocator, "</h1>\n<ul>\n");

    for (terms.items) |term| {
        const slug = try slugify(allocator, term);
        defer allocator.free(slug);
        try index_html.appendSlice(allocator, "<li><a href=\"");
        try index_html.append(allocator, '/');
        try appendHtmlEscaped(allocator, &index_html, root);
        try index_html.append(allocator, '/');
        try appendHtmlEscaped(allocator, &index_html, slug);
        try index_html.appendSlice(allocator, "/\">");
        try appendHtmlEscaped(allocator, &index_html, term);
        try index_html.appendSlice(allocator, "</a></li>\n");

        var term_posts: std.ArrayListUnmanaged(Page) = .empty;
        defer term_posts.deinit(allocator);
        for (pages.items) |page| {
            if (page.date.len == 0) continue;
            const raw = if (std.mem.eql(u8, field, "tags")) page.tags else page.categories;
            if (!hasTerm(raw, term)) continue;
            try term_posts.append(allocator, page);
        }
        std.sort.insertion(Page, term_posts.items, {}, pageDateDesc);

        const term_base_url = try std.mem.concat(allocator, u8, &.{ "/", root, "/", slug, "/" });
        defer allocator.free(term_base_url);
        const page_size = config.paginate;
        const page_count = paginatedPageCount(term_posts.items.len, page_size);
        var page_number: usize = 1;
        while (page_number <= page_count) : (page_number += 1) {
            const start = (page_number - 1) * page_size;
            const end = @min(start + page_size, term_posts.items.len);
            const term_url = try paginatedUrl(allocator, term_base_url, page_number);
            defer allocator.free(term_url);
            const term_title = if (page_number == 1)
                try std.mem.concat(allocator, u8, &.{ root, ": ", term })
            else
                try std.fmt.allocPrint(allocator, "{s}: {s} page {d}", .{ root, term, page_number });
            defer allocator.free(term_title);

            var term_html: std.ArrayListUnmanaged(u8) = .empty;
            defer term_html.deinit(allocator);
            try term_html.appendSlice(allocator, "<h1>");
            try appendHtmlEscaped(allocator, &term_html, term);
            try term_html.appendSlice(allocator, "</h1>\n<ul class=\"post-list\">\n");
            for (term_posts.items[start..end]) |post| try appendPostListItem(allocator, &term_html, post, false);
            try term_html.appendSlice(allocator, "</ul>\n");
            try appendPagination(allocator, &term_html, term_base_url, page_number, page_count);

            try writeGeneratedPage(allocator, engine, output_dir, inject_reload, config, term_url, term_title, "", term_html.items, stats);
            try pages.append(allocator, try makePage(allocator, term_url, term_title, "", "", "", ""));
        }
    }
    try index_html.appendSlice(allocator, "</ul>\n");

    const index_url = try std.mem.concat(allocator, u8, &.{ "/", root, "/" });
    defer allocator.free(index_url);
    try writeGeneratedPage(allocator, engine, output_dir, inject_reload, config, index_url, root, "", index_html.items, stats);
    try pages.append(allocator, try makePage(allocator, index_url, root, "", "", "", ""));
}

fn paginatedPageCount(item_count: usize, page_size: usize) usize {
    if (item_count == 0) return 1;
    return (item_count + page_size - 1) / page_size;
}

fn paginatedUrl(allocator: std.mem.Allocator, base_url: []const u8, page_number: usize) ![]u8 {
    if (page_number == 1) return allocator.dupe(u8, base_url);
    return std.fmt.allocPrint(allocator, "{s}page/{d}/", .{ base_url, page_number });
}

fn appendPostListItem(allocator: std.mem.Allocator, html: *std.ArrayListUnmanaged(u8), post: Page, include_date: bool) !void {
    try html.appendSlice(allocator, "<li><a href=\"");
    try appendHtmlEscaped(allocator, html, post.url);
    try html.appendSlice(allocator, "\">");
    try appendHtmlEscaped(allocator, html, post.title);
    try html.appendSlice(allocator, "</a>");
    if (include_date and post.date.len > 0) {
        try html.appendSlice(allocator, " <span>");
        try appendHtmlEscaped(allocator, html, post.date);
        try html.appendSlice(allocator, "</span>");
    }
    try html.appendSlice(allocator, "</li>\n");
}

fn appendPagination(allocator: std.mem.Allocator, html: *std.ArrayListUnmanaged(u8), base_url: []const u8, page_number: usize, page_count: usize) !void {
    if (page_count <= 1) return;
    try html.appendSlice(allocator, "<nav class=\"pagination\" aria-label=\"Pagination\">\n");
    if (page_number > 1) {
        const prev_url = try paginatedUrl(allocator, base_url, page_number - 1);
        defer allocator.free(prev_url);
        try html.appendSlice(allocator, "<a rel=\"prev\" href=\"");
        try appendHtmlEscaped(allocator, html, prev_url);
        try html.appendSlice(allocator, "\">newer</a>\n");
    }
    try html.appendSlice(allocator, "<span>page ");
    try appendFmt(allocator, html, "{d} of {d}", .{ page_number, page_count });
    try html.appendSlice(allocator, "</span>\n");
    if (page_number < page_count) {
        const next_url = try paginatedUrl(allocator, base_url, page_number + 1);
        defer allocator.free(next_url);
        try html.appendSlice(allocator, "<a rel=\"next\" href=\"");
        try appendHtmlEscaped(allocator, html, next_url);
        try html.appendSlice(allocator, "\">older</a>\n");
    }
    try html.appendSlice(allocator, "</nav>\n");
}

fn writeGeneratedPage(allocator: std.mem.Allocator, engine: *const template.Engine, output_dir: []const u8, inject_reload: bool, config: Config, page_url: []const u8, title: []const u8, description: []const u8, html: []const u8, stats: *BuildStats) !void {
    var meta = std.StringHashMap([]const u8).init(allocator);
    defer meta.deinit();
    try meta.put("title", title);
    try meta.put("description", description);
    var vars = try buildTemplateVars(allocator, meta, config, page_url, "");
    defer vars.deinit(allocator);
    const rendered = try engine.renderWithLayout("base", html, vars.map);
    defer allocator.free(rendered);
    const final_html = if (inject_reload) try injectLiveReload(allocator, rendered) else rendered;
    defer if (inject_reload) allocator.free(final_html);
    stats.generated_bytes += final_html.len;
    if (stats.generated_bytes > max_total_generated_output_size) return error.GeneratedOutputLimitExceeded;
    const filename = try outputPathForGeneratedUrl(allocator, page_url);
    defer allocator.free(filename);
    const output_path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(output_path);
    if (std.fs.path.dirname(output_path)) |dir| try std.fs.cwd().makePath(dir);
    try writeFileAtomic(allocator, output_path, final_html);
}

fn outputPathForGeneratedUrl(allocator: std.mem.Allocator, page_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, page_url, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "index.html");
    return std.mem.concat(allocator, u8, &.{ trimmed, "/index.html" });
}

fn validateInternalLinks(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    try validateInternalLinksInDir(allocator, output_dir, output_dir, 0);
}

fn validateInternalLinksInDir(allocator: std.mem.Allocator, output_dir: []const u8, current_dir: []const u8, depth: usize) !void {
    if (depth > max_directory_depth) return error.DirectoryDepthExceeded;

    var dir = try std.fs.cwd().openDir(current_dir, .{ .iterate = true, .no_follow = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const path = try std.fs.path.join(allocator, &.{ current_dir, entry.name });
        defer allocator.free(path);

        if (entry.kind == .directory) {
            try validateInternalLinksInDir(allocator, output_dir, path, depth + 1);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".html")) {
            try validateHtmlFileLinks(allocator, output_dir, path);
        }
    }
}

fn validateHtmlFileLinks(allocator: std.mem.Allocator, output_dir: []const u8, html_path: []const u8) !void {
    const html = try readFile(allocator, html_path);
    defer allocator.free(html);

    var index: usize = 0;
    while (findNextUrlAttribute(html, index)) |attr| {
        index = attr.end;
        const url = std.mem.trim(u8, attr.value, " \t\r\n");
        if (!shouldValidateLocalUrl(url)) continue;

        const resolved = try resolveLocalUrl(allocator, output_dir, html_path, url);
        defer resolved.deinit(allocator);
        if (!try localOutputTargetExists(allocator, output_dir, resolved.path, resolved.fragment)) {
            std.debug.print("broken internal link in {s}: {s}\n", .{ html_path, url });
            return error.BrokenInternalLink;
        }
    }
}

const UrlAttribute = struct {
    value: []const u8,
    end: usize,
};

const ResolvedLocalUrl = struct {
    path: []u8,
    fragment: []u8,

    fn deinit(self: ResolvedLocalUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.fragment);
    }
};

fn findNextUrlAttribute(html: []const u8, start: usize) ?UrlAttribute {
    var i = start;
    while (i < html.len) : (i += 1) {
        if (!startsWithUrlAttributeName(html[i..], "href") and !startsWithUrlAttributeName(html[i..], "src")) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(html[i - 1]) or html[i - 1] == '-' or html[i - 1] == '_')) continue;

        var j = i + if (std.ascii.eqlIgnoreCase(html[i..@min(i + 4, html.len)], "href")) @as(usize, 4) else @as(usize, 3);
        while (j < html.len and std.ascii.isWhitespace(html[j])) : (j += 1) {}
        if (j >= html.len or html[j] != '=') continue;
        j += 1;
        while (j < html.len and std.ascii.isWhitespace(html[j])) : (j += 1) {}
        if (j >= html.len or (html[j] != '"' and html[j] != '\'')) continue;
        const quote = html[j];
        const value_start = j + 1;
        const value_end_offset = std.mem.indexOfScalar(u8, html[value_start..], quote) orelse return null;
        const value_end = value_start + value_end_offset;
        return .{ .value = html[value_start..value_end], .end = value_end + 1 };
    }
    return null;
}

fn startsWithUrlAttributeName(text: []const u8, comptime name: []const u8) bool {
    if (text.len < name.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..name.len], name)) return false;
    if (text.len == name.len) return true;
    const next = text[name.len];
    return std.ascii.isWhitespace(next) or next == '=';
}

fn shouldValidateLocalUrl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "//")) return false;
    if (url[0] == '#') return true;
    const colon_idx = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    const first_delim = firstUrlDelimiter(url) orelse url.len;
    return colon_idx > first_delim;
}

fn resolveLocalUrl(allocator: std.mem.Allocator, output_dir: []const u8, html_path: []const u8, url: []const u8) !ResolvedLocalUrl {
    const query_idx = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const fragment_idx = std.mem.indexOfScalar(u8, url, '#');
    const path_part = url[0..query_idx];
    const fragment_part = if (fragment_idx) |idx| blk: {
        const end = std.mem.indexOfScalar(u8, url[idx + 1 ..], '?') orelse (url.len - idx - 1);
        break :blk url[idx + 1 .. idx + 1 + end];
    } else "";

    const resolved_path = if (path_part.len == 0) blk: {
        break :blk try currentPageUrlPath(allocator, output_dir, html_path);
    } else if (path_part[0] == '/') blk: {
        break :blk try allocator.dupe(u8, path_part);
    } else blk: {
        const base = try currentPageUrlDir(allocator, output_dir, html_path);
        defer allocator.free(base);
        const joined = try std.fs.path.join(allocator, &.{ base, path_part });
        defer allocator.free(joined);
        break :blk try normalizeUrlPath(allocator, joined);
    };
    errdefer allocator.free(resolved_path);

    return .{ .path = resolved_path, .fragment = try allocator.dupe(u8, fragment_part) };
}

fn currentPageUrlPath(allocator: std.mem.Allocator, output_dir: []const u8, html_path: []const u8) ![]u8 {
    const relative = relativeOutputPath(output_dir, html_path);
    if (std.mem.eql(u8, relative, "index.html")) return allocator.dupe(u8, "/");
    if (std.mem.endsWith(u8, relative, "/index.html")) return std.mem.concat(allocator, u8, &.{ "/", relative[0 .. relative.len - "/index.html".len], "/" });
    return std.mem.concat(allocator, u8, &.{ "/", relative });
}

fn currentPageUrlDir(allocator: std.mem.Allocator, output_dir: []const u8, html_path: []const u8) ![]u8 {
    const page_url = try currentPageUrlPath(allocator, output_dir, html_path);
    defer allocator.free(page_url);
    if (std.mem.endsWith(u8, page_url, "/")) return allocator.dupe(u8, page_url);
    const slash_idx = std.mem.lastIndexOfScalar(u8, page_url, '/') orelse return allocator.dupe(u8, "/");
    return allocator.dupe(u8, page_url[0 .. slash_idx + 1]);
}

fn relativeOutputPath(output_dir: []const u8, path: []const u8) []const u8 {
    var relative = path[output_dir.len..];
    if (relative.len > 0 and relative[0] == std.fs.path.sep) relative = relative[1..];
    return relative;
}

fn normalizeUrlPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts_out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts_out.deinit(allocator);

    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts_out.items.len == 0) return error.InvalidInternalLink;
            _ = parts_out.pop();
            continue;
        }
        try parts_out.append(allocator, part);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '/');
    for (parts_out.items, 0..) |part, idx| {
        if (idx > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    if (std.mem.endsWith(u8, path, "/") and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
    return out.toOwnedSlice(allocator);
}

fn localOutputTargetExists(allocator: std.mem.Allocator, output_dir: []const u8, url_path: []const u8, fragment: []const u8) !bool {
    if (!isSafeLocalUrl(url_path)) return false;
    const output_path = try outputPathForLocalUrl(allocator, output_dir, url_path);
    defer allocator.free(output_path);

    const stat = std.fs.cwd().statFile(output_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file) return false;
    if (fragment.len == 0) return true;
    if (!std.mem.endsWith(u8, output_path, ".html")) return false;

    const html = try readFile(allocator, output_path);
    defer allocator.free(html);
    return htmlHasAnchor(html, fragment);
}

fn outputPathForLocalUrl(allocator: std.mem.Allocator, output_dir: []const u8, url_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, url_path, "/");
    if (trimmed.len == 0) return std.fs.path.join(allocator, &.{ output_dir, "index.html" });

    const direct_path = try std.fs.path.join(allocator, &.{ output_dir, trimmed });
    const direct_stat = std.fs.cwd().statFile(direct_path) catch |err| {
        allocator.free(direct_path);
        return switch (err) {
            error.FileNotFound => std.fs.path.join(allocator, &.{ output_dir, trimmed, "index.html" }),
            else => err,
        };
    };
    if (direct_stat.kind == .file) return direct_path;
    allocator.free(direct_path);
    return std.fs.path.join(allocator, &.{ output_dir, trimmed, "index.html" });
}

fn htmlHasAnchor(html: []const u8, fragment: []const u8) bool {
    return htmlHasAttributeValue(html, "id", fragment) or htmlHasAttributeValue(html, "name", fragment);
}

fn htmlHasAttributeValue(html: []const u8, comptime name: []const u8, value: []const u8) bool {
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (!startsWithUrlAttributeName(html[i..], name)) continue;
        var j = i + name.len;
        while (j < html.len and std.ascii.isWhitespace(html[j])) : (j += 1) {}
        if (j >= html.len or html[j] != '=') continue;
        j += 1;
        while (j < html.len and std.ascii.isWhitespace(html[j])) : (j += 1) {}
        if (j >= html.len or (html[j] != '"' and html[j] != '\'')) continue;
        const quote = html[j];
        const value_start = j + 1;
        const value_end_offset = std.mem.indexOfScalar(u8, html[value_start..], quote) orelse return false;
        const value_end = value_start + value_end_offset;
        if (std.mem.eql(u8, html[value_start..value_end], value)) return true;
        i = value_end;
    }
    return false;
}

fn makePage(allocator: std.mem.Allocator, url: []const u8, title: []const u8, date: []const u8, description: []const u8, tags: []const u8, categories: []const u8) !Page {
    return .{ .url = try allocator.dupe(u8, url), .title = try allocator.dupe(u8, title), .date = try allocator.dupe(u8, date), .description = try allocator.dupe(u8, description), .tags = try allocator.dupe(u8, tags), .categories = try allocator.dupe(u8, categories) };
}

fn pageDateDesc(_: void, lhs: Page, rhs: Page) bool {
    return std.mem.order(u8, lhs.date, rhs.date) == .gt;
}

fn stringLessThan(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn collectTerms(allocator: std.mem.Allocator, terms: *std.ArrayListUnmanaged([]u8), raw: []const u8) !void {
    var split = std.mem.tokenizeAny(u8, raw, ",");
    while (split.next()) |part| {
        const term = std.mem.trim(u8, part, " \t");
        if (term.len == 0 or containsTermSlice(terms.items, term)) continue;
        try terms.append(allocator, try allocator.dupe(u8, term));
    }
}

fn containsTermSlice(terms: [][]u8, term: []const u8) bool {
    for (terms) |existing| if (std.ascii.eqlIgnoreCase(existing, term)) return true;
    return false;
}

fn hasTerm(raw: []const u8, term: []const u8) bool {
    var split = std.mem.tokenizeAny(u8, raw, ",");
    while (split.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), term)) return true;
    }
    return false;
}

fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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
    if (out.items.len == 0) try out.appendSlice(allocator, "x");
    return out.toOwnedSlice(allocator);
}

fn injectLiveReload(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const script =
        \\<script>
        \\(function(){var v=0;setInterval(function(){
        \\fetch('/_reload').then(r=>r.text()).then(t=>{if(v&&t!=v)location.reload();v=t;});
        \\},500);})();
        \\</script>
    ;
    if (std.mem.indexOf(u8, html, "</body>")) |idx| {
        return std.mem.concat(allocator, u8, &.{ html[0..idx], script, html[idx..] });
    }
    return std.mem.concat(allocator, u8, &.{ html, script });
}

fn buildTemplateVars(allocator: std.mem.Allocator, meta: std.StringHashMap([]const u8), config: Config, page_url: []const u8, toc: []const u8) !TemplateVars {
    var vars = std.StringHashMap([]const u8).init(allocator);
    errdefer vars.deinit();

    try vars.put("site_title", config.title);
    try vars.put("site_description", config.description);
    try vars.put("author", config.author);
    try vars.put("base_url", config.url);
    try vars.put("theme", config.theme);
    try vars.put("nav_html", config.nav_html);
    try vars.put("page_url", page_url);
    try vars.put("toc", toc);

    var iter = meta.iterator();
    while (iter.next()) |entry| {
        try vars.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    if (!vars.contains("description")) try vars.put("description", config.description);

    const permalink = try absoluteUrl(allocator, config.url, page_url);
    errdefer allocator.free(permalink);
    try vars.put("permalink", permalink);
    return .{ .map = vars, .permalink = permalink };
}

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn absoluteUrl(allocator: std.mem.Allocator, base_url: []const u8, page_url: []const u8) ![]u8 {
    if (base_url.len == 0) return allocator.dupe(u8, page_url);
    const base = std.mem.trimRight(u8, base_url, "/");
    if (page_url.len == 0) return allocator.dupe(u8, base);
    if (std.mem.startsWith(u8, page_url, "/")) return std.mem.concat(allocator, u8, &.{ base, page_url });
    return std.mem.concat(allocator, u8, &.{ base, "/", page_url });
}

fn outputPathForMarkdown(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const path = withoutExtension(filename);
    if (std.mem.eql(u8, path, "404")) return allocator.dupe(u8, "404.html");
    if (isIndexPath(path)) return std.mem.concat(allocator, u8, &.{ path, ".html" });
    return std.mem.concat(allocator, u8, &.{ path, "/index.html" });
}

fn urlForMarkdown(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const path = withoutExtension(filename);
    if (std.mem.eql(u8, path, "404")) return allocator.dupe(u8, "/404.html");
    if (std.mem.eql(u8, path, "index")) return allocator.dupe(u8, "/");
    if (std.mem.endsWith(u8, path, "/index")) return std.mem.concat(allocator, u8, &.{ "/", path[0 .. path.len - "/index".len], "/" });
    return std.mem.concat(allocator, u8, &.{ "/", path, "/" });
}

fn withoutExtension(filename: []const u8) []const u8 {
    const dot_idx = std.mem.lastIndexOf(u8, filename, ".") orelse filename.len;
    return filename[0..dot_idx];
}

fn isIndexPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "index") or std.mem.endsWith(u8, path, "/index");
}

fn copyStaticFiles(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !usize {
    var stats: StaticCopyStats = .{};
    try copyDir(allocator, src_dir, dest_dir, &stats, 0);
    return stats.count;
}

fn copyDir(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8, stats: *StaticCopyStats, depth: usize) !void {
    if (depth > max_directory_depth) return error.DirectoryDepthExceeded;

    var dir = try std.fs.cwd().openDir(src_dir, .{ .iterate = true, .no_follow = true });
    defer dir.close();

    std.fs.cwd().makePath(dest_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src_dir, entry.name });
        defer allocator.free(src_path);
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.name });
        defer allocator.free(dest_path);

        if (entry.kind == .directory) {
            try copyDir(allocator, src_path, dest_path, stats, depth + 1);
        } else if (entry.kind == .file) {
            if (stats.count >= max_static_files) return error.StaticFileLimitExceeded;
            try ensureNoSymlinkComponents(allocator, dest_dir);
            try ensureStaticDestinationAvailable(dest_path);
            const copied = try copyFile(allocator, src_path, dest_path, max_total_static_size - stats.bytes);
            stats.count += 1;
            stats.bytes += copied;
        }
    }
}

fn ensureStaticDestinationAvailable(dest: []const u8) !void {
    _ = std.fs.cwd().statFile(dest) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.StaticOutputCollision;
}

fn ensureStaticDestinationAvailableInDir(dir: std.fs.Dir, name: []const u8) !void {
    _ = dir.statFile(name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.StaticOutputCollision;
}

fn copyFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8, max_remaining: u64) !u64 {
    const src_file = try openFileNoFollow(allocator, src);
    defer src_file.close();
    const src_stat = try src_file.stat();
    if (src_stat.kind != .file) return error.InvalidStaticFile;

    var dest_parent = try openParentDirNoFollow(allocator, dest);
    defer dest_parent.deinit(allocator);
    const temp_name = try tempName(allocator, dest_parent.name);
    defer allocator.free(temp_name);
    errdefer dest_parent.dir.deleteFile(temp_name) catch {};

    const dest_file = try dest_parent.dir.createFile(temp_name, .{ .exclusive = true });
    var dest_file_closed = false;
    defer if (!dest_file_closed) dest_file.close();

    var copied: u64 = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try src_file.read(&buf);
        if (bytes_read == 0) break;
        copied += bytes_read;
        if (copied > max_static_file_size or copied > max_remaining) return error.StaticSizeLimitExceeded;
        try dest_file.writeAll(buf[0..bytes_read]);
    }

    dest_file.close();
    dest_file_closed = true;
    try ensureStaticDestinationAvailableInDir(dest_parent.dir, dest_parent.name);
    try dest_parent.dir.rename(temp_name, dest_parent.name);
    return copied;
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    var parent = try openParentDirNoFollow(allocator, path);
    defer parent.deinit(allocator);
    const temp_name = try tempName(allocator, parent.name);
    defer allocator.free(temp_name);
    errdefer parent.dir.deleteFile(temp_name) catch {};

    const file = try parent.dir.createFile(temp_name, .{ .exclusive = true });
    var file_closed = false;
    defer if (!file_closed) file.close();
    try file.writeAll(content);

    file.close();
    file_closed = true;
    try parent.dir.rename(temp_name, parent.name);
}

fn ensureOutputParentSafe(allocator: std.mem.Allocator, output_dir: []const u8, output_filename: []const u8) !void {
    const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_filename });
    defer allocator.free(output_path);

    if (std.fs.path.dirname(output_path)) |parent| {
        try ensureNoSymlinkComponents(allocator, parent);
    }
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
        if (kind == .sym_link) return error.SymlinkInOutputPath;

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

fn tempName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    return std.mem.concat(allocator, u8, &.{ name, ".", &suffix, ".tmp" });
}

fn isSameOrChildPath(allocator: std.mem.Allocator, parent_path: []const u8, child_path: []const u8) !bool {
    const parent = try std.fs.path.resolve(allocator, &.{parent_path});
    defer allocator.free(parent);
    const child = try std.fs.path.resolve(allocator, &.{child_path});
    defer allocator.free(child);

    const normalized_parent = std.mem.trimRight(u8, parent, &.{std.fs.path.sep});
    if (std.mem.eql(u8, normalized_parent, child)) return true;
    if (!std.mem.startsWith(u8, child, normalized_parent)) return false;
    return child.len > normalized_parent.len and child[normalized_parent.len] == std.fs.path.sep;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try openFileNoFollow(allocator, path);
    defer file.close();
    return file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn openFileNoFollow(allocator: std.mem.Allocator, path: []const u8) !std.fs.File {
    var parent = try openParentDirNoFollow(allocator, path);
    defer parent.deinit(allocator);
    return openFileNoFollowAt(parent.dir, parent.name);
}

fn openFileNoFollowAt(dir: std.fs.Dir, name: []const u8) !std.fs.File {
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(std.posix.O, "NOFOLLOW")) flags.NOFOLLOW = true;
    const fd = try std.posix.openat(dir.fd, name, flags, 0);
    return .{ .handle = fd };
}

fn openParentDirNoFollow(allocator: std.mem.Allocator, path: []const u8) !OpenParent {
    const resolved = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved);
    const name = std.fs.path.basename(resolved);
    if (name.len == 0) return error.InvalidPath;
    const parent_path = std.fs.path.dirname(resolved) orelse std.fs.path.sep_str;
    var dir = try openDirNoFollowPath(allocator, parent_path);
    errdefer dir.close();
    return .{ .dir = dir, .name = try allocator.dupe(u8, name) };
}

fn openDirNoFollowPath(allocator: std.mem.Allocator, path: []const u8) !std.fs.Dir {
    try ensureNoSymlinkComponents(allocator, path);
    return std.fs.cwd().openDir(path, .{ .access_sub_paths = true, .iterate = true, .no_follow = true });
}
