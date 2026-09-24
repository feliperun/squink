//! CUPS: queues, drivers, driver options, submitting and tracking jobs.
const std = @import("std");
const proc = @import("proc.zig");
const ipp = @import("ipp.zig");

// lpadmin/lpinfo live in /usr/sbin, outside a regular user's PATH.
const LP = "/usr/bin/lp";
const LPSTAT = "/usr/bin/lpstat";
const LPOPTIONS = "/usr/bin/lpoptions";
const CANCEL = "/usr/bin/cancel";
const LPADMIN = "/usr/sbin/lpadmin";
const LPINFO = "/usr/sbin/lpinfo";

// ------------------------------------------------------------------- queues

/// Device URI of a queue (`lpstat -v QUEUE`), or null when the queue does not exist.
pub fn deviceUri(gpa: std.mem.Allocator, queue: []const u8) ?[]const u8 {
    const r = proc.run(gpa, &.{ LPSTAT, "-v", queue });
    if (!r.ok()) return null;
    return parseLpstatV(r.stdout, queue);
}

/// "device for epson-l3250: ipp://192.168.100.27:631/ipp/print"
fn parseLpstatV(out: []const u8, queue: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const pos = std.mem.indexOf(u8, line, ": ") orelse continue;
        const head = line[0..pos];
        if (std.mem.endsWith(u8, head, queue) and std.mem.indexOf(u8, head, "for ") != null)
            return std.mem.trim(u8, line[pos + 2 ..], " \t\r");
    }
    return null;
}

pub const Target = struct { ip: [4]u8, port: u16, rp: []const u8, socket: bool };

/// Address of an ipp://, ipps:// or socket:// URI. null when the host is not a literal
/// IPv4 address (e.g. EPSON66C78E.local) or the scheme is something else.
pub fn targetFromUri(uri: []const u8) ?Target {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return null;
    const scheme = uri[0..sep];
    const socket = std.mem.eql(u8, scheme, "socket");
    if (!socket and !std.mem.eql(u8, scheme, "ipp") and !std.mem.eql(u8, scheme, "ipps")) return null;

    const rest = uri[sep + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, ":/?") orelse rest.len;
    const ip = proc.parseIp(rest[0..host_end]) orelse return null;
    var port: u16 = if (socket) 9100 else 631;
    var i = host_end;
    if (i < rest.len and rest[i] == ':') {
        const p = rest[i + 1 ..];
        const port_end = std.mem.indexOfAny(u8, p, "/?") orelse p.len;
        port = std.fmt.parseInt(u16, p[0..port_end], 10) catch return null;
        i += 1 + port_end;
    }
    const path = if (i < rest.len and rest[i] == '/') rest[i + 1 ..] else "";
    const rp = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
    return .{ .ip = ip, .port = port, .rp = if (rp.len > 0) rp else "ipp/print", .socket = socket };
}

/// Queue name from a model: "EPSON L3250 Series" -> "epson-l3250".
pub fn queueName(gpa: std.mem.Allocator, model: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, model, " \t");
    while (words.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, "series")) continue;
        for (w) |c| {
            const lc = std.ascii.toLower(c);
            if (std.ascii.isAlphanumeric(lc)) {
                out.append(gpa, lc) catch return "squink";
            } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
                out.append(gpa, '-') catch return "squink";
            }
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '-') out.append(gpa, '-') catch return "squink";
    }
    const name = std.mem.trim(u8, out.items, "-");
    return if (name.len > 0) name else "squink";
}

// ------------------------------------------------------------------- drivers

/// Best installed driver (PPD) for a make and model, from `lpinfo -m`. Skips
/// driverless entries: those are what `everywhere` already means.
///
/// Why not always driverless: some printers (the Epson L3250 among them) do not
/// announce every attribute IPP Everywhere requires, and lpadmin then fails with
/// "Printer does not support required IPP attributes or document formats".
pub fn findDriver(gpa: std.mem.Allocator, model: []const u8) ?[]const u8 {
    if (model.len == 0) return null;
    var r = proc.run(gpa, &.{ LPINFO, "-m" });
    if (!r.ok()) r = proc.runAdmin(gpa, &.{ LPINFO, "-m" });
    if (!r.ok()) return null;
    return pickDriver(r.stdout, model);
}

