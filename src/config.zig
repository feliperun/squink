//! Saved printer: a KEY=VALUE file, compatible with the older print.py / printctl.
//!
//! Path: $SQUINK_CONFIG, else $XDG_CONFIG_HOME/squink/printer.env, else
//! ~/.config/squink/printer.env. When it does not exist the legacy files
//! ~/.config/printctl/printer.env and ~/.config/ford/printer.env are read (never written).
//!
//! Keys: PRINTER_QUEUE, PRINTER_URI, PRINTER_MODEL, PRINTER_IP, PRINTER_PORT, PRINTER_RP.
const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Config = struct {
    path: []const u8,
    /// Where the values came from (may be a legacy file). null = nothing read.
    read_from: ?[]const u8 = null,
    pairs: std.ArrayList(Pair) = .empty,

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        for (self.pairs.items) |p| {
            if (std.mem.eql(u8, p.key, key)) return if (p.value.len > 0) p.value else null;
        }
        return null;
    }

    pub fn set(self: *Config, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.pairs.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                p.value = value;
                return;
            }
        }
        try self.pairs.append(gpa, .{ .key = key, .value = value });
    }

    pub fn save(self: *Config, gpa: std.mem.Allocator) !void {
        std.mem.sort(Pair, self.pairs.items, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);

        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(gpa, "# squink printer config. Written by squink; edit with care.\n");
        for (self.pairs.items) |p| try content.print(gpa, "{s}={s}\n", .{ p.key, p.value });

        if (std.fs.path.dirname(self.path)) |dir| try std.fs.cwd().makePath(dir);
        const f = try std.fs.cwd().createFile(self.path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(content.items);
        // createFile keeps the mode of a file that already existed.
        try f.chmod(0o600);
        self.read_from = self.path;
    }
};

pub fn load(gpa: std.mem.Allocator) Config {
    var cfg: Config = .{ .path = defaultPath(gpa) };
    var candidates: [3]?[]const u8 = .{ cfg.path, null, null };
    if (std.posix.getenv("SQUINK_CONFIG") == null) {
        if (std.posix.getenv("HOME")) |home| {
            candidates[1] = std.fs.path.join(gpa, &.{ home, ".config", "printctl", "printer.env" }) catch null;
            candidates[2] = std.fs.path.join(gpa, &.{ home, ".config", "ford", "printer.env" }) catch null;
        }
    }
    for (candidates) |c| {
        const path = c orelse continue;
        const data = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch continue;
        parse(gpa, &cfg, data) catch continue;
        cfg.read_from = path;
        break;
    }
    return cfg;
}

fn parse(gpa: std.mem.Allocator, cfg: *Config, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (parseLine(raw)) |p| try cfg.set(gpa, p.key, p.value);
    }
}

fn parseLine(raw: []const u8) ?Pair {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const value = std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "'\"");
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

fn defaultPath(gpa: std.mem.Allocator) []const u8 {
    if (std.posix.getenv("SQUINK_CONFIG")) |c| return c;
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "squink", "printer.env" }) catch x;
    }
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(gpa, &.{ home, ".config", "squink", "printer.env" }) catch "printer.env";
}

test "parseLine accepts the legacy printer.env format" {
    const p = parseLine("  PRINTER_IP = '192.168.100.27' \r").?;
    try std.testing.expectEqualStrings("PRINTER_IP", p.key);
    try std.testing.expectEqualStrings("192.168.100.27", p.value);
    try std.testing.expect(parseLine("# comment") == null);
    try std.testing.expect(parseLine("") == null);
    try std.testing.expect(parseLine("no equals") == null);
    try std.testing.expect(parseLine("=value") == null);
}

test "set overwrites and get ignores empty values" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{ .path = "x" };
    defer cfg.pairs.deinit(gpa);
    try parse(gpa, &cfg, "PRINTER_IP=1.2.3.4\nPRINTER_PORT=\nOTHER=kept\n");
    try cfg.set(gpa, "PRINTER_IP", "5.6.7.8");
    try std.testing.expectEqualStrings("5.6.7.8", cfg.get("PRINTER_IP").?);
    try std.testing.expect(cfg.get("PRINTER_PORT") == null);
    try std.testing.expectEqualStrings("kept", cfg.get("OTHER").?);
    try std.testing.expectEqual(@as(usize, 3), cfg.pairs.items.len);
}
