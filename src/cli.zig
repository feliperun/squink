//! Command-line parsing and help text.
const std = @import("std");
const proc = @import("proc.zig");

pub const version = "0.2.0";

pub const Command = enum { print, setup, status, jobs, cancel, discover, options, help, version };
pub const Quality = enum { draft, normal, high };

pub const Opts = struct {
    command: Command = .help,
    /// `squink <command> --help`
    help: bool = false,
    /// Command whose help to show (`squink help print`).
    help_topic: ?Command = null,

    // global
    json: bool = false,
    ip: ?[4]u8 = null,
    no_discover: bool = false,
    queue: ?[]const u8 = null,
    model: ?[]const u8 = null,
    driver: ?[]const u8 = null,
    dry_run: bool = false,

    // print
    files: []const []const u8 = &.{},
    url: ?[]const u8 = null,
    text: ?[]const u8 = null,
    copies: u8 = 1,
    job_name: ?[]const u8 = null,
    pages: ?[]const u8 = null,
    paper: ?[]const u8 = null,
    mono: bool = false,
    quality: ?Quality = null,
    fit: bool = false,
    landscape: bool = false,
    duplex: bool = false,
    options: []const []const u8 = &.{},
    /// Seconds to wait for the job to finish. null = do not wait.
    wait: ?u32 = null,

    // jobs / cancel / discover
    all: bool = false,
    done: bool = false,
    targets: []const []const u8 = &.{},
    scan: bool = false,
};

pub const default_wait_s = 300;

const Flag = struct {
    name: []const u8,
    value: bool = false,
    /// Commands that accept it. Empty = every command.
    only: []const Command = &.{},
};

const flags = [_]Flag{
    .{ .name = "--json" },
    .{ .name = "--ip", .value = true, .only = &.{ .print, .setup, .status } },
    .{ .name = "--no-discover", .only = &.{ .print, .setup, .discover } },
    .{ .name = "--queue", .value = true },
    .{ .name = "--model", .value = true, .only = &.{ .print, .setup } },
    .{ .name = "--driver", .value = true, .only = &.{ .print, .setup } },
    .{ .name = "--dry-run", .only = &.{ .print, .setup } },
    .{ .name = "--url", .value = true, .only = &.{.print} },
    .{ .name = "--text", .value = true, .only = &.{.print} },
    .{ .name = "--copies", .value = true, .only = &.{.print} },
    .{ .name = "--job-name", .value = true, .only = &.{.print} },
    .{ .name = "--pages", .value = true, .only = &.{.print} },
    .{ .name = "--paper", .value = true, .only = &.{.print} },
    .{ .name = "--mono", .only = &.{.print} },
    .{ .name = "--quality", .value = true, .only = &.{.print} },
    .{ .name = "--fit", .only = &.{.print} },
    .{ .name = "--landscape", .only = &.{.print} },
    .{ .name = "--duplex", .only = &.{.print} },
    .{ .name = "--option", .value = true, .only = &.{.print} },
    .{ .name = "-o", .value = true, .only = &.{.print} },
    .{ .name = "--wait", .only = &.{.print} }, // optional value: --wait=SECS
    .{ .name = "--all", .only = &.{ .jobs, .cancel } },
    .{ .name = "--done", .only = &.{.jobs} },
    .{ .name = "--scan", .only = &.{.discover} },
    .{ .name = "--help" },
    .{ .name = "-h" },
};

