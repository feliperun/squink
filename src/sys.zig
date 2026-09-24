//! The operating system, for every other module: the process's `std.Io`, its
//! environment, clocks, and TCP/Unix sockets with deadlines.
//!
//! Sockets are raw because `std.Io.net` (Zig 0.16) cannot bound a connect by time
//! yet, and the network scan depends on that. Linux goes through syscalls (the
//! binary stays static, no libc); macOS through libSystem.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;

pub const is_darwin = builtin.os.tag.isDarwin();

/// Set once by `main` (and by tests) before anything else runs.
pub var io: std.Io = undefined;
var env: ?*const std.process.Environ.Map = null;

pub fn init(the_io: std.Io, environ: ?*const std.process.Environ.Map) void {
    io = the_io;
    env = environ;
}

pub fn getenv(key: []const u8) ?[]const u8 {
    const m = env orelse return null;
    return m.get(key);
}

/// Wall-clock time in milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Wall-clock time in seconds since the Unix epoch.
pub fn timestamp() i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub fn sleepMs(ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub fn randomBytes(buf: []u8) void {
    io.random(buf);
}

pub fn geteuid() u32 {
    return @intCast(system.geteuid());
}

// --------------------------------------------------------------------- sockets

pub const Fd = posix.fd_t;
pub const Error = error{ ConnectFailed, Timeout, ConnectionReset };

/// macOS refused a connection to the local network: the app running squink lacks
/// the Local Network permission (macOS 15+). Reported next to "unreachable" errors.
pub var lan_blocked = false;

/// Hint for error messages when macOS blocked the local network. Empty otherwise.
pub fn lanHint() []const u8 {
    if (!lan_blocked) return "";
    return "\n  macOS blocked the connection (No route to host): allow Local Network for the app" ++
        "\n  running squink (System Settings > Privacy & Security > Local Network), then retry";
}

fn noteRefusal(e: posix.E) void {
    if (is_darwin and e == .HOSTUNREACH) lan_blocked = true;
}

pub fn close(fd: Fd) void {
    _ = system.close(fd);
}

/// A non-blocking, close-on-exec socket. (macOS has no SOCK_NONBLOCK / SOCK_CLOEXEC.)
fn openSocket(family: u32, kind: u32) Error!Fd {
    const rc = system.socket(family, kind, 0);
    if (posix.errno(rc) != .SUCCESS) return error.ConnectFailed;
    const fd: Fd = @intCast(rc);
    errdefer close(fd);
    const fd_cloexec: usize = 1;
    if (posix.errno(system.fcntl(fd, posix.F.SETFD, fd_cloexec)) != .SUCCESS) return error.ConnectFailed;
    try setBlocking(fd, false);
    return fd;
}

pub fn setBlocking(fd: Fd, blocking: bool) Error!void {
    const flags_rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags_rc) != .SUCCESS) return error.ConnectFailed;
    const flags: usize = @intCast(flags_rc);
    const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    const new = if (blocking) flags & ~nonblock else flags | nonblock;
    if (posix.errno(system.fcntl(fd, posix.F.SETFL, new)) != .SUCCESS) return error.ConnectFailed;
}

fn inAddr(ip: [4]u8, port: u16) posix.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip) };
}

/// Starts a connect on a non-blocking socket and waits for it until `deadline` (ms).
fn finishConnect(fd: Fd, addr: *const posix.sockaddr, len: posix.socklen_t, deadline: i64) Error!void {
    while (true) {
        switch (posix.errno(system.connect(fd, addr, len))) {
            .SUCCESS => return,
            .INTR => continue,
            .INPROGRESS, .AGAIN => break,
            else => |e| {
                noteRefusal(e);
                return error.ConnectFailed;
            },
        }
    }
    try waitFor(fd, posix.POLL.OUT, deadline);
    var so_error: i32 = 0;
    var so_len: posix.socklen_t = @sizeOf(i32);
    if (posix.errno(system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&so_error), &so_len)) != .SUCCESS)
        return error.ConnectFailed;
    if (so_error != 0) {
        noteRefusal(@enumFromInt(so_error));
        return error.ConnectFailed;
    }
}

/// TCP connection to `ip:port`, non-blocking once connected.
pub fn connectTcp(ip: [4]u8, port: u16, deadline: i64) Error!Fd {
    const fd = try openSocket(posix.AF.INET, posix.SOCK.STREAM);
    errdefer close(fd);
    const sa = inAddr(ip, port);
    try finishConnect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in), deadline);
    return fd;
}

pub fn connectUnix(path: []const u8, deadline: i64) Error!Fd {
    var sa: posix.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= sa.path.len) return error.ConnectFailed;
    @memcpy(sa.path[0..path.len], path);
    const fd = try openSocket(posix.AF.UNIX, posix.SOCK.STREAM);
    errdefer close(fd);
    try finishConnect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.un), deadline);
    return fd;
}

