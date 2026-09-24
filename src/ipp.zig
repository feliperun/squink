//! A small IPP/1.1-2.0 client (RFC 8010/8011): just enough to ask printers and CUPS
//! for attributes. Binary encoding, HTTP/1.1 POST over TCP or a Unix socket, with a
//! hard deadline. No dependencies.
const std = @import("std");
const sys = @import("sys.zig");

pub const op = struct {
    pub const get_job_attributes: u16 = 0x0009;
    pub const get_jobs: u16 = 0x000A;
    pub const get_printer_attributes: u16 = 0x000B;
};

pub const tag = struct {
    // delimiters
    pub const operation_group: u8 = 0x01;
    pub const job_group: u8 = 0x02;
    pub const end: u8 = 0x03;
    pub const printer_group: u8 = 0x04;
    // values
    pub const integer: u8 = 0x21;
    pub const boolean: u8 = 0x22;
    pub const enumeration: u8 = 0x23;
    pub const text: u8 = 0x41;
    pub const name: u8 = 0x42;
    pub const keyword: u8 = 0x44;
    pub const uri: u8 = 0x45;
    pub const charset: u8 = 0x47;
    pub const language: u8 = 0x48;
};

/// IPP job-state values.
pub const JobState = enum(i32) {
    pending = 3,
    held = 4,
    processing = 5,
    stopped = 6,
    canceled = 7,
    aborted = 8,
    completed = 9,
    _,

    pub fn isFinal(s: JobState) bool {
        return @intFromEnum(s) >= 7;
    }

    pub fn label(s: JobState) []const u8 {
        return switch (s) {
            .pending => "pending",
            .held => "held",
            .processing => "processing",
            .stopped => "stopped",
            .canceled => "canceled",
            .aborted => "aborted",
            .completed => "completed",
            _ => "unknown",
        };
    }
};

/// IPP printer-state values.
pub fn printerStateLabel(v: i32) []const u8 {
    return switch (v) {
        3 => "idle",
        4 => "processing",
        5 => "stopped",
        else => "unknown",
    };
}

// ------------------------------------------------------------------- encoding

pub const Request = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    /// Starts a request with the mandatory operation attributes (charset, language).
    pub fn init(gpa: std.mem.Allocator, operation: u16) !Request {
        var r: Request = .{ .gpa = gpa };
        try r.bytes.appendSlice(gpa, &.{ 2, 0 }); // version 2.0
        try r.u16be(operation);
        try r.bytes.appendSlice(gpa, &.{ 0, 0, 0, 1 }); // request-id
        try r.bytes.append(gpa, tag.operation_group);
        try r.add(tag.charset, "attributes-charset", "utf-8");
        try r.add(tag.language, "attributes-natural-language", "en");
        return r;
    }

    pub fn add(self: *Request, value_tag: u8, attr_name: []const u8, value: []const u8) !void {
        try self.bytes.append(self.gpa, value_tag);
        try self.u16be(@intCast(attr_name.len));
        try self.bytes.appendSlice(self.gpa, attr_name);
        try self.u16be(@intCast(value.len));
        try self.bytes.appendSlice(self.gpa, value);
    }

    pub fn addInt(self: *Request, value_tag: u8, attr_name: []const u8, value: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, value, .big);
        try self.add(value_tag, attr_name, &b);
    }

    /// A 1setOf keyword: the first value carries the name, the rest an empty one.
    pub fn addKeywords(self: *Request, attr_name: []const u8, values: []const []const u8) !void {
        for (values, 0..) |v, i| try self.add(tag.keyword, if (i == 0) attr_name else "", v);
    }

    pub fn finish(self: *Request) ![]const u8 {
        try self.bytes.append(self.gpa, tag.end);
        return self.bytes.items;
    }

    fn u16be(self: *Request, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        try self.bytes.appendSlice(self.gpa, &b);
    }
};

// ------------------------------------------------------------------- decoding