fn findFlag(name: []const u8) ?Flag {
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Flags of the old print.sh / printctl, mapped onto commands.
const Legacy = struct { flag: []const u8, command: Command, value: bool };
const legacy = [_]Legacy{
    .{ .flag = "--file", .command = .print, .value = true },
    .{ .flag = "--stdin", .command = .print, .value = false },
    .{ .flag = "--probe", .command = .setup, .value = false },
    .{ .flag = "--list", .command = .discover, .value = false },
    .{ .flag = "--version", .command = .version, .value = false },
};

pub fn parse(gpa: std.mem.Allocator, args: []const []const u8, err: *[]const u8) error{ Usage, OutOfMemory }!Opts {
    var o: Opts = .{};
    var command: ?Command = null;
    var positionals: std.ArrayList([]const u8) = .empty;
    var extra: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Legacy spellings: squink --file X, --stdin, --probe, --list, --version.
        if (legacyFor(arg)) |l| {
            if (command != null and command.? != l.command) return usage(err, "use one command at a time");
            command = l.command;
            if (std.mem.eql(u8, arg, "--stdin")) try positionals.append(gpa, "-");
            if (std.mem.eql(u8, arg, "--list")) o.scan = true;
            if (l.value) {
                i += 1;
                if (i >= args.len or args[i].len == 0) return usage(err, "--file needs a path");
                try positionals.append(gpa, args[i]);
            }
            continue;
        }

        if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (eq) |e| arg[0..e] else arg;
            const flag = findFlag(name) orelse
                return usage(err, try std.fmt.allocPrint(gpa, "unknown option {s}", .{name}));
            var value: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
            if (flag.value and value == null) {
                i += 1;
                if (i >= args.len) return usage(err, try std.fmt.allocPrint(gpa, "{s} needs a value", .{name}));
                value = args[i];
            }
            if (!flag.value and value != null and !std.mem.eql(u8, name, "--wait"))
                return usage(err, try std.fmt.allocPrint(gpa, "{s} takes no value", .{name}));
            try seen.append(gpa, name);
            try apply(gpa, &o, name, value, &extra, err);
            continue;
        }

        if (command == null) {
            if (std.meta.stringToEnum(Command, arg)) |c| {
                command = c;
                continue;
            }
            // `squink FILE` prints the file.
            command = .print;
        }
        try positionals.append(gpa, arg);
    }

    // `squink --text X` / `squink --url X`: legacy spellings of print.
    if (command == null and (o.url != null or o.text != null)) command = .print;
    o.command = command orelse .help;
    if (o.help) {
        o.help_topic = if (o.command == .help) null else o.command;
        o.command = .help;
        return o;
    }

    // Flags that do not belong to the command are mistakes, not no-ops.
    for (seen.items) |name| {
        const f = findFlag(name).?;
        if (f.only.len == 0) continue;
        if (std.mem.indexOfScalar(Command, f.only, o.command) == null)
            return usage(err, try std.fmt.allocPrint(gpa, "{s} does not apply to `{s}`", .{ name, @tagName(o.command) }));
    }

    switch (o.command) {
        .help => {
            if (positionals.items.len > 0) {
                o.help_topic = std.meta.stringToEnum(Command, positionals.items[0]) orelse
                    return usage(err, try std.fmt.allocPrint(gpa, "no such command: {s}", .{positionals.items[0]}));
            }
        },
        .print => {
            o.files = positionals.items;
            const sources = @as(u8, @intFromBool(o.files.len > 0)) + @intFromBool(o.url != null) + @intFromBool(o.text != null);
            if (sources == 0) return usage(err, "nothing to print: give files, - (stdin), --url or --text");
            if (sources > 1) return usage(err, "give only one of: files, --url, --text");
            for (o.files) |f| {
                if (std.mem.eql(u8, f, "-") and o.files.len > 1) return usage(err, "- (stdin) cannot be mixed with files");
                if (f.len == 0) return usage(err, "empty file name");
            }
        },
        .cancel => {
            o.targets = positionals.items;
            if (o.targets.len == 0 and !o.all) return usage(err, "cancel what? give job ids, or --all");
            if (o.targets.len > 0 and o.all) return usage(err, "give job ids or --all, not both");
        },
        else => if (positionals.items.len > 0)
            return usage(err, try std.fmt.allocPrint(gpa, "`{s}` takes no arguments (got {s})", .{ @tagName(o.command), positionals.items[0] })),
    }
    o.options = extra.items;
    return o;
}

fn legacyFor(arg: []const u8) ?Legacy {
    for (legacy) |l| {
        if (std.mem.eql(u8, arg, l.flag)) return l;
    }
    return null;
}

