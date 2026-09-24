//! Finding printers on the network: mDNS (avahi-browse on Linux, ippfind on macOS),
//! a gentle /24 scan, and an IPP query that tells the make and model of an address.
const std = @import("std");
const sys = @import("sys.zig");
const proc = @import("proc.zig");
const ipp = @import("ipp.zig");

pub const Scheme = enum { ipp, socket };

pub const Printer = struct {
    name: []const u8,
    ip: [4]u8,
    port: u16 = 631,
    scheme: Scheme = .ipp,
    /// IPP resource path, without the leading slash.
    rp: []const u8 = "ipp/print",
    /// Make and model ("EPSON L3250 Series"). Empty when unknown.
    model: []const u8 = "",
    /// Where it came from: --ip, config, mdns:_ipp._tcp, scan.
    source: []const u8,

    pub fn uri(self: Printer, gpa: std.mem.Allocator) []const u8 {
        var b: [15]u8 = undefined;
        const ip = proc.formatIp(&b, self.ip);
        return switch (self.scheme) {
            .ipp => std.fmt.allocPrint(gpa, "ipp://{s}:{d}/{s}", .{ ip, self.port, self.rp }),
            .socket => std.fmt.allocPrint(gpa, "socket://{s}:{d}", .{ ip, self.port }),
        } catch "";
    }

    pub fn matchesModel(self: Printer, model: []const u8) bool {
        return model.len > 0 and self.model.len > 0 and std.ascii.eqlIgnoreCase(self.model, model);
    }
};

/// TCP connect with a timeout. Closes right away; sends nothing.
pub fn portOpen(ip: [4]u8, port: u16, timeout_ms: i32) bool {
    return sys.portOpen(ip, port, timeout_ms);
}

pub fn reachable(p: Printer, timeout_ms: i32) bool {
    return portOpen(p.ip, p.port, timeout_ms);
}

/// Asks the printer itself (IPP on port 631) for its make and model.
pub fn queryModel(gpa: std.mem.Allocator, ip: [4]u8, rp: []const u8) ?[]const u8 {
    const attrs = printerAttributes(gpa, ip, 631, rp, &.{"printer-make-and-model"}) orelse return null;
    const g = attrs.first(ipp.tag.printer_group) orelse return null;
    const model = g.str("printer-make-and-model") orelse return null;
    return if (model.len > 0) model else null;
}

/// Get-Printer-Attributes straight to the device.
pub fn printerAttributes(
    gpa: std.mem.Allocator,
    ip: [4]u8,
    port: u16,
    rp: []const u8,
    wanted: []const []const u8,
) ?ipp.Response {
    var b: [15]u8 = undefined;
    const ip_s = proc.formatIp(&b, ip);
    const printer_uri = std.fmt.allocPrint(gpa, "ipp://{s}:{d}/{s}", .{ ip_s, port, rp }) catch return null;
    const host = std.fmt.allocPrint(gpa, "{s}:{d}", .{ ip_s, port }) catch return null;
    const path = std.fmt.allocPrint(gpa, "/{s}", .{rp}) catch return null;

    var req = ipp.Request.init(gpa, ipp.op.get_printer_attributes) catch return null;
    req.add(ipp.tag.uri, "printer-uri", printer_uri) catch return null;
    req.add(ipp.tag.name, "requesting-user-name", ipp.userName()) catch return null;
    req.addKeywords("requested-attributes", wanted) catch return null;
    const body = req.finish() catch return null;

    const resp = ipp.call(gpa, .{ .tcp = .{ .ip = ip, .port = port } }, host, path, body, 4000) catch |e| {
        debug("IPP to {s}{s}: {s}", .{ host, path, @errorName(e) });
        return null;
    };
    if (!resp.ok()) debug("IPP to {s}{s}: status 0x{x:0>4}", .{ host, path, resp.status });
    return if (resp.ok()) resp else null;
}