/// Picks the `lpinfo -m` line whose description names the same vendor and model
/// number. Prefers English PPDs.
fn pickDriver(lpinfo: []const u8, model: []const u8) ?[]const u8 {
    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, model, " \t,");
    const vendor = it.next() orelse return null;
    while (it.next()) |w| {
        if (n == words.len) break;
        if (std.ascii.eqlIgnoreCase(w, "series")) continue;
        // Model numbers are what identify a printer: keep the words with digits.
        if (std.mem.indexOfAny(u8, w, "0123456789") != null) {
            words[n] = w;
            n += 1;
        }
    }
    if (n == 0) return null;

    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, lpinfo, '\n');
    next_line: while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const ppd = line[0..space];
        if (std.mem.startsWith(u8, ppd, "driverless:") or std.mem.eql(u8, ppd, "everywhere")) continue;
        if (!vendorMatches(line, vendor)) continue;
        for (words[0..n]) |w| {
            if (!proc.containsWordIgnoreCase(line, w)) continue :next_line;
        }
        if (std.mem.indexOf(u8, ppd, "-en.ppd") != null) return ppd;
        if (best == null) best = ppd;
    }
    return best;
}

fn vendorMatches(line: []const u8, vendor: []const u8) bool {
    if (proc.containsIgnoreCase(line, vendor)) return true;
    return std.ascii.eqlIgnoreCase(vendor, "hp") and proc.containsIgnoreCase(line, "hewlett");
}

/// Creates the queue or repoints it (`lpadmin -p` edits in place). Returns an error
/// message, or null on success.
///
/// The caller MUST have checked that the printer answers: with a dead address CUPS
/// keeps a phantom queue in the *stopped* state.
pub fn configureQueue(
    gpa: std.mem.Allocator,
    queue: []const u8,
    uri: []const u8,
    driver: []const u8,
    description: []const u8,
    existed: bool,
) ?[]const u8 {
    const argv = [_][]const u8{
        LPADMIN, "-p", queue,       "-E", "-v", uri, "-m", driver, "-D", description,
        "-o",    "printer-is-shared=false",
    };
    const r = proc.runAdmin(gpa, &argv);
    if (r.ok()) return null;
    // lpadmin creates the queue before it validates the driver, and leaves it behind.
    if (!existed) _ = proc.runAdmin(gpa, &.{ LPADMIN, "-x", queue });

    const t = r.text(gpa);
    if (proc.sudoUnavailable(r, gpa)) {
        return std.fmt.allocPrint(gpa,
            \\no permission to create the queue (not in group lpadmin, no passwordless sudo).
            \\  run once:  sudo {s} -p {s} -E -v {s} -m {s}
            \\  or join the group:  sudo adduser $USER lpadmin
        , .{ LPADMIN, queue, uri, driver }) catch t;
    }
    if (std.mem.eql(u8, driver, "everywhere")) {
        return std.fmt.allocPrint(gpa,
            \\the printer does not support driverless printing and no matching driver is installed.
            \\  install the vendor driver (Epson: sudo apt-get install printer-driver-escpr),
            \\  or pass one from `lpinfo -m` with --driver.
            \\  (lpadmin: {s})
        , .{t}) catch t;
    }
    return std.fmt.allocPrint(gpa, "lpadmin failed: {s}", .{t}) catch t;
}

/// Re-enables a queue CUPS stopped (it does after a failed job) and makes it accept jobs.
pub fn enableQueue(gpa: std.mem.Allocator, queue: []const u8) bool {
    const a = proc.runAdmin(gpa, &.{ "/usr/sbin/cupsenable", queue });
    const b = proc.runAdmin(gpa, &.{ "/usr/sbin/cupsaccept", queue });
    return a.ok() and b.ok();
}

// ------------------------------------------------------------ driver options

pub const Option = struct {
    name: []const u8,
    label: []const u8,
    default: ?[]const u8,
    choices: []const []const u8,
};

/// Options of the queue's driver (`lpoptions -p QUEUE -l`).
pub fn queueOptions(gpa: std.mem.Allocator, queue: []const u8) []Option {
    const r = proc.run(gpa, &.{ LPOPTIONS, "-p", queue, "-l" });
    if (!r.ok()) return &.{};
    return parseLpoptions(gpa, r.stdout);
}