pub const Attribute = struct {
    name: []const u8,
    value_tag: u8,
    values: std.ArrayList([]const u8) = .empty,

    pub fn int(self: Attribute, i: usize) ?i32 {
        if (i >= self.values.items.len or self.values.items[i].len != 4) return null;
        return std.mem.readInt(i32, self.values.items[i][0..4], .big);
    }
};

pub const Group = struct {
    group_tag: u8,
    attrs: std.ArrayList(Attribute) = .empty,

    pub fn get(self: *const Group, attr_name: []const u8) ?*const Attribute {
        for (self.attrs.items) |*a| {
            if (std.mem.eql(u8, a.name, attr_name)) return a;
        }
        return null;
    }

    /// First value as bytes (text, keyword, uri...).
    pub fn str(self: *const Group, attr_name: []const u8) ?[]const u8 {
        const a = self.get(attr_name) orelse return null;
        return if (a.values.items.len > 0) a.values.items[0] else null;
    }

    /// First value as integer/enum.
    pub fn int(self: *const Group, attr_name: []const u8) ?i32 {
        const a = self.get(attr_name) orelse return null;
        return a.int(0);
    }

    pub fn boolean(self: *const Group, attr_name: []const u8) ?bool {
        const s = self.str(attr_name) orelse return null;
        return s.len == 1 and s[0] != 0;
    }
};

pub const Response = struct {
    /// IPP status-code: 0x0000-0x00FF are successes.
    status: u16,
    groups: std.ArrayList(Group) = .empty,

    pub fn ok(self: Response) bool {
        return self.status < 0x0100;
    }

    pub fn first(self: *const Response, group_tag: u8) ?*const Group {
        for (self.groups.items) |*g| {
            if (g.group_tag == group_tag) return g;
        }
        return null;
    }
};

pub fn parse(gpa: std.mem.Allocator, data: []const u8) !Response {
    if (data.len < 8) return error.InvalidIpp;
    var resp: Response = .{ .status = std.mem.readInt(u16, data[2..4], .big) };
    var i: usize = 8;
    var group: ?*Group = null;
    while (i < data.len) {
        const t = data[i];
        i += 1;
        if (t == tag.end) break;
        if (t < 0x10) {
            try resp.groups.append(gpa, .{ .group_tag = t });
            group = &resp.groups.items[resp.groups.items.len - 1];
            continue;
        }
        const g = group orelse return error.InvalidIpp;
        if (i + 2 > data.len) return error.InvalidIpp;
        const name_len = std.mem.readInt(u16, data[i..][0..2], .big);
        i += 2;
        if (i + name_len + 2 > data.len) return error.InvalidIpp;
        const attr_name = data[i .. i + name_len];
        i += name_len;
        const value_len = std.mem.readInt(u16, data[i..][0..2], .big);
        i += 2;
        if (i + value_len > data.len) return error.InvalidIpp;
        const value = data[i .. i + value_len];
        i += value_len;

        if (name_len == 0) {
            // Additional value of the previous attribute (1setOf). Collection members
            // also land here; nothing in squink reads collections.
            if (g.attrs.items.len == 0) return error.InvalidIpp;
            try g.attrs.items[g.attrs.items.len - 1].values.append(gpa, value);
        } else {
            var a: Attribute = .{ .name = attr_name, .value_tag = t };
            try a.values.append(gpa, value);
            try g.attrs.append(gpa, a);
        }
    }
    return resp;
}

// ------------------------------------------------------------------ transport

pub const Endpoint = union(enum) {
    tcp: struct { ip: [4]u8, port: u16 },
    unix: []const u8,
};

pub const Error = error{ ConnectFailed, Timeout, TlsFailed, HttpError, InvalidHttp, InvalidIpp, TooLarge, OutOfMemory };

