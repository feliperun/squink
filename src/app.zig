//! The commands: resolve the printer and its queue, then print, report or manage jobs.
const std = @import("std");
const cli = @import("cli.zig");
const term = @import("term.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const discover = @import("discover.zig");
const cups = @import("cups.zig");
const ipp = @import("ipp.zig");
const sys = @import("sys.zig");

const Printer = discover.Printer;
const Opts = cli.Opts;
const Allocator = std.mem.Allocator;

pub const exit_ok: u8 = 0;
pub const exit_fail: u8 = 1;
pub const exit_timeout: u8 = 3;

pub fn run(gpa: Allocator, o: Opts) u8 {
    return switch (o.command) {
        .help => {
            term.write(std.Io.File.stdout(), "{s}", .{cli.helpFor(o.help_topic)});
            term.emitted = true; // help is text even with --json
            return exit_ok;
        },
        .version => {
            if (term.json) term.emit(.{ .ok = true, .version = cli.version }) else term.info("squink {s}\n", .{cli.version});
            return exit_ok;
        },
        .print => cmdPrint(gpa, o),
        .setup => cmdSetup(gpa, o),
        .status => cmdStatus(gpa, o),
        .jobs => cmdJobs(gpa, o),
        .cancel => cmdCancel(gpa, o),
        .discover => cmdDiscover(gpa, o),
        .options => cmdOptions(gpa, o),
    };
}

// ------------------------------------------------------------ JSON shapes

const PrinterOut = struct {
    name: []const u8,
    ip: []const u8,
    port: u16,
    uri: []const u8,
    model: []const u8,
    source: []const u8,
    reachable: ?bool = null,
};

fn printerOut(gpa: Allocator, p: Printer) PrinterOut {
    return .{
        .name = p.name,
        .ip = proc.ipString(gpa, p.ip),
        .port = p.port,
        .uri = p.uri(gpa),
        .model = p.model,
        .source = p.source,
    };
}

// ------------------------------------------------------ resolving the queue

const Resolved = struct {
    queue: []const u8,
    uri: []const u8,
    /// existing, created, repointed, would-create, would-repoint
    action: []const u8,
    driver: ?[]const u8 = null,
    printer: ?PrinterOut = null,
};

/// Finds the printer and makes sure a CUPS queue points at it. null = failed
/// (the reason went through term.fail).
fn resolve(gpa: Allocator, o: Opts) ?Resolved {
    var cfg = config.load(gpa);
    const saved_queue = o.queue orelse cfg.get("PRINTER_QUEUE");

    // 1. --ip wins.
    if (o.ip) |ip| return ensure(gpa, o, &cfg, saved_queue, .{ .name = "given", .ip = ip, .source = "--ip" });

    // 2. The queue exists and its printer answers: fast path, no discovery.
    var dead_uri: ?[]const u8 = null;
    if (saved_queue) |q| {
        if (cups.deviceUri(gpa, q)) |uri| {
            const t = cups.targetFromUri(uri) orelse {
                // Host by name (e.g. .local): CUPS resolves it, not us.
                return .{ .queue = q, .uri = uri, .action = "existing" };
            };
            if (discover.portOpen(t.ip, t.port, 3000)) {
                revive(gpa, o, q);
                return .{ .queue = q, .uri = uri, .action = "existing" };
            }
            term.info("queue {s} points to {s}, which does not answer. searching for the printer...\n", .{ q, uri });
            dead_uri = uri;
        }
    }

    // 3. The address saved in the config (possibly by an older tool).
    if (printerFromConfig(gpa, &cfg)) |p| {
        const same_as_dead = dead_uri != null and std.mem.eql(u8, dead_uri.?, p.uri(gpa));
        if (!same_as_dead and discover.reachable(p, 3000)) return ensure(gpa, o, &cfg, saved_queue, p);
    }

    if (o.no_discover) {
        term.fail("no reachable printer, and --no-discover forbids searching the network.\n" ++
            "  pass --ip <IP> (printers show it on their panel or network status page)", .{});
        return null;
    }

    const preferred = o.model orelse cfg.get("PRINTER_MODEL") orelse "";

    // 4. mDNS. It answers from a cache: only what answers on its port counts.
    term.info("searching via mDNS...\n", .{});
    if (pick(discover.mdns(gpa), preferred)) |p| return ensure(gpa, o, &cfg, saved_queue, p);

    // 5. Scan: last resort.
    term.info("scanning the local network (ports 631/9100, ~40 s)...\n", .{});
    if (pick(discover.scan(gpa), preferred)) |p| return ensure(gpa, o, &cfg, saved_queue, p);

    term.fail("no printer found on the network.\n" ++
        "  - check that it is on and on the same network (many printers only join 2.4 GHz Wi-Fi)\n" ++
        "  - or pass its address:  squink setup --ip <IP>{s}", .{sys.lanHint()});
    return null;
}

/// The printer matching the preferred model, else the first; only ones that answer now.
fn pick(list: []const Printer, preferred_model: []const u8) ?Printer {
    var first: ?Printer = null;
    for (list) |p| {
        if (!discover.reachable(p, 1500)) continue;
        if (p.matchesModel(preferred_model)) return p;
        if (first == null) first = p;
    }
    return first;
}

fn printerFromConfig(gpa: Allocator, cfg: *const config.Config) ?Printer {
    if (cfg.get("PRINTER_URI")) |uri| {
        if (cups.targetFromUri(uri)) |t| return .{
            .name = "saved",
            .ip = t.ip,
            .port = t.port,
            .scheme = if (t.socket) .socket else .ipp,
            .rp = t.rp,
            .model = cfg.get("PRINTER_MODEL") orelse "",
            .source = "config",
        };
    }
    // Written by print.py: IP and port only.
    const ip = proc.parseIp(cfg.get("PRINTER_IP") orelse return null) orelse return null;
    const port = std.fmt.parseInt(u16, cfg.get("PRINTER_PORT") orelse "631", 10) catch 631;
    _ = gpa;
    return .{
        .name = "saved",
        .ip = ip,
        .port = port,
        .scheme = if (port == 9100) .socket else .ipp,
        .rp = cfg.get("PRINTER_RP") orelse "ipp/print",
        .model = cfg.get("PRINTER_MODEL") orelse "",
        .source = "config",
    };
}

/// Points the queue at `found` (unless it already does) and saves it to the config.
fn ensure(gpa: Allocator, o: Opts, cfg: *config.Config, queue_opt: ?[]const u8, found: Printer) ?Resolved {
    var p = found;
    var ipb: [15]u8 = undefined;
    const ip = proc.formatIp(&ipb, p.ip);
    term.info("printer: {s} at {s}:{d} [{s}]\n", .{ p.name, ip, p.port, p.source });

    // Never touch CUPS unless the printer answers: no phantom queues.
    if (!discover.reachable(p, 3000)) {
        term.fail("printer unreachable: {s}:{d} does not answer.\n" ++
            "  check that it is on and on the same network, or pass the right --ip <IP>{s}", .{ ip, p.port, sys.lanHint() });
        return null;
    }
    if (o.model) |m| {
        p.model = m;
    } else if (p.model.len == 0) {
        p.model = discover.queryModel(gpa, p.ip, p.rp) orelse "";
    }
    if (p.model.len > 0) term.info("  model: {s}\n", .{p.model});

    const queue = queue_opt orelse cups.queueName(gpa, p.model);
    const uri = p.uri(gpa);
    const current = cups.deviceUri(gpa, queue);
    var out: Resolved = .{ .queue = queue, .uri = uri, .action = "existing", .printer = printerOut(gpa, p) };

    if (current != null and std.mem.eql(u8, current.?, uri) and o.driver == null) {
        revive(gpa, o, queue);
    } else {
        const driver = o.driver orelse sys.getenv("SQUINK_DRIVER") orelse cups.findDriver(gpa, p.model) orelse
            if (p.scheme == .ipp) "everywhere" else {
                term.fail("no driver found for \"{s}\", and driverless printing needs IPP (this is {s}).\n" ++
                    "  pass --model \"MAKE MODEL\" or --driver <first column of lpinfo -m>", .{ p.model, uri });
                return null;
            };
        if (std.mem.eql(u8, driver, "everywhere")) term.info("  no model-specific driver installed: using driverless IPP Everywhere\n", .{});
        out.driver = driver;
        if (o.dry_run) {
            out.action = if (current == null) "would-create" else "would-repoint";
            term.info("  would set queue {s} -> {s}\n  driver: {s}\n", .{ queue, uri, driver });
            return out;
        }
        const description = if (p.model.len > 0) p.model else "squink printer";
        if (cups.configureQueue(gpa, queue, uri, driver, description, current != null)) |msg| {
            term.fail("{s}", .{msg});
            return null;
        }
        out.action = if (current == null) "created" else "repointed";
        term.info("  queue {s} -> {s}\n  driver: {s}\n", .{ queue, uri, driver });
    }

    if (!o.dry_run) {
        var port_buf: [5]u8 = undefined;
        cfg.set(gpa, "PRINTER_QUEUE", queue) catch {};
        cfg.set(gpa, "PRINTER_URI", uri) catch {};
        cfg.set(gpa, "PRINTER_IP", ip) catch {};
        cfg.set(gpa, "PRINTER_PORT", std.fmt.bufPrint(&port_buf, "{d}", .{p.port}) catch "631") catch {};
        cfg.set(gpa, "PRINTER_RP", p.rp) catch {};
        if (p.model.len > 0) cfg.set(gpa, "PRINTER_MODEL", p.model) catch {};
        cfg.save(gpa) catch |e| term.warn("could not save {s}: {s}", .{ cfg.path, @errorName(e) });
    }
    return out;
}

/// CUPS stops a queue after a failed job and then just holds new ones. Undo that.
fn revive(gpa: Allocator, o: Opts, queue: []const u8) void {
    if (o.dry_run) return;
    const s = cups.queueState(gpa, queue) orelse return;
    if (!std.mem.eql(u8, s.state, "stopped") and s.accepting) return;
    term.info("queue {s} was stopped ({s}); re-enabling it\n", .{ queue, if (s.message.len > 0) s.message else "no message" });
    if (!cups.enableQueue(gpa, queue)) term.warn("could not re-enable {s}: try  cupsenable {s}", .{ queue, queue });
}

// ------------------------------------------------------------------- setup

fn cmdSetup(gpa: Allocator, o: Opts) u8 {
    const r = resolve(gpa, o) orelse return exit_fail;
    const state = if (o.dry_run) null else cups.queueState(gpa, r.queue);
    if (term.json) {
        term.emit(.{
            .ok = true,
            .command = "setup",
            .queue = r.queue,
            .uri = r.uri,
            .action = r.action,
            .driver = r.driver,
            .printer = r.printer,
            .queue_state = if (state) |s| s.state else null,
        });
    } else {
        if (std.mem.eql(u8, r.action, "existing")) term.info("queue {s} -> {s}\n", .{ r.queue, r.uri });
        if (state) |s| term.info("  state: {s}{s}\n", .{ s.state, if (s.accepting) ", accepting jobs" else ", NOT accepting jobs" });
        if (!o.dry_run) term.info("ready. try:  squink print --text \"hello\" --wait\n", .{});
    }
    return exit_ok;
}

// ------------------------------------------------------------------- print

fn cmdPrint(gpa: Allocator, o: Opts) u8 {
    // Prepare the input BEFORE touching CUPS: bad files, URLs or stdin fail early.
    var files: []const []const u8 = &.{};
    var stdin_data: ?[]const u8 = null;
    var name: []const u8 = "squink";
    var temp: ?[]const u8 = null;
    defer if (temp) |p| std.Io.Dir.cwd().deleteFile(sys.io, p) catch {};

    if (o.url) |url| {
        temp = download(gpa, url) orelse return exit_fail;
        files = gpa.dupe([]const u8, &.{temp.?}) catch return exit_fail;
        name = nameFromUrl(url);
    } else if (o.text) |t| {
        stdin_data = std.mem.concat(gpa, u8, &.{ t, "\n" }) catch return exit_fail;
        name = "text";
    } else if (o.files.len == 1 and std.mem.eql(u8, o.files[0], "-")) {
        stdin_data = readStdin(gpa) orelse return exit_fail;
        name = "stdin";
    } else {
        for (o.files) |f| {
            const st = std.Io.Dir.cwd().statFile(sys.io, f, .{}) catch {
                term.fail("file not found: {s}", .{f});
                return exit_fail;
            };
            if (st.kind != .file) {
                term.fail("not a regular file: {s}", .{f});
                return exit_fail;
            }
            if (st.size == 0) {
                term.fail("file is empty: {s}", .{f});
                return exit_fail;
            }
        }
        files = o.files;
        name = std.fs.path.basename(o.files[0]);
    }
    if (o.job_name) |n| name = n;

    const r = resolve(gpa, o) orelse return exit_fail;
    const argv = lpArgv(gpa, o, r.queue, name, files) catch return exit_fail;

    if (o.dry_run) {
        const cmdline = std.mem.join(gpa, " ", argv) catch "";
        if (term.json) {
            term.emit(.{ .ok = true, .command = "print", .dry_run = true, .queue = r.queue, .setup = r.action, .lp_argv = argv });
        } else {
            term.info("would run: {s}{s}\n", .{ cmdline, if (stdin_data != null) "  (data on stdin)" else "" });
        }
        return exit_ok;
    }

    const job_id = switch (cups.submit(gpa, argv, stdin_data)) {
        .ok => |id| id,
        .failed => |msg| {
            term.fail("CUPS rejected the job:\n  {s}", .{msg});
            return exit_fail;
        },
    };
    const number = cups.jobNumber(job_id);
    term.info("sent: {s}\n", .{job_id});

    var waited: ?Waited = null;
    if (o.wait) |secs| {
        if (number) |n| waited = waitJob(gpa, r.queue, n, secs) else term.warn("cannot follow job \"{s}\"", .{job_id});
    }

    const code: u8 = if (waited) |w| w.code else exit_ok;
    if (term.json) {
        term.emit(.{
            .ok = code == exit_ok,
            .command = "print",
            .job = job_id,
            .job_id = number,
            .queue = r.queue,
            .setup = r.action,
            .copies = o.copies,
            .name = name,
            .state = if (waited) |w| w.state else "sent",
            .message = if (waited) |w| w.message else null,
            .waited_s = if (waited) |w| w.elapsed_s else null,
            .@"error" = if (code != exit_ok) term.last_error else null,
            .exit_code = code,
        });
    }
    return code;
}

fn lpArgv(gpa: Allocator, o: Opts, queue: []const u8, name: []const u8, files: []const []const u8) ![]const []const u8 {
    var copies_buf: [3]u8 = undefined;
    const copies = try gpa.dupe(u8, try std.fmt.bufPrint(&copies_buf, "{d}", .{o.copies}));
    var a: std.ArrayList([]const u8) = .empty;
    try a.appendSlice(gpa, &.{ "lp", "-d", queue, "-n", copies, "-t", name });
    if (o.pages) |p| try a.appendSlice(gpa, &.{ "-P", p });

    // Generic IPP options first; driver-specific ones when the driver has them.
    const driver_opts = if (o.paper != null or o.mono or o.quality != null) cups.queueOptions(gpa, queue) else &.{};
    if (o.paper) |paper| {
        if (cups.findChoice(driver_opts, "PageSize", paper)) |c| {
            try opt(gpa, &a, "PageSize={s}", .{c});
        } else {
            try opt(gpa, &a, "media={s}", .{paper});
        }
    }
    if (o.mono) {
        try a.appendSlice(gpa, &.{ "-o", "print-color-mode=monochrome" });
        if (cups.findChoice(driver_opts, "Ink", "MONO")) |c| try opt(gpa, &a, "Ink={s}", .{c});
        for ([_][]const u8{ "Gray", "Grayscale", "Mono" }) |g| {
            if (cups.findChoice(driver_opts, "ColorModel", g)) |c| {
                try opt(gpa, &a, "ColorModel={s}", .{c});
                break;
            }
        }
    }
    if (o.quality) |q| {
        const ipp_value: u8 = switch (q) {
            .draft => 3,
            .normal => 4,
            .high => 5,
        };
        try opt(gpa, &a, "print-quality={d}", .{ipp_value});
        // Epson ESC/P-R expresses quality as a plain-paper media type.
        const media_type = switch (q) {
            .draft => "PLAIN_DRAFT",
            .normal => "PLAIN_NORMAL",
            .high => "PLAIN_HIGH",
        };
        if (cups.findChoice(driver_opts, "MediaType", media_type)) |c| try opt(gpa, &a, "MediaType={s}", .{c});
    }
    if (o.fit) try a.appendSlice(gpa, &.{ "-o", "fit-to-page" });
    if (o.landscape) try a.appendSlice(gpa, &.{ "-o", "landscape" });
    if (o.duplex) try a.appendSlice(gpa, &.{ "-o", "sides=two-sided-long-edge" });
    for (o.options) |kv| try a.appendSlice(gpa, &.{ "-o", kv });
    if (files.len > 0) {
        try a.append(gpa, "--");
        try a.appendSlice(gpa, files);
    }
    return a.items;
}

fn opt(gpa: Allocator, a: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
    try a.append(gpa, "-o");
    try a.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
}

const Waited = struct { code: u8, state: []const u8, message: []const u8, elapsed_s: i64 };

/// Follows a job until it leaves the queue or time runs out.
fn waitJob(gpa: Allocator, queue: []const u8, number: u32, timeout_s: u32) Waited {
    term.info("waiting for the job (up to {d} s)...\n", .{timeout_s});
    const start = sys.timestamp();
    var last_state: []const u8 = "";
    var last_message: []const u8 = "";
    var misses: u8 = 0;
    while (true) {
        const elapsed = sys.timestamp() - start;
        if (cups.job(gpa, queue, number)) |j| {
            misses = 0;
            if (!std.mem.eql(u8, j.state, last_state) or !std.mem.eql(u8, j.message, last_message)) {
                if (j.message.len > 0) term.info("  {s}: {s}\n", .{ j.state, j.message }) else term.info("  {s}\n", .{j.state});
                last_state = j.state;
                last_message = j.message;
            }
            const state: ipp.JobState = std.meta.stringToEnum(ipp.JobState, j.state) orelse .pending;
            if (state.isFinal()) {
                if (state == .completed) {
                    term.info("completed in {d} s\n", .{elapsed});
                    return .{ .code = exit_ok, .state = j.state, .message = j.message, .elapsed_s = elapsed };
                }
                term.fail("job {s}-{d} {s}{s}{s}", .{ queue, number, j.state, if (j.message.len > 0) ": " else "", j.message });
                return .{ .code = exit_fail, .state = j.state, .message = j.message, .elapsed_s = elapsed };
            }
        } else {
            misses += 1;
            if (misses >= 5) {
                term.fail("lost track of job {s}-{d}: CUPS does not answer", .{ queue, number });
                return .{ .code = exit_fail, .state = "unknown", .message = "", .elapsed_s = elapsed };
            }
        }
        if (elapsed >= timeout_s) {
            term.fail("job {s}-{d} still {s} after {d} s{s}{s}\n  follow it with: squink jobs   cancel it with: squink cancel {d}", .{
                queue, number, last_state, timeout_s, if (last_message.len > 0) ": " else "", last_message, number,
            });
            return .{ .code = exit_timeout, .state = last_state, .message = last_message, .elapsed_s = elapsed };
        }
        sys.sleepMs(1000);
    }
}

fn readStdin(gpa: Allocator) ?[]const u8 {
    const in = std.Io.File.stdin();
    if (in.isTty(sys.io) catch false) term.info("reading from the keyboard; finish with Ctrl+D\n", .{});
    var buf: [4096]u8 = undefined;
    var r = in.readerStreaming(sys.io, &buf);
    const data = r.interface.allocRemaining(gpa, .limited(64 << 20)) catch |e| {
        term.fail("reading stdin: {s}", .{@errorName(e)});
        return null;
    };
    if (std.mem.trim(u8, data, " \t\r\n").len == 0) {
        term.fail("stdin is empty: nothing to print", .{});
        return null;
    }
    return data;
}

/// Downloads with curl to a private temp file. Returns its path, or null.
fn download(gpa: Allocator, url: []const u8) ?[]const u8 {
    const tmpdir = sys.getenv("TMPDIR") orelse "/tmp";
    var rand: [8]u8 = undefined;
    sys.randomBytes(&rand);
    const path = std.fmt.allocPrint(gpa, "{s}/squink-url-{x}", .{ tmpdir, rand }) catch return null;
    const f = std.Io.Dir.cwd().createFile(sys.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |e| {
        term.fail("could not create {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    f.close(sys.io);

    term.info("downloading {s}\n", .{url});
    const r = proc.run(gpa, &.{ "curl", "-fsSL", "--proto", "=http,https", "--max-time", "60", "-o", path, "--", url });
    if (!r.ok()) {
        std.Io.Dir.cwd().deleteFile(sys.io, path) catch {};
        if (r.code == 127) term.fail("curl not found (install it: sudo apt-get install curl)", .{}) else term.fail("download failed: {s}", .{r.text(gpa)});
        return null;
    }
    return path;
}

/// Last path segment of a URL, without the query: a good job name.
fn nameFromUrl(url: []const u8) []const u8 {
    const no_scheme = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const path = no_scheme[std.mem.indexOfScalar(u8, no_scheme, '/') orelse return "url" ..];
    const no_query = path[0 .. std.mem.indexOfAny(u8, path, "?#") orelse path.len];
    const clean = std.mem.trimEnd(u8, no_query, "/");
    const last = clean[(std.mem.lastIndexOfScalar(u8, clean, '/') orelse return "url") + 1 ..];
    return if (last.len > 0) last else "url";
}

// ------------------------------------------------------------------ status

const Ink = struct { name: []const u8, level: ?i32, color: []const u8 };

fn cmdStatus(gpa: Allocator, o: Opts) u8 {
    const cfg = config.load(gpa);
    const queue = o.queue orelse cfg.get("PRINTER_QUEUE");
    const queue_uri = if (queue) |q| cups.deviceUri(gpa, q) else null;

    var target: ?cups.Target = null;
    if (o.ip) |ip| {
        target = .{ .ip = ip, .port = 631, .rp = "ipp/print", .socket = false };
    } else if (queue_uri) |u| {
        target = cups.targetFromUri(u);
    } else if (cfg.get("PRINTER_URI")) |u| {
        target = cups.targetFromUri(u);
    }
    if (queue_uri == null and target == null) {
        term.fail("no printer set up yet: run  squink setup", .{});
        return exit_fail;
    }

    const qstate = if (queue_uri != null) cups.queueState(gpa, queue.?) else null;

    var reachable = false;
    var model: []const u8 = cfg.get("PRINTER_MODEL") orelse "";
    var state: []const u8 = "unknown";
    var message: []const u8 = "";
    var alerts: std.ArrayList([]const u8) = .empty;
    var inks: std.ArrayList(Ink) = .empty;
    var ip_s: ?[]const u8 = null;

    if (target) |t| {
        ip_s = proc.ipString(gpa, t.ip);
        reachable = discover.portOpen(t.ip, t.port, 3000);
        // Ask over IPP even for socket:// queues: most printers also speak IPP on 631.
        const attrs = if (reachable) discover.printerAttributes(gpa, t.ip, 631, if (t.socket) "ipp/print" else t.rp, &.{
            "printer-make-and-model", "printer-state", "printer-state-reasons", "printer-state-message",
            "marker-names",           "marker-levels", "marker-colors",
        }) else null;
        if (attrs) |resp| if (resp.first(ipp.tag.printer_group)) |g| {
            if (g.str("printer-make-and-model")) |m| model = m;
            state = ipp.printerStateLabel(g.int("printer-state") orelse 0);
            message = g.str("printer-state-message") orelse "";
            if (g.get("printer-state-reasons")) |a| for (a.values.items) |reason| {
                if (!std.mem.eql(u8, reason, "none")) alerts.append(gpa, reason) catch {};
            };
            if (g.get("marker-names")) |names| {
                const levels = g.get("marker-levels");
                const colors = g.get("marker-colors");
                for (names.values.items, 0..) |n, i| {
                    const level = if (levels) |l| l.int(i) else null;
                    inks.append(gpa, .{
                        .name = n,
                        // negative levels mean unknown (-1, -2) or "some remaining" (-3)
                        .level = if (level) |v| (if (v >= 0) v else null) else null,
                        .color = if (colors) |c| (if (i < c.values.items.len) c.values.items[i] else "") else "",
                    }) catch {};
                }
            }
        };
    }

    var blocking_alert = false;
    for (alerts.items) |a| {
        if (!std.mem.endsWith(u8, a, "-report") and !std.mem.endsWith(u8, a, "-warning")) blocking_alert = true;
    }
    const queue_ok = if (qstate) |s| !std.mem.eql(u8, s.state, "stopped") and s.accepting else queue_uri == null;
    const ready = reachable and queue_ok and !blocking_alert;

    if (term.json) {
        term.emit(.{
            .ok = true,
            .command = "status",
            .ready = ready,
            .queue = if (queue_uri != null) .{
                .name = queue.?,
                .uri = queue_uri.?,
                .state = if (qstate) |s| s.state else "unknown",
                .accepting = if (qstate) |s| s.accepting else false,
                .jobs = if (qstate) |s| s.jobs else 0,
                .message = if (qstate) |s| s.message else "",
            } else null,
            .printer = .{
                .ip = ip_s,
                .reachable = reachable,
                .model = model,
                .state = state,
                .message = message,
                .alerts = alerts.items,
                .ink = inks.items,
            },
        });
    } else {
        if (queue_uri) |u| {
            if (qstate) |s| {
                term.info("queue:    {s} -> {s}\n          {s}, {s}, {d} job(s) waiting{s}{s}\n", .{
                    queue.?,                              u,         s.state, if (s.accepting) "accepting jobs" else "NOT accepting jobs", s.jobs,
                    if (s.message.len > 0) " - " else "", s.message,
                });
            } else term.info("queue:    {s} -> {s} (CUPS did not answer)\n", .{ queue.?, u });
        } else term.info("queue:    none yet (squink setup creates it)\n", .{});
        term.info("printer:  {s}{s}{s}\n", .{ if (model.len > 0) model else "unknown model", if (ip_s != null) " at " else "", ip_s orelse "" });
        if (!reachable) {
            term.info("          NOT REACHABLE (off, asleep, or on another network){s}\n", .{sys.lanHint()});
        } else {
            term.info("          {s}{s}{s}\n", .{ state, if (message.len > 0) " - " else "", message });
        }
        if (reachable) {
            if (alerts.items.len == 0) term.info("alerts:   none\n", .{});
            for (alerts.items, 0..) |a, i| term.info("{s}{s}\n", .{ if (i == 0) "alerts:   " else "          ", a });
            if (inks.items.len == 0) term.info("ink:      not reported by this printer\n", .{});
            for (inks.items, 0..) |k, i| {
                const head = if (i == 0) "ink:      " else "          ";
                if (k.level) |l| term.info("{s}{s:<12} {d:>3}% {s}\n", .{ head, k.name, l, bar(gpa, l) }) else term.info("{s}{s:<12} level unknown\n", .{ head, k.name });
            }
        }
        term.info("ready:    {s}\n", .{if (ready) "yes" else "NO"});
    }
    return if (ready) exit_ok else exit_fail;
}

fn bar(gpa: Allocator, level: i32) []const u8 {
    const filled: usize = @intCast(@divTrunc(@min(@max(level, 0), 100), 10));
    const s = gpa.alloc(u8, 10) catch return "";
    @memset(s[0..filled], '#');
    @memset(s[filled..], '.');
    return s;
}

// -------------------------------------------------------------- jobs, cancel

fn requireQueue(gpa: Allocator, o: Opts) ?[]const u8 {
    const cfg = config.load(gpa);
    const q = o.queue orelse cfg.get("PRINTER_QUEUE") orelse {
        term.fail("no printer set up yet: run  squink setup  (or pass --queue NAME)", .{});
        return null;
    };
    return q;
}

fn cmdJobs(gpa: Allocator, o: Opts) u8 {
    const queue = requireQueue(gpa, o) orelse return exit_fail;
    const which: cups.Which = if (o.all) .all else if (o.done) .completed else .pending;
    const list = cups.jobs(gpa, queue, which) orelse {
        term.fail("could not ask CUPS about queue {s} (does it exist? is cups running?)", .{queue});
        return exit_fail;
    };
    if (term.json) {
        term.emit(.{ .ok = true, .command = "jobs", .queue = queue, .which = @tagName(which), .jobs = list });
        return exit_ok;
    }
    if (list.len == 0) {
        term.info("no {s} jobs in {s}\n", .{ switch (which) {
            .pending => "pending",
            .completed => "finished",
            .all => "",
        }, queue });
        return exit_ok;
    }
    term.info("{s:<6} {s:<11} {s:<10} {s:<16} {s}\n", .{ "ID", "STATE", "USER", "CREATED", "NAME" });
    for (list) |j| {
        term.info("{d:<6} {s:<11} {s:<10} {s:<16} {s}\n", .{ j.id, j.state, j.user, when(gpa, j.created), j.name });
        if (j.message.len > 0 and !std.mem.eql(u8, j.state, "completed")) term.info("       {s}\n", .{j.message});
    }
    return exit_ok;
}

/// Unix time as local-ish "YYYY-MM-DD HH:MM" (UTC; no tz database in a static binary).
fn when(gpa: Allocator, t: i64) []const u8 {
    if (t <= 0) return "-";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(t) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(gpa, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "-";
}

fn cmdCancel(gpa: Allocator, o: Opts) u8 {
    const Failure = struct { job: []const u8, @"error": []const u8 };
    var done: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(Failure) = .empty;

    if (o.all) {
        const queue = requireQueue(gpa, o) orelse return exit_fail;
        const r = cups.cancel(gpa, queue, true);
        if (r.ok()) done.append(gpa, queue) catch {} else failed.append(gpa, .{ .job = queue, .@"error" = r.text(gpa) }) catch {};
    } else {
        for (o.targets) |t| {
            const r = cups.cancel(gpa, t, false);
            if (r.ok()) done.append(gpa, t) catch {} else failed.append(gpa, .{ .job = t, .@"error" = r.text(gpa) }) catch {};
        }
    }

    for (done.items) |d| term.info("canceled: {s}{s}\n", .{ d, if (o.all) " (all jobs)" else "" });
    for (failed.items) |f| term.fail("could not cancel {s}: {s}", .{ f.job, f.@"error" });
    const code = if (failed.items.len == 0) exit_ok else exit_fail;
    if (term.json) term.emit(.{ .ok = code == exit_ok, .command = "cancel", .canceled = done.items, .failed = failed.items });
    return code;
}

// ---------------------------------------------------------------- discover

fn cmdDiscover(gpa: Allocator, o: Opts) u8 {
    const queues = cups.allQueues(gpa);
    const cfg = config.load(gpa);

    var announced: std.ArrayList(PrinterOut) = .empty;
    var scanned: std.ArrayList(PrinterOut) = .empty;
    if (!o.no_discover) {
        for (discover.mdns(gpa)) |p| {
            var po = printerOut(gpa, p);
            po.reachable = discover.reachable(p, 1500);
            announced.append(gpa, po) catch {};
        }
        if (o.scan) {
            term.info("scanning the local network (ports 631/9100, ~40 s)...\n", .{});
            for (discover.scan(gpa)) |p| {
                var po = printerOut(gpa, p);
                po.model = discover.queryModel(gpa, p.ip, p.rp) orelse "";
                po.reachable = true;
                scanned.append(gpa, po) catch {};
            }
        }
    }

    if (term.json) {
        term.emit(.{
            .ok = true,
            .command = "discover",
            .queues = queues,
            .config = .{ .path = cfg.path, .read_from = cfg.read_from, .values = cfg.pairs.items },
            .mdns = if (o.no_discover) null else announced.items,
            .scan = if (o.scan and !o.no_discover) scanned.items else null,
        });
        return exit_ok;
    }

    term.info("=== CUPS queues ===\n", .{});
    if (queues.len == 0) term.info("  (none)\n", .{});
    for (queues) |q| term.info("  {s:<24} {s}\n", .{ q.name, q.uri });

    term.info("\n=== saved printer ===\n  file: {s}\n", .{cfg.path});
    if (cfg.read_from) |from| {
        if (!std.mem.eql(u8, from, cfg.path)) term.info("  (read from legacy {s})\n", .{from});
        for (cfg.pairs.items) |p| term.info("  {s}={s}\n", .{ p.key, p.value });
    } else term.info("  (none)\n", .{});

    if (o.no_discover) return exit_ok;
    term.info("\n=== mDNS ===\n", .{});
    if (announced.items.len == 0) term.info("  (nothing announcing a printer)\n", .{});
    for (announced.items) |p| {
        term.info("  {s:<28} {s:<16} {s}  [{s}]{s}\n", .{
            p.name, p.ip, p.model, p.source, if (p.reachable.?) "" else "  NOT ANSWERING (stale mDNS cache?)",
        });
    }
    if (sys.lan_blocked) term.info("{s}\n", .{sys.lanHint()});
    if (o.scan) {
        term.info("\n=== local network scan (631/9100) ===\n", .{});
        if (scanned.items.len == 0) term.info("  (no host with a printer port open)\n", .{});
        for (scanned.items) |p| term.info("  {s}:{d}  {s}\n", .{ p.ip, p.port, p.model });
    } else term.info("\n(add --scan to also scan the local network, ~40 s)\n", .{});
    return exit_ok;
}

// ----------------------------------------------------------------- options

fn cmdOptions(gpa: Allocator, o: Opts) u8 {
    const queue = requireQueue(gpa, o) orelse return exit_fail;
    const list = cups.queueOptions(gpa, queue);
    if (list.len == 0) {
        term.fail("queue {s} lists no driver options (does it exist? try: squink setup)", .{queue});
        return exit_fail;
    }
    if (term.json) {
        term.emit(.{ .ok = true, .command = "options", .queue = queue, .options = list });
        return exit_ok;
    }
    term.info("driver options of {s} (default marked *), use with: squink print -o NAME=VALUE\n\n", .{queue});
    for (list) |opt_| {
        term.info("{s} ({s}):\n ", .{ opt_.name, opt_.label });
        for (opt_.choices) |c| {
            const is_default = opt_.default != null and std.mem.eql(u8, opt_.default.?, c);
            term.info(" {s}{s}", .{ if (is_default) "*" else "", c });
        }
        term.info("\n", .{});
    }
    return exit_ok;
}

// ------------------------------------------------------------------- tests

test "nameFromUrl" {
    try std.testing.expectEqualStrings("photo.jpg", nameFromUrl("https://x.com/a/photo.jpg?w=1"));
    try std.testing.expectEqualStrings("url", nameFromUrl("https://x.com/"));
    try std.testing.expectEqualStrings("url", nameFromUrl("https://x.com"));
}

test "lpArgv maps options onto lp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const o: Opts = .{ .command = .print, .copies = 2, .pages = "1-3", .fit = true, .duplex = true, .options = &.{"Brightness=5"} };
    const argv = try lpArgv(gpa, o, "q", "doc", &.{"a.pdf"});
    const joined = try std.mem.join(gpa, " ", argv);
    try std.testing.expectEqualStrings(
        "lp -d q -n 2 -t doc -P 1-3 -o fit-to-page -o sides=two-sided-long-edge -o Brightness=5 -- a.pdf",
        joined,
    );
}

test "when formats unix time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-09-24 18:44Z", when(arena.allocator(), 1790275440));
    try std.testing.expectEqualStrings("-", when(arena.allocator(), 0));
}