/// "Ink/Grayscale: *COLOR MONO" -> {Ink, Grayscale, COLOR, [COLOR, MONO]}
fn parseLpoptions(gpa: std.mem.Allocator, out: []const u8) []Option {
    var list: std.ArrayList(Option) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const head = line[0..colon];
        const slash = std.mem.indexOfScalar(u8, head, '/');
        var choices: std.ArrayList([]const u8) = .empty;
        var default: ?[]const u8 = null;
        var it = std.mem.tokenizeScalar(u8, line[colon + 2 ..], ' ');
        while (it.next()) |c| {
            const choice = if (c[0] == '*') c[1..] else c;
            if (c[0] == '*') default = choice;
            choices.append(gpa, choice) catch {};
        }
        list.append(gpa, .{
            .name = if (slash) |s| head[0..s] else head,
            .label = if (slash) |s| head[s + 1 ..] else head,
            .default = default,
            .choices = choices.items,
        }) catch {};
    }
    return list.items;
}

/// The option's own spelling of `choice` (case-insensitive), if the driver has it.
pub fn findChoice(options: []const Option, name: []const u8, choice: []const u8) ?[]const u8 {
    for (options) |o| {
        if (!std.ascii.eqlIgnoreCase(o.name, name)) continue;
        for (o.choices) |c| {
            if (std.ascii.eqlIgnoreCase(c, choice)) return c;
        }
    }
    return null;
}

// ---------------------------------------------------------------------- jobs

pub const Submitted = union(enum) { ok: []const u8, failed: []const u8 };

/// Runs `lp`. Returns the job id ("epson-l3250-7") or the error text.
pub fn submit(gpa: std.mem.Allocator, argv: []const []const u8, stdin_data: ?[]const u8) Submitted {
    const r = proc.runInput(gpa, argv, stdin_data);
    const t = r.text(gpa);
    if (!r.ok()) return .{ .failed = t };
    return .{ .ok = parseRequestId(t) orelse t };
}

/// "request id is epson-l3250-7 (1 file(s))" -> "epson-l3250-7"
fn parseRequestId(line: []const u8) ?[]const u8 {
    const marker = "request id is ";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    return rest[0 .. std.mem.indexOfAny(u8, rest, " \n") orelse rest.len];
}

