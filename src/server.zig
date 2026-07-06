const std = @import("std");

var version = std.atomic.Value(u32).init(0);
const max_connections = 64;
const read_timeout_ms = 2000;
const write_timeout_ms = 2000;
var active_connections = std.atomic.Value(usize).init(0);

const RequestPathError = error{
    InvalidPath,
    OutOfMemory,
};

const ServedFile = struct {
    path: []u8,
    file: std.fs.File,

    fn deinit(self: ServedFile, allocator: std.mem.Allocator) void {
        self.file.close();
        allocator.free(self.path);
    }
};

pub fn bump_version() void {
    _ = version.fetchAdd(1, .seq_cst);
}

pub fn listen(port: u16) !std.net.Server {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const sockfd = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    var srv = std.net.Server{
        .listen_address = addr,
        .stream = .{ .handle = sockfd },
    };
    errdefer srv.stream.close();

    try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    var socklen = addr.getOsSockLen();
    try std.posix.bind(sockfd, &addr.any, socklen);
    try std.posix.listen(sockfd, 128);
    try std.posix.getsockname(sockfd, &srv.listen_address.any, &socklen);
    return srv;
}

pub fn run(allocator: std.mem.Allocator, root_dir: []const u8, listener: std.net.Server) void {
    var srv = listener;
    defer srv.deinit();

    const root_dir_copy = allocator.dupe(u8, root_dir) catch return;

    while (true) {
        const conn = srv.accept() catch continue;
        const active = active_connections.fetchAdd(1, .seq_cst);
        if (active >= max_connections) {
            _ = active_connections.fetchSub(1, .seq_cst);
            conn.stream.close();
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ allocator, conn, root_dir_copy }) catch {
            _ = active_connections.fetchSub(1, .seq_cst);
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: std.net.Server.Connection, root_dir: []const u8) void {
    defer _ = active_connections.fetchSub(1, .seq_cst);
    defer conn.stream.close();
    setSocketTimeouts(conn.stream) catch return;
    handleRequest(allocator, conn, root_dir) catch {};
}

fn handleRequest(allocator: std.mem.Allocator, conn: std.net.Server.Connection, root_dir: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const n = try readWithTimeout(conn.stream, &buf, read_timeout_ms);
    if (n == 0) return;

    const request = buf[0..n];
    const path = parsePath(request) orelse return;
    const decoded_path = decodeRequestPath(allocator, path) catch {
        try sendResponse(conn.stream, "400 Bad Request", "text/plain", "bad request");
        return;
    };
    defer allocator.free(decoded_path);

    if (std.mem.eql(u8, decoded_path, "/_reload")) {
        var version_buf: [16]u8 = undefined;
        const version_str = std.fmt.bufPrint(&version_buf, "{d}", .{version.load(.seq_cst)}) catch "0";
        try sendResponse(conn.stream, "200 OK", "text/plain", version_str);
        return;
    }

    if (!isSafeRequestPath(decoded_path)) {
        try sendResponse(conn.stream, "403 Forbidden", "text/plain", "forbidden");
        return;
    }

    const served_file = readRequestFile(allocator, root_dir, decoded_path) catch {
        const error_page = std.fs.path.join(allocator, &.{ root_dir, "404.html" }) catch {
            try sendResponse(conn.stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer allocator.free(error_page);
        ensureNoSymlinkComponents(allocator, root_dir, "404.html") catch {
            try sendResponse(conn.stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        const error_content = openRegularFile(error_page) catch {
            try sendResponse(conn.stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer error_content.close();
        try sendFileResponse(conn.stream, "404 Not Found", "text/html", error_content);
        return;
    };
    defer served_file.deinit(allocator);

    const mime = getMime(served_file.path);
    try sendFileResponse(conn.stream, "200 OK", mime, served_file.file);
}

fn setSocketTimeouts(stream: std.net.Stream) !void {
    const read_timeout = std.posix.timeval{
        .sec = @intCast(read_timeout_ms / 1000),
        .usec = @intCast((read_timeout_ms % 1000) * 1000),
    };
    const write_timeout = std.posix.timeval{
        .sec = @intCast(write_timeout_ms / 1000),
        .usec = @intCast((write_timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&read_timeout));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&write_timeout));
}

fn readWithTimeout(stream: std.net.Stream, buf: []u8, timeout_ms: u64) !usize {
    const start = std.time.milliTimestamp();
    while (true) {
        const n = stream.read(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) return n;

        const elapsed_ms = std.time.milliTimestamp() - start;
        if (elapsed_ms >= timeout_ms) return 0;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn readRequestFile(allocator: std.mem.Allocator, root_dir: []const u8, path: []const u8) !ServedFile {
    const relative_path = if (std.mem.eql(u8, path, "/")) "index.html" else path[1..];
    if (relative_path.len == 0 or std.fs.path.isAbsolute(relative_path)) return error.InvalidPath;

    const direct_path = try std.fs.path.join(allocator, &.{ root_dir, relative_path });
    try ensureNoSymlinkComponents(allocator, root_dir, relative_path);
    const direct_stat = std.fs.cwd().statFile(direct_path) catch {
        allocator.free(direct_path);
        const index_path = try std.fs.path.join(allocator, &.{ root_dir, relative_path, "index.html" });
        const index_relative_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
        defer allocator.free(index_relative_path);
        try ensureNoSymlinkComponents(allocator, root_dir, index_relative_path);
        const index_stat = std.fs.cwd().statFile(index_path) catch |err| {
            allocator.free(index_path);
            return err;
        };
        if (index_stat.kind != .file) {
            allocator.free(index_path);
            return error.InvalidPath;
        }
        const file = openRegularFile(index_path) catch |err| {
            allocator.free(index_path);
            return err;
        };
        return .{ .path = index_path, .file = file };
    };

    if (direct_stat.kind != .file) {
        allocator.free(direct_path);
        const index_path = try std.fs.path.join(allocator, &.{ root_dir, relative_path, "index.html" });
        const index_relative_path = try std.fs.path.join(allocator, &.{ relative_path, "index.html" });
        defer allocator.free(index_relative_path);
        try ensureNoSymlinkComponents(allocator, root_dir, index_relative_path);
        const index_stat = std.fs.cwd().statFile(index_path) catch |err| {
            allocator.free(index_path);
            return err;
        };
        if (index_stat.kind != .file) {
            allocator.free(index_path);
            return error.InvalidPath;
        }
        const file = openRegularFile(index_path) catch |err| {
            allocator.free(index_path);
            return err;
        };
        return .{ .path = index_path, .file = file };
    }

    const file = openRegularFile(direct_path) catch |err| {
        allocator.free(direct_path);
        return err;
    };
    return .{ .path = direct_path, .file = file };
}

fn openRegularFile(path: []const u8) !std.fs.File {
    const file = try openFileNoFollow(path);
    errdefer file.close();
    const stat = try file.stat();
    if (stat.kind != .file) return error.InvalidPath;
    return file;
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

fn ensureNoSymlinkComponents(allocator: std.mem.Allocator, root_dir: []const u8, relative_path: []const u8) !void {
    var current = try allocator.dupe(u8, root_dir);
    defer allocator.free(current);

    var parts = std.mem.tokenizeScalar(u8, relative_path, std.fs.path.sep);
    while (parts.next()) |part| {
        var dir = try std.fs.cwd().openDir(current, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        var found = false;
        while (try iter.next()) |entry| {
            if (!std.mem.eql(u8, entry.name, part)) continue;
            if (entry.kind == .sym_link) return error.SymlinkInServedPath;
            found = true;
            break;
        }

        if (!found) return error.FileNotFound;
        if (parts.peek() != null) {
            const next = try std.fs.path.join(allocator, &.{ current, part });
            allocator.free(current);
            current = next;
        }
    }
}

fn parsePath(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const start = 4;
    const end = std.mem.indexOf(u8, request[start..], " ") orelse return null;
    return request[start .. start + end];
}

fn decodeRequestPath(allocator: std.mem.Allocator, request_target: []const u8) RequestPathError![]u8 {
    if (request_target.len == 0 or request_target[0] != '/') return RequestPathError.InvalidPath;

    const query_idx = std.mem.indexOfAny(u8, request_target, "?#") orelse request_target.len;
    const raw_path = request_target[0..query_idx];

    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        if (raw_path[i] == '%') {
            if (i + 2 >= raw_path.len) return RequestPathError.InvalidPath;
            const hi = hexValue(raw_path[i + 1]) orelse return RequestPathError.InvalidPath;
            const lo = hexValue(raw_path[i + 2]) orelse return RequestPathError.InvalidPath;
            try decoded.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try decoded.append(allocator, raw_path[i]);
            i += 1;
        }
    }

    return decoded.toOwnedSlice(allocator);
}

fn isSafeRequestPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == 0 or c == '\\') return false;
        }
    }

    return true;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    try stream.writeAll(header);
    try stream.writeAll(body);
}

fn sendFileResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, file: std.fs.File) !void {
    const stat = try file.stat();
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, stat.size }) catch return;
    try stream.writeAll(header);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try stream.writeAll(buf[0..n]);
    }
}

fn getMime(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".woff")) return "font/woff";
    return "application/octet-stream";
}

test "request path validation rejects encoded traversal" {
    const decoded = try decodeRequestPath(std.testing.allocator, "/safe/%2e%2e/secret");
    defer std.testing.allocator.free(decoded);

    try std.testing.expect(!isSafeRequestPath(decoded));
}

test "request path validation strips query strings" {
    const decoded = try decodeRequestPath(std.testing.allocator, "/about/?x=1");
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("/about/", decoded);
    try std.testing.expect(isSafeRequestPath(decoded));
}
