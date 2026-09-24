//! Terminal output. In `--json` mode stdout carries exactly one JSON document and
//! all progress text moves to stderr, so agents can parse stdout blindly.
const std = @import("std");

pub var json = false;
pub var arena: std.mem.Allocator = undefined;
/// Last message passed to `fail`, reported as `"error"` in JSON mode.
pub var last_error: ?[]const u8 = null;
/// Set once a JSON document has been written to stdout.
pub var emitted = false;

/// Progress for humans: stdout normally, stderr in JSON mode.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    write(if (json) std.fs.File.stderr() else std.fs.File.stdout(), fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write(std.fs.File.stderr(), "warning: " ++ fmt ++ "\n", args);
}

/// Records an error. Printed as `ERROR: ...` on stderr, or carried in the JSON result.
pub fn fail(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(arena, fmt, args) catch "error";
    last_error = msg;
    if (!json) write(std.fs.File.stderr(), "ERROR: {s}\n", .{msg});
}

/// Writes `value` as one line of JSON on stdout.
pub fn emit(value: anytype) void {
    emitted = true;
    write(std.fs.File.stdout(), "{f}\n", .{std.json.fmt(value, .{})});
}

pub fn write(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = f.writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}
