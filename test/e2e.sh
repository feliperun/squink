#!/usr/bin/env bash
# End-to-end test WITHOUT a physical printer.
#
# Starts a fake printer (a TCP listener on 127.0.0.1:9100 that keeps the bytes), lets
# squink create the queue from a config file, and checks: print --wait reaches
# "completed", the bytes arrive, a held job times out with exit 3, jobs lists it,
# cancel removes it, and --json output parses.
#
# The queue uses CUPS's generic PPD: this proves squink and the CUPS pipeline, not
# any printer's dialect.
#
# Needs: CUPS running, python3 (listener and JSON checks only), permission to run
# lpadmin (group lpadmin or passwordless sudo; on macOS, group _lpadmin). Runs on
# Linux and macOS. Cleans up after itself.
#
# Usage: test/e2e.sh [path/to/squink]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-${DIR}/zig-out/bin/squink}"
QUEUE="squink-selftest"
PORT=9100
TMP="$(mktemp -d "${TMPDIR:-/tmp}/squink-e2e.XXXXXX")"
RECEIVED="${TMP}/received.bin"
LISTENER_PID=""
STEP=0

cleanup() {
  /usr/bin/cancel -a "${QUEUE}" 2>/dev/null || true
  /usr/sbin/lpadmin -x "${QUEUE}" 2>/dev/null || sudo -n /usr/sbin/lpadmin -x "${QUEUE}" 2>/dev/null || true
  if [[ -n "${LISTENER_PID}" ]]; then kill "${LISTENER_PID}" 2>/dev/null; wait "${LISTENER_PID}" 2>/dev/null; fi || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

step() { STEP=$((STEP + 1)); echo; echo "${STEP}. $*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
json_get() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }

[[ -x "${BIN}" ]] || fail "binary not found: ${BIN} (run: zig build --release)"

step "fake printer on 127.0.0.1:${PORT}"
# Accepts several connections: squink opens one just to check the port.
python3 - "${PORT}" "${RECEIVED}" <<'PY' &
import socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
s.settimeout(180)
with open(out, "ab") as f:
    while True:
        try:
            c, _ = s.accept()
        except socket.timeout:
            break
        c.settimeout(30)
        while True:
            try:
                d = c.recv(65536)
            except socket.timeout:
                break
            if not d:
                break
            f.write(d)
            f.flush()
        c.close()
PY
LISTENER_PID=$!
sleep 1

cat > "${TMP}/printer.env" <<EOF
PRINTER_QUEUE=${QUEUE}
PRINTER_URI=socket://127.0.0.1:${PORT}
EOF
export SQUINK_CONFIG="${TMP}/printer.env"
export SQUINK_DRIVER="drv:///sample.drv/generic.ppd"

step "print --text --wait (queue does not exist yet: created from the config)"
"${BIN}" print --text "SQUINK E2E $(date +%T)" --job-name e2e-text --no-discover --wait=90
/usr/bin/lpstat -v "${QUEUE}"

step "setup (queue exists: fast path, no lpadmin)"
"${BIN}" setup --no-discover | tee "${TMP}/setup.txt"
grep -q "queue ${QUEUE} -> socket://127.0.0.1:${PORT}" "${TMP}/setup.txt" || fail "setup did not take the fast path"

step "print FILE --json --wait"
printf 'line 1\nline 2\n' > "${TMP}/doc.txt"
OUT="$("${BIN}" print "${TMP}/doc.txt" --copies 2 --json --wait=90 2>/dev/null)"
echo "   ${OUT}"
[[ "$(echo "${OUT}" | json_get "['state']")" == "completed" ]] || fail "job did not complete"

step "held job: --wait times out with exit 3"
set +e
"${BIN}" print --text "held" -o job-hold-until=indefinite --wait=3
CODE=$?
set -e
[[ ${CODE} -eq 3 ]] || fail "expected exit 3, got ${CODE}"

step "jobs lists the held job"
"${BIN}" jobs
HELD="$("${BIN}" jobs --json | json_get "['jobs'][0]['id']")"
[[ -n "${HELD}" ]] || fail "no pending job listed"

step "cancel ${HELD}"
"${BIN}" cancel "${HELD}"
sleep 1
[[ "$("${BIN}" jobs --json | json_get "['jobs'].__len__()")" == "0" ]] || fail "job still pending after cancel"

step "status --json"
"${BIN}" status --json --queue "${QUEUE}" | tee "${TMP}/status.json"
[[ "$(json_get "['queue']['name']" < "${TMP}/status.json")" == "${QUEUE}" ]] || fail "status did not report the queue"

step "bytes at the fake printer"
BYTES=$(wc -c < "${RECEIVED}" 2>/dev/null | tr -d " " || echo 0)
echo "   received: ${BYTES} bytes"
[[ "${BYTES}" -gt 0 ]] || fail "nothing reached the printer"
grep -q "PRINTER_URI=socket://127.0.0.1:${PORT}" "${SQUINK_CONFIG}" || fail "config was not saved"

echo
echo "OK: squink end-to-end passed."