fn apply(
    gpa: std.mem.Allocator,
    o: *Opts,
    name: []const u8,
    value: ?[]const u8,
    extra: *std.ArrayList([]const u8),
    err: *[]const u8,
) error{ Usage, OutOfMemory }!void {
    const v = value orelse "";
    const eq = std.mem.eql;
    if (eq(u8, name, "--json")) {
        o.json = true;
    } else if (eq(u8, name, "--ip")) {
        o.ip = proc.parseIp(v) orelse return usage(err, "--ip needs an IPv4 address, e.g. 192.168.1.20");
    } else if (eq(u8, name, "--no-discover")) {
        o.no_discover = true;
    } else if (eq(u8, name, "--queue")) {
        if (v.len == 0) return usage(err, "--queue needs a name");
        o.queue = v;
    } else if (eq(u8, name, "--model")) {
        o.model = v;
    } else if (eq(u8, name, "--driver")) {
        o.driver = v;
    } else if (eq(u8, name, "--dry-run")) {
        o.dry_run = true;
    } else if (eq(u8, name, "--url")) {
        if (!std.mem.startsWith(u8, v, "http://") and !std.mem.startsWith(u8, v, "https://"))
            return usage(err, "--url must start with http:// or https://");
        o.url = v;
    } else if (eq(u8, name, "--text")) {
        if (v.len == 0) return usage(err, "--text is empty");
        o.text = v;
    } else if (eq(u8, name, "--copies")) {
        o.copies = std.fmt.parseInt(u8, v, 10) catch 0;
        if (o.copies < 1 or o.copies > 99) return usage(err, "--copies must be a number from 1 to 99");
    } else if (eq(u8, name, "--job-name")) {
        o.job_name = v;
    } else if (eq(u8, name, "--pages")) {
        if (!validPages(v)) return usage(err, "--pages takes ranges like 1-3,5");
        o.pages = v;
    } else if (eq(u8, name, "--paper")) {
        if (v.len == 0) return usage(err, "--paper needs a size, e.g. A4 or Letter");
        o.paper = v;
    } else if (eq(u8, name, "--mono")) {
        o.mono = true;
    } else if (eq(u8, name, "--quality")) {
        o.quality = std.meta.stringToEnum(Quality, v) orelse return usage(err, "--quality is draft, normal or high");
    } else if (eq(u8, name, "--fit")) {
        o.fit = true;
    } else if (eq(u8, name, "--landscape")) {
        o.landscape = true;
    } else if (eq(u8, name, "--duplex")) {
        o.duplex = true;
    } else if (eq(u8, name, "--option") or eq(u8, name, "-o")) {
        const e = std.mem.indexOfScalar(u8, v, '=') orelse return usage(err, "--option takes KEY=VALUE");
        if (e == 0) return usage(err, "--option takes KEY=VALUE");
        try extra.append(gpa, v);
    } else if (eq(u8, name, "--wait")) {
        o.wait = if (value) |s| (std.fmt.parseInt(u32, s, 10) catch
            return usage(err, "--wait=SECONDS takes a whole number")) else default_wait_s;
        if (o.wait.? == 0) return usage(err, "--wait=SECONDS must be at least 1");
    } else if (eq(u8, name, "--all")) {
        o.all = true;
    } else if (eq(u8, name, "--done")) {
        o.done = true;
    } else if (eq(u8, name, "--scan")) {
        o.scan = true;
    } else if (eq(u8, name, "--help") or eq(u8, name, "-h")) {
        o.help = true;
    }
}

/// "1-3,5,8-" style page ranges.
fn validPages(s: []const u8) bool {
    if (s.len == 0) return false;
    var parts = std.mem.splitScalar(u8, s, ',');
    while (parts.next()) |p| {
        if (p.len == 0) return false;
        var saw_digit = false;
        for (p, 0..) |c, i| {
            if (std.ascii.isDigit(c)) {
                saw_digit = true;
            } else if (c != '-' or i == 0) {
                return false;
            }
        }
        if (!saw_digit or std.mem.count(u8, p, "-") > 1) return false;
    }
    return true;
}

fn usage(err: *[]const u8, msg: []const u8) error{Usage} {
    err.* = msg;
    return error.Usage;
}

// ------------------------------------------------------------------------ help

