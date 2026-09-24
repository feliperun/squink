//! squink - command-line printing through CUPS. See `squink --help`.
const std = @import("std");
const cli = @import("cli.zig");
const term = @import("term.zig");
const app = @import("app.zig");
const sys = @import("sys.zig");

pub fn main(init: std.process.Init) u8 {
    // One short-lived process: everything goes in the arena, freed at exit.
    const gpa = init.arena.allocator();
    term.arena = gpa;
    sys.init(init.io, init.environ_map);

    const args = init.minimal.args.toSlice(gpa) catch return 1;
    const wants_json = for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--json")) break true;
    } else false;

    var err: []const u8 = "";
    const o = cli.parse(gpa, args[1..], &err) catch |e| {
        if (e == error.OutOfMemory) return 1;
        if (wants_json) {
            term.json = true;
            term.emit(.{ .ok = false, .@"error" = err, .exit_code = 2 });
        } else {
            term.write(std.Io.File.stderr(), "ERROR: {s}\n  see: squink --help\n", .{err});
        }
        return 2;
    };
    term.json = o.json;

    const code = app.run(gpa, o);
    // Every --json run ends with one object on stdout, failures included.
    if (term.json and !term.emitted) term.emit(.{ .ok = code == 0, .@"error" = term.last_error, .exit_code = code });
    return code;
}

test {
    std.testing.refAllDecls(@This());
    _ = sys;
    _ = @import("proc.zig");
    _ = @import("config.zig");
    _ = @import("ipp.zig");
    _ = @import("discover.zig");
    _ = @import("cups.zig");
    _ = cli;
    _ = app;
}