/// Diagnostics for SQUINK_DEBUG=1.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (sys.getenv("SQUINK_DEBUG") == null) return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(sys.io, &buf);
    w.interface.print("debug: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

// ------------------------------------------------------------------------ mDNS

/// Service types, in order of preference. The first announcement of each address
/// wins, so IPP (what the queue uses) beats raw port 9100.
const mdns_types = [_][]const u8{ "_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp" };

/// Printers announced over mDNS, one per address. Empty without avahi-browse
/// (Linux) or ippfind (macOS).
///
/// WARNING: avahi-daemon answers from its cache, so a printer that just left the
/// network keeps showing up here. Check the port before trusting a result.
pub fn mdns(gpa: std.mem.Allocator) []Printer {
    if (sys.is_darwin) return mdnsIppfind(gpa);
    var found: std.ArrayList(Printer) = .empty;
    for (mdns_types) |t| {
        // -k keeps raw service types (_ipp._tcp); without it avahi prints "Internet Printer".
        const r = proc.run(gpa, &.{ "timeout", "20", "avahi-browse", "-rtpk", t });
        if (r.code == 127) break; // no `timeout` or no avahi-browse
        if (!r.ok()) continue;
        var lines = std.mem.splitScalar(u8, r.stdout, '\n');
        while (lines.next()) |line| {
            const p = parseAvahi(gpa, line) orelse continue;
            if (indexByIp(found.items, p.ip) == null) found.append(gpa, p) catch {};
        }
    }
    return found.items;
}

/// Field separator in ippfind's output: a byte that no printer name contains.
const us = "\x1f";

/// macOS: `ippfind` (ships with the system's CUPS) browses all types at once and
/// stops by itself; the system resolver turns the `.local` host into an address.
fn mdnsIppfind(gpa: std.mem.Allocator) []Printer {
    const r = proc.run(gpa, &.{
        "/usr/bin/ippfind",                                                                                               "-T", "5", "_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp", "-x", "/bin/echo",
        "{service_port}" ++ us ++ "{service_name}" ++ us ++ "{service_hostname}" ++ us ++ "{txt_rp}" ++ us ++ "{txt_ty}", ";",
    });
    if (!r.ok()) return &.{};

    var found: std.ArrayList(Printer) = .empty;
    // One pass per type, in order of preference, as on Linux.
    for (mdns_types) |t| {
        var lines = std.mem.splitScalar(u8, r.stdout, '\n');
        while (lines.next()) |line| {
            const f = parseIppfind(line) orelse continue;
            if (!std.mem.eql(u8, f.service, t)) continue;
            const ip = proc.parseIp(f.host) orelse sys.resolveIp4(gpa, f.host) orelse continue;
            if (indexByIp(found.items, ip) != null) continue;
            var p: Printer = .{
                .name = f.name,
                .ip = ip,
                .port = f.port,
                .model = f.ty,
                .source = std.fmt.allocPrint(gpa, "mdns:{s}", .{t}) catch "mdns",
            };
            if (std.mem.eql(u8, t, "_pdl-datastream._tcp")) {
                p.scheme = .socket;
            } else {
                p.rp = std.mem.trim(u8, f.rp, "/");
                if (p.rp.len == 0) p.rp = "ipp/print";
            }
            found.append(gpa, p) catch {};
        }
    }
    return found.items;
}

const IppfindLine = struct { service: []const u8, port: u16, name: []const u8, host: []const u8, rp: []const u8, ty: []const u8 };

/// PORT US NAME US HOST US RP US TY. ippfind's {service_regtype} does not exist and
/// its {service_scheme} says "lpd" for 9100, so the type comes from port and TXT.
fn parseIppfind(raw: []const u8) ?IppfindLine {
    const line = std.mem.trimStart(u8, std.mem.trim(u8, raw, "\r"), "=");
    var it = std.mem.splitSequence(u8, line, us);
    const port = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    const name = it.next() orelse return null;
    const host = std.mem.trimEnd(u8, it.next() orelse return null, ".");
    const rp = it.next() orelse return null;
    const ty = it.next() orelse return null;
    if (host.len == 0) return null;
    const service = if (port == 9100) "_pdl-datastream._tcp" else if (rp.len > 0 or port == 631) "_ipp._tcp" else return null;
    return .{ .service = service, .port = port, .name = name, .host = host, .rp = rp, .ty = ty };
}

fn indexByIp(list: []const Printer, ip: [4]u8) ?usize {
    for (list, 0..) |p, i| {
        if (std.mem.eql(u8, &p.ip, &ip)) return i;
    }
    return null;
}

/// One resolved line of `avahi-browse -rtpk`:
/// =;iface;IPv4;name;type;domain;host;address;port;"txt" "txt" ...
fn parseAvahi(gpa: std.mem.Allocator, line: []const u8) ?Printer {
    if (line.len == 0 or line[0] != '=') return null;
    var fields: [10][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, ';');
    for (&fields) |*f| f.* = it.next() orelse return null;
    // TXT records may contain ';': take the rest of the line.
    const txt = line[fields[9].ptr - line.ptr ..];

    if (!std.mem.eql(u8, fields[2], "IPv4")) return null; // link-local IPv6 is no use to CUPS here
    const ip = proc.parseIp(fields[7]) orelse return null;
    const port = std.fmt.parseInt(u16, fields[8], 10) catch return null;
    const service = fields[4];

    var p: Printer = .{
        .name = unescape(gpa, fields[3]),
        .ip = ip,
        .port = port,
        .model = txtValue(txt, "ty") orelse "",
        .source = std.fmt.allocPrint(gpa, "mdns:{s}", .{service}) catch "mdns",
    };
    if (std.mem.eql(u8, service, "_pdl-datastream._tcp")) {
        p.scheme = .socket;
    } else {
        // _ipps is the same port 631; the queue uses ipp:// and CUPS upgrades to TLS if needed.
        if (txtValue(txt, "rp")) |rp| p.rp = std.mem.trim(u8, rp, "/");
        if (p.rp.len == 0) p.rp = "ipp/print";
    }
    return p;
}

/// Value of `"key=value"` in an avahi TXT field.
fn txtValue(txt: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, txt, i, '"')) |q| {
        const end = std.mem.indexOfScalarPos(u8, txt, q + 1, '"') orelse return null;
        const item = txt[q + 1 .. end];
        if (item.len > key.len and std.mem.startsWith(u8, item, key) and item[key.len] == '=')
            return item[key.len + 1 ..];
        i = end + 1;
    }
    return null;
}