pub const help_main =
    \\squink - print from the command line. Finds the printer, sets up CUPS, prints,
    \\and tells you when the paper actually came out.
    \\
    \\USAGE
    \\  squink <command> [options]
    \\  squink FILE...                  shorthand for: squink print FILE...
    \\
    \\COMMANDS
    \\  print      Print files, stdin, a URL or a text
    \\  setup      Find the printer and create or repoint its CUPS queue
    \\  status     Is the printer ready? State, alerts, ink levels, queue
    \\  jobs       List print jobs
    \\  cancel     Cancel print jobs
    \\  discover   Show queues, the saved printer and printers on the network
    \\  options    List the options of the printer's driver
    \\  help       Help for a command: squink help print
    \\  version    Print the version
    \\
    \\GLOBAL OPTIONS
    \\  --json          Print exactly one JSON object on stdout (progress goes to stderr)
    \\  --queue NAME    Use this CUPS queue instead of the saved one
    \\  -h, --help      Help (also after a command: squink print --help)
    \\
    \\EXIT CODES
    \\  0 success, 1 failure, 2 bad usage, 3 --wait timed out (job still in the queue)
    \\
    \\FIRST RUN
    \\  squink setup            find the printer and create the queue
    \\  squink status           check it is ready
    \\  squink print doc.pdf --wait
    \\
    \\Old flags still work: --file, --text, --url, --stdin, --probe (= setup), --list (= discover --scan).
    \\More: squink help <command>, and the README at https://github.com/feliperun/squink
    \\
;

pub const help_print =
    \\squink print - print files, stdin, a URL or a text
    \\
    \\USAGE
    \\  squink print FILE... [options]
    \\  squink print -              read stdin (plain text or any printable format)
    \\  squink print --url URL      download (curl, 60 s limit), print, delete
    \\  squink print --text TEXT    print TEXT as plain text
    \\
    \\  Files: PDF, JPEG, PNG, plain text; CUPS converts them. Several files make one job.
    \\  The first time, print runs `setup` by itself.
    \\
    \\OPTIONS
    \\  --copies N           1-99 copies (default 1)
    \\  --job-name NAME      title in the queue (default: file name, "text" or "stdin")
    \\  --pages RANGES       only these pages, e.g. 1-3,5
    \\  --paper SIZE         paper size, e.g. A4, Letter, A5, 4x6 (see `squink options`)
    \\  --mono               black and white
    \\  --quality Q          draft, normal or high
    \\  --fit                scale the document to fit the page
    \\  --landscape          rotate 90 degrees
    \\  --duplex             both sides (long edge), if the printer can
    \\  -o, --option K=V     any CUPS/driver option, repeatable (see `squink options`)
    \\  --wait[=SECONDS]     wait until the job leaves the queue (default 300 s) and
    \\                       exit 0 = printed, 1 = failed/canceled, 3 = still waiting
    \\  --dry-run            show what would run (the lp command); change nothing
    \\  --ip, --no-discover, --model, --driver: as in `squink setup`
    \\
    \\OUTPUT
    \\  "sent: epson-l3250-7" means CUPS accepted the job. Without --wait that is all you
    \\  know; use --wait, or `squink jobs`, to learn whether it printed.
    \\  JSON: {"ok":true,"job":"epson-l3250-7","job_id":7,"queue":...,"state":"completed",...}
    \\
    \\EXAMPLES
    \\  squink print invoice.pdf --wait
    \\  squink print photo.jpg --paper 4x6 --quality high --fit
    \\  squink print report.pdf --pages 1-2 --mono --copies 2
    \\  git log -5 | squink print - --job-name "git log"
    \\  squink print --text "Shopping list: milk, eggs" --json --wait
    \\
;