/// POSTs an IPP request and returns the parsed response. `timeout_ms` bounds each
/// exchange: connect, send and receive.
///
/// Printers that insist on encryption answer plain HTTP with "426 Upgrade Required"
/// (Epson does); the request is then repeated over TLS, as ipps://. Printer
/// certificates are self-signed, so they are not verified.
pub fn call(
    gpa: std.mem.Allocator,
    endpoint: Endpoint,
    host: []const u8,
    path: []const u8,
    body: []const u8,
    timeout_ms: i64,
) Error!Response {
    const head = std.fmt.allocPrint(gpa, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/ipp\r\n" ++
        "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, host, body.len }) catch return error.OutOfMemory;
    const request = std.mem.concat(gpa, u8, &.{ head, body }) catch return error.OutOfMemory;

    var raw = try exchangePlain(gpa, endpoint, request, timeout_ms);
    const upgrade = if (splitHttp(raw)) |h| h.status == 426 else false;
    if (upgrade and endpoint == .tcp) raw = try exchangeTls(gpa, endpoint.tcp.ip, endpoint.tcp.port, request, timeout_ms);
    const payload = try httpBody(gpa, raw);
    return parse(gpa, payload) catch error.InvalidIpp;
}

fn connect(endpoint: Endpoint, deadline: i64) Error!sys.Fd {
    return switch (endpoint) {
        .tcp => |t| sys.connectTcp(t.ip, t.port, deadline),
        .unix => |p| sys.connectUnix(p, deadline),
    } catch |e| if (e == error.Timeout) error.Timeout else error.ConnectFailed;
}

fn exchangePlain(gpa: std.mem.Allocator, endpoint: Endpoint, request: []const u8, timeout_ms: i64) Error![]const u8 {
    const deadline = sys.milliTimestamp() + timeout_ms;
    const fd = try connect(endpoint, deadline);
    defer sys.close(fd);
    sys.writeAll(fd, request, deadline) catch |e| return if (e == error.Timeout) error.Timeout else error.ConnectFailed;

    var raw: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf, deadline) catch |e| switch (e) {
            error.Timeout => return error.Timeout,
            // A printer that wants TLS may reset right after its 426 answer.
            error.ConnectionReset => break,
            else => return error.ConnectFailed,
        };
        if (n == 0) break;
        raw.appendSlice(gpa, buf[0..n]) catch return error.OutOfMemory;
        if (raw.items.len > 8 << 20) return error.TooLarge;
        // Some printers keep the connection open despite "Connection: close".
        if (httpComplete(raw.items)) break;
    }
    return raw.items;
}

fn exchangeTls(gpa: std.mem.Allocator, ip: [4]u8, port: u16, request: []const u8, timeout_ms: i64) Error![]const u8 {
    const tls = std.crypto.tls;
    const deadline = sys.milliTimestamp() + timeout_ms;
    const fd = try connect(.{ .tcp = .{ .ip = ip, .port = port } }, deadline);
    defer sys.close(fd);

    const bufs = gpa.alloc(u8, 4 * tls.Client.min_buffer_len) catch return error.OutOfMemory;
    const n = tls.Client.min_buffer_len;
    var sock_r = sys.SocketReader.init(fd, deadline, bufs[0..n]);
    var sock_w = sys.SocketWriter.init(fd, deadline, bufs[n .. 2 * n]);
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    sys.randomBytes(&entropy);
    var client = tls.Client.init(&sock_r.interface, &sock_w.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = bufs[2 * n .. 3 * n],
        .write_buffer = bufs[3 * n ..],
        .entropy = &entropy,
        .realtime_now = std.Io.Timestamp.now(sys.io, .real),
        // HTTP's Content-Length / chunked framing detects truncation.
        .allow_truncation_attacks = true,
    }) catch return if (timedOut(sock_r.err) or timedOut(sock_w.err)) error.Timeout else error.TlsFailed;

    client.writer.writeAll(request) catch return error.TlsFailed;
    client.writer.flush() catch return error.TlsFailed;
    sock_w.interface.flush() catch return error.TlsFailed;

    var raw: std.ArrayList(u8) = .empty;
    while (!httpComplete(raw.items)) {
        client.reader.fillMore() catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                if (timedOut(sock_r.err)) return error.Timeout;
                return if (raw.items.len > 0) error.InvalidHttp else error.TlsFailed;
            },
        };
        const got = client.reader.buffered();
        raw.appendSlice(gpa, got) catch return error.OutOfMemory;
        client.reader.toss(got.len);
        if (raw.items.len > 8 << 20) return error.TooLarge;
    }
    return raw.items;
}