/// "epson-l3250-7" -> 7. A bare "7" works too.
pub fn jobNumber(id: []const u8) ?u32 {
    const dash = std.mem.lastIndexOfScalar(u8, id, '-');
    const digits = if (dash) |d| id[d + 1 ..] else id;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

pub const JobInfo = struct {
    id: u32,
    job: []const u8,
    name: []const u8,
    state: []const u8,
    user: []const u8,
    /// Unix time the job was created.
    created: i64,
    /// Latest message from the printer backend ("Connecting to printer.", ...).
    message: []const u8,
};

const job_attrs = [_][]const u8{
    "job-id",                    "job-name",                 "job-state", "job-originating-user-name",
    "time-at-creation",          "job-printer-state-message", "job-state-reasons",
};

fn jobFromGroup(gpa: std.mem.Allocator, queue: []const u8, g: *const ipp.Group) JobInfo {
    const id: u32 = @intCast(@max(0, g.int("job-id") orelse 0));
    const state: ipp.JobState = @enumFromInt(g.int("job-state") orelse 0);
    return .{
        .id = id,
        .job = std.fmt.allocPrint(gpa, "{s}-{d}", .{ queue, id }) catch "",
        .name = g.str("job-name") orelse "",
        .state = state.label(),
        .user = g.str("job-originating-user-name") orelse "",
        .created = g.int("time-at-creation") orelse 0,
        .message = g.str("job-printer-state-message") orelse "",
    };
}

/// One job, asked from CUPS over IPP. null when CUPS does not answer or knows no such job.
pub fn job(gpa: std.mem.Allocator, queue: []const u8, number: u32) ?JobInfo {
    const job_uri = std.fmt.allocPrint(gpa, "ipp://localhost/jobs/{d}", .{number}) catch return null;
    var req = ipp.Request.init(gpa, ipp.op.get_job_attributes) catch return null;
    req.add(ipp.tag.uri, "job-uri", job_uri) catch return null;
    req.add(ipp.tag.name, "requesting-user-name", ipp.userName()) catch return null;
    req.addKeywords("requested-attributes", &job_attrs) catch return null;
    const resp = ipp.cups(gpa, req.finish() catch return null) catch return null;
    if (!resp.ok()) return null;
    const g = resp.first(ipp.tag.job_group) orelse return null;
    return jobFromGroup(gpa, queue, g);
}

pub const Which = enum { pending, completed, all };

/// Jobs of a queue, asked from CUPS over IPP.
pub fn jobs(gpa: std.mem.Allocator, queue: []const u8, which: Which) ?[]JobInfo {
    const printer_uri = std.fmt.allocPrint(gpa, "ipp://localhost/printers/{s}", .{queue}) catch return null;
    var req = ipp.Request.init(gpa, ipp.op.get_jobs) catch return null;
    req.add(ipp.tag.uri, "printer-uri", printer_uri) catch return null;
    req.add(ipp.tag.name, "requesting-user-name", ipp.userName()) catch return null;
    req.add(ipp.tag.keyword, "which-jobs", switch (which) {
        .pending => "not-completed",
        .completed => "completed",
        .all => "all",
    }) catch return null;
    req.addKeywords("requested-attributes", &job_attrs) catch return null;
    const resp = ipp.cups(gpa, req.finish() catch return null) catch return null;
    if (!resp.ok() and resp.status != 0x0406) return null; // 0x0406 = not-found: no jobs

    var list: std.ArrayList(JobInfo) = .empty;
    for (resp.groups.items) |*g| {
        if (g.group_tag == ipp.tag.job_group) list.append(gpa, jobFromGroup(gpa, queue, g)) catch {};
    }
    return list.items;
}

pub fn cancel(gpa: std.mem.Allocator, target: []const u8, all_of_queue: bool) proc.Result {
    const argv: []const []const u8 = if (all_of_queue) &.{ CANCEL, "-a", target } else &.{ CANCEL, target };
    return proc.runAdmin(gpa, argv);
}

pub const QueueState = struct {
    state: []const u8,
    accepting: bool,
    message: []const u8,
    reasons: []const []const u8,
    jobs: i32,
};

/// State of a CUPS queue over IPP.
pub fn queueState(gpa: std.mem.Allocator, queue: []const u8) ?QueueState {
    const printer_uri = std.fmt.allocPrint(gpa, "ipp://localhost/printers/{s}", .{queue}) catch return null;
    var req = ipp.Request.init(gpa, ipp.op.get_printer_attributes) catch return null;
    req.add(ipp.tag.uri, "printer-uri", printer_uri) catch return null;
    req.add(ipp.tag.name, "requesting-user-name", ipp.userName()) catch return null;
    req.addKeywords("requested-attributes", &.{
        "printer-state", "printer-is-accepting-jobs", "printer-state-message", "printer-state-reasons", "queued-job-count",
    }) catch return null;
    const resp = ipp.cups(gpa, req.finish() catch return null) catch return null;
    if (!resp.ok()) return null;
    const g = resp.first(ipp.tag.printer_group) orelse return null;
    return .{
        .state = ipp.printerStateLabel(g.int("printer-state") orelse 0),
        .accepting = g.boolean("printer-is-accepting-jobs") orelse false,
        .message = g.str("printer-state-message") orelse "",
        .reasons = if (g.get("printer-state-reasons")) |a| a.values.items else &.{},
        .jobs = g.int("queued-job-count") orelse 0,
    };
}

/// All queues with their device URIs, for `discover`.
pub const QueueEntry = struct { name: []const u8, uri: []const u8 };

pub fn allQueues(gpa: std.mem.Allocator) []QueueEntry {
    var list: std.ArrayList(QueueEntry) = .empty;
    const r = proc.run(gpa, &.{ LPSTAT, "-v" });
    if (!r.ok()) return &.{};
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        const prefix = "device for ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        list.append(gpa, .{ .name = line[prefix.len..colon], .uri = std.mem.trim(u8, line[colon + 2 ..], " \r") }) catch {};
    }
    return list.items;
}

// ---------------------------------------------------------------------- tests

test "parseLpstatV" {
    const s = "device for epson-l3250: ipp://192.168.100.27:631/ipp/print\n";
    try std.testing.expectEqualStrings("ipp://192.168.100.27:631/ipp/print", parseLpstatV(s, "epson-l3250").?);
    try std.testing.expect(parseLpstatV("device for other: socket://1.2.3.4\n", "epson-l3250") == null);
}

