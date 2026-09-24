# squink 🦑

**Print from the command line, and know when the paper actually came out.**

squink is a small, dependency-free printing CLI for Linux and macOS, written in Zig. It
finds your printer on the network, sets up CUPS with the right driver, prints files,
URLs, text or stdin, and follows the job until it is done. Every command speaks
`--json` with stable exit codes, so scripts and AI agents can print without guessing.

```console
$ squink print invoice.pdf --wait
sent: epson-l3250-12
waiting for the job (up to 300 s)...
  processing: Connected to printer.
  processing: Waiting for job to complete.
  completed
completed in 11 s
```

- **One ~600 KB binary.** No Python, no runtime; on Linux fully static, without libc. Runs on a 2014 laptop, a Raspberry Pi or a Mac.
- **Zero-config setup.** Finds the printer (mDNS, then a gentle LAN scan), asks it for its model over IPP, picks the installed driver that matches, creates the queue. Only after the printer answers: no phantom queues.
- **`--wait`** follows the job in CUPS and exits `0` when it printed, `1` when it failed, `3` when it is still stuck.
- **`status`** asks the printer itself: ready or not, alerts (paper out, jam...), ink levels when the printer reports them.
- **Built-in IPP client**, including IPP over TLS for printers that refuse plain HTTP (Epson does).
- **Heals CUPS**: re-enables a queue CUPS stopped after a failed job, repoints the queue when the printer's IP changes.

## Install