fn timedOut(e: ?sys.Error) bool {
    return if (e) |err| err == error.Timeout else false;
}

const Http = struct { status: u16, headers: []const u8, body: []const u8 };

/// Splits the final HTTP response (skipping any "100 Continue").
fn splitHttp(raw: []const u8) ?Http {
    var rest = raw;
    while (true) {
        const end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return null;
        const head = rest[0..end];
        if (!std.mem.startsWith(u8, head, "HTTP/1.")) return null;
        const sp = std.mem.indexOfScalar(u8, head, ' ') orelse return null;
        if (sp + 4 > head.len) return null;
        const status = std.fmt.parseInt(u16, head[sp + 1 .. sp + 4], 10) catch return null;
        if (status == 100) {
            rest = rest[end + 4 ..];
            continue;
        }
        return .{ .status = status, .headers = head, .body = rest[end + 4 ..] };
    }
}

fn header(headers: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), key))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn isChunked(headers: []const u8) bool {
    const te = header(headers, "transfer-encoding") orelse return false;
    return std.ascii.indexOfIgnoreCase(te, "chunked") != null;
}

/// Is the whole response already here? (Lets us stop without waiting for EOF.)
fn httpComplete(raw: []const u8) bool {
    const h = splitHttp(raw) orelse return false;
    if (isChunked(h.headers)) return std.mem.endsWith(u8, h.body, "0\r\n\r\n");
    const len_str = header(h.headers, "content-length") orelse return false;
    const len = std.fmt.parseInt(usize, len_str, 10) catch return false;
    return h.body.len >= len;
}

fn httpBody(gpa: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const h = splitHttp(raw) orelse return error.InvalidHttp;
    if (h.status != 200) return error.HttpError;
    if (isChunked(h.headers)) return dechunk(gpa, h.body);
    if (header(h.headers, "content-length")) |len_str| {
        const len = std.fmt.parseInt(usize, len_str, 10) catch return error.InvalidHttp;
        if (h.body.len < len) return error.InvalidHttp;
        return h.body[0..len];
    }
    return h.body;
}

fn dechunk(gpa: std.mem.Allocator, body: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (true) {
        const eol = std.mem.indexOfPos(u8, body, i, "\r\n") orelse return error.InvalidHttp;
        const size_str = body[i..eol];
        const semi = std.mem.indexOfScalar(u8, size_str, ';') orelse size_str.len;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_str[0..semi], " "), 16) catch
            return error.InvalidHttp;
        i = eol + 2;
        if (size == 0) return out.items;
        if (i + size > body.len) return error.InvalidHttp;
        out.appendSlice(gpa, body[i .. i + size]) catch return error.OutOfMemory;
        i += size + 2;
    }
}

// ---------------------------------------------------------------------- CUPS

/// Where cupsd listens locally: Debian/Ubuntu, and macOS.
const cups_socket = if (sys.is_darwin) "/private/var/run/cupsd" else "/run/cups/cups.sock";

/// Sends a request to the local CUPS scheduler: its Unix socket first, then
/// localhost:631.
pub fn cups(gpa: std.mem.Allocator, body: []const u8) Error!Response {
    return call(gpa, .{ .unix = cups_socket }, "localhost", "/", body, 5000) catch
        call(gpa, .{ .tcp = .{ .ip = .{ 127, 0, 0, 1 }, .port = 631 } }, "localhost", "/", body, 5000);
}

pub fn userName() []const u8 {
    return sys.getenv("USER") orelse sys.getenv("LOGNAME") orelse "anonymous";
}

// ---------------------------------------------------------------------- tests