test "targetFromUri" {
    const a = targetFromUri("ipp://192.168.100.27:631/ipp/print").?;
    try std.testing.expectEqual([4]u8{ 192, 168, 100, 27 }, a.ip);
    try std.testing.expectEqual(@as(u16, 631), a.port);
    try std.testing.expectEqualStrings("ipp/print", a.rp);
    try std.testing.expect(targetFromUri("socket://10.0.0.9").?.socket);
    try std.testing.expectEqual(@as(u16, 9100), targetFromUri("socket://10.0.0.9").?.port);
    try std.testing.expectEqualStrings("printers/x", targetFromUri("ipps://10.0.0.9/printers/x?w=1").?.rp);
    try std.testing.expect(targetFromUri("ipp://EPSON66C78E.local:631/ipp/print") == null);
    try std.testing.expect(targetFromUri("usb://EPSON/L3250") == null);
}

test "queueName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("epson-l3250", queueName(gpa, "EPSON L3250 Series"));
    try std.testing.expectEqualStrings("hp-laserjet-pro-m404n", queueName(gpa, "HP LaserJet Pro M404n"));
    try std.testing.expectEqualStrings("brother-hl-l2350dw", queueName(gpa, "Brother HL-L2350DW series"));
    try std.testing.expectEqualStrings("squink", queueName(gpa, ""));
}

test "pickDriver finds the vendor driver and does not confuse models" {
    const lpinfo =
        \\drv:///sample.drv/generic.ppd Generic PostScript Printer
        \\driverless:ipps://EPSON%20L3250%20Series._ipps._tcp.local/ EPSON L3250 Series, driverless, cups-filters 1.28.17
        \\escpr:0/cups/model/epson-inkjet-printer-escpr/Epson-L32500_Series-epson-escpr-en.ppd EPSON L32500 Series
        \\escpr:0/cups/model/epson-inkjet-printer-escpr/Epson-L3250_Series-epson-escpr-en.ppd EPSON L3250 Series, Epson Inkjet Printer Driver (ESC/P-R) for Linux
        \\escpr:0/cups/model/epson-inkjet-printer-escpr/Epson-L3150_Series-epson-escpr-en.ppd EPSON L3150 Series
        \\drv:///hpcups.drv/hp-laserjet_pro_m404-m405.ppd HP LaserJet Pro M404-M405, hpcups 3.22.10
    ;
    try std.testing.expectEqualStrings(
        "escpr:0/cups/model/epson-inkjet-printer-escpr/Epson-L3250_Series-epson-escpr-en.ppd",
        pickDriver(lpinfo, "EPSON L3250 Series").?,
    );
    try std.testing.expectEqualStrings("drv:///hpcups.drv/hp-laserjet_pro_m404-m405.ppd", pickDriver(lpinfo, "HP M404").?);
    try std.testing.expect(pickDriver(lpinfo, "EPSON L4260 Series") == null);
    try std.testing.expect(pickDriver(lpinfo, "Canon L3250") == null);
    try std.testing.expect(pickDriver(lpinfo, "") == null);
}

test "parseLpoptions and findChoice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out =
        \\MediaType/Print Quality: PLAIN_HIGH *PLAIN_NORMAL PMPHOTO_DRAFT
        \\Ink/Grayscale: *COLOR MONO
        \\PageSize/Media Size: *A4 Letter Legal
    ;
    const opts = parseLpoptions(arena.allocator(), out);
    try std.testing.expectEqual(@as(usize, 3), opts.len);
    try std.testing.expectEqualStrings("Ink", opts[1].name);
    try std.testing.expectEqualStrings("Grayscale", opts[1].label);
    try std.testing.expectEqualStrings("COLOR", opts[1].default.?);
    try std.testing.expectEqualStrings("MONO", findChoice(opts, "ink", "mono").?);
    try std.testing.expectEqualStrings("Letter", findChoice(opts, "PageSize", "letter").?);
    try std.testing.expect(findChoice(opts, "PageSize", "A3") == null);
}

test "parseRequestId and jobNumber" {
    try std.testing.expectEqualStrings("epson-l3250-7", parseRequestId("request id is epson-l3250-7 (1 file(s))").?);
    try std.testing.expectEqual(@as(u32, 7), jobNumber("epson-l3250-7").?);
    try std.testing.expectEqual(@as(u32, 12), jobNumber("12").?);
    try std.testing.expect(jobNumber("epson-l3250") == null);
}