Download a binary from the [releases](https://github.com/feliperun/squink/releases)
(Linux x86_64, aarch64, armv7, riscv64; macOS arm64 and x86_64), or build it (Zig 0.16):

```bash
git clone https://github.com/feliperun/squink && cd squink
zig build --release                           # this machine (Linux or macOS)
zig build --release -Dtarget=aarch64-linux    # or x86_64-linux, arm-linux-musleabihf, riscv64-linux,
                                              #    aarch64-macos, x86_64-macos
sudo install -m 755 zig-out/bin/squink /usr/local/bin/
```

squink drives CUPS, so the machine needs it.

**Linux:**

```bash
sudo apt-get install cups avahi-utils curl     # Debian/Ubuntu
sudo adduser $USER lpadmin                     # create queues without sudo (next login)
```

`avahi-utils` is optional (without it discovery goes straight to the scan) and `curl` is
only used by `print --url`. Some printers also need their vendor driver; see
[Printers](#printers).

**macOS:** CUPS, `ippfind` (mDNS) and `curl` come with the system, and admin accounts
are already in the `_lpadmin` group. Two things to know:

- macOS 15+ asks for **Local Network** permission before an app talks to devices on
  the LAN. Allow it for the terminal that runs squink (System Settings > Privacy &
  Security > Local Network). Without it every printer looks unreachable, and squink
  says so.
- A binary downloaded with a browser is quarantined: `xattr -d com.apple.quarantine squink`.

## Quick start

```bash
squink setup                 # find the printer, create the queue
squink status                # ready?
squink print report.pdf --wait
```

## Commands

| Command | What it does |
|---|---|
| `squink print FILE...` | Print files (PDF, JPEG, PNG, text). Several files make one job. |
| `squink print -` | Print stdin. |
| `squink print --url URL` | Download (curl, 60 s limit), print, delete. |
| `squink print --text TEXT` | Print a text. |
| `squink setup` | Find the printer, create or repoint its queue. Prints nothing. |
| `squink status` | Queue state, printer state, alerts, ink. Exit 0 = ready. |
| `squink jobs [--done\|--all]` | Jobs in the queue (or finished ones). |
| `squink cancel JOB... \| --all` | Cancel jobs. |
| `squink discover [--scan]` | Queues, the saved printer, printers on the network. |
| `squink options` | Options of the printer's driver, for `print -o`. |
| `squink help [COMMAND]` | Full help. Every command also takes `--help`. |

`squink FILE` is short for `squink print FILE`.

### Print options

| Option | Meaning |
|---|---|
| `--copies N` | 1-99 copies |
| `--job-name NAME` | Title in the queue |
| `--pages 1-3,5` | Page ranges |
| `--paper A4\|Letter\|4x6...` | Paper size (matched against the driver's sizes) |
| `--mono` | Black and white |
| `--quality draft\|normal\|high` | Print quality |
| `--fit` | Scale to fit the page |
| `--landscape` | Rotate 90° |
| `--duplex` | Both sides, long edge |
| `-o KEY=VALUE` | Any CUPS or driver option (repeatable; see `squink options`) |
| `--wait[=SECONDS]` | Follow the job until it leaves the queue (default 300 s) |
| `--dry-run` | Show the `lp` command; change nothing |

`--mono`, `--quality` and `--paper` set the standard IPP attributes **and** the driver's
own option when it has one. Epson's ESC/P-R driver, for instance, ignores
`print-color-mode` and wants `Ink=MONO`; squink sends both.

### Choosing the printer

`--ip IP` uses that address, `--queue NAME` a specific CUPS queue, `--model` and
`--driver` override the driver choice, `--no-discover` forbids searching the network.

## For scripts and agents

- `--json` prints **exactly one JSON object on stdout**, on success and on failure. Progress goes to stderr.
- Exit codes: `0` success, `1` failure, `2` bad usage, `3` `--wait` timed out.
- `sent` only means CUPS accepted the job. Use `--wait` to know it printed.

```console
$ squink print --text "hello" --wait --json
{"ok":true,"command":"print","job":"epson-l3250-13","job_id":13,"queue":"epson-l3250","setup":"existing","copies":1,"name":"text","state":"completed","message":"","waited_s":9,"error":null,"exit_code":0}

$ squink status --json
{"ok":true,"command":"status","ready":true,"queue":{"name":"epson-l3250","uri":"ipp://192.168.100.27:631/ipp/print","state":"idle","accepting":true,"jobs":0,"message":""},"printer":{"ip":"192.168.100.27","reachable":true,"model":"EPSON L3250 Series","state":"idle","message":"","alerts":[],"ink":[]}}

$ squink print missing.pdf --json
{"ok":false,"error":"file not found: missing.pdf","exit_code":1}
```

[AGENTS.md](AGENTS.md) is a one-page guide for AI agents, with the rules they should follow.

## How it works

**Finding the printer**, first that answers on its TCP port wins:

1. `--ip`
2. the existing CUPS queue (fast path: no network traffic beyond one connect)
3. the address saved in `~/.config/squink/printer.env`
4. mDNS (`_ipp._tcp`, `_ipps._tcp`, `_pdl-datastream._tcp`) via `avahi-browse` on Linux and `ippfind` on macOS, each result checked on its port, because mDNS answers from a cache
5. a scan of the local /24 on ports 631 and 9100, 16 connections at a time with jitter (~40 s). Cheap network stacks in printers fall over under aggressive scans.

**Choosing the driver:**

1. `--driver` (or `$SQUINK_DRIVER`)
2. an installed driver whose `lpinfo -m` description names the same vendor and model number. The model comes from mDNS or from asking the printer over IPP.
3. driverless IPP Everywhere

**The queue** is named after the model (`EPSON L3250 Series` becomes `epson-l3250`), created
with `lpadmin` only after the printer answered, and deleted again if `lpadmin` fails
halfway. When the printer moves to another address, the queue is repointed and the new
address saved.

## Printers

| Printer | Status | Notes |
|---|---|---|
| Epson L3250 (EcoTank) | Tested | Linux: needs `printer-driver-escpr`; driverless fails. No ink levels over IPP. |
| Any IPP Everywhere / AirPrint printer | Should work | Driverless, no extra packages. |
| Printers with a CUPS driver installed | Should work | The driver is picked from `lpinfo -m` by model. |

Tested another printer? A pull request adding a row is very welcome.

## Configuration

`~/.config/squink/printer.env` (or `$XDG_CONFIG_HOME/squink/`, or `$SQUINK_CONFIG`), mode
0600, written by squink:

```ini
PRINTER_QUEUE=epson-l3250
PRINTER_URI=ipp://192.168.100.27:631/ipp/print
PRINTER_MODEL=EPSON L3250 Series
PRINTER_IP=192.168.100.27
PRINTER_PORT=631
PRINTER_RP=ipp/print
```

| Variable | Effect |
|---|---|
| `SQUINK_CONFIG` | Config file path |
| `SQUINK_DRIVER` | Driver to use when creating a queue |
| `SQUINK_DEBUG=1` | Print IPP errors to stderr |

## Security notes

- Printer certificates are self-signed, so IPP-over-TLS connections to the printer are
  **not verified**. squink only reads status and model this way. The print data itself
  goes through CUPS.
- squink never asks for a password. Queue changes run directly (group `lpadmin`) or
  through `sudo -n`; if neither works, squink prints the one command to run by hand.
- Downloads (`--url`) go to a `0600` temp file that is deleted after the job is sent.

## Development

```bash
zig build test                       # unit tests (IPP codec, HTTP, parsers, CLI)
zig build --release && test/e2e.sh   # end to end against real CUPS with a fake printer
```

`test/e2e.sh` starts a TCP listener as the printer, lets squink create a queue for it and
checks print, `--wait` (completed and timeout), `jobs`, `cancel` and `--json`. It needs
CUPS and `lpadmin` permission, runs on Linux and macOS, and cleans up after itself.

Code map: `cli.zig` (flags and help), `app.zig` (commands), `ipp.zig` (IPP and HTTP/TLS),
`discover.zig` (mDNS, scan), `cups.zig` (queues, drivers, jobs), `config.zig`, `sys.zig`
(the `std.Io` instance, environment, clocks, sockets with deadlines).

## License

MIT. See [LICENSE](LICENSE).