/// Waits until `fd` is ready for `events` (POLL.IN / POLL.OUT) or `deadline` passes.
pub fn waitFor(fd: Fd, events: i16, deadline: i64) Error!void {
    while (true) {
        const left = deadline - milliTimestamp();
        if (left <= 0) return error.Timeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const n = posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32)))) catch return error.ConnectFailed;
        if (n > 0) return;
    }
}

/// One read. 0 = end of stream. Waits for data until `deadline`.
pub fn read(fd: Fd, buf: []u8, deadline: i64) Error!usize {
    while (true) {
        try waitFor(fd, posix.POLL.IN, deadline);
        const rc = system.read(fd, buf.ptr, buf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR, .AGAIN => continue,
            .CONNRESET => return error.ConnectionReset,
            else => return error.ConnectFailed,
        }
    }
}

pub fn writeAll(fd: Fd, data: []const u8, deadline: i64) Error!void {
    var sent: usize = 0;
    while (sent < data.len) {
        try waitFor(fd, posix.POLL.OUT, deadline);
        const rc = system.write(fd, data[sent..].ptr, data.len - sent);
        switch (posix.errno(rc)) {
            .SUCCESS => sent += @intCast(rc),
            .INTR, .AGAIN => {},
            .CONNRESET, .PIPE => return error.ConnectionReset,
            else => return error.ConnectFailed,
        }
    }
}

/// TCP connect with a timeout that closes right away and sends nothing.
pub fn portOpen(ip: [4]u8, port: u16, timeout_ms: i64) bool {
    const fd = connectTcp(ip, port, milliTimestamp() + timeout_ms) catch return false;
    close(fd);
    return true;
}

/// IPv4 address of the default-route interface. A UDP connect sends no packet.
pub fn localIp() ?[4]u8 {
    const rc = system.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: Fd = @intCast(rc);
    defer close(fd);
    const dst = inAddr(.{ 1, 1, 1, 1 }, 80);
    if (posix.errno(system.connect(fd, @ptrCast(&dst), @sizeOf(posix.sockaddr.in))) != .SUCCESS) return null;
    var local: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (posix.errno(system.getsockname(fd, @ptrCast(&local), &len)) != .SUCCESS) return null;
    return @bitCast(local.addr);
}

/// IPv4 address of a host name through the system resolver (macOS answers `.local`
/// names over mDNS). Linux has no libc here, so no resolver: null.
pub fn resolveIp4(gpa: std.mem.Allocator, host: []const u8) ?[4]u8 {
    if (!is_darwin) return null;
    const c = std.c;
    const name = gpa.dupeZ(u8, host) catch return null;
    const hints: c.addrinfo = .{
        .flags = .{},
        .family = posix.AF.INET,
        .socktype = posix.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .addr = null,
        .canonname = null,
        .next = null,
    };
    var res: ?*c.addrinfo = null;
    if (@intFromEnum(c.getaddrinfo(name, null, &hints, &res)) != 0) return null;
    defer if (res) |r| c.freeaddrinfo(r);
    var it = res;
    while (it) |ai| : (it = ai.next) {
        const a = ai.addr orelse continue;
        if (a.family != posix.AF.INET) continue;
        const in: *const posix.sockaddr.in = @ptrCast(@alignCast(a));
        return @bitCast(in.addr);
    }
    return null;
}

// ------------------------------------------------------------ socket streams

/// `std.Io.Reader` over a socket, every read bounded by `deadline`. Feeds the TLS client.
pub const SocketReader = struct {
    fd: Fd,
    deadline: i64,
    interface: std.Io.Reader,
    err: ?Error = null,

    pub fn init(fd: Fd, deadline: i64, buffer: []u8) SocketReader {
        return .{
            .fd = fd,
            .deadline = deadline,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SocketReader = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = read(self.fd, dest, self.deadline) catch |e| {
            self.err = e;
            return if (e == error.ConnectionReset) error.EndOfStream else error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

/// `std.Io.Writer` over a socket, every write bounded by `deadline`.
pub const SocketWriter = struct {
    fd: Fd,
    deadline: i64,
    interface: std.Io.Writer,
    err: ?Error = null,

    pub fn init(fd: Fd, deadline: i64, buffer: []u8) SocketWriter {
        return .{
            .fd = fd,
            .deadline = deadline,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SocketWriter = @alignCast(@fieldParentPtr("interface", w));
        self.put(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.put(d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.put(last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }

    fn put(self: *SocketWriter, bytes: []const u8) Error!void {
        writeAll(self.fd, bytes, self.deadline) catch |e| {
            self.err = e;
            return e;
        };
    }
};

// ----------------------------------------------------------------------- tests

/// For tests that call into modules which use `sys`.
pub fn initForTests() void {
    init(std.testing.io, null);
}

test "portOpen and localIp do not crash" {
    initForTests();
    try std.testing.expect(!portOpen(.{ 127, 0, 0, 1 }, 1, 500));
    _ = localIp();
}