/// avahi escapes names like `EPSON\032L3250` (decimal). Undo that.
fn unescape(gpa: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 4 <= s.len and std.ascii.isDigit(s[i + 1]) and std.ascii.isDigit(s[i + 2]) and
            std.ascii.isDigit(s[i + 3]))
        {
            out.append(gpa, std.fmt.parseInt(u8, s[i + 1 .. i + 4], 10) catch '?') catch return s;
            i += 4;
        } else if (s[i] == '\\' and i + 1 < s.len) {
            out.append(gpa, s[i + 1]) catch return s;
            i += 2;
        } else {
            out.append(gpa, s[i]) catch return s;
            i += 1;
        }
    }
    return out.items;
}

// ------------------------------------------------------------------------ scan

/// Deliberately LOW concurrency: an Epson L3250 dropped off Wi-Fi right after a scan
/// with ~100 threads. 16 connections with jitter cover a /24 in about 40 s.
const workers = 16;
const scan_ports = [_]u16{ 631, 9100 };

const Scan = struct {
    base: [3]u8,
    next: std.atomic.Value(u16) = .init(1),
    /// found[h] = port that answered on host .h (0 = none).
    found: [255]u16 = @splat(0),

    fn work(self: *Scan) void {
        var seed: [8]u8 = undefined;
        sys.randomBytes(&seed);
        var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
        while (true) {
            const h = self.next.fetchAdd(1, .monotonic);
            if (h > 254) return;
            sys.sleepMs(prng.random().uintLessThan(u64, 250));
            const ip = [4]u8{ self.base[0], self.base[1], self.base[2], @intCast(h) };
            for (scan_ports) |port| {
                if (portOpen(ip, port, 1200)) {
                    self.found[h] = port;
                    break;
                }
            }
        }
    }
};