pub const help_setup =
    \\squink setup - find the printer and create or repoint its CUPS queue
    \\
    \\USAGE
    \\  squink setup [--ip IP] [--no-discover] [--model MODEL] [--driver PPD] [--queue NAME] [--dry-run]
    \\
    \\  Prints nothing on paper. Safe to run any time; when the queue already works it
    \\  returns in milliseconds. `print` runs it by itself when needed.
    \\
    \\HOW THE PRINTER IS FOUND (the first that answers on its port wins)
    \\  1. --ip
    \\  2. the existing queue (fast path: no network search)
    \\  3. the address saved in the config file
    \\  4. mDNS (avahi-browse: _ipp._tcp, _ipps._tcp, _pdl-datastream._tcp)
    \\  5. a gentle scan of the local /24 on ports 631 and 9100 (~40 s)
    \\  A queue is only created or changed after the printer answers.
    \\
    \\HOW THE DRIVER IS CHOSEN
    \\  1. --driver (any first column of `lpinfo -m`)
    \\  2. an installed driver whose description names the printer model (asked over IPP)
    \\  3. driverless IPP Everywhere
    \\  Some printers need the vendor driver: Epson ink-tank models (L3250...) fail
    \\  driverless; install printer-driver-escpr.
    \\
    \\OPTIONS
    \\  --ip IP          use the printer at this IPv4 address (repoints the queue)
    \\  --no-discover    never search the network
    \\  --model MODEL    make and model to pick the driver by, e.g. "EPSON L3250 Series"
    \\  --driver PPD     use this driver
    \\  --queue NAME     queue name (default: from the model, e.g. epson-l3250)
    \\  --dry-run        find the printer and the driver, create nothing
    \\
    \\Saved to ~/.config/squink/printer.env ($SQUINK_CONFIG overrides the path).
    \\
;

pub const help_status =
    \\squink status - is the printer ready?
    \\
    \\USAGE
    \\  squink status [--ip IP] [--queue NAME] [--json]
    \\
    \\  Asks CUPS about the queue and the printer itself (IPP) about its state, alerts
    \\  (paper out, jam, low ink...) and ink levels. Changes nothing.
    \\  Ink-tank printers (Epson EcoTank/L-series) cannot measure ink: "not reported".
    \\
    \\EXIT CODES
    \\  0 ready, 1 not ready (unreachable, stopped, or an error alert), 2 bad usage
    \\
;

pub const help_jobs =
    \\squink jobs - list print jobs
    \\
    \\USAGE
    \\  squink jobs [--done | --all] [--queue NAME] [--json]
    \\
    \\  Default: jobs still in the queue. --done: finished ones. --all: both.
    \\  States: pending, held, processing, stopped, canceled, aborted, completed.
    \\
;

pub const help_cancel =
    \\squink cancel - cancel print jobs
    \\
    \\USAGE
    \\  squink cancel JOB...        e.g. squink cancel 7  or  squink cancel epson-l3250-7
    \\  squink cancel --all         every job in the queue
    \\
;

pub const help_discover =
    \\squink discover - queues, the saved printer and printers on the network
    \\
    \\USAGE
    \\  squink discover [--scan] [--no-discover] [--json]
    \\
    \\  Shows CUPS queues, the saved config and printers announced over mDNS (each
    \\  checked on its port: avahi answers from a cache). --scan also scans the local
    \\  /24 on ports 631/9100 (~40 s). --no-discover: queues and config only.
    \\  Changes nothing.
    \\
;

pub const help_options =
    \\squink options - options of the printer's driver
    \\
    \\USAGE
    \\  squink options [--queue NAME] [--json]
    \\
    \\  Lists what the driver accepts (`lpoptions -l`), default marked with *. Use them
    \\  with `squink print -o NAME=VALUE`, e.g. -o MediaType=PMPHOTO_HIGH.
    \\
;

pub fn helpFor(topic: ?Command) []const u8 {
    const t = topic orelse return help_main;
    return switch (t) {
        .print => help_print,
        .setup => help_setup,
        .status => help_status,
        .jobs => help_jobs,
        .cancel => help_cancel,
        .discover => help_discover,
        .options => help_options,
        .help, .version => help_main,
    };
}

// ----------------------------------------------------------------------- tests

