#!/bin/bash
#
# remap_test.sh  --  run on the 149 (client) machine
#
# Exercises and validates the tc port-remap on 222 (wire port 88 <-> real
# listener port 80). Each test targets a distinct property; see the banner
# printed before each one for what it proves.
#
# Usage:
#   ./remap_test.sh                 # run everything
#   ./remap_test.sh handshake       # run one test by name
#   TARGET=10.134.26.222 ./remap_test.sh
#
# Companion: run watch_222.sh on the 222 box to see tc counters climb.

set -u

# ---- config -----------------------------------------------------------------
TARGET="${TARGET:-10.134.26.222}"   # server (222)
FAKE_PORT="${FAKE_PORT:-88}"        # wire port the client talks to
BIGFILE="${BIGFILE:-/big.bin}"      # large file served by 222 (create it there)
OUTDIR="${OUTDIR:-./remap_results}"
DUR="${DUR:-15s}"                   # default wrk duration
# -----------------------------------------------------------------------------

URL="http://${TARGET}:${FAKE_PORT}"
mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$OUTDIR/run_${STAMP}.log"

banner() {
  echo | tee -a "$LOG"
  echo "==================================================================" | tee -a "$LOG"
  echo ">> $1" | tee -a "$LOG"
  echo "   $2" | tee -a "$LOG"
  echo "==================================================================" | tee -a "$LOG"
}