/// Hosts on the local /24 (this machine's default-route address) with a printer port open.
pub fn scan(gpa: std.mem.Allocator) []Printer {
    const me = sys.localIp() orelse return &.{};
    var s: Scan = .{ .base = me[0..3].* };

    var threads: [workers]?std.Thread = @splat(null);
    for (&threads) |*t| t.* = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Scan.work, .{&s}) catch null;
    if (threads[0] == null) s.work(); // no threads at all: scan inline
    for (threads) |t| if (t) |th| th.join();

    var found: std.ArrayList(Printer) = .empty;
    for (s.found, 0..) |port, h| {
        if (port == 0 or h == me[3]) continue;
        found.append(gpa, .{
            .name = std.fmt.allocPrint(gpa, "host-{d}", .{h}) catch "host",
            .ip = .{ me[0], me[1], me[2], @intCast(h) },
            .port = port,
            .scheme = if (port == 631) .ipp else .socket,
            .source = "scan",
        }) catch {};
    }
    return found.items;
}

// ----------------------------------------------------------------------- tests

test "parseAvahi reads the line announced by an L3250" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const line =
        \\=;wlp3s0;IPv4;EPSON\032L3250\032Series;_ipp._tcp;local;EPSON66C78E.local;192.168.100.27;631;"txtvers=1" "rp=ipp/print" "ty=EPSON L3250 Series" "note=a;b"
    ;
    const p = parseAvahi(gpa, line).?;
    try std.testing.expectEqualStrings("EPSON L3250 Series", p.name);
    try std.testing.expectEqualStrings("EPSON L3250 Series", p.model);
    try std.testing.expectEqualStrings("mdns:_ipp._tcp", p.source);
    try std.testing.expectEqual([4]u8{ 192, 168, 100, 27 }, p.ip);
    try std.testing.expectEqualStrings("ipp://192.168.100.27:631/ipp/print", p.uri(gpa));
}

test "parseAvahi: 9100 becomes socket, IPv6 and unresolved lines are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const pdl = parseAvahi(gpa, "=;wlan0;IPv4;EPSON;_pdl-datastream._tcp;local;E.local;10.0.0.9;9100;\"ty=EPSON L3250\"").?;
    try std.testing.expectEqualStrings("socket://10.0.0.9:9100", pdl.uri(gpa));
    try std.testing.expect(parseAvahi(gpa, "=;wlan0;IPv6;EPSON;_ipp._tcp;local;E.local;fe80::1;631;\"\"") == null);
    try std.testing.expect(parseAvahi(gpa, "+;wlan0;IPv4;EPSON;_ipp._tcp;local") == null);
    try std.testing.expect(parseAvahi(gpa, "") == null);
}

test "parseIppfind reads the lines macOS prints for an L3250" {
    const ipp_line = parseIppfind("631" ++ us ++ "EPSON L3250 Series" ++ us ++ "EPSON66C78E.local." ++ us ++ "ipp/print" ++ us ++ "EPSON L3250 Series").?;
    try std.testing.expectEqualStrings("_ipp._tcp", ipp_line.service);
    try std.testing.expectEqualStrings("EPSON66C78E.local", ipp_line.host);
    try std.testing.expectEqualStrings("ipp/print", ipp_line.rp);
    try std.testing.expectEqualStrings("EPSON L3250 Series", ipp_line.ty);
    const raw = parseIppfind("=9100" ++ us ++ "EPSON" ++ us ++ "E.local" ++ us ++ "" ++ us ++ "EPSON L3250").?;
    try std.testing.expectEqualStrings("_pdl-datastream._tcp", raw.service);
    try std.testing.expectEqual(@as(u16, 9100), raw.port);
    try std.testing.expect(parseIppfind("") == null);
    try std.testing.expect(parseIppfind("abc" ++ us ++ "x") == null);
}

test "portOpen sees a local listener and not a closed port" {
    sys.initForTests();
    const io = sys.io;
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var srv = try addr.listen(io, .{});
    const port = srv.socket.address.getPort();
    try std.testing.expect(portOpen(.{ 127, 0, 0, 1 }, port, 500));
    srv.deinit(io);
    try std.testing.expect(!portOpen(.{ 127, 0, 0, 1 }, port, 500));
}