test "print: files, flags, --flag=value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var err: []const u8 = "";
    const o = try parse(arena.allocator(), &.{ "print", "a.pdf", "b.pdf", "--copies=2", "--pages", "1-3,5", "--mono", "--quality", "high", "-o", "MediaType=PLAIN_HIGH", "--wait=60", "--json" }, &err);
    try std.testing.expectEqual(Command.print, o.command);
    try std.testing.expectEqual(@as(usize, 2), o.files.len);
    try std.testing.expectEqual(@as(u8, 2), o.copies);
    try std.testing.expectEqualStrings("1-3,5", o.pages.?);
    try std.testing.expect(o.mono and o.json);
    try std.testing.expectEqual(Quality.high, o.quality.?);
    try std.testing.expectEqualStrings("MediaType=PLAIN_HIGH", o.options[0]);
    try std.testing.expectEqual(@as(u32, 60), o.wait.?);

    const w = try parse(arena.allocator(), &.{ "print", "x", "--wait" }, &err);
    try std.testing.expectEqual(@as(u32, default_wait_s), w.wait.?);
}

test "shorthands and legacy flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var err: []const u8 = "";

    const bare = try parse(gpa, &.{"doc.pdf"}, &err);
    try std.testing.expectEqual(Command.print, bare.command);
    try std.testing.expectEqualStrings("doc.pdf", bare.files[0]);

    const file = try parse(gpa, &.{ "--file", "doc.pdf", "--copies", "2", "--ip", "192.168.100.27", "--no-discover" }, &err);
    try std.testing.expectEqual(Command.print, file.command);
    try std.testing.expectEqualStrings("doc.pdf", file.files[0]);
    try std.testing.expectEqual([4]u8{ 192, 168, 100, 27 }, file.ip.?);

    try std.testing.expectEqualStrings("-", (try parse(gpa, &.{"--stdin"}, &err)).files[0]);
    try std.testing.expectEqual(Command.print, (try parse(gpa, &.{ "--text", "hi" }, &err)).command);
    try std.testing.expectEqual(Command.setup, (try parse(gpa, &.{"--probe"}, &err)).command);
    const list = try parse(gpa, &.{"--list"}, &err);
    try std.testing.expectEqual(Command.discover, list.command);
    try std.testing.expect(list.scan);
    try std.testing.expectEqual(Command.version, (try parse(gpa, &.{"--version"}, &err)).command);
    try std.testing.expectEqual(Command.help, (try parse(gpa, &.{}, &err)).command);

    const h = try parse(gpa, &.{ "print", "--help" }, &err);
    try std.testing.expectEqual(Command.help, h.command);
    try std.testing.expectEqual(Command.print, h.help_topic.?);
    try std.testing.expectEqual(Command.jobs, (try parse(gpa, &.{ "help", "jobs" }, &err)).help_topic.?);
}

test "usage errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var err: []const u8 = "";
    const bad = [_][]const []const u8{
        &.{"print"},
        &.{ "print", "a.pdf", "--text", "x" },
        &.{ "print", "-", "a.pdf" },
        &.{ "print", "a", "--copies", "0" },
        &.{ "print", "a", "--copies", "100" },
        &.{ "print", "a", "--quality", "ultra" },
        &.{ "print", "a", "--pages", "1-" ++ "-2" },
        &.{ "print", "a", "--pages", "abc" },
        &.{ "print", "a", "-o", "novalue" },
        &.{ "print", "--url", "ftp://x" },
        &.{ "print", "a", "--ip", "printer.local" },
        &.{ "print", "a", "--wait=abc" },
        &.{ "status", "--copies", "2" },
        &.{ "jobs", "extra" },
        &.{"cancel"},
        &.{ "cancel", "7", "--all" },
        &.{"--bogus"},
        &.{ "--probe", "--list" },
        &.{ "help", "nope" },
        &.{ "print", "a", "--mono=yes" },
    };
    for (bad) |args| {
        if (parse(gpa, args, &err)) |_| {
            std.debug.print("accepted: {any}\n", .{args});
            return error.TestExpectedError;
        } else |e| try std.testing.expectEqual(error.Usage, e);
    }
}

test "validPages" {
    try std.testing.expect(validPages("1"));
    try std.testing.expect(validPages("1-3,5,8-"));
    try std.testing.expect(!validPages(""));
    try std.testing.expect(!validPages("-3"));
    try std.testing.expect(!validPages("1,,2"));
    try std.testing.expect(!validPages("1-2-3"));
}
