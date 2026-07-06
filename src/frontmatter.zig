const std = @import("std");

pub const FrontMatter = struct {
    meta: std.StringHashMap([]const u8),
    content: []const u8,

    pub fn deinit(self: *FrontMatter) void {
        self.meta.deinit();
    }

    pub fn get(self: *const FrontMatter, key: []const u8) ?[]const u8 {
        return self.meta.get(key);
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !FrontMatter {
    var meta = std.StringHashMap([]const u8).init(allocator);
    errdefer meta.deinit();

    if (!std.mem.startsWith(u8, input, "---")) {
        return FrontMatter{ .meta = meta, .content = input };
    }

    const after_open = input[3..];
    const close_idx = std.mem.indexOf(u8, after_open, "\n---");
    if (close_idx == null) {
        return FrontMatter{ .meta = meta, .content = input };
    }

    const front_matter_block = after_open[0..close_idx.?];
    const content_start = 3 + close_idx.? + 4;
    const content = if (content_start < input.len) skipLeadingNewlines(input[content_start..]) else "";

    var lines = std.mem.splitScalar(u8, front_matter_block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
            const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");
            if (std.mem.eql(u8, key, "content") or std.mem.eql(u8, key, "nav_html") or std.mem.eql(u8, key, "toc")) return error.ReservedFrontmatterKey;
            try meta.put(key, value);
        }
    }

    return FrontMatter{ .meta = meta, .content = content };
}

fn skipLeadingNewlines(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == '\n' or s[i] == '\r')) : (i += 1) {}
    return s[i..];
}