test "request encoding matches the wire format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = try Request.init(arena.allocator(), op.get_printer_attributes);
    try r.add(tag.uri, "printer-uri", "ipp://x/ipp/print");
    try r.addKeywords("requested-attributes", &.{ "a", "b" });
    const bytes = try r.finish();
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0x0B, 0, 0, 0, 1, 0x01, 0x47, 0, 18 }, bytes[0..12]);
    try std.testing.expectEqual(tag.end, bytes[bytes.len - 1]);

    // Our own request parses back: 2 groups-worth of attributes in one operation group.
    const resp = try parse(arena.allocator(), bytes);
    const g = resp.first(tag.operation_group).?;
    try std.testing.expectEqualStrings("utf-8", g.str("attributes-charset").?);
    try std.testing.expectEqual(@as(usize, 2), g.get("requested-attributes").?.values.items.len);
}

test "response parsing: groups, 1setOf and integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var r = try Request.init(gpa, 0); // same layout as a response with status 0
    try r.bytes.append(gpa, tag.printer_group);
    try r.add(tag.text, "printer-make-and-model", "EPSON L3250 Series");
    try r.addInt(tag.enumeration, "printer-state", 3);
    try r.add(tag.name, "marker-names", "Black");
    try r.add(tag.name, "", "Cyan");
    try r.addInt(tag.integer, "marker-levels", 80);
    try r.addInt(tag.integer, "", -3);
    const resp = try parse(gpa, try r.finish());
    try std.testing.expect(resp.ok());
    const p = resp.first(tag.printer_group).?;
    try std.testing.expectEqualStrings("EPSON L3250 Series", p.str("printer-make-and-model").?);
    try std.testing.expectEqual(@as(i32, 3), p.int("printer-state").?);
    try std.testing.expectEqualStrings("Cyan", p.get("marker-names").?.values.items[1]);
    try std.testing.expectEqual(@as(i32, -3), p.get("marker-levels").?.int(1).?);
    try std.testing.expectError(error.InvalidIpp, parse(gpa, &.{ 2, 0 }));
}

test "http body: content-length, chunked and 100 Continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const plain = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcEXTRA";
    try std.testing.expectEqualStrings("abc", try httpBody(gpa, plain));
    try std.testing.expect(httpComplete(plain));

    const chunked = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "3\r\nabc\r\na;x=1\r\n0123456789\r\n0\r\n\r\n";
    try std.testing.expectEqualStrings("abc0123456789", try httpBody(gpa, chunked));
    try std.testing.expect(httpComplete(chunked));
    try std.testing.expect(!httpComplete("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nabc"));
    try std.testing.expectError(error.HttpError, httpBody(gpa, "HTTP/1.1 404 Not Found\r\n\r\n"));
}

test "call talks HTTP to a local server" {
    sys.initForTests();
    const io = sys.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const Srv = struct {
        fn serve(s: *std.Io.net.Server) void {
            const conn = s.accept(sys.io) catch return;
            defer conn.close(sys.io);
            var buf: [4096]u8 = undefined;
            _ = sys.read(conn.socket.handle, &buf, sys.milliTimestamp() + 2000) catch return;
            // status 0x0000, one printer group with printer-state = 3 (idle)
            const ipp_body = [_]u8{ 2, 0, 0, 0, 0, 0, 0, 1, 0x04, 0x23, 0, 13 } ++ "printer-state".* ++
                [_]u8{ 0, 4, 0, 0, 0, 3, 0x03 };
            var head_buf: [128]u8 = undefined;
            const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{ipp_body.len}) catch return;
            const deadline = sys.milliTimestamp() + 2000;
            sys.writeAll(conn.socket.handle, head, deadline) catch return;
            sys.writeAll(conn.socket.handle, &ipp_body, deadline) catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, Srv.serve, .{&server});
    defer t.join();

    var req = try Request.init(gpa, op.get_printer_attributes);
    const resp = try call(gpa, .{ .tcp = .{ .ip = .{ 127, 0, 0, 1 }, .port = port } }, "localhost", "/", try req.finish(), 2000);
    try std.testing.expectEqual(@as(i32, 3), resp.first(tag.printer_group).?.int("printer-state").?);
}
