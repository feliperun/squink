//! Running external commands (CUPS tools, avahi-browse, curl) and small text helpers.
const std = @import("std");

pub const Result = struct {
    /// Exit status. 127 = command not found, 128 = killed by a signal.
    code: u8,
    stdout: []const u8,
    stderr: []const u8,

    pub fn ok(self: Result) bool {
        return self.code == 0;
    }

    /// stdout and stderr joined and trimmed. Good for error messages.
    pub fn text(self: Result, gpa: std.mem.Allocator) []const u8 {
        const joined = std.mem.concat(gpa, u8, &.{ self.stdout, self.stderr }) catch return self.stderr;
        return std.mem.trim(u8, joined, " \t\r\n");
    }
};

/// Runs a command and collects its output. Never fails: spawn errors become exit codes.
pub fn run(gpa: std.mem.Allocator, argv: []const []const u8) Result {
    return runInput(gpa, argv, null);
}

/// Like `run`, but writes `input` to the command's stdin (e.g. text for `lp`).
pub fn runInput(gpa: std.mem.Allocator, argv: []const []const u8, input: ?[]const u8) Result {
    var child = std.process.Child.init(argv, gpa);
    child.stdin_behavior = if (input != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |e| return spawnFailure(argv, e);

    if (input) |data| {
        // The commands we feed (lp) answer with a line or two, so writing everything
        // before reading cannot fill the output pipe and deadlock.
        child.stdin.?.writeAll(data) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }

    var out: std.ArrayList(u8) = .empty;
    var err: std.ArrayList(u8) = .empty;
    child.collectOutput(gpa, &out, &err, 16 << 20) catch {};
    const term = child.wait() catch |e| return spawnFailure(argv, e);
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 128,
    };
    return .{ .code = code, .stdout = out.items, .stderr = err.items };
}

fn spawnFailure(argv: []const []const u8, e: anyerror) Result {
    return .{
        .code = if (e == error.FileNotFound) 127 else 126,
        .stdout = "",
        .stderr = if (e == error.FileNotFound) argv[0] else @errorName(e),
    };
}

/// CUPS administration. Runs directly first (members of group `lpadmin` may), and
/// only when CUPS refuses retries with `sudo -n`. Never prompts for a password.
pub fn runAdmin(gpa: std.mem.Allocator, argv: []const []const u8) Result {
    const direct = run(gpa, argv);
    if (direct.ok() or std.os.linux.geteuid() == 0) return direct;

    const t = direct.text(gpa);
    const denied = containsIgnoreCase(t, "forbidden") or containsIgnoreCase(t, "not authorized") or
        containsIgnoreCase(t, "permission");
    if (!denied) return direct;

    const with_sudo = std.mem.concat(gpa, []const u8, &.{ &.{ "sudo", "-n" }, argv }) catch return direct;
    return run(gpa, with_sudo);
}

/// Did sudo refuse because it needs a password (or is missing)?
pub fn sudoUnavailable(r: Result, gpa: std.mem.Allocator) bool {
    const t = r.text(gpa);
    return containsIgnoreCase(t, "password is required") or containsIgnoreCase(t, "a terminal is required") or
        (r.code == 127 and std.mem.eql(u8, r.stderr, "sudo"));
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// `needle` appears in `haystack` as a whole word: not glued to letters or digits,
/// so "L3250" matches "Epson-L3250_Series" but not "L32500".
pub fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(haystack[i - 1]);
        const end = i + needle.len;
        const after_ok = end == haystack.len or !std.ascii.isAlphanumeric(haystack[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

pub fn formatIp(buf: *[15]u8, ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
}

pub fn ipString(gpa: std.mem.Allocator, ip: [4]u8) []const u8 {
    var buf: [15]u8 = undefined;
    return gpa.dupe(u8, formatIp(&buf, ip)) catch "";
}

pub fn parseIp(s: []const u8) ?[4]u8 {
    const a = std.net.Ip4Address.parse(s, 0) catch return null;
    return @bitCast(a.sa.addr);
}

test "parseIp and formatIp round-trip" {
    const ip = parseIp("192.168.100.27").?;
    try std.testing.expectEqual([4]u8{ 192, 168, 100, 27 }, ip);
    var buf: [15]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.100.27", formatIp(&buf, ip));
    try std.testing.expect(parseIp("EPSON66C78E.local") == null);
    try std.testing.expect(parseIp("192.168.100") == null);
}

test "containsWordIgnoreCase respects word boundaries" {
    try std.testing.expect(containsWordIgnoreCase("Epson-L3250_Series-epson-escpr-en.ppd", "l3250"));
    try std.testing.expect(containsWordIgnoreCase("EPSON L3250 Series", "L3250"));
    try std.testing.expect(!containsWordIgnoreCase("EPSON L32500 Series", "L3250"));
    try std.testing.expect(!containsWordIgnoreCase("EPSON XL3250", "L3250"));
    try std.testing.expect(!containsWordIgnoreCase("abc", ""));
}