run() { echo "\$ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }

need() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# TEST: connectivity
#   Proves: the remap delivers a single request end to end. This is the
#   smallest possible confirmation -- one connection, one HTTP response.
#   A "200" means: SYN rewritten 88->80, listener on 80 answered, reply
#   rewritten 80->88, client saw it as coming from :88. If this fails,
#   nothing else will; stop and fix the rules first.
# -----------------------------------------------------------------------------
t_connectivity() {
  banner "connectivity" "One request end-to-end. Proves the remap works at all."
  run curl -s -o /dev/null -w "http_code=%{http_code} time_total=%{time_total}s\n" \
      --connect-timeout 3 -m 5 "$URL/"
}

# -----------------------------------------------------------------------------
# TEST: wire-check (CLIENT SIDE, 149)
#   Proves (client half): port-88 traffic flows in BOTH directions, i.e. the
#   client's request goes to :88 AND the reply comes back sourced from :88.
#   A reply from TARGET.88 can only happen if 222's EGRESS rewrite (80->88)
#   fired -- so this confirms the egress direction.
#
#   IMPORTANT: On the wire, traffic is ALWAYS :88 both ways -- the :80 rewrite
#   lives only inside 222. So "no port-80 on the wire" is expected and proves
#   nothing from here. The INGRESS direction (was the SYN really delivered to
#   the :80 socket?) can only be confirmed ON 222 at the socket layer. Run
#   verify_222.sh there, at the same time, for that half. This function does
#   the client half and reminds you to run the server half.
# -----------------------------------------------------------------------------
t_wirecheck() {
  banner "wire-check (client half)" \
    "Confirm reply comes back from :$FAKE_PORT (proves 222 egress 80->$FAKE_PORT fired)."
  if ! need tcpdump; then echo "tcpdump not installed, skipping" | tee -a "$LOG"; return; fi
  local cap="$OUTDIR/wirecheck_${STAMP}.pcap"
  local iface
  iface=$(ip -o route get "$TARGET" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  iface="${iface:-vf_eth0}"
  echo "capturing on $iface for 6s..." | tee -a "$LOG"
  timeout 6 tcpdump -i "$iface" -nn -w "$cap" "tcp and host $TARGET" &
  local tpid=$!
  sleep 1
  for i in 1 2 3 4 5; do curl -s -o /dev/null "$URL/"; done
  wait $tpid 2>/dev/null

  echo "--- port-$FAKE_PORT traffic, grouped by direction (expect BOTH ways) ---" | tee -a "$LOG"
  # column $3 = src.port, $5 = dst.port(:); group to show both directions exist
  tcpdump -nn -r "$cap" "tcp port $FAKE_PORT" 2>/dev/null | \
     awk '{print $3" -> "$5}' | sed 's/:$//' | sort | uniq -c | tee -a "$LOG"

  # explicit pass/fail: did we see a packet whose SOURCE is TARGET.FAKE_PORT?
  if tcpdump -nn -r "$cap" "tcp and src host $TARGET and src port $FAKE_PORT" 2>/dev/null | grep -q .; then
    echo "PASS: reply observed FROM $TARGET:$FAKE_PORT  => egress rewrite (80->$FAKE_PORT) confirmed" | tee -a "$LOG"
  else
    echo "FAIL: no reply seen from $TARGET:$FAKE_PORT  => egress rewrite NOT confirmed" | tee -a "$LOG"
  fi

  echo | tee -a "$LOG"
  echo "NOTE: this proves the EGRESS half only. For the INGRESS half (SYN actually" | tee -a "$LOG"
  echo "      delivered to the :80 socket on 222), run verify_222.sh ON 222 now." | tee -a "$LOG"
  echo "pcap saved: $cap" | tee -a "$LOG"
}

# -----------------------------------------------------------------------------
# TEST: baseline
#   Proves: a known-good reference under light load. Low concurrency, so the
#   numbers reflect a healthy path, not saturation. Everything later is
#   compared against this. Watch for the "Socket errors" line -- it must be
#   absent.
# -----------------------------------------------------------------------------
t_baseline() {
  banner "baseline" "Light load (2t/10c). Reference throughput+latency, expect 0 errors."
  need wrk || { echo "wrk not installed, skipping"; return; }
  run wrk -t2 -c10 -d"$DUR" --latency "$URL/"
}

# -----------------------------------------------------------------------------
# TEST: handshake-flood
#   Proves: the INGRESS rewrite survives a high rate of NEW connections. Many
#   short connections = many SYNs, each of which must be rewritten 88->80.
#   High concurrency, tiny response. If the ingress rule mis-fires under load
#   you'll see connect errors here specifically.
# -----------------------------------------------------------------------------
t_handshake() {
  banner "handshake-flood" "High connection churn (8t/500c). Stresses the INGRESS 88->80 rewrite on every SYN."
  need wrk || { echo "wrk not installed, skipping"; return; }
  run wrk -t8 -c500 -d"$DUR" --latency "$URL/"
}

# -----------------------------------------------------------------------------
# TEST: large-transfer
#   Proves: the EGRESS rewrite + checksum action handle large, multi-segment
#   responses correctly. Big file => thousands of full 1448-byte data segments,
#   each passing through egress pedit+csum on 222. A checksum bug shows up as
#   read errors or a hang HERE, not in the tiny-response tests. Requires a
#   large file served by 222 at $BIGFILE.
# -----------------------------------------------------------------------------
t_transfer() {
  banner "large-transfer" "Big file (4t/50c). Stresses EGRESS 80->88 rewrite + TCP checksum on bulk data."
  need wrk || { echo "wrk not installed, skipping"; return; }
  # verify the file exists first
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$URL$BIGFILE")
  if [ "$code" != "200" ]; then
    echo "WARNING: $URL$BIGFILE returned $code -- create a big file on 222:" | tee -a "$LOG"
    echo "  dd if=/dev/urandom of=<served-dir>$BIGFILE bs=1M count=50" | tee -a "$LOG"
    return
  fi
  run wrk -t4 -c50 -d"$DUR" --latency "$URL$BIGFILE"
}

# -----------------------------------------------------------------------------
# TEST: capacity
#   Proves: the maximum sustainable throughput and where latency degrades.
#   Steps concurrency up and records req/sec at each level. The point where
#   req/sec stops rising is the ceiling. NOTE: with python http.server the
#   ceiling is the single-threaded server, not the remap -- use nginx on 222
#   to measure the remap's real ceiling.
# -----------------------------------------------------------------------------
t_capacity() {
  banner "capacity" "Concurrency sweep. Finds the throughput ceiling (server-bound unless 222 runs nginx)."
  need wrk || { echo "wrk not installed, skipping"; return; }
  for c in 10 50 100 200 400; do
    echo "--- concurrency=$c ---" | tee -a "$LOG"
    wrk -t4 -c"$c" -d10s "$URL/" 2>&1 | grep -E "Requests/sec|Socket errors|Latency" | tee -a "$LOG"
  done
}

# -----------------------------------------------------------------------------
# TEST: latency (open-model, needs wrk2)
#   Proves: TRUE latency at a fixed request rate, free of Coordinated Omission.
#   Stock wrk's closed loop understates tail latency; wrk2's -R fixes the
#   arrival rate so p99/p99.9 are honest. Isolates any per-packet cost the
#   rewrite adds. Skipped automatically if wrk2 is absent.
# -----------------------------------------------------------------------------
t_latency() {
  banner "latency (wrk2 -R)" "Fixed-rate load. Honest p99/p99.9 latency, reveals per-packet rewrite cost."
  if need wrk2; then
    run wrk2 -t4 -c100 -d"$DUR" -R2000 --latency "$URL/"
  else
    echo "wrk2 not installed; skipping the Coordinated-Omission-corrected test." | tee -a "$LOG"
    echo "Install: git clone https://github.com/giltene/wrk2 && cd wrk2 && make" | tee -a "$LOG"
  fi
}

# -----------------------------------------------------------------------------
# TEST: soak
#   Proves: stability over time -- no fd leaks, no conntrack exhaustion, no
#   drift in the rewrite path. Long duration at moderate load. Watch 222's
#   conntrack count and fd usage alongside. Off by default (long); run with:
#   ./remap_test.sh soak
# -----------------------------------------------------------------------------
t_soak() {
  banner "soak" "Long moderate load (default 5m). Checks for leaks/drift over time."
  need wrk || { echo "wrk not installed, skipping"; return; }
  run wrk -t4 -c50 -d"${SOAK_DUR:-5m}" --latency "$URL$BIGFILE"
}

# -----------------------------------------------------------------------------
# TEST: single-packet (scapy) -- optional
#   Proves: one crafted SYN out, one reply in, and the reply's SOURCE PORT
#   reads 88 (egress rewrite acted on a single packet). Needs root + scapy,
#   and drops outbound RSTs so the kernel doesn't kill the crafted flow.
# -----------------------------------------------------------------------------
t_singlepacket() {
  banner "single-packet (scapy)" "One SYN out, one reply in; confirms egress stamps src=88 on a single packet."
  if ! need python3 || ! python3 -c "from scapy.all import IP, TCP, sr1" 2>/dev/null; then
    echo "scapy not available; skipping." | tee -a "$LOG"; return
  fi
  if [ "$(id -u)" != 0 ]; then echo "needs root; skipping." | tee -a "$LOG"; return; fi
  iptables -A OUTPUT -p tcp --tcp-flags RST RST -d "$TARGET" -j DROP
  trap 'iptables -D OUTPUT -p tcp --tcp-flags RST RST -d "$TARGET" -j DROP 2>/dev/null' RETURN
  python3 - "$TARGET" "$FAKE_PORT" <<'PY' 2>&1 | tee -a "$LOG"
import sys
from scapy.all import IP, TCP, sr1
dst, port = sys.argv[1], int(sys.argv[2])
ans = sr1(IP(dst=dst)/TCP(sport=40001, dport=port, flags="S", seq=1000), timeout=2, verbose=0)
if ans:
    print(f"reply: {ans[IP].src}:{ans[TCP].sport} flags={ans[TCP].flags}")
    print("PASS: reply source port is", ans[TCP].sport, "(expect 88)")
else:
    print("no reply (timeout)")
PY
}

# ---- runner -----------------------------------------------------------------
ALL="connectivity wirecheck baseline handshake transfer capacity latency"

echo "remap test harness  target=$URL  log=$LOG"

if [ $# -gt 0 ]; then
  for name in "$@"; do
    case "$name" in
      connectivity) t_connectivity ;;
      wirecheck)    t_wirecheck ;;
      baseline)     t_baseline ;;
      handshake)    t_handshake ;;
      transfer)     t_transfer ;;
      capacity)     t_capacity ;;
      latency)      t_latency ;;
      soak)         t_soak ;;
      singlepacket) t_singlepacket ;;
      *) echo "unknown test: $name" ;;
    esac
  done
else
  t_connectivity
  t_wirecheck
  t_baseline
  t_handshake
  t_transfer
  t_capacity
  t_latency
  echo | tee -a "$LOG"
  echo "(soak and singlepacket are opt-in: ./remap_test.sh soak | singlepacket)" | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "done. full log: $LOG" | tee -a "$LOG"
